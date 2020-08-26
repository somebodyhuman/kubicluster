# kubicluster

kubicluster is a bash script collection that helps you setup a kubernetes cluster inside virtual machines from scratch. It's predominant purpose is to help you to learn the ins and outs of kubernetes. Of course, it can also be used as a basis to (semi-)automate your production cluster setup.

If you are looking for a more sophisticated, production-ready approach, checkout https://github.com/kubernetes-sigs/kubespray


## Suported tool version combination(s)

It currently supports:
* hypervisor OS: debian 10
  * underlying virtualisation: KVM (in turn relying on virsh and libvirt-qemu)

```bash
virsh version

# should yield the following version numbers (or later versions) on your hypervisor
Compiled against library: libvirt 5.0.0
Using library: libvirt 5.0.0
Using API: QEMU 5.0.0
Running hypervisor: QEMU 3.1.0
```

* guest OS for (controller and worker) nodes: debian 9 (debian 9 is used due to an unresolved kata setup issue on debian 10 (see https://github.com/kata-containers/documentation/issues/685))
  * high-level container-runtimes: containerd 1.3.6 or later
  * low-level container-runtimes: kata 1.11.2 (default), runc 1.0.0-rc91 (on-demand)
  * kubernetes networking: calica 3.11.3 (this version is constrained by the underlying kernel checks, which are incorrect for higher versions, see https://github.com/kubernetes-sigs/kubespray/issues/6289#issuecomment-672288815)

If you would like to see other options or versions supported as well, you are welcome to open a PR.

kubicluster emphasizes runtime security and workload isolation and therefore uses kata containers as the default runtime and runc as an optional on-demand runtime. calico is not yet compatible with kata containers as the underlying container runtime. Therefore kubicluster runs calico pods using runc as the low-level runtime.

## Prerequisites

You should know the basics about kvm, virsh and libvirt-qemu (or any other underlying virtualisation you might want to use). You should be familiar with the command line. All scripts are written in bash to keep the entry level barrier as low as possible (picking a higher level programming makes it more difficult to clearly see how all the tools interact on the command line level and how they depend on each other, in particular ).

You should have a clean virtual machine image with a fresh, empty install of debian 9 that can be used as a template for controller nodes and worker nodes. Inside this VM the root user needs to have ssh access using a key file. This can be revoked once the kubicluster setup is completed.

### Aquire basic knowledge about kubernetes
Some good resources to learn more about kubernetes are the following:
* Introduction to Container Runtimes: https://medium.com/@saschagrunert/demystifying-containers-part-ii-container-runtimes-e363aa378f25
* Backup and Recovery Strategies: https://medium.com/velotio-perspectives/the-ultimate-guide-to-disaster-recovery-for-your-kubernetes-clusters-94143fcc8c1e
* Kubernetes relies heavily on certificates to manage access and authentication; a really good introduction to certificates and the csr field meanings can be found here: https://www.youtube.com/watch?v=gXz4cq3PKdg&t=539
***TODO add more helpful resources***

## Basic Ideas / "Features"

### General
* use kubicluster from the master hypervisor in your cluster to manage your kubernetes cluster across all hypervisors (not yet supported, currently only one hypervisor is supported)
* everything cluster-specific to spin up controlleres and worker nodes and extend the cluster using more hypervisors resides in your working directory `./work`. This includes things like kubicluster certs, configs, base images, etc., so backup/restore procedures are easy to setup - just backup this directory by your favorite means (e.g. tracking this directory as a separate git repository - despite the flaw that committing huge binaries like image files is considered bad practice ;-)
* private keys are residing inside the master hypervisor and are NOT accessible from within the kubicluster (from controller nodes or worker nodes)

### Architecture of the resulting cluster

Everything should run inside virtual machines, so we can easily (re)create a cluster on a hypervisor with affecting the hypervisor and port the cluster to a different hypervisor / server easily.

There are 4 Layers in our cluster:
* **(1) The hypervisor**: responsible for running the virtual machines
* **(2) The virtual machines**: the term for them in kubernetes is "node", a node is either a controller (coordinating the cluster) or a worker (running workloads / pods consisting of one or more containers)
* **(3) The cluster layer**:
  * **(3a) data store**: this is usually an etcd data store (which in development environments is usually installed directly onto one or more controllers)
  * **(3b) controller = kube-apiserver + kube-controller-manager + kube-scheduler**: kube-apiserver is usually the interface through which the other controllers and the worker nodes communicate with the "kube-controller-manager"
  * **(3c) worker = kubelet + high-level runtime + low-level-runtime + cni-plugins and other extensions**: kubelet organises the workloads assigned to the worker and runs the pods in a given high-level + low-level runtime combination
* **(4) The workload layer = pods + networking**: consists of the pods communicating with each other and the outside world through a defined cluster networking solution

To setup a cluster from scratch, each layer has to be setup consecutively from (1) to (4).

### Handling variables and arguments
* variables that should only be adjusted on the hypervisor (or are only used on the hypervisor, but not inside the nodes) can be changed by directly overwriting them before calling the command, example (user shorter than default keylength and newer kubernetes on hypervisor for certificate and configuration file generation): `KUBERNETES_VERSION=1.18.6 RSA_KEYLENGTH=2048 ./kubicluster cnc -c ${CONTROLLER_01} -w ${WORKER_0001} -w ${WORKER_0002}`
* variables that should be consistently adjusted are passed in as arguments, example (use and run newer kubernetes version on controllers): `./kubicluster create-controllers -c ${CONTROLLER_01} --kubernetes-version=1.18.6`

Supporting the customisation of some variables through environment variables and through command arguments, is both convenient, but also allows to play around a bit more with them and to learn about the dependencies between all components, the commands to install them and configure them.

### Security aspects

#### SSH access into virtual machines
Authentication over an SSH_KEY (instead of password) is considered safer and allows for an automation without waiting for a user interaction to provide a password. The ssh access of the root user can be limited to the hypervisor(s) on which the virtual machines will be running inside the VM template. If the virtual machines are only accessible via ssh from the hypervisor itself, but not from the outside world, an attacker would have to gain access to the hypervisor (which - in a production setup - should be hardened and protected through various means like firewall by default) to be able to gain access to a virtual machine / a node. If an attacker gains access to a hypervisor, the whole server including it's virtual machines would have to be considered compromised.

#### Certificates and authentication

Kubernetes relies heavily on certificates to manage access and authentication. To be future proof for a good while the default RSA keylength to be used to generate certificates is set to 8192. Any keylength of 2048 and higher is considered save. A custom keylength can be defined with the environment variable `RSA_KEYLENGTH`.


## Usage

## Installation

You can simply install kubicluster by cloning this repository and adding a symbolic link pointing to the ./kubicluster script or directly calling it.

```bash
git clone https://github.com/sray/kubicluster.git
ln -s $(pwd)/kubicluster/kubicluster /usr/local/bin/kubicluster
```

### Standard flow to create a small development cluster

The following creates a small cluster on one hypervisor with one controller (also hosting the one etcd instance) and two worker nodes.
```bash
CONTROLLER_01=kubi-controller-01,192.168.122.11
WORKER_0001=kubi-worker-0001,192.168.122.21
WORKER_0002=kubi-worker-0002,192.168.122.22
# note: you manage IP allocation, so be sure you do not have IP conflicts between nodes on the same hypervisor

./kubicluster prepare path/to/vm.qcow2 path/to/vm-root-ssh_rsa
./kubicluster create-vms ${CONTROLLER_01} ${WORKER_0001} ${WORKER_0002}

# generate _C_ertificates a_N_d _C_onfiguration files
RSA_KEYLENGTH=2048 ./kubicluster cnc -c ${CONTROLLER_01} -w ${WORKER_0001} -w ${WORKER_0002}
./kubicluster create-controllers -c ${CONTROLLER_01} --force-etcd-data-reset # etcd data have to be reset on initial install to initialise encryption of etcd
./kubicluster create-workers -c ${CONTROLLER_01} -w ${WORKER_0001} -w ${WORKER_0002}
```
Running these commands to setup a cluster is rather straight forward. If you want to look under the hood and run all the sub-commands yourself, checkout the `*)` section in the sub-command argument parsing within the sub-command shell script files.

### Diving deeper

The kubicluster command and each sub-command show information on how to use it and which environment variables and which command arguments are supported when called with `help`:
```bash
./kubicluster help
./kubicluster prepare help
./kubicluster create-vms help
./kubicluster cnc help
./kubicluster create-controllers help
./kubicluster create-workers help
```

All scripts are written in plain bash/shell. If you dive into them and feel there could be more explanation or a clarifying comment would be helpful in a place that is not yet commented (enough) for beginners, please consider contributing to the community and open a PR.

### What each script / sub-command is doing

#### kubicluster prepare

* sets up the hypervisor
* installs kvm, virsh, libvirt-qemu
* install dependencies curl, ssh, ...
* puts the base image for all vms into the default location ./work/imgs/vm-template.(img|qcow2|...)

**NOTE: install_dependencies and setup_virtualisation should run on any debian/ubuntu hypervisor without problems, for other distros you need to execute the corresponding commands yourself, or better yet - submit a PR to this repo ;-)**

### kubicluster create-vms

* creates vms on the hypervisor using virsh, a template image and a template xml (if you want to use a different template, you have to run the `prepare` command again)

### kubicluster cnc

* installs cfssl on the master hypervisor
* checks if cfssl is installed / otherwise it installs it again
* generates a certificate authority and the required certificates
* generate required kubeconfig files
* certs and configs are placed by default in ./work/certs_and_configs

### kubicluster create-controllers

* creates standard directory structure
* upload necessary certs and config files
* install dependencies
* install kubernetes tools as services

### kubicluster create-workers

* creates standard directory structure
* upload necessary certs and config files
* install dependencies
* install kubernetes tools as services

In case, you run into networking issues, that you cannot solve and would like to start from scratch, you can delete some of the kubernetes resources to force a redeployment of calico networking pods before re-running the create-workers sub-command:
```bash
kubectl delete daemonset calico-node -n kube-system
kubectl delete deployment calico-kube-controllers -n kube-system
# then re-run
/kubicluster create-workers ...
```

## Road Map
* supporting different image format types (only qcow2 is supported in all scripts already)
* support more than one hypervisor (staging and production environment cases)
* refactoring: extract the networking setup out from the create-workers into a separate create-networking sub-command
* support second networking alternative (weavenet)
* support change of deployed networking solution with a single command
* support simple removal of components (with warning if the last of it's type is removed, components: etcd server, kubernetes controller, kubernetes worker, virtual machine (including components deployed onto it))
* support change of etcd data encryption with a single command
* support addition and removal of different runtimes on different nodes
* provide a "kubicluster status" command, that does the following:
  * listing etcd (cluster) health
  * listing kubernetes controllers, workers and runtimes on workers
  * listing all pods running on each node,
  * listing persistent volumes, their usage on each node and their backup status
  * listing deployed networking solution stats
* implement <tab><tab> auto-completion of commands and sub-commands
* update the obsolete numbering of file names (010 and 011 should be swapped) and improve the naming of sub command files
* translate bash scripts into simple shell scripts for increased portability across unix/linux systems
* support non-root, admin user access to VMs
* support more hypervisor operating systems
* support more hypervisor virtualisation technologies (VirtualBox, ...)
* support more node operating systems
* automate end-to-end test for typical cases
	* development: one hypervisor, one controller, two worker nodes
	* staging: two hypervisors, three controllers, three worker nodes
	* production: three hypervisors (two different locations), three controllers, separate etcd cluster, three worker nodes
