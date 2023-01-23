#!/bin/sh
#
# @author Rio Astamal <rio@rioastamal.net>
# @desc Script to automate Kubernetes installation on Amazon Lightsail instances

LK8S_BASEDIR=$( realpath "$( dirname "$0" )" )
LK8S_VERSION="2023-01-21"
LK8S_CONFIG_FILE=""

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
LK8S_NUMBER_OF_CP_NODES=1
[ -z "$LK8S_SSH_PUBLIC_KEY_FILE" ] && LK8S_SSH_PUBLIC_KEY_FILE="$HOME/.ssh/id_rsa.pub"
[ -z "$LK8S_SSH_PRIVATE_KEY_FILE" ] && LK8S_SSH_PRIVATE_KEY_FILE="$HOME/.ssh/id_rsa"
[ -z "$LK8S_FIREWALL_SSH_ALLOW_CIDR" ] && LK8S_FIREWALL_SSH_ALLOW_CIDR="0.0.0.0/0"
[ -z "$LK8S_DRY_RUN" ] && LK8S_DRY_RUN="yes"

# See all available OS/Blueprint ID using: `aws lightsail get-blueprints`
# Only amazon_linux_2 is supported at the moment.
LK8S_CP_OS_ID="amazon_linux_2"
LK8S_WORKER_OS_ID="amazon_linux_2"
LK8S_CLOUDFORMATION_STACK_ID=$1
LK8S_CLOUDFORMATION_STACKNAME=$LK8S_CLOUDFORMATION_STACKNAME_PREFIX-$LK8S_CLOUDFORMATION_STACK_ID
LK8S_CONTROL_PLANE_NODE_PREFIX=$LK8S_CONTROL_PLANE_NODE_PREFIX-$LK8S_CLOUDFORMATION_STACKNAME
LK8S_WORKER_NODE_PREFIX=$LK8S_WORKER_NODE_PREFIX-$LK8S_CLOUDFORMATION_STACKNAME
LK8S_WORKER_LOAD_BALANCER_PREFIX=$LK8S_WORKER_LOAD_BALANCER_PREFIX-$LK8S_CLOUDFORMATION_STACKNAME

# See all available Bundle ID using CLI: `aws lightsail get-bundles`
# micro_2_0 -> 1vCPU & 1GB RAM
# small_2_0 -> 1vCPU & 2GB RAM
# medium_2_0 -> 2vCPU & 4GB RAM
[ -z "$LK8S_CP_BUNDLE_ID" ] && LK8S_CP_BUNDLE_ID="micro_2_0"
[ -z "$LK8S_WORKER_BUNDLE_ID" ] && LK8S_WORKER_BUNDLE_ID="micro_2_0"

# See all available regions using CLI: `aws lightsail get-regions`
# The AZ list is the same with EC2
[ -z "$LK8S_AZ_POOL" ] && LK8S_AZ_POOL="ap-southeast-1a ap-southeast-1b ap-southeast-1c"

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

lk8s_init()
{
  mkdir -p "$LK8S_OUTPUT_DIR"
  
  # Load config file if specified
  [ -f "$LK8S_CONFIG_FILE" ] && source "$LK8S_CONFIG_FILE"
  
  [ -z "$LK8S_CLOUDFORMATION_STACK_ID" ] && {
    echo "Missing stack id." >&1
    return 1
  }
  
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

lk8s_cf_template_master_node()
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

lk8s_cf_template_worker_node()
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

lk8s_cf_template_load_balancer_worker_node()
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
    lk8s_cf_template_header && \
    lk8s_cf_template_master_node && \
    lk8s_cf_template_worker_node && \
    lk8s_cf_template_load_balancer_worker_node
    return 1
  }

  # Do not create when the stack already exists
  aws cloudformation describe-stacks --stack-name=$LK8S_CLOUDFORMATION_STACKNAME >/dev/null 2>&1 && {
    echo "Stack already exists. SKIP."
    return 0
  }

  ( lk8s_cf_template_header && \
  lk8s_cf_template_master_node && \
  lk8s_cf_template_worker_node && \
  lk8s_cf_template_load_balancer_worker_node ) | \
  aws cloudformation create-stack \
    --stack-name="${LK8S_CLOUDFORMATION_STACKNAME_PREFIX}-$1" \
    --template-body file:///dev/stdin

  local STACK_STATUS=""
  local _WAIT_COUNTER=1
  
  while [ "$STACK_STATUS" != "CREATE_COMPLETE" ]
  do
    echo -ne "\rWaiting stack $LK8S_CLOUDFORMATION_STACKNAME to be ready$( lk8s_char_repeat '.' $_WAIT_COUNTER )\033[K"
    STACK_STATUS="$( aws cloudformation describe-stacks \
                    --stack-name="$LK8S_CLOUDFORMATION_STACKNAME" | \
                    jq -r '.Stacks[0].StackStatus' )"

    [ $_WAIT_COUNTER -ge 3 ] && _WAIT_COUNTER=0
    _WAIT_COUNTER=$(( $_WAIT_COUNTER + 1 ))
    sleep 2
  done
  
  echo -e "\rStack '$LK8S_CLOUDFORMATION_STACKNAME' is ready.\033[K"
    
  return $?
}

lk8s_run_post_command_master_node()
{
  echo "Running post commands on master nodes..."
  local _ETC_HOSTS="$( lk8s_gen_node_etc_hosts )"
  
  for i in $( seq 1 $LK8S_NUMBER_OF_CP_NODES )
  do
    local _NODE_NAME=$LK8S_CONTROL_PLANE_NODE_PREFIX-$i
    lk8s_wait_for_node_to_be_ready $_NODE_NAME
    
    echo "Applying firewall rules on node ${_NODE_NAME}..."
    lk8s_apply_firewall_rules_master_node $_NODE_NAME > /dev/null
    
    local _NODE_IP="$( aws lightsail get-instance --instance-name=$_NODE_NAME | jq -r .instance.publicIpAddress )"
    echo "Installing Kubernetes control plane on node ${_NODE_NAME}..."
    cat <<EOF | lk8s_ssh_to_node $_NODE_IP sudo -u ec2-user bash
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
  kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml
}
EOF
  done
  
  return 0
}

lk8s_run_post_command_worker_node()
{
  echo "Running post commands on worker nodes..."
  local _ETC_HOSTS="$( lk8s_gen_node_etc_hosts )"
  
  for i in $( seq 1 $LK8S_NUMBER_OF_WORKER_NODES )
  do
    local _NODE_NAME=$LK8S_WORKER_NODE_PREFIX-$i
    lk8s_wait_for_node_to_be_ready $_NODE_NAME
    
    echo "Applying firewall rules on node ${_NODE_NAME}..."
    lk8s_apply_firewall_rules_worker_node $_NODE_NAME > /dev/null
    
    local _NODE_IP="$( aws lightsail get-instance --instance-name=$_NODE_NAME | jq -r .instance.publicIpAddress )"
    local _JOIN_CMD=$( lk8s_gen_join_command )
    
    echo "Joining node $_NODE_NAME to control plane..."
    cat <<EOF | lk8s_ssh_to_node $_NODE_IP sudo -u ec2-user bash
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

lk8s_apply_firewall_rules_master_node()
{
  local _NODE_NAME=$1
  local _RULES=$( cat <<EOF
portInfos:
  - fromPort: 22
    toPort: 22
    protocol: tcp
    cidrs:
      - 0.0.0.0/0
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
      - 0.0.0.0/0
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

  aws lightsail attach-instances-to-load-balancer \
    --load-balancer-name $LK8S_WORKER_LOAD_BALANCER_PREFIX \
    --instance-names $_INSTANCE_NAMES
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
  
  echo "Deploying sample apps..."
  lk8s_wait_for_kubelet_worker_to_be_ready $_NODE_IP 
  lk8s_gen_sample_configuration_deployment | lk8s_ssh_to_node $_NODE_IP kubectl apply -f -
  lk8s_wait_for_sample_pods_to_be_ready $_NODE_IP 
  lk8s_add_node_labels_to_sample_pods $_NODE_IP
  
  return 0
}

lk8s_wait_for_sample_pods_to_be_ready()
{
  local _CONTROL_PLANE_IP=$1
  local _NUMBER_OF_PODS_READY=0
  local _NUMBER_OF_REPLICAS=$(( $LK8S_NUMBER_OF_WORKER_NODES * 2 ))
  local _WAIT_COUNTER=1
  
  while [ $_NUMBER_OF_PODS_READY -lt $_NUMBER_OF_REPLICAS ]
  do
    echo -ne "\rWaiting sample pods ($_NUMBER_OF_PODS_READY/${_NUMBER_OF_REPLICAS}) to be ready$( lk8s_char_repeat '.' $_WAIT_COUNTER )\033[K"
    _NUMBER_OF_PODS_READY=$( cat <<EOF | lk8s_ssh_to_node $_CONTROL_PLANE_IP 
kubectl get pods --show-kind \
  -l 'action=auto-label-node' -l '!node' --no-headers -o wide \
  --field-selector=status.phase=Running | grep -v 'Terminating' | wc -l
EOF
)
    [ $_WAIT_COUNTER -ge 3 ] && _WAIT_COUNTER=0
    _WAIT_COUNTER=$(( $_WAIT_COUNTER + 1 ))
    
    sleep 1
  done

  echo -e "\rAll sample pods is ready.\033[K"
  return 0
}

lk8s_wait_for_kubelet_worker_to_be_ready()
{
  local _CONTROL_PLANE_IP=$1
  local _NUMBER_OF_KUBELET_WORKER_READY=0
  local _WAIT_COUNTER=1
  
  while [ $_NUMBER_OF_KUBELET_WORKER_READY -lt $LK8S_NUMBER_OF_WORKER_NODES ]
  do
    echo -ne "\rWaiting kubelet ($_NUMBER_OF_KUBELET_WORKER_READY/${LK8S_NUMBER_OF_WORKER_NODES}) on worker to be ready$( lk8s_char_repeat '.' $_WAIT_COUNTER )\033[K"
    _NUMBER_OF_KUBELET_WORKER_READY=$( cat <<EOF | lk8s_ssh_to_node $_CONTROL_PLANE_IP 
kubectl get nodes --selector='!node-role.kubernetes.io/control-plane' --no-headers | grep -v 'NotReady' | wc -l
EOF
)
    [ $_WAIT_COUNTER -ge 3 ] && _WAIT_COUNTER=0
    _WAIT_COUNTER=$(( $_WAIT_COUNTER + 1 ))
    
    sleep 1
  done

  echo -e "\rAll kubelet for worker node is ready.\033[K"
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
    echo -ne "\rWaiting node $_NODE_NAME to be ready$( lk8s_char_repeat '.' $_WAIT_COUNTER )\033[K"
    
    [ $_WAIT_COUNTER -ge 3 ] && _WAIT_COUNTER=0
    _WAIT_COUNTER=$(( $_WAIT_COUNTER + 1 ))
    
    sleep 2
  done
  
  echo -e "\rNode '$_NODE_NAME' is ready.\033[K"
  return 0
}

lk8s_init && \
lk8s_run_cloudformation $1 && \
lk8s_run_post_command_master_node && \
lk8s_run_post_command_worker_node && \
lk8s_deploy_sample_app &&
lk8s_attach_load_balancer_to_worker_node
