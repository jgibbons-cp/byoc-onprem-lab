#!/usr/bin/env bash
# =============================================================================
#  Datadog BYOC CloudPrem — Bare-Metal Lab Installer
#  github.com/datadoghq-se/byoc-onprem-lab
# =============================================================================
set -uo pipefail
IFS=$'\n\t'

# ── Terminal & Colors ─────────────────────────────────────────────────────────
TERM_WIDTH=$(tput cols 2>/dev/null || echo 80)
RED='\033[0;31m';   GREEN='\033[0;32m';  YELLOW='\033[1;33m'
BLUE='\033[0;34m';  CYAN='\033[0;36m';   WHITE='\033[1;37m'
MAGENTA='\033[0;35m'; BOLD='\033[1m';    DIM='\033[2m';  NC='\033[0m'
HIDE_CURSOR='\033[?25l'; SHOW_CURSOR='\033[?25h'
trap 'printf "${SHOW_CURSOR}"; stty echo 2>/dev/null; exit' INT TERM EXIT

# ── Checkpoint System (resume after failure) ──────────────────────────────────
# CKPT_DIR is keyed to the K8S instance ID after selection so the same node
# can be resumed across separate invocations. Initialized with a stable default
# here; re-keyed below once K8S_INSTANCE is known.
CKPT_DIR="${TMPDIR:-/tmp}/.byoc_ckpt_default"
mkdir -p "$CKPT_DIR"
ckpt_set()  { touch "$CKPT_DIR/$1"; }
ckpt_done() { [[ -f "$CKPT_DIR/$1" ]]; }

# ── UI: Core Helpers ──────────────────────────────────────────────────────────
_pad() { printf '%*s' "$1" ''; }
_hr()  { printf '%*s\n' "$TERM_WIDTH" '' | tr ' ' "${1:--}"; }

banner() {
  clear
  echo -e "${BLUE}${BOLD}"
  echo "  ╔══════════════════════════════════════════════════════════════════╗"
  echo "  ║                                                                  ║"
  echo "  ║    ██████╗ ██╗   ██╗ ██████╗  ██████╗                          ║"
  echo "  ║    ██╔══██╗╚██╗ ██╔╝██╔═══██╗██╔════╝                          ║"
  echo "  ║    ██████╔╝ ╚████╔╝ ██║   ██║██║                               ║"
  echo "  ║    ██╔══██╗  ╚██╔╝  ██║   ██║██║                               ║"
  echo "  ║    ██████╔╝   ██║   ╚██████╔╝╚██████╗                          ║"
  echo "  ║    ╚═════╝    ╚═╝    ╚═════╝  ╚═════╝  CloudPrem Lab Installer ║"
  echo "  ║                                                                  ║"
  echo "  ╚══════════════════════════════════════════════════════════════════╝"
  echo -e "${NC}"
  echo -e "  ${DIM}Bare-metal Kubernetes · SeaweedFS · QuickWit · Reverse Connection${NC}"
  echo ""
}

section() {
  local title="$1" icon="${2:-▸}"
  echo ""
  echo -e "${WHITE}${BOLD}  $icon  $title${NC}"
  echo -e "${DIM}  $(_hr '─' | head -c $((TERM_WIDTH-4)))${NC}"
  echo ""
}

# Architecture diagram — highlights the current phase in context
arch_diagram() {
  local phase="$1"
  echo -e "${DIM}"
  echo "  ┌──────────────────────────────────────────────────────────────────┐"
  local saas_color="$DIM" k8s_color="$DIM" pg_color="$DIM" agent_color="$DIM"
  local cilium_color="$DIM" storage_color="$DIM" cloudprem_color="$DIM"
  case "$phase" in
    k8s)       k8s_color="${WHITE}${BOLD}" ;;
    cilium)    cilium_color="${CYAN}${BOLD}" ;;
    storage)   storage_color="${CYAN}${BOLD}" ;;
    postgres)  pg_color="${CYAN}${BOLD}" ;;
    cloudprem) cloudprem_color="${CYAN}${BOLD}"; saas_color="${GREEN}" ;;
    agent)     agent_color="${CYAN}${BOLD}" ;;
    done)      saas_color="${GREEN}${BOLD}"; k8s_color="${GREEN}"; pg_color="${GREEN}"
               cilium_color="${GREEN}"; storage_color="${GREEN}"
               cloudprem_color="${GREEN}"; agent_color="${GREEN}" ;;
  esac
  printf "  │  ${saas_color}%-64s${DIM}│\n" "  Datadog SaaS (app.datadoghq.com)"
  echo   "  │         ↑ reverse WebSocket                                     │"
  printf "  │  ${k8s_color}%-64s${DIM}│\n" "  Kubernetes (kubeadm)  ← Phase 1"
  printf "  │    ${cilium_color}%-62s${DIM}│\n" "├─ Cilium CNI             ← Phase 2"
  printf "  │    ${storage_color}%-62s${DIM}│\n" "├─ local-path + SeaweedFS ← Phase 3"
  printf "  │    ${cloudprem_color}%-62s${DIM}│\n" "├─ CloudPrem (indexer/searcher/ctrl) ← Phase 5"
  printf "  │    ${agent_color}%-62s${DIM}│\n" "└─ Datadog Agent          ← Phase 6"
  echo   "  │                                                                  │"
  printf "  │  ${pg_color}%-64s${DIM}│\n" "  PostgreSQL t3.micro     ← Phase 4 (parallel)"
  echo   "  └──────────────────────────────────────────────────────────────────┘"
  echo -e "${NC}"
}

explain() {
  local text="$1"
  echo -e "${DIM}  ╭─────────────────────────────────────────────────────────────────╮${NC}"
  while IFS= read -r line; do
    printf "${DIM}  │${NC}  ${CYAN}%-65s${DIM}│${NC}\n" "$line"
  done <<< "$text"
  echo -e "${DIM}  ╰─────────────────────────────────────────────────────────────────╯${NC}"
  echo ""
}

info()    { echo -e "  ${CYAN}   $1${NC}"; }
success() { echo -e "  ${GREEN}${BOLD} ✓ ${NC}${GREEN}$1${NC}"; }
warn()    { echo -e "  ${YELLOW} ⚠  $1${NC}"; }
abort()   { echo -e "\n  ${RED}${BOLD} ✗  $1${NC}\n"; printf "${SHOW_CURSOR}"; exit 1; }

phase_done() {
  local name="$1" elapsed="$2"
  echo ""
  echo -e "  ${GREEN}${BOLD}  ✓  $name complete${NC}  ${DIM}(${elapsed}s)${NC}"
  echo ""
}

pause() {
  [[ "${BYOC_YES:-}" == "1" ]] && return
  echo -e "\n  ${YELLOW}  Press ${WHITE}[Enter]${YELLOW} to continue...${NC}"
  read -r < /dev/tty
}

ask() {
  local prompt="$1" default="$2" varname="$3" resp
  if [[ "${BYOC_YES:-}" == "1" ]]; then
    local envvar="BYOC_${varname}"
    local val="${!envvar:-$default}"
    printf -v "$varname" '%s' "$val"
    printf "  ${WHITE}%-40s${NC}${DIM}[${val}]${NC}: ${DIM}%s (auto)${NC}\n" "$prompt" "$val"
    return
  fi
  if [[ -n "$default" ]]; then
    printf "  ${WHITE}%-40s${NC}${DIM}[${default}]${NC}: " "$prompt"
  else
    printf "  ${WHITE}%-40s${NC}: " "$prompt"
  fi
  read -re resp < /dev/tty
  [[ -z "$resp" ]] && resp="$default"
  printf -v "$varname" '%s' "$resp"
}

ask_secret() {
  local prompt="$1" varname="$2" resp
  if [[ "${BYOC_YES:-}" == "1" ]]; then
    local envvar="BYOC_${varname}"
    resp="${!envvar:-${!varname:-}}"
    [[ -z "$resp" ]] && abort "$prompt must be set via BYOC_${varname} when BYOC_YES=1"
    printf -v "$varname" '%s' "$resp"
    printf "  ${WHITE}%-40s${NC}: ${DIM}******* (env)${NC}\n" "$prompt"
    return
  fi
  local existing="${!varname:-}"
  if [[ -n "$existing" ]]; then
    printf "  ${WHITE}%-40s${NC}${DIM}[set - Enter to keep, or type new]${NC}: " "$prompt"
  else
    printf "  ${WHITE}%-40s${NC}${DIM}[required]${NC}: " "$prompt"
  fi
  stty -echo 2>/dev/null; read -re resp < /dev/tty; stty echo 2>/dev/null
  echo ""
  [[ -z "$resp" && -n "$existing" ]] && resp="$existing"
  [[ -z "$resp" ]] && abort "$prompt is required."
  printf -v "$varname" '%s' "$resp"
}

# ── Spinner ───────────────────────────────────────────────────────────────────
SPINNER_PID=""
SPIN_CHARS=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')

spin_start() {
  local msg="$1"
  printf "${HIDE_CURSOR}"
  (
    local i=0
    while true; do
      printf "\r  ${CYAN}${SPIN_CHARS[$((i % 10))]}${NC}  ${msg}${DIM}...${NC}"
      sleep 0.1
      ((i++)) || true
    done
  ) &
  SPINNER_PID=$!
}

spin_stop() {
  local label="${1:-}"
  [[ -n "$SPINNER_PID" ]] && kill "$SPINNER_PID" 2>/dev/null && wait "$SPINNER_PID" 2>/dev/null || true
  SPINNER_PID=""
  printf "\r\033[K"
  printf "${SHOW_CURSOR}"
  [[ -n "$label" ]] && success "$label"
}

# ── SSM Execution Engine ──────────────────────────────────────────────────────
_ssm_send() {
  local instance="$1" script_file="$2"
  local params_file
  params_file=$(mktemp /tmp/byoc_ssm.XXXXXX.json)

  python3 - "$script_file" "$params_file" << 'PY'
import json, sys
lines = open(sys.argv[1]).read().splitlines()
lines = [l for l in lines if l.strip() and not l.strip().startswith('#')]
with open(sys.argv[2], 'w') as f:
    f.write(json.dumps({'commands': lines}))
PY

  local cmd_id
  cmd_id=$(aws ssm send-command \
    --instance-ids "$instance" \
    --document-name "AWS-RunShellScript" \
    --parameters "file://${params_file}" \
    --region "$REGION" --profile "$PROFILE" \
    --output text --query "Command.CommandId" 2>&1)
  rm -f "$params_file"

  [[ "$cmd_id" =~ ^[0-9a-f-]{36}$ ]] || {
    echo "SSM_ERROR: $cmd_id"
    return 1
  }

  local poll_count=0
  while true; do
    local status
    status=$(aws ssm get-command-invocation \
      --command-id "$cmd_id" --instance-id "$instance" \
      --region "$REGION" --profile "$PROFILE" \
      --query "Status" --output text 2>/dev/null) || status="InProgress"
    [[ "$status" != "InProgress" && "$status" != "Pending" ]] && break
    ((poll_count++)) || true
    if [[ "$poll_count" -ge 300 ]]; then
      echo "SSM_TIMEOUT: command $cmd_id still running after 15 minutes"
      return 1
    fi
    sleep 3
  done

  local out rc
  out=$(aws ssm get-command-invocation \
    --command-id "$cmd_id" --instance-id "$instance" \
    --region "$REGION" --profile "$PROFILE" \
    --query "StandardOutputContent" --output text 2>/dev/null)
  rc=$(aws ssm get-command-invocation \
    --command-id "$cmd_id" --instance-id "$instance" \
    --region "$REGION" --profile "$PROFILE" \
    --query "ResponseCode" --output text 2>/dev/null)

  echo "$out"
  [[ "$rc" == "0" ]]
}

# Run script on instance with spinner
ssm_run() {
  local instance="$1" script_file="$2" label="${3:-}"
  local t0=$SECONDS output
  output=$(_ssm_send "$instance" "$script_file") || {
    spin_stop
    abort "Remote command failed.\n\n${output}"
  }
  spin_stop "${label}"
  [[ -n "$output" ]] && echo -e "${DIM}${output}${NC}" >&2
  echo $((SECONDS - t0))
}

# Run in background; write output to file; echo PID
ssm_bg() {
  local instance="$1" script_file="$2" outfile="$3"
  (_ssm_send "$instance" "$script_file" > "$outfile" 2>&1; echo $? >> "${outfile}.rc") &
  echo $!
}

# ── AWS Helpers ───────────────────────────────────────────────────────────────
validate_creds() {
  aws sts get-caller-identity --profile "$PROFILE" --region "$REGION" \
    > /dev/null 2>&1 && return 0

  echo ""
  warn "AWS credentials expired."
  echo ""
  echo -e "  In a ${WHITE}separate terminal window${NC}, run:"
  echo -e "  ${CYAN}  aws configure set aws_access_key_id     \"\$AWS_ACCESS_KEY_ID\"     --profile ${PROFILE}${NC}"
  echo -e "  ${CYAN}  aws configure set aws_secret_access_key \"\$AWS_SECRET_ACCESS_KEY\" --profile ${PROFILE}${NC}"
  echo -e "  ${CYAN}  aws configure set aws_session_token     \"\$AWS_SESSION_TOKEN\"     --profile ${PROFILE}${NC}"
  echo ""
  echo -e "  Get fresh credentials from the ${WHITE}AWS SSO portal${NC} first (export the 3 lines),"
  echo -e "  then run the aws configure set commands above, then come back here."
  echo ""
  echo -e -n "  ${YELLOW}Press ${WHITE}[Enter]${YELLOW} once credentials are refreshed...${NC}"
  read -r < /dev/tty
  aws sts get-caller-identity --profile "$PROFILE" --region "$REGION" > /dev/null 2>&1 \
    || abort "Credentials still invalid. Re-run the installer after refreshing."
  success "Credentials refreshed."
}

get_private_ip() {
  aws ec2 describe-instances \
    --instance-ids "$1" \
    --query "Reservations[0].Instances[0].PrivateIpAddress" \
    --output text --region "$REGION" --profile "$PROFILE" 2>/dev/null
}

list_ssm_instances() {
  aws ssm describe-instance-information \
    --filters "Key=PingStatus,Values=Online" \
    --query "InstanceInformationList[*].[InstanceId,IPAddress,ComputerName,PlatformName]" \
    --output text --region "$REGION" --profile "$PROFILE" 2>/dev/null
}

pick_instance() {
  local role="$1" varname="$2"
  local rows
  rows=$(list_ssm_instances)

  if [[ -z "$rows" ]]; then
    ask "No SSM instances found. Enter $role instance ID" "" "$varname"
    return
  fi

  echo -e "\n  ${WHITE}Online SSM instances:${NC}\n"
  local i=1
  declare -a ids=()
  while IFS=$'\t' read -r id ip name platform; do
    printf "  ${CYAN}[%d]${NC}  %-22s  ${DIM}%-16s  %s${NC}\n" "$i" "$id" "$ip" "$name"
    ids+=("$id")
    ((i++)) || true
  done <<< "$rows"
  echo ""

  local choice
  if [[ "${BYOC_YES:-}" == "1" ]]; then
    local envvar="BYOC_${varname}"
    local preset="${!envvar:-}"
    [[ -z "$preset" ]] && abort "BYOC_YES=1 requires $envvar env var (instance ID for $role)"
    printf -v "$varname" '%s' "$preset"
    printf "  ${WHITE}%-40s${NC}: ${DIM}%s (env)${NC}\n" "Select $role instance" "$preset"
    return
  fi
  ask "Select $role instance number (or type instance ID directly)" "" choice
  if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 && "$choice" -le "${#ids[@]}" ]]; then
    printf -v "$varname" '%s' "${ids[$((choice-1))]}"
  else
    printf -v "$varname" '%s' "$choice"
  fi
}

# ── Config Summary Card ───────────────────────────────────────────────────────
print_config() {
  echo ""
  echo -e "${WHITE}${BOLD}  Configuration Summary${NC}"
  echo -e "${DIM}  ─────────────────────────────────────────────────────────────────${NC}"
  printf "  ${DIM}%-28s${NC}  %s\n"  "AWS Profile"        "$PROFILE"
  printf "  ${DIM}%-28s${NC}  %s\n"  "Region"             "$REGION"
  printf "  ${DIM}%-28s${NC}  %s  ${DIM}(%s)${NC}\n" "Kubernetes instance"  "$K8S_INSTANCE"  "$K8S_IP"
  printf "  ${DIM}%-28s${NC}  %s  ${DIM}(%s)${NC}\n" "PostgreSQL instance"  "$PG_INSTANCE"   "$PG_IP"
  printf "  ${DIM}%-28s${NC}  %s\n"  "Datadog site"       "$DD_SITE"
  printf "  ${DIM}%-28s${NC}  %s\n"  "Cluster name"       "$CLUSTER_NAME"
  printf "  ${DIM}%-28s${NC}  %s\n"  "Namespace"          "$NAMESPACE"
  printf "  ${DIM}%-28s${NC}  %s\n"  "S3 bucket"          "$BUCKET"
  printf "  ${DIM}%-28s${NC}  %s\n"  "API key"            "${DD_API_KEY:0:8}••••••••••••••••"
  echo -e "${DIM}  ─────────────────────────────────────────────────────────────────${NC}"
  echo ""
}

# ── Remote Phase Scripts ──────────────────────────────────────────────────────

write_phase1() { cat > /tmp/byoc_p1.sh << REMOTE
#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive
echo "=== reset any existing cluster ==="
kubeadm reset -f 2>/dev/null || true
rm -rf /etc/kubernetes /root/.kube /var/lib/etcd /var/lib/kubelet /etc/cni /opt/cni 2>/dev/null || true
apt-mark unhold kubelet kubeadm kubectl 2>/dev/null || true
echo "=== containerd ==="
apt-get update -qq
apt-get install -y -qq apt-transport-https ca-certificates curl gpg containerd
mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml
sed -i 's/SystemdCgroup = true/SystemdCgroup = false/' /etc/containerd/config.toml
systemctl restart containerd && systemctl enable containerd
echo "=== kernel settings ==="
modprobe br_netfilter overlay
cat > /etc/sysctl.d/99-k8s.conf << 'EOF'
net.bridge.bridge-nf-call-iptables=1
net.bridge.bridge-nf-call-ip6tables=1
net.ipv4.ip_forward=1
EOF
sysctl --system -q
swapoff -a && sed -i '/swap/d' /etc/fstab
echo "=== kubeadm ==="
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.32/deb/Release.key \
  | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.32/deb/ /' \
  > /etc/apt/sources.list.d/kubernetes.list
apt-get update -qq
apt-get install -y -qq kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl
echo "=== helm ==="
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
echo "=== kubeadm init ==="
kubeadm init \
  --control-plane-endpoint=${K8S_IP}:6443 \
  --pod-network-cidr=10.0.0.0/16 \
  --skip-phases=addon/kube-proxy \
  --ignore-preflight-errors=NumCPU 2>&1 | tail -5
mkdir -p /root/.kube
cp /etc/kubernetes/admin.conf /root/.kube/config
sed -i "s|https://.*:6443|https://${K8S_IP}:6443|g" /root/.kube/config /etc/kubernetes/admin.conf
echo "=== waiting for API server ==="
for i in \$(seq 1 24); do
  kubectl get nodes 2>/dev/null && break
  sleep 5
done
kubectl wait node --for=condition=Ready=False --timeout=60s 2>/dev/null || true
kubectl taint nodes --all node-role.kubernetes.io/control-plane- 2>/dev/null || true
kubectl get nodes
REMOTE
}

write_phase2() { cat > /tmp/byoc_p2.sh << REMOTE
#!/bin/bash
export KUBECONFIG=/root/.kube/config
helm repo add cilium https://helm.cilium.io/ --force-update 2>/dev/null || helm repo update
helm upgrade --install cilium cilium/cilium \
  --version 1.17.4 \
  --namespace kube-system \
  --set k8sServiceHost=${K8S_IP} \
  --set k8sServicePort=6443 \
  --wait --timeout=3m
kubectl wait node --all --for=condition=Ready --timeout=180s
kubectl get nodes
REMOTE
}

write_phase3() { cat > /tmp/byoc_p3.sh << REMOTE
#!/bin/bash
export KUBECONFIG=/root/.kube/config
echo "=== local-path-provisioner ==="
kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.31/deploy/local-path-storage.yaml
kubectl patch storageclass local-path \
  -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
kubectl -n local-path-storage rollout status deploy/local-path-provisioner --timeout=60s
echo "=== SeaweedFS ==="
helm repo add seaweedfs https://seaweedfs.github.io/seaweedfs/helm --force-update 2>/dev/null || helm repo update
cat > /tmp/swfs.yaml << 'EOF'
master:
  replicas: 1
  volumeSizeLimitMB: 30000
  data: {type: persistentVolumeClaim, size: "30G", storageClass: local-path}
volume:
  replicas: 1
  dataDirs:
    - {name: data, size: 100Gi, type: persistentVolumeClaim, storageClass: local-path, maxVolumes: 100}
filer:
  replicas: 1
  enablePVC: true
  data: {type: persistentVolumeClaim, size: "10G", storageClass: local-path}
s3: {enabled: true, replicas: 1, port: 8333, enableAuth: true}
persistence: {enabled: true}
admin: {enabled: true}
ingress: {enabled: false}
EOF
kubectl create ns seaweedfs 2>/dev/null || true
helm upgrade --install seaweedfs seaweedfs/seaweedfs -f /tmp/swfs.yaml -n seaweedfs
kubectl rollout status statefulset/seaweedfs-master -n seaweedfs --timeout=300s
echo "=== bucket + user ==="
kubectl exec -n seaweedfs seaweedfs-master-0 -- sh -c "
  echo 's3.bucket.create -name ${BUCKET}' | weed shell -master=localhost:9333
  echo 's3.configure -access_key=${S3_KEY} -secret_key=${S3_SECRET} -user=${BUCKET} -actions=Read,Write,List,Tagging -buckets=${BUCKET} -apply' | weed shell -master=localhost:9333
" 2>&1
kubectl create ns ${NAMESPACE} 2>/dev/null || true
kubectl delete secret byoc-logs-minio-credentials -n ${NAMESPACE} 2>/dev/null || true
kubectl create secret generic byoc-logs-minio-credentials \
  --from-literal AWS_ACCESS_KEY_ID="${S3_KEY}" \
  --from-literal AWS_SECRET_ACCESS_KEY="${S3_SECRET}" \
  -n ${NAMESPACE}
kubectl get pods -n seaweedfs
REMOTE
}

write_phase4() { cat > /tmp/byoc_p4.sh << REMOTE
#!/bin/bash
export DEBIAN_FRONTEND=noninteractive
set -e
apt-get update -qq && apt-get install -y -qq postgresql-14
systemctl enable postgresql && systemctl start postgresql
sudo -u postgres psql -c "CREATE USER ${PG_USER} WITH ENCRYPTED PASSWORD '${PG_PASS}';" 2>/dev/null || true
sudo -u postgres psql -c "CREATE DATABASE ${PG_USER};" 2>/dev/null || true
sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE ${PG_USER} TO ${PG_USER};"
sudo -u postgres psql -c "ALTER DATABASE ${PG_USER} OWNER TO ${PG_USER};"
PG_CONF=\$(find /etc/postgresql -name postgresql.conf | head -1)
PG_HBA=\$(find /etc/postgresql -name pg_hba.conf | head -1)
sed -i "s/#listen_addresses = 'localhost'/listen_addresses = '*'/" "\$PG_CONF"
grep -q "host.*${PG_USER}.*${PG_USER}.*10.0.0.0" "\$PG_HBA" || \
  echo "host  ${PG_USER}  ${PG_USER}  10.0.0.0/8  md5" >> "\$PG_HBA"
systemctl restart postgresql
systemctl is-active postgresql
echo "PostgreSQL ready at ${PG_IP}:5432"
REMOTE
}

write_phase4b() { cat > /tmp/byoc_p4b.sh << REMOTE
#!/bin/bash
export KUBECONFIG=/root/.kube/config
kubectl create ns ${NAMESPACE} 2>/dev/null || true
kubectl delete secret byoc-logs-metastore-uri -n ${NAMESPACE} 2>/dev/null || true
kubectl create secret generic byoc-logs-metastore-uri \
  --from-literal QW_METASTORE_URI="postgres://${PG_USER}:${PG_PASS}@${PG_IP}:5432/${PG_USER}?sslmode=disable" \
  -n ${NAMESPACE}
echo "Metastore URI secret created."
REMOTE
}

write_phase5() { cat > /tmp/byoc_p5.sh << REMOTE
#!/bin/bash
export KUBECONFIG=/root/.kube/config
kubectl delete secret datadog-secret -n ${NAMESPACE} 2>/dev/null || true
kubectl create secret generic datadog-secret \
  --from-literal api-key="${DD_API_KEY}" -n ${NAMESPACE}
helm repo add datadog https://helm.datadoghq.com --force-update 2>/dev/null || helm repo update
cat > /tmp/ddvals.yaml << 'EOF'
datadog:
  site: ${DD_SITE}
  apiKeyExistingSecret: datadog-secret
serviceAccount:
  create: true
  name: ${NAMESPACE}
config:
  default_index_root_uri: s3://${BUCKET}/indexes
  storage:
    s3:
      endpoint: http://seaweedfs-s3.seaweedfs.svc.cluster.local:8333
      force_path_style_access: true
metastore:
  extraEnvFrom:
    - secretRef: {name: byoc-logs-metastore-uri}
    - secretRef: {name: byoc-logs-minio-credentials}
indexer:
  replicaCount: 1
  podSize: large
  persistentVolume: {enabled: true, storage: 50Gi, storageClass: local-path}
  extraEnvFrom:
    - secretRef: {name: byoc-logs-minio-credentials}
searcher:
  replicaCount: 1
  podSize: large
  extraEnvFrom:
    - secretRef: {name: byoc-logs-minio-credentials}
controlPlane:
  extraEnvFrom:
    - secretRef: {name: byoc-logs-minio-credentials}
janitor:
  extraEnvFrom:
    - secretRef: {name: byoc-logs-minio-credentials}
EOF
helm upgrade --install ${NAMESPACE} datadog/cloudprem -f /tmp/ddvals.yaml -n ${NAMESPACE}
echo "=== waiting for pods ==="
kubectl wait --for=condition=Ready pod \
  -l app.kubernetes.io/instance=${NAMESPACE} \
  -n ${NAMESPACE} --timeout=300s 2>&1 | tail -3
kubectl get pods -n ${NAMESPACE}
REMOTE
}

write_phase6() { cat > /tmp/byoc_p6.sh << REMOTE
#!/bin/bash
export KUBECONFIG=/root/.kube/config
helm upgrade --install datadog-operator datadog/datadog-operator -n ${NAMESPACE} --wait --timeout=2m
cat > /tmp/dda.yaml << 'EOF'
apiVersion: datadoghq.com/v2alpha1
kind: DatadogAgent
metadata:
  name: datadog
  namespace: ${NAMESPACE}
spec:
  global:
    clusterName: ${CLUSTER_NAME}
    site: ${DD_SITE}
    kubelet: {tlsVerify: false}
    credentials:
      apiSecret: {secretName: datadog-secret, keyName: api-key}
    env:
      - name: DD_LOGS_CONFIG_LOGS_DD_URL
        value: http://${NAMESPACE}-cloudprem-indexer.${NAMESPACE}.svc.cluster.local:7280
      - name: DD_LOGS_CONFIG_EXPECTED_TAGS_DURATION
        value: "100000"
  features:
    logCollection: {enabled: true, containerCollectAll: true}
    prometheusScrape: {enabled: true, enableServiceEndpoints: true}
  override:
    nodeAgent:
      env:
        - name: DD_HOSTNAME
          valueFrom:
            fieldRef: {fieldPath: spec.nodeName}
EOF
kubectl apply -f /tmp/dda.yaml
echo "=== waiting for operator to create cluster-agent deployment ==="
for i in $(seq 1 36); do
  kubectl get deployment/datadog-cluster-agent -n ${NAMESPACE} 2>/dev/null && break
  sleep 5
done
kubectl wait deployment/datadog-cluster-agent -n ${NAMESPACE} \
  --for=condition=Available --timeout=180s
kubectl rollout status daemonset/datadog-agent -n ${NAMESPACE} --timeout=180s
echo "=== final pod status ==="
kubectl get pods -n ${NAMESPACE}
REMOTE
}

# ── Final Dashboard ───────────────────────────────────────────────────────────
print_dashboard() {
  echo ""
  echo -e "${GREEN}${BOLD}"
  echo "  ╔══════════════════════════════════════════════════════════════════╗"
  echo "  ║                                                                  ║"
  echo "  ║   🎉  BYOC CloudPrem Lab is Live                                ║"
  echo "  ║                                                                  ║"
  echo "  ╚══════════════════════════════════════════════════════════════════╝"
  echo -e "${NC}"

  echo -e "  ${YELLOW}${BOLD}  Required: Enable the logs-cloudprem feature flag${NC}"
  echo -e "  ${YELLOW}  The reverse connection will not activate until this is on.${NC}"
  echo -e "  ${YELLOW}  Ask your Datadog contact (or Mosaic admin) to enable it at:${NC}"
  echo -e "  ${CYAN}  https://mosaic.us1.ddbuild.io/feature-flags/logs-cloudprem${NC}"
  echo -e "  ${YELLOW}  Org: ${WHITE}${DD_SITE}${YELLOW}  API key prefix: ${WHITE}${DD_API_KEY:0:8}...${NC}"
  echo ""

  echo -e "  ${WHITE}${BOLD}Verify in Datadog:${NC}"
  echo ""
  printf "  ${CYAN}1.${NC}  %-55s\n" "https://${DD_SITE}/byoc-logs"
  printf "      ${DIM}%-55s${NC}\n" "→ Your cluster should show: Connected  (Reverse)"
  echo ""
  printf "  ${CYAN}2.${NC}  %-55s\n" "Hover cluster → Search Logs"
  printf "      ${DIM}%-55s${NC}\n" "→ Pod logs appear within ~2 minutes"
  echo ""
  printf "  ${CYAN}3.${NC}  %-55s\n" "https://${DD_SITE}/metric/summary?filter=cloudprem"
  printf "      ${DIM}%-55s${NC}\n" "→ QuickWit internal metrics via DogStatsD"
  echo ""

  echo -e "  ${WHITE}${BOLD}Installed components:${NC}"
  echo ""
  printf "  ${GREEN}✓${NC}  %-32s  ${DIM}%s${NC}\n"  "Kubernetes v1.32 (kubeadm)"  "$K8S_INSTANCE ($K8S_IP)"
  printf "  ${GREEN}✓${NC}  %-32s  ${DIM}%s${NC}\n"  "Cilium CNI"                  "kube-system"
  printf "  ${GREEN}✓${NC}  %-32s  ${DIM}%s${NC}\n"  "local-path-provisioner"      "default StorageClass"
  printf "  ${GREEN}✓${NC}  %-32s  ${DIM}%s${NC}\n"  "SeaweedFS (S3)"              "s3://byoclogs @ :8333"
  printf "  ${GREEN}✓${NC}  %-32s  ${DIM}%s${NC}\n"  "PostgreSQL 14"               "$PG_INSTANCE ($PG_IP)"
  printf "  ${GREEN}✓${NC}  %-32s  ${DIM}%s${NC}\n"  "CloudPrem"                   "$NAMESPACE namespace"
  printf "  ${GREEN}✓${NC}  %-32s  ${DIM}%s${NC}\n"  "Datadog Operator + Agent"    "log collection active"
  echo ""
  echo -e "  ${DIM}Note: AWS STS tokens expire every ~1hr. When SSM commands fail,${NC}"
  echo -e "  ${DIM}paste fresh export block and re-run the aws configure set commands.${NC}"
  echo ""
}

# =============================================================================
#  MAIN
# =============================================================================
banner

# ── Step 0: Prerequisites ─────────────────────────────────────────────────────
section "Prerequisites" "0"
for tool in aws python3; do
  command -v "$tool" &>/dev/null \
    && success "$tool found" \
    || abort "$tool not found — install it first."
done

# ── Step 0: Configuration ─────────────────────────────────────────────────────
section "Configuration" "◎"

ask "AWS profile"                             "byoc"          PROFILE
ask "AWS region (e.g. us-east-1, us-west-1)"  "us-east-1"     REGION

info "Validating credentials..."
validate_creds
echo ""

info "Fetching available SSM instances..."
pick_instance "Kubernetes node" K8S_INSTANCE
pick_instance "PostgreSQL node" PG_INSTANCE

ask "Datadog site"                            "datadoghq.com" DD_SITE
echo ""
echo -e "  ${DIM}The next two values determine your Datadog cluster identifier:${NC}"
echo -e "  ${DIM}  <namespace>-<namespace>-<cluster-name>${NC}"
echo -e "  ${DIM}  e.g. byoclogs-byoclogs-cloudprem${NC}"
echo -e "  ${DIM}  This is how the cluster appears in app.datadoghq.com/byoc-logs${NC}"
echo ""
ask "Cluster name in Datadog"                 "cloudprem"     CLUSTER_NAME
ask "Kubernetes namespace"                    "byoclogs"      NAMESPACE
ask "S3 bucket name"                          "byoclogs"      BUCKET
ask "PostgreSQL database / user"              "byoclogs"      PG_USER
ask "PostgreSQL password"                     "byoclogs"      PG_PASS
ask_secret "Datadog API key"                                  DD_API_KEY

echo ""
info "Resolving instance IPs..."
K8S_IP=$(get_private_ip "$K8S_INSTANCE") || abort "Could not resolve IP for $K8S_INSTANCE"
[[ "$K8S_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] \
  || abort "IP lookup returned '${K8S_IP}' for ${K8S_INSTANCE} — check instance ID and region."
PG_IP=$(get_private_ip "$PG_INSTANCE")   || abort "Could not resolve IP for $PG_INSTANCE"
[[ "$PG_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] \
  || abort "IP lookup returned '${PG_IP}' for ${PG_INSTANCE} — check instance ID and region."

# Re-key checkpoint dir to this specific K8S instance so runs against different
# nodes don't share state, and re-running the same node resumes correctly.
CKPT_DIR="${TMPDIR:-/tmp}/.byoc_ckpt_${K8S_INSTANCE}"
mkdir -p "$CKPT_DIR"

S3_KEY=$(openssl rand -hex 10)
S3_SECRET=$(openssl rand -hex 20)

print_config
arch_diagram "k8s"

echo -e "  ${YELLOW}  This will take approximately 15–20 minutes total.${NC}"
echo -e "  ${YELLOW}  PostgreSQL (Phase 4) runs in parallel with storage (Phase 3).${NC}"
pause

# ── Phase 1: Kubernetes ───────────────────────────────────────────────────────
section "Phase 1 — Kubernetes (kubeadm)" "①"
explain "kubeadm bootstraps a production-grade Kubernetes cluster:
containerd (CRI) → kubelet → kubeadm init → TLS PKI
We use the PRIVATE IP for --control-plane-endpoint so the
kubeconfig works from inside the instance via SSM without
hairpin NAT. The control-plane taint is removed so pods
can schedule on this single node.

Phase 1 is idempotent: it runs 'kubeadm reset -f' first,
so re-running the installer on an existing node is safe."

if ckpt_done "phase1"; then
  success "Phase 1 already completed — skipping."
else
  write_phase1
  spin_start "Bootstrapping Kubernetes"
  elapsed=$(ssm_run "$K8S_INSTANCE" /tmp/byoc_p1.sh)
  ckpt_set "phase1"
  phase_done "Kubernetes bootstrap" "$elapsed"
fi

# ── Phase 2: Cilium ───────────────────────────────────────────────────────────
section "Phase 2 — Cilium CNI" "②"
arch_diagram "cilium"
explain "Cilium is an eBPF-based CNI — it programs the Linux kernel
directly for pod networking, bypassing iptables overhead.
On bare metal, the cluster service IP (10.96.0.1) is not
reachable during Cilium's bootstrap phase. We pass
--set k8sServiceHost to point Cilium's init container
directly at the API server's private IP. Without this,
Cilium crashes in a bootstrap deadlock."

if ckpt_done "phase2"; then
  success "Phase 2 already completed — skipping."
else
  write_phase2
  spin_start "Installing Cilium and waiting for node Ready"
  elapsed=$(ssm_run "$K8S_INSTANCE" /tmp/byoc_p2.sh)
  ckpt_set "phase2"
  phase_done "Cilium CNI" "$elapsed"
fi

# ── Phase 3+4 (parallel): Storage + PostgreSQL ────────────────────────────────
section "Phase 3 — Storage  ·  Phase 4 — PostgreSQL  (parallel)" "③④"
arch_diagram "storage"
explain "Two independent phases running concurrently:

  Phase 3 — local-path-provisioner + SeaweedFS
  local-path-provisioner creates PVCs as host directories.
  SeaweedFS provides an S3-compatible API for CloudPrem to
  store indexed log segments (Parquet splits). We replaced
  Longhorn (deadlock bug on k8s 1.32+) and MinIO (archived).

  Phase 4 — PostgreSQL 14 on t3.micro
  CloudPrem's QuickWit engine tracks log segment metadata
  (split catalog) in PostgreSQL. QuickWit defaults to SSL;
  a bare-metal PostgreSQL has no certs, so we append
  ?sslmode=disable to the connection URI.

  Both run on separate EC2 instances — zero contention."

PG_OUT=$(mktemp /tmp/byoc_pg_out.XXXXXX)
STORAGE_ELAPSED=0
PG_ELAPSED=0

if ckpt_done "phase3" && ckpt_done "phase4"; then
  success "Phases 3 and 4 already completed — skipping."
else
  write_phase3
  write_phase4
  write_phase4b

  # Start PostgreSQL in background
  PG_PID=""
  if ! ckpt_done "phase4"; then
    PG_PID=$(ssm_bg "$PG_INSTANCE" /tmp/byoc_p4.sh "$PG_OUT")
    info "PostgreSQL install running in background (PID $PG_PID)..."
  fi

  # Storage in foreground
  if ! ckpt_done "phase3"; then
    spin_start "Installing local-path-provisioner + SeaweedFS"
    STORAGE_ELAPSED=$(ssm_run "$K8S_INSTANCE" /tmp/byoc_p3.sh)
    ckpt_set "phase3"
    phase_done "Storage (local-path + SeaweedFS)" "$STORAGE_ELAPSED"
  fi

  # Wait for PostgreSQL background job
  if [[ -n "$PG_PID" ]]; then
    spin_start "Waiting for PostgreSQL"
    local_t0=$SECONDS
    wait "$PG_PID" || true
    spin_stop
    local_rc=$(cat "${PG_OUT}.rc" 2>/dev/null | tail -1)
    PG_ELAPSED=$((SECONDS - local_t0))
    if [[ "$local_rc" != "0" ]]; then
      echo -e "${DIM}$(cat "$PG_OUT")${NC}"
      abort "PostgreSQL install failed."
    fi
    echo -e "${DIM}$(cat "$PG_OUT")${NC}"
    ckpt_set "phase4"
    phase_done "PostgreSQL" "$PG_ELAPSED"
    rm -f "$PG_OUT" "${PG_OUT}.rc"
  fi

  # Store metastore URI secret on k8s instance
  spin_start "Creating metastore URI secret"
  ssm_run "$K8S_INSTANCE" /tmp/byoc_p4b.sh > /dev/null
  spin_stop "Metastore URI secret created"
fi

# ── Phase 5: CloudPrem ────────────────────────────────────────────────────────
section "Phase 5 — CloudPrem" "⑤"
arch_diagram "cloudprem"
explain "The CloudPrem helm chart deploys 5 components:
  indexer       Ingests logs → writes Parquet splits to SeaweedFS
  searcher      Executes queries against splits in SeaweedFS
  metastore     Manages the split catalog in PostgreSQL
  control-plane Orchestrates the cluster + reverse WebSocket to SaaS
  janitor       Enforces retention policy, cleans expired splits

The reverse WebSocket is what allows Datadog SaaS to query
your on-prem searcher without any public ingress — the cluster
initiates the connection outbound to app.datadoghq.com."

if ckpt_done "phase5"; then
  success "Phase 5 already completed — skipping."
else
  write_phase5
  spin_start "Deploying CloudPrem (this takes ~3 minutes)"
  elapsed=$(ssm_run "$K8S_INSTANCE" /tmp/byoc_p5.sh)
  ckpt_set "phase5"
  phase_done "CloudPrem" "$elapsed"
fi

echo ""
info "At this point, open https://app.datadoghq.com/byoc-logs"
info "Your cluster should appear as Connected before we continue."
pause

# ── Phase 6: Datadog Operator + Agent ─────────────────────────────────────────
section "Phase 6 — Datadog Operator + Agent" "⑥"
arch_diagram "agent"
explain "The Datadog Operator manages Agent deployments declaratively.
You define a DatadogAgent resource; the operator handles the
DaemonSet, ClusterAgent, and RBAC lifecycle automatically.

Key config: DD_LOGS_CONFIG_LOGS_DD_URL redirects log shipping
from app.datadoghq.com to the local CloudPrem indexer service
(byoclogs-cloudprem-indexer.byoclogs.svc.cluster.local:7280).
Log data never leaves your cluster — only metadata and query
traffic traverse the reverse WebSocket to Datadog SaaS.

DD_LOGS_CONFIG_EXPECTED_TAGS_DURATION: 100000ms buffer ensures
Kubernetes metadata tags (pod name, namespace, container) are
fully resolved before logs are sent to the indexer."

if ckpt_done "phase6"; then
  success "Phase 6 already completed — skipping."
else
  write_phase6
  spin_start "Deploying Datadog Operator and Agent"
  elapsed=$(ssm_run "$K8S_INSTANCE" /tmp/byoc_p6.sh)
  ckpt_set "phase6"
  phase_done "Datadog Operator + Agent" "$elapsed"
fi

# ── Done ──────────────────────────────────────────────────────────────────────
arch_diagram "done"
print_dashboard
