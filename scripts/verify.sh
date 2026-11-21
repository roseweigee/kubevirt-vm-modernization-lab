#!/usr/bin/env bash
# Run every step of the lab and assert the result.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

say "Deploy namespace, VM, Service and clients"
kubectl apply -f "$M/00-namespace.yaml"
# the KubeVirt/CDI admission webhooks can need a few more seconds after install
for i in $(seq 1 20); do kubectl apply -f "$M/10-legacy-vm.yaml" && break; echo "  webhook not ready yet, retry $i"; sleep 10; done
kubectl -n "$NS" get vm legacy-app >/dev/null
kubectl apply -f "$M/20-service-and-clients.yaml"
kubectl -n "$NS" rollout status deploy/frontend --timeout=180s
kubectl -n "$NS" rollout status deploy/other --timeout=180s

# ---------------------------------------------------------------------------
say "Step 1 – import the VM disk image with CDI (DataVolume)"
kubectl -n "$NS" wait dv legacy-app-rootdisk --for=condition=Ready --timeout=25m
kubectl -n "$NS" get dv,pvc
ok "DataVolume legacy-app-rootdisk imported: $(kubectl -n "$NS" get dv legacy-app-rootdisk -o jsonpath='{.status.phase}')"

# ---------------------------------------------------------------------------
say "Step 2 – boot the VM (Ready only when the app inside answers on :8080)"
for _ in $(seq 1 60); do kubectl -n "$NS" get vmi legacy-app >/dev/null 2>&1 && break; sleep 5; done
kubectl -n "$NS" wait vmi legacy-app --for=condition=Ready --timeout=25m
kubectl -n "$NS" get vm,vmi -o wide
kubectl -n "$NS" get pods -l kubevirt.io=virt-launcher -o wide
ok "VM legacy-app is Running and Ready on node $(kubectl -n "$NS" get vmi legacy-app -o jsonpath='{.status.nodeName}')"

# ---------------------------------------------------------------------------
say "Step 3 – reach the VM through an ordinary Kubernetes Service"
expect_body frontend "running in a VM" "frontend → Service legacy-app → VM"
expect_body other    "running in a VM" "other    → Service legacy-app → VM (no policy yet)"

# ---------------------------------------------------------------------------
say "Step 4 – NetworkPolicy: only frontend may reach the VM"
kubectl apply -f "$M/30-networkpolicy.yaml"
expect_blocked other "other → VM"
expect_body frontend "running in a VM" "frontend → VM still allowed"

# ---------------------------------------------------------------------------
say "Step 5 – stop and start the VM; its disk (PVC) keeps the data"
before=$(boot_no); echo "  boot counter before restart: #$before"
kubectl -n "$NS" patch vm legacy-app --type=merge -p '{"spec":{"runStrategy":"Halted"}}'
kubectl -n "$NS" wait vmi legacy-app --for=delete --timeout=5m
ok "VM stopped (runStrategy Halted, VMI deleted)"
expect_blocked frontend "frontend → stopped VM"
kubectl -n "$NS" patch vm legacy-app --type=merge -p '{"spec":{"runStrategy":"Always"}}'
for _ in $(seq 1 60); do kubectl -n "$NS" get vmi legacy-app >/dev/null 2>&1 && break; sleep 3; done
kubectl -n "$NS" wait vmi legacy-app --for=condition=Ready --timeout=20m
expect_body frontend "boot #$((before + 1))" "VM back up; counter read from its own disk"

# ---------------------------------------------------------------------------
say "Step 6 – modernize: run the same app as a container and switch the Service"
kubectl apply -f "$M/40-container-version.yaml"
kubectl -n "$NS" rollout status deploy/legacy-app-container --timeout=180s
kubectl -n "$NS" patch service legacy-app --type=merge -p '{"spec":{"selector":{"app":"legacy-app","tier":"container"}}}'
expect_body frontend "running in a container" "frontend → same Service name → container"
expect_blocked other "other → container (same NetworkPolicy still applies)"

# ---------------------------------------------------------------------------
say "Step 7 – roll back to the VM by switching the selector back"
kubectl -n "$NS" patch service legacy-app --type=merge -p '{"spec":{"selector":{"app":"legacy-app","tier":"vm"}}}'
expect_body frontend "running in a VM" "frontend → VM again (rollback, VM untouched)"

say "Final state"
kubectl -n "$NS" get vm,vmi,dv,pvc,svc,networkpolicy,deploy
say "All checks passed: $PASS"
