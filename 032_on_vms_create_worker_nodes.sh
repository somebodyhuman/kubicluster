#/!bin/bash

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

function update_scripts_in_nodes() {
  # TODO only update worker scripts
  for node in ${WORKERS}; do
    name_ip=($(echo $node | tr "," "\n"))
    echo "syncing scripts dir to node ${name_ip[0]}"
    ${SSH_CMD} root@${name_ip[2]} "if [ ! -d ${NODE_SCRIPTS_DIR} ]; then mkdir -p ${NODE_SCRIPTS_DIR}; fi"
    ${SSH_CMD} root@${name_ip[2]} "if [ ! -f /usr/bin/rsync ]; then apt-get install -y rsync; fi"
    echo ${RSYNC_CMD}
    rsync -e "${SSH_CMD}" -av --no-owner --no-group ${SCRIPTS_DIR}/* root@${name_ip[2]}:${NODE_SCRIPTS_DIR}
  done
}

function update_certs() {
  CERTS=''
  for node in ${WORKERS}; do
    name_ip=($(echo $node | tr "," "\n"))
    CERTS="${CERTS_AND_CONFIGS_DIR}/${name_ip[0]}.pem ${CERTS_AND_CONFIGS_DIR}/${name_ip[0]}-key.pem"
    for cert in "$@"; do CERTS="${CERTS} ${CERTS_AND_CONFIGS_DIR}/${cert}.pem" ; done
    echo "updating certs: ${name_ip[0]} $@"

    ${SSH_CMD} root@${name_ip[2]} "if [ ! -d ${NODE_CERTS_AND_CONFIGS_DIR} ]; then mkdir -p ${NODE_CERTS_AND_CONFIGS_DIR}; fi"
    ${SCP_CMD} ${CERTS} root@${name_ip[2]}:${NODE_CERTS_AND_CONFIGS_DIR}
  done
}

function update_configs() {
  for node in ${WORKERS}; do
    name_ip=($(echo $node | tr "," "\n"))

    CONFIGS="${CERTS_AND_CONFIGS_DIR}/${name_ip[0]}.kubeconfig"
    for config in "$@"; do CONFIGS="${CONFIGS} ${CERTS_AND_CONFIGS_DIR}/${config}" ; done
    echo "updating configs: ${name_ip[0]} $@"

    ${SSH_CMD} root@${name_ip[2]} "if [ ! -d ${NODE_CERTS_AND_CONFIGS_DIR} ]; then mkdir -p ${NODE_CERTS_AND_CONFIGS_DIR}; fi"
    ${SCP_CMD} ${CONFIGS} root@${name_ip[2]}:${NODE_CERTS_AND_CONFIGS_DIR}
  done
}

function install_kata() {
  for node in ${WORKERS}; do
    name_ip=($(echo $node | tr "," "\n"))

    ${SSH_CMD} root@${name_ip[2]} "${NODE_SCRIPTS_DIR}/worker/setup_kata.sh ${NODE_ARGS}"
  done
}

function install_runc() {
  for node in ${WORKERS}; do
    name_ip=($(echo $node | tr "," "\n"))

    ${SSH_CMD} root@${name_ip[2]} "bash -x ${NODE_SCRIPTS_DIR}/worker/setup_runc.sh ${NODE_ARGS}"
  done

  EXEC_ON_ONE_CONTROLLER=false
  for cmu in ${CONTROLLERS}; do
    cmu_name_ip=($(echo $cmu | tr "," "\n"))
    if [ "${EXEC_ON_ONE_CONTROLLER}" = false ]; then
      # TODO force redeployment with -frd / --force-redeployment
      # kubectl delete daemonset calico-node -n kube-system
      # kubectl delete deployment calico-kube-controllers -n kube-system
      ${SSH_CMD} root@${cmu_name_ip[2]} "${NODE_SCRIPTS_DIR}/controller/setup_runc.sh ${NODE_ARGS}"
      EXEC_ON_ONE_CONTROLLER=true
    fi
  done
}

function install_containerd() {
  for node in ${WORKERS}; do
    name_ip=($(echo $node | tr "," "\n"))

    ${SSH_CMD} root@${name_ip[2]} "${NODE_SCRIPTS_DIR}/worker/setup_containerd.sh ${NODE_ARGS}"
  done
}

function install_kubernetes_workers() {
  for node in ${WORKERS}; do
    name_ip=($(echo $node | tr "," "\n"))

    ${SSH_CMD} root@${name_ip[2]} "${NODE_SCRIPTS_DIR}/worker/setup_kubernetes_worker.sh ${NODE_ARGS}"
  done
}

function install_cni_calico() {
  for node in ${WORKERS}; do
    name_ip=($(echo $node | tr "," "\n"))

    ${SSH_CMD} root@${name_ip[2]} "${NODE_SCRIPTS_DIR}/worker/setup_cni_calico.sh ${NODE_ARGS}"
  done

  EXEC_ON_ONE_CONTROLLER=false
  for cmu in ${CONTROLLERS}; do
    cmu_name_ip=($(echo $cmu | tr "," "\n"))
    if [ "${EXEC_ON_ONE_CONTROLLER}" = false ]; then
      # TODO force redeployment with -frd / --force-redeployment
      # kubectl delete daemonset calico-node -n kube-system
      # kubectl delete deployment calico-kube-controllers -n kube-system
      ${SSH_CMD} root@${cmu_name_ip[2]} "${NODE_SCRIPTS_DIR}/controller/setup_cni_calico_typha.sh ${NODE_ARGS}"
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
  install_kubernetes_workers)
    install_kubernetes_workers
    ;;
  install_cni_calico)
    install_cni_calico
    ;;
  help)
    echo -e "\nDefault usage:\nkubicluster create-workers [OPTIONAL_ARGUMENTS]\n\t This executes all subcommands in order"
    echo -e "\nSub-command usage via kubicluster command:\nkubicluster create-workers [update_scripts_in_nodes|update_certs|update_configs|install_kata|install_runc|isntall_containerd|install_kubernetes_workers|install_cni_calico] [OPTIONAL_ARGUMENTS]"
    echo -e "\nDirect sub-command usage:\n$0 [update_scripts_in_nodes|update_certs|update_configs|install_kata|install_runc|isntall_containerd|install_kubernetes_workers|install_cni_calico] [OPTIONAL_ARGUMENTS]"
    echo -e "\nOPTIONAL ARGUMENTS:"
    echo -e "-c kube-controller-01,192.168.24.11 -c kube-controller-02,192.168.24.12"
    echo -e "\t the controllers currently running the cluster, provide all, format always: HOSTNAME,IP"
    echo -e "\t (long: --controller-node kube-controller-01,192.168.24.11 -controller-node kube-controller-02,192.168.24.12)\n"
    echo -e "-w kube-worker-0001,192.168.24.21 -w kube-worker-0002,192.168.24.22"
    echo -e "\t the worker nodes to be added or updated, provide one ore more, format always: HOSTNAME,IP"
    echo -e "\t (long: --worker-node kube-controller-01,192.168.24.21 -worker-node kube-controller-02,192.168.24.22)\n"
    echo -e "-f|--force-update\n\t force update, caution this updates every file affected by the run command/sub-command"
    echo -e "-d|--debug\n\t show debug messages"
    #echo -e "-cp=2379|--client-port=2379\n\t custom etcd client port,\n\t should not be changed unless you have a pretty good reason to do so"
    echo -e "-kv=1.18.5|--kubernetes-version=1.18.5\n\t custom kubernetes version used on controller nodes,\n\t should ideally be the same on hypervisor on all nodes (controllers and workers)"
    echo -e "-cdv=1.3.6|--containerd-version=1.3.6\n\t custom containerd version used on worker nodes,\n\t should ideally be the same on all worker nodes"
    echo -e "-katav=1.11.2|--kata-version=1.11.2\n\t custom kata version used on worker nodes,\n\t should ideally be the same on all worker nodes"
    echo -e "-runcv=1.0.0-rc91|--runc-version=1.0.0-rc91\n\t custom runc version used on worker nodes,\n\t should ideally be the same on all worker nodes"
    echo -e "-cnipv=0.8.6|--cni-plugins-version=0.8.6\n\t custom cni plguins version used on worker nodes,\n\t should ideally be the same on all worker nodes"
    echo -e "-calicov=3.11.3|--calico-version=3.11.3\n\t custom calico version used on worker nodes,\n\t should ideally be the same on all worker nodes"
    echo -e "-cidr=10.200.0.0/16|--cluster-cidr=10.200.0.0/16\n\t custom cluster cidr (cluster ip range in CIDR notation),\n\t each pod will automatically be assigned an IP within the cluster IP range"

    echo -e "\nOPTIONAL ENVIRONMENT VARIABLES (=default_value):"
    echo -e "WORKDIR=./work\n\t use a custom workdir on the HYPERVISOR (default is a dir called 'work' in the same directory as the kubicluster executable or $0)"
    # TODO add less commonly changed env variables from ./utils/env-variables (and make them configurable)
    ;;
  *)
    update_scripts_in_nodes
    update_certs ca calico-cni calico-cni-key
    update_configs kube-proxy.kubeconfig calico-cni.kubeconfig
    install_kata
    install_runc
    install_containerd
    install_kubernetes_workers
    install_cni_calico
    ;;
esac
