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

* **010_on_hypervisor_generate_certs_and_configs.sh:**
  * installs cfssl on the master hypervisor
  * checks if cfssl is installed / otherwise it installs it again
  * generates a certificate authority, the required certificates

## Example workflows:

The following example workflows show you how to setup different kinds of networks and how to scale them up and down.

### simple: Single hypervisor with one controller and two worker nodes
```bash
./010_on_hypervisor_generate_certs_and_configs.sh kubenode-0001=192.168.122.11 kubenode-0002=192.168.122.12
```
