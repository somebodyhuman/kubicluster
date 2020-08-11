#/!bin/bash

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

source ${DIR}/utils/env-variables

function update_scripts_in_nodes() {
  # TODO only update worker scripts
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
  for node in ${NODES}; do
    name_ip=($(echo $node | tr "=" "\n"))
    CERTS="${CERTS_AND_CONFIGS_DIR}/${name_ip[0]}.pem ${CERTS_AND_CONFIGS_DIR}/${name_ip[0]}-key.pem"
    for cert in "$@"; do CERTS="${CERTS} ${CERTS_AND_CONFIGS_DIR}/${cert}.pem" ; done
    echo "updating certs: ${name_ip[0]} $@"

    ${SSH_CMD} root@${name_ip[1]} "if [ ! -d ${NODE_CERTS_AND_CONFIGS_DIR} ]; then mkdir -p ${NODE_CERTS_AND_CONFIGS_DIR}; fi"
    ${SCP_CMD} ${CERTS} root@${name_ip[1]}:${NODE_CERTS_AND_CONFIGS_DIR}
  done
}

function update_configs() {
  for node in ${NODES}; do
    name_ip=($(echo $node | tr "=" "\n"))

    CONFIGS="${CERTS_AND_CONFIGS_DIR}/${name_ip[0]}.kubeconfig"
    for config in "$@"; do CONFIGS="${CONFIGS} ${CERTS_AND_CONFIGS_DIR}/${config}" ; done
    echo "updating configs: ${name_ip[0]} $@"

    ${SSH_CMD} root@${name_ip[1]} "if [ ! -d ${NODE_CERTS_AND_CONFIGS_DIR} ]; then mkdir -p ${NODE_CERTS_AND_CONFIGS_DIR}; fi"
    ${SCP_CMD} ${CONFIGS} root@${name_ip[1]}:${NODE_CERTS_AND_CONFIGS_DIR}
  done
}

function install_kata() {
  for node in ${NODES}; do
    name_ip=($(echo $node | tr "=" "\n"))

    ${SSH_CMD} root@${name_ip[1]} "${NODE_SCRIPTS_DIR}/worker/setup_kata.sh"
  done
}

function install_runc() {
  RUNC_VERSION='1.0.0-rc91'
  FORCE_UPDATE=false
  while [[ $# -gt 0 ]]; do
      key="$1"
      echo $key
      case "$key" in
        -rv=*|--runc-version=*)
        RUNC_VERSION="${key#*=}"
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
  if [ "${FORCE_UPDATE}" = true ]; then PARAMS="${PARAMS} -f"; fi
  CONTROLLER_PARAMS="${PARAMS}"
  if [ "${RUNC_VERSION}" != "1.3.6" ]; then PARAMS="${PARAMS} -v=${RUNC_VERSION}"; fi

  for node in ${NODES}; do
    name_ip=($(echo $node | tr "=" "\n"))

    ${SSH_CMD} root@${name_ip[1]} "${NODE_SCRIPTS_DIR}/worker/setup_runc.sh -nwd=${NODE_WORK_DIR}${PARAMS}"
  done

  EXEC_ON_ONE_CONTROLLER=false
  for cmu in ${CONTROLLERS}; do
    cmu_name_ip=($(echo $cmu | tr "=" "\n"))
    if [ "${EXEC_ON_ONE_CONTROLLER}" = false ]; then
      # TODO force redeployment with -frd / --force-redeployment
      # kubectl delete daemonset calico-node -n kube-system
      # kubectl delete deployment calico-kube-controllers -n kube-system
      ${SSH_CMD} root@${cmu_name_ip[1]} "${NODE_SCRIPTS_DIR}/controller/setup_runc.sh -nwd=${NODE_WORK_DIR} ${ETCD_CLUSTER_MEMBERS}${CONTROLLER_PARAMS}"
      EXEC_ON_ONE_CONTROLLER=true
    fi
  done
}

function install_containerd() {
  CONTAINERD_VERSION='1.3.6'
  FORCE_UPDATE=false
  while [[ $# -gt 0 ]]; do
      key="$1"
      echo $key
      case "$key" in
        -cv=*|--containerd-version=*)
        CONTAINERD_VERSION="${key#*=}"
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
  if [ "${CONTAINERD_VERSION}" != "1.3.6" ]; then PARAMS="${PARAMS} -v=${CONTAINERD_VERSION}"; fi
  if [ "${FORCE_UPDATE}" = true ]; then PARAMS="${PARAMS} -f"; fi

  for node in ${NODES}; do
    name_ip=($(echo $node | tr "=" "\n"))

    ${SSH_CMD} root@${name_ip[1]} "${NODE_SCRIPTS_DIR}/worker/setup_containerd.sh -nwd=${NODE_WORK_DIR}${PARAMS}"
  done
}

function install_kubernetes_worker() {
  KUBERNETES_VERSION='1.18.5'
  FORCE_UPDATE=false
  while [[ $# -gt 0 ]]; do
      key="$1"
      echo $key
      case "$key" in
        -v=*|--version=*)
        KUBERNETES_VERSION="${key#*=}"
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
  if [ "${KUBERNETES_VERSION}" != "1.18.5" ]; then PARAMS="${PARAMS} -v=${KUBERNETES_VERSION}"; fi
  if [ "${FORCE_UPDATE}" = true ]; then PARAMS="${PARAMS} -f"; fi

  for node in ${NODES}; do
    name_ip=($(echo $node | tr "=" "\n"))

    ${SSH_CMD} root@${name_ip[1]} "${NODE_SCRIPTS_DIR}/worker/setup_kubernetes_worker.sh -nwd=${NODE_WORK_DIR}${PARAMS}"
  done
}

function install_cni_calico() {
  # TODO move all the defaults from functions and scripts into env-variable (otherwise it's annoying to maintain changes to those defaults because the will need to be changed in several places)
  CLIENT_PORT=2379
  FORCE_UPDATE=false
  CALICO_USER='calico-cni'
  CALICO_VERSION='3.11.3'
  KUBERNETES_VERSION='1.18.5'
  while [[ $# -gt 0 ]]; do
      key="$1"
      echo $key
      case "$key" in
        -cp=*|--client-port=*)
        CLIENT_PORT="${key#*=}"
        ;;
        -u=*|--user=*)
        CALICO_USER="${key#*=}"
        ;;
        -v=*|--version=*)
        KUBERNETES_VERSION="${key#*=}"
        ;;
        -clv=*|--calico-version=*)
        CALICO_VERSION="${key#*=}"
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
  if [ "${FORCE_UPDATE}" = true ]; then PARAMS="${PARAMS} -f"; fi
  CONTROLLER_PARAMS="${PARAMS}"
  # if [ "${CALICO_USER}" != "calico-cni" ]; then CONTROLLER_PARAMS="${CONTROLLER_PARAMS} -u=${CALICO_USER}"; fi
  if [ "${KUBERNETES_VERSION}" != "1.18.5" ]; then CONTROLLER_PARAMS="${CONTROLLER_PARAMS} -v=${KUBERNETES_VERSION}"; fi

  if [ "${CALICO_VERSION}" != "calico-cni" ]; then PARAMS="${PARAMS} -v=${CALICO_VERSION}"; fi

  ETCD_CLUSTER_MEMBERS=''
  for cmu in ${CONTROLLERS}; do
    cmu_name_ip=($(echo $cmu | tr "=" "\n"))
    ETCD_CLUSTER_MEMBERS="$ETCD_CLUSTER_MEMBERS -cmu=https://${cmu_name_ip[1]}:${CLIENT_PORT}"
  done

  for node in ${NODES}; do
    name_ip=($(echo $node | tr "=" "\n"))

    ${SSH_CMD} root@${name_ip[1]} "${NODE_SCRIPTS_DIR}/worker/setup_cni_calico.sh -nwd=${NODE_WORK_DIR}${PARAMS}"
  done

  EXEC_ON_ONE_CONTROLLER=false
  for cmu in ${CONTROLLERS}; do
    cmu_name_ip=($(echo $cmu | tr "=" "\n"))
    if [ "${EXEC_ON_ONE_CONTROLLER}" = false ]; then
      # TODO force redeployment with -frd / --force-redeployment
      # kubectl delete daemonset calico-node -n kube-system
      # kubectl delete deployment calico-kube-controllers -n kube-system
      ${SSH_CMD} root@${cmu_name_ip[1]} "${NODE_SCRIPTS_DIR}/controller/setup_cni_calico_typha.sh -nwd=${NODE_WORK_DIR} ${ETCD_CLUSTER_MEMBERS}${CONTROLLER_PARAMS}"
      EXEC_ON_ONE_CONTROLLER=true
    fi
  done
}

REMAINING_ARGS=''
CONTROLLERS='' ; NODES=''
CLUSTER_NAME='kubicluster'
# PEER_PORT=2380
# As long as there is at least one more argument, keep looping
while [[ $# -gt 0 ]]; do
    key="$1"
    case "$key" in
        -cl=*|--cluster=*)
        CLUSTER_NAME="${key#*=}"
        ;;
        -c|--controller-node)
        shift # past the key and to the value
        CONTROLLERS="${CONTROLLERS} $1"
        ;;
        -n|--worker-node)
        shift # past the key and to the value
        NODES="${NODES} $1"
        ;;
        *)
        PL=' ' ; if [ "${REMAINING_ARGS}" = "" ]; then PL=''; fi
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
  install_kata)
    install_kata
    ;;
  install_runc)
    install_runc "${RARGS_ARRAY[@]:1}"
    ;;
  install_containerd)
    install_containerd "${RARGS_ARRAY[@]:1}"
    ;;
  install_kubernetes_worker)
    install_kubernetes_worker "${RARGS_ARRAY[@]:1}"
    ;;
  install_cni_calico)
    install_cni_calico "${RARGS_ARRAY[@]:1}"
    ;;
  help)
    # TODO improve documentation
    echo "Usage: $0 {[WORKDIR='./work'] [update_scripts_in_node|update_certs|update_configs|install_kata|install_containerd|install_kubernetes_worker]}"
    ;;
  *)
    update_scripts_in_nodes
    # TODO check for -cip/--controller-ip and exit if not specified
    update_certs ca calico-cni calico-cni-key
    update_configs kube-proxy.kubeconfig calico-cni.kubeconfig
    install_kata
    install_runc "${RARGS_ARRAY[@]}"
    install_containerd "${RARGS_ARRAY[@]}"
    install_kubernetes_worker "${RARGS_ARRAY[@]}"
    install_cni_calico "${RARGS_ARRAY[@]}"
    ;;
esac
