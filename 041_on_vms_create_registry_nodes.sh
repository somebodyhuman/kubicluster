#/!bin/bash

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

function setup_nexus_oss() {
  echo 'setting up nexus oss'
}

source ${DIR}/utils/env-variables "$@"

case "${SUB_CMD}" in
  setup_nexus_oss)
  # TODO rargs may be removed ?
    setup_nexus_oss "${RARGS_ARRAY[@]}"
    ;;
  help)
    echo -e "\nDefault usage:\nkubicluster create-registry -r [REGISTRY_HOSTNAME],[REGISTRY_CLUSTER_NET_IP],[REGISTRY_HYPERVISOR_NET_IP] [OPTIONAL_ARGUMENTS]\n\t This executes all subcommands in order"
    echo -e "\nSub-command usage via kubicluster command:\nkubicluster create-registry [setup_nexus_oss] [OPTIONAL_ARGUMENTS]"
    echo -e "\nDirect sub-command usage:\n$0 [setup_nexus_oss] [OPTIONAL_ARGUMENTS]"
    echo -e "\nOPTIONAL ARGUMENTS:"
    echo -e "-f|--force-update\n\t force update, caution this updates every file affected by the run command/sub-command"
    echo -e "-d|--debug\n\t show debug messages"

    echo -e "\nOPTIONAL ENVIRONMENT VARIABLES (=default_value):"
    echo -e "WORKDIR=./work\n\t use a custom workdir on the HYPERVISOR (default is a dir called 'work' in the same directory as the kubicluster executable or $0)"
    # TODO add less commonly changed env variables from ./utils/env-variables (and make them configurable)
    ;;
  *)
    setup_nexus_oss
    ;;
esac
