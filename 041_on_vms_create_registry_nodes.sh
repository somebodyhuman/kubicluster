#/!bin/bash

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"


function update_scripts_in_nodes() {
  # TODO only update registry scripts
  for node in ${REGISTRIES}; do
    name_ip=($(echo $node | tr "," "\n"))
    echo "syncing scripts dir to node ${name_ip[0]}"
    ${SSH_CMD} root@${name_ip[2]} "if [ ! -d ${NODE_SCRIPTS_DIR} ]; then mkdir -p ${NODE_SCRIPTS_DIR}; fi"
    ${SSH_CMD} root@${name_ip[2]} "if [ ! -f /usr/bin/rsync ]; then apt-get install -y rsync; fi"
    rsync -e "${SSH_CMD}" -av --no-owner --no-group ${SCRIPTS_DIR}/* root@${name_ip[2]}:${NODE_SCRIPTS_DIR}
  done
}

function setup_nexus_oss() {
  echo 'setting up nexus oss'
  for node in ${REGISTRIES}; do
    name_ip=($(echo $node | tr "," "\n"))

    if [ ! -e ${CERTS_AND_CONFIGS_DIR}/${name_ip[0]}-nexus-csr.conf ] || \
       [ "${FORCE_UPDATE}" = true ]; then

      cat << EOF | tee ${CERTS_AND_CONFIGS_DIR}/${name_ip[0]}-nexus-csr.conf
[ req ]
prompt = no
distinguished_name = req_distinguished_name
x509_extensions = san_self_signed

[ req_distinguished_name ]
CN=${name_ip[0]}-nexus
subjectAltName = @alt_names

[ san_self_signed ]
subjectAltName = @alt_names
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always,issuer
basicConstraints = CA:true
keyUsage = nonRepudiation, digitalSignature, keyEncipherment, dataEncipherment, keyCertSign, cRLSign
extendedKeyUsage = serverAuth, clientAuth, timeStamping

[ req_ext ]
subjectAltName = @alt_names

[ v3_ca ]
subjectAltName = @alt_names

[ alt_names ]
DNS.1   = localhost
IP.1    = 127.0.0.1
IP.2    = ${name_ip[1]}
EOF

    fi
    if [ ! -e ${CERTS_AND_CONFIGS_DIR}/${name_ip[0]}-nexus-fullchain.pem ] || \
       [ ! -e ${CERTS_AND_CONFIGS_DIR}/${name_ip[0]}-nexus-privkey.pem ] || \
       [ "${FORCE_UPDATE}" = true ]; then
      openssl req \
        -extensions san_self_signed \
        -newkey rsa:2048 -nodes \
        -keyout "${CERTS_AND_CONFIGS_DIR}/${name_ip[0]}-nexus-privkey.pem" \
        -x509 -sha256 -days 3650 \
        -config <(cat ${CERTS_AND_CONFIGS_DIR}/${name_ip[0]}-nexus-csr.conf) \
        -out "${CERTS_AND_CONFIGS_DIR}/${name_ip[0]}-nexus-fullchain.pem"
      openssl x509 -noout -text -in "${CERTS_AND_CONFIGS_DIR}/${name_ip[0]}-nexus-fullchain.pem"
    fi

    if [ ! -e ${CERTS_AND_CONFIGS_DIR}/${name_ip[0]}-nexus-fullchain.crt ] || \
       [ "${FORCE_UPDATE}" = true ]; then
      openssl x509 -inform PEM -in "${CERTS_AND_CONFIGS_DIR}/${name_ip[0]}-nexus-fullchain.pem" -out "${CERTS_AND_CONFIGS_DIR}/${name_ip[0]}-nexus-fullchain.crt"
    fi

    ${SSH_CMD} root@${name_ip[2]} "if [ ! -d ${NODE_CERTS_AND_CONFIGS_DIR} ]; then mkdir -p ${NODE_CERTS_AND_CONFIGS_DIR}; fi"
    ${SCP_CMD} ${CERTS_AND_CONFIGS_DIR}/${name_ip[0]}-nexus-privkey.pem root@${name_ip[2]}:${NODE_CERTS_AND_CONFIGS_DIR}/nexus-privkey.pem
    ${SCP_CMD} ${CERTS_AND_CONFIGS_DIR}/${name_ip[0]}-nexus-fullchain.pem root@${name_ip[2]}:${NODE_CERTS_AND_CONFIGS_DIR}/nexus-fullchain.pem
    ${SSH_CMD} root@${name_ip[2]} "update-ca-certificates --fresh | grep added"
    ${SCP_CMD} ${CERTS_AND_CONFIGS_DIR}/${name_ip[0]}-nexus-fullchain.crt root@${name_ip[2]}:/usr/local/share/ca-certificates/nexus-fullchain.crt
    ${SSH_CMD} root@${name_ip[2]} "update-ca-certificates --fresh | grep added"
    # TODO check that cert really got added

    if [ "${DEBUG}" = true ]; then echo "[DEBUG]: calling: ${SSH_CMD} root@${name_ip[2]} \"${NODE_SCRIPTS_DIR}/registry/setup_nexus_oss.sh ${NODE_ARGS} -kip=${name_ip[1]}\"" ; fi
    ${SSH_CMD} root@${name_ip[2]} "${NODE_SCRIPTS_DIR}/registry/setup_nexus_oss.sh ${NODE_ARGS} -kip=${name_ip[1]}"

    # for worker in ${WORKERS}; do
    #   w_name_ip=($(echo $worker | tr "," "\n"))
    #
    #   ${SCP_CMD} "${CERTS_AND_CONFIGS_DIR}/${name_ip[0]}-nexus-fullchain.pem" root@${w_name_ip[2]}:${NODE_CERTS_AND_CONFIGS_DIR}
    #   # update worker nodes /etc/containerd/config.toml by (re)running install containerd on them
    #   ${SSH_CMD} root@${w_name_ip[2]} "update-ca-certificates --fresh | grep added"
    #   ${SCP_CMD} ${CERTS_AND_CONFIGS_DIR}/${name_ip[0]}-nexus-fullchain.crt root@${w_name_ip[2]}:/usr/local/share/ca-certificates/
    #   ${SSH_CMD} root@${w_name_ip[2]} "update-ca-certificates --fresh | grep added"
    # done
  done

  # for worker in ${WORKERS}; do
  #   w_name_ip=($(echo $worker | tr "," "\n"))
  #
  #   ${SCP_CMD} "${CERTS_AND_CONFIGS_DIR}/${name_ip[0]}-nexus-fullchain.pem" root@${w_name_ip[2]}:${NODE_CERTS_AND_CONFIGS_DIR}
  #   ${SSH_CMD} root@${w_name_ip[2]} "${NODE_SCRIPTS_DIR}/worker/setup_containerd.sh ${NODE_ARGS}"
  #   # update worker nodes /etc/containerd/config.toml by (re)running install containerd on them
  #   ${SSH_CMD} root@${w_name_ip[2]} "update-ca-certificates --fresh | grep added"
  #   ${SCP_CMD} ${CERTS_AND_CONFIGS_DIR}/${name_ip[0]}-fullchain.crt root@${w_name_ip[2]}:/usr/local/share/ca-certificates/
  #   ${SSH_CMD} root@${w_name_ip[2]} "update-ca-certificates --fresh | grep added"
  ${DIR}/kubicluster create-controllers configure_registry_secrets ${NODE_ARGS}
  ${DIR}/kubicluster create-workers update_scripts_in_nodes ${NODE_ARGS}
  ${DIR}/kubicluster create-workers install_containerd ${NODE_ARGS} -f
  # done
}

function distribute_certs_to_workers() {
  for node in ${REGISTRIES}; do
    name_ip=($(echo $node | tr "," "\n"))
    # TODO test image pull through registry using pw: admin_pw=$(${SSH_CMD} root@${name_ip[2]} "cat /opt/kubicluster/nexus-admin.password")

    for worker in ${WORKERS}; do
      w_name_ip=($(echo $worker | tr "," "\n"))
      # TODO handle -f / force-update correctly
      ${SCP_CMD} "${CERTS_AND_CONFIGS_DIR}/${name_ip[0]}-nexus-fullchain.pem" root@${w_name_ip[2]}:${NODE_CERTS_AND_CONFIGS_DIR}
      # update worker nodes /etc/containerd/config.toml by (re)running install containerd on them
      ${SSH_CMD} root@${w_name_ip[2]} "update-ca-certificates --fresh | grep added"
      ${SCP_CMD} ${CERTS_AND_CONFIGS_DIR}/${name_ip[0]}-nexus-fullchain.crt root@${w_name_ip[2]}:/usr/local/share/ca-certificates/
      ${SSH_CMD} root@${w_name_ip[2]} "update-ca-certificates --fresh | grep added"
    done
  done
}

source ${DIR}/utils/env-variables "$@"

case "${SUB_CMD}" in
  update_scripts_in_nodes)
    update_scripts_in_nodes
    ;;
  setup_nexus_oss)
  # TODO rargs may be removed ?
    setup_nexus_oss "${RARGS_ARRAY[@]}"
    ;;
  distribute_certs_to_workers)
    distribute_certs_to_workers
    ;;
  help)
    echo -e "\nDefault usage:\nkubicluster create-registry -r [REGISTRY_HOSTNAME],[REGISTRY_CLUSTER_NET_IP],[REGISTRY_HYPERVISOR_NET_IP] [OPTIONAL_ARGUMENTS]\n\t This executes all subcommands in order"
    echo -e "\nSub-command usage via kubicluster command:\nkubicluster create-registry [setup_nexus_oss] [OPTIONAL_ARGUMENTS]"
    echo -e "\nDirect sub-command usage:\n$0 [setup_nexus_oss] [OPTIONAL_ARGUMENTS]"
    echo -e "\nOPTIONAL ARGUMENTS:"
    echo -e "-f|--force-update\n\t force update, caution this updates every file affected by the run command/sub-command"
    echo -e "-d|--debug\n\t show debug messages"

    echo -e "\nOPTIONAL ENVIRONMENT VARIABLES (=default_value):"
    echo -e "WORKDIR=./work\n\t use a custom workdir on the HYPERVISOR (default is a dir called 'work' in the same directory as the kubicluster executable or $0)"
    # TODO add less commonly changed env variables from ./utils/env-variables (and make them configurable)
    ;;
  *)
    update_scripts_in_nodes
    setup_nexus_oss
    distribute_certs_to_workers
    ;;
esac
