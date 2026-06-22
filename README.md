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

# 1. Set up AWS credentials — see AWS credentials section below

# 2. Launch EC2 instances and wait for SSM registration (~3 min)
git clone https://github.com/rf00028/byoc-onprem-lab
cd byoc-onprem-lab
bash launch_instances.sh

# 3. Install the full BYOC stack (~20–25 min)
bash install.sh
```

> **First time?** You need a `byoc` AWS profile configured before step 2 — see [AWS credentials](#aws-credentials) below.

`launch_instances.sh` creates both EC2 nodes, sets up the IAM instance profile, and waits until they're reachable via SSM. `install.sh` then discovers them automatically — just pick them from the numbered list.

The script asks ~8 questions, press **Enter once** to confirm, then runs fully automated end-to-end with live progress, parallel installs, and a checkpoint system that resumes from where it left off if interrupted.

> **Phase 1 takes 12–15 minutes** (package installs + `kubeadm init`). The spinner is running — it's not hung. Don't Ctrl+C.

> **If the install is interrupted for any reason**, just re-run `bash install.sh` and select the same instances. Completed phases are skipped automatically — it picks up exactly where it left off.

---

## Architecture

```
╔══════════════════════════════════════════════════════════════════════════╗
║                       DATADOG BYOC CLOUDPREM                            ║
╠══════════════════════════════════════════════════════════════════════════╣
║                                                                          ║
║   Log Sources                                                            ║
║   ┌──────────┐  ┌──────────┐  ┌──────────┐                              ║
║   │ DC-1 App │  │ DC-2 App │  │ DC-3 App │  ...any shipper (Agent,      ║
║   └────┬─────┘  └────┬─────┘  └────┬─────┘       Fluentd, HTTP)        ║
║        └─────────────┴─────────────┘                                    ║
║                             │  logs (HTTP :7280)                        ║
║                             ▼                                            ║
║   ┌──────────────────────────────────────────────────────────────────┐  ║
║   │  Kubernetes Cluster                                              │  ║
║   │                                                                  │  ║
║   │   ┌─────────────────────────────────────────────────────────┐   │  ║
║   │   │  BYOC Log Engine  (cloudprem Helm chart · byoclogs ns)  │   │  ║
║   │   │                                                         │   │  ║
║   │   │  ┌──────────┐  ┌──────────┐  ┌──────────┐              │   │  ║
║   │   │  │ Indexer  │  │ Searcher │  │  Janitor │              │   │  ║
║   │   │  │ (ingest) │  │ (query)  │  │(retention│              │   │  ║
║   │   │  └────┬─────┘  └────┬─────┘  └──────────┘              │   │  ║
║   │   │       │              │                                  │   │  ║
║   │   │  ┌────▼──────┐  ┌───▼──────────────────────────────┐   │   │  ║
║   │   │  │ Metastore │  │         Control Plane             │   │   │  ║
║   │   │  │(split cat.)│  │  (reverse WebSocket to SaaS)  ───┼───┼──╬═══╗
║   │   │  └─────┬─────┘  └───────────────────────────────┘   │   │  ║  ║
║   │   └─────── │ ─────────────────────────────────────────── ┘   │  ║  ║
║   │            │ SQL (:5432)                                      │  ║  ║
║   │     ┌──────┴────────────┐   ┌──────────────────────────┐     │  ║  ║
║   │     │  PostgreSQL 14    │   │  SeaweedFS (S3 :8333)    │     │  ║  ║
║   │     │  Split Metastore  │   │  Log Splits (Parquet)    │     │  ║  ║
║   │     │  (separate EC2)   │   │  s3://byoclogs/indexes   │     │  ║  ║
║   │     └───────────────────┘   └──────────────────────────┘     │  ║  ║
║   └──────────────────────────────────────────────────────────────┘  ║  ║
║                                                                       ║  ║
╚═══════════════════════════════════════════════════════════════════════╝  ║
                              Outbound reverse WebSocket (wss://, port 443) ║
                                                                            ▼
                                                  ┌────────────────────────────────────┐
                                                  │       Datadog SaaS                 │
                                                  │   app.datadoghq.com                │
                                                  │                                    │
                                                  │  Log Search UI ─► reverse WS ──►  │
                                                  │  query ──► searcher ──► results    │
                                                  │                                    │
                                                  │  Raw log bytes: NEVER cross this   │
                                                  │  boundary. Only search queries     │
                                                  │  and results travel the WebSocket. │
                                                  └────────────────────────────────────┘
```

**The key insight:** The control plane dials *out* to Datadog SaaS — your cluster initiates the connection. No inbound firewall rules, no public ingress, no VPN. Works in any air-gapped or private-subnet environment as long as egress to `app.datadoghq.com:443` is allowed.

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

The scripts use a `byoc` AWS profile. Credentials come from the AWS Access Portal and expire every ~1 hour.

**One-time config** — run this once to create the profile (if you haven't already):

```bash
aws configure set region us-east-1 --profile byoc
```

**Every session** — go to the AWS Access Portal, select your account and role, click **Access keys**, and copy the **Option 1** export block. It looks like:

```bash
export AWS_ACCESS_KEY_ID="ASIA..."
export AWS_SECRET_ACCESS_KEY="..."
export AWS_SESSION_TOKEN="..."
```

Paste that into your terminal, then immediately run this to save it to the `byoc` profile:

```bash
aws configure set aws_access_key_id     "$AWS_ACCESS_KEY_ID"     --profile byoc
aws configure set aws_secret_access_key "$AWS_SECRET_ACCESS_KEY" --profile byoc
aws configure set aws_session_token     "$AWS_SESSION_TOKEN"     --profile byoc
```

Verify:

```bash
aws sts get-caller-identity --profile byoc
```

> **Credentials expire after ~1 hour.** Repeat the export + configure steps above to refresh. The install checkpoint system means you can refresh mid-run and resume without losing progress.

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

### AWS credentials expired

Temporary credentials last ~1 hour. Go back to the AWS Access Portal, copy the **Option 1** export block, paste it into your terminal, then run:

```bash
aws configure set aws_access_key_id     "$AWS_ACCESS_KEY_ID"     --profile byoc
aws configure set aws_secret_access_key "$AWS_SECRET_ACCESS_KEY" --profile byoc
aws configure set aws_session_token     "$AWS_SESSION_TOKEN"     --profile byoc
```

Then re-run `bash install.sh` — the checkpoint system picks up where it left off.

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

## Post-Lab Quiz — BYOC CloudPrem 🎯

*Ten questions for Bits of Learning. Take this after completing the lab — and prepare to ace your next customer conversation about CloudPrem!*

---

**Question 1**
You're meeting a customer with strict data residency requirements. Their legal team says "no log data can leave our private network — ever." Which Datadog capability would you recommend, and why?

- A) Standard Datadog Agent with log forwarding to SaaS  
- B) BYOC CloudPrem — logs are stored, indexed, and searched entirely on-premises; only search queries cross the network boundary  
- C) A third-party SIEM with Datadog forwarding  
- D) Datadog Flex Logs — data stays in the customer's S3 bucket  

✅ **Answer: B** — CloudPrem is purpose-built for data residency. Raw log bytes never leave the customer's infrastructure. The reverse WebSocket carries only search queries and results.

---

**Question 2**
What is the "reverse connection" in BYOC CloudPrem, and why does it matter for customers who can't open inbound firewall ports?

- A) The customer's SIEM pushes aggregated alerts to Datadog  
- B) The Datadog Agent polls SaaS for configuration changes  
- C) The CloudPrem control plane opens an *outbound* WebSocket to Datadog SaaS; the SaaS backend uses this same connection to send search queries down to the on-prem searcher  
- D) A VPN tunnel that Datadog provisions into the customer's VPC  

✅ **Answer: C** — The cluster dials out. No VPN, no inbound rules, no public ingress required. Any environment with egress to `app.datadoghq.com:443` can use CloudPrem.

---

**Question 3**
A customer's CloudPrem cluster installs cleanly — all pods are Running, no errors — but their cluster never appears in the BYOC Logs UI. What is the most likely cause?

- A) The Datadog Agent is misconfigured  
- B) The `logs-cloudprem` feature flag is not enabled on their Datadog org  
- C) SeaweedFS failed to initialize  
- D) The PostgreSQL password is wrong  

✅ **Answer: B** — This is the #1 footgun. Without the feature flag, the control plane's WebSocket handshake is silently rejected by SaaS. Everything looks healthy locally, but the cluster never appears in the UI.

---

**Question 4**
CloudPrem's indexer stores log data as "Parquet splits" in an S3-compatible object store. A customer asks if they can use their existing NetApp storage instead of AWS S3. What do you tell them?

- A) No — CloudPrem only works with native AWS S3  
- B) Yes — any S3-compatible endpoint works, including NetApp StorageGRID, Ceph, Azure Blob via gateway, and on-prem object stores  
- C) Only if they're running Kubernetes on AWS  
- D) Yes, but only with an Enterprise license  

✅ **Answer: B** — CloudPrem uses the S3 API, not AWS-specific features. Any S3-compatible store works. In this lab we use SeaweedFS to prove that flexibility.

---

**Question 5**
What is the role of PostgreSQL in a BYOC CloudPrem deployment?

- A) Stores raw log events for long-term retention  
- B) Powers the Datadog dashboards that display log queries  
- C) Stores the QuickWit split catalog — metadata about every indexed log segment (file path, time range, tags, merge history) — required by the searcher to locate the right data  
- D) Caches search results for faster repeated queries  

✅ **Answer: C** — PostgreSQL is the Metastore. Every time the indexer writes a Parquet split to object storage, it registers that split in PostgreSQL. Without the catalog, the searcher has no map of where the data lives.

---

**Question 6**
A customer is concerned about Kubernetes expertise on their team. They've heard BYOC requires running their own cluster. How do you address this?

- A) Tell them BYOC requires a dedicated Kubernetes team  
- B) CloudPrem runs on any CNCF-conformant cluster — EKS, GKE, AKS, OpenShift, bare metal — deployed and managed however the customer prefers; Datadog doesn't require them to change their existing cluster strategy  
- C) Suggest they use Datadog's managed Kubernetes offering  
- D) BYOC only supports bare-metal deployments  

✅ **Answer: B** — CloudPrem is a Helm chart. The customer owns and manages the cluster using whatever tools they already have. No new cluster model required.

---

**Question 7**
In the lab, the Datadog Agent is configured with `DD_LOGS_CONFIG_LOGS_DD_URL` pointing at the local CloudPrem indexer instead of `app.datadoghq.com`. What does this single configuration change accomplish?

- A) Disables log collection entirely  
- B) Routes all log bytes to the on-prem indexer instead of SaaS intake — making the Agent a local log shipper while still sending metrics and traces to SaaS normally  
- C) Encrypts logs before sending them to SaaS  
- D) Enables log sampling  

✅ **Answer: B** — One URL override is all it takes. Logs go locally; metrics and traces continue to SaaS. The Agent is unchanged in every other way.

---

**Question 8**
Which CloudPrem component is responsible for enforcing log retention policies and cleaning up expired data?

- A) Metastore  
- B) Control Plane  
- C) Searcher  
- D) Janitor  

✅ **Answer: D** — The Janitor runs on a schedule, deletes expired Parquet splits from object storage, and removes their records from the PostgreSQL split catalog. Retention is enforced entirely on-premises with no SaaS involvement.

---

**Question 9**
A customer asks how Datadog's SaaS backend can execute search queries against data that lives entirely in the customer's private network. How does this work?

- A) Datadog creates a secure VPN into the customer's environment for each query  
- B) The customer copies query results to a Datadog-hosted S3 bucket  
- C) The control plane holds an outbound WebSocket open at all times; SaaS sends search requests *down* this connection to the on-prem searcher, and results flow back the same way — no inbound connection is ever made  
- D) The searcher periodically syncs indexed data to Datadog SaaS  

✅ **Answer: C** — The persistent outbound WebSocket is the entire mechanism. The connection is already open before any query arrives. From a network perspective, every search query is a response to an existing outbound connection — no new inbound connection required.

---

**Question 10**
What are the two primary use cases that drive customers to choose BYOC CloudPrem over standard Datadog log management?

- A) Cost savings and faster query performance  
- B) **Data residency / regulatory compliance** (logs must stay on-prem or in a specific region) AND **data sovereignty** (the customer owns and controls their log infrastructure, including what gets indexed and retained)  
- C) Easier Kubernetes deployment and lower agent resource consumption  
- D) Support for non-standard log formats and multi-cloud routing  

✅ **Answer: B** — Data residency and sovereignty are the two headline drivers. Customers in regulated industries (finance, healthcare, government, defense) often cannot send log data outside their own infrastructure. CloudPrem gives them the full Datadog experience — search, dashboards, alerts, retention — while keeping every log byte on their own hardware.

---

*Nice work! If you aced this, you're ready to lead a CloudPrem conversation. If any answers surprised you, re-run the lab and pay attention to the Phase 5–7 explain screens — they cover all of this live. 🚀*

---

## Reference

- [docs/deviations.md](docs/deviations.md) — full deviation report with root cause analysis and article fix recommendations

---

## Contributing

Issues and PRs welcome. This repo is maintained by the Datadog SE team.

For questions: `#byoc-logs` Slack channel or reach out to the CloudPrem product team.

---

*Validated against CloudPrem `v0.1.29` · kubeadm `v1.32` · Cilium `v1.17.4` · SeaweedFS `v3.x`*
