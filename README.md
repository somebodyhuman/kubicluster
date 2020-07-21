# kubicluster

kubicluster is a bash script collection that helps you setup a kubernetes cluster inside virtual machines from scratch. It's predominant purpose is to help you to learn the ins and outs of kubernetes. Of course, it can also be used as a basis to (semi-)automate your production cluster setup.

It currently supports (TODO give minimal versions):
* hypervisor OS: debian10
  * underlying virtualisation: KVM (in turn relying on virsh and libvirt-qemu)
* guest OS for (controller and worker) nodes: debian9 (debian9 is used due to an unresolved kata setup issue on debian10)
  * high-level container-runtime: containerd
  * low-level container-runtime: kata
  * kubernetes networking: calica

If you would like to see other options supported as well, feel free to open a PR.

kubicluster emphasizes runtime security and workload isolation and therefore uses the kata containers as the default runtime.

## Prerequisites

You should know the basics about kvm, virsh and libvirt-qemu (or any other underlying virtualisation you might want to use). You should be familiar with the command line. All scripts are written in bash to keep the entry level barrier as low as possible (picking a higher level programming makes it more difficult to clearly see how all the tools interact on the command line level).

You should have a clean virtual machine image with a fresh, empty install debian/ubuntu that can be used as a template for controller nodes and worker nodes. Inside this VM the root user needs to have ssh access using a key file. This can be revoked once the kubicluster setup is completed.

## Basic Ideas / "Features"

* use kubicluster from the master hypervisor in your cluster to manage your kubernetes cluster across all hypervisors
* everything cluster-specific to spin up controlleres and worker nodes and extend the cluster using more hypervisors resides in your working directory `./work`. This includes things like kubicluster certs, configs, base images, etc., so backup/restore procedures are easy to setup - just backup this directory by your favorite means (e.g. tracking this directory as a separate git repository - despite the flaw that commiting huge binaries like image files is considered bad practice ;-)
* private keys are residing inside the master hypervisor and are NOT accessible from within the kubicluster (from controller nodes or worker nodes)
* load balancer for controller nodes is integrated into the first controller node on the master hypervisor

***Some things are not yet fully implemented in all scripts / steps, including:***
* supporting different image format types (only qcow2 is supported in all scripts already)

## What each script is doing

### 000_prepare_hypervisor.sh
* installs kvm, virsh, libvirt-qemu
* install dependencies curl, ssh, ...
* puts the base image for all vms into the default location ./work/imgs/vm-template.(img|qcow2|...)

**NOTE: install_dependencies and setup_virtualisation should run on any debian/ubuntu hypervisor without problems, for other distros you need to execute the corresponding commands yourself, or better yet - submit a PR to this repo ;-)**

***Usage***:
```bash
./000_prepare_hypervisor.sh install_dependencies
./000_prepare_hypervisor.sh setup_virtualisation
# set_vm_template file_path ip_of_template
# warns you if the template exists already on the hypervisor
./000_prepare_hypervisor.sh set_vm_template /path/to/file.(img|qcow2|...) 192.168.122.254

# run all three subcommands in the correct order: install_dependencies, setup_virtualisation, set_vm_template
./000_prepare_hypervisor.sh /path/to/file.qcow2 192.168.122.254
```

### 010_on_hypervisor_generate_certs_and_configs.sh
* installs cfssl on the master hypervisor
* checks if cfssl is installed / otherwise it installs it again
* generates a certificate authority and the required certificates

***Usage***:
```bash
# turn the current hypervisor into the certificate authority
./010_on_hypervisor_generate_certs_and_configs.sh generate_ca

# ensure certs needed to setup the system exist, this generates a cert for the following entitites: admin kube-controller-man kube-proxy kube-scheduler
# certs are placed in ./work/certs_and_configs
# already existing certs are NOT overwritten
# if you want to regenerate an existing certificate delete it first inside ./work/certs_and_configs
./010_on_hypervisor_generate_certs_and_configs.sh generate_system_certs

# ensure certs needed for the workers given as arguments exist (format: hostname=ip_on_hypervisor)
# certs are placed in ./work/certs_and_configs
# already existing certs are NOT overwritten
# if you want to regenerate an existing certificate delete it first inside ./work/certs_and_configs
# note: you manage IP allocation, so be sure you do not have IP conflicts between worker nodes on the same hypervisor
./010_on_hypervisor_generate_certs_and_configs.sh generate_worker_certs kubenode-0001=192.168.122.11 kubenode-0002=192.168.122.12

# run all subcommands at once in the correct order: generate_ca, generate_system_certs, generate_worker_certs
./010_on_hypervisor_generate_certs_and_configs.sh kubenode-0001=192.168.122.11 kubenode-0002=192.168.122.12

# the following env variables can be set to adjust the results of any command of this script
# the values used here are the default values, if you would not explicitely set the variable
# the controller ip can be the ip of a specific controller or of a load balancer in front of the controllers
CUSTOM_RSA_KEYLENGTH=2048 CUSTOM_CFSSL_VERSION=1.2 ./010_on_hypervisor_generate_certs_and_configs.sh --controller-ip=192.168.122.2 kubenode-0001=192.168.122.11 kubenode-0002=192.168.122.12
```

### 011_on_hypervisor_create_vms.sh
* creates vms on the hypervisor using virsh, a template image and a template xml (if you want to use a new template you have to run `000_prepare_hypervisor.sh` again)

***Usage***:
```bash
# create a vm on the master hypervisor (format hostname=ip)
./011_on_hypervisor_create_vms.sh kubenode-0001=192.168.122.11 kubenode-0002=192.168.122.12
```

### 021_on_hypervisor_create_controller_nodes.sh
* creates standard directory structure
* upload necessary certs and config files
* install dependencies
* install kubernetes tools as services

```bash
# turn vms into controller nodes (format -c hostname=ip)
./021_on_hypervisor_create_controller_nodes.sh -c kubemaster-01=192.168.122.03 -c kubemaster-0002=192.168.122.04
```

## Example workflows:

The following example workflows show you how to setup different kinds of networks and how to scale them up and down.

### simple: Single hypervisor with One controller and Two worker nodes (Single-One-Two)
```bash
# set the controller ip:
# this is either: the ip of your one and only controller
# or: the ip of your load balancer in front of your controllers
CONTROLLER_IP='192.168.122.2'
CONTROLLER_HOSTNAME='ikubemaster-01'
CONTROLLER="${CONTROLLER_HOSTNAME}=${CONTROLLER_IP}"
WORKER_0001='ikubenode-0001=192.168.122.11'
WORKER_0002='ikubenode-0002=192.168.122.12'
./000_prepare_hypervisor.sh path/to/my-template.qcow2 192.168.122.254 path/to/my-template-root_rsa
./010_on_hypervisor_generate_certs_and_configs.sh --controller-ip=${CONTROLLER_IP} --controller-hostname=${CONTROLLER_HOSTNAME} -n ${WORKER_0001} -n ${WORKER_0002}

./011_on_hypervisor_create_vms.sh ${CONTROLLER} ${WORKER_0001} ${WORKER_0002}
# turn the vms into controllers or workers
./021_on_hypervisor_create_controller_nodes.sh -c ${CONTROLLER}

```
