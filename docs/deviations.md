# Deviation Report — BYOC On-Prem Lab

**Reference:** [BYOC Logs Lab Environment](https://datadoghq.atlassian.net/wiki/spaces/GTMSEH/pages/5388141147/BYOC+Logs+Lab+Environment)
**Validated:** June 17 2026 · Ricky Fair, Datadog SE
**Environment:** m5zn.metal EC2 · Ubuntu 22.04 · k8s v1.32 · us-west-1

This document records every point where the validated install path diverged from the original article, including root cause analysis and recommendations for the article authors.

---

## Deviation 1 — EKS Unavailable: Pivoted to Bare Metal

**Article path:** AWS EKS Lab Environment using `eksctl`

**What blocked it:**
- `us-east-1` — EKS denied by AWS Organizations SCP `p-a4i2xfs2`
- `us-west-1` — Elastic IP quota exhausted; eksctl requires one EIP for the NAT Gateway

**Resolution:** Used the article's alternate "BYOC On-Prem Lab" section (kubeadm on bare-metal EC2). Functionally equivalent — CloudPrem has no cloud provider dependency.

---

## Deviation 2 — Longhorn Webhook Deadlock (k8s 1.32+)

**Article says:** Install Longhorn for dynamic volume provisioning.

**What happened:**

Longhorn installs a `ValidatingWebhookConfiguration` with `failurePolicy: Fail`. During startup, the Longhorn manager runs an upgrade routine that tries to create a `CRDAPIVersionSetting` custom resource. Creating that CR triggers the webhook. The webhook service (`longhorn-admission-webhook.longhorn-system.svc:9502`) has no endpoints yet because the manager pod hasn't finished initializing — classic chicken-and-egg. The webhook call times out after 10 seconds, the upgrade fails, and the manager crashes and restarts.

The natural fix — patch the webhook to `failurePolicy: Ignore` — doesn't work because Longhorn's own controller reconciliation loop immediately reverts the patch. The controller always wins this race.

Reproduced on:
- Longhorn v1.7.0 + k8s v1.32
- Longhorn v1.8.1 + k8s v1.32

**Fix:** Replaced with [`local-path-provisioner`](https://github.com/rancher/local-path-provisioner) v0.0.31 (Rancher).

```bash
kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.31/deploy/local-path-storage.yaml
kubectl patch storageclass local-path \
  -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
```

local-path-provisioner creates PVCs as host directories on the node. No webhooks, no controllers. Used by default in k3s, kind, and minikube. On a single-node cluster, Longhorn's HA replication across nodes is meaningless anyway.

**Article update needed:** Note that Longhorn 1.7.x and 1.8.x are broken on k8s 1.26+. Recommend local-path-provisioner for single-node labs; Longhorn or Ceph for multi-node production.

---

## Deviation 3 — MinIO Open-Source Repo Archived

**Article says:** Use MinIO for S3-compatible object storage.

**Problem:** The MinIO open-source (AGPL) repository was archived in 2024 and is no longer receiving security updates. Using it in a lab that SEs demo to customers introduces supply chain risk and may raise questions about Datadog's recommended architecture.

**Fix:** Replaced with [SeaweedFS](https://github.com/seaweedfs/seaweedfs), which provides an equivalent S3 API and is actively maintained.

The SeaweedFS helm values differ from the MinIO values file in the article — see the installer for the validated configuration.

**Note on secret name:** The k8s secret is still named `byoc-logs-minio-credentials` because that is what the CloudPrem helm chart references by default. This is a naming artifact, not a dependency on MinIO.

**Article update needed:** Replace MinIO with SeaweedFS throughout. Update bucket and user creation steps (now done via `weed shell` instead of the MinIO CLI or UI).

---

## Deviation 4 — Cilium Requires Explicit API Server Address on Bare Metal

**Article says:** Install Cilium via helm (no special flags documented).

**What happened:** On bare metal, during Cilium's init phase, the Kubernetes cluster service IP (`10.96.0.1`) is not yet reachable — the CNI hasn't set up routing yet. Cilium's init container tries to contact the API server via the cluster service IP and fails with a TLS error or connection timeout.

**Fix:**

```bash
helm install cilium cilium/cilium \
  --set k8sServiceHost=<PRIVATE_IP> \
  --set k8sServicePort=6443
```

This tells Cilium's init container to contact the API server directly via the node's private IP, bypassing the cluster service IP entirely.

**Article update needed:** Add `--set k8sServiceHost` and `--set k8sServicePort` to the Cilium install command. These flags are required on all bare-metal clusters.

---

## Deviation 5 — kubeadm Sets Public IP in kubeconfig

**Article says:** kubectl works after `kubeadm init`.

**What happened:** `install_control_plane.sh` fetches the instance's public IP and passes it as `--control-plane-endpoint`. The generated kubeconfig points kubectl at `https://<PUBLIC_IP>:6443`. When kubectl runs inside the instance via SSM (no SSH tunnel), the security group doesn't allow inbound port 6443 from the instance's own public IP (no hairpin NAT), so all kubectl commands time out.

**Fix:** Pass the private IP directly to avoid the issue entirely:

```bash
kubeadm init --control-plane-endpoint=<PRIVATE_IP>:6443 ...
```

And patch immediately after as a belt-and-suspenders guarantee (kubeadm can still write a secondary public IP in some configurations):
```bash
sed -i "s|https://.*:6443|https://<PRIVATE_IP>:6443|g" /root/.kube/config /etc/kubernetes/admin.conf
```

The TLS certificate issued by kubeadm covers both the public and private IPs, so no cert regeneration is needed. Both fixes are applied automatically by the installer.

**Article update needed:** Note the kubeconfig public/private IP issue. If SSM is used instead of SSH, the private IP must be used.

---

## Deviation 6 — QuickWit Requires `?sslmode=disable` in Metastore URI

**Article says:** Connection string example: `postgres://user:pass@host:5432/db`

**What happened:** QuickWit (the CloudPrem indexing engine) connects to PostgreSQL with SSL enabled by default. A default PostgreSQL install has no TLS certificates configured. The metastore pod enters CrashLoopBackOff with:

```
no pg_hba.conf entry for host "172.31.27.94", user "byoclogs",
database "byoclogs", SSL encryption
```

**Fix:** Append `?sslmode=disable` to the URI:

```
postgres://byoclogs:byoclogs@<IP>:5432/byoclogs?sslmode=disable
```

**Article update needed:** Add `?sslmode=disable` to the connection string example, or document that PostgreSQL must be configured with TLS if omitted.

---

## Deviation 7 — pg_hba.conf Entry Missing and Wrong Auth Method

**Article says:** Add `host all all 0.0.0.0/0 scram-sha-256` to pg_hba.conf.

**Two problems:**

**Problem A:** The article's PostgreSQL install steps don't include adding this pg_hba.conf line. Without it, no remote connections are accepted at all, and the metastore fails with `no pg_hba.conf entry for host`.

**Problem B:** PostgreSQL 14 creates users with `ENCRYPTED PASSWORD` using `md5` hashing by default (unless `password_encryption = scram-sha-256` is set in `postgresql.conf`). Specifying `scram-sha-256` in `pg_hba.conf` when the stored password hash is `md5` causes authentication failure.

**Fix:**

```bash
echo "host  byoclogs  byoclogs  10.0.0.0/8  md5" >> /etc/postgresql/14/main/pg_hba.conf
systemctl reload postgresql
```

Use `md5` to match PostgreSQL 14's default password hash format.

**Article update needed:** Include the pg_hba.conf edit in the PostgreSQL setup steps. Note md5 vs scram-sha-256 compatibility.

---

## Deviation 8 — Longhorn Webhooks Persist After Uninstall

**What happened:** After switching from Longhorn to local-path-provisioner, the Longhorn manager DaemonSet was still scheduled. On each restart, the manager pod recreated the `ValidatingWebhookConfiguration` and `MutatingWebhookConfiguration`. These webhook configs blocked any pod that requested a PVC — including the CloudPrem indexer — with:

```
running PreBind plugin "VolumeBinding": failed calling webhook
"validator.longhorn.io": context deadline exceeded
```

This happened even after `helm uninstall longhorn` because the webhook configs are cluster-scoped resources not owned by the helm release.

**Fix:**

```bash
kubectl delete validatingwebhookconfiguration longhorn-webhook-validator --ignore-not-found
kubectl delete mutatingwebhookconfiguration   longhorn-webhook-mutator   --ignore-not-found

# Permanently disable the manager so it can't recreate them
kubectl patch daemonset longhorn-manager -n longhorn-system \
  --type=json \
  -p '[{"op":"replace","path":"/spec/template/spec/nodeSelector","value":{"stop":"true"}}]'
```

**Article update needed:** Document that if Longhorn is abandoned mid-install, webhook configs must be explicitly deleted and the manager DaemonSet disabled. Leftover webhooks are a silent PVC blocker.

---

## Deviation 9 — SSM as Sole Remote Access Method

**Article assumes:** SSH access to instances (uses `setup.sh` which SSHes in and runs `install_control_plane.sh`).

**Our environment:** Port 22 blocked by sandbox security group. SSM SendCommand was the only available remote execution method.

**Impact on article steps:** Every command that the article shows as a direct shell command had to be wrapped in an SSM SendCommand call. Shell quoting, heredocs, and multi-line scripts required careful encoding (JSON parameters file via Python to avoid shell escaping issues).

**Article update note:** The article's target audience (SEs) may frequently be in sandbox accounts with restricted SSH. A note about SSM as an alternative access method would be valuable.

---

## Summary Table

| # | Article says | Problem | Fix |
|---|---|---|---|
| 1 | Use EKS | SCP + EIP quota blocked it | Bare-metal kubeadm |
| 2 | Use Longhorn | Webhook deadlock on k8s 1.32+ | local-path-provisioner |
| 3 | Use MinIO | Repo archived 2024 | SeaweedFS |
| 4 | Install Cilium (no flags) | Bootstrap deadlock on bare metal | Add `--set k8sServiceHost/Port` |
| 5 | kubectl works after init | kubeconfig uses public IP; no hairpin NAT | Use private IP for `--control-plane-endpoint` |
| 6 | Connection string without SSL | QuickWit requires SSL; PostgreSQL has no certs | Add `?sslmode=disable` |
| 7 | Add scram-sha-256 to pg_hba | Step missing; PG14 defaults to md5 | Add md5 entry; step documented |
| 8 | (not mentioned) | Longhorn webhooks block PVC binding after uninstall | Delete configs + disable manager |
| 9 | Use SSH | Port 22 blocked in sandbox | AWS SSM SendCommand |
