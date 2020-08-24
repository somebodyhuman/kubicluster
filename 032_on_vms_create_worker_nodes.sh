#/!bin/bash

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

function update_scripts_in_nodes() {
  # TODO only update worker scripts
  for node in ${WORKERS}; do
    name_ip=($(echo $node | tr "," "\n"))
    echo "syncing scripts dir to node ${name_ip[0]}"
    ${SSH_CMD} root@${name_ip[1]} "if [ ! -d ${NODE_SCRIPTS_DIR} ]; then mkdir -p ${NODE_SCRIPTS_DIR}; fi"
    ${SSH_CMD} root@${name_ip[1]} "if [ ! -f /usr/bin/rsync ]; then apt-get install -y rsync; fi"
    echo ${RSYNC_CMD}
    rsync -e "${SSH_CMD}" -av --no-owner --no-group ${SCRIPTS_DIR}/* root@${name_ip[1]}:${NODE_SCRIPTS_DIR}
  done
}

function update_certs() {
  CERTS=''
  for node in ${WORKERS}; do
    name_ip=($(echo $node | tr "," "\n"))
    CERTS="${CERTS_AND_CONFIGS_DIR}/${name_ip[0]}.pem ${CERTS_AND_CONFIGS_DIR}/${name_ip[0]}-key.pem"
    for cert in "$@"; do CERTS="${CERTS} ${CERTS_AND_CONFIGS_DIR}/${cert}.pem" ; done
    echo "updating certs: ${name_ip[0]} $@"

    ${SSH_CMD} root@${name_ip[1]} "if [ ! -d ${NODE_CERTS_AND_CONFIGS_DIR} ]; then mkdir -p ${NODE_CERTS_AND_CONFIGS_DIR}; fi"
    ${SCP_CMD} ${CERTS} root@${name_ip[1]}:${NODE_CERTS_AND_CONFIGS_DIR}
  done
}

function update_configs() {
  for node in ${WORKERS}; do
    name_ip=($(echo $node | tr "," "\n"))

    CONFIGS="${CERTS_AND_CONFIGS_DIR}/${name_ip[0]}.kubeconfig"
    for config in "$@"; do CONFIGS="${CONFIGS} ${CERTS_AND_CONFIGS_DIR}/${config}" ; done
    echo "updating configs: ${name_ip[0]} $@"

    ${SSH_CMD} root@${name_ip[1]} "if [ ! -d ${NODE_CERTS_AND_CONFIGS_DIR} ]; then mkdir -p ${NODE_CERTS_AND_CONFIGS_DIR}; fi"
    ${SCP_CMD} ${CONFIGS} root@${name_ip[1]}:${NODE_CERTS_AND_CONFIGS_DIR}
  done
}

function install_kata() {
  for node in ${WORKERS}; do
    name_ip=($(echo $node | tr "," "\n"))

    ${SSH_CMD} root@${name_ip[1]} "${NODE_SCRIPTS_DIR}/worker/setup_kata.sh ${NODE_ARGS}"
  done
}

function install_runc() {
  # PARAMS=''
  # if [ "${FORCE_UPDATE}" = true ]; then PARAMS="${PARAMS} -f"; fi
  # CONTROLLER_PARAMS="${PARAMS}"
  # if [ "${RUNC_VERSION}" != "1.3.6" ]; then PARAMS="${PARAMS} -v=${RUNC_VERSION}"; fi

  for node in ${WORKERS}; do
    name_ip=($(echo $node | tr "," "\n"))

    ${SSH_CMD} root@${name_ip[1]} "bash -x ${NODE_SCRIPTS_DIR}/worker/setup_runc.sh ${NODE_ARGS}"
  done

  EXEC_ON_ONE_CONTROLLER=false
  for cmu in ${CONTROLLERS}; do
    cmu_name_ip=($(echo $cmu | tr "," "\n"))
    if [ "${EXEC_ON_ONE_CONTROLLER}" = false ]; then
      # TODO force redeployment with -frd / --force-redeployment
      # kubectl delete daemonset calico-node -n kube-system
      # kubectl delete deployment calico-kube-controllers -n kube-system
      ${SSH_CMD} root@${cmu_name_ip[1]} "${NODE_SCRIPTS_DIR}/controller/setup_runc.sh ${NODE_ARGS}"
      EXEC_ON_ONE_CONTROLLER=true
    fi
  done
}

function install_containerd() {
  # PARAMS=''
  # if [ "${CONTAINERD_VERSION}" != "1.3.6" ]; then PARAMS="${PARAMS} -v=${CONTAINERD_VERSION}"; fi
  # if [ "${FORCE_UPDATE}" = true ]; then PARAMS="${PARAMS} -f"; fi

  for node in ${WORKERS}; do
    name_ip=($(echo $node | tr "," "\n"))

    ${SSH_CMD} root@${name_ip[1]} "${NODE_SCRIPTS_DIR}/worker/setup_containerd.sh ${NODE_ARGS}"
  done
}

function install_kubernetes_worker() {
  # PARAMS=''
  # if [ "${KUBERNETES_VERSION}" != "1.18.5" ]; then PARAMS="${PARAMS} -v=${KUBERNETES_VERSION}"; fi
  # if [ "${FORCE_UPDATE}" = true ]; then PARAMS="${PARAMS} -f"; fi

  for node in ${WORKERS}; do
    name_ip=($(echo $node | tr "," "\n"))

    ${SSH_CMD} root@${name_ip[1]} "${NODE_SCRIPTS_DIR}/worker/setup_kubernetes_worker.sh ${NODE_ARGS}"
  done
}

function install_cni_calico() {
  # PARAMS=''
  # if [ "${FORCE_UPDATE}" = true ]; then PARAMS="${PARAMS} -f"; fi
  # CONTROLLER_PARAMS="${PARAMS}"
  # # if [ "${CALICO_USER}" != "calico-cni" ]; then CONTROLLER_PARAMS="${CONTROLLER_PARAMS} -u=${CALICO_USER}"; fi
  # if [ "${KUBERNETES_VERSION}" != "1.18.5" ]; then CONTROLLER_PARAMS="${CONTROLLER_PARAMS} -v=${KUBERNETES_VERSION}"; fi
  #
  # if [ "${CALICO_VERSION}" != "calico-cni" ]; then PARAMS="${PARAMS} -v=${CALICO_VERSION}"; fi

  # # TODO can be derived from -c instead of using -cmu
  # ETCD_CLUSTER_MEMBERS=''
  # for cmu in ${CONTROLLERS}; do
  #   # cmu_name_ip=($(echo $cmu | tr "," "\n"))
  #   ETCD_CLUSTER_MEMBERS="$ETCD_CLUSTER_MEMBERS -cmu=${cmu}"
  # done

  for node in ${WORKERS}; do
    name_ip=($(echo $node | tr "," "\n"))

    ${SSH_CMD} root@${name_ip[1]} "${NODE_SCRIPTS_DIR}/worker/setup_cni_calico.sh ${NODE_ARGS}"
  done

  EXEC_ON_ONE_CONTROLLER=false
  for cmu in ${CONTROLLERS}; do
    cmu_name_ip=($(echo $cmu | tr "," "\n"))
    if [ "${EXEC_ON_ONE_CONTROLLER}" = false ]; then
      # TODO force redeployment with -frd / --force-redeployment
      # kubectl delete daemonset calico-node -n kube-system
      # kubectl delete deployment calico-kube-controllers -n kube-system
      ${SSH_CMD} root@${cmu_name_ip[1]} "${NODE_SCRIPTS_DIR}/controller/setup_cni_calico_typha.sh ${NODE_ARGS}"
      EXEC_ON_ONE_CONTROLLER=true
    fi
  done
}

source ${DIR}/utils/env-variables "$@"

case "${SUB_CMD}" in
  update_scripts_in_nodes)
    update_scripts_in_nodes
    ;;
  update_certs)
    update_certs "${RARGS_ARRAY[@]}"
    ;;
  update_configs)
    # TODO check for -cip/--controller-ip and exit if not specified
    update_configs "${RARGS_ARRAY[@]}"
    ;;
  install_kata)
    install_kata
    ;;
  install_runc)
    install_runc
    ;;
  install_containerd)
    install_containerd
    ;;
  install_kubernetes_worker)
    install_kubernetes_worker
    ;;
  install_cni_calico)
    install_cni_calico
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
    install_runc
    install_containerd
    install_kubernetes_worker
    install_cni_calico
    ;;
esac
