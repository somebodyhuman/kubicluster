#/!bin/bash

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

source ${DIR}/../utils/env-variables "$@"

function wait_for_startup_to_complete() {
  attempts=0
  MAX_ATTEMPTS=20
  NEXUS_STARTED=1
  start_at='+0'
  if [ -f ${NODE_WORK_DIR}/sonatype-work/nexus3/log/nexus.log ]; then
    start_at="+$(wc -l ${NODE_WORK_DIR}/sonatype-work/nexus3/log/nexus.log)"
  fi
  while [[ ${attempts} -lt ${MAX_ATTEMPTS} ]]; do
    # TODO make this resumable i.e. try to connect to both template ip and target ip
    echo "(${attempts}) waiting for nexus to finish starting up ... "
    sleep 6

    if [ -f ${NODE_WORK_DIR}/sonatype-work/nexus3/log/nexus.log ] && tail -n ${start_at} ${NODE_WORK_DIR}/sonatype-work/nexus3/log/nexus.log | grep 'Started Sonatype Nexus' ; then
      NEXUS_STARTED=0
      attempts=${MAX_ATTEMPTS}
    fi
    attempts=$((${attempts}+1))
  done

  if [[ ${NEXUS_STARTED} -ne 0 ]]; then
    echo "Nexus failed to start within $((${MAX_ATTEMPTS}*6))."
    echo "Manual intervention is required before rerunning this script."
    exit ${NEXUS_STARTED}
  fi
}

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
# wait for nexus server to properly start (otherwise the following steps will fail)
wait_for_startup_to_complete

if ! grep allowCreation ${NODE_WORK_DIR}/sonatype-work/nexus3/etc/nexus.properties ; then
  echo "nexus.scripts.allowCreation=true" >>${NODE_WORK_DIR}/sonatype-work/nexus3/etc/nexus.properties
fi

systemctl restart nexus.service
wait_for_startup_to_complete

# prevent the auto-generated admin password from being deleted by interaction with the UI
if [ -f ${NODE_WORK_DIR}/sonatype-work/nexus3/admin.password ]; then
  mv -f ${NODE_WORK_DIR}/sonatype-work/nexus3/admin.password ${NODE_WORK_DIR}/nexus-admin.password
fi

## disabling anonymous access using the nexus REST scripting API
if ! git --version ; then
  apt-get install -y git
fi

if [ ! -d ${NODE_WORK_DIR}/nexus-scripting-examples ] || \
   [ "${FORCE_UPDATE}" = true ]; then
  if [ -d ${NODE_WORK_DIR}/nexus-scripting-examples ] ; then rm -rf ${NODE_WORK_DIR}/nexus-scripting-examples ; fi
  git clone https://github.com/sonatype-nexus-community/nexus-scripting-examples ${NODE_WORK_DIR}/nexus-scripting-examples
  sed -i "s#:admin123#:\$(cat ${NODE_WORK_DIR}/nexus-admin.password)#g" ${NODE_WORK_DIR}/nexus-scripting-examples/simple-shell-example/*.sh
fi

${NODE_WORK_DIR}/nexus-scripting-examples/simple-shell-example/create.sh ${NODE_WORK_DIR}/nexus-scripting-examples/simple-shell-example/anonymous.json
${NODE_WORK_DIR}/nexus-scripting-examples/simple-shell-example/run.sh anonymous false
grep -v allowCreation ${NODE_WORK_DIR}/sonatype-work/nexus3/etc/nexus.properties >${NODE_WORK_DIR}/sonatype-work/nexus3/etc/nexus-clean.properties
mv -f ${NODE_WORK_DIR}/sonatype-work/nexus3/etc/nexus-clean.properties ${NODE_WORK_DIR}/sonatype-work/nexus3/etc/nexus.properties
chown nexus:nexus ${NODE_WORK_DIR}/sonatype-work/nexus3/etc/nexus.properties
systemctl restart nexus.service
wait_for_startup_to_complete
