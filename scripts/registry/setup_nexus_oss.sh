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

if ! systemctl is-active nexus.service ; then
  systemctl start nexus.service
  systemctl status nexus.service
  # wait for nexus server to properly start (otherwise the following steps will fail)
  wait_for_startup_to_complete
fi

if ! grep allowCreation ${NODE_WORK_DIR}/sonatype-work/nexus3/etc/nexus.properties ; then
  echo "nexus.scripts.allowCreation=true" >>${NODE_WORK_DIR}/sonatype-work/nexus3/etc/nexus.properties
fi

systemctl restart nexus.service
wait_for_startup_to_complete

# prevent the auto-generated admin password from being deleted by interaction with the UI
if [ -f ${NODE_WORK_DIR}/sonatype-work/nexus3/admin.password ]; then
  mv -f ${NODE_WORK_DIR}/sonatype-work/nexus3/admin.password ${NODE_WORK_DIR}/nexus-admin.password
fi

## configuring server using the nexus REST scripting API
if ! git --version ; then
  apt-get update
  apt-get install -y git
fi

if ! curl --version ; then
  apt-get update
  apt-get install -y curl
fi

if [ ! -d ${NODE_WORK_DIR}/nexus-scripting-examples ] || \
   [ "${FORCE_UPDATE}" = true ]; then
  if [ -d ${NODE_WORK_DIR}/nexus-scripting-examples ] ; then rm -rf ${NODE_WORK_DIR}/nexus-scripting-examples ; fi
  git clone https://github.com/sonatype-nexus-community/nexus-scripting-examples ${NODE_WORK_DIR}/nexus-scripting-examples
  sed -i "s#:admin123#:\$(cat ${NODE_WORK_DIR}/nexus-admin.password)#g" ${NODE_WORK_DIR}/nexus-scripting-examples/simple-shell-example/*.sh
fi

if ! grep '$@' ${NODE_WORK_DIR}/nexus-scripting-examples/simple-shell-example/list.sh ; then
  sed -i "s#/script'#/script' \"\$@\"#g" ${NODE_WORK_DIR}/nexus-scripting-examples/simple-shell-example/list.sh
fi

if -e /tmp/list.json ; then rm -f /tmp/list.json ; fi
${NODE_WORK_DIR}/nexus-scripting-examples/simple-shell-example/list.sh -o /tmp/list.json
echo "already available scripts in REST API:"
grep name /tmp/list.json

# configure anonymous access (as disabled)
if ! grep name /tmp/list.json | grep anonymous ; then
  ${NODE_WORK_DIR}/nexus-scripting-examples/simple-shell-example/create.sh ${NODE_WORK_DIR}/nexus-scripting-examples/simple-shell-example/anonymous.json
fi

${NODE_WORK_DIR}/nexus-scripting-examples/simple-shell-example/run.sh anonymous false

# configure docker repos
if [ ! -f ${NODE_WORK_DIR}/nexus-scripting-examples/simple-shell-example/docker.json ] || \
   [ "${FORCE_UPDATE}" = true ]; then
  cat << EOF | tee ${NODE_WORK_DIR}/nexus-scripting-examples/simple-shell-example/docker.json
{
  "name": "docker",
  "type": "groovy",
  "content": "repository.createDockerHosted('docker-internal', 4448, null); repository.createDockerProxy('docker-io','https://hub.docker.com', 'HUB', null, null, null); repository.createDockerGroup('docker-all', 4444, null, ['docker-io','docker-internal'])"
}
EOF
fi

if ! grep name /tmp/list.json | grep docker ; then
  ${NODE_WORK_DIR}/nexus-scripting-examples/simple-shell-example/create.sh ${NODE_WORK_DIR}/nexus-scripting-examples/simple-shell-example/docker.json
fi
${NODE_WORK_DIR}/nexus-scripting-examples/simple-shell-example/run.sh docker

# TODO delete scripts

grep -v allowCreation ${NODE_WORK_DIR}/sonatype-work/nexus3/etc/nexus.properties >${NODE_WORK_DIR}/sonatype-work/nexus3/etc/nexus-clean.properties
mv -f ${NODE_WORK_DIR}/sonatype-work/nexus3/etc/nexus-clean.properties ${NODE_WORK_DIR}/sonatype-work/nexus3/etc/nexus.properties
chown nexus:nexus ${NODE_WORK_DIR}/sonatype-work/nexus3/etc/nexus.properties
systemctl restart nexus.service
wait_for_startup_to_complete

fn=nexus-https
mkdir -p ${NODE_WORK_DIR}/nginx/${fn}

cat << EOF | tee ${NODE_WORK_DIR}/nginx/${fn}/csr.conf
[ req ]
prompt = no
distinguished_name = req_distinguished_name
x509_extensions = san_self_signed

[ req_distinguished_name ]
CN=${fn}
subjectAltName = @alt_names

[ san_self_signed ]
subjectAltName = @alt_names
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always,issuer
basicConstraints = CA:true
keyUsage = nonRepudiation, digitalSignature, keyEncipherment, dataEncipherment, keyCertSign, cRLSign
extendedKeyUsage = serverAuth, clientAuth, timeStamping

[ req_ext ]
subjectAltName = @alt_names

[ v3_ca ]
subjectAltName = @alt_names

[ alt_names ]
DNS.1   = localhost
IP.1    = 127.0.0.1
IP.2    = ${CLUSTER_NET_IP}
EOF



openssl req \
  -extensions san_self_signed \
  -newkey rsa:2048 -nodes \
  -keyout "${NODE_WORK_DIR}/nginx/${fn}/privkey.pem" \
  -x509 -sha256 -days 3650 \
  -config <(cat ${NODE_WORK_DIR}/nginx/${fn}/csr.conf) \
  -out "${NODE_WORK_DIR}/nginx/${fn}/fullchain.pem"
openssl x509 -noout -text -in "${NODE_WORK_DIR}/nginx/${fn}/fullchain.pem"


# install docker and nginx - we can uninstall docker at the end - it's only there to test the registry connection
apt-get install -y \
    apt-transport-https \
    ca-certificates \
    curl \
    gnupg-agent \
    software-properties-common
curl -fsSL https://download.docker.com/linux/debian/gpg | apt-key add -
add-apt-repository \
   "deb [arch=amd64] https://download.docker.com/linux/debian \
   $(lsb_release -cs) \
   stable"
apt-get update
apt-get install -y nginx docker-ce docker-ce-cli

# TODO make docker-internal and docker-all ports configurable
mkdir -p /etc/docker/certs.d/${CLUSTER_NET_IP}
mkdir -p /etc/docker/certs.d/${CLUSTER_NET_IP}:443
mkdir -p /etc/docker/certs.d/${CLUSTER_NET_IP}:6666
mkdir -p /etc/docker/certs.d/${CLUSTER_NET_IP}:6668

cp -f ${NODE_WORK_DIR}/nginx/${fn}/fullchain.pem /etc/docker/certs.d/${CLUSTER_NET_IP}/
cp -f ${NODE_WORK_DIR}/nginx/${fn}/fullchain.pem /etc/docker/certs.d/${CLUSTER_NET_IP}:443/
cp -f ${NODE_WORK_DIR}/nginx/${fn}/fullchain.pem /etc/docker/certs.d/${CLUSTER_NET_IP}:6666/
cp -f ${NODE_WORK_DIR}/nginx/${fn}/fullchain.pem /etc/docker/certs.d/${CLUSTER_NET_IP}:6668/

echo "{ \"insecure-registries\": [\"${CLUSTER_NET_IP}\", \"${CLUSTER_NET_IP}:6666\"] }" >/etc/docker/daemon.json

systemctl restart docker.service

# redirecting https requests to http nexus
cat << EOF | tee /etc/nginx/conf.d/nexus-https.conf
server {
    listen 80;
    listen [::]:80;
    server_name "~^\d+\.\d+\.\d+\.\d+\$" localhost;

    location / {
        proxy_pass http://localhost:8081;
	proxy_set_header Host \$host:\$server_port;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto http;
    }
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name "~^\d+\.\d+\.\d+\.\d+\$" localhost;
    ssl_certificate ${NODE_WORK_DIR}/nginx/${fn}/fullchain.pem;
    ssl_certificate_key ${NODE_WORK_DIR}/nginx/${fn}/privkey.pem;
    client_max_body_size 0;

    location / {
        proxy_pass http://localhost:8081;
	      proxy_set_header Host \$host:\$server_port;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
    }
}

# correlates to your http connector (defined in the docker-all repo inside nexus)
server {
    listen 6666;
    server_name "~^\d+\.\d+\.\d+\.\d+\$" localhost;
    keepalive_timeout 60;
    ssl on;
    ssl_certificate ${NODE_WORK_DIR}/nginx/${fn}/fullchain.pem;
    ssl_certificate_key ${NODE_WORK_DIR}/nginx/${fn}/privkey.pem;
    ssl_ciphers HIGH:!kEDH:!ADH:!MD5:@STRENGTH;
    ssl_session_cache shared:TLSSSL:16m;
    ssl_session_timeout 10m;
    ssl_prefer_server_ciphers on;
    client_max_body_size 1G;
    chunked_transfer_encoding on;

    location / {

      access_log              /var/log/nginx/docker.log;
      proxy_set_header        Host \$http_host;
      proxy_set_header        X-Real-IP \$remote_addr;
      proxy_set_header        X-Forwarded-For \$proxy_add_x_forwarded_for;
      proxy_set_header        X-Forwarded-Proto "https";
      proxy_pass              http://localhost:4444;
      proxy_read_timeout      90;

    }
}
# correlates to your http connector (defined in the docker-internal repo inside nexus)
server {
    listen 6668;
    server_name "~^\d+\.\d+\.\d+\.\d+\$" localhost;
    keepalive_timeout 60;
    ssl on;
    ssl_certificate ${NODE_WORK_DIR}/nginx/${fn}/fullchain.pem;
    ssl_certificate_key ${NODE_WORK_DIR}/nginx/${fn}/privkey.pem;
    ssl_ciphers HIGH:!kEDH:!ADH:!MD5:@STRENGTH;
    ssl_session_cache shared:TLSSSL:16m;
    ssl_session_timeout 10m;
    ssl_prefer_server_ciphers on;
    client_max_body_size 1G;
    chunked_transfer_encoding on;

    location / {

      access_log              /var/log/nginx/docker.log;
      proxy_set_header        Host \$http_host;
      proxy_set_header        X-Real-IP \$remote_addr;
      proxy_set_header        X-Forwarded-For \$proxy_add_x_forwarded_for;
      proxy_set_header        X-Forwarded-Proto "https";
      proxy_pass              http://localhost:4448;
      proxy_read_timeout      90;

    }
}
EOF

systemctl restart nginx.service

mkdir ~/.docker
echo "{ \"auths\": { \"${CLUSTER_NET_IP}:6666\": { \"auth\": \"$(echo -n "admin:$(cat /opt/kubicluster/nexus-admin.password)" | base64)\" } } }" >~/.docker/config.json

timeout 10s bash <<EOT
function tryLogin {
  docker login https://${CLUSTER_NET_IP}:6666
}

tryLogin
EOT
