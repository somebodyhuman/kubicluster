#/!bin/bash

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

source ${DIR}/../utils/env-variables "$@"

if ! java -version || java -version | head -n 1 | grep -v 'java version "1.8.' ; then
  apt-get update
  apt-get install -y openjdk-8-jre
fi

if [ ! -f ${NODE_WORK_DIR}/nexus-${NEXUS_VERSION}-unix.tar.gz ]; then
  echo "${NODE_WORK_DIR}/nexus-${NEXUS_VERSION}-unix.tar.gz does not exist yet"
  NEXUS_MAJOR=$(echo ${NEXUS_VERSION} | cut -d '.' -f 1)
  wget -q --show-progress --https-only --timestamping \
    "http://download.sonatype.com/nexus/${NEXUS_MAJOR}/nexus-${NEXUS_VERSION}-unix.tar.gz" -O ${NODE_WORK_DIR}/nexus-${NEXUS_VERSION}-unix.tar.gz
fi


# create service user
if ! grep nexus /etc/passwd ; then
  useradd -s /sbin/nologin -d ${NODE_WORK_DIR}/nexus nexus
fi

if [ ! -d ${NODE_WORK_DIR}/nexus-${NEXUS_VERSION} ]; then
  mkdir -p ${NODE_WORK_DIR}/nexus-${NEXUS_VERSION}
  tar -xvzf ${NODE_WORK_DIR}/nexus-${NEXUS_VERSION}-unix.tar.gz -C ${NODE_WORK_DIR}/nexus-${NEXUS_VERSION}
  chown -R nexus:nexus ${NODE_WORK_DIR}/nexus-${NEXUS_VERSION}
fi

if [ ! -e ${NODE_WORK_DIR}/nexus ] || \
   [ "${FORCE_UPDATE}" = true ]; then
     # TODO use -e instead of -d or -f on symbolic link existence checks in other scripts as well
    if [ -e ${NODE_WORK_DIR}/nexus ]; then rm -f ${NODE_WORK_DIR}/nexus; fi
    ln -s ${NODE_WORK_DIR}/nexus-${NEXUS_VERSION}/nexus-${NEXUS_VERSION} ${NODE_WORK_DIR}/nexus
fi

if [ ! -e ${NODE_WORK_DIR}/sonatype-work ] || \
   [ "${FORCE_UPDATE}" = true ]; then
    if [ -e ${NODE_WORK_DIR}/sonatype-work ]; then rm -f ${NODE_WORK_DIR}/sonatype-work; fi
    ln -s ${NODE_WORK_DIR}/nexus-${NEXUS_VERSION}/sonatype-work ${NODE_WORK_DIR}/sonatype-work
fi

if ! grep nexus ${NODE_WORK_DIR}/nexus/bin/nexus.rc ; then
  echo "run_as_user=\"nexus\"" >>${NODE_WORK_DIR}/nexus/bin/nexus.rc
fi

if [ ! -f /etc/systemd/system/nexus.service ] || \
   [ "${FORCE_UPDATE}" = true ]; then
  cat << EOF | tee /etc/systemd/system/nexus.service
  [Unit]
  Description=nexus service
  After=network.target

  [Service]
  Type=forking
  LimitNOFILE=65536
  ExecStart=${NODE_WORK_DIR}/nexus/bin/nexus start
  ExecStop=${NODE_WORK_DIR}/nexus/bin/nexus stop
  User=nexus
  Restart=on-abort
  TimeoutSec=600

  [Install]
  WantedBy=multi-user.target
EOF
  systemctl daemon-reload
fi

systemctl enable nexus.service
if [ "${FORCE_UPDATE}" = true ]; then
  systemctl stop nexus.service
fi
systemctl start nexus.service
systemctl status nexus.service

# TODO check nexus status output
