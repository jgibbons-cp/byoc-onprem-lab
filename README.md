# Datadog BYOC CloudPrem — Bare-Metal Lab

> Deploy a fully operational [Datadog CloudPrem](https://docs.datadoghq.com/cloudprem/) environment on bare-metal Kubernetes in **~25 minutes** — no EKS, no GKE, no SSH required.

A single interactive script that teaches you what it deploys as it deploys it. Built and validated by the Datadog SE team.

---

## Before You Do Anything Else

> **The `logs-cloudprem` feature flag must be enabled on your Datadog org before the reverse connection will activate. Without it, everything installs cleanly, all pods go green, and absolutely nothing shows up in the UI. This is the #1 footgun.**

Enable it now, before launching a single instance:

[mosaic.us1.ddbuild.io/feature-flags/logs-cloudprem](https://mosaic.us1.ddbuild.io/feature-flags/logs-cloudprem)

If you don't have Mosaic access, ask your Datadog contact or a Mosaic admin to enable it. The install takes ~25 minutes — use that time to get the flag enabled so you're not waiting on it after everything is up.

---

## Quick Start

```bash
# 0. Enable the logs-cloudprem feature flag (see above) — do this first

# 1. Configure your AWS profile (paste SSO export lines first)
aws configure set aws_access_key_id     "$AWS_ACCESS_KEY_ID"     --profile byoc
aws configure set aws_secret_access_key "$AWS_SECRET_ACCESS_KEY" --profile byoc
aws configure set aws_session_token     "$AWS_SESSION_TOKEN"     --profile byoc

# 2. Launch EC2 instances and wait for SSM registration (~3 min)
git clone https://github.com/rf00028/byoc-onprem-lab
cd byoc-onprem-lab
bash launch_instances.sh

# 3. Install the full BYOC stack (~20–25 min)
bash install.sh
```

`launch_instances.sh` creates both EC2 nodes, sets up the IAM instance profile, and waits until they're reachable via SSM. `install.sh` then discovers them automatically — just pick them from the numbered list.

The script asks ~8 questions, press **Enter once** to confirm, then runs fully automated end-to-end with live progress, parallel installs, and a checkpoint system that resumes from where it left off if interrupted.

> **Phase 1 takes 12–15 minutes** (package installs + `kubeadm init`). The spinner is running — it's not hung. Don't Ctrl+C.

> **If the install is interrupted for any reason**, just re-run `bash install.sh` and select the same instances. Completed phases are skipped automatically — it picks up exactly where it left off.

---

## What It Deploys

```
  Datadog SaaS (app.datadoghq.com)
       ^  reverse WebSocket — no public ingress required
  +--------------------------------------------------------------+
  |  EC2: m5.4xlarge  ·  Kubernetes (kubeadm)                   |
  |                                                              |
  |   +-----------------------------------------------------+   |
  |   |  byoclogs namespace                                 |   |
  |   |                                                     |   |
  |   |  control-plane -- reverse connection to SaaS        |   |
  |   |  indexer       -- writes log splits -> SeaweedFS    |   |
  |   |  searcher      -- executes queries from SaaS        |   |
  |   |  metastore     -- split catalog -> PostgreSQL       |   |
  |   |  janitor       -- enforces retention policy         |   |
  |   |  Datadog Agent -- collects pod logs -> indexer:7280 |   |
  |   +-----------------------------------------------------+   |
  |                                                              |
  |   SeaweedFS (S3 API :8333)  ·  s3://byoclogs/indexes        |
  +--------------------------------------------------------------+
                    |  SQL :5432
       +------------+------------------------+
       |  EC2: t3.micro                      |
       |  PostgreSQL 14                      |
       |  (split metadata store)             |
       +-------------------------------------+
```

| Component | What it is | Role in CloudPrem | Why this one |
|---|---|---|---|
| **Kubernetes** (kubeadm v1.32) | Single-node bare-metal cluster bootstrapped with `kubeadm init` on Ubuntu 22.04 | Runs all CloudPrem pods and the Datadog Agent on a single schedulable node | No cloud provider dependency — behavior is identical to EKS/GKE; containerd CRI; control-plane taint removed so workloads schedule |
| **Cilium** CNI | eBPF-based Container Network Interface plugin | Provides pod-to-pod networking, DNS, and kube-proxy replacement | On bare metal the cluster service IP is unreachable during bootstrap — Cilium requires `--set k8sServiceHost/Port` flags; documented in [deviations #4](docs/deviations.md) |
| **local-path-provisioner** | Lightweight dynamic PVC provisioner — creates volumes as host directories on the node | Satisfies PersistentVolumeClaims for the indexer (50 Gi scratch) and SeaweedFS volumes | Replaces Longhorn, which has a webhook deadlock on k8s 1.32+ that cannot be patched without disabling the manager; see [deviations #2](docs/deviations.md) |
| **SeaweedFS** | Self-hosted S3-compatible object store (POSIX + S3 API on port 8333) | Stores the indexed log data as Parquet "split" files at `s3://byoclogs/indexes` — stands in for customer-managed S3, Azure Blob, Ceph, or NetApp | Replaces MinIO whose open-source AGPL repo was archived in 2024; AWS SDK v2 requires an explicit `region` field even for custom endpoints — see [deviations #10](docs/deviations.md) |
| **PostgreSQL 14** | Relational database on a separate `t3.micro` EC2 instance | Stores QuickWit's split catalog — metadata about every indexed log segment (file path, time range, tags, merge history); required for search to work | Mirrors real-world BYOC deployments where customers bring RDS or Cloud SQL; runs on a separate node to reflect realistic network topology |
| **CloudPrem** (helm chart) | Five microservices deployed via the `datadog/cloudprem` Helm chart | **indexer** writes incoming logs to SeaweedFS; **searcher** executes queries from SaaS over the reverse WebSocket; **metastore** manages the split catalog in PostgreSQL; **control-plane** holds the outbound WebSocket to `app.datadoghq.com`; **janitor** enforces retention | The actual product being demoed — all traffic flows locally except the control-plane's outbound connection to SaaS |
| **Datadog Operator + Agent** | Kubernetes Operator managing a `DatadogAgent` CRD; node agent runs as a DaemonSet | Collects all container logs from the CRI socket and ships them to `indexer:7280` — never to SaaS intake | Demonstrates the full on-prem log collection path; `DD_LOGS_CONFIG_LOGS_DD_URL` overrides the default SaaS endpoint to point at the local indexer |

---

## Prerequisites

### Your laptop

| Tool | Required for |
|---|---|
| `aws` CLI v2 | All SSM remote execution |
| `python3` | JSON-encoding SSM parameters |

No `kubectl`, `helm`, or SSH needed locally. Everything runs remotely via AWS SSM SendCommand. The installer installs `helm`, `kubectl`, `kubeadm`, and `kubelet` on the remote Kubernetes node automatically.

### AWS credentials

This lab uses the `byoc` AWS CLI profile. Before running either script, configure it with your current SSO credentials:

```bash
# Get credentials from your AWS SSO portal (the "Export" button gives you 3 export lines)
# Paste those first, then run:
aws configure set aws_access_key_id     "$AWS_ACCESS_KEY_ID"     --profile byoc
aws configure set aws_secret_access_key "$AWS_SECRET_ACCESS_KEY" --profile byoc
aws configure set aws_session_token     "$AWS_SESSION_TOKEN"     --profile byoc

# Verify
aws sts get-caller-identity --profile byoc
```

> **Note:** SSO tokens expire every ~1 hour. The installer detects this and pauses to let you refresh. Run the same four commands above to resume.

Your local AWS profile needs: `AmazonSSMFullAccess` + `AmazonEC2ReadOnlyAccess` + `IAMFullAccess` (for instance profile creation).

### Launching instances

```bash
bash launch_instances.sh
```

The script:
1. Finds the latest Ubuntu 22.04 LTS AMI for your region
2. Creates (or reuses) a `byoc-cloudprem-lab` security group
3. Creates (or reuses) an IAM instance profile with `AmazonSSMManagedInstanceCore`
4. Launches the Kubernetes node (`m5.4xlarge`, 300 GB gp3)
5. Launches the PostgreSQL node (`t3.micro`, 20 GB gp2)
6. Tags both instances with `Project=byoc-cloudprem-lab` and `CreatedBy=<your-email>`
7. Waits until both appear `Online` in SSM, then prints the instance IDs

Once it finishes, run `bash install.sh` and select the two instances it discovered.

**Override defaults** with environment variables before running:

```bash
export BYOC_PROFILE=byoc          # AWS profile
export BYOC_REGION=us-east-1      # AWS region
export BYOC_K8S_TYPE=m5zn.metal   # use bare-metal if available in your account
bash launch_instances.sh
```

| Instance | Default type | Storage | Notes |
|---|---|---|---|
| Kubernetes node | `m5.4xlarge` | 300 GB gp3 | Override with `BYOC_K8S_TYPE` |
| PostgreSQL node | `t3.micro` | 20 GB gp2 | Override with `BYOC_PG_TYPE` |

### Datadog

- Org with `logs-cloudprem` feature flag enabled → [mosaic.us1.ddbuild.io/feature-flags/logs-cloudprem](https://mosaic.us1.ddbuild.io/feature-flags/logs-cloudprem)
- A Datadog API key (not an app key)

---

## How It Works

The installer runs seven sequential phases, with Phases 3 and 4 executing **in parallel** for speed:

```
Phase 1  Kubernetes bootstrap     kubeadm init, containerd, remove control-plane taint   ~12-15 min
Phase 2  Cilium CNI               eBPF pod networking, waits for node Ready               ~3 min
Phase 3  Storage layer    +--     local-path-provisioner + SeaweedFS + bucket/user        ~5 min  } parallel
Phase 4  PostgreSQL        +--    install + configure on separate instance                ~5 min  }
Phase 5  CloudPrem                helm install, all pods to Ready                         ~5 min
Phase 6  Datadog Agent            Operator + DatadogAgent CRD, log collection active      ~3 min
Phase 7  Verify connection        polls control-plane logs until reverse WebSocket is live ~1 min
```

**Total wall-clock: ~25 minutes** (Phases 3 and 4 run concurrently).

### Smart features

- **Instance discovery** — lists your online SSM instances, pick by number or paste the ID
- **Checkpoint/resume** — completed phases are skipped on re-run; keyed to the Kubernetes instance ID so separate instances don't share state
- **Parallel execution** — PostgreSQL installs on the t3.micro while SeaweedFS deploys on the k8s node; saves ~3 minutes
- **Unique cluster name** — auto-appends a random 6-char hex suffix (e.g. `cloudprem-a3f91c`) to prevent naming collisions across runs on the same Datadog org
- **Idempotent secrets** — all Kubernetes secrets are recreated before Phase 5 on every run, so a resumed install never fails due to missing credentials
- **Taint guard** — checks and removes the `control-plane:NoSchedule` taint before Phase 5 so pods always schedule, even on resumed runs
- **Live spinner** — animated progress on every remote operation
- **Credential refresh** — detects expired STS tokens and pauses for you to refresh
- **Architecture diagram** — each phase shows the full stack with the current component highlighted
- **Connection verification** — Phase 7 tails the control-plane logs and confirms the reverse WebSocket is live before showing the finish screen

### Non-interactive mode (`BYOC_YES=1`)

For automated testing or scripted deployments, set `BYOC_YES=1` and provide values as `BYOC_<VARNAME>` environment variables. Unset variables fall back to their defaults.

```bash
export BYOC_YES=1
export BYOC_PROFILE=byoc                    # default: byoc
export BYOC_REGION=us-east-1               # default: us-east-1
export BYOC_K8S_INSTANCE=i-0abc123...      # required — no default
export BYOC_PG_INSTANCE=i-0def456...       # required — no default
export BYOC_DD_SITE=datadoghq.com          # default: datadoghq.com
export BYOC_CLUSTER_NAME=cloudprem-abc123  # default: cloudprem-<random6hex>
export BYOC_NAMESPACE=byoclogs             # default: byoclogs
export BYOC_BUCKET=byoclogs               # default: byoclogs
export BYOC_PG_USER=byoclogs              # default: byoclogs
export BYOC_PG_PASS=byoclogs              # default: byoclogs
export BYOC_DD_API_KEY=<your-api-key>     # required — no default
bash install.sh
```

The script aborts if `BYOC_K8S_INSTANCE`, `BYOC_PG_INSTANCE`, or `BYOC_DD_API_KEY` are missing.

---

## Demo Walkthrough

Once Phase 7 completes and the reverse WebSocket is confirmed live, here is the tour to give a customer.

### 1. Show the connected cluster

Go to **[app.datadoghq.com/byoc-logs](https://app.datadoghq.com/byoc-logs)**.

Your cluster appears as `Connected`, type `Reverse`. This is the key slide — the customer's logs never leave their environment. The control plane in SaaS holds an outbound WebSocket to the indexer; all search queries travel over that channel, results flow back, and no inbound firewall rules are needed.

### 2. Show live log ingestion

Hover the cluster name and click **Search Logs**. Pod logs from the Kubernetes node appear within ~2 minutes of install completing. These are the CloudPrem components logging to themselves — a working closed loop.

Point out the source: the Datadog Agent is running as a pod on the same node, collecting container logs via the CRI socket, and shipping directly to the indexer at `indexer:7280` — not to SaaS intake. The SaaS backend never sees raw log bytes.

### 3. Show CloudPrem metrics

Open **[app.datadoghq.com/metric/summary?filter=cloudprem](https://app.datadoghq.com/metric/summary?filter=cloudprem)**. QuickWit emits internal metrics over DogStatsD to the local Agent, which forwards them to SaaS as regular metrics. This gives customers full observability into their own log infrastructure from within Datadog — index rates, query latency, storage usage — without any logs crossing the boundary.

### 4. Walk through the data flow

Use the architecture diagram above (or the one printed by the installer during each phase) to walk through the data path:

- **Logs written**: Agent → indexer → SeaweedFS (S3 on the same node)
- **Logs queried**: SaaS UI → reverse WebSocket → searcher → SeaweedFS → results back over WebSocket → UI
- **Metadata**: indexer → PostgreSQL (split catalog on the t3.micro)
- **Control plane role**: holds the connection open, proxies search, enforces retention via janitor

### 5. Key talking points

- No inbound firewall rules — the cluster dials out to SaaS, not the other way around
- Works in air-gapped or private-subnet environments (only egress to `app.datadoghq.com` required)
- Kubernetes-native — runs on EKS, GKE, AKS, bare metal, or any CNCF-conformant cluster
- Storage is pluggable — any S3-compatible store works (AWS S3, Azure Blob via gateway, Ceph, NetApp, etc.)
- The Datadog Agent is optional — any log shipper that speaks HTTP to the indexer works

---

## Key Deviations from the Official Article

This installer fixes issues discovered during full verbatim validation. See [docs/deviations.md](docs/deviations.md) for complete root-cause analysis.

| # | Issue | Root cause | Fix |
|---|---|---|---|
| 1 | EKS unavailable | SCP blocked EKS in us-east-1; EIP quota exhausted in us-west-1 | Bare-metal kubeadm on EC2 |
| 2 | Longhorn deadlock on k8s 1.32+ | Webhook calls itself during startup with `failurePolicy: Fail`; controller reconciliation prevents patching | Replaced with `local-path-provisioner` |
| 3 | MinIO archived (2024) | Open-source AGPL repo is read-only — supply chain risk | Replaced with SeaweedFS |
| 4 | QuickWit SSL rejection | QuickWit requires SSL by default; bare-metal PostgreSQL has no certs | Added `?sslmode=disable` to URI |
| 5 | pg_hba.conf missing | Article doesn't include this step; PostgreSQL 14 uses `md5` not `scram-sha-256` | Added `host byoclogs byoclogs 10.0.0.0/8 md5` |
| 6 | kubeconfig uses public IP | kubeadm sets public IP; SSM runs inside the instance, no hairpin NAT | Use private IP for `--control-plane-endpoint` |
| 7 | Cilium bootstrap deadlock | Cluster service IP unreachable during CNI init on bare metal | Added `--set k8sServiceHost/Port` flags |
| 8 | Longhorn webhooks persist after uninstall | Manager recreates webhook configs on every restart, blocks PVC binding even after `helm uninstall` | Delete configs + permanently disable manager DaemonSet |
| 9 | SSM as sole remote access method | Port 22 blocked by sandbox security group | Instance profile with `AmazonSSMManagedInstanceCore`; launcher waits for SSM `Online` |
| 10 | SeaweedFS S3 requires explicit region | AWS SDK v2 rejects requests with no region header; splits silently fail to upload | Added `region: us-east-1` to CloudPrem S3 config |

---

## Verification

Phase 7 handles this automatically — the installer polls the control-plane pod logs and prints a confirmation line when the reverse WebSocket connection is established. The finish screen then shows your exact cluster name and URL.

For `datadoghq.com`:

1. **[app.datadoghq.com/byoc-logs](https://app.datadoghq.com/byoc-logs)** — cluster appears as `Connected`, type `Reverse`
2. Hover cluster → **Search Logs** — pod logs appear within ~2 minutes
3. **[cloudprem metrics](https://app.datadoghq.com/metric/summary?filter=cloudprem)** — QuickWit internal metrics via DogStatsD

> **Important:** The `logs-cloudprem` feature flag must be enabled on your org before the reverse connection will activate. Ask your Datadog contact or Mosaic admin: [mosaic.us1.ddbuild.io/feature-flags/logs-cloudprem](https://mosaic.us1.ddbuild.io/feature-flags/logs-cloudprem)

---

## Troubleshooting

### AWS STS token expired

```bash
# Paste fresh export lines from the SSO portal, then:
aws configure set aws_access_key_id     "$AWS_ACCESS_KEY_ID"     --profile byoc
aws configure set aws_secret_access_key "$AWS_SECRET_ACCESS_KEY" --profile byoc
aws configure set aws_session_token     "$AWS_SESSION_TOKEN"     --profile byoc
aws sts get-caller-identity --profile byoc
```

The script detects this automatically and pauses, but tokens expire every ~1 hour so you may need to refresh mid-run.

---

### Phase 1 spinner running for more than 20 minutes

Phase 1 is legitimately slow (kubeadm init + package installs), but it should not exceed 20 minutes. If it does, open a second terminal and check SSM directly:

```bash
aws ssm list-command-invocations \
  --instance-id <k8s-instance-id> \
  --details \
  --region $BYOC_REGION --profile $BYOC_PROFILE \
  --query 'CommandInvocations[0].CommandPlugins[0].Output'
```

Common causes: instance is out of disk space (check that you launched with 300 GB gp3), or `apt` is waiting on a dpkg lock from Ubuntu's automatic update process. You can also log in via SSM (see below) and run `journalctl -f` to watch live output.

---

### Phase 7 never prints "connected" / times out

Phase 7 polls control-plane pod logs for a WebSocket confirmation string. If it times out:

**1. Check the feature flag first** — the most common cause. If it's not enabled, the control-plane will connect to SaaS but the session is silently rejected.

**2. Check the control-plane pod logs directly:**

```bash
# Via SSM session on the k8s instance:
export KUBECONFIG=/root/.kube/config
kubectl logs -n byoclogs -l app.kubernetes.io/component=control-plane --tail=50
```

Look for `connected`, `established`, or `error` lines. Repeated connection refused or TLS errors indicate a bad API key or wrong `DD_SITE`.

**3. Verify the pod is running:**

```bash
kubectl get pods -n byoclogs
```

If the control-plane is in `CrashLoopBackOff`, check its logs for configuration errors (wrong cluster name format, invalid API key, missing secret).

---

### Cluster not appearing in `app.datadoghq.com/byoc-logs`

Almost always the `logs-cloudprem` feature flag. If logs show `connected` or `established` but the cluster still doesn't appear in the UI — the feature flag is the issue. Contact your Mosaic admin.

---

### Pods stuck in ImagePullBackOff

The node cannot pull container images.

```bash
kubectl describe pod <pod-name> -n byoclogs
# Check the Events section for the specific registry and error
```

Common causes:
- DNS not resolving from within the cluster — check `kubectl get pods -n kube-system` for CoreDNS pod status
- containerd not running — check `systemctl status containerd` on the k8s instance via SSM
- DockerHub pull rate limits — if running many installs from the same IP, wait a few minutes and re-run

---

### SeaweedFS pods not ready

```bash
kubectl get pvc -n byoclogs
kubectl get storageclass
kubectl get pods -n local-path-storage
```

If the `local-path` StorageClass is missing or the provisioner pods are not running, Phase 3 was interrupted. Re-run `bash install.sh` — the checkpoint system retries Phase 3 automatically.

---

### Metastore CrashLoopBackOff

```bash
kubectl logs -n byoclogs deploy/byoclogs-cloudprem-metastore --tail=5
# "SSL encryption"   -> URI is missing ?sslmode=disable
# "no pg_hba.conf"   -> add host entry and reload postgresql on the postgres instance
```

---

### Indexer Pending — webhook error

```bash
kubectl delete validatingwebhookconfiguration longhorn-webhook-validator --ignore-not-found
kubectl delete mutatingwebhookconfiguration   longhorn-webhook-mutator   --ignore-not-found
```

---

### Node stuck NotReady

```bash
kubectl get pods -n kube-system | grep cilium
# If Cilium pods are failing: confirm helm install included --set k8sServiceHost and k8sServicePort
```

---

### Accessing the k8s instance manually via SSM

If you need an interactive shell to debug:

```bash
aws ssm start-session \
  --target <k8s-instance-id> \
  --region $BYOC_REGION --profile $BYOC_PROFILE
```

No SSH or key pair needed. Once in:

```bash
sudo -i
export KUBECONFIG=/root/.kube/config
kubectl get pods -A
kubectl get nodes
```

---

## Cleanup

> **Cost reminder:** The default instance types run approximately **$0.768/hr** (`m5.4xlarge`) and **$0.010/hr** (`t3.micro`) in `us-east-1` — roughly **$0.78/hr combined**. A lab left running overnight costs ~$6. Terminate when you're done.

```bash
# Set these to match your deployment (defaults shown)
export BYOC_REGION=us-east-1
export BYOC_PROFILE=byoc

# Terminate both EC2 instances (replace with your actual instance IDs)
aws ec2 terminate-instances \
  --instance-ids <k8s-instance-id> <postgres-instance-id> \
  --region $BYOC_REGION --profile $BYOC_PROFILE
```

To find your instance IDs if you've lost them:

```bash
aws ec2 describe-instances \
  --filters "Name=tag:Project,Values=byoc-cloudprem-lab" \
            "Name=tag:CreatedBy,Values=$(aws sts get-caller-identity --profile $BYOC_PROFILE --query 'Arn' --output text | sed 's/.*\///')" \
  --query 'Reservations[*].Instances[*].[InstanceId,Tags[?Key==`Name`]|[0].Value,State.Name]' \
  --output table --region $BYOC_REGION --profile $BYOC_PROFILE
```

---

## Reference

- [docs/deviations.md](docs/deviations.md) — full deviation report with root cause analysis and article fix recommendations

---

## Contributing

Issues and PRs welcome. This repo is maintained by the Datadog SE team.

For questions: `#byoc-logs` Slack channel or reach out to the CloudPrem product team.

---

*Validated against CloudPrem `v0.1.29` · kubeadm `v1.32` · Cilium `v1.17.4` · SeaweedFS `v3.x`*
