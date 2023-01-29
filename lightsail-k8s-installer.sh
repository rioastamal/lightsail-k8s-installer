#!/bin/sh
#
# @author Rio Astamal <rio@rioastamal.net>
# @desc Script to automate Kubernetes installation on Amazon Lightsail instances

readonly LK8S_SCRIPT_NAME=$( basename "$0" )
LK8S_BASEDIR=$( cd -P -- "$( dirname "$0" )" && pwd -P )
LK8S_VERSION="1.0"
LC_CTYPE="C"

# Path to directory to store application outputs
[ ! -d "$LK8S_OUTPUT_DIR/.out" ] && LK8S_OUTPUT_DIR="$LK8S_BASEDIR/.out"

# Default config
# --------------
[ -z "$LK8S_CLOUDFORMATION_STACKNAME_PREFIX" ] && LK8S_CLOUDFORMATION_STACKNAME_PREFIX="lk8s"
[ -z "$LK8S_CONTROL_PLANE_NODE_PREFIX" ] && LK8S_CONTROL_PLANE_NODE_PREFIX="kube-cp"
[ -z "$LK8S_WORKER_NODE_PREFIX" ] && LK8S_WORKER_NODE_PREFIX="kube-worker"
[ -z "$LK8S_WORKER_LOAD_BALANCER_PREFIX" ] && LK8S_WORKER_LOAD_BALANCER_PREFIX="kube-worker-lb"
[ -z "$LK8S_POD_NETWORK_CIDR" ] && LK8S_POD_NETWORK_CIDR="10.244.0.0/16"
[ -z "$LK8S_NUMBER_OF_WORKER_NODES" ] && LK8S_NUMBER_OF_WORKER_NODES=2
[ -z "$LK8S_SSH_LIGHTSAIL_KEYPAIR_NAME" ] && LK8S_SSH_LIGHTSAIL_KEYPAIR_NAME="id_rsa"
[ -z "$LK8S_SSH_PRIVATE_KEY_FILE" ] && LK8S_SSH_PRIVATE_KEY_FILE="$HOME/.ssh/id_rsa"
[ -z "$LK8S_FIREWALL_SSH_ALLOW_CIDR" ] && LK8S_FIREWALL_SSH_ALLOW_CIDR="0.0.0.0/0"
[ -z "$LK8S_DRY_RUN" ] && LK8S_DRY_RUN="no"
[ -z "$LK8S_CONTROL_PLANE_PLAN" ] && LK8S_CONTROL_PLANE_PLAN="5_usd"
[ -z "$LK8S_WORKER_PLAN" ] && LK8S_WORKER_PLAN="5_usd"
[ -z "$LK8S_DEBUG" ] && LK8S_DEBUG="true"

# Currently only 1 control plane node supported
# Todo: Support High Availability Control Plane Cluster
LK8S_NUMBER_OF_CP_NODES=1

# Required tools to perform tasks
LK8S_REQUIRED_TOOLS="awk aws cat cut date jq sed ssh tr wc"

# See all available OS/Blueprint ID using: `aws lightsail get-blueprints`
# Only amazon_linux_2 is supported at the moment.
LK8S_CP_OS_ID="amazon_linux_2"
LK8S_WORKER_OS_ID="amazon_linux_2"

# Function to show the help message
lk8s_help()
{
    echo "\
Usage: $0 [OPTIONS]

Where OPTIONS:
  -a AZs        specify list of Available Zones using AZs
  -c CIDR       specify pod network using CIDR
  -d ID         destroy installation id specified by ID
  -h            print this help and exit
  -i ID         specify installation id using ID
  -m            dry run mode, print CloudFormation template and exit
  -r REGION     specify region using REGION
  -v            print script version
  -w NUM        specify number of worker nodes using NUM
  -u            update the cluster by adding new worker nodes

----------------------- lightsail-k8s-installer -----------------------

lightsail-k8s-installer is a command line interface to bootstrap Kubernetes 
cluster on Amazon Lightsail. 

lightsail-k8s-installer is free software licensed under MIT. Visit the project 
homepage at http://github.com/rioastamal/lightsail-k8s-installer."
}

lk8s_write_log()
{
    _LOG_MESSAGE="$@"
    _SYSLOG_DATE_STYLE="$( date +"%b %e %H:%M:%S" )"

    # Date Hostname AppName[PID]: MESSAGE
    printf "[%s LK8S]: %s\n" \
        "$_SYSLOG_DATE_STYLE" \
        "${_LOG_MESSAGE}">> "$LK8S_LOG_FILE"
}

lk8s_log()
{
    [ "$LK8S_DEBUG" = "true" ] && printf "[LK8S]: %s\n" "$@"
    lk8s_write_log "$@"
}

lk8s_log_waiting()
{
    [ "$LK8S_DEBUG" = "true" ] && printf "\r[LK8S]: %s\033[K" "$@"
    lk8s_write_log "$@"
}

lk8s_err() {
    echo "[LK8S ERROR]: $@" >&2
    lk8s_write_log "$@"
}

lk8s_init()
{
  mkdir -p "$LK8S_OUTPUT_DIR"
  
  [ -z "$LK8S_INSTALLATION_ID" ] && {
    echo "Missing installation id. See -h for help." >&2
    return 1
  }

  local _MISSING_TOOL="$( lk8s_missing_tool )"
  [ ! -z "$_MISSING_TOOL" ] && {
    echo "Missing tool: ${_MISSING_TOOL}. Make sure it is installed and available in your PATH." >&2
    return 1
  }

  # See all available regions using CLI: `aws lightsail get-regions`
  [ -z "$LK8S_REGION" ] && {
    [ ! -z "$AWS_REGION" ] && LK8S_REGION=$AWS_REGION
    [ -z "$AWS_REGION" ] && {
      [ ! -z "$AWS_DEFAULT_REGION" ] && LK8S_REGION=$AWS_DEFAULT_REGION
      [ -z "$AWS_DEFAULT_REGION" ] && LK8S_REGION="us-east-1"
    }
  }
  
  export AWS_REGION=$LK8S_REGION
  
  # The AZ list is the same with EC2
  [ -z "$LK8S_AZ_POOL" ] && {
    LK8S_AZ_POOL=""
    
    for az in a b c
    do
      LK8S_AZ_POOL="${LK8S_AZ_POOL}${LK8S_REGION}${az} "
    done
  }
  
  LK8S_CLOUDFORMATION_STACKNAME=$LK8S_CLOUDFORMATION_STACKNAME_PREFIX-$LK8S_INSTALLATION_ID
  LK8S_CONTROL_PLANE_NODE_PREFIX=$LK8S_CONTROL_PLANE_NODE_PREFIX-$LK8S_CLOUDFORMATION_STACKNAME
  LK8S_WORKER_NODE_PREFIX=$LK8S_WORKER_NODE_PREFIX-$LK8S_CLOUDFORMATION_STACKNAME
  LK8S_WORKER_LOAD_BALANCER_PREFIX=$LK8S_WORKER_LOAD_BALANCER_PREFIX-$LK8S_CLOUDFORMATION_STACKNAME
  
  local _LOG_SUFFIX="$( date +"%Y%m%d%H%M%S" )"
  LK8S_LOG_FILE="${LK8S_OUTPUT_DIR}/${LK8S_REGION}-${LK8S_CLOUDFORMATION_STACKNAME}-${_LOG_SUFFIX}.log"
  
  [ ! -r "$LK8S_SSH_PRIVATE_KEY_FILE" ] && {
    echo "Missing SSH private key file, make sure it is exists and readble." >&2
    return 1
  }
  
  [ -z "$LK8S_SSH_PUBLIC_KEY_FILE" ] && {
    LK8S_SSH_PUBLIC_KEY_FILE="${LK8S_SSH_PRIVATE_KEY_FILE}.pub"
  }
  
  [ ! -r "$LK8S_SSH_PUBLIC_KEY_FILE" ] && {
    echo "Missing SSH public key file, make sure it is exists and readble." >&2
    return 1
  }
  
  ([ $LK8S_NUMBER_OF_WORKER_NODES -lt 2 ] && [ "$LK8S_ACTION" = "install" ]) && {
    echo "Number of worker nodes must be >= 2." >&2
    return 1
  }
  
  ([ $LK8S_NUMBER_OF_WORKER_NODES -lt 1 ] && [ "$LK8S_ACTION" = "update" ]) && {
    echo "Number of worker nodes must be >= 1." >&2
    return 1
  }
  
  LK8S_WORKER_NODE_RANDOM_IDS=""
  for i in $( seq 1 $LK8S_NUMBER_OF_WORKER_NODES )
  do
    LK8S_WORKER_NODE_RANDOM_IDS="$( lk8s_gen_random_chars 6 ) ${LK8S_WORKER_NODE_RANDOM_IDS}"
  done
  
  LK8S_CONTROL_PLANE_NODE_RANDOM_IDS=""
  for i in $( seq 1 $LK8S_NUMBER_OF_CP_NODES )
  do
    LK8S_CONTROL_PLANE_NODE_RANDOM_IDS="$( lk8s_gen_random_chars 6 ) ${LK8S_CONTROL_PLANE_NODE_RANDOM_IDS}"
  done

  return 0
}

lk8s_char_repeat()
{
  # $1 -> char
  # $2 -> number of repeat
  for i in $( seq 1 $2 )
  do
    printf "%s" "$1"
  done
}

lk8s_cp_node_user_data()
{
  # Indendation is important here since it will used inside YAML
  cat << 'EOF'
#!/bin/sh

## Disable SELinux
sudo setenforce 0
sudo sed -i 's/^SELINUX=enforcing$/SELINUX=permissive/' /etc/selinux/config

## Add Kubernetes repo
cat <<EOF_KUBE | sudo tee /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=https://packages.cloud.google.com/yum/repos/kubernetes-el7-\$basearch
enabled=1
gpgcheck=1
gpgkey=https://packages.cloud.google.com/yum/doc/rpm-package-key.gpg
exclude=kubelet kubeadm kubectl
EOF_KUBE

## Install Kubernetes Tools and Docker
sudo yum install -y docker kubelet kubeadm kubectl tc jq --disableexcludes=kubernetes
sudo systemctl enable --now docker
sudo systemctl enable --now kubelet

## Modify networking and Swappiness
cat <<EOF_SYS | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
vm.swappiness = 0
EOF_SYS

sudo sysctl --system
EOF
  return 0
}

lk8s_worker_node_user_data()
{
  lk8s_cp_node_user_data
  
  return 0
}

lk8s_ssh_to_node()
{
  local _NODE_IP=$1

  # Remove the $1
  shift
  
  ssh -i $LK8S_SSH_PRIVATE_KEY_FILE -o ConnectTimeout=3 \
    -o StrictHostKeyChecking=no -o LogLevel=error \
    ec2-user@$_NODE_IP $@
}

lk8s_get_az_pool_index()
{
  local _SEQUENCE=$1
  local _NUMBER_OF_AZ=$( echo "$_AZ_POOL" | wc -w )
  local _AZ_POOL_INDEX=$(( $_SEQUENCE % $_NUMBER_OF_AZ ))
  
  [ $_AZ_POOL_INDEX -eq 0 ] && {
    echo $_NUMBER_OF_AZ
    return 0
  }
  
  echo $_AZ_POOL_INDEX
  return 0
}

lk8s_cf_template_nodes()
{
  while [ $# -gt 0 ]; do
    case $1 in
      --node-az-pool) local _NODE_AZ_POOL="$2"; shift ;;
      --node-prefix) local _NODE_PREFIX="$2"; shift ;;
      --number-of-nodes) local _NO_OF_NODES=$2; shift ;;
      --random-ids) local _RANDOM_IDS="$2"; shift ;;
      --node-type) local _NODE_TYPE="$2"; shift ;;
      *) echo "Unrecognised option passed: $1" 2>&2; return 1;;
    esac
    shift
  done

  for i in $( seq 1 $_NO_OF_NODES )
  do
    local _AZ_POOL_INDEX=$( _AZ_POOL=$_NODE_AZ_POOL lk8s_get_az_pool_index $i )
    local _AZ_ID=$( echo "$_NODE_AZ_POOL" | awk "{print \$${_AZ_POOL_INDEX}}" )
    local _RANDOM_ID=$( echo $_RANDOM_IDS | awk "{print \$${i}}" )
    
    [ "$_NODE_TYPE" = "control-plane" ] && _RESOURCE_NAME="ControlPlaneNode${_RANDOM_ID}" 
    [ "$_NODE_TYPE" = "worker" ] && _RESOURCE_NAME="WorkerNode${_RANDOM_ID}" 
    
    lk8s_cf_template_node --az-id "$_AZ_ID" \
      --bundle-id "$LK8S_WORKER_BUNDLE_ID" \
      --cf-stackname "$LK8S_CLOUDFORMATION_STACKNAME" \
      --installation-id "$LK8S_INSTALLATION_ID" \
      --instance-name "$_NODE_PREFIX-$_RANDOM_ID" \
      --node-type "$_NODE_TYPE" \
      --resource-name "$_RESOURCE_NAME" \
      --ssh-allow-cidr "$LK8S_FIREWALL_SSH_ALLOW_CIDR" \
      --os-id "$LK8S_WORKER_OS_ID"
  done
  
  return 0
}

lk8s_cf_template_node()
{
  while [ $# -gt 0 ]; do
    case $1 in
      --az-id) local _AZ_ID="$2"; shift ;;
      --bundle-id) local _BUNDLE_ID="$2"; shift ;;
      --cf-stackname) local _CF_STACKNAME="$2"; shift ;;
      --installation-id) local _INSTALLATION_ID="$2"; shift ;;
      --instance-name) local _INSTANCE_NAME="$2"; shift ;;
      --keypair-name) local _KEYPAIR_NAME="$2"; shift ;;
      --resource-name) local _RESOURCE_NAME="$2"; shift ;;
      --ssh-allow-cidr) local _SSH_ALLOW_CIDR="$2"; shift ;;
      --node-type) local _NODE_TYPE="$2"; shift ;;
      --os-id) local _OS_ID="$2"; shift ;;
      *) echo "Unrecognised option passed: $1" 2>&2; return 1;;
    esac
    shift
  done
  
  [ -z "$_KEYPAIR_NAME" ] && _KEYPAIR_NAME=$LK8S_SSH_LIGHTSAIL_KEYPAIR_NAME
  [ "$_NODE_TYPE" = "worker" ] && {
    local _NETWORKING_RULES="$(cat <<EOF
          Ports:
            - Protocol: tcp
              FromPort: 22
              ToPort: 22
              Cidrs:
                - $_SSH_ALLOW_CIDR
            - FromPort: 80
              ToPort: 80
              Protocol: tcp
              Cidrs:
                - 172.26.0.0/16
            - FromPort: 30000
              ToPort: 32767
              Protocol: tcp
              Cidrs:
                - 172.26.0.0/16
            - FromPort: 10250
              ToPort: 10250
              Protocol: tcp
              Cidrs:
                - 172.26.0.0/16
EOF
)"
  }
  
  [ "$_NODE_TYPE" = "control-plane" ] && {
    local _NETWORKING_RULES="$( cat <<EOF
          Ports:
            - Protocol: tcp
              FromPort: 22
              ToPort: 22
              Cidrs:
                - $_SSH_ALLOW_CIDR
            - FromPort: 6443
              ToPort: 6443
              Protocol: tcp
              Cidrs:
                - 172.26.0.0/16
            - FromPort: 2379
              ToPort: 2380
              Protocol: tcp
              Cidrs:
                - 172.26.0.0/16
            - FromPort: 10250
              ToPort: 10250
              Protocol: tcp
              Cidrs:
                - 172.26.0.0/16
            - FromPort: 10257
              ToPort: 10257
              Protocol: tcp
              Cidrs:
                - 172.26.0.0/16
            - FromPort: 10259
              ToPort: 10259
              Protocol: tcp
              Cidrs:
                - 172.26.0.0/16
EOF
)"
  }

  cat <<EOF
  $_RESOURCE_NAME:
    Type: AWS::Lightsail::Instance
    Properties:
      AvailabilityZone: $_AZ_ID
      BlueprintId: $_OS_ID
      BundleId: $_BUNDLE_ID
      KeyPairName: $_KEYPAIR_NAME
      InstanceName: $_INSTANCE_NAME
      Networking:
$_NETWORKING_RULES
      Tags:
        - Key: cf-$_CF_STACKNAME
        - Key: lightsail-k8s-installer
        - Key: type-$_NODE_TYPE-$_INSTALLATION_ID
        - Key: installation-id-$_INSTALLATION_ID
        - Key: installer
          Value: lightsail-k8s-installer
        - Key: cfstackname
          Value: $_CF_STACKNAME
        - Key: node-type
          Value: $_NODE_TYPE
EOF
  
  return 0
}

lk8s_cf_template_load_balancer_worker_nodes()
{
  local _WORKER_INSTANCE_LIST=""
  
  cat <<EOF
  LoadBalancerWorker:
    Type: AWS::Lightsail::LoadBalancer
    Properties:
      LoadBalancerName: $LK8S_WORKER_LOAD_BALANCER_PREFIX
      IpAddressType: ipv4
      InstancePort: 80
      SessionStickinessEnabled: false
EOF

  return 0
}

lk8s_cf_template_header()
{
  echo "AWSTemplateFormatVersion: '2010-09-09'"
  echo "Resources:"
  
  return 0
}

lk8s_run_cloudformation()
{
  # See all available Bundle ID using CLI: `aws lightsail get-bundles`
  LK8S_CP_BUNDLE_ID="$( lk8s_is_package_valid $LK8S_CONTROL_PLANE_PLAN )" || {
    lk8s_err "Control plane plan '$LK8S_CONTROL_PLANE_PLAN' is not valid"
    return 1
  }
  
  LK8S_WORKER_BUNDLE_ID="$( lk8s_is_package_valid $LK8S_WORKER_PLAN )" || {
    lk8s_err "Worker plan '$LK8S_WORKER_PLAN' is not valid"
    return 1
  }
  
  [ "$LK8S_DRY_RUN" = "yes" ] && {
    lk8s_is_region_and_az_valid && \
    lk8s_cf_template_header && \
    lk8s_cf_template_nodes \
      --node-az-pool "$LK8S_AZ_POOL" \
      --number-of-nodes "$LK8S_NUMBER_OF_CP_NODES" \
      --random-ids "$LK8S_CONTROL_PLANE_NODE_RANDOM_IDS" \
      --node-prefix "$LK8S_CONTROL_PLANE_NODE_PREFIX" \
      --node-type "control-plane" && \
    lk8s_cf_template_nodes \
      --node-az-pool "$LK8S_AZ_POOL" \
      --number-of-nodes "$LK8S_NUMBER_OF_WORKER_NODES" \
      --random-ids "$LK8S_WORKER_NODE_RANDOM_IDS" \
      --node-prefix "$LK8S_WORKER_NODE_PREFIX" \
      --node-type "worker" && \
    lk8s_cf_template_load_balancer_worker_nodes
    return 1
  }

  local _ANSWER="no"
  local _TITLE="lightsail-k8s-installer v${LK8S_VERSION}"
  local _ANY_KEY=""
  
  local _MONTHLY_COST=$( lk8s_get_monthly_estimated_cost )
  local _HOURLY_COST=$( echo "$_MONTHLY_COST 30 24" | awk '{printf "%.2f", $1 / $2 / $3}' )
  local _CP_PRICE=$( lk8s_get_control_plane_plan_price )
  local _WORKER_PRICE=$( lk8s_get_worker_plan_price )
  
  lk8s_char_repeat "-" $( echo $_TITLE | wc -c ) && echo
  echo $_TITLE
  lk8s_char_repeat "-" $( echo $_TITLE | wc -c ) && echo
  cat <<EOF
This process will create Kubernetes cluster on Amazon Lightsail.

CloudFormation stack: $LK8S_CLOUDFORMATION_STACKNAME
              Region: $LK8S_REGION
     AZs worker pool: $LK8S_AZ_POOL
           Resources: - $LK8S_NUMBER_OF_CP_NODES control plane node (plan: \$${_CP_PRICE})
                      - $LK8S_NUMBER_OF_WORKER_NODES worker nodes (plan: \$${_WORKER_PRICE})
                      - 1 load balancer (plan: \$18)
      Estimated cost: \$${_MONTHLY_COST}/month or \$${_HOURLY_COST}/hour
EOF
  
  echo
  read -p "Press any key to continue: " _ANY_KEY
  echo "This may take several minutes, please wait..."
  echo "To view detailed log, run following command on another terminal:"
  echo "  tail -f $LK8S_LOG_FILE"
  echo
  
  lk8s_log "Checking region validity"
  lk8s_is_region_and_az_valid || return 1
  
  lk8s_log "Checking SSH key pair '$LK8S_SSH_LIGHTSAIL_KEYPAIR_NAME' in region '$LK8S_REGION'"
  lk8s_is_ssh_keypair_valid || return 1

  lk8s_log "Checking existing stack '${LK8S_CLOUDFORMATION_STACKNAME}'"
  # Do not create when the stack already exists
  aws cloudformation describe-stacks --stack-name=$LK8S_CLOUDFORMATION_STACKNAME >>$LK8S_LOG_FILE 2>&1 && {
    lk8s_err "Stack already exists. Aborted!"
    return 1
  }
  
  lk8s_log "Stack '${LK8S_CLOUDFORMATION_STACKNAME}' is not exists, good!"
  
  # Validating template
  ( lk8s_cf_template_header && \
    lk8s_cf_template_nodes \
      --node-az-pool "$LK8S_AZ_POOL" \
      --number-of-nodes "$LK8S_NUMBER_OF_CP_NODES" \
      --random-ids "$LK8S_CONTROL_PLANE_NODE_RANDOM_IDS" \
      --node-prefix "$LK8S_CONTROL_PLANE_NODE_PREFIX" \
      --node-type "control-plane" && \
    lk8s_cf_template_nodes \
      --node-az-pool "$LK8S_AZ_POOL" \
      --number-of-nodes "$LK8S_NUMBER_OF_WORKER_NODES" \
      --random-ids "$LK8S_WORKER_NODE_RANDOM_IDS" \
      --node-prefix "$LK8S_WORKER_NODE_PREFIX" \
      --node-type "worker" && \
    lk8s_cf_template_load_balancer_worker_nodes ) | \
    aws cloudformation validate-template --template-body file:///dev/stdin >> $LK8S_LOG_FILE 2>&1 || {
      lk8s_err "CloudFormation generated template is not valid. Aborted!"
      return 1
    }

  ( lk8s_cf_template_header && \
    lk8s_cf_template_nodes \
      --node-az-pool "$LK8S_AZ_POOL" \
      --number-of-nodes "$LK8S_NUMBER_OF_CP_NODES" \
      --random-ids "$LK8S_CONTROL_PLANE_NODE_RANDOM_IDS" \
      --node-prefix "$LK8S_CONTROL_PLANE_NODE_PREFIX" \
      --node-type "control-plane" && \
    lk8s_cf_template_nodes \
      --node-az-pool "$LK8S_AZ_POOL" \
      --number-of-nodes "$LK8S_NUMBER_OF_WORKER_NODES" \
      --random-ids "$LK8S_WORKER_NODE_RANDOM_IDS" \
      --node-prefix "$LK8S_WORKER_NODE_PREFIX" \
      --node-type "worker" && \
  lk8s_cf_template_load_balancer_worker_nodes ) | \
  aws cloudformation create-stack \
    --stack-name="$LK8S_CLOUDFORMATION_STACKNAME" \
    --template-body file:///dev/stdin >> $LK8S_LOG_FILE 2>&1

  local STACK_STATUS=""
  local _WAIT_COUNTER=1
  
  while [ "$STACK_STATUS" != "CREATE_COMPLETE" ]
  do
    lk8s_log_waiting "Waiting stack '$LK8S_CLOUDFORMATION_STACKNAME' to be ready$( lk8s_char_repeat '.' $_WAIT_COUNTER )"
    STACK_STATUS="$( aws cloudformation describe-stacks \
                    --stack-name="$LK8S_CLOUDFORMATION_STACKNAME" 2>>$LK8S_LOG_FILE | \
                    jq -r '.Stacks[0].StackStatus' )"

    [ $_WAIT_COUNTER -ge 3 ] && _WAIT_COUNTER=0
    _WAIT_COUNTER=$(( $_WAIT_COUNTER + 1 ))
    sleep 2
  done
  
  echo
  lk8s_log "Stack '$LK8S_CLOUDFORMATION_STACKNAME' is ready"
  
  local _CP_NODE_NAME="$LK8S_CONTROL_PLANE_NODE_PREFIX-"$( echo "$LK8S_CONTROL_PLANE_NODE_RANDOM_IDS" | awk '{print $1}' )
  lk8s_run_post_command_control_plance_nodes && \
  lk8s_run_post_command_worker_node --cp-node-name "$_CP_NODE_NAME" && \
  lk8s_deploy_sample_app && \
  lk8s_attach_load_balancer_to_worker_node && \
  lk8s_print_installation_info
  
  return 0
}

lk8s_update_cloudformation()
{
  # See all available Bundle ID using CLI: `aws lightsail get-bundles`
  LK8S_CP_BUNDLE_ID="$( lk8s_is_package_valid $LK8S_CONTROL_PLANE_PLAN )" || {
    lk8s_err "Control plane plan '$LK8S_CONTROL_PLANE_PLAN' is not valid"
    return 1
  }
  
  LK8S_WORKER_BUNDLE_ID="$( lk8s_is_package_valid $LK8S_WORKER_PLAN )" || {
    lk8s_err "Worker plan '$LK8S_WORKER_PLAN' is not valid"
    return 1
  }

  lk8s_log_waiting "Checking region validity" >&2
  lk8s_is_region_and_az_valid || return 1

  lk8s_log_waiting "Checking existing stack '$LK8S_CLOUDFORMATION_STACKNAME'" >&2
  aws cloudformation describe-stacks --stack-name=$LK8S_CLOUDFORMATION_STACKNAME >>$LK8S_LOG_FILE 2>&1 || {
    lk8s_err "Stack not exists. Aborted!"
    return 1
  }

  local _ANSWER="no"
  local _TITLE="lightsail-k8s-installer v${LK8S_VERSION}"
  local _ANY_KEY=""
  local _WORKER_PRICE=$( lk8s_get_worker_plan_price )
  
  local _CURRENT_CF_TEMPLATE=$( aws cloudformation get-template \
    --stack-name "$LK8S_CLOUDFORMATION_STACKNAME" --output text | head -n -3)

  local _WORKER_TEMPLATE=$(
lk8s_cf_template_nodes \
      --node-az-pool "$LK8S_AZ_POOL" \
      --number-of-nodes "$LK8S_NUMBER_OF_WORKER_NODES" \
      --random-ids "$LK8S_WORKER_NODE_RANDOM_IDS" \
      --node-prefix "$LK8S_WORKER_NODE_PREFIX" \
      --node-type "worker"
)
  local _NEW_CF_TEMPLATE="$_CURRENT_CF_TEMPLATE
$_WORKER_TEMPLATE
"
  
  [ "$LK8S_DRY_RUN" = "yes" ] && {
    echo "$_NEW_CF_TEMPLATE"
    return 0
  }
  
  echo -en "\r\033[2K" >&2
  
  lk8s_char_repeat "-" $( echo $_TITLE | wc -c ) && echo
  echo $_TITLE
  lk8s_char_repeat "-" $( echo $_TITLE | wc -c ) && echo
  cat <<EOF
This process will update your Kubernetes cluster on Amazon Lightsail.

CloudFormation stack: $LK8S_CLOUDFORMATION_STACKNAME
              Region: $LK8S_REGION
     AZs worker pool: $LK8S_AZ_POOL
       New resources: $LK8S_NUMBER_OF_WORKER_NODES worker node(s) (plan: \$${_WORKER_PRICE})
EOF

  echo
  read -p "Press any key to continue: " _ANY_KEY
  echo "This may take several minutes, please wait..."
  echo "To view detailed log, run following command on another terminal:"
  echo "  tail -f $LK8S_LOG_FILE"
  echo
  
  lk8s_log "Checking SSH key pair '$LK8S_SSH_LIGHTSAIL_KEYPAIR_NAME' in region '$LK8S_REGION'"
  lk8s_is_ssh_keypair_valid || return 1
  
  # Apply change set
  local _NOW="$( date +"%Y%m%d%H%M%S" )"
  local _CHANGE_SET_NAME=$LK8S_WORKER_NODE_PREFIX-$_NOW
  lk8s_log "Creating CloudFormation change set '$_CHANGE_SET_NAME' for new worker node(s)"
  echo "$_NEW_CF_TEMPLATE" | aws cloudformation create-change-set \
    --stack-name $LK8S_CLOUDFORMATION_STACKNAME \
    --change-set-name $_CHANGE_SET_NAME \
    --template-body file:///dev/stdin >>$LK8S_LOG_FILE 2>&1 || {
      lk8s_err "Failed to creating change set '$_CHANGE_SET_NAME'"
      return 1
    }
    
  local _CHANGE_SET_STATUS=""
  local _WAIT_COUNTER=1
  
  while [ "$_CHANGE_SET_STATUS" != "CREATE_COMPLETE" ]
  do
    lk8s_log_waiting "Waiting change set '$_CHANGE_SET_NAME' to be ready$( lk8s_char_repeat '.' $_WAIT_COUNTER )"
    _CHANGE_SET_STATUS="$( aws cloudformation describe-change-set \
                    --stack-name "$LK8S_CLOUDFORMATION_STACKNAME" \
                    --change-set-name "$_CHANGE_SET_NAME" 2>>$LK8S_LOG_FILE | \
                    jq -r '.Status' )"

    [ $_WAIT_COUNTER -ge 3 ] && _WAIT_COUNTER=0
    _WAIT_COUNTER=$(( $_WAIT_COUNTER + 1 ))
    
    sleep 1
  done

  echo

  aws cloudformation execute-change-set \
    --stack-name "$LK8S_CLOUDFORMATION_STACKNAME" \
    --change-set-name "$_CHANGE_SET_NAME" >>$LK8S_LOG_FILE >&1 || {
      lk8s_err "Failed to execute change set '$_CHANGE_SET_NAME'"
      return 1
    }
  
  local STACK_STATUS=""
  local _WAIT_COUNTER=1
  
  while [ "$STACK_STATUS" != "UPDATE_COMPLETE" ]
  do
    lk8s_log_waiting "Updating stack '$LK8S_CLOUDFORMATION_STACKNAME'$( lk8s_char_repeat '.' $_WAIT_COUNTER )"
    STACK_STATUS="$( aws cloudformation describe-stacks \
                    --stack-name="$LK8S_CLOUDFORMATION_STACKNAME" 2>>$LK8S_LOG_FILE | \
                    jq -r '.Stacks[0].StackStatus' )"

    [ $_WAIT_COUNTER -ge 3 ] && _WAIT_COUNTER=0
    _WAIT_COUNTER=$(( $_WAIT_COUNTER + 1 ))
    
    sleep 2
  done
  
  local _GET_INSTANCES_OUTPUT="$( aws lightsail get-instances --no-paginate 2>>$LK8S_LOG_FILE )"
  local _CP_NODE_NAME=$( 
    echo "$_GET_INSTANCES_OUTPUT" | \
    jq -r ".instances | map(select(any(.tags[]; .key==\"type-control-plane-$LK8S_INSTALLATION_ID\"))) | .[0].name"
  )
  lk8s_run_post_command_worker_node --cp-node-name "$_CP_NODE_NAME" && \
  lk8s_attach_load_balancer_to_worker_node && {
    local _CP_NODE_IP=$( 
      echo "$_GET_INSTANCES_OUTPUT" | \
      jq -r ".instances | map(select(any(.tags[]; .key==\"type-control-plane-$LK8S_INSTALLATION_ID\"))) | .[0].publicIpAddress"
    )
    
    lk8s_wait_for_kubelet_worker_to_be_ready "$_CP_NODE_IP"
    lk8s_log "Kubernetes nodes info:"
    lk8s_ssh_to_node $_CP_NODE_IP kubectl get nodes
    echo
    lk8s_log "update COMPLETED."
  }
  
  return 0
}

lk8s_run_post_command_control_plance_nodes()
{
  for i in $( seq 1 $LK8S_NUMBER_OF_CP_NODES )
  do
    local _NODE_NAME="$LK8S_CONTROL_PLANE_NODE_PREFIX"-$( echo $LK8S_CONTROL_PLANE_NODE_RANDOM_IDS | awk "{print \$${i}}" )
    lk8s_wait_for_node_to_be_ready $_NODE_NAME
    
    local _NODE_IP="$( aws lightsail get-instance --instance-name=$_NODE_NAME 2>>$LK8S_LOG_FILE \
      | jq -r .instance.publicIpAddress )"
    
    lk8s_log "Running init scripts on control plane node '${_NODE_NAME}'"
    local _INIT_SCRIPTS="$( lk8s_cp_node_user_data )"
    echo "$_INIT_SCRIPTS" >> $LK8S_LOG_FILE
    echo "$_INIT_SCRIPTS" | lk8s_ssh_to_node $_NODE_IP sudo -u ec2-user bash >> $LK8S_LOG_FILE 2>&1

    lk8s_log "Installing Kubernetes control plane on node '${_NODE_NAME}'"
    local _KUBERNETES_INSTALL_CMD="$( cat <<EOF
[ "\$( hostname )" != "$_NODE_NAME" ] && {
  sudo hostnamectl set-hostname $_NODE_NAME
}

[ ! -f /etc/kubernetes/admin.conf ] && {
  sudo kubeadm init --pod-network-cidr=$LK8S_POD_NETWORK_CIDR \
    --ignore-preflight-errors=NumCPU,Mem  
}
  
[ ! -d /home/ec2-user/.kube ] && (
  mkdir -p $HOME/.kube
  sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
  sudo chown $(id -u):$(id -g) $HOME/.kube/config
)

CP_NODE_STATUS="\$( kubectl get nodes --no-headers | awk '{print \$2}' )"

[ "\$CP_NODE_STATUS" = "NotReady" ] && {
  curl -s -L https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml | \
  sed 's#10.244.0.0/16#$LK8S_POD_NETWORK_CIDR#' | kubectl apply -f -
}
EOF
)"
    echo "$_KUBERNETES_INSTALL_CMD" >> $LK8S_LOG_FILE
    echo "$_KUBERNETES_INSTALL_CMD" | lk8s_ssh_to_node $_NODE_IP sudo -u ec2-user bash >> $LK8S_LOG_FILE 2>&1
  done
  
  return 0
}

lk8s_run_post_command_worker_node()
{
  while [ $# -gt 0 ]; do
    case $1 in
      --cp-node-name) local _CP_NODE_NAME="$2"; shift ;;
      *) echo "Unrecognised option passed: $1" 2>&2; return 1;;
    esac
    shift
  done
  
  for i in $( seq 1 $LK8S_NUMBER_OF_WORKER_NODES )
  do
    local _NODE_NAME="$LK8S_WORKER_NODE_PREFIX"-"$( echo $LK8S_WORKER_NODE_RANDOM_IDS | awk "{print \$${i}}" )"
    lk8s_wait_for_node_to_be_ready $_NODE_NAME
    
    local _NODE_IP="$( aws lightsail get-instance --instance-name=$_NODE_NAME | jq -r .instance.publicIpAddress )"
    
    lk8s_log "Running init scripts on worker node '${_NODE_NAME}'"
    local _INIT_SCRIPTS="$( lk8s_worker_node_user_data )"
    echo "$_INIT_SCRIPTS" >> $LK8S_LOG_FILE
    echo "$_INIT_SCRIPTS" | lk8s_ssh_to_node $_NODE_IP sudo -u ec2-user bash >> $LK8S_LOG_FILE 2>&1
    
    local _JOIN_CMD="$( lk8s_gen_join_command --cp-node-name "$_CP_NODE_NAME" )"
    local _KUBERNETES_WORKER_CMD="$(cat <<EOF
[ "\$( hostname )" != "$_NODE_NAME" ] && {
  sudo hostnamectl set-hostname $_NODE_NAME
}

sudo $_JOIN_CMD
EOF
)"
    lk8s_log "Joining worker node '$_NODE_NAME' to control plane"
    echo "$_KUBERNETES_WORKER_CMD" >> $LK8S_LOG_FILE
    echo "$_KUBERNETES_WORKER_CMD" | lk8s_ssh_to_node $_NODE_IP sudo -u ec2-user bash >> $LK8S_LOG_FILE 2>&1
  done

  return 0
}

lk8s_attach_load_balancer_to_worker_node()
{
  local _INSTANCE_NAMES=""
  for i in $( seq $LK8S_NUMBER_OF_WORKER_NODES )
  do
    local _NAME="$LK8S_WORKER_NODE_PREFIX"-$( echo $LK8S_WORKER_NODE_RANDOM_IDS | awk "{print \$${i}}" )
    _INSTANCE_NAMES="$_INSTANCE_NAMES $_NAME"
  done

  lk8s_log "Attaching worker nodes to Lightsail Load Balancer"
  aws lightsail attach-instances-to-load-balancer \
    --load-balancer-name $LK8S_WORKER_LOAD_BALANCER_PREFIX \
    --instance-names $_INSTANCE_NAMES >> $LK8S_LOG_FILE 2>&1
    
  return 0
}

lk8s_print_installation_info()
{
  local _NODE_NAME="$LK8S_CONTROL_PLANE_NODE_PREFIX"-$( echo $LK8S_CONTROL_PLANE_NODE_RANDOM_IDS | awk '{print $1}' )
  local _CONTROL_PLANE_IP=$( aws lightsail get-instance --instance-name=$_NODE_NAME | jq -r .instance.publicIpAddress )
  local _LB_URL=$( aws lightsail get-load-balancer --load-balancer-name $LK8S_WORKER_LOAD_BALANCER_PREFIX | jq -r '.loadBalancer.dnsName' )
  local _KUBERNETES_INFO="$( lk8s_ssh_to_node $_CONTROL_PLANE_IP kubectl get nodes,services,deployments,pods )"
  local _BACKSLASH=$( printf '%b' '\134' ) # backslash
  local _INFO="$( cat <<EOF
Your Kubernetes installation info:
$_KUBERNETES_INFO

Accessing Control Plane via SSH:
  ssh ec2-user@$_CONTROL_PLANE_IP
  
Your app are available via load balancer:
  http://$_LB_URL

You can view detailed installation log at:
  $LK8S_LOG_FILE
  
To delete sample app run following on Control plane:
  kubectl get services,deployments --no-headers -o name $_BACKSLASH
    -l cfstackname=$LK8S_CLOUDFORMATION_STACKNAME | xargs kubectl delete

EOF
)"
  lk8s_log "$_INFO"
  echo
  lk8s_log "Installation COMPLETED."
  
  return 0
}

lk8s_gen_join_command()
{
  while [ $# -gt 0 ]; do
    case $1 in
      --cp-node-name) local _NODE_NAME="$2"; shift ;;
      *) echo "Unrecognised option passed: $1" 2>&2; return 1;;
    esac
    shift
  done
  
  local _NODE_IP="$( aws lightsail get-instance --instance-name=$_NODE_NAME | jq -r .instance.publicIpAddress )"
  lk8s_ssh_to_node $_NODE_IP kubeadm token create --print-join-command
  
  return 0
}

lk8s_gen_sample_configuration_deployment()
{
  local _NUMBER_OF_REPLICAS=$(( $LK8S_NUMBER_OF_WORKER_NODES * 2 ))
  local _YAML_DEPLOYMENT="$( cat <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: http-echo-deployment
  labels:
    app: http-echo
    cfstackname: $LK8S_CLOUDFORMATION_STACKNAME
spec:
  replicas: $_NUMBER_OF_REPLICAS
  selector:
    matchLabels:
      app: http-echo
  template:
    metadata:
      labels:
        app: http-echo
        action: auto-label-node
        cfstackname: $LK8S_CLOUDFORMATION_STACKNAME
    spec:
      containers:
      - name: http-echo
        image: hashicorp/http-echo
        args: 
          - |-
            -text=Node: \$(MY_NODE_NAME)
              IP: \$(MY_HOST_IP)
            --
             Pod: \$(MY_POD_NAME)
              IP: \$(MY_POD_IP)
          - "-listen=:80"
        ports:
          - containerPort: 80
        env:
          - name: MY_NODE_NAME
            valueFrom:
              fieldRef:
                fieldPath: spec.nodeName
          - name: MY_HOST_IP
            valueFrom:
              fieldRef:
                fieldPath: status.hostIP
          - name: MY_POD_NAME
            valueFrom:
              fieldRef:
                fieldPath: metadata.name
          - name: MY_POD_IP
            valueFrom:
              fieldRef:
                fieldPath: status.podIP
EOF
)"

  local _YAML_SERVICES=""
  
  for i in $( seq 1 $LK8S_NUMBER_OF_WORKER_NODES )
  do
    local _NODE_NAME="$LK8S_WORKER_NODE_PREFIX"-$( echo $LK8S_WORKER_NODE_RANDOM_IDS | awk "{print \$${i}}" )
    local _NODE_PRIVATE_IP="$( aws lightsail get-instance --instance-name=$_NODE_NAME | jq -r .instance.privateIpAddress )"
    local _TMP="$( cat <<EOF

---
apiVersion: v1
kind: Service
metadata:
  name: http-echo-svc-$_NODE_NAME
  labels:
    app: http-echo
    cfstackname: $LK8S_CLOUDFORMATION_STACKNAME
spec:
  selector:
    app: http-echo
    node: $_NODE_NAME
  ports:
    - protocol: TCP
      port: 80
      targetPort: 80
  type: ClusterIP
  externalIPs:
    - $_NODE_PRIVATE_IP
EOF
)"
    _YAML_SERVICES="${_YAML_SERVICES}
${_TMP}"
  done
  
  printf "%s\n" "$_YAML_DEPLOYMENT"
  printf "%s\n" "$_YAML_SERVICES"
  
  printf "Kubernetes YAML deployment\n%s\n\%s" "$_YAML_DEPLOYMENT" "$_YAML_SERVICES" >> $LK8S_LOG_FILE
  
  return 0
}

lk8s_gen_cloudformation_new_worker_node()
{
  lk8s_cf_template_header && \
  lk8s_cf_template_control_plane_nodes && \
  lk8s_cf_template_worker_nodes
}

lk8s_gen_random_chars()
{
  local _LENGTH=$1
  tr -dc 'a-z0-9' </dev/urandom | head -c $_LENGTH; echo
  
  return 0
}

lk8s_add_node_labels_to_sample_pods()
{
  local _NODE_IP=$1

  # Wait pods to be ready and running
  cat <<'EOF' | lk8s_ssh_to_node $_NODE_IP bash
kubectl get pods --show-kind \
  -l 'action=auto-label-node' -l '!node' --no-headers -o wide \
  --field-selector=status.phase=Running | \
  awk '{print "kubectl label",$1,"node="$7}' | sh
EOF

  return 0
}

lk8s_deploy_sample_app()
{
  local _NODE_NAME="$LK8S_CONTROL_PLANE_NODE_PREFIX"-$( echo $LK8S_CONTROL_PLANE_NODE_RANDOM_IDS | awk '{print $1}' )
  local _NODE_IP="$( aws lightsail get-instance --instance-name=$_NODE_NAME | jq -r .instance.publicIpAddress )"
  
  lk8s_log "Deploying sample http-echo app"
  lk8s_wait_for_kubelet_worker_to_be_ready $_NODE_IP && (
    lk8s_gen_sample_configuration_deployment | \
    lk8s_ssh_to_node $_NODE_IP kubectl apply -f - >> $LK8S_LOG_FILE)
  lk8s_wait_for_sample_pods_to_be_ready $_NODE_IP && (
    lk8s_add_node_labels_to_sample_pods $_NODE_IP >> $LK8S_LOG_FILE) && \
  lk8s_log "Sample app has been deployed."
  
  return 0
}

lk8s_wait_for_sample_pods_to_be_ready()
{
  local _CONTROL_PLANE_IP=$1
  local _NUMBER_OF_PODS_READY=0
  local _NUMBER_OF_REPLICAS=$(( $LK8S_NUMBER_OF_WORKER_NODES * 2 ))
  local _WAIT_COUNTER=1
  
  lk8s_log_waiting "Waiting sample pods ($_NUMBER_OF_PODS_READY/${_NUMBER_OF_REPLICAS}) to be ready$( lk8s_char_repeat '.' $_WAIT_COUNTER )"
  
  while [ $_NUMBER_OF_PODS_READY -lt $_NUMBER_OF_REPLICAS ]
  do
    _NUMBER_OF_PODS_READY="$( cat <<EOF | lk8s_ssh_to_node $_CONTROL_PLANE_IP 2>> $LK8S_LOG_FILE
kubectl get pods --show-kind \
  -l 'action=auto-label-node' -l '!node' --no-headers -o wide \
  --field-selector=status.phase=Running 2>/dev/null | grep -v 'Terminating' | wc -l
EOF
)"

    lk8s_log_waiting "Waiting sample pods ($_NUMBER_OF_PODS_READY/${_NUMBER_OF_REPLICAS}) to be ready$( lk8s_char_repeat '.' $_WAIT_COUNTER )"
    
    [ $_WAIT_COUNTER -ge 3 ] && _WAIT_COUNTER=0
    _WAIT_COUNTER=$(( $_WAIT_COUNTER + 1 ))
    
    sleep 1
  done

  echo
  lk8s_log "All sample pods is ready"
  
  return 0
}

lk8s_wait_for_kubelet_worker_to_be_ready()
{
  local _CONTROL_PLANE_IP=$1
  local _NUMBER_OF_KUBELET_WORKER_READY=0
  local _WAIT_COUNTER=1
  local _NUMBER_OF_WORKER_NODES="$( cat <<EOF | lk8s_ssh_to_node $_CONTROL_PLANE_IP 
kubectl get nodes --selector='!node-role.kubernetes.io/control-plane' --no-headers | \
grep $LK8S_CLOUDFORMATION_STACKNAME | wc -l
EOF
)"
  
  lk8s_log_waiting "Waiting kubelet on worker ($_NUMBER_OF_KUBELET_WORKER_READY/${_NUMBER_OF_WORKER_NODES}) to be ready$( lk8s_char_repeat '.' $_WAIT_COUNTER )"
  
  while [ $_NUMBER_OF_KUBELET_WORKER_READY -lt $_NUMBER_OF_WORKER_NODES ]
  do
      _NUMBER_OF_KUBELET_WORKER_READY=$( cat <<EOF | lk8s_ssh_to_node $_CONTROL_PLANE_IP 2>>$LK8S_LOG_FILE
kubectl get nodes --selector='!node-role.kubernetes.io/control-plane' --no-headers | \
grep '$LK8S_CLOUDFORMATION_STACKNAME' | grep -v 'NotReady' | wc -l
EOF
)
    lk8s_log_waiting "Waiting kubelet on worker ($_NUMBER_OF_KUBELET_WORKER_READY/${_NUMBER_OF_WORKER_NODES}) to be ready$( lk8s_char_repeat '.' $_WAIT_COUNTER )"
    
    [ $_WAIT_COUNTER -ge 3 ] && _WAIT_COUNTER=0
    _WAIT_COUNTER=$(( $_WAIT_COUNTER + 1 ))
    
    sleep 1
  done

  echo
  lk8s_log "All kubelet on worker nodes is ready"
  return 0
}

lk8s_wait_for_node_to_be_ready()
{
  local _NODE_NAME=$1
  local _NODE_IP=""
  local _NODE_STATUS=""
  
  local _WAIT_COUNTER=1
  while [ "$_NODE_STATUS" != "ec2-user" ]
  do
    # There is possibility public IP is changed when instance is stopped, so we
    # get the IP inside the loop
    _NODE_IP="$( aws lightsail get-instance --instance-name=$_NODE_NAME | jq -r .instance.publicIpAddress )"
    _NODE_STATUS="$( lk8s_ssh_to_node $_NODE_IP whoami 2>>$LK8S_LOG_FILE | tr -d '[:space:]' )"
    lk8s_log_waiting "Waiting SSH connection to '$_NODE_NAME' to be ready$( lk8s_char_repeat '.' $_WAIT_COUNTER )"
    
    [ $_WAIT_COUNTER -ge 3 ] && _WAIT_COUNTER=0
    _WAIT_COUNTER=$(( $_WAIT_COUNTER + 1 ))
    
    sleep 1
  done

  echo
  lk8s_log "Node '$_NODE_NAME' is ready"
  
  return 0
}

lk8s_destroy_installation()
{
  local _CMD_TO_RUN="aws cloudformation delete-stack --stack-name=$LK8S_CLOUDFORMATION_STACKNAME"
  
  [ "$LK8S_DRY_RUN" = "yes" ] && {
    echo "[DRY RUN] $_CMD_TO_RUN"
    return 0
  }
  
  local _ANSWER="no"
  
  echo "This action will destroy CloudFormation stack '$LK8S_CLOUDFORMATION_STACKNAME' ($LK8S_REGION)."
  read -p "Type 'yes' to continue: " _ANSWER
  
  [ "$_ANSWER" != "yes" ] && {
    echo "Aborted."
    return 0
  }
  
  lk8s_is_region_valid $LK8S_REGION || {
    echo "[ERROR]: Region is not valid." >&2
    return 1
  }
  
  echo
  lk8s_log "Checking CloudFormation stack '$LK8S_CLOUDFORMATION_STACKNAME'"
  aws cloudformation describe-stacks --stack-name $LK8S_CLOUDFORMATION_STACKNAME \
    2>>$LK8S_LOG_FILE >/dev/null || {
    lk8s_log "Stack not found, aborted."
    return 1
  }
  
  $_CMD_TO_RUN >> $LK8S_LOG_FILE 2>&1
  local _WAIT_COUNTER=1
  
  while :
  do
    lk8s_log_waiting "Destroying CloudFormation stack '$LK8S_CLOUDFORMATION_STACKNAME'$( lk8s_char_repeat '.' $_WAIT_COUNTER )"
    aws cloudformation describe-stacks \
      --stack-name="$LK8S_CLOUDFORMATION_STACKNAME" 2>>$LK8S_LOG_FILE >>$LK8S_LOG_FILE || break
    sleep 2
    
    [ $_WAIT_COUNTER -ge 3 ] && _WAIT_COUNTER=0
    _WAIT_COUNTER=$(( $_WAIT_COUNTER + 1 ))
  done
  
  echo
  lk8s_log "Installation '$LK8S_INSTALLATION_ID' has been destroyed."
  
  return 0
}

lk8s_get_lightsail_regions()
{
  local _REGIONS="$( aws lightsail get-regions | jq -r '.regions[].name' )"
  
  echo "$_REGIONS"
  
  return 0
}

lk8s_is_region_valid()
{
  local _REGION_NAME=$1
  local _REGIONS="$( lk8s_get_lightsail_regions 2>/dev/null )"
  local _VALID="false"
  
  for region in $_REGIONS
  do
    [ "$region" = "$_REGION_NAME" ] && {
      _VALID="true"
      break
    }
  done
  
  [ "$_VALID" = "false" ] && return 1
  
  return 0
}

lk8s_get_region_az()
{
  local _REGION_NAME=$1
  local _AZ="$( aws ec2 describe-availability-zones --region $_REGION_NAME | \
    jq -r '.AvailabilityZones[].ZoneName' )"
  
  echo "$_AZ"
}

lk8s_is_az_valid()
{
  local _REGION=$1
  local _AZ="$2"
  local _AZ_LIST="$( lk8s_get_region_az $_REGION )"
  local _NUMBER_OF_AZ=$( echo "$_AZ" | wc -w | tr -d ' ' )
  local _VALID=0
  
  for our_az in $_AZ
  do
    for their_az in $_AZ_LIST
    do
      [ "$our_az" = "$their_az" ] && _VALID=$(( $_VALID + 1 ))
    done
  done
  
  [ "$_VALID" = "$_NUMBER_OF_AZ" ] && return 0
  
  return 1
}

lk8s_is_region_and_az_valid()
{
  lk8s_is_region_valid $LK8S_REGION || {
    echo "[ERROR]: Region is not valid." >&2
    return 1
  }
  
  lk8s_is_az_valid $LK8S_REGION "$LK8S_AZ_POOL" || {
    echo "[ERROR]: One of the value of availability zones is not valid." >&2
    return 1
  }
  
  return 0
}

lk8s_get_bundle_ids()
{
  cat <<EOF
{
  "3_5_usd": "nano_2_0",
  "5_usd": "micro_2_0",
  "10_usd": "small_2_0",
  "20_usd": "medium_2_0",
  "40_usd": "large_2_0",
  "80_usd": "xlarge_2_0",
  "160_usd": "2xlarge_2_0"
}
EOF
}

lk8s_is_package_valid()
{
  local _PACKAGE=$1
  (lk8s_get_bundle_ids | jq -r -e ".[\"$_PACKAGE\"]" 2>/dev/null) || return 1
  
  return 0
}

lk8s_get_control_plane_plan_price()
{
  echo "$LK8S_CONTROL_PLANE_PLAN" | sed 's/_usd//;s/_/\./'
  return 0
}

lk8s_get_worker_plan_price()
{
  echo "$LK8S_WORKER_PLAN" | sed 's/_usd//;s/_/\./'
  return 0
}

lk8s_get_monthly_estimated_cost()
{
  local _CONTROL_PLANE_PRICE=$( lk8s_get_control_plane_plan_price )
  local _WORKER_PRICE=$( lk8s_get_worker_plan_price )
  local _LOAD_BALANCER_PRICE=18.0
  
  local _TOTAL_CP_COST=$( echo "$LK8S_NUMBER_OF_CP_NODES $_CONTROL_PLANE_PRICE" | awk '{printf "%.2f", $1 * $2}' )
  local _TOTAL_WORKER_COST=$( echo "$LK8S_NUMBER_OF_WORKER_NODES $_WORKER_PRICE" | awk '{printf "%.2f", $1 * $2}' )
  
  echo "$_TOTAL_CP_COST $_TOTAL_WORKER_COST $_LOAD_BALANCER_PRICE" | awk '{printf "%.2f", $1 + $2 + $3}'
  return 0
}

lk8s_missing_tool()
{
  for tool in $LK8S_REQUIRED_TOOLS
  do
    command -v $tool >/dev/null || {
      echo "$tool"
      return 1
    }
  done
  
  echo ""
  return 0
}

lk8s_is_ssh_keypair_valid()
{
  aws lightsail get-key-pair --key-pair-name $LK8S_SSH_LIGHTSAIL_KEYPAIR_NAME >/dev/null 2>/dev/null || {
    lk8s_err "Can not find SSH key pair '$LK8S_SSH_LIGHTSAIL_KEYPAIR_NAME' in region $LK8S_REGION"
    return 1
  }
  
  return 0
}

# Default action
LK8S_ACTION="install"

# Parse the arguments
while getopts a:c:d:hi:mr:w:vu LK8S_OPT;
do
    case $LK8S_OPT in
        a)
          LK8S_AZ_POOL="$OPTARG"
        ;;

        c)
          LK8S_POD_NETWORK_CIDR="$OPTARG"
        ;;

        d)
            LK8S_INSTALLATION_ID="$OPTARG"
            LK8S_ACTION="destroy"
        ;;

        h)
            lk8s_help
            exit 0
        ;;

        i)
            LK8S_INSTALLATION_ID="$OPTARG"
        ;;
        
        m)
            LK8S_DRY_RUN="yes"
        ;;

        r)
            LK8S_REGION="$OPTARG"
        ;;

        w)
            LK8S_NUMBER_OF_WORKER_NODES="$OPTARG"
        ;;

        v)
            echo "lightsail-k8s-installer version $LK8S_VERSION"
            exit 0
        ;;
        
        u)
          LK8S_ACTION="update"
        ;;

        \?)
            echo "Unrecognised option, use -h to see help." >&2
            exit 1
        ;;
    esac
done

case $LK8S_ACTION in
  install)
    lk8s_init && \
    lk8s_run_cloudformation
  ;;
  
  update)
    lk8s_init && \
    lk8s_update_cloudformation
  ;;
  
  destroy)
    lk8s_init && \
    lk8s_destroy_installation 
  ;;
  
  *)
    echo "Unrecognised action." >&2
    exit 1
  ;;
esac
