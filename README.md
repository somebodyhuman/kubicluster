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

You should know the basics about kvm, virsh and libvirt-qemu (or any other underlying virtualisation you might want to use).

## Dependencies

These scripts require the following packages to be installed:
* curl

## Basic Ideas / "Features"

* use kubicluster from the master hypervisor in your cluster to manage your kubernetes cluster across all hypervisors
* everything cluster-specific to spin up controlleres and worker nodes and extend the cluster using more hypervisors resides in your working directory `./work`. This includes things like kubicluster certs, configs, base images, etc., so backup/restore procedures are easy to setup - just backup this directory by your favorite means (e.g. tracking this directory as a separate git repository - despite the flaw that commiting huge binaries like image files is considered bad practice ;-)
* private keys are residing inside the master hypervisor and are NOT accessible from within the kubicluster (from controller nodes or worker nodes)
* load balancer for controller nodes is integrated into the first controller node on the master hypervisor

## What each script is doing

### 000_prepare_hypervisor.sh
* installs kvm, virsh, libvirt-qemu
* install dependencies curl
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

## Example workflows:

The following example workflows show you how to setup different kinds of networks and how to scale them up and down.

### simple: Single hypervisor with one controller and two worker nodes
```bash
./010_on_hypervisor_generate_certs_and_configs.sh kubenode-0001=192.168.122.11 kubenode-0002=192.168.122.12
```
