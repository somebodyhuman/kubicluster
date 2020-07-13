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

function generate_system_certs() {
  # TODO make the certs configurable and adjustable
  for cert_name in "$@"
  do
    if [ ! -e ${CERTS_AND_CONFIGS_DIR}/${cert_name}.pem ]; then
      echo "generating_cert for ${cert_name}"
      cat > ${CERTS_AND_CONFIGS_DIR}/${cert_name}-csr.json << EOF
{
  "CN": "${cert_name}",
  "key": { "algo": "rsa", "size": ${RSA_KEYLENGTH} },
  "names": [ { "O": "system:${cert_name}" } ]
}
EOF
      ${CFSSL_CMD} gencert ${GENCERT_ARGS} ${CERTS_AND_CONFIGS_DIR}/${cert_name}-csr.json | ${CFSSLJSON_CMD} -bare ${CERTS_AND_CONFIGS_DIR}/${cert_name}
    else
      echo "cert for ${cert_name} exists already"
    fi
  done

}

function generate_worker_certs() {
  # TODO make the certs configurable and adjustable
  for worker in "$@"
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
      # TODO check if there need to be more hostnames included
      ${CFSSL_CMD} gencert ${GENCERT_ARGS} -hostname=${worker_name_ip[0]},${worker_name_ip[1]} ${CERTS_AND_CONFIGS_DIR}/${worker_name_ip[0]}-csr.json | ${CFSSLJSON_CMD} -bare ${CERTS_AND_CONFIGS_DIR}/${worker_name_ip[0]}
    else
      echo "cert for ${worker_name_ip[0]} exists already"
    fi
  done
}

case "$1" in
  generate_ca)
    generate_ca
    ;;
  generate_system_certs)
    generate_system_certs admin kube-controller-man kube-proxy kube-scheduler
    ;;
  generate_worker_certs)
    generate_worker_certs
    ;;
  help)
    # TODO improve documentation
    echo "Usage: $0 {[WORKDIR='./work'] generate_ca|generate_system_certs|generate_worker_certs}"
    ;;
  *)
    generate_ca
    generate_system_certs admin kube-controller-man kube-proxy kube-scheduler
    generate_worker_certs "${@:1}"
esac
