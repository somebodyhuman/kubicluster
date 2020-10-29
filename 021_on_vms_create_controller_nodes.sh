#/!bin/bash

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

function update_scripts_in_nodes() {
  # TODO only update controller scripts
  for node in ${CONTROLLERS}; do
    name_ip=($(echo $node | tr "," "\n"))
    echo "syncing scripts dir to node ${name_ip[0]}"
    ${SSH_CMD} root@${name_ip[2]} "if [ ! -d ${NODE_SCRIPTS_DIR} ]; then mkdir -p ${NODE_SCRIPTS_DIR}; fi"
    ${SSH_CMD} root@${name_ip[2]} "if [ ! -f /usr/bin/rsync ]; then apt-get install -y rsync; fi"
    rsync -e "${SSH_CMD}" -av --no-owner --no-group ${SCRIPTS_DIR}/* root@${name_ip[2]}:${NODE_SCRIPTS_DIR}
  done
}

function update_certs() {
  CERTS=''
  echo "updating certs: $@"
  for cert in "$@"; do CERTS="${CERTS} ${CERTS_AND_CONFIGS_DIR}/${cert}.pem ${CERTS_AND_CONFIGS_DIR}/${cert}-key.pem" ; done
  for node in ${CONTROLLERS}; do
    name_ip=($(echo $node | tr "," "\n"))
    ${SSH_CMD} root@${name_ip[2]} "if [ ! -d ${NODE_CERTS_AND_CONFIGS_DIR} ]; then mkdir -p ${NODE_CERTS_AND_CONFIGS_DIR}; fi"
    ${SCP_CMD} ${CERTS} root@${name_ip[2]}:${NODE_CERTS_AND_CONFIGS_DIR}
  done
}

function update_configs() {
  if [ "$FORCE_ETCD_DATA_RESET" = true ]; then echo "INFO: etcd data reset enforced if encryption-config.yaml is different"; fi

  CONFIGS=''
  PERFORM_ETCD_DATA_RESET=false
  source ${DIR}/utils/workdir ensure_certs_and_configs_mirror_dir_exists

  for config in "$@"; do
    if [ "${config}" != "encryption-config.yaml" ]; then
      CONFIGS="${CONFIGS} ${CERTS_AND_CONFIGS_DIR}/${config}"
    else
      # the following block ensures that the encryption-config.yaml is only updated
      # IF it does not exist yet on all controller nodes
      # OR if an etcd data reset is forced
      DIFFERS_ON='' ; SAME_ON='' ; NOT_YET_ON=''
      for node in ${CONTROLLERS}; do
        name_ip=($(echo $node | tr "," "\n"))
        if [ -d ${CERTS_AND_CONFIGS_MIRROR_DIR}/${name_ip[0]} ]; then rm -rf ${CERTS_AND_CONFIGS_MIRROR_DIR}/${name_ip[0]}; fi
        mkdir -p ${CERTS_AND_CONFIGS_MIRROR_DIR}/${name_ip[0]}
        ${SCP_CMD} root@${name_ip[2]}:${NODE_CERTS_AND_CONFIGS_DIR}/${config} ${CERTS_AND_CONFIGS_MIRROR_DIR}/${name_ip[0]}/${config}

        if [ -e ${CERTS_AND_CONFIGS_MIRROR_DIR}/${name_ip[0]}/${config} ]; then
          if ! diff ${CERTS_AND_CONFIGS_MIRROR_DIR}/${name_ip[0]}/${config} ${CERTS_AND_CONFIGS_DIR}/${config}; then
            PL=', ' ; if [ "${DIFFERS_ON}" = "" ]; then PL=''; fi
            DIFFERS_ON="${DIFFERS_ON}${PL}${node}"
          else
            PL=', ' ; if [ "${SAME_ON}" = "" ]; then PL=''; fi
            SAME_ON="${SAME_ON}${PL}${node}"
          fi
        else
          PL=', ' ; if [ "${NOT_YET_ON}" = "" ]; then PL=''; fi
          NOT_YET_ON="${NOT_YET_ON}${PL}${node}"
        fi
      done

      if [ "${NOT_YET_ON}" != "" ]; then echo "encryption-config.yaml not yet on ${NOT_YET_ON}"; fi
      if [ "${SAME_ON}" != "" ]; then echo "encryption-config.yaml is the same on ${SAME_ON}"; fi
      if [ "${DIFFERS_ON}" != "" ]; then echo "encryption-config.yaml differs on ${SAME_ON}"; fi
      if [ "${DIFFERS_ON}" != "" ] || [ "${NOT_YET_ON}" != "" ]; then
        if [ ! "${FORCE_ETCD_DATA_RESET}" = true ]; then
          echo "WARN: -fedr/--fore-etcd-data-reset is not set, so encryption-config.yaml state is not changed on any node. Re-run with -fedr or resolve manually before re-running without -fedr."
        else
          echo "INFO: -fedr/--fore-etcd-data-reset IS SET. Clearing data directories on nodes and forcing update of encryption-config.yaml on all nodes."
          PERFORM_ETCD_DATA_RESET=true
          CONFIGS="${CONFIGS} ${CERTS_AND_CONFIGS_DIR}/${config}"
        fi
      fi
    fi
  done

  for node in ${CONTROLLERS}; do
    name_ip=($(echo $node | tr "," "\n"))
    ${SSH_CMD} root@${name_ip[2]} "if [ ! -d ${NODE_CERTS_AND_CONFIGS_DIR} ]; then mkdir -p ${NODE_CERTS_AND_CONFIGS_DIR}; fi"
    if [ "${PERFORM_ETCD_DATA_RESET}" = true ]; then
      echo "INFO: performing etcd data reset on ${name_ip[0]}"
      ${SSH_CMD} root@${name_ip[2]} "if systemctl is-active etcd.service; then systemctl stop etcd.service; fi ; if [ -d ${ETCD_DATA_DIR} ]; then rm -rf ${ETCD_DATA_DIR}; fi"
    fi
    if [ "${CONFIGS}" != "" ]; then
      ${SCP_CMD} ${CONFIGS} root@${name_ip[2]}:${NODE_CERTS_AND_CONFIGS_DIR}
    fi
  done
}

function install_etcd() {
  for node in ${CONTROLLERS}; do
    name_ip=($(echo $node | tr "," "\n"))
    CLUSTER_MEMBERS=''
    for cmu in ${CONTROLLERS}; do
      if [ "${cmu}" != "${node}" ]; then
        CLUSTER_MEMBERS="${CLUSTER_MEMBERS} -cmu=${cmu}"
      fi
    done

    if [ "${DEBUG}" = true ]; then echo "[DEBUG]: calling: ${SSH_CMD} root@${name_ip[2]} ${NODE_SCRIPTS_DIR}/controller/setup_etcd.sh $@ -ip=${name_ip[1]} ${CLUSTER_MEMBERS} ${NODE_ARGS}" ; fi
    ${SSH_CMD} root@${name_ip[2]} "${NODE_SCRIPTS_DIR}/controller/setup_etcd.sh $@ -ip=${name_ip[1]} ${CLUSTER_MEMBERS} ${NODE_ARGS}"
  done
}

function install_kubernetes_controllers() {
  for node in ${CONTROLLERS}; do
    name_ip=($(echo $node | tr "," "\n"))
    # TODO can be derived from -c instead of using -cmu
    ETCD_CLUSTER_MEMBERS=''
    for cmu in ${CONTROLLERS}; do
        ETCD_CLUSTER_MEMBERS="${ETCD_CLUSTER_MEMBERS} -cmu=${cmu}"
    done

    if [ "${DEBUG}" = true ]; then echo "[DEBUG]: calling: ${SSH_CMD} root@${name_ip[2]} ${NODE_SCRIPTS_DIR}/controller/setup_kubernetes_controller.sh -ip=${name_ip[1]} ${ETCD_CLUSTER_MEMBERS} ${NODE_ARGS}" ; fi
    ${SSH_CMD} root@${name_ip[2]} "${NODE_SCRIPTS_DIR}/controller/setup_kubernetes_controller.sh -ip=${name_ip[1]} ${ETCD_CLUSTER_MEMBERS} ${NODE_ARGS}"
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
  install_etcd)
    # TODO check for essential args and exit if not specified
    install_etcd
    ;;
  install_kubernetes_controllers)
    # TODO check for essential args and exit if not specified
    install_kubernetes_controllers
    ;;
  help)
    echo -e "\nDefault usage:\nkubicluster create-controllers [OPTIONAL_ARGUMENTS]\n\t This executes all subcommands in order"
    echo -e "\nSub-command usage via kubicluster command:\nkubicluster create-controllers [update_scripts_in_nodes|update_certs|update_configs|install_etcd|install_kubernetes_controllers] [OPTIONAL_ARGUMENTS]"
    echo -e "\nDirect sub-command usage:\n$0 [update_scripts_in_nodes|update_certs|update_configs|install_etcd|install_kubernetes_controllers] [OPTIONAL_ARGUMENTS]"
    echo -e "\nOPTIONAL ARGUMENTS:"
    echo -e "-c kube-controller-01,192.168.24.11 -c kube-controller-02,192.168.24.12"
    echo -e "\t the affected controllers, provide one or more, format always: HOSTNAME,IP"
    echo -e "\t (long: --controller-node kube-controller-01,192.168.24.11 -controller-node kube-controller-02,192.168.24.12)\n"
    echo -e "-f|--force-update\n\t force update, caution this updates every file affected by the run command/sub-command"
    echo -e "-d|--debug\n\t show debug messages"
    echo -e "-t=etcd-kubicluster|--cluster-token=etcd-kubicluster\n\t defines a custom etcd-cluster-token to be used on all controllers listed with -c"
    echo -e "-fedr|--force-etcd-data-reset\n\t if provided, it will enforce resetting all etcd data, USE WITH CAUTION on an already running cluster\n\t can be helpful in cases of changes in the etcd data encryption"
    echo -e "-pp=2380|--peer-port=2380\n\t custom etcd peer port,\n\t used by etcd instances to communicate with each other,\n\t should not be changed unless you have a pretty good reason to do so"
    echo -e "-cp=2379|--client-port=2379\n\t custom etcd client port,\n\t should not be changed unless you have a pretty good reason to do so"
    echo -e "-ev=3.4.10|--etcd-version=3.4.10\n\t custom etcd version to be installed, configured and run\n\t must be the same on all controllers(/ etcd-nodes if etcd is running outside the controllers as a separate cluster)"
    echo -e "-kv=1.18.5|--kubernetes-version=1.18.5\n\t custom kubernetes version used on controller nodes,\n\t should ideally be the same on hypervisor on all nodes (controllers and workers)"

    echo -e "\nOPTIONAL ENVIRONMENT VARIABLES (=default_value):"
    echo -e "WORKDIR=./work\n\t use a custom workdir on the HYPERVISOR (default is a dir called 'work' in the same directory as the kubicluster executable or $0)"
    # TODO add less commonly changed env variables from ./utils/env-variables (and make them configurable)
    ;;
  *)
    update_scripts_in_nodes
    # TODO check for -cip/--controller-ip and exit if not specified
    update_certs ca kubernetes service-accounts calico-cni
    update_configs admin.kubeconfig kube-controller-manager.kubeconfig kube-scheduler.kubeconfig encryption-config.yaml
    install_etcd
    install_kubernetes_controllers
    ;;
esac
