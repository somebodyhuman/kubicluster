#/!bin/bash

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

source ${DIR}/../utils/env-variables "$@"

HOSTNAME=$(hostname)
CERTS_AND_CONFIGS_DIR=${NODE_WORK_DIR}/certs_and_configs
KUBERNETES_PARENT_DIR=${NODE_WORK_DIR}/kubernetes-${KUBERNETES_VERSION}
KUBERNETES_DIR=${KUBERNETES_PARENT_DIR}/kubernetes
KUBERNETES_SERVER_DIR=${KUBERNETES_DIR}/server

if [ ! -d ${NODE_WORK_DIR} ]; then mkdir -p ${NODE_WORK_DIR}; fi

if [ ! -f ${NODE_WORK_DIR}/kubernetes-${KUBERNETES_VERSION}.tar.gz ]; then
  if ! (dpkg -s ca-certificates); then apt-get install -y ca-certificates; fi
  wget -q --show-progress --https-only --timestamping \
    "https://github.com/kubernetes/kubernetes/releases/download/v${KUBERNETES_VERSION}/kubernetes.tar.gz" -O ${NODE_WORK_DIR}/kubernetes-${KUBERNETES_VERSION}.tar.gz
fi

if [ ! -d ${NODE_WORK_DIR}/kubernetes-${KUBERNETES_VERSION} ]; then
  mkdir -p ${NODE_WORK_DIR}/kubernetes-${KUBERNETES_VERSION}
  tar -xvzf ${NODE_WORK_DIR}/kubernetes-${KUBERNETES_VERSION}.tar.gz -C ${NODE_WORK_DIR}/kubernetes-${KUBERNETES_VERSION}/
fi
if [ ! -f ${KUBERNETES_SERVER_DIR}/bin/kubelet ] || \
   [ ! -f ${KUBERNETES_SERVER_DIR}/bin/kube-proxy ] || \
   [ ! -f ${KUBERNETES_SERVER_DIR}/bin/kubectl ]; then
  KUBERNETES_SKIP_CONFIRM=true ${KUBERNETES_PARENT_DIR}/kubernetes/cluster/get-kube-binaries.sh
  tar vxzf ${KUBERNETES_SERVER_DIR}/kubernetes-server-linux-amd64.tar.gz -C ${KUBERNETES_PARENT_DIR}/
else
  echo "kubernetes ${KUBERNETES_VERSION} already exists"
fi

if [ ! -f /etc/systemd/system/kubelet.service ] || \
   [ "$(systemctl status kubelet.service | grep running)" = "" ] || \
   [ ! -f /etc/systemd/system/kube-proxy.service ] || \
   [ "$(systemctl status kube-proxy.service | grep running)" = "" ] || \
   [ ! -f /usr/local/bin/kubelet ] || \
   [ ! -f /usr/local/bin/kube-proxy ] || \
   [ ! -f /usr/local/bin/kubectl ] || \
   [ "${FORCE_UPDATE}" = true ]; then
  if [ -f /usr/local/bin/kubelet ]; then rm -f /usr/local/bin/kubelet; fi
  if [ -f /usr/local/bin/kube-proxy ]; then rm -f /usr/local/bin/kube-proxy; fi
  if [ -f /usr/local/bin/kubectl ]; then rm -f /usr/local/bin/kubectl; fi
  ln -s ${KUBERNETES_SERVER_DIR}/bin/kubelet /usr/local/bin/kubelet
  ln -s ${KUBERNETES_SERVER_DIR}/bin/kube-proxy /usr/local/bin/kube-proxy
  ln -s ${KUBERNETES_SERVER_DIR}/bin/kubectl /usr/local/bin/kubectl

  KUBECTL_VERSION=$(kubectl version --short --client)
  if [ "${KUBECTL_VERSION}" != "Client Version: v${KUBERNETES_VERSION}" ]; then
    echo "kubectl ${KUBECTL_VERSION} installation failed."
    exit 1
  else
    echo "kubectl version is ${KUBECTL_VERSION}."
  fi
  if [ ! -f ${CERTS_AND_CONFIGS_DIR}/kubelet-config.yaml ] || \
     [ "${FORCE_UPDATE}" = true ]; then
    cat << EOF | tee ${CERTS_AND_CONFIGS_DIR}/kubelet-config.yaml
kind: KubeletConfiguration
apiVersion: kubelet.config.k8s.io/v1beta1
authentication:
 anonymous:
   enabled: false
 webhook:
   enabled: true
 x509:
   clientCAFile: "${CERTS_AND_CONFIGS_DIR}/ca.pem"
authorization:
 mode: Webhook
clusterDomain: "cluster.local"
clusterDNS:
 - "${CLUSTER_DNS}"
runtimeRequestTimeout: "15m"
tlsCertFile: "${CERTS_AND_CONFIGS_DIR}/${HOSTNAME}.pem"
tlsPrivateKeyFile: "${CERTS_AND_CONFIGS_DIR}/${HOSTNAME}-key.pem"
EOF
  fi
  if [ ! -f /etc/systemd/system/kubelet.service ] || \
     [ "${FORCE_UPDATE}" = true ]; then
    cat << EOF | tee /etc/systemd/system/kubelet.service
[Unit]
Description=Kubernetes Kubelet
Documentation=https://github.com/kubernetes/kubernetes
After=containerd.service
Requires=containerd.service

[Service]
ExecStart=/usr/local/bin/kubelet \\
 --config=${CERTS_AND_CONFIGS_DIR}/kubelet-config.yaml \\
 --container-runtime=remote \\
 --container-runtime-endpoint=unix:///var/run/containerd/containerd.sock \\
 --image-pull-progress-deadline=2m \\
 --kubeconfig=${CERTS_AND_CONFIGS_DIR}/${HOSTNAME}.kubeconfig \\
 --network-plugin=cni \\
 --register-node=true \\
 --v=2 \\
 --hostname-override=${HOSTNAME}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
  fi

  systemctl enable kubelet
  if [ "${FORCE_UPDATE}" = true ]; then
    systemctl stop kubelet
  fi
  systemctl start kubelet
  systemctl status kubelet

  if [ ! -f ${CERTS_AND_CONFIGS_DIR}/kube-proxy-config.yaml ] || \
     [ "${FORCE_UPDATE}" = true ]; then
    cat << EOF | tee ${CERTS_AND_CONFIGS_DIR}/kube-proxy-config.yaml
kind: KubeProxyConfiguration
apiVersion: kubeproxy.config.k8s.io/v1alpha1
clientConnection:
 kubeconfig: "${CERTS_AND_CONFIGS_DIR}/kube-proxy.kubeconfig"
mode: "iptables"
clusterCIDR: "${CLUSTER_CIDR}"
EOF
  fi
  if [ ! -f /etc/systemd/system/kube-proxy.service ] || \
     [ "${FORCE_UPDATE}" = true ]; then
    cat << EOF | tee /etc/systemd/system/kube-proxy.service
[Unit]
Description=Kubernetes Kube Proxy
Documentation=https://github.com/kubernetes/kubernetes

[Service]
ExecStart=/usr/local/bin/kube-proxy \\
 --config=${CERTS_AND_CONFIGS_DIR}/kube-proxy-config.yaml
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
  fi

  systemctl enable kube-proxy
  if [ "${FORCE_UPDATE}" = true ]; then
    systemctl stop kube-proxy
  fi
  systemctl start kube-proxy
  systemctl status kube-proxy
fi
