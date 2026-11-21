# kubevirt-vm-modernization-lab

![lab](https://github.com/roseweigee/kubevirt-vm-modernization-lab/actions/workflows/lab.yml/badge.svg)

Run a legacy application **as a virtual machine on Kubernetes**, operate it with ordinary
Kubernetes objects, then **modernize it into a container** behind the same Service — and roll back.

Two ways to run it:

* **Automated, on kind** – KubeVirt + CDI (the upstream projects behind Red Hat OpenShift
  Virtualization). GitHub Actions runs every step on each push and asserts the result.
* **Hands-on, on Red Hat OpenShift Virtualization** – the Developer Sandbox walkthrough in
  [`sandbox/`](sandbox/) and [docs/NOTES.zh-TW.md](docs/NOTES.zh-TW.md).

| Step | What happens | What is checked |
|---|---|---|
| 1 Import disk | CDI `DataVolume` pulls an Ubuntu qcow2 image over HTTP into a PVC | DataVolume `Succeeded` |
| 2 Boot VM | `VirtualMachine` boots from that PVC; cloud-init installs the app as a systemd service | VMI `Ready` (guest HTTP readiness probe on :8080) |
| 3 Service | a normal `Service` selects the VM's virt-launcher pod | clients get the page served from inside the VM |
| 4 Isolate | `NetworkPolicy` allows only `role=frontend` | frontend reaches the VM, another pod is blocked |
| 5 Stop / start | `runStrategy: Halted` → `Always` | VM unreachable while stopped; boot counter on its own disk goes +1 |
| 6 Modernize | same app as a 2-replica `Deployment`; switch the Service selector | same Service name now answers from containers; policy still enforced |
| 7 Roll back | switch the selector back | traffic is on the VM again, untouched |

## Run it

On a Linux machine with `/dev/kvm` (or let CI do it):

```bash
kind create cluster --name kubevirt-lab
NODE_CONTAINER=kubevirt-lab-control-plane bash scripts/install-kubevirt.sh
bash scripts/verify.sh
bash scripts/teardown.sh
```

Without `/dev/kvm` the install script switches KubeVirt to software emulation (works, slower).
Apple Silicon Macs can't run this x86 VM image locally — use the Developer Sandbox instead.

## Why this matters

Many teams are moving VMs off VMware. On OpenShift Virtualization, a VM becomes a Kubernetes
object: it gets Services, Routes, NetworkPolicy, RBAC and GitOps like any workload, and it can be
replaced piece by piece by containers without changing how clients reach it. In a real migration
the Migration Toolkit for Virtualization (MTV) copies VMware disks onto the cluster using CDI —
the same import step this lab performs with a public cloud image. This lab does **not** include a
VMware source or MTV itself.
