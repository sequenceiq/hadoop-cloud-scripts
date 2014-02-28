#!/bin/bash
# with ansible its a 1 liner:
# ansible -i hosts all -m ec2_vpc -a "aws_access_key=$AK aws_secret_key=$AS region=eu-west-1 vpc_id=vpc-9b8f9df9 state=absent"

# first cli parameter of this script is the owner, default is $OWNER
OWNER=${1:-$USER}

TAG_KEY=owner

if [[ "" == "$(aws ec2 describe-vpcs --filters Name=tag:owner,Values=$OWNER --out text)" ]]; then
    echo no VPC found with tag: $TAG_KEY=$OWNER
    exit 1
fi

VPC=$(aws ec2 describe-vpcs --filters Name=tag:$TAG_KEY,Values=$OWNER --query Vpcs[0].VpcId --out text)

INSTANCES=$(aws ec2 describe-instances --filter Name=vpc-id,Values=$VPC --query Reservations[].Instances[].InstanceId --out text)
for ins in $INSTANCES; do 
  #echo [DELETE] terminates $ins
  aws ec2 terminate-instances --instance-ids $ins --query TerminatingInstances[].[InstanceId,CurrentState.Name] --out text
done

IMAGES=$(aws ec2 describe-images --filters Name=tag:$TAG_KEY,Values=$OWNER --query Images[].ImageId --out text)
if [[ $IMAGES = "" ]]; then
    echo "no more running instances"
else
    for ami in $IMAGES; do
        echo deregister image: $ami
        SNAPSHOTS=$(aws ec2 describe-images --image-ids $ami --query Images[].BlockDeviceMappings[].Ebs.SnapshotId --out text)
        aws ec2 deregister-image --image-id $ami --out text

        for snap in $SNAPSHOTS; do
            echo delete snapshot: $snap
            aws ec2 delete-snapshot --snapshot-id $snap --out text
        done
    done
fi

INS_STATES=$(aws ec2 describe-instances --instance-ids $INSTANCES --query Reservations[].Instances[].State.Name --out text)
REMAINING=$(echo $INS_STATES|sed 's/ //g;s/terminated//g')
while [[ $REMAINING != "" ]]; do 
  echo "waits until all instances are terminated ..."
  sleep 10
  INS_STATES=$(aws ec2 describe-instances --instance-ids $INSTANCES --query Reservations[].Instances[].State.Name --out text)
  REMAINING=$(echo $INS_STATES|sed 's/ //g;s/terminated//g')
done

SUBS=$(aws ec2 describe-subnets --filter Name=vpc-id,Values=$VPC --query Subnets[].SubnetId --out text)
for sub in $SUBS; do
    echo [DELETE] $sub
    aws ec2 delete-subnet --subnet-id $sub --out text
done

IGWS=$(aws ec2 describe-internet-gateways --filter Name=attachment.vpc-id,Values=$VPC --query InternetGateways[].InternetGatewayId --out text) 
for igw in $IGWS; do
    echo [detach-internet-gateway] $igw from $VPC
    aws ec2 detach-internet-gateway --internet-gateway-id $igw --vpc-id $VPC --out text
    echo [DELETE] $igw
    aws ec2 delete-internet-gateway --internet-gateway-id  $igw --out text
done

RTBS=$(aws ec2 describe-route-tables --filter Name=vpc-id,Values=$VPC Name=tag:$TAG_KEY,Values=$OWNER --query RouteTables[].RouteTableId --out text)
for rtb in $RTBS; do
    echo [DELETE] default route 0.0.0.0/0 from $rtb
    aws ec2 delete-route --route-table-id $rtb --destination-cidr-block 0.0.0.0/0 --out text
    
    NOT_MAIN_ASSOCS=$(aws ec2 describe-route-tables  --route-table-ids $rtb --query "RouteTables[].Associations[].[Main,RouteTableAssociationId]" --out text|grep -v True)
    echo RouteTableAssociations left: $NOT_MAIN_ASSOCS
    # for rtbassoc in $RTBASSOCS; do 
    #      aws ec2 disassociate-route-table --association-id $rtbassoc
    # done
    echo [DELETE] $rtb
    aws ec2 delete-route-table --route-table-id $rtb --out text
    
done

SGS=$(aws ec2 describe-security-groups --filter Name=vpc-id,Values=$VPC --query SecurityGroups[].GroupName --out text)
for sg in $SGS; do
    if [[ 'default' != $sg ]]; then
        echo [DELETE] $sg            
        sgid=$(aws ec2 describe-security-groups --filter Name=vpc-id,Values=$VPC Name=group-name,Values=$sg  --query SecurityGroups[].GroupId --out text)
        aws ec2 delete-security-group --group-id $sgid --out text
    fi
done

# Network ACLs are getting deleted automagically
# ACLS=$(aws ec2 describe-network-acls --filter Name=vpc-id,Values=$VPC --query NetworkAcls[].NetworkAclId --out text)
# for acl in $ACLS; do
#     aws ec2 delete-network-acl --network-acl-id $acl
# done

echo [DELETE] $VPC
aws ec2 delete-vpc --vpc-id $VPC --out text

#aws ec2 delete-key-pair --key-name $KEY_NAME