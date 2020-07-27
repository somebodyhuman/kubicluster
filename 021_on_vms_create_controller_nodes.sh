#/!bin/bash

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

source ${DIR}/utils/env-variables

########################
# Distributing the Certificate File

SCRIPTS='scripts'
SCRIPTS_DIR="./${SCRIPTS}"

## on node
NODE_WORK_DIR=/opt/kubicluster
NODE_SCRIPTS_DIR=${NODE_WORK_DIR}/${SCRIPTS}
ETCD_DATA_DIR=${NODE_WORK_DIR}/etcd_data

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
  if [ "$FORCE_ETCD_DATA_RESET" = true ]; then echo "INFO: etcd data reset enforced if encryption-config.yaml is different"; fi

  CONFIGS=''
  PERFORM_ETCD_DATA_RESET=false
  ${DIR}/utils/workdir ensure_certs_and_configs_mirror_dir_exists

  for config in "$@"; do
    if [ "${config}" != "encryption-config.yaml" ]; then
      CONFIGS="${CONFIGS} ${CERTS_AND_CONFIGS_DIR}/${config}"
    else
      # the following block ensures that the encryption-config.yaml is only updated
      # IF it does not exist yet on all controller nodes
      # OR if an etcd data reset is forced
      DIFFERS_ON='' ; SAME_ON='' ; NOT_YET_ON=''
      for node in ${NODES}; do
        name_ip=($(echo $node | tr "=" "\n"))
        if [ -d ${CERTS_AND_CONFIGS_MIRROR_DIR}/${name_ip[0]} ]; then rm -rf ${CERTS_AND_CONFIGS_MIRROR_DIR}/${name_ip[0]}; fi
        mkdir -p ${CERTS_AND_CONFIGS_MIRROR_DIR}/${name_ip[0]}
        ${SCP_CMD} root@${name_ip[1]}:${NODE_WORK_DIR}/${CERTS_AND_CONFIGS}/${config} ${CERTS_AND_CONFIGS_MIRROR_DIR}/${name_ip[0]}/${config}

        if [ -e ${CERTS_AND_CONFIGS_MIRROR_DIR}/${name_ip[0]}/${config} ]; then
          if ! diff ${CERTS_AND_CONFIGS_MIRROR_DIR}/${name_ip[0]}/${config} ${CERTS_AND_CONFIGS_DIR}/${config}; then
            PL=', ' ; if [ "${DIFFERS_ON}" == "" ]; then PL=''; fi
            DIFFERS_ON="${DIFFERS_ON}${PL}${node}"
          else
            PL=', ' ; if [ "${SAME_ON}" == "" ]; then PL=''; fi
            SAME_ON="${SAME_ON}${PL}${node}"
          fi
        else
          PL=', ' ; if [ "${NOT_YET_ON}" == "" ]; then PL=''; fi
          NOT_YET_ON="${NOT_YET_ON}${PL}${node}"
        fi
      done

      if [ "${NOT_YET_ON}" != "" ]; then echo "encryption-config.yaml not yet on ${NOT_YET_ON}"; fi
      if [ "${SAME_ON}" != "" ]; then echo "encryption-config.yaml is the same on ${SAME_ON}"; fi
      if [ "${DIFFERS_ON}" != "" ]; then echo "encryption-config.yaml differs on ${SAME_ON}"; fi
      if [ "${DIFFERS_ON}" != "" ] || [ "${NOT_YET_ON}" != "" ]; then
        if [ ! "${FORCE_ETCD_DATA_RESET}" = true ]; then
          echo "WARN: -fedr/--fore-etcd-data-reset is not set, so encryption-config.yaml state is not changed on any node. Re-run with -fedr or resolve manually before re-running withou -fedr."
        else
          echo "INFO: -fedr/--fore-etcd-data-reset IS SET. Clearing data directories on nodes and forcing update of encryption-config.yaml on all nodes."
          PERFORM_ETCD_DATA_RESET=true
          CONFIGS="${CONFIGS} ${CERTS_AND_CONFIGS_DIR}/${config}"
        fi
      fi
    fi
  done

  for node in ${NODES}; do
    name_ip=($(echo $node | tr "=" "\n"))
    ${SSH_CMD} root@${name_ip[1]} "if [ ! -d ${NODE_WORK_DIR}/${CERTS_AND_CONFIGS} ]; then mkdir -p ${NODE_WORK_DIR}/${CERTS_AND_CONFIGS}; fi"
    if [ "${PERFORM_ETCD_DATA_RESET}" = true ]; then
      echo "INFO: performing etcd data reset on ${name_ip[0]}"
      ${SSH_CMD} root@${name_ip[1]} "if systemctl is-active etcd.service; then systemctl stop etcd.service; fi ; if [ -d ${ETCD_DATA_DIR} ]; then rm -rf ${ETCD_DATA_DIR}; fi"
    fi
    if [ "${CONFIGS}" != "" ]; then
      ${SCP_CMD} ${CONFIGS} root@${name_ip[1]}:${NODE_WORK_DIR}/${CERTS_AND_CONFIGS}
    fi
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

function install_kubernetes_controller() {
  CLIENT_PORT=2379
  FORCE_UPDATE=false
  while [[ $# -gt 0 ]]; do
      key="$1"
      echo $key
      case "$key" in
        -cp=*|--client-port=*)
        CLIENT_PORT="${key#*=}"
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
  if [ "${CLIENT_PORT}" != "2379" ]; then PARAMS="${PARAMS} -cp=${CLIENT_PORT}"; fi
  if [ "${CLUSTER_NAME}" != "kubicluster" ]; then PARAMS="${PARAMS} -cl=${CLUSTER_NAME}"; fi
  if [ "${FORCE_UPDATE}" = true ]; then PARAMS="${PARAMS} -f"; fi

  for node in ${NODES}; do
    name_ip=($(echo $node | tr "=" "\n"))
    ETCD_CLUSTER_MEMBERS=''
    for cmu in ${NODES}; do
      # if [ "${cmu}" != "${node}" ]; then
        cmu_name_ip=($(echo $cmu | tr "=" "\n"))
        ETCD_CLUSTER_MEMBERS="$ETCD_CLUSTER_MEMBERS -cmu=https://${cmu_name_ip[1]}:${CLIENT_PORT}"
      # fi
    done

    ${SSH_CMD} root@${name_ip[1]} "${NODE_SCRIPTS_DIR}/controller/setup_kubernetes_controller.sh -nwd=${NODE_WORK_DIR} -ip=${name_ip[1]} ${ETCD_CLUSTER_MEMBERS}${PARAMS}"
  done
}

REMAINING_ARGS=''
NODES=''
CLUSTER_NAME='kubicluster'
PEER_PORT=2380
FORCE_ETCD_DATA_RESET=false
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
        -fedr|--force-etcd-data-reset)
        FORCE_ETCD_DATA_RESET=true
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
  install_kubernetes_controller)
    # TODO check for essential args and exit if not specified
    install_kubernetes_controller "${RARGS_ARRAY[@]:1}"
    ;;
  help)
    # TODO improve documentation
    echo "Usage: $0 {[WORKDIR='./work'] [update_scripts_in_node|update_certs|update_configs|install_etcd|install_kubernetes_controller]}"
    ;;
  *)
    update_scripts_in_nodes
    # TODO check for -cip/--controller-ip and exit if not specified
    update_certs ca kubernetes service-accounts
    update_configs admin.kubeconfig kube-controller-manager.kubeconfig kube-scheduler.kubeconfig encryption-config.yaml
    install_etcd "${RARGS_ARRAY[@]}"
    install_kubernetes_controller "${RARGS_ARRAY[@]}"
    ;;
esac
