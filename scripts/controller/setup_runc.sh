#/!bin/bash

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

source ${DIR}/../utils/env-variables "$@"

# REMAINING_ARGS=''
#
# while [[ $# -gt 0 ]]; do
#     key="$1"
#     case "$key" in
#         -nwd=*|--node-work-dir=*)
#         NODE_WORK_DIR="${key#*=}"
#         ;;
#         -v=*|--version=*)
#         KUBERNETES_VERSION="${key#*=}"
#         ;;
#         -f|--force-update)
#         FORCE_UPDATE=true
#         ;;
#         *)
#         REMAINING_ARGS="${REMAINING_ARGS} $key"
#         ;;
#     esac
#     # Shift after checking all the cases to get the next option
#     shift
# done

KUBERNETES_PARENT_DIR=${NODE_WORK_DIR}/kubernetes-${KUBERNETES_VERSION}
KUBERNETES_DIR=${KUBERNETES_PARENT_DIR}/kubernetes
KUBERNETES_SERVER_DIR=${KUBERNETES_DIR}/server

KUBECTL_CMD=${KUBERNETES_SERVER_DIR}/bin/kubectl

cat << EOF | ${KUBECTL_CMD} apply  -f -
kind: RuntimeClass
apiVersion: node.k8s.io/v1beta1
metadata:
  name: runc
handler: runc
EOF
