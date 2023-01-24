#!/bin/sh
#
# @author Rio Astamal <rio@rioastamal.net>
# @desc Script to automate Kubernetes installation on Amazon Lightsail instances

readonly LK8S_SCRIPT_NAME=$( basename "$0" )
LK8S_BASEDIR=$( realpath "$( dirname "$0" )" )
LK8S_VERSION="2023-01-21"
LK8S_DEBUG="true"

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
[ -z "$LK8S_SSH_PUBLIC_KEY_FILE" ] && LK8S_SSH_PUBLIC_KEY_FILE="$HOME/.ssh/id_rsa.pub"
[ -z "$LK8S_SSH_PRIVATE_KEY_FILE" ] && LK8S_SSH_PRIVATE_KEY_FILE="$HOME/.ssh/id_rsa"
[ -z "$LK8S_FIREWALL_SSH_ALLOW_CIDR" ] && LK8S_FIREWALL_SSH_ALLOW_CIDR="0.0.0.0/0"
[ -z "$LK8S_DRY_RUN" ] && LK8S_DRY_RUN="no"
[ -z "$LK8S_CONTROL_PLANE_PLAN"] && LK8S_CONTROL_PLANE_PLAN="5_usd"
[ -z "$LK8S_WORKER_PLAN"] && LK8S_WORKER_PLAN="5_usd"

# Currently only 1 control plane node supported
# Todo: Support High Availability Control Plane Cluster
LK8S_NUMBER_OF_CP_NODES=1

# See all available OS/Blueprint ID using: `aws lightsail get-blueprints`
# Only amazon_linux_2 is supported at the moment.
LK8S_CP_OS_ID="amazon_linux_2"
LK8S_WORKER_OS_ID="amazon_linux_2"

# Default user data for instance initialization
LK8S_NODE_USER_DATA=$( cat << 'EOF'
        #!/bin/sh
        
        ## Disable SELinux
        sudo setenforce 0
        sudo sed -i 's/^SELINUX=enforcing$/SELINUX=permissive/' /etc/selinux/config
        
        ## Add Kubernetes repo
        cat <<EOF | sudo tee /etc/yum.repos.d/kubernetes.repo
        [kubernetes]
        name=Kubernetes
        baseurl=https://packages.cloud.google.com/yum/repos/kubernetes-el7-\$basearch
        enabled=1
        gpgcheck=1
        gpgkey=https://packages.cloud.google.com/yum/doc/rpm-package-key.gpg
        exclude=kubelet kubeadm kubectl
        EOF
        
        ## Install Kubernetes Tools and Docker
        sudo yum install -y docker kubelet kubeadm kubectl tc jq --disableexcludes=kubernetes
        sudo systemctl enable --now docker
        sudo systemctl enable --now kubelet
        
        ## Modify networking and Swappiness
        cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
        net.bridge.bridge-nf-call-ip6tables = 1
        net.bridge.bridge-nf-call-iptables = 1
        vm.swappiness = 0
        EOF
        
        sudo sysctl --system
EOF
        cat << EOF
        echo '$( cat $LK8S_SSH_PUBLIC_KEY_FILE )' >> /home/ec2-user/.ssh/authorized_keys
EOF
)

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
  -w NUM        specify number of worker nodes using NUM
  -v            print script version
  
----------------------- lightsail-k8s-installer -----------------------

lightsail-k8s-installer is a command line interface to bootstrap Kubernetes 
cluster on Amazon Lightsail. 

lightsail-k8s-installer is free software licensed under MIT. Visit the project 
homepage at http://github.com/rioastamal/lightsail-k8s-installer."
}

lk8s_write_log()
{
    _LOG_MESSAGE="$@"
    _SYSLOG_DATE_STYLE=$( date +"%b %e %H:%M:%S" )

    # Date Hostname AppName[PID]: MESSAGE
    printf "[%s LK8S]: %s\n" \
        "$_SYSLOG_DATE_STYLE" \
        "${_LOG_MESSAGE}">> "$LK8S_LOG_FILE"
}

lk8s_log()
{
    [ "$LK8S_DEBUG" = "true" ] && echo "[LK8S]: $@"
    lk8s_write_log "$@"
}

lk8s_log_waiting()
{
    [ "$LK8S_DEBUG" = "true" ] && echo -en "\r[LK8S]: $@\033[K"
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

  return 0
}

lk8s_char_repeat()
{
  # $1 -> char
  # $2 -> number of repeat
  for i in $( seq 1 $2 )
  do
    echo -n $1
  done
}

lk8s_ssh_to_node()
{
  local _NODE_IP=$1

  # Remove the $1
  shift
  
  ssh -o ConnectTimeout=3 -o StrictHostKeyChecking=no -o LogLevel=error \
    ec2-user@$_NODE_IP $@
}

lk8s_get_az_pool_index()
{
  local _SEQUENCE=$1
  local _NUMBER_OF_AZ=$( echo "$LK8S_AZ_POOL" | wc -w )
  local _AZ_POOL_INDEX=$(( $_SEQUENCE % $_NUMBER_OF_AZ ))
  
  [ $_AZ_POOL_INDEX -eq 0 ] && {
    echo $_NUMBER_OF_AZ
    return 0
  }
  
  echo $_AZ_POOL_INDEX
  return 0
}

lk8s_cf_template_control_plane_nodes()
{
  for i in $( seq 1 $LK8S_NUMBER_OF_CP_NODES )
  do
    local _AZ_POOL_INDEX=$( lk8s_get_az_pool_index $i )
    local _AZ_ID=$( echo "$LK8S_AZ_POOL" | cut -d' ' -f$_AZ_POOL_INDEX )
    
    cat <<EOF
  ControlPlaneNode${i}:
    Type: AWS::Lightsail::Instance
    Properties:
      AvailabilityZone: $_AZ_ID
      BlueprintId: $LK8S_CP_OS_ID
      BundleId: $LK8S_CP_BUNDLE_ID
      InstanceName: $LK8S_CONTROL_PLANE_NODE_PREFIX-$i
      Networking:
        Ports:
          - Protocol: tcp
            FromPort: 22
            ToPort: 22
            Cidrs:
              - $LK8S_FIREWALL_SSH_ALLOW_CIDR
      UserData: |
$LK8S_NODE_USER_DATA
EOF
  done
  
  return 0
}

lk8s_cf_template_worker_nodes()
{
  for i in $( seq 1 $LK8S_NUMBER_OF_WORKER_NODES )
  do
    local _AZ_POOL_INDEX=$( lk8s_get_az_pool_index $i )
    local _AZ_ID=$( echo "$LK8S_AZ_POOL" | cut -d' ' -f$_AZ_POOL_INDEX )
    cat <<EOF
  WorkerNode${i}:
    Type: AWS::Lightsail::Instance
    Properties:
      AvailabilityZone: $_AZ_ID
      BlueprintId: $LK8S_WORKER_OS_ID
      BundleId: $LK8S_WORKER_BUNDLE_ID
      InstanceName: $LK8S_WORKER_NODE_PREFIX-$i
      Networking:
        Ports:
          - Protocol: tcp
            FromPort: 22
            ToPort: 22
            Cidrs:
              - $LK8S_FIREWALL_SSH_ALLOW_CIDR
      UserData: |
$LK8S_NODE_USER_DATA
EOF
  done
  
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
  [ "$LK8S_DRY_RUN" = "yes" ] && {
    lk8s_is_region_and_az_valid && \
    lk8s_cf_template_header && \
    lk8s_cf_template_control_plane_nodes && \
    lk8s_cf_template_worker_nodes && \
    lk8s_cf_template_load_balancer_worker_nodes
    return 1
  }

  local _ANSWER="no"
  local _TITLE="lightsail-k8s-installer v${LK8S_VERSION}"
  local _ANY_KEY=""
  
  # See all available Bundle ID using CLI: `aws lightsail get-bundles`
  LK8S_CP_BUNDLE_ID="$( lk8s_is_package_valid $LK8S_CONTROL_PLANE_PLAN )" || {
    lk8s_err "Control plane plan '$LK8S_CONTROL_PLANE_PLAN' is not valid"
    return 1
  }
  
  LK8S_WORKER_BUNDLE_ID="$( lk8s_is_package_valid $LK8S_WORKER_PLAN )" || {
    lk8s_err "Worker plan '$LK8S_WORKER_PLAN' is not valid"
    return 1
  }
  
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
  
  lk8s_is_region_and_az_valid || return 1

  lk8s_log "Checking existing stack '${LK8S_CLOUDFORMATION_STACKNAME}'"
  # Do not create when the stack already exists
  aws cloudformation describe-stacks --stack-name=$LK8S_CLOUDFORMATION_STACKNAME >>$LK8S_LOG_FILE 2>&1 && {
    lk8s_log "Stack already exists. Skip."
    return 0
  }
  
  lk8s_log "Stack '${LK8S_CLOUDFORMATION_STACKNAME}' is not exists, good!"

  ( lk8s_cf_template_header && \
  lk8s_cf_template_control_plane_nodes && \
  lk8s_cf_template_worker_nodes && \
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
                    --stack-name="$LK8S_CLOUDFORMATION_STACKNAME" | \
                    jq -r '.Stacks[0].StackStatus' )"

    [ $_WAIT_COUNTER -ge 3 ] && _WAIT_COUNTER=0
    _WAIT_COUNTER=$(( $_WAIT_COUNTER + 1 ))
    sleep 2
  done
  
  echo
  lk8s_log "Stack '$LK8S_CLOUDFORMATION_STACKNAME' is ready"
  
  return $?
}

lk8s_run_post_command_control_plance_nodes()
{
  lk8s_log "Running post installation commands on control plane nodes"
  local _ETC_HOSTS="$( lk8s_gen_node_etc_hosts )"
  
  for i in $( seq 1 $LK8S_NUMBER_OF_CP_NODES )
  do
    local _NODE_NAME=$LK8S_CONTROL_PLANE_NODE_PREFIX-$i
    lk8s_wait_for_node_to_be_ready $_NODE_NAME
    
    lk8s_log "Applying firewall rules on node '${_NODE_NAME}'"
    lk8s_apply_firewall_rules_control_plane_nodes $_NODE_NAME > /dev/null
    
    local _NODE_IP="$( aws lightsail get-instance --instance-name=$_NODE_NAME | jq -r .instance.publicIpAddress )"
    lk8s_log "Installing Kubernetes control plane on node ${_NODE_NAME}"
    
    cat <<EOF | lk8s_ssh_to_node $_NODE_IP sudo -u ec2-user bash >> $LK8S_LOG_FILE
[ "\$( hostname )" != "$_NODE_NAME" ] && {
  sudo hostnamectl set-hostname $_NODE_NAME
}

grep $_NODE_NAME /etc/hosts >/dev/null || (
  echo -e "$_ETC_HOSTS" | sudo tee -a /etc/hosts >/dev/null
)

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
  done
  
  return 0
}

lk8s_run_post_command_worker_node()
{
  lk8s_log "Running post installation commands on worker nodes"
  local _ETC_HOSTS="$( lk8s_gen_node_etc_hosts )"
  
  for i in $( seq 1 $LK8S_NUMBER_OF_WORKER_NODES )
  do
    local _NODE_NAME=$LK8S_WORKER_NODE_PREFIX-$i
    lk8s_wait_for_node_to_be_ready $_NODE_NAME
    
    lk8s_log "Applying firewall rules on node '${_NODE_NAME}'"
    lk8s_apply_firewall_rules_worker_node $_NODE_NAME >> $LK8S_LOG_FILE
    
    local _NODE_IP="$( aws lightsail get-instance --instance-name=$_NODE_NAME | jq -r .instance.publicIpAddress )"
    local _JOIN_CMD=$( lk8s_gen_join_command )
    
    lk8s_log "Joining worker node '$_NODE_NAME' to control plane"
    cat <<EOF | lk8s_ssh_to_node $_NODE_IP sudo -u ec2-user bash >> $LK8S_LOG_FILE
[ "\$( hostname )" != "$_NODE_NAME" ] && {
  sudo hostnamectl set-hostname $_NODE_NAME
}

grep $_NODE_NAME /etc/hosts >/dev/null || (
  echo -e "$_ETC_HOSTS" | sudo tee -a /etc/hosts >/dev/null
)

sudo $_JOIN_CMD
EOF
  done
  
  return 0
}

lk8s_apply_firewall_rules_control_plane_nodes()
{
  local _NODE_NAME=$1
  local _RULES=$( cat <<EOF
portInfos:
  - fromPort: 22
    toPort: 22
    protocol: tcp
    cidrs:
      - $LK8S_FIREWALL_SSH_ALLOW_CIDR
  - fromPort: 6443
    toPort: 6443
    protocol: tcp
    cidrs:
      - 172.26.0.0/16
  - fromPort: 2379
    toPort: 2380
    protocol: tcp
    cidrs:
      - 172.26.0.0/16
  - fromPort: 10250
    toPort: 10250
    protocol: tcp
    cidrs:
      - 172.26.0.0/16
  - fromPort: 10257
    toPort: 10257
    protocol: tcp
    cidrs:
      - 172.26.0.0/16
  - fromPort: 10259
    toPort: 10259
    protocol: tcp
    cidrs:
      - 172.26.0.0/16
EOF
)
  aws lightsail put-instance-public-ports \
    --instance-name=$_NODE_NAME \
    --cli-input-yaml "$_RULES"
}

lk8s_apply_firewall_rules_worker_node()
{
  local _NODE_NAME=$1
  local _RULES=$( cat <<EOF
portInfos:
  - fromPort: 22
    toPort: 22
    protocol: tcp
    cidrs:
      - $LK8S_FIREWALL_SSH_ALLOW_CIDR
  - fromPort: 80
    toPort: 80
    protocol: tcp
    cidrs:
      - 172.26.0.0/16
  - fromPort: 30000
    toPort: 32767
    protocol: tcp
    cidrs:
      - 172.26.0.0/16
  - fromPort: 10250
    toPort: 10250
    protocol: tcp
    cidrs:
      - 172.26.0.0/16
EOF
)
  aws lightsail put-instance-public-ports \
    --instance-name=$_NODE_NAME \
    --cli-input-yaml "$_RULES"
}

lk8s_attach_load_balancer_to_worker_node()
{
  local _INSTANCE_NAMES=""
  for i in $( seq $LK8S_NUMBER_OF_WORKER_NODES )
  do
    _INSTANCE_NAMES="$_INSTANCE_NAMES $LK8S_WORKER_NODE_PREFIX-$i"
  done

  lk8s_log "Attaching worker nodes to Lightsail Load Balancer"
  aws lightsail attach-instances-to-load-balancer \
    --load-balancer-name $LK8S_WORKER_LOAD_BALANCER_PREFIX \
    --instance-names $_INSTANCE_NAMES >> $LK8S_LOG_FILE
    
  return 0
}

lk8s_print_installation_info()
{
  local _NODE_NAME=$LK8S_CONTROL_PLANE_NODE_PREFIX-1
  local _CONTROL_PLANE_IP=$( aws lightsail get-instance --instance-name=$_NODE_NAME | jq -r .instance.publicIpAddress )
  local _LB_URL=$( aws lightsail get-load-balancer --load-balancer-name $LK8S_WORKER_LOAD_BALANCER_PREFIX | jq -r '.loadBalancer.dnsName' )
  local _KUBERNETES_INFO="$( lk8s_ssh_to_node $_CONTROL_PLANE_IP kubectl get nodes,services,deployments,pods )"
  local _INFO=$( cat <<EOF
Your Kubernetes installation info:
$_KUBERNETES_INFO

Accessing Control Plane via SSH:
  ssh ec2-user@$_CONTROL_PLANE_IP
  
Your app are available via load balancer:
  http://$_LB_URL

You can view detailed installation log at:
  $LK8S_LOG_FILE
  
To delete sample app run following on Control plane:
  kubectl get services,deployments --no-headers -o name \
    -l cfstackname=$LK8S_CLOUDFORMATION_STACKNAME | xargs kubectl delete

EOF
)
  lk8s_log "$_INFO"
  echo
  lk8s_log "Installation COMPLETED."
  
  return 0
}

lk8s_gen_join_command()
{
  local _NODE_NAME=$LK8S_CONTROL_PLANE_NODE_PREFIX-1
  local _NODE_IP="$( aws lightsail get-instance --instance-name=$_NODE_NAME | jq -r .instance.publicIpAddress )"
  local _SERVER="$( lk8s_ssh_to_node $_NODE_IP kubectl config view -o jsonpath='{.clusters[].cluster.server}' | cut -c9- )"
  local _TOKEN="$( lk8s_ssh_to_node $_NODE_IP kubeadm token list -o jsonpath='{.token}')"
  local _CA_CERT_HASH=$( cat <<EOF | lk8s_ssh_to_node $_NODE_IP sudo -u ec2-user bash
openssl x509 -pubkey -in /etc/kubernetes/pki/ca.crt | openssl rsa -pubin -outform der 2>/dev/null | openssl dgst -sha256 -hex | sed 's/^.* //'
EOF
  )
  
  echo "kubeadm join $_SERVER --token=$_TOKEN --discovery-token-ca-cert-hash=sha256:$_CA_CERT_HASH"
}

lk8s_gen_node_etc_hosts()
{
  local _ETC_HOSTS=""
  local _HOSTNAME=""
  local _PRIVATE_IP=""
  
  for i in $( seq $LK8S_NUMBER_OF_CP_NODES )
  do
    _HOSTNAME=$LK8S_CONTROL_PLANE_NODE_PREFIX-$i
    _PRIVATE_IP=$( aws lightsail get-instance --instance-name=$_HOSTNAME | jq -r .instance.privateIpAddress )
    _ETC_HOSTS="${_ETC_HOSTS}$_PRIVATE_IP $_HOSTNAME\n"
  done
  
  for i in $( seq $LK8S_NUMBER_OF_WORKER_NODES )
  do
    _HOSTNAME=$LK8S_WORKER_NODE_PREFIX-$i
    _PRIVATE_IP=$( aws lightsail get-instance --instance-name=$_HOSTNAME | jq -r .instance.privateIpAddress )
    _ETC_HOSTS="${_ETC_HOSTS}$_PRIVATE_IP $_HOSTNAME\n"
  done
  
  echo -en "$_ETC_HOSTS"
  
  return 0
}

lk8s_gen_sample_configuration_deployment()
{
  local _NUMBER_OF_REPLICAS=$(( $LK8S_NUMBER_OF_WORKER_NODES * 2 ))
  local _YAML_DEPLOYMENT=$( cat <<EOF
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
          - "-text=Node: \$(MY_NODE_NAME)/\$(MY_HOST_IP) - Pod: \$(MY_POD_NAME)/\$(MY_POD_IP)"
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
)

  local _YAML_SERVICES=""
  
  for i in $( seq 1 $LK8S_NUMBER_OF_WORKER_NODES )
  do
    local _NODE_NAME=$LK8S_WORKER_NODE_PREFIX-$i
    local _NODE_PRIVATE_IP="$( aws lightsail get-instance --instance-name=$_NODE_NAME | jq -r .instance.privateIpAddress )"
    local _TMP=$( cat <<EOF
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
)
    _YAML_SERVICES="${_YAML_SERVICES}\n${_TMP}"
  done
  
  echo -e "$_YAML_DEPLOYMENT"
  echo -e "$_YAML_SERVICES"
  
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
  local _NODE_NAME=$LK8S_CONTROL_PLANE_NODE_PREFIX-1
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
    _NUMBER_OF_PODS_READY=$( cat <<EOF | lk8s_ssh_to_node $_CONTROL_PLANE_IP 
kubectl get pods --show-kind \
  -l 'action=auto-label-node' -l '!node' --no-headers -o wide \
  --field-selector=status.phase=Running 2>/dev/null | grep -v 'Terminating' | wc -l
EOF
)

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
  
  lk8s_log_waiting "Waiting kubelet on worker ($_NUMBER_OF_KUBELET_WORKER_READY/${LK8S_NUMBER_OF_WORKER_NODES}) to be ready$( lk8s_char_repeat '.' $_WAIT_COUNTER )"
  
  while [ $_NUMBER_OF_KUBELET_WORKER_READY -lt $LK8S_NUMBER_OF_WORKER_NODES ]
  do
    _NUMBER_OF_KUBELET_WORKER_READY=$( cat <<EOF | lk8s_ssh_to_node $_CONTROL_PLANE_IP 
kubectl get nodes --selector='!node-role.kubernetes.io/control-plane' --no-headers | grep -v 'NotReady' | wc -l
EOF
)

    lk8s_log_waiting "Waiting kubelet on worker ($_NUMBER_OF_KUBELET_WORKER_READY/${LK8S_NUMBER_OF_WORKER_NODES}) to be ready$( lk8s_char_repeat '.' $_WAIT_COUNTER )"
    
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
    _NODE_STATUS="$( lk8s_ssh_to_node $_NODE_IP whoami 2>/dev/null )"
    lk8s_log_waiting "Waiting node '$_NODE_NAME' to be ready$( lk8s_char_repeat '.' $_WAIT_COUNTER )"
    
    [ $_WAIT_COUNTER -ge 3 ] && _WAIT_COUNTER=0
    _WAIT_COUNTER=$(( $_WAIT_COUNTER + 1 ))
    
    sleep 2
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
  local _REGIONS=$( lk8s_get_lightsail_regions )
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
  local _AZ=$( aws ec2 describe-availability-zones --region $_REGION_NAME | \
    jq -r '.AvailabilityZones[].ZoneName' )
  
  echo "$_AZ"
}

lk8s_is_az_valid()
{
  local _REGION=$1
  local _AZ=$2
  local _AZ_LIST="$( lk8s_get_region_az $_REGION )"
  local _NUMBER_OF_AZ=$( echo "$_AZ" | wc -w )
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
  echo "$LK8S_CONTROL_PLANE_PLAN" | sed 's/_usd//;s/_/\./'
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

# Default action
LK8S_ACTION="install"

# Parse the arguments
while getopts a:c:d:hi:mr:w:v LK8S_OPT;
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

        \?)
            echo "Unrecognised option, use -h to see help." >&2
            exit 1
        ;;
    esac
done

case $LK8S_ACTION in
  install)
    lk8s_init && \
    lk8s_run_cloudformation && \
    lk8s_run_post_command_control_plance_nodes && \
    lk8s_run_post_command_worker_node && \
    lk8s_deploy_sample_app && \
    lk8s_attach_load_balancer_to_worker_node && \
    lk8s_print_installation_info
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
