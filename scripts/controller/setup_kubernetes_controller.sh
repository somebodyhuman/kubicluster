#/!bin/bash

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

REMAINING_ARGS=''
NODE_WORK_DIR=''
INTERNAL_IP=''
CLUSTER_NAME='kubicluster'
CLIENT_PORT=2379
KUBERNETES_VERSION=1.18.5
FORCE_UPDATE=false
# TODO let the following be overwritten through args
CLUSTER_IP_RANGE='10.32.0.0/24'
SERVICE_NODE_PORT_RANGE='30000-32767'
CLUSTER_CIDR='10.200.0.0/16'

INITIAL_ETCD_CLUSTER=''
# As long as there is at least one more argument, keep looping
while [[ $# -gt 0 ]]; do
    key="$1"
    case "$key" in
        -nwd=*|--node-work-dir=*)
        NODE_WORK_DIR="${key#*=}"
        ;;
        -ip=*|--internal-ip=*)
        INTERNAL_IP="${key#*=}"
        ;;
        -cl=*|--cluster=*)
        CLUSTER_NAME="${key#*=}"
        ;;
        -cp=*|--client-port=*)
        CLIENT_PORT="${key#*=}"
        ;;
        -f|--force-update)
        FORCE_UPDATE=true
        ;;
        -cmu=*|--cluster-member-uri=*)
        PL=',' ; if [ "${INITIAL_ETCD_CLUSTER}" == "" ]; then PL=''; fi
        INITIAL_ETCD_CLUSTER="${INITIAL_ETCD_CLUSTER}${PL}${key#*=}"
        ;;
        *)
        REMAINING_ARGS="${REMAINING_ARGS} $key"
        ;;
    esac
    # Shift after checking all the cases to get the next option
    shift
done

if [ "$(wget --help| grep 'command not found')" ]; then
  apt-get install -y wget
fi
if [ "$(tar --help| grep 'command not found')" ]; then
  apt-get install -y tar
fi

CERTS_AND_CONFIGS_DIR=${NODE_WORK_DIR}/certs_and_configs
KUBERNETES_PARENT_DIR=${NODE_WORK_DIR}/kubernetes-${KUBERNETES_VERSION}
KUBERNETES_DIR=${KUBERNETES_PARENT_DIR}/kubernetes
KUBERNETES_SERVER_DIR=${KUBERNETES_DIR}/server

if [ ! -d /var/lib/kubernetes ]; then mkdir -p /var/lib/kubernetes; fi
if [ ! -d ${NODE_WORK_DIR} ]; then mkdir -p ${NODE_WORK_DIR}; fi

if [ ! -f ${NODE_WORK_DIR}/kubernetes-${KUBERNETES_VERSION}.tar.gz ]; then
  if ! (dpkg -s ca-certificates); then apt-get install -y ca-certificates; fi
  wget -q --show-progress --https-only --timestamping \
    "https://github.com/kubernetes/kubernetes/releases/download/v${KUBERNETES_VERSION}/kubernetes.tar.gz" -O ${NODE_WORK_DIR}/kubernetes-${KUBERNETES_VERSION}.tar.gz
fi

if [ ! -d ${NODE_WORK_DIR}/kubernetes-${KUBERNETES_VERSION} ]; then
  mkdir -p ${NODE_WORK_DIR}/kubernetes-${KUBERNETES_VERSION}
  tar -xvzf ${NODE_WORK_DIR}/kubernetes-${KUBERNETES_VERSION}.tar.gz -C ${NODE_WORK_DIR}/kubernetes-${KUBERNETES_VERSION}/
fi
if [ ! -f ${KUBERNETES_SERVER_DIR}/bin/kube-apiserver ] || \
   [ ! -f ${KUBERNETES_SERVER_DIR}/bin/kube-controller-manager ] || \
   [ ! -f ${KUBERNETES_SERVER_DIR}/bin/kube-scheduler ] || \
   [ ! -f ${KUBERNETES_SERVER_DIR}/bin/kubectl ]; then
  KUBERNETES_SKIP_CONFIRM=true ${KUBERNETES_PARENT_DIR}/kubernetes/cluster/get-kube-binaries.sh
  tar vxzf ${KUBERNETES_SERVER_DIR}/kubernetes-server-linux-amd64.tar.gz -C ${KUBERNETES_PARENT_DIR}/
else
  echo "kubernetes ${KUBERNETES_VERSION} already exists"
fi

if [ ! -f /etc/systemd/system/kube-apiserver.service ] || \
   [ "$(systemctl status kube-apiserver.service | grep running)" = "" ] || \
   [ ! -f /usr/local/bin/kubectl ] || \
   [ "${FORCE_UPDATE}" = true ]; then
  if [ -f /usr/local/bin/kube-apiserver ]; then rm -f /usr/local/bin/kube-apiserver; fi
  if [ -f /usr/local/bin/kubectl ]; then rm -f /usr/local/bin/kubectl; fi
  ln -s ${KUBERNETES_SERVER_DIR}/bin/kube-apiserver /usr/local/bin/kube-apiserver
  ln -s ${KUBERNETES_SERVER_DIR}/bin/kubectl /usr/local/bin/kubectl

  KUBECTL_VERSION=$(kubectl version --short --client)
  if [ "${KUBECTL_VERSION}" != "Client Version: v${KUBERNETES_VERSION}" ]; then
    echo "kubectl ${KUBECTL_VERSION} installation failed."
    exit 1
  else
    echo "kubectl version is ${KUBECTL_VERSION}."
  fi
  # explain config args of kube-apiserver and their effects on the cluster
  # TODO explain admissions plugins
  # TODO explain swagger ui
  # TODO explain apiserver-count
  # TODO explain runtime-config
  # TODO explain event-ttl
  # TODO explain kubelet-https and kubelet-preferred-address-types
  if [ ! -f /etc/systemd/system/kube-apiserver.service ] || \
     [ "${FORCE_UPDATE}" = true ]; then
    cat << EOF | tee /etc/systemd/system/kube-apiserver.service
[Unit]
Description=Kubernetes API Server
Documentation=https://github.com/kubernetes/kubernetes

[Service]
ExecStart=/usr/local/bin/kube-apiserver \\
  --advertise-address=${INTERNAL_IP} \\
  --allow-privileged=true \\
  --apiserver-count=3 \\
  --audit-log-maxage=30 \\
  --audit-log-maxbackup=3 \\
  --audit-log-maxsize=100 \\
  --audit-log-path=/var/log/audit.log \\
  --authorization-mode=Node,RBAC \\
  --bind-address=0.0.0.0 \\
  --client-ca-file=${CERTS_AND_CONFIGS_DIR}/ca.pem \\
  --enable-admission-plugins=NamespaceLifecycle,NodeRestriction,LimitRanger,ServiceAccount,DefaultStorageClass,ResourceQuota \\
  --enable-swagger-ui=true \\
  --etcd-cafile=${CERTS_AND_CONFIGS_DIR}/ca.pem \\
  --etcd-certfile=${CERTS_AND_CONFIGS_DIR}/kubernetes.pem \\
  --etcd-keyfile=${CERTS_AND_CONFIGS_DIR}/kubernetes-key.pem \\
  --etcd-servers=${INITIAL_ETCD_CLUSTER} \\
  --event-ttl=1h \\
  --experimental-encryption-provider-config=${CERTS_AND_CONFIGS_DIR}/encryption-config.yaml \\
  --kubelet-certificate-authority=${CERTS_AND_CONFIGS_DIR}/ca.pem \\
  --kubelet-client-certificate=${CERTS_AND_CONFIGS_DIR}/kubernetes.pem \\
  --kubelet-client-key=${CERTS_AND_CONFIGS_DIR}/kubernetes-key.pem \\
  --kubelet-https=true \\
  --runtime-config=api/all=true \\
  --service-account-key-file=${CERTS_AND_CONFIGS_DIR}/service-account.pem \\
  --service-cluster-ip-range=${CLUSTER_IP_RANGE} \\
  --service-node-port-range=${SERVICE_NODE_PORT_RANGE} \\
  --tls-cert-file=${CERTS_AND_CONFIGS_DIR}/kubernetes.pem \\
  --tls-private-key-file=${CERTS_AND_CONFIGS_DIR}/kubernetes-key.pem \\
  --v=2 \\
  --kubelet-preferred-address-types=InternalIP,InternalDNS,Hostname,ExternalIP,ExternalDNS
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
  fi
  systemctl enable kube-apiserver
  if [ "${FORCE_UPDATE}" = true ]; then
    systemctl stop kube-apiserver
  fi
  systemctl start kube-apiserver
  systemctl status kube-apiserver
fi

if [ "$(systemctl status kube-controller-manager.service | grep running)" = "" ] || [ "${FORCE_UPDATE}" = true ]; then
  if [ -f /usr/local/bin/kube-controller-manager ]; then rm -f /usr/local/bin/kube-controller-manager; fi
  ln -s ${KUBERNETES_SERVER_DIR}/bin/kube-controller-manager /usr/local/bin/kube-controller-manager

  # TODO explain leader-elect
  # TODO explain use-service-account-credentials
  # TODO explain v=2
  cat << EOF | tee /etc/systemd/system/kube-controller-manager.service
[Unit]
Description=Kubernetes Controller Manager
Documentation=https://github.com/kubernetes/kubernetes

[Service]
ExecStart=/usr/local/bin/kube-controller-manager \\
  --address=0.0.0.0 \\
  --cluster-cidr=${CLUSTER_CIDR} \\
  --cluster-name=${CLUSTER_NAME} \\
  --cluster-signing-cert-file=${CERTS_AND_CONFIGS_DIR}/ca.pem \\
  --cluster-signing-key-file=${CERTS_AND_CONFIGS_DIR}/ca-key.pem \\
  --kubeconfig=${CERTS_AND_CONFIGS_DIR}/kube-controller-manager.kubeconfig \\
  --leader-elect=true \\
  --root-ca-file=${CERTS_AND_CONFIGS_DIR}/ca.pem \\
  --service-account-private-key-file=${CERTS_AND_CONFIGS_DIR}/service-account-key.pem \\
  --service-cluster-ip-range=${CLUSTER_IP_RANGE} \\
  --use-service-account-credentials=true \\
  --v=2
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable kube-controller-manager
  if [ "${FORCE_UPDATE}" = true ]; then
    systemctl stop kube-controller-manager
  fi
  systemctl start kube-controller-manager
  systemctl status kube-controller-manager
fi

if [ "$(systemctl status kube-scheduler.service | grep running)" = "" ] || [ "${FORCE_UPDATE}" = true ]; then
  if [ -f /usr/local/bin/kube-scheduler ]; then rm -f /usr/local/bin/kube-scheduler; fi
  ln -s ${KUBERNETES_SERVER_DIR}/bin/kube-scheduler /usr/local/bin/kube-scheduler

  cat << EOF | tee ${CERTS_AND_CONFIGS_DIR}/kube-scheduler.yaml
apiVersion: kubescheduler.config.k8s.io/v1alpha1
kind: KubeSchedulerConfiguration
clientConnection:
  kubeconfig: "${CERTS_AND_CONFIGS_DIR}/kube-scheduler.kubeconfig"
leaderElection:
  leaderElect: true
EOF

  # TODO explain v=2
  # TODO make cluster name configurable
  # TODO explain leader-elect
  # TODO explain use-service-account-credentials
  cat << EOF | tee /etc/systemd/system/kube-scheduler.service
[Unit]
Description=Kubernetes Scheduler
Documentation=https://github.com/kubernetes/kubernetes

[Service]
ExecStart=/usr/local/bin/kube-scheduler \\
  --config=${CERTS_AND_CONFIGS_DIR}/kube-scheduler.yaml \\
  --v=2
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable kube-scheduler
  if [ "${FORCE_UPDATE}" = true ]; then
    systemctl stop kube-scheduler
  fi
  systemctl start kube-scheduler
  systemctl status kube-scheduler
fi

# check the detail status of the controller components
# note: if we would only check if the services are running, we would miss permission issues (which are common points of misconfiguration if the cluster is setup manually)
COMPS_STATUS=$(kubectl get componentstatuses --kubeconfig ${CERTS_AND_CONFIGS_DIR}/admin.kubeconfig)
API_SERVER_STATUS=$(echo -e "${COMPS_STATUS}" | grep STATUS)

if [ "${API_SERVER_STATUS}" == "" ]; then
  echo "Error: API Server not healthy or not reachable:"
  echo "${COMPS_STATUS}"
  exit 1
else
  echo "API Server healthy and reachable"
  EXIT_CODE=0
  for component in etcd controller-manager scheduler; do
    COMP_STATUS=$(echo -e "${COMPS_STATUS}" | grep ${component} | grep Healthy)
    if [ "${COMP_STATUS}" == "" ]; then
      echo "Error: ${component} not healthy or not reachable:"
      echo "${COMP_STATUS}"
      EXIT_CODE=$((${EXIT_CODE} + 1))
    fi
  done
  echo ${EXIT_CODE}
fi
