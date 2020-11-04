#/!bin/bash

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

source ${DIR}/../utils/env-variables "$@"

CNI_PLUGINS_DIR=${NODE_WORK_DIR}/cni-plugins-${CNI_PLUGINS_VERSION}
CONTAINERD_DIR=${NODE_WORK_DIR}/containerd-${CONTAINERD_VERSION}

# download and extract cni plugins
if [ ! -f ${NODE_WORK_DIR}/cni-plugins-${CNI_PLUGINS_VERSION}.tar.gz ]; then
  if ! (dpkg -s ca-certificates); then apt-get update ; apt-get install -y ca-certificates; fi
  wget -q --show-progress --https-only --timestamping \
    "https://github.com/containernetworking/plugins/releases/download/v${CNI_PLUGINS_VERSION}/cni-plugins-linux-amd64-v${CNI_PLUGINS_VERSION}.tgz" -O ${NODE_WORK_DIR}/cni-plugins-${CNI_PLUGINS_VERSION}.tar.gz
fi

if [ ! -d ${CNI_PLUGINS_DIR} ]; then
  mkdir ${CNI_PLUGINS_DIR}
  tar -xzf ${NODE_WORK_DIR}/cni-plugins-${CNI_PLUGINS_VERSION}.tar.gz -C ${CNI_PLUGINS_DIR}
fi

# configure cni
mkdir -p ${CNI_CONF_DIR}
if [ ! -f ${CNI_CONF_DIR}/10-kubicluster.conf ] || [ "${FORCE_UPDATE}" = true ]; then
  cat << EOF | tee ${CNI_CONF_DIR}/10-kubicluster.conf
{
	"cniVersion": "0.2.0",
	"name": "kubicluster",
	"type": "bridge",
	"bridge": "cni0",
	"isGateway": true,
	"ipMasq": true,
	"ipam": {
		"type": "host-local",
		"subnet": "172.19.0.0/24",
		"routes": [
			{ "dst": "0.0.0.0/0" }
		]
	}
}
EOF
fi

# download and extract containerd
if [ ! -f ${NODE_WORK_DIR}/containerd-${CONTAINERD_VERSION}.tar.gz ]; then
  if ! (dpkg -s ca-certificates); then apt-get update ; apt-get install -y ca-certificates; fi
  wget -q --show-progress --https-only --timestamping \
    "https://github.com/containerd/containerd/releases/download/v${CONTAINERD_VERSION}/containerd-${CONTAINERD_VERSION}-linux-amd64.tar.gz" -O ${NODE_WORK_DIR}/containerd-${CONTAINERD_VERSION}.tar.gz
fi

if [ ! -d ${CONTAINERD_DIR} ]; then
  mkdir ${CONTAINERD_DIR}
  tar -xzf ${NODE_WORK_DIR}/containerd-${CONTAINERD_VERSION}.tar.gz -C ${CONTAINERD_DIR}
fi

if [ ! -f /usr/local/bin/containerd ] || \
   [ "${FORCE_UPDATE}" = true ]; then
  for item in containerd containerd-shim containerd-shim-runc-v1 containerd-shim-runc-v2 containerd-stress ctr; do
    if [ -h /usr/local/bin/${item} ]; then rm -f /usr/local/bin/${item} ; fi
    ln -s ${CONTAINERD_DIR}/bin/${item} /usr/local/bin/${item}
  done
fi

CONTAINERD_RESULT=$(containerd --version | cut -d ' ' -f 3)
if [ "${CONTAINERD_RESULT}" != "v${CONTAINERD_VERSION}" ]; then
  echo "containerd ${CONTAINERD_VERSION} installation failed."
  exit 1
else
  echo "containerd version is ${CONTAINERD_VERSION}."
fi

# configure containerd
if [ ! -f /etc/containerd/config.toml ] || [ "${FORCE_UPDATE}" = true ]; then
  mkdir -p /etc/containerd/
  rm -f ${NODE_CERTS_AND_CONFIGS_DIR}/config-*.toml

  echo '[plugins]' >${NODE_CERTS_AND_CONFIGS_DIR}/config-before-registries.toml

  for node in ${REGISTRIES}; do
    name_ip=($(echo $node | tr "," "\n"))
    if [ ! -e ${NODE_CERTS_AND_CONFIGS_DIR}/config-registries-mirrors.toml ]; then
      echo '  [plugins.cri.registry]' >${NODE_CERTS_AND_CONFIGS_DIR}/config-registries-mirrors.toml
      echo '    [plugins.cri.registry.mirrors]' >>${NODE_CERTS_AND_CONFIGS_DIR}/config-registries-mirrors.toml
    fi
    #TODO allow port to be configured
    echo "      [plugins.cri.registry.mirrors.\"${name_ip[1]}:6666\"]" >>${NODE_CERTS_AND_CONFIGS_DIR}/config-registries-mirrors.toml
    echo "        endpoint = [\"https://${name_ip[1]}:6666\"]" >>${NODE_CERTS_AND_CONFIGS_DIR}/config-registries-mirrors.toml
  done

  for node in ${REGISTRIES}; do
    name_ip=($(echo $node | tr "," "\n"))
    if [ ! -e ${NODE_CERTS_AND_CONFIGS_DIR}/config-registries.toml ]; then
      echo '    [plugins.cri.registry.configs]' >>${NODE_CERTS_AND_CONFIGS_DIR}/config-registries.toml
    fi
    #TODO allow port to be configured
    echo "      [plugins.cri.registry.configs.\"${name_ip[1]}:6666\".tls]" >>${NODE_CERTS_AND_CONFIGS_DIR}/config-registries.toml
    echo "        ca_file = \"${NODE_CERTS_AND_CONFIGS_DIR}/${name_ip[0]}-nexus-fullchain.pem\"" >>${NODE_CERTS_AND_CONFIGS_DIR}/config-registries.toml
  done

  cat << EOF | tee ${NODE_CERTS_AND_CONFIGS_DIR}/config-after-registries.toml
  [plugins.cri.containerd]
    no_pivot = false

  [plugins.cri.containerd.runtimes]
    [plugins.cri.containerd.runtimes.runc]
       runtime_type = "io.containerd.runc.v1"
       [plugins.cri.containerd.runtimes.runc.options]
         NoPivotRoot = false
         NoNewKeyring = false
         ShimCgroup = ""
         IoUid = 0
         IoGid = 0
         BinaryName = "runc"
         Root = ""
         CriuPath = ""
         SystemdCgroup = false
    [plugins.cri.containerd.runtimes.kata]
      runtime_type = "io.containerd.kata.v2"
  [plugins.cri.containerd.default_runtime]
      runtime_type = "io.containerd.kata.v2"
  [plugins.cri.cni]
    # conf_dir is the directory in which the admin places a CNI conf.
    conf_dir = "${CNI_CONF_DIR}"
EOF

  cat ${NODE_CERTS_AND_CONFIGS_DIR}/config-before-registries.toml \
      ${NODE_CERTS_AND_CONFIGS_DIR}/config-registries-mirrors.toml \
      ${NODE_CERTS_AND_CONFIGS_DIR}/config-registries.toml \
      ${NODE_CERTS_AND_CONFIGS_DIR}/config-after-registries.toml >/etc/containerd/config.toml
fi

if [ ! -f /etc/systemd/system/containerd.service ] || \
   [ "$(systemctl status containerd.service | grep running)" = "" ] || \
   [ ! -f /usr/local/bin/containerd ] || \
   [ "${FORCE_UPDATE}" = true ]; then
  if [ ! -f /etc/systemd/system/containerd.service ] || \
     [ "${FORCE_UPDATE}" = true ]; then
    cat << EOF | tee /etc/systemd/system/containerd.service
[Unit]
Description=containerd container runtime
Documentation=https://containerd.io
After=network.target

[Service]
ExecStartPre=/sbin/modprobe overlay
ExecStart=/usr/local/bin/containerd
Restart=always
RestartSec=5
Delegate=yes
KillMode=process
OOMScoreAdjust=-999
LimitNOFILE=1048576
LimitNPROC=infinity
LimitCORE=infinity

[Install]
WantedBy=multi-user.target
EOF
      systemctl daemon-reload
    fi

  systemctl enable containerd.service
  if [ "${FORCE_UPDATE}" = true ]; then
    systemctl stop kube-apiserver
  fi
  systemctl start containerd.service
  systemctl status containerd.service
fi
