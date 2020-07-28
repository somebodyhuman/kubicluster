#/!bin/bash

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

REMAINING_ARGS=''
NODE_WORK_DIR=''
CLIENT_PORT=2379
CALICO_VERSION=3.11.3
FORCE_UPDATE=false

INITIAL_ETCD_CLUSTER=''
while [[ $# -gt 0 ]]; do
    key="$1"
    case "$key" in
        -nwd=*|--node-work-dir=*)
        NODE_WORK_DIR="${key#*=}"
        ;;
        -v=*|--version=*)
        CALICO_VERSION="${key#*=}"
        ;;
        -f|--force-update)
        FORCE_UPDATE=true
        ;;
        -cmu=*|--cluster-member-uri=*)
        PL=',' ; if [ "${INITIAL_ETCD_CLUSTER}" = "" ]; then PL=''; fi
        INITIAL_ETCD_CLUSTER="${INITIAL_ETCD_CLUSTER}${PL}${key#*=}"
        ;;
        *)
        REMAINING_ARGS="${REMAINING_ARGS} $key"
        ;;
    esac
    # Shift after checking all the cases to get the next option
    shift
done

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
  if ! (dpkg -s ca-certificates); then apt-get install -y ca-certificates; fi
  wget -q --show-progress --https-only --timestamping \
    "https://github.com/projectcalico/calicoctl/releases/download/v${CALICO_VERSION}/calicoctl" -O ${NODE_WORK_DIR}/calicoctl-${CALICO_VERSION}
else
  echo "calicoctl ${CALICO_VERSION} already exists"
fi

chmod +x ${NODE_WORK_DIR}/calicoctl-${CALICO_VERSION}

cat << EOF | tee ${CERTS_AND_CONFIGS_DIR}/calico-config.yaml
apiVersion: projectcalico.org/v3
kind: CalicoAPIConfig
metadata:
spec:
  etcdEndpoints: ${INITIAL_ETCD_CLUSTER}
  etcdKeyFile: ${CERTS_AND_CONFIGS_DIR}/calico-key.pem
  etcdCertFile: ${CERTS_AND_CONFIGS_DIR}/calico.pem
  etcdCACertFile: ${CERTS_AND_CONFIGS_DIR}/ca.pem
EOF
