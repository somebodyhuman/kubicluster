#/!bin/bash

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

REMAINING_ARGS=''
NODE_WORK_DIR=''
INTERNAL_IP=''
CLUSTER_TOKEN=etcd-kubicluster
CLIENT_PORT=2379
PEER_PORT=2380
ETCD_VERSION='3.3.5'
INITIAL_CLUSTER=''
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
        -cp=*|--client-port=*)
        CLIENT_PORT="${key#*=}"
        ;;
        -pp=*|--peer-port=*)
        PEER_PORT="${key#*=}"
        ;;
        -t=*|--cluster-token=*)
        CLUSTER_TOKEN="${key#*=}"
        ;;
        -ev=*|--etcd-version=*)
        ETCD_VERSION="${key#*=}"
        ;;
        -cmu=*|--cluster-member-uri=*)
        shift # past the key and to the value
        INITIAL_CLUSTER="${INITIAL_CLUSTER},$1"
        ;;
        *)
        REMAINING_ARGS="${REMAINING_ARGS} $key"
        ;;
    esac
    # Shift after checking all the cases to get the next option
    shift
done

# TODO check for essential args and exit if not specified

if [ "$(wget --help| grep 'command not found')" ]; then
  apt-get install -y wget
fi
if [ "$(tar --help| grep 'command not found')" ]; then 
  apt-get install -y tar
fi

CERTS_AND_CONFIGS_DIR=${NODE_WORK_DIR}/certs_and_configs
ETC_DATA_DIR=${NODE_WORK_DIR}/etc_data

# add this controller to the initial cluster list
INITIAL_CLUSTER="$(hostname)=https://${INTERNAL_IP}:${PEER_PORT}${INITIAL_CLUSTER}"

if [ -d /etc/etcd ]; then mkdir -p /etc/etcd; fi
if [ -d /var/lib/etcd ]; then mkdir -p /var/lib/etcd; fi
if [ -d ${NODE_WORK_DIR} ]; then mkdir -p ${NODE_WORK_DIR}; fi

if [ -f ${NODE_WORK_DIR}/etcd-v${ETCD_VERSION}-linux-amd64.tar.gz ]; then
  wget -q --show-progress --https-only --timestamping \
    "https://github.com/coreos/etcd/releases/download/v${ETCD_VERSION}/etcd-v${ETCD_VERSION}-linux-amd64.tar.gz" -O ${NODE_WORK_DIR}/etcd-v${ETCD_VERSION}-linux-amd64.tar.gz
fi

if [ -d ${NODE_WORK_DIR}/etcd-v${ETCD_VERSION} ]; then
  mkdir -p ${NODE_WORK_DIR}/etcd-v${ETCD_VERSION}/
  tar -xvf ${NODE_WORK_DIR}/etcd-v${ETCD_VERSION}-linux-amd64.tar.gz ${NODE_WORK_DIR}/etcd-v${ETCD_VERSION}/
fi

if [ "$(systemctl status etcd.service | grep running)" == "" ]; then
  if [ -f /usr/local/bin/etcd ]; then rm -f /usr/local/bin/etcd; fi
  if [ -f /usr/local/bin/etcdctl ]; then rm -f /usr/local/bin/etcdctl; fi
  ln -s ${NODE_WORK_DIR}/etcd-v${ETCD_VERSION}/etcd /usr/local/bin/etcd
  ln -s ${NODE_WORK_DIR}/etcd-v${ETCD_VERSION}/etcdctl /usr/local/bin/etcdctl

  ETCD_NAME=etcd-$(hostname)

  cat << EOF | tee /etc/systemd/system/etcd.service
[Unit]
Description=etcd
Documentation=https://github.com/coreos

[Service]
ExecStart=/usr/local/bin/etcd \\
  --name ${ETCD_NAME} \\
  --cert-file=${CERTS_AND_CONFIGS_DIR}/kubernetes.pem \\
  --key-file=${CERTS_AND_CONFIGS_DIR}/kubernetes-key.pem \\
  --peer-cert-file=${CERTS_AND_CONFIGS_DIR}/kubernetes.pem \\
  --peer-key-file=${CERTS_AND_CONFIGS_DIR}/kubernetes-key.pem \\
  --trusted-ca-file=${CERTS_AND_CONFIGS_DIR}/ca.pem \\
  --peer-trusted-ca-file=${CERTS_AND_CONFIGS_DIR}/ca.pem \\
  --peer-client-cert-auth \\
  --client-cert-auth \\
  --initial-advertise-peer-urls https://${INTERNAL_IP}:${PEER_PORT} \\
  --listen-peer-urls https://${INTERNAL_IP}:${PEER_PORT} \\
  --listen-client-urls https://${INTERNAL_IP}:${CLIENT_PORT},https://127.0.0.1:${CLIENT_PORT} \\
  --advertise-client-urls https://${INTERNAL_IP}:${CLIENT_PORT} \\
  --initial-cluster-token ${CLUSTER_TOKEN} \\
  --initial-cluster ${INITIAL_CLUSTER} \\
  --initial-cluster-state new \\
  --data-dir=${ETC_DATA_DIR}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable etcd
  systemctl start etcd
  systemctl status etcd
fi

if [ ! -f /usr/local/bin/etcdctl ]; then
  echo "installation of etcd v${ETCD_VERSION} failed. /usr/local/bin/etcdctl is missing."
  exit 1
else
  # verify its working correctly
  API_STARTED=$(ETCDCTL_API=3 etcdctl member list --endpoints=https://127.0.0.1:${CLIENT_PORT} \
    --cacert=${CERTS_AND_CONFIGS_DIR}/ca.pem \
    --cert=${CERTS_AND_CONFIGS_DIR}/kubernetes.pem \
    --key=${CERTS_AND_CONFIGS_DIR}/kubernetes-key.pem \
    | grep started)
  if [ "${API_STARTED}" == "" ]; then
    echo "installation of etcd v${ETCD_VERSION} failed. API did not start."
    exit 1
  else
    echo "installation of etcd v${ETCD_VERSION} successful."
fi
