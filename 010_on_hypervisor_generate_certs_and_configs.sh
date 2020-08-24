#!/bin/bash

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

source ${DIR}/utils/workdir ensure_certs_and_configs_dir_exists

function setup_cfssl() {
  # ensure cfssl tools exist in tools dir
  source ${DIR}/utils/workdir ensure_tools_dir_exists
  if [ ! -e ${CFSSL_CMD} ]; then
    curl -s -L -o ${CFSSL_CMD} https://pkg.cfssl.org/R${CFSSL_VERSION}/cfssl_linux-amd64
    chmod +x ${CFSSL_CMD}
  fi
  if [ ! -e ${CFSSLJSON_CMD} ]; then
    curl -s -L -o ${CFSSLJSON_CMD} https://pkg.cfssl.org/R${CFSSL_VERSION}/cfssljson_linux-amd64
    chmod +x ${CFSSLJSON_CMD}
  fi
  if [ ! -e ${CFSSLCERTINFO_CMD} ]; then
    curl -s -L -o ${CFSSLCERTINFO_CMD} https://pkg.cfssl.org/R${CFSSL_VERSION}/cfssl-certinfo_linux-amd64
    chmod +x ${CFSSLCERTINFO_CMD}
  fi
}

function generate_ca() {
  if [ ! -e ${CA_PUB} ] || [ ! -e ${CA_KEY} ]; then
    # generate ca config
    cat > ${CA_CONFIG} << EOF
{
  "signing": {
    "default": { "expiry": "8760h" },
    "profiles": {
      "kubicluster": {
        "usages": ["signing", "key encipherment", "server auth", "client auth"],
        "expiry": "8760h"
      }
    }
  }
}
EOF

    # generate ca csr
    cat > ${CA_CSR} << EOF
{
  "CN": "${RBAC_CLUSTER_NAME}",
  "key": { "algo": "rsa", "size": ${RSA_KEYLENGTH} },
  "names": [ { "O": "${RBAC_CLUSTER_NAME}" } ]
}
EOF

    ${CFSSL_CMD} gencert -initca ${CA_CSR} | ${CFSSLJSON_CMD} -bare ${CA_BARE}
  else
    echo "certificate authority ${CA_BARE} exists already"
  fi
}

function generate_encryption_configs() {
  # TODO link to and explain different encryption used according to https://github.com/kubernetes/kubernetes/issues/66844
  # TODO switch this to kms according to https://kubernetes.io/docs/tasks/administer-cluster/encrypt-data/
  #      because aescbc only moderately improves security of data in etcd
  for conf in "$@"
  do
    CFILE="${CERTS_AND_CONFIGS_DIR}/$conf.yaml"
    if [ -e ${CFILE} ]; then
      echo "encryption config ${conf} exists already"
    else
      echo "generating encryption config ${conf}"
      ENCRYPTION_KEY=$(head -c 32 /dev/urandom | base64)
      cat >${CFILE} << EOF
kind: EncryptionConfig
apiVersion: v1
resources:
  - resources:
      - secrets
    providers:
      - aescbc:
          keys:
            - name: key1
              secret: ${ENCRYPTION_KEY}
      - identity: {}
EOF
    fi
  done
}

function generate_certs() {
  CN_O_HN_ARRAY=($(echo $REMAINING_ARGS | tr " " "\n"))
  for cn_o_h in "$@"
  do
    NAME_ROLE_HOSTNAME=($(echo ${cn_o_h} | tr "@" "\n"))
    if [ "${NAME_ROLE_HOSTNAME[1]}" != "" ] ; then HN_ARG=" -hostname=${NAME_ROLE_HOSTNAME[1]}" ; else HN_ARG='' ; fi
    NAME_ROLE=($(echo ${NAME_ROLE_HOSTNAME[0]} | tr "=" "\n"))
    NAME_PARTS=($(echo ${NAME_ROLE[0]} | tr ":" "\n"))
    FILE_NAME=${NAME_PARTS[1]} ; if [ "${FILE_NAME}" = "" ]; then FILE_NAME=${NAME_PARTS[0]}; fi
    if [ ! -e ${CERTS_AND_CONFIGS_DIR}/${FILE_NAME}.pem ]  || [ "${FORCE_UPDATE}" = true ]; then
      echo "generating_cert request for ${NAME_ROLE[0]} into ${FILE_NAME}-csr.json"
      cat > ${CERTS_AND_CONFIGS_DIR}/${FILE_NAME}-csr.json << EOF
{
"CN": "${NAME_ROLE[0]}",
"key": { "algo": "rsa", "size": ${RSA_KEYLENGTH} },
"names": [ { "O": "${NAME_ROLE[1]}" } ]
}
EOF
      ${CFSSL_CMD} gencert ${GENCERT_ARGS}${HN_ARG} ${CERTS_AND_CONFIGS_DIR}/${FILE_NAME}-csr.json | ${CFSSLJSON_CMD} -bare ${CERTS_AND_CONFIGS_DIR}/${FILE_NAME}
    else
      echo "cert for ${NAME_ROLE[0]} exists already"
    fi
  done
}

function generate_configs() {
  for entity in "$@"
  do
    NAME_PARTS=($(echo ${entity} | tr ":" "\n"))
    NAME=${NAME_PARTS[1]} ; if [ "${NAME}" = "" ]; then NAME=${NAME_PARTS[0]}; fi

    config_file=${CERTS_AND_CONFIGS_DIR}/${NAME}.kubeconfig
    SERVER_IP='127.0.0.1'
    if [ "${NAME}" = "kube-proxy" ] || [ "${NAME}" = "calico-cni" ] ; then SERVER_IP=${CONTROLLER_LB_IP}; fi
    if [ ! -e ${config_file} ] || [ "${FORCE_UPDATE}" = true ]; then
      echo "generating config for ${NAME} into ${NAME}.kubeconfig"
      kubectl config set-cluster ${CLUSTER_NAME} --server=https://${SERVER_IP}:6443 \
        --certificate-authority=${CA_PUB} \
        --embed-certs=true --kubeconfig=${config_file}

      kubectl config set-credentials ${entity} \
        --client-certificate=${CERTS_AND_CONFIGS_DIR}/${NAME}.pem \
        --client-key=${CERTS_AND_CONFIGS_DIR}/${NAME}-key.pem \
        --embed-certs=true --kubeconfig=${config_file}

      kubectl config set-context default --cluster=${CLUSTER_NAME} \
        --user=${entity} \
        --kubeconfig=${config_file}

      kubectl config use-context default --kubeconfig=${config_file}
    else
      echo "kubconfig for ${entity} exists already"
    fi
  done
}

function for_system_components() {
  # TODO make the certs configurable and adjustable
  for component in "$@"
  do
    generate_certs system:${component}=system:${component}

    generate_configs ${component}
  done
}

function for_worker_nodes() {
  echo "workers: ${WORKERS}"

  # TODO make the certs configurable and adjustable
  for worker in ${WORKERS}
  do
    worker_name_ip=($(echo $worker | tr "," "\n"))
    if [ ! -e ${CERTS_AND_CONFIGS_DIR}/${worker_name_ip[0]}.pem ] || [ "${FORCE_UPDATE}" = true ]; then
      echo "generating_cert for ${worker_name_ip[0]} (with IP: ${worker_name_ip[1]})"
      cat > ${CERTS_AND_CONFIGS_DIR}/${worker_name_ip[0]}-csr.json << EOF
{
  "CN": "system:node:${worker_name_ip[0]}",
  "key": { "algo": "rsa", "size": ${RSA_KEYLENGTH} },
  "names": [ { "O": "system:nodes" } ]
}
EOF
      ${CFSSL_CMD} gencert ${GENCERT_ARGS} -hostname=${worker_name_ip[0]},${worker_name_ip[1]} ${CERTS_AND_CONFIGS_DIR}/${worker_name_ip[0]}-csr.json | ${CFSSLJSON_CMD} -bare ${CERTS_AND_CONFIGS_DIR}/${worker_name_ip[0]}
    else
      echo "cert for ${worker_name_ip[0]} exists already"
    fi
    config_file=${CERTS_AND_CONFIGS_DIR}/${worker_name_ip[0]}.kubeconfig
    if [ ! -e ${config_file} ] || [ "${FORCE_UPDATE}" = true ]; then
      echo "(re)generating kubeconfig for ${worker_name_ip[0]}"
      kubectl config set-cluster ${CLUSTER_NAME} --server=https://${CONTROLLER_LB_IP}:6443 \
        --certificate-authority=${CA_PUB} \
        --embed-certs=true --kubeconfig=${config_file}

      kubectl config set-credentials system:node:${worker_name_ip[0]} \
        --client-certificate=${CERTS_AND_CONFIGS_DIR}/${worker_name_ip[0]}.pem \
        --client-key=${CERTS_AND_CONFIGS_DIR}/${worker_name_ip[0]}-key.pem \
        --embed-certs=true --kubeconfig=${config_file}

      kubectl config set-context default --cluster=${CLUSTER_NAME} \
        --user=system:node:${worker_name_ip[0]} \
        --kubeconfig=${config_file}

      kubectl config use-context default --kubeconfig=${config_file}
    else
      echo "kubconfig for ${worker_name_ip[0]} exists already"
    fi
  done
}

source ${DIR}/utils/env-variables "$@"

# using the certificate authority to create all the needed signed certificates
GENCERT_ARGS="-ca=${CA_PUB} -ca-key=${CA_KEY} -config=${CA_CONFIG} -profile=kubicluster"

case "${SUB_CMD}" in
  generate_ca)
    setup_cfssl
    generate_ca
    ;;
  generate_encryption_configs)
    setup_cfssl
    generate_encryption_configs "${RARGS_ARRAY[@]}"
    ;;
  generate_certs)
    setup_cfssl
    generate_certs "${RARGS_ARRAY[@]}"
    ;;
  generate_configs)
    setup_cfssl
    generate_configs "${RARGS_ARRAY[@]}"
    ;;
  for_system_components)
    setup_cfssl
    # TODO check for -cip/--controller-ip and exit if not specified
    for_system_components "${RARGS_ARRAY[@]}"
    ;;
  for_worker_nodes)
    setup_cfssl
    # TODO check for -cip/--controller-ip and exit if not specified
    # TODO check for -n/--node and exit if not specified
    for_worker_nodes
    ;;
  help)
    # TODO improve documentation
    echo "Usage: $0 {[WORKDIR='./work'] [generate_ca|generate_certs (NAME|CN)=(CLUSTERNAME|O)(@HOSTNAME(S))|for_system_components (-cip=|--controller_ip=x.x.x.x)|for_worker_nodes (-cip=|--controller_ip=x.x.x.x)]}"
    echo "A really good introduction to certificates and the csr field meanings can be found here: https://www.youtube.com/watch?v=gXz4cq3PKdg&t=539"
    echo "Disclaimer: It is better to grant superuser/admin access through a service account authenticated by tokens, rather than through certificate authentication. For details read, e.g.: https://dev.to/danielkun/kubernetes-certificates-tokens-authentication-and-service-accounts-4fj7"
    ;;
  *)
    # TODO check for -cip/--controller-ip and exit if not specified
    # TODO check for -n/--node and exit if not specified
    setup_cfssl
    generate_ca
    generate_encryption_configs encryption-config
    generate_certs kubernetes=${RBAC_CLUSTER_NAME}@${CERT_HOSTNAME} service-accounts=${RBAC_CLUSTER_NAME} admin=system:masters
    generate_certs calico-cni=${RBAC_CLUSTER_NAME}
    generate_configs calico-cni admin
    for_system_components kube-controller-manager kube-proxy kube-scheduler
    for_worker_nodes
    ;;
esac
