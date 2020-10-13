#/!bin/bash

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

source ${DIR}/../utils/env-variables "$@"

CERTS_AND_CONFIGS_DIR=${NODE_WORK_DIR}/certs_and_configs

# ipt_set is an alias of xt_set (https://github.com/kubernetes/kubernetes/issues/32625), so on debian only checking for xt_set
# modules required for calico 3.12.x and later
# ip_set ip_tables ip6_tables ipt_REJECT ipt_rpfilter \
# nf_conntrack_netlink nf_conntrack_proto_sctp sctp \
# xt_addrtype xt_comment xt_conntrack xt_icmp xt_icmp6 xt_ipvs \
# xt_mark xt_multiport xt_rpfilter xt_sctp xt_set xt_u32 ipip; do

KERNEL_MODULES_FAILED=0
# check modules required for calico 3.11.3 and later
for module in \
  nf_conntrack_netlink ip_tables ip6_tables ip_set xt_set \
  ipt_rpfilter ipt_REJECT ipip; do
  if [ "$(grep ${module} /etc/modules)" = "" ]; then echo -e "\n${module}" >>/etc/modules ; modprobe ${module} ; fi
  if ! lsmod | grep ${module}; then echo "kernel module ${module} could not be activated" ; KERNEL_MODULES_FAILED=$((${KERNEL_MODULES_FAILED} + 1)) ; fi
done

if [[ ${KERNEL_MODULES_FAILED} -gt 0 ]]; then exit ${KERNEL_MODULES_FAILED} ; fi

if [ ! -f ${NODE_WORK_DIR}/calicoctl-${CALICO_VERSION} ]; then
  if ! (dpkg -s ca-certificates); then apt-get update ; apt-get install -y ca-certificates; fi
  wget -q --show-progress --https-only --timestamping \
    "https://github.com/projectcalico/calicoctl/releases/download/v${CALICO_VERSION}/calicoctl" -O ${NODE_WORK_DIR}/calicoctl-${CALICO_VERSION}
else
  echo "calicoctl ${CALICO_VERSION} already exists"
fi

chmod +x ${NODE_WORK_DIR}/calicoctl-${CALICO_VERSION}

cat <<EOF | tee /etc/sysctl.d/992-cni-calico.conf
net.netfilter.nf_conntrack_max=1000000
EOF
sysctl --system

if [ ! -d /etc/cni/net.d ]; then mkdir -p /etc/cni/net.d; fi
# TODO check mtu, default is "mtu": 1500,
cat << EOF | tee /etc/cni/net.d/10-calico.conflist
{
  "name": "k8s-pod-network",
  "cniVersion": "0.3.1",
  "plugins": [
    {
      "type": "calico",
      "log_level": "info",
      "datastore_type": "kubernetes",
      "mtu": 1440,
      "ipam": {
          "type": "calico-ipam"
      },
      "policy": {
          "type": "k8s"
      },
      "kubernetes": {
          "kubeconfig": "${CERTS_AND_CONFIGS_DIR}/calico-cni.kubeconfig"
      }
    },
    {
      "type": "portmap",
      "snat": true,
      "capabilities": {"portMappings": true}
    }
  ]
}
EOF

if [ ! -f ${NODE_WORK_DIR}/calico-${CALICO_VERSION} ]; then
  if ! (dpkg -s ca-certificates); then apt-get update ; apt-get install -y ca-certificates; fi
  wget -q --show-progress --https-only --timestamping \
    "https://github.com/projectcalico/cni-plugin/releases/download/v${CALICO_VERSION}/calico-amd64" -O ${NODE_WORK_DIR}/calico-${CALICO_VERSION}
  chmod 755 ${NODE_WORK_DIR}/calico-${CALICO_VERSION}
else
  echo "calico cni plugin ${CALICO_VERSION} already exists"
fi

if [ ! -f ${NODE_WORK_DIR}/calico-ipam-${CALICO_VERSION} ]; then
  if ! (dpkg -s ca-certificates); then apt-get update ; apt-get install -y ca-certificates; fi
  wget -q --show-progress --https-only --timestamping \
    "https://github.com/projectcalico/cni-plugin/releases/download/v${CALICO_VERSION}/calico-ipam-amd64" -O ${NODE_WORK_DIR}/calico-ipam-${CALICO_VERSION}
    chmod 755 ${NODE_WORK_DIR}/calico-ipam-${CALICO_VERSION}
else
  echo "calico cni plugin ipam ${CALICO_VERSION} already exists"
fi

if [ ! -d /opt/cni/bin ]; then mkdir -p /opt/cni/bin; fi
if [ -f /opt/cni/bin/calico ]; then rm -f /opt/cni/bin/calico; fi
if [ -f /opt/cni/bin/calico-ipam ]; then rm -f /opt/cni/bin/calico-ipam; fi
ln -s ${NODE_WORK_DIR}/calico-${CALICO_VERSION} /opt/cni/bin/calico
ln -s ${NODE_WORK_DIR}/calico-ipam-${CALICO_VERSION} /opt/cni/bin/calico-ipam
