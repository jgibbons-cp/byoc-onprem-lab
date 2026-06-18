# Datadog BYOC CloudPrem — Bare-Metal Lab

> Deploy a fully operational [Datadog CloudPrem](https://docs.datadoghq.com/cloudprem/) environment on bare-metal Kubernetes in **15–20 minutes** — no EKS, no GKE, no SSH required.

A single interactive script that teaches you what it deploys as it deploys it. Built and validated by the Datadog SE team.

---

## Quick Start

```bash
git clone https://github.com/datadoghq-se/byoc-onprem-lab
cd byoc-onprem-lab
bash install.sh
```

Or run directly:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/datadoghq-se/byoc-onprem-lab/main/install.sh)
```

The script discovers your SSM-registered instances automatically, asks ~10 questions, then runs end-to-end with live progress, parallel installs, and a checkpoint system that resumes from where it left off if interrupted.

---

## What It Deploys

```
  Datadog SaaS (app.datadoghq.com)
       ↑  reverse WebSocket — no public ingress required
  ┌──────────────────────────────────────────────────────────────┐
  │  EC2: m5zn.metal  ·  Kubernetes (kubeadm)                   │
  │                                                              │
  │   ┌─────────────────────────────────────────────────────┐   │
  │   │  byoclogs namespace                                 │   │
  │   │                                                     │   │
  │   │  control-plane ── reverse connection to SaaS        │   │
  │   │  indexer       ── writes log splits → SeaweedFS     │   │
  │   │  searcher      ── executes queries from SaaS        │   │
  │   │  metastore     ── split catalog → PostgreSQL        │   │
  │   │  janitor       ── enforces retention policy         │   │
  │   │  Datadog Agent ── collects pod logs → indexer:7280  │   │
  │   └─────────────────────────────────────────────────────┘   │
  │                                                              │
  │   SeaweedFS (S3 API :8333)  ·  s3://byoclogs/indexes        │
  └──────────────────────────────────────────────────────────────┘
                    │  SQL :5432
       ┌────────────┴──────────────┐
       │  EC2: t3.micro            │
       │  PostgreSQL 14            │
       │  (split metadata store)   │
       └───────────────────────────┘
```

| Component | What it is | Why this one |
|---|---|---|
| **Kubernetes** (kubeadm v1.32) | Single-node bare-metal cluster | No cloud provider needed — runs identically to EKS/GKE |
| **Cilium** CNI | eBPF-based pod networking | High-performance; required bare-metal bootstrap flags documented |
| **local-path-provisioner** | Dynamic PVC provisioning | Replaces Longhorn — deadlock bug on k8s 1.32+, see [docs/deviations.md](docs/deviations.md) |
| **SeaweedFS** | S3-compatible object store | Replaces MinIO — open-source repo was archived in 2024 |
| **PostgreSQL 14** | QuickWit split metadata store | Mirrors real-world BYOC deployments with RDS |
| **CloudPrem** (helm) | Indexer · searcher · metastore · control-plane · janitor | The actual product |
| **Datadog Operator + Agent** | Manages agent lifecycle via CRD | Log collection → CloudPrem indexer (never touches SaaS) |

---

## Prerequisites

### Your laptop
| Tool | Required for |
|---|---|
| `aws` CLI v2 | All SSM remote execution |
| `python3` | JSON-encoding SSM parameters |

No `kubectl`, `helm`, or SSH needed locally. Everything runs remotely via AWS SSM SendCommand. The installer installs `helm`, `kubectl`, `kubeadm`, and `kubelet` on the remote Kubernetes node automatically.

### AWS — launch before running the script

| Instance | Type | OS | Storage | Notes |
|---|---|---|---|---|
| Kubernetes node | `m5zn.metal` or `m5.4xlarge` | Ubuntu 22.04 | 300 GB gp3 | SSM agent + instance profile |
| PostgreSQL node | `t3.micro` | Ubuntu 22.04 | 20 GB gp2 | SSM agent + port 5432 open to k8s SG |

Both instances need:
- SSM Agent running
- IAM instance profile with `AmazonSSMManagedInstanceCore`
- Verify: `aws ssm describe-instance-information --region <region>` shows both as `Online`

Your local AWS profile needs: `AmazonSSMFullAccess` + `AmazonEC2ReadOnlyAccess`

### Datadog
- Org with `logs-cloudprem` feature flag enabled → [mosaic.us1.ddbuild.io/feature-flags/logs-cloudprem](https://mosaic.us1.ddbuild.io/feature-flags/logs-cloudprem)
- A Datadog API key (not an app key)

---

## How It Works

The installer runs six sequential phases, with Phases 3 and 4 executing **in parallel** for speed:

```
Phase 1  Kubernetes bootstrap     kubeadm init, containerd, remove control-plane taint
Phase 2  Cilium CNI               eBPF pod networking, waits for node Ready
Phase 3  Storage layer    ┐       local-path-provisioner + SeaweedFS + bucket/user
Phase 4  PostgreSQL       ┘ parallel on separate instance
Phase 5  CloudPrem               helm install, all pods to Ready
Phase 6  Datadog Agent            Operator + DatadogAgent CRD, log collection active
```

### Smart features

- **Instance discovery** — lists your online SSM instances, pick by number
- **Checkpoint/resume** — completed phases are skipped on re-run, safe to retry after failure; keyed to the Kubernetes instance ID so separate instances don't share state
- **Parallel execution** — PostgreSQL installs on the t3.micro while SeaweedFS deploys on the k8s node; saves ~3 minutes
- **Live spinner** — animated progress on every remote operation
- **Credential refresh** — detects expired STS tokens and pauses for you to paste fresh credentials
- **Architecture diagram** — each phase shows the full stack with the current component highlighted

### Non-interactive mode (`BYOC_YES=1`)

For automated testing or scripted deployments, set `BYOC_YES=1` and provide values as `BYOC_<VARNAME>` environment variables. Unset variables fall back to their defaults.

```bash
export BYOC_YES=1
export BYOC_PROFILE=byoc           # default: byoc
export BYOC_REGION=us-east-1       # default: us-east-1
export BYOC_K8S_INSTANCE=i-0abc123...   # required — no default
export BYOC_PG_INSTANCE=i-0def456...    # required — no default
export BYOC_DD_SITE=datadoghq.com  # default: datadoghq.com
export BYOC_CLUSTER_NAME=cloudprem # default: cloudprem
export BYOC_NAMESPACE=byoclogs     # default: byoclogs
export BYOC_BUCKET=byoclogs        # default: byoclogs
export BYOC_PG_USER=byoclogs       # default: byoclogs
export BYOC_PG_PASS=byoclogs       # default: byoclogs
export BYOC_DD_API_KEY=<your-api-key>   # required — no default
bash install.sh
```

The script aborts if `BYOC_K8S_INSTANCE`, `BYOC_PG_INSTANCE`, or `BYOC_DD_API_KEY` are missing.

---

## Key Deviations from the Official Article

This installer fixes issues discovered during full verbatim validation. See [docs/deviations.md](docs/deviations.md) for complete root-cause analysis.

| Issue | Root cause | Fix |
|---|---|---|
| Longhorn deadlock on k8s 1.32+ | Webhook calls itself during startup with `failurePolicy: Fail`; controller reconciliation prevents patching | Replaced with `local-path-provisioner` |
| MinIO archived (2024) | Open-source AGPL repo is read-only — supply chain risk | Replaced with SeaweedFS |
| QuickWit SSL rejection | QuickWit requires SSL by default; bare-metal PostgreSQL has no certs | Added `?sslmode=disable` to URI |
| pg_hba.conf missing | Article doesn't include this step; PostgreSQL 14 uses `md5` not `scram-sha-256` | Added `host byoclogs byoclogs 10.0.0.0/8 md5` |
| kubeconfig uses public IP | kubeadm sets public IP; SSM runs inside the instance, no hairpin NAT | Use private IP for `--control-plane-endpoint` |
| Cilium bootstrap deadlock | Cluster service IP unreachable during CNI init on bare metal | Added `--set k8sServiceHost/Port` flags |
| Longhorn webhooks persist | Manager recreates webhook configs on every restart, blocks PVC binding | Delete configs + permanently disable manager DaemonSet |

---

## Verification

After the script completes, the finish screen shows the correct URLs for your `DD_SITE`. For `datadoghq.com`:

1. **[app.datadoghq.com/byoc-logs](https://app.datadoghq.com/byoc-logs)** — cluster appears as `Connected`, type `Reverse`
2. Hover cluster → **Search Logs** — pod logs appear within ~2 minutes
3. **[cloudprem metrics](https://app.datadoghq.com/metric/summary?filter=cloudprem)** — QuickWit internal metrics via DogStatsD

> **Important:** The `logs-cloudprem` feature flag must be enabled on your org before the reverse connection will activate. Ask your Datadog contact or Mosaic admin: [mosaic.us1.ddbuild.io/feature-flags/logs-cloudprem](https://mosaic.us1.ddbuild.io/feature-flags/logs-cloudprem)

---

## Troubleshooting

**AWS STS token expired**
```bash
# After pasting fresh export lines from the SSO portal:
aws configure set aws_access_key_id     "$AWS_ACCESS_KEY_ID"     --profile byoc
aws configure set aws_secret_access_key "$AWS_SECRET_ACCESS_KEY" --profile byoc
aws configure set aws_session_token     "$AWS_SESSION_TOKEN"     --profile byoc
aws sts get-caller-identity --profile byoc
```
The script detects this and pauses automatically, but if you're running commands manually, tokens expire every ~1 hour.

**Metastore CrashLoopBackOff**
```bash
kubectl logs -n byoclogs deploy/byoclogs-cloudprem-metastore --tail=5
# "SSL encryption"    → URI is missing ?sslmode=disable
# "no pg_hba.conf"    → add host entry, systemctl reload postgresql
```

**Indexer Pending — webhook error**
```bash
kubectl delete validatingwebhookconfiguration longhorn-webhook-validator --ignore-not-found
kubectl delete mutatingwebhookconfiguration   longhorn-webhook-mutator   --ignore-not-found
```

**Node stuck NotReady**
```bash
kubectl get pods -n kube-system | grep cilium
# If Cilium pods failing: confirm helm install included --set k8sServiceHost and k8sServicePort
```

---

## Cleanup

```bash
# On the Kubernetes instance
export KUBECONFIG=/root/.kube/config
helm uninstall byoclogs -n byoclogs
helm uninstall datadog-operator -n byoclogs
helm uninstall seaweedfs -n seaweedfs
kubectl delete ns byoclogs seaweedfs

# Terminate both EC2 instances from the AWS console
```

---

## Docs

| File | Contents |
|---|---|
| [docs/deviations.md](docs/deviations.md) | Full deviation report — root cause analysis and article fix recommendations |

---

## Contributing

Issues and PRs welcome. This repo is maintained by the Datadog SE team.

For questions: `#byoc-logs` Slack channel or reach out to the CloudPrem product team.

---

*Validated against CloudPrem `v0.1.29` · kubeadm `v1.32` · Cilium `v1.17.4` · SeaweedFS `v3.x`*
