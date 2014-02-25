#!/bin/bash

if [ ${DEBUG:-0} -eq 1 ]; then 
	set -x
fi

# if OWNER not set checks $USER or falls back to $USERNAME (windows?!)
OWNER=${OWNER:=${USER:-$USERNAME}}

# base centos 6.4 for sdp
echo AMI=${AMI:=ami-75342c01}
echo INS_TYPE=${INS_TYPE:=m1.large}
echo NUM_OF_AGENTS=${NUM_OF_AGENTS:=2}

TAG_KEY=owner
CUST_AMI_NAME=horton-cloud-base-$OWNER
KEY_NAME=hdp-key-$OWNER
KEY=$KEY_NAME.pem
SEC_NAME=hdp-sec-grp-$OWNER
CIDR=10.0.0.0/16

LOGFILE=hdp-silent-install.log
rm $LOGFILE

create_new_pkey() {
    echo creating a key: $KEY_NAME
    aws ec2 create-key-pair --key-name $KEY_NAME --query KeyMaterial --out text > $KEY
    chmod 600 $KEY
}

if [[ -f $KEY ]]; then
    echo private key file: $KEY already exists
    FING=$(openssl pkcs8 -in $KEY -nocrypt -topk8 -outform DER | openssl sha1 -c|sed "s/^.*= //")
    echo "  searching in EC2 keypairs the fingerprint: $FING"
    KEY_FOUND=$(aws ec2 describe-key-pairs --filters Name=fingerprint,Values=${FING} --query KeyPairs[].KeyName --out text)
    if [[ $KEY_FOUND == $KEY_NAME ]]; then 
        echo "  key found on ec2: $KEY_FOUND"
    else
        echo "  [WARNING] local file: $KEY can not be recognised as a valid ec2 key-pair"
        TIMESTAMP=$(date +%Y-%m-%d_%H-%M)
        mv $KEY $KEY-$TIMESTAMP
        echo "  [WARNING] it is renamed to: $KEY-$TIMESTAMP"
        echo "  [WARNING] new key will be generated:"
        create_new_pkey
    fi
else
    create_new_pkey
fi


#############
# NETWORKING
#############
VPC_ID=$(aws ec2 create-vpc --cidr-block $CIDR --query Vpc.VpcId --out text)
VPC_STATE=$(aws ec2 describe-vpcs --vpc-ids $VPC_ID --query Vpcs[].State --out text)
echo [CREATED] VPC: $VPC_ID

aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-support true --out text
aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-hostnames true --out text

# waits for running state
while [[ $VPC_STATE != "available" ]]; do 
  echo "wait until VPC gets available ..."
  sleep 10
  VPC_STATE=$(aws ec2 describe-vpcs --vpc-ids $VPC_ID --query Vpcs[].State --out text)
done

# todo: potentially wait for 'available' state

SUBNET=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block $CIDR --out text --query Subnet.SubnetId)
echo [CREATED] SUBNET: $SUBNET

GW_ID=$(aws ec2 create-internet-gateway --query InternetGateway.InternetGatewayId --out text)
echo [CREATED]  GW_ID: $GW_ID

echo [attach] $GW_ID to $VPC_ID >> $LOGFILE
aws ec2 attach-internet-gateway --internet-gateway-id $GW_ID --vpc-id $VPC_ID --out text >> $LOGFILE

ROUTE_ID=$(aws ec2 create-route-table --vpc-id $VPC_ID --out text --query RouteTable.RouteTableId)
echo [CREATED] ROUTE_ID: $ROUTE_ID

echo [associate] $ROUTE_ID to $SUBNET >> $LOGFILE
aws ec2 associate-route-table --route-table-id $ROUTE_ID --subnet-id $SUBNET --out text>> $LOGFILE

echo [route] add default to routing table: $ROUTE_ID >> $LOGFILE
aws ec2 create-route --route-table-id $ROUTE_ID --gateway-id $GW_ID --destination-cidr-block 0.0.0.0/0 --out text >> $LOGFILE
echo [TAG] $SUBNET,$ROUTE_ID,$GW_ID,$VPC_ID with: $TAG_KEY=$OWNER >> $LOGFILE
aws ec2 create-tags --resources $SUBNET $ROUTE_ID  $GW_ID $VPC_ID --tags Key=$TAG_KEY,Value=$OWNER  --out text >> $LOGFILE

# creates a security group
SEC_ID=$(aws ec2 create-security-group --group-name $SEC_NAME --vpc-id $VPC_ID --description "security group for hadoop cluster" --out text --query GroupId)
echo [CREATED] $SEC_NAME id:$SEC_ID
echo [TAG] $SEC_ID  with: $TAG_KEY=$OWNER >> $LOGFILE
aws ec2 create-tags --resources $SEC_ID  --tags Key=$TAG_KEY,Value=$OWNER --out text >> $LOGFILE

# sets firewall rules
#aws ec2 authorize-security-group-egress --group-id $SEC_ID --protocol -1 --cidr 0.0.0.0/0
echo [SEC] open port 22 >> $LOGFILE
aws ec2 authorize-security-group-ingress --group-id $SEC_ID --protocol tcp --port 22 --cidr 0.0.0.0/0 --out text >> $LOGFILE
echo [SEC] open port 8080 >> $LOGFILE
aws ec2 authorize-security-group-ingress --group-id $SEC_ID --protocol tcp --port 8080 --cidr 0.0.0.0/0 --out text >> $LOGFILE
echo [SEC] open port 0-65535 for $CIDR >> $LOGFILE
aws ec2 authorize-security-group-ingress --group-id $SEC_ID --protocol tcp --port 0-65535 --cidr $CIDR --out text >> $LOGFILE

AMBARI_ID=$(aws ec2 run-instances --image-id $AMI --count 1 --key-name $KEY_NAME --instance-type $INS_TYPE --security-group-ids $SEC_ID --subnet-id $SUBNET --associate-public-ip-address --out text --query Instances[0].InstanceId)
echo [CREATED] AMBARI_ID: $AMBARI_ID
AMBARI_STATE=$(aws ec2 describe-instances --instance-ids $AMBARI_ID --query Reservations[].Instances[].State.Name --out text)

# waits for running state
while [[ $AMBARI_STATE != "running" ]]; do 
  echo "wait for instance running ..."
  sleep 10
  AMBARI_STATE=$(aws ec2 describe-instances --instance-ids $AMBARI_ID --query Reservations[].Instances[].State.Name --out text)
done

# tag
echo [TAG] $AMBARI_ID  with: $TAG_KEY=$OWNER >> $LOGFILE
aws ec2 create-tags --resources $AMBARI_ID  --tags Key=$TAG_KEY,Value=$OWNER --out text >> $LOGFILE
echo [TAG] $AMBARI_ID  with: Name=ambari >> $LOGFILE
aws ec2 create-tags --resources $AMBARI_ID  --tags Key=Name,Value=ambari --out text >> $LOGFILE

AMBARI_IP=$(aws ec2 describe-instances --instance-ids $AMBARI_ID --query Reservations[].Instances[].PublicIpAddress --out text)

SSH_COMMAND="ssh -t -o ConnectTimeout=5 -o LogLevel=quiet -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i $KEY ec2-user@$AMBARI_IP"
SSH_COMMANDTTY="ssh -f -tt -o ConnectTimeout=5 -o LogLevel=quiet -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i $KEY ec2-user@$AMBARI_IP"
echo ssh command to connect:
echo $SSH_COMMAND

while ! $SSH_COMMAND true; do
  echo sleeping 5 sec for ssh ...
  sleep 5
done

# workaround-1: tty needed for sudo, see more: http://blog.zenlinux.com/2008/02/centos-5-configuration-tweak-for-sudo/
# workaround-2: fixing RHEL specific ssh issue, see more: https://forums.aws.amazon.com/thread.jspa?messageID=474971
$SSH_COMMANDTTY 'sudo sed -i "/requiretty/ s/^/#/" /etc/sudoers'
$SSH_COMMANDTTY<<"EOF1"
tac /etc/rc.local | sed "1,3 s/^/#/"|tac > /tmp/rc.local
sudo cp /tmp/rc.local /etc/rc.local
EOF1

# prepare the custome AMI
# copies private key for passwordless ssh
scp  -i $KEY -o LogLevel=quiet -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null  $KEY ec2-user@$AMBARI_IP:.ssh/id_rsa

$SSH_COMMANDTTY <<"EOF2"
sudo chkconfig ntpd on
sudo chkconfig iptables off
sudo /etc/init.d/iptables stop
sudo service ntpd start
EOF2

CUST_AMI=$(aws ec2 create-image --instance-id $AMBARI_ID --name $CUST_AMI_NAME --no-reboot --out text --query ImageId)
echo [TAG] CUST_AMI with $TAG_KEY=$OWNER >> $LOGFILE
aws ec2 create-tags --resources $CUST_AMI  --tags Key=$TAG_KEY,Value=$OWNER --out text >> $LOGFILE

SNAPSHOT=$(aws ec2 describe-images --image-ids $CUST_AMI --query Images[].BlockDeviceMappings[0].Ebs.SnapshotId --out text)
echo [TAG] SNAPSHOT:$SNAPSHOT with $TAG_KEY=$OWNER >> $LOGFILE
aws ec2 create-tags --resources $SNAPSHOT  --tags Key=$TAG_KEY,Value=$OWNER --out text >> $LOGFILE

echo [install] ambari
$SSH_COMMAND <<"EOF3"
sudo su
# curl -so /etc/yum.repos.d/ambari.repo http://public-repo-1.hortonworks.com/ambari/centos6/1.x/updates/1.4.3.38/ambari.repo 
curl -so /etc/yum.repos.d/ambari.repo http://public-repo-1.hortonworks.com/ambari/centos6/1.x/GA/ambari.repo
# curl -so /etc/yum.repos.d/ambari.repo   http://public-repo-1.hortonworks.com/HDP/centos6/2.x/updates/2.0.6.0/hdp.repo

yum repolist
yum -y install ambari-server
ambari-server setup --silent
exit
EOF3


$SSH_COMMAND <<"EOF4"
sudo ambari-server start < /dev/null > /tmp/start_ambari.log 2>&1 &
EOF4

echo ======================================================
echo open the AMBARI in you browser http://$AMBARI_IP:8080
echo ======================================================

# start NUM_OF_AGENTS instances
SLAVE_RESERV=$(aws ec2 run-instances --image-id $CUST_AMI --count $NUM_OF_AGENTS --key-name $KEY_NAME --instance-type $INS_TYPE  --security-group-ids $SEC_ID --subnet-id $SUBNET --associate-public-ip-address --query ReservationId --out text)
echo [CREATED] SLAVE_RESERV=$SLAVE_RESERV

SLAVES=$(aws ec2 describe-instances --filters Name=reservation-id,Values=$SLAVE_RESERV --query Reservations[].Instances[].InstanceId --out text |xargs echo)
SLAVE_IPS=$(aws ec2 describe-instances --filters Name=reservation-id,Values=$SLAVE_RESERV --query Reservations[].Instances[].PublicIpAddress --out text)

# tag all slave
aws ec2 create-tags --resources $SLAVES  --tags Key=$TAG_KEY,Value=$OWNER --out text >> $LOGFILE
aws ec2 create-tags --resources $SLAVES  --tags Key=Name,Value=slave --out text >> $LOGFILE

NUM_OF_NOT_RUNNING=$(aws ec2 describe-instances --filters Name=reservation-id,Values=$SLAVE_RESERV  --query Reservations[].Instances[].State.Name --out text|xargs -n 1 echo|grep -v running|wc -l)    
while [[ $NUM_OF_NOT_RUNNING -ne 0 ]]; do 
  echo "wait until all SLAVES are running ..."
  sleep 10
  NUM_OF_NOT_RUNNING=$(aws ec2 describe-instances --filters  Name=reservation-id,Values=$SLAVE_RESERV  --query Reservations[].Instances[].State.Name --out text|xargs -n 1 echo|grep -v running|wc -l)
done


# copies the private key for every slave for passwordless ssh
chmod 600 $KEY
for slave in $SLAVE_IPS; do 
  echo checking ssh connectivity on: $SLAVE_IPS
  SLAVE_SSH="ssh -t -o ConnectTimeout=5 -o LogLevel=quiet -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i $KEY ec2-user@$slave"
  while ! $SLAVE_SSH true; do
    echo sleeping 5 sec for ssh ...
    sleep 5
  done
  
  scp -i $KEY -o LogLevel=quiet -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null $KEY ec2-user@${slave}:~/.ssh/id_rsa
done


echo ======================================================
echo create a new cluster and enter the target hosts:
echo CHANGE THE FOLLOWING FIELDS:
echo Provide your SSH Private Key to automatically register hosts:    $KEY
echo "SSH user (root or passwordless sudo account):                    ec2-user"
aws ec2 describe-instances --filters Name=reservation-id,Values=$SLAVE_RESERV --query Reservations[].Instances[].PrivateDnsName --out text|xargs -n 1
echo ======================================================

: <<"TESTHADOOP"
#!/bin/bash
 
set -x
 
su hdfs - -c "hadoop fs -rmdir /shakespeare"
cd /tmp
wget http://homepages.ihug.co.nz/~leonov/shakespeare.tar.bz2
tar xjvf shakespeare.tar.bz2
now=`date +"%y%m%d-%H%M"`
su hdfs - -c "hadoop fs -mkdir -p /shakespeare"
su hdfs - -c "hadoop fs -mkdir -p /shakespeare/$now"
su hdfs - -c "hadoop fs -put /tmp/Shakespeare /shakespeare/$now/input"
su hdfs - -c "hadoop jar /usr/lib/hadoop-mapreduce/hadoop-mapreduce-examples-2.2.0.2.0.6.0-76.jar wordcount /shakespeare/$now/input /shakespeare/$now/output"
su hdfs - -c "hadoop fs -cat /shakespeare/$now/output/part-r-* | sort -nk2"
TESTHADOOP


: <<COMMENTBLOCK

in /etc/ambari-agent/conf/ambari-agent.ini:
[server]
hostname=ip-10-0-140-6.eu-west-1.compute.internal.localdomain.localdomain.localdomain.localdomain

# fix-1
sudo sed -i.xxx "/hostname=/ s/.*/hostname=ip-10-0-140-6.eu-west-1.compute.internal/" /etc/ambari-agent/conf/ambari-agent.ini
echo "35 36 37 38 39 40"|xargs -n 1 echo|xargs -I@ ssh  ip-10-0-82-@.eu-west-1.compute.internal 'sudo /etc/init.d/ambari-agent restart'

# server api:
https://github.com/apache/ambari/blob/trunk/ambari-server/docs/api/v1/index.md

# agent:
#/etc/init.d/ambari-agent which starts:
# /usr/sbin/ambari-agent which starts:
OUTFILE=/var/log/ambari-agent/ambari-agent.out
LOGFILE=/var/log/ambari-agent/ambari-agent.log
AGENT_SCRIPT=/usr/lib/python2.6/site-packages/ambari_agent/main.py


/sbin/dhclient-script
/etc/resolv.conf


curl -u admin:admin "http://54.229.167.41:8080/api/v1/clusters/delme/configurations?type=capacity-scheduler&tag=version1"
curl -u admin:admin "http://54.229.167.41:8080/api/v1/clusters/delme/configurations?type=mapred-site&tag=version1"
COMMENTBLOCK