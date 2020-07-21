#/!bin/bash

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

source ${DIR}/utils/env-variables

########################
# Distributing the Certificate File

TEMPLATE_ROOT_SSH_KEY=${IMAGES_DIR}/vm-template_rsa
TIMEOUT_IN_SEC=10
SSH_OPTS="-i ${TEMPLATE_ROOT_SSH_KEY} -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o ConnectionAttempts=1 -o ConnectTimeout=${TIMEOUT_IN_SEC}"
SSH_CMD="ssh ${SSH_OPTS}"
SCP_CMD="scp ${SSH_OPTS}"

SCRIPTS='scripts'
SCRIPTS_DIR="./${SCRIPTS}"

## on node
NODE_WORK_DIR=/opt/kubicluster
NODE_SCRIPTS_DIR=${NODE_WORK_DIR}/${SCRIPTS}

function update_scripts_in_nodes() {
  for node in ${NODES}; do
    name_ip=($(echo $node | tr "=" "\n"))
    echo "syncing scripts dir to node ${name_ip[0]}"
    ${SSH_CMD} root@${name_ip[1]} "if [ ! -d ${NODE_SCRIPTS_DIR} ]; then mkdir -p ${NODE_SCRIPTS_DIR}; fi"
    ${SSH_CMD} root@${name_ip[1]} "if [ ! -f /usr/bin/rsync ]; then apt-get install -y rsync; fi"
    echo ${RSYNC_CMD}
    rsync -e "${SSH_CMD}" -av --no-owner --no-group ${SCRIPTS_DIR}/* root@${name_ip[1]}:${NODE_SCRIPTS_DIR}

  done
}

function update_certs() {
  CERTS=''
  echo "$@"
  for cert in "$@"; do CERTS="${CERTS} ${CERTS_AND_CONFIGS_DIR}/${cert}.pem ${CERTS_AND_CONFIGS_DIR}/${cert}-key.pem" ; done
  echo "$CERTS"
  for node in ${NODES}; do
    name_ip=($(echo $node | tr "=" "\n"))
    ${SSH_CMD} root@${name_ip[1]} "if [ ! -d ${NODE_WORK_DIR}/${CERTS_AND_CONFIGS} ]; then mkdir -p ${NODE_WORK_DIR}/${CERTS_AND_CONFIGS}; fi"
    ${SCP_CMD} ${CERTS} root@${name_ip[1]}:${NODE_WORK_DIR}/${CERTS_AND_CONFIGS}
  done
}

function update_configs() {
  CONFIGS=''
  for config in "$@"; do CONFIGS="${CECONFIGSRTS} ${CERTS_AND_CONFIGS_DIR}/${config}" ; done

  for node in ${NODES}; do
    name_ip=($(echo $node | tr "=" "\n"))
    ${SSH_CMD} root@${name_ip[1]} "if [ ! -d ${NODE_WORK_DIR}/${CERTS_AND_CONFIGS} ]; then mkdir -p ${NODE_WORK_DIR}/${CERTS_AND_CONFIGS}; fi"
    ${SCP_CMD} ${CONFIGS} root@${name_ip[1]}:${NODE_WORK_DIR}/${CERTS_AND_CONFIGS}
  done
}

function install_etcd() {
  CLIENT_PORT=2379
  PEER_PORT=2380
  CLUSTER_TOKEN=''
  ETCD_VERSION=''
  FORCE_UPDATE=false
  while [[ $# -gt 0 ]]; do
      key="$1"
      echo $key
      case "$key" in
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
        -f|--force-update)
        FORCE_UPDATE=true
        ;;
        *)
        # do nothing
        ;;
      esac
      # Shift after checking all the cases to get the next option
      shift
  done

  PARAMS=''
  if [ "${PEER_PORT}" != "2380" ]; then PARAMS="${PARAMS} -pp=${PEER_PORT}"; fi
  if [ "${CLIENT_PORT}" != "2379" ]; then PARAMS="${PARAMS} -cp=${CLIENT_PORT}"; fi
  if [ "${CLUSTER_TOKEN}" != "" ]; then PARAMS="${PARAMS} -t=${CLUSTER_TOKEN}"; fi
  if [ "${ETCD_VERSION}" != "" ]; then PARAMS="${PARAMS} -ev=${ETCD_VERSION}"; fi
  if [ "${FORCE_UPDATE}" = true ]; then PARAMS="${PARAMS} -f"; fi

  for node in ${NODES}; do
    name_ip=($(echo $node | tr "=" "\n"))
    CLUSTER_MEMBERS=''
    for cmu in ${NODES}; do
      if [ "${cmu}" != "${node}" ]; then
        cmu_name_ip=($(echo $cmu | tr "=" "\n"))
        CLUSTER_MEMBERS="$CLUSTER_MEMBERS -cmu=${cmu_name_ip[1]}:${PEER_PORT}"
      fi
    done

    ${SSH_CMD} root@${name_ip[1]} "${NODE_SCRIPTS_DIR}/controller/setup_etcd.sh -nwd=${NODE_WORK_DIR} -ip=${name_ip[1]} ${CLUSTER_MEMBERS}${PARAMS}"
  done
}

REMAINING_ARGS=''
NODES=''
CLUSTER_NAME='kubicluster'
PEER_PORT=2380
# As long as there is at least one more argument, keep looping
while [[ $# -gt 0 ]]; do
    key="$1"
    case "$key" in
        -cl=*|--cluster=*)
        CLUSTER_NAME="${key#*=}"
        ;;
        -c|--controller-node)
        shift # past the key and to the value
        NODES="${NODES} $1"
        ;;
        -pp=*|--peer-port=*)
        PEER_PORT="${key#*=}"
        ;;
        *)
        PL=' ' ; if [ "${REMAINING_ARGS}" == "" ]; then PL=''; fi
        REMAINING_ARGS="${REMAINING_ARGS}${PL}$key"
        ;;
    esac
    # Shift after checking all the cases to get the next option
    shift
done

RARGS_ARRAY=($(echo $REMAINING_ARGS | tr " " "\n"))
echo "running: ${RARGS_ARRAY[0]}"
case "${RARGS_ARRAY[0]}" in
  'update_scripts_in_nodes')
    update_scripts_in_nodes
    ;;
  update_certs)
    update_certs "${RARGS_ARRAY[@]:1}"
    ;;
  update_configs)
    # TODO check for -cip/--controller-ip and exit if not specified
    update_configs "${RARGS_ARRAY[@]:1}"
    ;;
  install_etcd)
    # TODO check for essential args and exit if not specified
    install_etcd "${RARGS_ARRAY[@]:1}"
    ;;
  help)
    # TODO improve documentation
    echo "Usage: $0 {[WORKDIR='./work'] [update_scripts_in_node|update_certs|update_configs|install_etcd]}"
    ;;
  *)
    update_scripts_in_nodes
    # TODO check for -cip/--controller-ip and exit if not specified
    # TODO check for -n/--node and exit if not specified
    update_certs ca kubernetes service-account
    update_configs admin.kubeconfig kube-controller-manager.kubeconfig kube-scheduler.kubeconfig encryption-config.yaml
    install_etcd "${RARGS_ARRAY[@]}"
    ;;
esac
