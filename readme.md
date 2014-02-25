# Deploying a Hadoop Cluster on Amazon EC2 with HDP2

The [original] (http://hortonworks.com/blog/deploying-hadoop-cluster-amazon-ec2-hortonworks) documentation contains screenshots to describe AWS cli actions. These scripts help you to do it automated. It is continousely under development and improvements, so feel free to create an issue if you run into some trouble.

You have 2 choises to run it:

- **Option-1**: run it locally on your dev box: it needs aws cli installed
- **Option-2**: run it from the cloud: all you need is a browser, no python/pip/aws-cli installation needed.

# Option-1: Run it locally

If you have [aws cli] (http://aws.amazon.com/cli/) installed and configured, you can run the silent installer script rigth away:

```
./silent-install.sh
```

this will start by default:

- 1 ambari server and 2 agents
- OS: centos 6.4 
- Instance type: m1.large
- create a new key-pair, and use it for all instances

### Configuring the silent install script

If you are not satisfied with with the default values above, you can set the following environment variables:

```
export AMI=ami-xxx
export INS_TYPE=m1.micro
export NUM_OF_AGENTS=6

./silent-install.sh
```

region specific EC2 ami's are listed below.

# Option-2: Deploy from EC2

The silent install script is written is *bash*, so its not trivial to run it on `windows`. Its possile from [git bash](http://msysgit.github.io/), but there is an easier way:

* start a micro instance on ec2
* pass an installer script as user-data. all ubuntu images are prepared with [cloud init] (https://help.ubuntu.com/community/CloudInit) which interprets the user-data as script if the first line starts with: `#!/`

### step 1: start ubuntu
Choose your region:

| region | ami | launch |
| --- | --- | --- |
| eu-west-1 | ami-aa56a1dd | [start](https://console.aws.amazon.com/ec2/home?region=eu-west-1#launchAmi=ami-aa56a1dd) |
| us-east-1 | ami-83dee0ea | [start](https://console.aws.amazon.com/ec2/home?region=eu-west-1#launchAmi=ami-83dee0ea) |
| us-west-1 | ami-c45f6281 | [start](https://console.aws.amazon.com/ec2/home?region=eu-west-1#launchAmi=ami-c45f6281) |
| us-west-2 | ami-d0d8b8e0 | [start](https://console.aws.amazon.com/ec2/home?region=eu-west-1#launchAmi=ami-d0d8b8e0) |


for other egions check the [Amazon EC2 AMI Locator](http://cloud-images.ubuntu.com/locator/ec2/)

### step 2: select instance type
 
choose micro instance: `m1.micro`, and clik next

### step 3: user-data

when you are on the `Configure Instance Details` dialog, open the `Advanced Details` section and fill the `User data` as text:

```
#!/usr/bin/env bash

sudo apt-get install -y python-pip
sudo pip install awscli

export AWS_ACCESS_KEY_ID=<YOUR_KEY>
export AWS_SECRET_ACCESS_KEY=<YOUR_SECRET>
export AWS_DEFAULT_REGION=eu-west-1
export TAG=delme-ok-yes

curl -s -o /tmp/silent-install.sh https://gist.github.com/lalyos/bc986eab38ab72874c87/raw/silent-install.sh
chmod +x /tmp/silent-install.sh
/tmp/silent-install.sh delme-owner &> /tmp/silent-install-ambari.log
```

Replace `<YOUR_KEY>` and `<YOUR_SECRET>` with your real key values. You can check that the script doesnt' store it. Should you want you can create temporal access keys on IAM.

### step 3: Start the instance

Click on `Review and Launch`. Make sure you have the private key available.

### step 4: Check the process

Once the instance is running, ssh into it and `tail` the log file.

```
ssh -i your-key.pem ubuntu@<PUBLIC_IP> tail -f /tmp/silent-install-ambari.log
```

Hope this helps, and saved you lots of time.
Enjoy,
SequenceIQ
