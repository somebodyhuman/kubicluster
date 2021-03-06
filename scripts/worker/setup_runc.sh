#/!bin/bash

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

source ${DIR}/../utils/env-variables "$@"

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

if [ ! -h /usr/local/bin/runc ] || [ "${FORCE_UPDATE}" = true ]; then
  if [ -h /usr/local/bin/runc ]; then rm -f /usr/local/bin/runc; fi
  ln -s ${NODE_WORK_DIR}/runc-v${RUNC_VERSION}.amd64 /usr/local/bin/runc
fi
