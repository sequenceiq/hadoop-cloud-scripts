#!/bin/bash

# checks required software
which aws > /dev/null || echo install aws cli from http://aws.amazon.com/cli/

# base centos 6.4 for sdp
AMI=ami-75342c01

CUST_AMI_NAME=horton-cloud-base-$USER

KEY_NAME=cdhp-key-$USER
KEY=$KEY_NAME.pem
INS_TYPE=m1.large
SEC_NAME=cdhp-sec-grp-$USER
CIDR=10.0.0.0/16

# creates a key
aws ec2 create-key-pair --key-name $KEY_NAME --query KeyMaterial --out text > $KEY
chmod 600 $KEY

# create a VPC
VPC_ID=$(aws ec2 create-vpc --cidr-block $CIDR --query Vpc.VpcId --out text)
VPC_STATE=$(aws ec2 describe-vpcs --vpc-ids $VPC_ID --query Vpcs[].State --out text)
echo VPC id: $VPC_ID
echo VPC state: $VPC_STATE
# todo: potentially wait for 'available' state


#############
# NETWORKING
#############
SUBNET=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block $CIDR --out text --query Subnet.SubnetId)

GW_ID=$(aws ec2 create-internet-gateway --query InternetGateway.InternetGatewayId --out text)
aws ec2 attach-internet-gateway --internet-gateway-id $GW_ID --vpc-id $VPC_ID

ROUTE_ID=$(aws ec2 create-route-table --vpc-id $VPC_ID --out text --query RouteTable.RouteTableId)
aws ec2 associate-route-table --route-table-id $ROUTE_ID --subnet-id $SUBNET

# add routing
aws ec2 create-route --route-table-id $ROUTE_ID --gateway-id $GW_ID --destination-cidr-block 0.0.0.0/0

# tag
aws ec2 create-tags --resources $SUBNET $ROUTE_ID  $GW_ID $VPC_ID --tags Key=hdp-cloud-owner,Value=$USER

# creates a security group
SEC_ID=$(aws ec2 create-security-group --group-name $SEC_NAME --vpc-id $VPC_ID --description "security group for hadoop cluster" --out text --query GroupId)
echo Security group created name:$SEC_NAME id:$SEC_ID
# tag
aws ec2 create-tags --resources $SEC_ID  --tags Key=hdp-cloud-owner,Value=$USER

# sets firewall rules
# aws ec2 authorize-security-group-egress --group-id $SEC_ID --protocol -1 --cidr 0.0.0.0/0aws ec2 authorize-security-group-ingress --group-id $SEC_ID --protocol tcp --port 22 --cidr 0.0.0.0/0
aws ec2 authorize-security-group-ingress --group-id $SEC_ID --protocol tcp --port 8080 --cidr 0.0.0.0/0
aws ec2 authorize-security-group-ingress --group-id $SEC_ID --protocol tcp --port 0-65535 --cidr $CIDR

# see the gist containing the initial script: https://gist.github.com/lalyos/bc986eab38ab72874c87
USER_DATA=$(curl -s https://gist.github.com/lalyos/bc986eab38ab72874c87/raw/init.sh|base64)

AMBARI_ID=$(aws ec2 run-instances --image-id $AMI --count 1 --key-name $KEY_NAME --instance-type $INS_TYPE --user-data $USER_DATA --security-group-ids $SEC_ID --subnet-id $SUBNET --associate-public-ip-address --out text --query Instances[0].InstanceId)
#AMBARI_ID=$(aws ec2 run-instances --image-id $AMI --count 1 --key-name $KEY_NAME --instance-type $INS_TYPE --security-group-ids $SEC_ID --subnet-id $SUBNET --associate-public-ip-address --out text --query Instances[0].InstanceId)
AMBARI_STATE=$(aws ec2 describe-instances --instance-ids $AMBARI_ID --query Reservations[].Instances[].State.Name --out text)

# waits for running state
while [[ $AMBARI_STATE != "running" ]]; do 
  echo "wait for instance running ..."
  sleep 10
  AMBARI_STATE=$(aws ec2 describe-instances --instance-ids $AMBARI_ID --query Reservations[].Instances[].State.Name --out text)
done

# tag
aws ec2 create-tags --resources $AMBARI_ID  --tags Key=hdp-cloud-owner,Value=$USER
aws ec2 create-tags --resources $AMBARI_ID  --tags Key=Name,Value=ambari

AMBARI_IP=$(aws ec2 describe-instances --instance-ids $AMBARI_ID --query Reservations[].Instances[].PublicIpAddress --out text)

ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i $KEY ec2-user@$AMBARI_IP 

# fixing RHEL specific ssh issue
# https://forums.aws.amazon.com/thread.jspa?messageID=474971
# workaround for the workaround: http://blog.zenlinux.com/2008/02/centos-5-configuration-tweak-for-sudo/
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i $KEY ec2-user@$AMBARI_IP 'sudo sed -i "/requiretty/ s/^/#/" /etc/sudoers && tac /etc/rc.local | sed "1,3 s/^/#/"|tac > /tmp/rc.local && sudo cp /tmp/rc.local /etc/rc.local'

ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i $KEY ec2-user@$AMBARI_IP 'sudo chkconfig ntpd on && sudo chkconfig iptables off && sudo /etc/init.d/iptables stop && sudo service ntpd start'


CUST_AMI=$(aws ec2 create-image --instance-id $AMBARI_ID --name $CUST_AMI_NAME --no-reboot --out text --query ImageId)
aws ec2 create-tags --resources $CUST_AMI  --tags Key=hdp-cloud-owner,Value=$USER


# start 6 instances

aws ec2 run-instances --image-id $CUST_AMI --count 6 --key-name $KEY_NAME --instance-type $INS_TYPE --user-data $USER_DATA --security-group-ids $SEC_ID --subnet-id $SUBNET --associate-public-ip-address

SLAVES=$(aws ec2 describe-instances --filters Name=reservation-id,Values=r-d1671991 --query Reservations[].Instances[].InstanceId --out text |xargs echo)
# tag all slave
aws ec2 create-tags --resources $SLAVES  --tags Key=hdp-cloud-owner,Value=$USER
aws ec2 create-tags --resources $SLAVES  --tags Key=Name,Value=slave

#ambari install 
#ssh AMBARI

ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i $KEY ec2-user@$AMBARI_IP 'curl -sO https://gist.github.com/lalyos/bc986eab38ab72874c87/raw/install_ambari.sh && chmod +x install_ambari.sh && sudo ./install_ambari.sh'

echo open the AMBARI in you browser http://$AMBARI_IP:8080
echo create a new cluster and enter the target hosts:
aws ec2 describe-instances --filters Name=tag:hdp-cloud-owner,Values=$USER --query Reservations[].Instances[].PrivateDnsName --out text|xargs -n 1 echo


aws_clear() {
    aws ec2 delete-key-pair --key-name $KEY_NAME
    aws ec2 delete-security-group --group-id $SEC_ID
    aws ec2 delete-route-table --route-table-id $ROUTE_ID
    aws ec2 terminate-instances --instance-ids $AMBARI_ID
}
