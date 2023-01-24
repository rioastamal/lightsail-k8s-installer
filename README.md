## About lightsail-k8s-installer

lightsail-k8s-installer is a shell script to simplifies the process of setting up a Kubernetes cluster on Amazon Lightsail. Not only it automates the creation of necessary resources using AWS CloudFormation, but it also automates the installation of Kubernetes packages. With just one simple command, your Kubernetes cluster should up and running in no time!

```sh
sh lightsail-k8s-installer.sh -i demo
```

By default it will create 3 Amazon Lightsail instances (1 control plane, 2 workers) and 1 Load Balancer. The load balancer will distribute the traffic to all worker nodes.

To destroy the cluster.

```sh
sh lightsail-k8s-installer.sh -d demo
```

You can also use CloudFormation console or AWS CLI to delete the stack.

## Requirements

Things you need to run this script:

- Active AWS account and make sure it has permissions to create Lightsail and CloudFormation resources.
- AWS CLI v2
- SSH client
- Basic shell utilise such as `awk`, `cat`, `cut`, `date`, `sed`, `tr`, `wc`.

lightsail-k8s-installer has been tested using Bash v4.2 but it should work for other shells.

## Installation

Download the archive or clone the repository.

```sh
curl -o 'lightsail-k8s-installer.zip' -s -L https://github.com/rioastamal/lightsail-k8s-installer/archive/refs/heads/master.zip
unzip lightsail-k8s-installer.zip
cd lightsail-k8s-installer-master/
```

## Usage and Examples

Running lightsail-k8s-installer with `-h` flag will gives you list of options and examples.

```sh
sh lightsail-k8s-installer.sh -h
```

```
Usage: lightsail-k8s-installer.sh [OPTIONS]

Where OPTIONS:
  -a AZs        specify list of Available Zones using AZs
  -c CIDR       specify pod network using CIDR
  -d ID         destroy installation id specified by ID
  -h            print this help and exit
  -i ID         specify installation id using ID
  -m            dry run mode, print CloudFormation template and exit
  -r REGION     specify region using REGION
  -w NUM        specify number of worker nodes using NUM
  -v            print script version
  
----------------------- lightsail-k8s-installer -----------------------

lightsail-k8s-installer is a command line interface to bootstrap Kubernetes 
cluster on Amazon Lightsail. 

lightsail-k8s-installer is free software licensed under MIT. Visit the project 
homepage at http://github.com/rioastamal/lightsail-k8s-installer.
```

To create Kubernetes cluster with 4 worker nodes you only need to specify installation id using `-i` and `-w` options.

```sh
sh lightsail-k8s-installer.sh -i demo -w 4
```

```
------------------------------------
lightsail-k8s-installer v2023-01-21
------------------------------------
This process will create Kubernetes cluster on Amazon Lightsail.

CloudFormation stack: lk8s-namer
              Region: us-east-1
     AZs worker pool: us-east-1a us-east-1b us-east-1c 
           Resources: - 1 control plane node (plan: $5)
                      - 4 worker nodes (plan: $5)
                      - 1 load balancer (plan: $18)
      Estimated cost: $43.00/month or $0.06/hour

Press any key to continue: 

This may take several minutes, please wait...
To view detailed log, run following command on another terminal:
  tail -f /home/ec2-user/lightsail-k8s-installer/.out/us-east-1-lk8s-demo-20230124085932.log

[LK8S]: Checking existing stack 'lk8s-demo'
[LK8S]: Stack 'lk8s-demo' is not exists, good!
[LK8S]: Waiting stack 'lk8s-demo' to be ready..
...[cut]...
```

Command above will produces following resources:

Resource | Name | Description
---------|------|-----
CloudFormation | lk8s-demo | CloudFormation stack
Lightsail Instance | kube-cp-lk8s-demo-1 | Control plane node
Lightsail Instance | kube-worker-lk8s-demo-1 | Worker node
Lightsail Instance | kube-worker-lk8s-demo-1 | Worker node
Lightsail Instance | kube-worker-lk8s-demo-3 | Worker node
Lightsail Instance | kube-worker-lk8s-demo-4 | Worker node
Lightsail Load Balancer | kube-lb-lk8s-demo-1 | Load Balancer for worker nodes

### Create cluster in specific region

To specify region you can use `-r` option or `LK8S_REGION` environment variable.

```sh
sh lightsail-k8s-installer.sh -i demo -r ap-southeast-1
```

### Specify Availability Zones pool

By default lightsail-k8s-installer will put worker nodes on three availability zones. As an example if you specify `us-east-1` as region and 3 worker nodes, it will spread accross `us-east-1a`, `us-east-1b` and `us-east-1c`.

You can override this by using `-a` options. Let say you want the worker nodes to be placed on `us-east-1a` and `us-east-1f`.

```sh
sh lightsail-k8s-installer.sh -i demo -r us-east-1 -a "us-east-1a us-east-1f"
```

If you have 3 worker nodes 2 will be on `us-east-1a` and 1 in `us-east-1f` and so on.

### Custom CIDR for Pod network

lightsail-k8s-installer utilise [flannel](https://github.com/flannel-io/flannel) for Pod network add-on. The default CIDR for the Pod network is `10.244.0.0/16`. To specify different CIDR use `-c` option.

```sh
sh lightsail-k8s-installer.sh -i demo -c "10.100.0.0/16"
```

### Lightsail instance plan

By default all nodes including the control plane is using **$5** plan. To change this settings specify environment variables `LK8S_CONTROL_PLANE_PLAN=[VALUE]` and `LK8S_WORKER_PLAN=[VALUE]`.

```sh
LK8S_CONTROL_PLANE_PLAN=20_usd \
LK8S_WORKER_PLAN=10_usd \
sh lightsail-k8s-installer.sh -i demo -r ap-southeast-1
```

Valid values: `3_5_usd`, `5_usd`, `10_usd`, `20_usd`, `40_usd`, `80_usd`, `160_usd`.

### Dry run mode

If you want run the script in dry run mode it will print CloudFormation template and then exit. It may useful if you want to inspect what resources that going to be created.

```sh
sh lightsail-k8s-installer.sh -i demo -r ap-southeast-1 -m
```

The dry run mode does not shows what commands that are going to be run on each nodes.

### Environment variables

All configuration for lightsail-k8s-installer are taken from environment variables. Here is a list of environment variables you can change.

Name | Default | Notes
-----|---------|------
LK8S_CLOUDFORMATION_STACKNAME_PREFIX | lk8s | |
LK8S_CONTROL_PLANE_NODE_PREFIX | kube-cp | |
LK8S_WORKER_NODE_PREFIX | kube-worker | |
LK8S_WORKER_LOAD_BALANCER_PREFIX | kube-worker-lb | |
LK8S_POD_NETWORK_CIDR | 10.244.0.0/16 | |
LK8S_NUMBER_OF_WORKER_NODES | 2 | |
LK8S_SSH_PUBLIC_KEY_FILE | $HOME/.ssh/id_rsa.pub | Injected to each node
LK8S_SSH_PRIVATE_KEY_FILE | $HOME/.ssh/id_rsa | |
LK8S_FIREWALL_SSH_ALLOW_CIDR | 0.0.0.0/0 | Allow from everywhere
LK8S_DRY_RUN | no | |
LK8S_CONTROL_PLANE_PLAN | 5_usd | Lightsail instance plan
LK8S_WORKER_PLAN | 5_usd | Lightsail instance plan

## Contributing

Fork this repo and send me a PR. I am happy to review and merge it.

## License

This project is licensed under MIT License.