#/!bin/bash

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

source ${DIR}/../utils/env-variables "$@"

CERTS_AND_CONFIGS_DIR=${NODE_WORK_DIR}/certs_and_configs

MAJOR_MINOR="$(echo ${CALICO_VERSION} | cut -d '.' -f 1).$(echo ${CALICO_VERSION} | cut -d '.' -f 2)"

if [ ! -f ${NODE_WORK_DIR}/calico.yaml ] || \
   [ "${FORCE_UPDATE}" = true ]; then
  if ! (dpkg -s ca-certificates); then apt-get install -y ca-certificates; fi
  wget -q --show-progress --https-only --timestamping \
    "https://docs.projectcalico.org/v${MAJOR_MINOR}/manifests/calico-typha.yaml" -O ${NODE_WORK_DIR}/calico.yaml
  # CA_B64="$(cat ${CERTS_AND_CONFIGS_DIR}/ca.pem | base64 -w 0)"
  # CERT_B64="$(cat ${CERTS_AND_CONFIGS_DIR}/calico-cni.pem | base64 -w 0)"
  # KEY_B64="$(cat ${CERTS_AND_CONFIGS_DIR}/calico-cni-key.pem | base64 -w 0)"

  sed -i "s_192.168.0.0/16_${CLUSTER_CIDR}_g" ${NODE_WORK_DIR}/calico.yaml
  sed -i "s_priorityClassName: system-cluster-critical_priorityClassName: system-cluster-critical\n      runtimeClassName: runc_g" ${NODE_WORK_DIR}/calico.yaml
  sed -i "s_priorityClassName: system-node-critical_priorityClassName: system-node-critical\n      runtimeClassName: runc_g" ${NODE_WORK_DIR}/calico.yaml
  # sed -i "s#etcd_endpoints: \"http://<ETCD_IP>:<ETCD_PORT>\"#etcd_endpoints: \"${INITIAL_ETCD_CLUSTER}\"#g" ${NODE_WORK_DIR}/calico.yaml
  # sed -i "s#__ETCD_ENDPOINTS__#${INITIAL_ETCD_CLUSTER}#g" ${NODE_WORK_DIR}/calico.yaml
  # sed -i "s#__ETCD_KEY_FILE__#${CERTS_AND_CONFIGS_DIR}/calico-cni-key.pem#g" ${NODE_WORK_DIR}/calico.yaml
  # sed -i "s#__ETCD_CERT_FILE__#${CERTS_AND_CONFIGS_DIR}/calico-cni.pem#g" ${NODE_WORK_DIR}/calico.yaml
  # sed -i "s#__ETCD_CA_CERT_FILE__#${CERTS_AND_CONFIGS_DIR}/ca.pem#g" ${NODE_WORK_DIR}/calico.yaml
  #sed -i "s#etcd_ca: \"\"#etcd_ca: \"${CERTS_AND_CONFIGS_DIR}/ca.pem\"#g" ${NODE_WORK_DIR}/calico.yaml
  #sed -i "s#etcd_cert: \"\"#etcd_cert: \"${CERTS_AND_CONFIGS_DIR}/calico-cni.pem\"#g" ${NODE_WORK_DIR}/calico.yaml
  #sed -i "s#etcd_key: \"\"#etcd_key: \"${CERTS_AND_CONFIGS_DIR}/calico-cni-key.pem\"#g" ${NODE_WORK_DIR}/calico.yaml
  # sed -i "s#etcd_ca: \"\"#etcd_ca: \"/calico-secrets/etcd-ca\"#g" ${NODE_WORK_DIR}/calico.yaml
  # sed -i "s#etcd_cert: \"\"#etcd_cert: \"/calico-secrets/etcd-cert\"#g" ${NODE_WORK_DIR}/calico.yaml
  # sed -i "s#etcd_key: \"\"#etcd_key: \"/calico-secrets/etcd-key\"#g" ${NODE_WORK_DIR}/calico.yaml
  # sed -i "s%# etcd-ca: null%etcd-ca: \"${CA_B64}\"%g" ${NODE_WORK_DIR}/calico.yaml
  # sed -i "s%# etcd-cert: null%etcd-cert: \"${CERT_B64}\"%g" ${NODE_WORK_DIR}/calico.yaml
  # sed -i "s%# etcd-key: null%etcd-key: \"${KEY_B64}\"%g" ${NODE_WORK_DIR}/calico.yaml
  # sed -i "s#__CNI_MTU__#1440#g" ${NODE_WORK_DIR}/calico.yaml
  # sed -i "s#__KUBECONFIG_FILEPATH__#${CERTS_AND_CONFIGS_DIR}/calico-cni.kubeconfig#g" ${NODE_WORK_DIR}/calico.yaml
else
  echo "calico conf already exists"
fi

kubectl apply -f ${NODE_WORK_DIR}/calico.yaml
