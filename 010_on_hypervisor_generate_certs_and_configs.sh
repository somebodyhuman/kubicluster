#!/bin/bash

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

source ${DIR}/utils/env-variables

# ensure cfssl tools exist in tools dir
${DIR}/utils/workdir ensure_tools_dir_exists
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

# ensure kubectl exists in tools dir
if [ ! -d ${KUBERNETES_ON_HYPERVISOR_DIR} ] || [ ! -e ${KUBECTL_CMD_ON_HYPERVISOR} ] \
   || [ "$(${KUBECTL_CMD_ON_HYPERVISOR} version --client --short)" != "Client Version: v${KUBERNETES_VERSION}" ]; then
  mkdir -p ${KUBERNETES_ON_HYPERVISOR_DIR}
  curl -s -L -o ${KUBERNETES_ON_HYPERVISOR_DIR}.tar.gz https://github.com/kubernetes/kubernetes/releases/download/v${KUBERNETES_VERSION}/kubernetes.tar.gz
  tar xzf ${KUBERNETES_ON_HYPERVISOR_DIR}.tar.gz -C ${KUBERNETES_ON_HYPERVISOR_DIR}
  cd ${KUBERNETES_ON_HYPERVISOR_DIR}/kubernetes
  KUBERNETES_SKIP_CONFIRM=true ./cluster/get-kube-binaries.sh
  if [ "$(${KUBECTL_CMD_ON_HYPERVISOR} version --client --short)" != "Client Version: v${KUBERNETES_VERSION}" ]; then
    echo "expected kubectl version ${KUBERNETES_VERSION}, but $(${KUBECTL_CMD_ON_HYPERVISOR} --client --short) is installed in tools dir"
    exit 1
  fi
fi

${DIR}/utils/workdir ensure_certs_and_configs_dir_exists

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
  "CN": "Kubicluster",
  "key": { "algo": "rsa", "size": ${RSA_KEYLENGTH} },
  "names": [ { "O": "Kubicluster" } ]
}
EOF

    ${CFSSL_CMD} gencert -initca ${CA_CSR} | ${CFSSLJSON_CMD} -bare ${CA_BARE}
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

# using the certificate authority to create all the needed signed certificates
GENCERT_ARGS="-ca=${CA_PUB} -ca-key=${CA_KEY} -config=${CA_CONFIG} -profile=kubicluster"
function generate_cert() {
  HN_ARG=''
  CN_O=''
  while [[ $# -gt 0 ]]; do
      key="$1"
      case "$key" in
          -hostname=*)
          HN_ARG="${key}"
          ;;
          *)
          PL=' ' ; if [ "${CN_O}" = "" ]; then PL=''; fi
          CN_O="${CN_O}${PL}${key}"
          ;;
      esac
      # Shift after checking all the cases to get the next option
      shift
  done
  CN_O_ARRAY=($(echo $CN_O | tr " " "\n"))
  CN_O=${CN_O_ARRAY[0]}
  NAME_ROLE=($(echo $CN_O | tr "=" "\n"))
  NAME_PARTS=($(echo ${NAME_ROLE[0]} | tr ":" "\n"))
  FILE_NAME=${NAME_PARTS[1]} ; if [ "${FILE_NAME}" = "" ]; then FILE_NAME=${NAME_PARTS[0]}; fi
  if [ ! -e ${CERTS_AND_CONFIGS_DIR}/${FILE_NAME}.pem ]; then
    echo "generating_cert request for ${NAME_ROLE[0]} into ${FILE_NAME}-csr.json"
    cat > ${CERTS_AND_CONFIGS_DIR}/${FILE_NAME}-csr.json << EOF
{
"CN": "${NAME_ROLE[0]}",
"key": { "algo": "rsa", "size": ${RSA_KEYLENGTH} },
"names": [ { "O": "${NAME_ROLE[1]}" } ]
}
EOF
    ${CFSSL_CMD} gencert ${GENCERT_ARGS} ${HN_ARG} ${CERTS_AND_CONFIGS_DIR}/${FILE_NAME}-csr.json | ${CFSSLJSON_CMD} -bare ${CERTS_AND_CONFIGS_DIR}/${FILE_NAME}
  else
    echo "cert for ${NAME_ROLE[0]} exists already"
  fi
}

function generate_config() {
  NAME_PARTS=($(echo ${1} | tr ":" "\n"))
  NAME=${NAME_PARTS[1]} ; if [ "${NAME}" = "" ]; then NAME=${NAME_PARTS[0]}; fi

  config_file=${CERTS_AND_CONFIGS_DIR}/${NAME}.kubeconfig
  SERVER_IP='127.0.0.1'
  if [ "${NAME}" = "kube-proxy" ]; then SERVER_IP=${CONTROLLER_IP}; fi
  if [ ! -e ${config_file} ]; then
    echo "generating config for ${NAME} into ${NAME}.kubeconfig"
    kubectl config set-cluster ${CLUSTER_NAME} --server=https://${SERVER_IP}:6443 \
      --certificate-authority=${CA_PUB} \
      --embed-certs=true --kubeconfig=${config_file}

    kubectl config set-credentials ${1} \
      --client-certificate=${CERTS_AND_CONFIGS_DIR}/${NAME}.pem \
      --client-key=${CERTS_AND_CONFIGS_DIR}/${NAME}-key.pem \
      --embed-certs=true --kubeconfig=${config_file}

    kubectl config set-context default --cluster=${CLUSTER_NAME} \
      --user=${1} \
      --kubeconfig=${config_file}

    kubectl config use-context default --kubeconfig=${config_file}
  else
    echo "kubconfig for ${1} exists already"
  fi
}

function for_system_components() {
  # TODO make the certs configurable and adjustable
  for component in "$@"
  do
    generate_cert system:${component}=system:${component}

    generate_config ${component}
  done
}

function for_worker_nodes() {
  echo "nodes: ${NODES}"

  # TODO make the certs configurable and adjustable
  for worker in ${NODES}
  do
    worker_name_ip=($(echo $worker | tr "=" "\n"))
    if [ ! -e ${CERTS_AND_CONFIGS_DIR}/${worker_name_ip[0]}.pem ]; then
      echo "generating_cert for ${worker}"
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
    if [ ! -e ${config_file} ]; then
      kubectl config set-cluster ${CLUSTER_NAME} --server=https://${CONTROLLER_IP}:6443 \
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


REMAINING_ARGS=''
NODES=''
CLUSTER_NAME='kubicluster'
# As long as there is at least one more argument, keep looping
while [[ $# -gt 0 ]]; do
    key="$1"
    case "$key" in
        -cip=*|--controller-ip=*)
        CONTROLLER_IP="${key#*=}"
        ;;
        -chn=*|--controller-hostname=*)
        CONTROLLER_HOSTNAME="${key#*=}"
        ;;
        -cl=*|--cluster=*)
        CLUSTER_NAME="${key#*=}"
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

# TODO support cluster of controllers and take first -cip as master controller
CERT_HOSTNAME="${CONTROLLER_IP},${CONTROLLER_HOSTNAME}"
CERT_HOSTNAME="${CERT_HOSTNAME},127.0.0.1,localhost,kubernetes.default"

RARGS_ARRAY=($(echo $REMAINING_ARGS | tr " " "\n"))
echo "running: ${RARGS_ARRAY[0]}"
case "${RARGS_ARRAY[0]}" in
  generate_ca)
    generate_ca
    ;;
  generate_encryption_configs)
    generate_encryption_configs "${RARGS_ARRAY[@]:1}"
    ;;
  generate_cert)
    generate_cert "${RARGS_ARRAY[@]:1}"
    ;;
  for_system_components)
    # TODO check for -cip/--controller-ip and exit if not specified
    for_system_components admin kube-controller-man kube-proxy kube-scheduler
    ;;
  for_worker_nodes)
    # TODO check for -cip/--controller-ip and exit if not specified
    # TODO check for -n/--node and exit if not specified
    for_worker_nodes
    ;;
  help)
    # TODO improve documentation
    echo "Usage: $0 {[WORKDIR='./work'] [generate_ca|generate_cert NAME (ADDITIONAL_CFSSL_ARGS)|for_system_components (-cip=|--controller_ip=x.x.x.x)|for_worker_nodes (-cip=|--controller_ip=x.x.x.x)]}"
    echo "A really good introduction to certificates and the csr field meanings can be found here: https://www.youtube.com/watch?v=gXz4cq3PKdg&t=539"
    echo "Disclaimer: It is better to grant superuser/admin access through service account authenticated by tokens, rather than through certificate authentication. For details read, e.g.: https://dev.to/danielkun/kubernetes-certificates-tokens-authentication-and-service-accounts-4fj7"
    ;;
  *)
    # TODO check for -cip/--controller-ip and exit if not specified
    # TODO check for -n/--node and exit if not specified
    generate_ca
    generate_encryption_configs encryption-config
    generate_cert kubernetes=Kubicluster -hostname=${CERT_HOSTNAME}
    generate_cert service-accounts=Kubicluster
    generate_cert admin=system:masters
    generate_config admin
    for_system_components kube-controller-manager kube-proxy kube-scheduler
    for_worker_nodes
    ;;
esac
