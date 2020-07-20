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

# using the certificate authority to create all the needed signed certificates
GENCERT_ARGS="-ca=${CA_PUB} -ca-key=${CA_KEY} -config=${CA_CONFIG} -profile=kubicluster"

function for_system_components() {
  # TODO make the certs configurable and adjustable
  for component in "$@"
  do
    if [ ! -e ${CERTS_AND_CONFIGS_DIR}/${component}.pem ]; then
      echo "generating_cert for ${component}"
      cat > ${CERTS_AND_CONFIGS_DIR}/${component}-csr.json << EOF
{
  "CN": "${component}",
  "key": { "algo": "rsa", "size": ${RSA_KEYLENGTH} },
  "names": [ { "O": "system:${component}" } ]
}
EOF
      ${CFSSL_CMD} gencert ${GENCERT_ARGS} ${CERTS_AND_CONFIGS_DIR}/${component}-csr.json | ${CFSSLJSON_CMD} -bare ${CERTS_AND_CONFIGS_DIR}/${component}
    else
      echo "cert for ${component} exists already"
    fi
    config_file=${CERTS_AND_CONFIGS_DIR}/${component}.kubeconfig
    SERVER_IP='127.0.0.1'
    if [ "${component}" == "kube-proxy" ]; then SERVER_IP=${CONTROLLER_IP}; fi
    if [ ! -e ${config_file} ]; then
      kubectl config set-cluster ${CLUSTER_NAME} --server=https://${SERVER_IP}:6443 \
        --certificate-authority=${CERTS_AND_CONFIGS_DIR}/ca.pem \
        --embed-certs=true --kubeconfig=${config_file}

      kubectl config set-credentials system:${component} \
        --client-certificate=${CERTS_AND_CONFIGS_DIR}/${component}.pem \
        --client-key=${CERTS_AND_CONFIGS_DIR}/${component}-key.pem \
        --embed-certs=true --kubeconfig=${config_file}

      kubectl config set-context default --cluster=${CLUSTER_NAME} \
        --user=system:${component} \
        --kubeconfig=${config_file}

      kubectl config use-context default --kubeconfig=${config_file}
    else
      echo "kubconfig for ${component} exists already"
    fi
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
        --certificate-authority=${CERTS_AND_CONFIGS_DIR}/ca.pem \
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
CLUSTER_NAME=''
# As long as there is at least one more argument, keep looping
while [[ $# -gt 0 ]]; do
    key="$1"
    case "$key" in
        -cip=*|--controller-ip=*)
        CONTROLLER_IP="${key#*=}"
        ;;
        -cl=*|--cluster=*)
        CLUSTER_NAME="${key#*=}"
        ;;
        -n|--worker-node)
        shift # past the key and to the value
        NODES="${NODES} $1"
        ;;
        *)
        REMAINING_ARGS="${REMAINING_ARGS} $key"
        ;;
    esac
    # Shift after checking all the cases to get the next option
    shift
done

if [ "${CLUSTER_NAME}" == "" ]; then CLUSTER_NAME='kubicluster'; fi

case "$1" in
  generate_ca)
    generate_ca
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
    echo "Usage: $0 {[WORKDIR='./work'] [generate_ca|for_system_components (-cip=|--controller_ip=x.x.x.x)|for_worker_nodes (-cip=|--controller_ip=x.x.x.x)]}"
    ;;
  *)
    # TODO check for -cip/--controller-ip and exit if not specified
    # TODO check for -n/--node and exit if not specified
    generate_ca
    for_system_components admin kube-controller-man kube-proxy kube-scheduler
    for_worker_nodes
esac
