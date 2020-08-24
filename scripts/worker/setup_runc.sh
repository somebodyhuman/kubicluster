#/!bin/bash

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

source ${DIR}/../utils/env-variables "$@"

# REMAINING_ARGS=''
# while [[ $# -gt 0 ]]; do
#     key="$1"
#     case "$key" in
#       -nwd=*|--node-work-dir=*)
#         NODE_WORK_DIR="${key#*=}"
#         ;;
#       -v=*|--version=*)
#         RUNC_VERSION="${key#*=}"
#         ;;
#       -f|--force-update)
#         FORCE_UPDATE=true
#         ;;
#       *)
#         REMAINING_ARGS="${REMAINING_ARGS} $key"
#         ;;
#     esac
#     # Shift after checking all the cases to get the next option
#     shift
# done

if ! which curl; then
  apt-get install -y wget
fi

if [ ! -f ${NODE_WORK_DIR}/runc-v${RUNC_VERSION}.amd64 ]; then
  if ! (dpkg -s ca-certificates); then apt-get install -y ca-certificates; fi
  wget -q --show-progress --https-only --timestamping \
  "https://github.com/opencontainers/runc/releases/download/v${RUNC_VERSION}/runc.amd64" -O ${NODE_WORK_DIR}/runc-v${RUNC_VERSION}.amd64
  # TODO handle wget exit code != 0
  chmod +x ${NODE_WORK_DIR}/runc-v${RUNC_VERSION}.amd64
fi

if [ ! -f /usr/local/bin/runc ] || [ "${FORCE_UPDATE}" = true ]; then
  if [ -f /usr/local/bin/runc ]; then rm -f /usr/local/bin/runc; fi
  ln -s ${NODE_WORK_DIR}/runc-v${RUNC_VERSION}.amd64 /usr/local/bin/runc
fi
