#/!bin/bash

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

KATA_VERSION='1.11.2'

while [[ $# -gt 0 ]]; do
    key="$1"
    case "$key" in
        -v=*|--version=*)
        KATA_VERSION="${key#*=}"
        ;;
    esac
    # Shift after checking all the cases to get the next option
    shift
done

if ! which curl; then
  apt-get install -y curl
fi

# container runtime requirements
# kubernets preps
cat <<EOF | tee /etc/sysctl.d/container-runtimes.conf
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
net.ipv6.ip_forward = 1
EOF

sysctl --system

KERNEL_MODULES_FAILED=0
for module in br_netfilter overlay; do
  if [ "$(grep ${module} /etc/modules)" = "" ]; then echo -e "\n${module}" >>/etc/modules ; modprobe ${module} ; fi
  if ! lsmod | grep ${module}; then echo "kernel module ${module} could not be activated" ; KERNEL_MODULES_FAILED=$((${KERNEL_MODULES_FAILED} + 1)) ; fi
done

if [[ ${KERNEL_MODULES_FAILED} -gt 0 ]]; then exit ${KERNEL_MODULES_FAILED} ; fi

# the container runtimes
# according to https://github.com/kata-containers/documentation/blob/master/install/debian-installation-guide.md
export DEBIAN_FRONTEND=noninteractive
ARCH=$(arch)
BRANCH='master'
MAJOR_MINOR=''
if [ "${KATA_VERSION}" != "master" ]; then
  MAJOR_MINOR="$(echo ${KATA_VERSION} | cut -d '.' -f 1).$(echo ${KATA_VERSION} | cut -d '.' -f 2)"
  BRANCH="stable-${MAJOR_MINOR}"
  MAJOR_MINOR="=${MAJOR_MINOR}"
fi
if which kata-runtime && [ "$(kata-runtime --version | head -n 1 | cut -d ' ' -f 4 | cut -d '-' -f 1)" = "${KATA_VERSION}" ]; then
  echo "kata ${KATA_VERSION} already exists"
else
  source /etc/os-release
  [ "$ID" = debian ] && [ -z "$VERSION_ID" ] && echo >&2 "ERROR: Debian unstable not supported.
  You can try stable packages here:
  http://download.opensuse.org/repositories/home:/katacontainers:/releases:/${ARCH}:/${BRANCH}" && exit 1
  sh -c "echo 'deb http://download.opensuse.org/repositories/home:/katacontainers:/releases:/${ARCH}:/${BRANCH}/Debian_${VERSION_ID}/ /' > /etc/apt/sources.list.d/kata-containers.list"
  curl -sL  http://download.opensuse.org/repositories/home:/katacontainers:/releases:/${ARCH}:/${BRANCH}/Debian_${VERSION_ID}/Release.key | apt-key add -
  apt-get update
  apt-get -y purge kata-* qemu-vanilla
  apt-get -y install kata-runtime${MAJOR_MINOR}* kata-proxy${MAJOR_MINOR}* kata-shim${MAJOR_MINOR}*
fi
