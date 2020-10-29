#/!bin/bash

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

source ${DIR}/../utils/env-variables "$@"

INITIAL_CLUSTER=''
INTERNAL_IP=''
IGNORED_ARGS=''
for key in ${REMARGS_ARRAY[@]} ; do
  case "$key" in
    -ip=*|--internal-ip=*)
    INTERNAL_IP="${key#*=}"
    ;;
    -cmu=*|--cluster-member-uri=*)
    cmu_name_ip=($(echo "${key#*=}" | tr "," "\n"))
    INITIAL_CLUSTER="${INITIAL_CLUSTER},${cmu_name_ip[0]}=https://${cmu_name_ip[1]}:${ETCD_PEER_PORT}"
    ;;
    *)
    IGNORED_ARGS="${IGNORED_ARGS} $key"
    ;;
  esac
done
if [ "${DEBUG}" = true ]; then echo "[DEBUG]: ignored args: ${IGNORED_ARGS}" ; fi

# TODO check for essential args and exit if not specified

if [ "$(wget --help | grep 'command not found')" ]; then
  apt-get install -y wget
fi
if [ "$(tar --help | grep 'command not found')" ]; then
  apt-get install -y tar
fi

CERTS_AND_CONFIGS_DIR=${NODE_WORK_DIR}/certs_and_configs
ETCD_DATA_DIR=${NODE_WORK_DIR}/etcd_data

# add this controller to the initial cluster list
INITIAL_CLUSTER="$(hostname)=https://${INTERNAL_IP}:${ETCD_PEER_PORT}${INITIAL_CLUSTER}"

if [ ! -d /etc/etcd ]; then mkdir -p /etc/etcd; fi
if [ ! -d /var/lib/etcd ]; then mkdir -p /var/lib/etcd; fi
if [ ! -d ${NODE_WORK_DIR} ]; then mkdir -p ${NODE_WORK_DIR}; fi

if [ ! -f ${NODE_WORK_DIR}/etcd-v${ETCD_VERSION}-linux-amd64.tar.gz ]; then
  if ! (dpkg -s ca-certificates); then apt-get install -y ca-certificates; fi
  wget -q --show-progress --https-only --timestamping \
    "https://github.com/etcd-io/etcd/releases/download/v${ETCD_VERSION}/etcd-v${ETCD_VERSION}-linux-amd64.tar.gz" -O ${NODE_WORK_DIR}/etcd-v${ETCD_VERSION}-linux-amd64.tar.gz
fi

if [ ! -d ${NODE_WORK_DIR}/etcd-v${ETCD_VERSION} ]; then
  tar -xvzf ${NODE_WORK_DIR}/etcd-v${ETCD_VERSION}-linux-amd64.tar.gz -C ${NODE_WORK_DIR}/
  mv ${NODE_WORK_DIR}/etcd-v${ETCD_VERSION}-linux-amd64 ${NODE_WORK_DIR}/etcd-v${ETCD_VERSION}
fi

if [ "$(systemctl status etcd.service | grep running)" = "" ] || [ "${FORCE_UPDATE}" = true ]; then
  if [ -f /usr/local/bin/etcd ]; then rm -f /usr/local/bin/etcd; fi
  if [ -f /usr/local/bin/etcdctl ]; then rm -f /usr/local/bin/etcdctl; fi
  ln -s ${NODE_WORK_DIR}/etcd-v${ETCD_VERSION}/etcd /usr/local/bin/etcd
  ln -s ${NODE_WORK_DIR}/etcd-v${ETCD_VERSION}/etcdctl /usr/local/bin/etcdctl

  # TODO document why this needs to be equal to the hostname
  ETCD_NAME=$(hostname)

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
  --initial-advertise-peer-urls https://${INTERNAL_IP}:${ETCD_PEER_PORT} \\
  --listen-peer-urls https://${INTERNAL_IP}:${ETCD_PEER_PORT} \\
  --listen-client-urls https://${INTERNAL_IP}:${ETCD_CLIENT_PORT},https://127.0.0.1:${ETCD_CLIENT_PORT} \\
  --advertise-client-urls https://${INTERNAL_IP}:${ETCD_CLIENT_PORT} \\
  --initial-cluster-token ${ETCD_CLUSTER_TOKEN} \\
  --initial-cluster ${INITIAL_CLUSTER} \\
  --initial-cluster-state new \\
  --data-dir=${ETCD_DATA_DIR}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable etcd
  if [ "${FORCE_UPDATE}" = true ]; then
    systemctl stop etcd
  fi
  systemctl start etcd
  systemctl status etcd
fi

if [ ! -f /usr/local/bin/etcdctl ]; then
  echo "installation of etcd v${ETCD_VERSION} failed. /usr/local/bin/etcdctl is missing."
  exit 1
else
  # TODO verify etcd version
  # verify its working correctly
  API_STARTED=$(ETCDCTL_API=3 etcdctl member list --endpoints=https://127.0.0.1:${ETCD_CLIENT_PORT} \
    --cacert=${CERTS_AND_CONFIGS_DIR}/ca.pem \
    --cert=${CERTS_AND_CONFIGS_DIR}/kubernetes.pem \
    --key=${CERTS_AND_CONFIGS_DIR}/kubernetes-key.pem \
    | grep started)
  if [ "${API_STARTED}" = "" ]; then
    echo "installation of etcd v${ETCD_VERSION} failed. API did not start."
    exit 1
  else
    echo "installation of etcd v${ETCD_VERSION} successful."
  fi
fi

# TODO check performance using:
#  etcdctl --cacert=ca.pem --cert=kubernetes.pem --key=kubernetes-key.pem del --prefix /etcdctl-check-perf/
#  etcdctl --cacert=ca.pem --cert=kubernetes.pem --key=kubernetes-key.pem check perf --load='s' | grep FAIL != ""
#  etcdctl --cacert=ca.pem --cert=kubernetes.pem --key=kubernetes-key.pem del --prefix /etcdctl-check-perf/
#  etcdctl --cacert=ca.pem --cert=kubernetes.pem --key=kubernetes-key.pem check perf --load='xl' | grep FAIL != ""
