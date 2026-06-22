#!/usr/bin/env bash
# =============================================================================
#  Datadog BYOC CloudPrem — Bare-Metal Lab Installer
#  github.com/datadoghq-se/byoc-onprem-lab
# =============================================================================
set -uo pipefail
IFS=$'\n\t'

# ── Terminal & Colors ─────────────────────────────────────────────────────────
TERM_WIDTH=$(tput cols 2>/dev/null || echo 80)
RED=$'\033[0;31m';   GREEN=$'\033[0;32m';  YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m';  CYAN=$'\033[0;36m';   WHITE=$'\033[1;37m'
MAGENTA=$'\033[0;35m'; BOLD=$'\033[1m';    DIM=$'\033[2m';  NC=$'\033[0m'
HIDE_CURSOR=$'\033[?25l'; SHOW_CURSOR=$'\033[?25h'
trap 'printf "${SHOW_CURSOR}"; stty echo 2>/dev/null; [[ -n "${SPINNER_PID:-}" ]] && kill "$SPINNER_PID" 2>/dev/null; exit' INT TERM EXIT

# ── Checkpoint + Config Persistence ──────────────────────────────────────────
# CKPT_DIR is keyed to K8S_INSTANCE after selection. A config.env is saved
# there so the user only needs to type 3 things on resume (profile, region,
# instance ID) and everything else is reloaded automatically.
GLOBAL_LAST="/tmp/.byoc_last.env"
CKPT_DIR="/tmp/.byoc_ckpt_default"
mkdir -p "$CKPT_DIR"
ckpt_set()  { touch "$CKPT_DIR/$1"; }
ckpt_done() { [[ -f "$CKPT_DIR/$1" ]]; }

save_config() {
  cat > "$CKPT_DIR/config.env" << CONF
PROFILE=${PROFILE}
REGION=${REGION}
K8S_INSTANCE=${K8S_INSTANCE}
PG_INSTANCE=${PG_INSTANCE}
DD_SITE=${DD_SITE}
CLUSTER_NAME=${CLUSTER_NAME}
NAMESPACE=${NAMESPACE}
BUCKET=${BUCKET}
PG_USER=${PG_USER}
PG_PASS=${PG_PASS}
DD_API_KEY=${DD_API_KEY}
S3_KEY=${S3_KEY}
S3_SECRET=${S3_SECRET}
K8S_IP=${K8S_IP}
PG_IP=${PG_IP}
CONF
  chmod 600 "$CKPT_DIR/config.env"
  printf "K8S_INSTANCE=%s\nPG_INSTANCE=%s\nPROFILE=%s\nREGION=%s\n" \
    "$K8S_INSTANCE" "$PG_INSTANCE" "$PROFILE" "$REGION" > "$GLOBAL_LAST"
}

# ── UI: Core Helpers ──────────────────────────────────────────────────────────
_pad() { printf '%*s' "$1" ''; }
_hr()  { printf '%*s\n' "$TERM_WIDTH" '' | tr ' ' "${1:--}"; }

banner() {
  clear
  echo -e "${BLUE}${BOLD}"
  echo "  ╔════════════════════════════════════════════════════════════════╗"
  echo "  ║                                                                ║"
  echo "  ║    ██████╗ ██╗   ██╗ ██████╗  ██████╗                          ║"
  echo "  ║    ██╔══██╗╚██╗ ██╔╝██╔═══██╗██╔════╝                          ║"
  echo "  ║    ██████╔╝ ╚████╔╝ ██║   ██║██║                               ║"
  echo "  ║    ██╔══██╗  ╚██╔╝  ██║   ██║██║                               ║"
  echo "  ║    ██████╔╝   ██║   ╚██████╔╝╚██████╗                          ║"
  echo "  ║    ╚═════╝    ╚═╝    ╚═════╝  ╚═════╝  CloudPrem Lab Installer ║"
  echo "  ║                                                                ║"
  echo "  ╚════════════════════════════════════════════════════════════════╝"
  echo -e "${NC}"
  echo -e "  ${DIM}Bare-metal Kubernetes · SeaweedFS · QuickWit · Reverse Connection${NC}"
  echo -e "  ${DIM}By Datadog SEs${NC}"
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
  echo -e "${DIM}"
  echo "  ╔════════════════════════════════════════════════════════════════╗"
  echo -e "  ║  ${saas_color}  Datadog SaaS (app.datadoghq.com)${DIM}"
  echo    "  ║         ^ reverse WebSocket"
  echo -e "  ║  ${k8s_color}  Kubernetes (kubeadm)  <- Phase 1${DIM}"
  echo -e "  ║    ${cilium_color}+- Cilium CNI             <- Phase 2${DIM}"
  echo -e "  ║    ${storage_color}+- local-path + SeaweedFS <- Phase 3${DIM}"
  echo -e "  ║    ${cloudprem_color}+- CloudPrem (indexer/searcher/ctrl) <- Phase 5${DIM}"
  echo -e "  ║    ${agent_color}+- Datadog Agent          <- Phase 6${DIM}"
  echo    "  ║"
  echo -e "  ║  ${pg_color}  PostgreSQL t3.micro     <- Phase 4 (parallel)${DIM}"
  echo    "  ╚════════════════════════════════════════════════════════════════╝"
  echo -e "${NC}"
}

explain() {
  local text="$1"
  echo -e "${DIM}  ╔════════════════════════════════════════════════════════════════╗${NC}"
  while IFS= read -r line; do
    echo -e "${DIM}  ║${NC}  ${CYAN}${line}${NC}"
  done <<< "$text"
  echo -e "${DIM}  ╚════════════════════════════════════════════════════════════════╝${NC}"
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
  [[ ! -e /dev/tty ]] && return
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
    printf "  ${CYAN}▶${NC}  ${WHITE}%-38s${NC}${DIM}[${default}]${NC}: " "$prompt"
  else
    printf "  ${CYAN}▶${NC}  ${WHITE}%-38s${NC}: " "$prompt"
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
    printf "  ${CYAN}▶${NC}  ${WHITE}%-38s${NC}${DIM}[set — Enter to keep]${NC}: " "$prompt"
  else
    printf "  ${CYAN}▶${NC}  ${WHITE}%-38s${NC}${YELLOW}[required]${NC}: " "$prompt"
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
lines = [l for l in lines if l.strip() and not (l.strip().startswith('#') and not l.strip().startswith('#!'))]
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
    local status poll_raw
    poll_raw=$(aws ssm get-command-invocation \
      --command-id "$cmd_id" --instance-id "$instance" \
      --region "$REGION" --profile "$PROFILE" \
      --query "Status" --output text 2>&1) || true
    if echo "$poll_raw" | grep -qi "ExpiredToken\|AuthFailure\|InvalidClientTokenId"; then
      # Refresh inline — the command is already running on the remote, no need to re-send
      validate_creds >&2
      continue
    fi
    status="$poll_raw"
    [[ "$status" != "InProgress" && "$status" != "Pending" ]] && break
    ((poll_count++)) || true
    if [[ "$poll_count" -ge 600 ]]; then
      echo "SSM_TIMEOUT: command $cmd_id still running after 30 minutes"
      return 1
    fi
    sleep 3
  done

  local out rc
  out=$(aws ssm get-command-invocation \
    --command-id "$cmd_id" --instance-id "$instance" \
    --region "$REGION" --profile "$PROFILE" \
    --query "StandardOutputContent" --output text 2>&1) || out=""
  # Creds can expire between poll and output fetch — refresh and retry once
  if echo "$out" | grep -qi "ExpiredToken\|AuthFailure\|InvalidClientTokenId"; then
    validate_creds >&2
    out=$(aws ssm get-command-invocation \
      --command-id "$cmd_id" --instance-id "$instance" \
      --region "$REGION" --profile "$PROFILE" \
      --query "StandardOutputContent" --output text 2>/dev/null) || out=""
  fi
  rc=$(aws ssm get-command-invocation \
    --command-id "$cmd_id" --instance-id "$instance" \
    --region "$REGION" --profile "$PROFILE" \
    --query "ResponseCode" --output text 2>/dev/null) || rc=""

  echo "$out"
  [[ "$rc" == "0" ]]
}

# Run script on instance with spinner
ssm_run() {
  local instance="$1" script_file="$2" label="${3:-}"
  local t0=$SECONDS output retried=false

  while true; do
    output=$(_ssm_send "$instance" "$script_file") && break

    # Expired token before/during send-command: refresh and retry once automatically
    if [[ "$retried" == "false" ]] && \
        echo "$output" | grep -qi "ExpiredToken\|expired token\|AuthFailure\|InvalidClientTokenId"; then
      spin_stop >&2
      validate_creds >&2
      echo -e "  ${DIM}Session refreshed — retrying...${NC}\n" >&2
      retried=true
      continue
    fi

    # Real failure — log and show targeted guidance
    spin_stop >&2
    local logfile="${CKPT_DIR}/error_$(basename "$script_file" .sh)_$(date +%H%M%S).log"
    echo "$output" > "$logfile"
    if echo "$output" | grep -qi "InvalidInstanceId\|not.*registered\|TargetNotConnected"; then
      echo -e "\n  ${RED}${BOLD} ✗  Instance not reachable via SSM${NC}" >&2
      echo -e "  ${DIM}  Instance: ${instance}${NC}" >&2
      echo -e "  ${YELLOW}The instance is not registered with SSM yet (can take 3-5 min after launch).${NC}" >&2
      echo -e "  Re-run in a minute — the checkpoint system will skip completed phases.\n" >&2
    else
      echo -e "\n  ${RED}${BOLD} ✗  Remote command failed${NC}" >&2
      echo -e "  ${DIM}  Instance: ${instance}  Script: $(basename "$script_file")${NC}" >&2
      echo -e "\n${DIM}  Last output:${NC}" >&2
      echo "$output" | tail -20 | while IFS= read -r line; do
        echo -e "  ${DIM}${line}${NC}" >&2
      done
    fi
    echo -e "\n  ${DIM}Full log: ${logfile}${NC}\n" >&2
    printf "${SHOW_CURSOR}" >&2
    exit 1
  done

  spin_stop "${label}" >&2
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

  local sso_url sso_account sso_role
  sso_url=$(aws configure get sso_start_url --profile "$PROFILE" 2>/dev/null || true)
  sso_account=$(aws configure get sso_account_id --profile "$PROFILE" 2>/dev/null || true)
  sso_role=$(aws configure get sso_role_name --profile "$PROFILE" 2>/dev/null || true)

  echo ""
  echo -e "  ${RED}${BOLD} ✗  AWS credentials not valid${NC}"
  echo ""

  if [[ -z "$sso_url" || -z "$sso_account" || -z "$sso_role" ]]; then
    # Profile incomplete — run aws configure sso inline right now, no need to re-run installer
    echo -e "  ${YELLOW}The '${PROFILE}' profile needs SSO setup. Starting it now...${NC}"
    echo ""
    echo -e "  ${DIM}  Enter these values when prompted:${NC}"
    echo -e "  ${DIM}    SSO session name → ${PROFILE}${NC}"
    echo -e "  ${DIM}    SSO start URL    → https://d-906757b57c.awsapps.com/start${NC}"
    echo -e "  ${DIM}    SSO region       → us-east-1${NC}"
    echo -e "  ${DIM}    (then pick your AWS account and role from the list)${NC}"
    echo ""
    aws configure sso --profile "$PROFILE" \
      || abort "SSO setup failed. Run manually: aws configure sso --profile ${PROFILE}"
  else
    # Profile fully configured — session just expired
    echo -e "  ${YELLOW}Session expired. Logging in — approve the request in your browser, then return here.${NC}"
    echo ""
    aws sso login --profile "$PROFILE" \
      || abort "SSO login failed. Run: aws configure sso --profile ${PROFILE}"
  fi

  echo ""
  sleep 2  # let the CLI finish writing the cached token
  aws sts get-caller-identity --profile "$PROFILE" --region "$REGION" > /dev/null 2>&1 \
    || abort "Still not authenticated. Run: aws configure sso --profile ${PROFILE}"
  success "SSO session valid — resuming."
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

detect_byoc_instance() {
  local tag_role="$1"
  aws ec2 describe-instances \
    --filters \
      "Name=tag:Project,Values=byoc-cloudprem-lab" \
      "Name=tag:byoc-role,Values=${tag_role}" \
      "Name=instance-state-name,Values=running" \
    --query "Reservations[*].Instances[*].InstanceId" \
    --output text --region "$REGION" --profile "$PROFILE" 2>/dev/null \
    | tr '\t' '\n' | grep -v '^$' || true
}

pick_instance() {
  local role="$1" varname="$2" tag_role="${3:-}"
  local rows last_var="LAST_${varname}"
  local last_id="${!last_var:-}"

  if [[ "${BYOC_YES:-}" == "1" ]]; then
    rows=$(list_ssm_instances)
    local envvar="BYOC_${varname}"
    local preset="${!envvar:-$last_id}"
    [[ -z "$preset" ]] && abort "BYOC_YES=1 requires $envvar env var (instance ID for $role)"
    printf -v "$varname" '%s' "$preset"
    printf "  ${WHITE}%-40s${NC}: ${DIM}%s (env)${NC}\n" "Select $role instance" "$preset"
    return
  fi

  # Auto-detect instances tagged by launch_instances.sh
  if [[ -n "$tag_role" ]]; then
    local detected
    detected=$(detect_byoc_instance "$tag_role")
    local count
    count=$(echo "$detected" | grep -c '^i-' 2>/dev/null || true)
    count=${count:-0}
    if [[ "$count" -eq 1 ]]; then
      local auto_id="$detected"
      local auto_ip
      auto_ip=$(get_private_ip "$auto_id")
      printf -v "$varname" '%s' "$auto_id"
      success "Auto-detected $role: ${auto_id}  ${DIM}(${auto_ip})${NC}"
      return
    elif [[ "$count" -gt 1 ]]; then
      echo -e "\n  ${YELLOW}Multiple byoc-${tag_role} instances found — select one:${NC}\n"
      local i=1
      declare -a ids=()
      while IFS= read -r id; do
        [[ -z "$id" ]] && continue
        local ip; ip=$(get_private_ip "$id")
        local marker=""
        [[ "$id" == "$last_id" ]] && marker=" ${GREEN}← last used${NC}"
        printf "  ${CYAN}[%d]${NC}  %-22s  ${DIM}%-16s${NC}%b\n" "$i" "$id" "$ip" "$marker"
        ids+=("$id")
        ((i++)) || true
      done <<< "$detected"
      echo ""
      local choice
      ask "Select $role instance (number or i-...)" "${last_id}" choice
      if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 && "$choice" -le "${#ids[@]}" ]]; then
        printf -v "$varname" '%s' "${ids[$((choice-1))]}"
      else
        printf -v "$varname" '%s' "$choice"
      fi
      return
    fi
  fi

  # Fallback: show all SSM-online instances
  rows=$(list_ssm_instances)
  if [[ -z "$rows" ]]; then
    ask "No SSM instances found. Enter $role instance ID" "$last_id" "$varname"
    return
  fi

  echo -e "\n  ${WHITE}Online SSM instances:${NC}\n"
  local i=1
  declare -a ids=()
  while IFS=$'\t' read -r id ip name platform; do
    local marker=""
    [[ "$id" == "$last_id" ]] && marker=" ${GREEN}← last used${NC}"
    printf "  ${CYAN}[%d]${NC}  %-22s  ${DIM}%-16s  %s${NC}%b\n" "$i" "$id" "$ip" "$name" "$marker"
    ids+=("$id")
    ((i++)) || true
  done <<< "$rows"
  echo ""

  local choice
  ask "Select $role instance (number or i-...)" "${last_id}" choice
  if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 && "$choice" -le "${#ids[@]}" ]]; then
    printf -v "$varname" '%s' "${ids[$((choice-1))]}"
  else
    printf -v "$varname" '%s' "$choice"
  fi
}

validate_instance() {
  local instance="$1" role="$2"
  [[ "$instance" =~ ^i-[0-9a-f]+$ ]] \
    || abort "${role} instance ID '${instance}' is not valid (expected i-xxxxxxxxxx). Check the ID and try again."
  local status
  status=$(aws ssm describe-instance-information \
    --filters "Key=InstanceIds,Values=${instance}" \
    --query "InstanceInformationList[0].PingStatus" \
    --output text --region "$REGION" --profile "$PROFILE" 2>/dev/null)
  [[ "$status" == "Online" ]] \
    || abort "${role} instance ${instance} is not Online in SSM (got: '${status:-not found}').\n  Check: correct instance ID, region is ${REGION}, SSM agent is running, IAM profile has AmazonSSMManagedInstanceCore."
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
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1

SECTION="init"

# Rich error handler: prints what failed, then runs section-specific diagnostics
err_handler() {
  local rc=\$?
  local line=\$1
  local cmd=\$2
  echo ""
  echo "================================================================"
  echo "  PHASE 1 FAILED"
  echo "  Section  : \$SECTION"
  echo "  Line     : \$line"
  echo "  Command  : \$cmd"
  echo "  Exit code: \$rc"
  echo "================================================================"
  echo ""
  case "\$SECTION" in
    "iptables flush")
      echo "--- iptables filter table ---"
      iptables -L -n --line-numbers 2>&1 | head -50 || true
      echo "--- ip6tables filter table ---"
      ip6tables -L -n --line-numbers 2>&1 | head -20 || true
      echo "--- loaded kernel modules ---"
      lsmod | grep -E 'ip_tables|ip6_tables|xt_|nf_' 2>&1 || true
      ;;
    "containerd install"|"containerd config"|"containerd start"|"containerd socket")
      echo "--- containerd service status ---"
      systemctl status containerd --no-pager -l 2>&1 || true
      echo "--- journalctl containerd (last 40 lines) ---"
      journalctl -u containerd --no-pager -n 40 2>&1 || true
      echo "--- /etc/containerd/config.toml ---"
      cat /etc/containerd/config.toml 2>/dev/null || echo "(file missing)"
      ;;
    "apt update"|"kubeadm package install")
      echo "--- apt-get update output (verbose) ---"
      apt-get update 2>&1 || true
      echo "--- kubernetes sources.list entry ---"
      cat /etc/apt/sources.list.d/kubernetes.list 2>/dev/null || echo "(file missing)"
      echo "--- GPG keyring ---"
      ls -la /etc/apt/keyrings/ 2>&1 || true
      gpg --no-default-keyring \
          --keyring /etc/apt/keyrings/kubernetes-apt-keyring.gpg \
          --list-keys 2>&1 || echo "(keyring unreadable or missing)"
      echo "--- apt-cache policy kubelet ---"
      apt-cache policy kubelet 2>&1 || true
      ;;
    "GPG keyring")
      echo "--- curl exit to stdout (key fetch test) ---"
      curl -fsSL --max-time 10 https://pkgs.k8s.io/core:/stable:/v1.32/deb/Release.key | wc -c 2>&1 || echo "(curl failed — network issue?)"
      echo "--- existing keyring files ---"
      ls -la /etc/apt/keyrings/ 2>&1 || true
      ;;
    "kubeadm init")
      echo "--- kubeadm init log (/tmp/kubeadm-init.log) ---"
      cat /tmp/kubeadm-init.log 2>/dev/null || echo "(no init log)"
      echo "--- kubeadm preflight errors ---"
      kubeadm init phase preflight \
        --control-plane-endpoint=${K8S_IP}:6443 \
        --pod-network-cidr=10.0.0.0/16 \
        --skip-phases=addon/kube-proxy \
        --ignore-preflight-errors=NumCPU 2>&1 || true
      echo "--- journalctl kubelet (last 50 lines) ---"
      journalctl -u kubelet --no-pager -n 50 2>&1 || true
      echo "--- iptables filter chains ---"
      iptables -L -n 2>&1 | head -30 || true
      ;;
    "API server wait")
      echo "--- kubectl get nodes ---"
      kubectl get nodes 2>&1 || true
      echo "--- kube-apiserver pod logs ---"
      kubectl -n kube-system logs --tail=40 \
        \$(kubectl -n kube-system get pod -l component=kube-apiserver -o name 2>/dev/null | head -1) 2>/dev/null || true
      echo "--- journalctl kubelet (last 50 lines) ---"
      journalctl -u kubelet --no-pager -n 50 2>&1 || true
      ;;
  esac
  echo "================================================================"
  exit \$rc
}

trap 'err_handler \$LINENO "\$BASH_COMMAND"' ERR

SECTION="check existing cluster"
echo "=== check existing cluster health ==="
if KUBECONFIG=/root/.kube/config kubectl get nodes 2>/dev/null | grep -q " Ready"; then
  echo "Cluster already initialized and node is Ready — skipping reset and init"
  KUBECONFIG=/root/.kube/config kubectl get nodes
  exit 0
fi

SECTION="reset"
echo "=== reset any existing cluster ==="
kubeadm reset -f 2>/dev/null || true
rm -rf /etc/kubernetes /root/.kube /var/lib/etcd /var/lib/kubelet /etc/cni /opt/cni 2>/dev/null || true
apt-mark unhold kubelet kubeadm kubectl 2>/dev/null || true

echo "=== killing any lingering kube/etcd processes ==="
pkill -9 -f 'kube-apiserver|kube-controller|kube-scheduler|kubelet|etcd' 2>/dev/null || true
sleep 2

SECTION="iptables flush"
echo "=== flushing stale iptables/IPVS rules from prior CNI runs ==="
iptables -F && iptables -X && iptables -t nat -F && iptables -t nat -X \
  && iptables -t mangle -F && iptables -t mangle -X
ip6tables -F && ip6tables -X && ip6tables -t nat -F && ip6tables -t nat -X \
  && ip6tables -t mangle -F && ip6tables -t mangle -X || true
if ipvsadm -l &>/dev/null; then ipvsadm --clear; fi

SECTION="containerd install"
echo "=== containerd ==="
apt-get update -qq
apt-get install -y -qq apt-transport-https ca-certificates curl gpg containerd

SECTION="containerd config"
mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml
sed -i 's/SystemdCgroup = true/SystemdCgroup = false/' /etc/containerd/config.toml

SECTION="containerd start"
systemctl restart containerd && systemctl enable containerd

SECTION="containerd socket"
echo "Waiting for containerd socket..."
for i in \$(seq 1 15); do
  [ -S /run/containerd/containerd.sock ] && break
  sleep 2
done
[ -S /run/containerd/containerd.sock ] || { echo "ERROR: containerd socket never appeared after 30s" >&2; exit 1; }

SECTION="kernel settings"
echo "=== kernel settings ==="
modprobe br_netfilter overlay
cat > /etc/sysctl.d/99-k8s.conf << 'EOF'
net.bridge.bridge-nf-call-iptables=1
net.bridge.bridge-nf-call-ip6tables=1
net.ipv4.ip_forward=1
EOF
sysctl --system -q
swapoff -a && sed -i '/swap/d' /etc/fstab

SECTION="GPG keyring"
echo "=== kubeadm ==="
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.32/deb/Release.key \
  | gpg --batch --yes --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.32/deb/ /' \
  > /etc/apt/sources.list.d/kubernetes.list

SECTION="apt update"
apt-get update -qq

SECTION="kubeadm package install"
apt-get install -y -qq kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl

SECTION="helm install"
echo "=== helm ==="
DESIRED_VERSION=v3.21.1 curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

SECTION="kubeadm init"
echo "=== kubeadm init ==="
kubeadm init \
  --control-plane-endpoint=${K8S_IP}:6443 \
  --pod-network-cidr=10.0.0.0/16 \
  --skip-phases=addon/kube-proxy \
  --ignore-preflight-errors=NumCPU 2>&1 | tee /tmp/kubeadm-init.log
mkdir -p /root/.kube
cp /etc/kubernetes/admin.conf /root/.kube/config
sed -i "s|https://.*:6443|https://${K8S_IP}:6443|g" /root/.kube/config /etc/kubernetes/admin.conf

SECTION="API server wait"
echo "=== waiting for API server ==="
API_READY=false
for i in \$(seq 1 36); do
  kubectl get nodes 2>/dev/null && API_READY=true && break
  sleep 5
done
[[ "\$API_READY" == "false" ]] && { echo "ERROR: API server not ready after 180s" >&2; exit 1; }
echo "=== removing control-plane taint (best-effort — Phase 5 taint guard is the safety net) ==="
for i in \$(seq 1 24); do
  kubectl taint nodes --all node-role.kubernetes.io/control-plane- 2>/dev/null && break
  sleep 5
done
kubectl get nodes
REMOTE
}

write_phase2() { cat > /tmp/byoc_p2.sh << REMOTE
#!/bin/bash
set -euo pipefail
export KUBECONFIG=/root/.kube/config

SECTION="init"

err_handler() {
  local rc=\$?
  local line=\$1
  local cmd=\$2
  echo ""
  echo "================================================================"
  echo "  PHASE 2 FAILED"
  echo "  Section  : \$SECTION"
  echo "  Line     : \$line"
  echo "  Command  : \$cmd"
  echo "  Exit code: \$rc"
  echo "================================================================"
  echo ""
  case "\$SECTION" in
    "cilium helm repo")
      echo "--- helm repo list ---"
      helm repo list 2>&1 || true
      echo "--- network connectivity test ---"
      curl -fsSL --max-time 10 https://helm.cilium.io/index.yaml -o /dev/null && echo "helm.cilium.io reachable" || echo "helm.cilium.io unreachable"
      ;;
    "cilium install")
      echo "--- helm status cilium ---"
      helm status cilium -n kube-system 2>&1 || true
      echo "--- all pods in kube-system ---"
      kubectl get pods -n kube-system -o wide 2>&1 || true
      echo "--- cilium pod logs (last 50 lines) ---"
      kubectl logs -n kube-system -l k8s-app=cilium --tail=50 2>&1 || true
      echo "--- cilium pod events ---"
      kubectl describe pods -n kube-system -l k8s-app=cilium 2>&1 | grep -A 15 "Events:" | tail -30 || true
      ;;
    "node ready wait")
      echo "--- kubectl get nodes -o wide ---"
      kubectl get nodes -o wide 2>&1 || true
      echo "--- cilium pod status ---"
      kubectl get pods -n kube-system -l k8s-app=cilium -o wide 2>&1 || true
      echo "--- cilium pod logs (last 50 lines) ---"
      kubectl logs -n kube-system -l k8s-app=cilium --tail=50 2>&1 || true
      echo "--- node conditions ---"
      kubectl describe nodes 2>&1 | grep -A 10 "Conditions:" | head -40 || true
      ;;
  esac
  echo "================================================================"
  exit \$rc
}

trap 'err_handler \$LINENO "\$BASH_COMMAND"' ERR

SECTION="cilium helm repo"
echo "=== adding cilium helm repo ==="
helm repo add cilium https://helm.cilium.io/ --force-update 2>/dev/null || helm repo update

SECTION="cilium install"
echo "=== installing cilium v1.17.4 ==="
helm upgrade --install cilium cilium/cilium \
  --version 1.17.4 \
  --namespace kube-system \
  --set k8sServiceHost=${K8S_IP} \
  --set k8sServicePort=6443 \
  --wait --timeout=10m

SECTION="node ready wait"
echo "=== waiting for node Ready ==="
kubectl wait node --all --for=condition=Ready --timeout=600s
kubectl get nodes
REMOTE
}

write_phase3() { cat > /tmp/byoc_p3.sh << REMOTE
#!/bin/bash
set -euo pipefail
export KUBECONFIG=/root/.kube/config

SECTION="init"

err_handler() {
  local rc=\$?
  local line=\$1
  local cmd=\$2
  echo ""
  echo "================================================================"
  echo "  PHASE 3 FAILED"
  echo "  Section  : \$SECTION"
  echo "  Line     : \$line"
  echo "  Command  : \$cmd"
  echo "  Exit code: \$rc"
  echo "================================================================"
  echo ""
  case "\$SECTION" in
    "local-path-provisioner")
      echo "--- pods in local-path-storage ---"
      kubectl get pods -n local-path-storage -o wide 2>&1 || true
      echo "--- storage classes ---"
      kubectl get storageclass 2>&1 || true
      echo "--- local-path-provisioner events ---"
      kubectl get events -n local-path-storage --field-selector type=Warning 2>&1 | tail -20 || true
      echo "--- describe provisioner pod ---"
      kubectl describe pods -n local-path-storage 2>&1 | grep -A 15 "Events:" | tail -30 || true
      ;;
    "seaweedfs install"|"seaweedfs rollout")
      echo "--- helm status seaweedfs ---"
      helm status seaweedfs -n seaweedfs 2>&1 || true
      echo "--- all pods in seaweedfs namespace ---"
      kubectl get pods -n seaweedfs -o wide 2>&1 || true
      echo "--- PVCs in seaweedfs ---"
      kubectl get pvc -n seaweedfs 2>&1 || true
      echo "--- warning events in seaweedfs ---"
      kubectl get events -n seaweedfs --field-selector type=Warning 2>&1 | tail -20 || true
      echo "--- describe failing pods ---"
      for pod in \$(kubectl get pods -n seaweedfs --no-headers 2>/dev/null | awk '\$3!="Running" && \$3!="Completed"{print \$1}'); do
        echo "  -- \$pod --"
        kubectl describe pod "\$pod" -n seaweedfs 2>&1 | grep -A 15 "Events:" | tail -20 || true
      done
      ;;
    "bucket and user")
      echo "--- seaweedfs-master-0 readiness ---"
      kubectl get pod seaweedfs-master-0 -n seaweedfs -o wide 2>&1 || true
      echo "--- seaweedfs-master-0 logs (last 40 lines) ---"
      kubectl logs seaweedfs-master-0 -n seaweedfs --tail=40 2>&1 || true
      echo "--- weed shell connectivity test ---"
      kubectl exec -n seaweedfs seaweedfs-master-0 -- weed shell -master=localhost:9333 -run="version" 2>&1 || true
      ;;
    "secrets")
      echo "--- namespace status ---"
      kubectl get ns ${NAMESPACE} 2>&1 || true
      echo "--- existing secrets in ${NAMESPACE} ---"
      kubectl get secrets -n ${NAMESPACE} 2>&1 || true
      ;;
  esac
  echo "================================================================"
  exit \$rc
}

trap 'err_handler \$LINENO "\$BASH_COMMAND"' ERR

SECTION="local-path-provisioner"
echo "=== local-path-provisioner ==="
kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.31/deploy/local-path-storage.yaml
kubectl patch storageclass local-path \
  -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
kubectl -n local-path-storage rollout status deploy/local-path-provisioner --timeout=60s

SECTION="seaweedfs install"
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

SECTION="seaweedfs rollout"
kubectl rollout status statefulset/seaweedfs-master -n seaweedfs --timeout=600s
kubectl rollout status statefulset/seaweedfs-filer  -n seaweedfs --timeout=600s
kubectl rollout status statefulset/seaweedfs-volume -n seaweedfs --timeout=600s

SECTION="bucket and user"
echo "=== bucket + user ==="
kubectl exec -n seaweedfs seaweedfs-master-0 -- sh -c "
  echo 's3.bucket.create -name ${BUCKET}' | weed shell -master=localhost:9333
  echo 's3.configure -access_key=${S3_KEY} -secret_key=${S3_SECRET} -user=${BUCKET} -actions=Read,Write,List,Tagging -buckets=${BUCKET} -apply' | weed shell -master=localhost:9333
" 2>&1

SECTION="secrets"
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
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1

SECTION="init"

err_handler() {
  local rc=\$?
  local line=\$1
  local cmd=\$2
  echo ""
  echo "================================================================"
  echo "  PHASE 4 FAILED  (PostgreSQL node)"
  echo "  Section  : \$SECTION"
  echo "  Line     : \$line"
  echo "  Command  : \$cmd"
  echo "  Exit code: \$rc"
  echo "================================================================"
  echo ""
  case "\$SECTION" in
    "postgres install")
      echo "--- apt-get update verbose ---"
      apt-get update 2>&1 | tail -20 || true
      echo "--- apt-cache policy postgresql-14 ---"
      apt-cache policy postgresql-14 2>&1 || true
      ;;
    "postgres start")
      echo "--- postgresql service status ---"
      systemctl status postgresql --no-pager -l 2>&1 || true
      echo "--- journalctl postgresql (last 40 lines) ---"
      journalctl -u postgresql --no-pager -n 40 2>&1 || true
      echo "--- pg_lsclusters ---"
      pg_lsclusters 2>&1 || true
      ;;
    "postgres readiness"|"postgres user/db"|"pg_hba config"|"postgres restart")
      echo "--- postgresql service status ---"
      systemctl status postgresql --no-pager -l 2>&1 || true
      echo "--- journalctl postgresql (last 40 lines) ---"
      journalctl -u postgresql --no-pager -n 40 2>&1 || true
      echo "--- pg_hba.conf ---"
      find /etc/postgresql -name pg_hba.conf -exec cat {} \; 2>/dev/null || echo "(not found)"
      echo "--- postgresql.conf listen_addresses ---"
      find /etc/postgresql -name postgresql.conf -exec grep -H listen_addresses {} \; 2>/dev/null || echo "(not found)"
      echo "--- pg_lsclusters ---"
      pg_lsclusters 2>&1 || true
      ;;
  esac
  echo "================================================================"
  exit \$rc
}

trap 'err_handler \$LINENO "\$BASH_COMMAND"' ERR

SECTION="postgres install"
apt-get update -qq && apt-get install -y -qq postgresql-14

SECTION="postgres start"
systemctl enable postgresql && systemctl start postgresql

SECTION="postgres readiness"
sudo -u postgres psql -c "SELECT 1" > /dev/null 2>&1 || { echo "ERROR: PostgreSQL not accepting connections" >&2; exit 1; }

SECTION="postgres user/db"
sudo -u postgres psql -c "CREATE USER ${PG_USER} WITH ENCRYPTED PASSWORD '${PG_PASS}';" 2>/dev/null || true
sudo -u postgres psql -c "CREATE DATABASE ${PG_USER};" 2>/dev/null || true
sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE ${PG_USER} TO ${PG_USER};"
sudo -u postgres psql -c "ALTER DATABASE ${PG_USER} OWNER TO ${PG_USER};"

SECTION="pg_hba config"
PG_CONF=\$(find /etc/postgresql -name postgresql.conf | head -1)
PG_HBA=\$(find /etc/postgresql -name pg_hba.conf | head -1)
sed -i "s/#listen_addresses = 'localhost'/listen_addresses = '*'/" "\$PG_CONF"
grep -q "10.0.0.0" "\$PG_HBA" || \
  echo "host  ${PG_USER}  ${PG_USER}  10.0.0.0/8  md5" >> "\$PG_HBA"
grep -q "172.16.0.0" "\$PG_HBA" || \
  echo "host  ${PG_USER}  ${PG_USER}  172.16.0.0/12  md5" >> "\$PG_HBA"
grep -q "192.168.0.0" "\$PG_HBA" || \
  echo "host  ${PG_USER}  ${PG_USER}  192.168.0.0/16  md5" >> "\$PG_HBA"

SECTION="postgres restart"
systemctl restart postgresql
for i in \$(seq 1 20); do
  systemctl is-active postgresql && break
  sleep 3
done
systemctl is-active postgresql
echo "PostgreSQL ready at ${PG_IP}:5432"
REMOTE
}

write_phase4b() { cat > /tmp/byoc_p4b.sh << REMOTE
#!/bin/bash
set -euo pipefail
export KUBECONFIG=/root/.kube/config

SECTION="init"

err_handler() {
  local rc=\$?
  local line=\$1
  local cmd=\$2
  echo ""
  echo "================================================================"
  echo "  PHASE 4b FAILED  (k8s secrets)"
  echo "  Section  : \$SECTION"
  echo "  Line     : \$line"
  echo "  Command  : \$cmd"
  echo "  Exit code: \$rc"
  echo "================================================================"
  echo ""
  echo "--- namespace status ---"
  kubectl get ns ${NAMESPACE} 2>&1 || echo "namespace ${NAMESPACE} does not exist"
  echo "--- existing secrets in ${NAMESPACE} ---"
  kubectl get secrets -n ${NAMESPACE} 2>&1 || true
  echo "--- kubectl api-server reachability ---"
  kubectl cluster-info 2>&1 || true
  echo "================================================================"
  exit \$rc
}

trap 'err_handler \$LINENO "\$BASH_COMMAND"' ERR

SECTION="namespace"
kubectl create ns ${NAMESPACE} 2>/dev/null || true

SECTION="metastore secret"
kubectl delete secret byoc-logs-metastore-uri -n ${NAMESPACE} 2>/dev/null || true
kubectl create secret generic byoc-logs-metastore-uri \
  --from-literal QW_METASTORE_URI="postgres://${PG_USER}:${PG_PASS}@${PG_IP}:5432/${PG_USER}?sslmode=disable" \
  -n ${NAMESPACE}

SECTION="minio credentials secret"
kubectl delete secret byoc-logs-minio-credentials -n ${NAMESPACE} 2>/dev/null || true
kubectl create secret generic byoc-logs-minio-credentials \
  --from-literal AWS_ACCESS_KEY_ID="${S3_KEY}" \
  --from-literal AWS_SECRET_ACCESS_KEY="${S3_SECRET}" \
  -n ${NAMESPACE}
echo "Secrets created."
REMOTE
}

write_taint_guard() { cat > /tmp/byoc_taint.sh << REMOTE
#!/bin/bash
export KUBECONFIG=/root/.kube/config
if kubectl get nodes -o jsonpath='{.items[*].spec.taints[*].key}' 2>/dev/null \
    | grep -q 'node-role.kubernetes.io/control-plane'; then
  kubectl taint nodes --all node-role.kubernetes.io/control-plane- 2>/dev/null || true
  echo "Taint removed."
else
  echo "No control-plane taint present."
fi
echo "TAINT_OK"
REMOTE
}

write_phase5() { cat > /tmp/byoc_p5.sh << REMOTE
#!/bin/bash
set -euo pipefail
export KUBECONFIG=/root/.kube/config

SECTION="init"

err_handler() {
  local rc=\$?
  local line=\$1
  local cmd=\$2
  echo ""
  echo "================================================================"
  echo "  PHASE 5 FAILED  (CloudPrem)"
  echo "  Section  : \$SECTION"
  echo "  Line     : \$line"
  echo "  Command  : \$cmd"
  echo "  Exit code: \$rc"
  echo "================================================================"
  echo ""
  case "\$SECTION" in
    "API key validation")
      echo "--- curl verbose to api.${DD_SITE} ---"
      curl -v --max-time 15 \
        -H "DD-API-KEY: \$DD_API_KEY_CLEAN" \
        "https://api.${DD_SITE}/api/v1/validate" 2>&1 || true
      ;;
    "datadog secret"|"helm repo")
      echo "--- existing secrets in ${NAMESPACE} ---"
      kubectl get secrets -n ${NAMESPACE} 2>&1 || true
      echo "--- helm repo list ---"
      helm repo list 2>&1 || true
      ;;
    "cloudprem helm install")
      echo "--- helm status ${NAMESPACE} ---"
      helm status ${NAMESPACE} -n ${NAMESPACE} 2>&1 || true
      echo "--- all pods in ${NAMESPACE} ---"
      kubectl get pods -n ${NAMESPACE} -o wide 2>&1 || true
      echo "--- PVCs in ${NAMESPACE} ---"
      kubectl get pvc -n ${NAMESPACE} 2>&1 || true
      echo "--- warning events in ${NAMESPACE} ---"
      kubectl get events -n ${NAMESPACE} --field-selector type=Warning 2>&1 | tail -20 || true
      ;;
    "pod ready wait")
      echo "--- all pods in ${NAMESPACE} ---"
      kubectl get pods -n ${NAMESPACE} -o wide 2>&1 || true
      echo "--- PVCs in ${NAMESPACE} ---"
      kubectl get pvc -n ${NAMESPACE} 2>&1 || true
      echo "--- warning events in ${NAMESPACE} ---"
      kubectl get events -n ${NAMESPACE} --field-selector type=Warning 2>&1 | tail -30 || true
      echo "--- describe non-Running pods ---"
      for pod in \$(kubectl get pods -n ${NAMESPACE} --no-headers 2>/dev/null | awk '\$3!="Running" && \$3!="Completed"{print \$1}'); do
        echo "  -- \$pod --"
        kubectl describe pod "\$pod" -n ${NAMESPACE} 2>&1 | grep -A 20 "Events:" | tail -25 || true
        echo "  -- \$pod logs (last 30 lines) --"
        kubectl logs "\$pod" -n ${NAMESPACE} --tail=30 2>&1 || true
      done
      echo "--- SeaweedFS S3 reachability from cluster ---"
      kubectl run --rm -i --restart=Never --image=curlimages/curl:latest curl-test-\$\$ \
        -n ${NAMESPACE} -- curl -fsSL --max-time 10 http://seaweedfs-s3.seaweedfs.svc.cluster.local:8333/ 2>&1 || true
      ;;
  esac
  echo "================================================================"
  exit \$rc
}

trap 'err_handler \$LINENO "\$BASH_COMMAND"' ERR

SECTION="API key validation"
DD_API_KEY_CLEAN="${DD_API_KEY}"
if [[ ! "\$DD_API_KEY_CLEAN" =~ ^[0-9a-fA-F]{32}\$ ]]; then
  echo "ERROR: DD_API_KEY does not look like a valid 32-char hex Datadog API key" >&2
  echo "ERROR: Got: '\$DD_API_KEY_CLEAN' (len=\${#DD_API_KEY_CLEAN})" >&2
  exit 1
fi
echo "=== validating API key against Datadog ==="
HTTP_CODE=\$(curl -s -o /dev/null -w "%{http_code}" \
  --max-time 15 --connect-timeout 10 \
  -H "DD-API-KEY: \$DD_API_KEY_CLEAN" \
  "https://api.${DD_SITE}/api/v1/validate")
if [[ "\$HTTP_CODE" != "200" ]]; then
  echo "ERROR: Datadog API key validation failed (HTTP \$HTTP_CODE)" >&2
  echo "ERROR: Check your key at https://app.datadoghq.com/organization-settings/api-keys" >&2
  exit 1
fi
echo "=== API key valid (HTTP 200) ==="

SECTION="datadog secret"
kubectl delete secret datadog-secret -n ${NAMESPACE} 2>/dev/null || true
kubectl create secret generic datadog-secret \
  --from-literal api-key="\$DD_API_KEY_CLEAN" -n ${NAMESPACE}

SECTION="helm repo"
helm repo add datadog https://helm.datadoghq.com --force-update 2>/dev/null || helm repo update

SECTION="cloudprem helm install"
cat > /tmp/ddvals.yaml << 'EOF'
datadog:
  site: ${DD_SITE}
  apiKeyExistingSecret: datadog-secret
  clusterName: ${CLUSTER_NAME}
serviceAccount:
  create: true
  name: ${NAMESPACE}
config:
  default_index_root_uri: s3://${BUCKET}/indexes
  storage:
    s3:
      endpoint: http://seaweedfs-s3.seaweedfs.svc.cluster.local:8333
      force_path_style_access: true
      region: us-east-1
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
echo "=== deploying cloudprem helm chart ==="
helm upgrade --install ${NAMESPACE} datadog/cloudprem -f /tmp/ddvals.yaml -n ${NAMESPACE}

SECTION="pod ready wait"
echo "=== waiting for all pods Ready (up to 20 min) ==="
kubectl wait --for=condition=Ready pod \
  -l app.kubernetes.io/instance=${NAMESPACE} \
  -n ${NAMESPACE} --timeout=1200s
echo "=== pod status ==="
kubectl get pods -n ${NAMESPACE}
echo "=== restarting searcher to pick up new datadog-secret ==="
kubectl rollout restart statefulset/${NAMESPACE}-cloudprem-searcher -n ${NAMESPACE} 2>/dev/null || true
kubectl rollout status statefulset/${NAMESPACE}-cloudprem-searcher -n ${NAMESPACE} --timeout=300s 2>/dev/null || true
REMOTE
}

write_phase6() { cat > /tmp/byoc_p6.sh << REMOTE
#!/bin/bash
set -euo pipefail
export KUBECONFIG=/root/.kube/config

SECTION="init"

err_handler() {
  local rc=\$?
  local line=\$1
  local cmd=\$2
  echo ""
  echo "================================================================"
  echo "  PHASE 6 FAILED  (Datadog Operator + Agent)"
  echo "  Section  : \$SECTION"
  echo "  Line     : \$line"
  echo "  Command  : \$cmd"
  echo "  Exit code: \$rc"
  echo "================================================================"
  echo ""
  case "\$SECTION" in
    "operator helm install")
      echo "--- helm status datadog-operator ---"
      helm status datadog-operator -n ${NAMESPACE} 2>&1 || true
      echo "--- operator pods ---"
      kubectl get pods -n ${NAMESPACE} -l app.kubernetes.io/name=datadog-operator -o wide 2>&1 || true
      echo "--- operator pod logs (last 40 lines) ---"
      kubectl logs -n ${NAMESPACE} -l app.kubernetes.io/name=datadog-operator --tail=40 2>&1 || true
      echo "--- warning events in ${NAMESPACE} ---"
      kubectl get events -n ${NAMESPACE} --field-selector type=Warning 2>&1 | tail -20 || true
      ;;
    "DDA apply")
      echo "--- /tmp/dda.yaml contents ---"
      cat /tmp/dda.yaml 2>/dev/null || echo "(file missing)"
      echo "--- kubectl api-resources (check CRD exists) ---"
      kubectl api-resources | grep -i datadogagent 2>&1 || echo "(DatadogAgent CRD not found)"
      echo "--- operator logs (last 40 lines) ---"
      kubectl logs -n ${NAMESPACE} -l app.kubernetes.io/name=datadog-operator --tail=40 2>&1 || true
      ;;
    "cluster-agent wait")
      echo "--- datadogagent resource status ---"
      kubectl describe datadogagent datadog -n ${NAMESPACE} 2>&1 | tail -40 || true
      echo "--- operator logs (last 50 lines) ---"
      kubectl logs -n ${NAMESPACE} -l app.kubernetes.io/name=datadog-operator --tail=50 2>&1 || true
      echo "--- all pods in ${NAMESPACE} ---"
      kubectl get pods -n ${NAMESPACE} -o wide 2>&1 || true
      echo "--- warning events ---"
      kubectl get events -n ${NAMESPACE} --field-selector type=Warning 2>&1 | tail -20 || true
      ;;
    "agent daemonset wait")
      echo "--- daemonset status ---"
      kubectl get daemonset datadog-agent -n ${NAMESPACE} 2>&1 || true
      echo "--- agent pod status ---"
      kubectl get pods -n ${NAMESPACE} -l agent.datadoghq.com/component=agent -o wide 2>&1 || true
      echo "--- agent pod logs (last 40 lines) ---"
      kubectl logs -n ${NAMESPACE} -l agent.datadoghq.com/component=agent --tail=40 2>&1 || true
      echo "--- warning events ---"
      kubectl get events -n ${NAMESPACE} --field-selector type=Warning 2>&1 | tail -20 || true
      ;;
  esac
  echo "================================================================"
  exit \$rc
}

trap 'err_handler \$LINENO "\$BASH_COMMAND"' ERR

SECTION="operator helm install"
echo "=== installing datadog operator ==="
helm upgrade --install datadog-operator datadog/datadog-operator -n ${NAMESPACE} --wait --timeout=5m

SECTION="DDA apply"
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

SECTION="cluster-agent wait"
echo "=== waiting for operator to create cluster-agent deployment (up to 10 min) ==="
FOUND=false
for i in \$(seq 1 120); do
  if kubectl get deployment/datadog-cluster-agent -n ${NAMESPACE} &>/dev/null; then
    FOUND=true
    break
  fi
  [[ \$((i % 6)) -eq 0 ]] && echo "  still waiting for cluster-agent... (\$((i * 5))s elapsed)"
  sleep 5
done
if [[ "\$FOUND" == "false" ]]; then
  echo "WARNING: cluster-agent deployment not yet created after 10 min — operator may still be reconciling"
  echo "=== operator pod status ==="
  kubectl get pods -n ${NAMESPACE} -l app.kubernetes.io/name=datadog-operator 2>/dev/null || true
  echo "=== datadogagent status ==="
  kubectl get datadogagent -n ${NAMESPACE} 2>/dev/null || true
  echo "PHASE6_PARTIAL"
else
  kubectl wait deployment/datadog-cluster-agent -n ${NAMESPACE} \
    --for=condition=Available --timeout=600s 2>/dev/null \
    || echo "WARNING: cluster-agent not Available within 10 min — it may still be pulling images"
  SECTION="agent daemonset wait"
  kubectl rollout status daemonset/datadog-agent -n ${NAMESPACE} --timeout=600s 2>/dev/null \
    || echo "WARNING: agent daemonset rollout incomplete — it may still be pulling images"
fi
echo "=== pod status ==="
kubectl get pods -n ${NAMESPACE}
echo "PHASE6_DONE"
REMOTE
}

write_phase7() { cat > /tmp/byoc_p7.sh << REMOTE
#!/bin/bash
set -euo pipefail
export KUBECONFIG=/root/.kube/config

SECTION="init"

err_handler() {
  local rc=\$?
  local line=\$1
  local cmd=\$2
  echo ""
  echo "================================================================"
  echo "  PHASE 7 FAILED  (reverse connection check)"
  echo "  Section  : \$SECTION"
  echo "  Line     : \$line"
  echo "  Command  : \$cmd"
  echo "  Exit code: \$rc"
  echo "================================================================"
  echo ""
  echo "--- all pods in ${NAMESPACE} ---"
  kubectl get pods -n ${NAMESPACE} -o wide 2>&1 || true
  echo "--- control plane pod logs (last 30 lines) ---"
  kubectl logs -n ${NAMESPACE} -l app.kubernetes.io/component=control-plane --tail=30 2>&1 || true
  echo "--- searcher pod logs (last 30 lines) ---"
  kubectl logs -n ${NAMESPACE} -l app.kubernetes.io/component=searcher --tail=30 2>&1 || true
  echo "--- warning events in ${NAMESPACE} ---"
  kubectl get events -n ${NAMESPACE} --field-selector type=Warning 2>&1 | tail -20 || true
  echo "================================================================"
  exit \$rc
}

trap 'err_handler \$LINENO "\$BASH_COMMAND"' ERR

SECTION="searcher pod wait"
echo "=== waiting for searcher pod to be Running ==="
SEARCHER_POD=""
for i in \$(seq 1 30); do
  SEARCHER_POD=\$(kubectl get pods -n ${NAMESPACE} --no-headers 2>/dev/null \
    | awk '/searcher.*Running/{print \$1}' | head -1)
  [[ -n "\$SEARCHER_POD" ]] && break
  sleep 5
done
if [[ -z "\$SEARCHER_POD" ]]; then
  echo "ERROR: searcher pod not Running after 150s" >&2
  echo "--- pod status ---"
  kubectl get pods -n ${NAMESPACE} 2>/dev/null || true
  echo "--- describe searcher pod ---"
  kubectl describe pods -n ${NAMESPACE} -l app.kubernetes.io/component=searcher 2>&1 | grep -A 15 "Events:" | tail -20 || true
  exit 1
fi
echo "Found: \$SEARCHER_POD"

SECTION="reverse connection poll"
echo "=== polling searcher logs for reverse connection ==="
CONNECTED=false
for i in \$(seq 1 60); do
  LOGS=\$(kubectl logs "\$SEARCHER_POD" -n ${NAMESPACE} --tail=200 2>/dev/null || true)
  UID_LINE=\$(echo "\$LOGS"  | grep "fetched cluster remote uid"        | tail -1 || true)
  INIT_LINE=\$(echo "\$LOGS" | grep "initiating new reverse connection" | tail -1 || true)
  AUTH_ERR=\$(echo "\$LOGS"  | grep "invalid authentication parameters" | tail -1 || true)
  if [[ -n "\$UID_LINE" && -n "\$INIT_LINE" && -z "\$AUTH_ERR" ]]; then
    echo "CONNECTION_SEEN"
    echo "\$UID_LINE"
    echo "\$INIT_LINE"
    CONNECTED=true
    break
  elif [[ -n "\$AUTH_ERR" ]]; then
    echo "AUTH_ERROR: invalid authentication parameters — check API key"
    echo "\$AUTH_ERR"
    break
  fi
  [[ \$((i % 6)) -eq 0 ]] && echo "  waiting for reverse WebSocket... (\$((i * 5))s elapsed)"
  sleep 5
done
if [[ "\$CONNECTED" == "false" ]]; then
  echo "TIMEOUT: no confirmed connection after 5 minutes"
  echo "=== last 50 searcher log lines ==="
  kubectl logs "\$SEARCHER_POD" -n ${NAMESPACE} --tail=50 2>/dev/null || true
  echo "=== control plane logs (last 50 lines) ==="
  kubectl logs -n ${NAMESPACE} -l app.kubernetes.io/component=control-plane --tail=50 2>/dev/null || true
  echo "NOTE: if the feature flag logs-cloudprem is not enabled, no connection attempt will appear at all"
fi
REMOTE
}

# ── Final Dashboard ───────────────────────────────────────────────────────────
print_dashboard() {
  echo ""
  echo -e "${GREEN}${BOLD}"
  echo "  ╔════════════════════════════════════════════════════════════════╗"
  echo "  ║                                                                ║"
  echo "  ║   🎉  BYOC CloudPrem Lab is Live                               ║"
  echo "  ║                                                                ║"
  echo "  ╚════════════════════════════════════════════════════════════════╝"
  echo -e "${NC}"

  echo -e "  ${YELLOW}${BOLD}  Required: Enable the logs-cloudprem feature flag${NC}"
  echo -e "  ${YELLOW}  The reverse connection will not activate until this is on.${NC}"
  echo -e "  ${YELLOW}  Ask your Datadog contact (or Mosaic admin) to enable it at:${NC}"
  echo -e "  ${CYAN}  https://mosaic.us1.ddbuild.io/feature-flags/logs-cloudprem${NC}"
  echo -e "  ${YELLOW}  Org: ${WHITE}${DD_SITE}${YELLOW}  API key prefix: ${WHITE}${DD_API_KEY:0:8}...${NC}"
  echo ""

  echo -e "  ${WHITE}${BOLD}Verify in Datadog:${NC}"
  echo ""
  local expected_name="${NAMESPACE}-${NAMESPACE}-${CLUSTER_NAME}"
  printf "  ${CYAN}1.${NC}  %-55s\n" "https://app.${DD_SITE}/byoc-logs"
  printf "      ${DIM}%-55s${NC}\n" "→ Look for cluster: ${expected_name}"
  printf "      ${DIM}%-55s${NC}\n" "  (may show as ${expected_name}-XXXXXXXX if the name"
  printf "      ${DIM}%-55s${NC}\n" "   already existed in your org — that is your cluster)"
  echo ""
  printf "  ${CYAN}2.${NC}  %-55s\n" "Hover cluster → Search Logs"
  printf "      ${DIM}%-55s${NC}\n" "→ Pod logs appear within ~2 minutes"
  echo ""
  printf "  ${CYAN}3.${NC}  %-55s\n" "https://app.${DD_SITE}/metric/summary?filter=cloudprem"
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
  echo -e "  ${DIM}Note: If SSM commands fail with an auth error, re-run: aws sso login --profile ${PROFILE}${NC}"
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

# Load last-used instance IDs so pick_instance can highlight them
LAST_K8S_INSTANCE="" LAST_PG_INSTANCE=""
if [[ -f "$GLOBAL_LAST" ]]; then
  source "$GLOBAL_LAST" 2>/dev/null || true
  LAST_K8S_INSTANCE="${K8S_INSTANCE:-}"
  LAST_PG_INSTANCE="${PG_INSTANCE:-}"
  unset K8S_INSTANCE PG_INSTANCE 2>/dev/null || true
fi

ask "AWS profile"                             "byoc"          PROFILE
ask "AWS region (e.g. us-east-1, us-west-1)"  "us-east-1"     REGION

info "Validating credentials..."
validate_creds
echo ""

info "Fetching available SSM instances..."
pick_instance "Kubernetes node" K8S_INSTANCE k8s
echo ""

# Re-key checkpoint dir now that K8S_INSTANCE is known
CKPT_DIR="/tmp/.byoc_ckpt_${K8S_INSTANCE}"
mkdir -p "$CKPT_DIR"

# ── Resume detection ──────────────────────────────────────────────────────────
RESUMING=0
if [[ -f "$CKPT_DIR/config.env" ]]; then
  echo ""
  echo -e "  ${GREEN}${BOLD}  ↩  Saved config found for $K8S_INSTANCE${NC}"
  echo -e "  ${DIM}  Loading previous session — skipping configuration questions.${NC}"
  echo -e "  ${DIM}  To start fresh: rm -rf /tmp/.byoc_ckpt_${K8S_INSTANCE} then re-run.${NC}"
  echo ""
  source "$CKPT_DIR/config.env"
  RESUMING=1

  info "Verifying instances are still reachable via SSM..."
  validate_instance "$K8S_INSTANCE" "Kubernetes"
  validate_instance "$PG_INSTANCE"  "PostgreSQL"
  success "Both instances reachable."
  echo ""
else
  pick_instance "PostgreSQL node" PG_INSTANCE postgres
  [[ "$K8S_INSTANCE" == "$PG_INSTANCE" ]] && \
    abort "K8S and PostgreSQL instances must be different — you selected the same instance for both."

  echo ""
  info "Verifying both instances are online in SSM..."
  validate_instance "$K8S_INSTANCE" "Kubernetes"
  validate_instance "$PG_INSTANCE"  "PostgreSQL"
  success "Both instances reachable."
  echo ""

  ask "Datadog site"                            "datadoghq.com" DD_SITE
  case "$DD_SITE" in
    datadoghq.com|datadoghq.eu|us3.datadoghq.com|us5.datadoghq.com|ap1.datadoghq.com|ddog-gov.com) ;;
    *) warn "Unrecognized Datadog site '${DD_SITE}' — double-check before continuing." ;;
  esac
  echo ""
  deploy_id=$(LC_ALL=C tr -dc 'a-f0-9' < /dev/urandom | head -c 6)
  echo -e "  ${DIM}The next two values determine your Datadog cluster identifier:${NC}"
  echo -e "  ${DIM}  <namespace>-<namespace>-<cluster-name>${NC}"
  echo -e "  ${DIM}  This is how the cluster appears in app.datadoghq.com/byoc-logs${NC}"
  echo ""
  ask "Cluster name in Datadog"                 "cloudprem-${deploy_id}"     CLUSTER_NAME
  ask "Kubernetes namespace"                    "byoclogs"      NAMESPACE
  ask "S3 bucket name"                          "byoclogs"      BUCKET
  ask "PostgreSQL database / user"              "byoclogs"      PG_USER
  ask "PostgreSQL password"                     "byoclogs"      PG_PASS
  ask_secret "Please supply your Datadog API key"               DD_API_KEY
  DD_API_KEY=$(echo -n "${DD_API_KEY}" | tr -dc '0-9a-fA-F')
  [[ ${#DD_API_KEY} -eq 32 ]] \
    || abort "Datadog API key must be exactly 32 hex characters (got ${#DD_API_KEY} after stripping non-hex chars). Check the key and try again."

  echo ""
  info "Resolving instance IPs..."
  K8S_IP=$(get_private_ip "$K8S_INSTANCE") || abort "Could not resolve IP for $K8S_INSTANCE"
  [[ "$K8S_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || abort "IP lookup returned '${K8S_IP}' for ${K8S_INSTANCE} — check instance ID and region."
  PG_IP=$(get_private_ip "$PG_INSTANCE")   || abort "Could not resolve IP for $PG_INSTANCE"
  [[ "$PG_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || abort "IP lookup returned '${PG_IP}' for ${PG_INSTANCE} — check instance ID and region."

  S3_KEY=$(openssl rand -hex 10)
  S3_SECRET=$(openssl rand -hex 20)
fi

save_config

print_config
arch_diagram "k8s"

echo -e "  ${YELLOW}  This will take approximately 15–20 minutes total.${NC}"
echo -e "  ${YELLOW}  PostgreSQL (Phase 4) runs in parallel with storage (Phase 3).${NC}"
if [[ "${RESUMING:-0}" == "1" ]]; then
  echo -e "  ${YELLOW}  Resuming — completed phases will be skipped.${NC}"
fi
pause

# ── Phase 1: Kubernetes ───────────────────────────────────────────────────────
section "Phase 1 — Kubernetes (kubeadm)" "①"
explain "🚀 Welcome to Phase 1 — the foundation of everything!

Kubernetes is the operating system for your CloudPrem cluster.
kubeadm bootstraps a production-grade cluster in minutes:
  containerd  Container Runtime Interface (CRI)
  kubelet     Node agent — starts/stops pods, mounts volumes
  kubeadm     Generates TLS PKI, kubeconfig, etcd, API server

WHY PRIVATE IP?  We set --control-plane-endpoint to the EC2's
PRIVATE IP so the kubeconfig works inside the instance. SSM
runs inside — no hairpin NAT, no floating EIP needed.

WHY REMOVE THE TAINT?  By default, kubeadm marks the control-
plane node NoSchedule so workloads don't land on it. On a
single-node lab, that would leave every CloudPrem pod Pending
forever. We remove the taint — that's it, fully schedulable.

This phase is idempotent: 'kubeadm reset -f' runs first,
so resuming from a checkpoint is always safe. ✓"

if ckpt_done "phase1"; then
  success "Phase 1 already completed — skipping."
else
  validate_creds
  write_phase1
  spin_start "Bootstrapping Kubernetes  ${DIM}[${K8S_INSTANCE}]${NC}"
  elapsed=$(ssm_run "$K8S_INSTANCE" /tmp/byoc_p1.sh) || exit 1
  ckpt_set "phase1"
  phase_done "Kubernetes bootstrap" "$elapsed"
fi

echo ""
echo -e "  ${GREEN}Node is up. Cilium will bring it to Ready state.${NC}"

# ── Phase 2: Cilium ───────────────────────────────────────────────────────────
section "Phase 2 — Cilium CNI" "②"
arch_diagram "cilium"
explain "⚡ Phase 2 — the network fabric that makes pods talk!

Cilium is an eBPF-based CNI (Container Network Interface).
Instead of iptables, it injects programs directly into the
Linux kernel's networking subsystem — faster, more secure,
and fully observable with zero overhead.

WHAT IS eBPF?  A way to run sandboxed programs in the kernel
without patching kernel source or loading modules. Cilium uses
it to implement pod networking, DNS, and kube-proxy — all at
wire speed with per-flow visibility.

THE BARE-METAL GOTCHA:  On cloud Kubernetes (EKS, GKE), the
cluster service IP (10.96.0.1) is reachable during CNI boot.
On bare metal, it's NOT — because Cilium itself provides it.
Bootstrap deadlock. We break the cycle by passing:
  --set k8sServiceHost=<private_ip>
  --set k8sServicePort=6443
This tells Cilium's init container to talk directly to the
API server, bypassing the ClusterIP it hasn't created yet.

Once this phase completes, the node flips to Ready. 🟢"

if ckpt_done "phase2"; then
  success "Phase 2 already completed — skipping."
else
  write_phase2
  spin_start "Installing Cilium and waiting for node Ready  ${DIM}[${K8S_INSTANCE}]${NC}"
  elapsed=$(ssm_run "$K8S_INSTANCE" /tmp/byoc_p2.sh) || exit 1
  ckpt_set "phase2"
  phase_done "Cilium CNI" "$elapsed"
fi

echo ""
echo -e "  ${GREEN}Node is Ready. Next: storage layer + PostgreSQL (parallel, ~5 min).${NC}"

# ── Phase 3+4 (parallel): Storage + PostgreSQL ────────────────────────────────
section "Phase 3 — Storage  ·  Phase 4 — PostgreSQL  (parallel)" "③④"
arch_diagram "storage"
explain "💾 Phases 3 + 4 — storage layer, running in PARALLEL!

These two phases run concurrently to save ~3 minutes. Each
targets a different EC2 instance, so there's zero contention.

━━━ PHASE 3: Local Storage + SeaweedFS (on k8s node) ━━━
  local-path-provisioner  Creates PVCs as host directories —
                          no cloud provider needed, no Longhorn
                          (which has a deadlock bug on k8s 1.32+)

  SeaweedFS  A self-hosted S3-compatible object store. CloudPrem
             stores its indexed log data here as Parquet 'splits'
             — the same format it would use with AWS S3, Azure Blob,
             Ceph, or NetApp in production. SeaweedFS replaced MinIO,
             which was archived in 2024.

━━━ PHASE 4: PostgreSQL 14 (on t3.micro) ━━━
  Every log segment written by the indexer is registered in a
  'split catalog' — a PostgreSQL table that tracks file path,
  time range, tags, and merge history. Without it, the searcher
  can't find anything. This is what we call the Metastore.

  GOTCHA: QuickWit (the engine inside CloudPrem) expects SSL on
  PostgreSQL by default. Our bare-metal instance has no certs.
  We append ?sslmode=disable to the connection URI. Done. ✓"

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
    spin_start "Installing local-path-provisioner + SeaweedFS  ${DIM}[${K8S_INSTANCE}]${NC}"
    STORAGE_ELAPSED=$(ssm_run "$K8S_INSTANCE" /tmp/byoc_p3.sh) || {
      [[ -n "${PG_PID:-}" ]] && kill "$PG_PID" 2>/dev/null; exit 1
    }
    ckpt_set "phase3"
    phase_done "Storage (local-path + SeaweedFS)" "$STORAGE_ELAPSED"
  fi

  # Wait for PostgreSQL background job
  if [[ -n "$PG_PID" ]]; then
    spin_start "Installing PostgreSQL  ${DIM}[${PG_INSTANCE}]${NC}"
    local_t0=$SECONDS
    wait "$PG_PID" || true
    spin_stop
    local_rc=$(cat "${PG_OUT}.rc" 2>/dev/null | tail -1)
    PG_ELAPSED=$((SECONDS - local_t0))
    if [[ -z "$local_rc" || "$local_rc" != "0" ]]; then
      local pg_logfile="${CKPT_DIR}/error_byoc_p4_$(date +%H%M%S).log"
      cp "$PG_OUT" "$pg_logfile" 2>/dev/null || true
      if [[ -z "$local_rc" ]]; then
        echo -e "\n  ${RED}${BOLD} ✗  PostgreSQL installer process died unexpectedly${NC}\n"
      else
        echo -e "\n  ${RED}${BOLD} ✗  PostgreSQL install failed (exit ${local_rc})${NC}\n"
      fi
      echo -e "${DIM}  Last output:${NC}"
      tail -20 "$PG_OUT" | while IFS= read -r line; do
        echo -e "  ${DIM}${line}${NC}"
      done
      echo -e "\n  ${DIM}Full log: ${pg_logfile}${NC}\n"
      rm -f "$PG_OUT" "${PG_OUT}.rc"
      printf "${SHOW_CURSOR}"
      exit 1
    fi
    ckpt_set "phase4"
    phase_done "PostgreSQL" "$PG_ELAPSED"
    rm -f "$PG_OUT" "${PG_OUT}.rc"
  fi

fi

# Always ensure metastore URI secret is current before Phase 5 (idempotent)
if ! ckpt_done "phase5"; then
  write_phase4b
  spin_start "Ensuring k8s secrets are current  ${DIM}[${K8S_INSTANCE}]${NC}"
  ssm_run "$K8S_INSTANCE" /tmp/byoc_p4b.sh "Secrets created" > /dev/null
fi

echo ""
echo -e "  ${GREEN}Storage and PostgreSQL ready. Next: CloudPrem helm install (~3 min).${NC}"
echo -e "  ${DIM}  SeaweedFS S3 endpoint:  seaweedfs-s3.seaweedfs.svc.cluster.local:8333${NC}"
echo -e "  ${DIM}  PostgreSQL metastore:   ${PG_IP}:5432/${PG_USER}${NC}"

info "Verifying credentials before Phase 5..."
validate_creds
echo ""

# ── Phase 5: CloudPrem ────────────────────────────────────────────────────────
section "Phase 5 — CloudPrem" "⑤"
arch_diagram "cloudprem"
explain "🎯 Phase 5 — THIS is the product! Welcome to CloudPrem!

The CloudPrem helm chart deploys 5 microservices that form your
complete on-premises log management engine:

  indexer       The front door. Receives logs on port 7280,
                batches them into Parquet 'splits', and writes
                to SeaweedFS. High-throughput, append-only.

  searcher      The query engine. When you search logs in the
                Datadog UI, the query travels over the reverse
                WebSocket to this service. It reads splits from
                SeaweedFS, evaluates the query, and sends results
                back. Logs NEVER leave your cluster.

  metastore     The librarian. Registers every split written by
                the indexer into the PostgreSQL catalog. Tells
                the searcher where to find the right data.

  control-plane The diplomat. Holds the persistent outbound
                WebSocket connection to app.datadoghq.com — the
                key innovation of CloudPrem. SaaS can query your
                data without any inbound firewall rules. 🔑

  janitor       The custodian. Enforces retention policy by
                deleting expired splits from SeaweedFS and
                removing their records from the catalog.

Five services. One cluster. Zero log data leaving your network."

if ckpt_done "phase5"; then
  success "Phase 5 already completed — skipping."
else
  # Remove the control-plane taint — it can persist across checkpoint boundaries
  # and will leave all pods Pending indefinitely on a single-node cluster.
  write_taint_guard
  spin_start "Checking control-plane taint  ${DIM}[${K8S_INSTANCE}]${NC}"
  ssm_run "$K8S_INSTANCE" /tmp/byoc_taint.sh "TAINT_OK" > /dev/null || exit 1
  write_phase5
  spin_start "Deploying CloudPrem (this takes ~3 minutes)  ${DIM}[${K8S_INSTANCE}]${NC}"
  elapsed=$(ssm_run "$K8S_INSTANCE" /tmp/byoc_p5.sh) || exit 1
  ckpt_set "phase5"
  phase_done "CloudPrem" "$elapsed"
fi

# ── Phase 6: Datadog Operator + Agent ─────────────────────────────────────────
section "Phase 6 — Datadog Operator + Agent" "⑥"
arch_diagram "agent"
explain "🤖 Phase 6 — the Datadog Agent, pointed at YOUR indexer!

The Datadog Operator manages Agent deployments declaratively
using a 'DatadogAgent' CRD (Custom Resource Definition). You
describe what you want; the operator handles the DaemonSet,
ClusterAgent, RBAC, and lifecycle — no manual pod management.

THE KEY OVERRIDE:  By default, the Agent ships logs to SaaS
intake at app.datadoghq.com. We override that with:
  DD_LOGS_CONFIG_LOGS_DD_URL = cloudprem-indexer:7280

That one env var is what makes it CloudPrem. The Agent collects
logs from all container CRI sockets on the node, ships them
locally to the indexer — and the raw log bytes NEVER leave
your cluster. Not a single byte.

METADATA BUFFERING:  Kubernetes tags like pod_name, namespace,
and container_name are resolved asynchronously. We set
DD_LOGS_CONFIG_EXPECTED_TAGS_DURATION=100000ms so the Agent
waits for full tag resolution before sending — clean, queryable
logs with complete context from the first entry.

CloudPrem metrics (index rates, query latency, storage) ARE
sent to SaaS as regular metrics via DogStatsD — that's fine.
Metadata goes to SaaS. Log data stays here. This is the line. ✓"

if ckpt_done "phase6"; then
  success "Phase 6 already completed — skipping."
else
  write_phase6
  spin_start "Deploying Datadog Operator and Agent  ${DIM}[${K8S_INSTANCE}]${NC}"
  elapsed=$(ssm_run "$K8S_INSTANCE" /tmp/byoc_p6.sh) || exit 1
  ckpt_set "phase6"
  phase_done "Datadog Operator + Agent" "$elapsed"
fi

# ── Phase 7: Verify Reverse Connection ───────────────────────────────────────
section "Phase 7 — Verifying Reverse Connection" "⑦"
explain "🔗 Phase 7 — the moment of truth. Let's see it connect!

The CloudPrem control-plane opens an outbound WebSocket to:
  app.${DD_SITE}  (port 443, HTTPS upgrade to wss://)

This is the 'Reverse Connection' that gives BYOC its magic:
  ✦ YOUR cluster dials OUT to Datadog SaaS
  ✦ No inbound firewall rules required — ever
  ✦ Works in air-gapped, private-subnet, and on-prem environments
  ✦ The SaaS backend never initiates a connection to your network

Once established, your cluster appears in the BYOC Logs UI as:
  Status: Connected  ·  Type: Reverse

This phase tails the control-plane pod logs and watches for
the connection confirmation message — up to 5 minutes.

  ★ Expected cluster name: ${NAMESPACE}-${NAMESPACE}-${CLUSTER_NAME}

IMPORTANT: The 'logs-cloudprem' feature flag must be enabled
on your Datadog org or the WebSocket will be rejected. If Phase
7 times out, that flag is almost certainly the reason.

Hang tight — this is the finish line! 🏁"

write_phase7
spin_start "Waiting for control-plane to connect to Datadog SaaS (~1-3 min)  ${DIM}[${K8S_INSTANCE}]${NC}"
p7_exit=0
p7_out=$(ssm_run "$K8S_INSTANCE" /tmp/byoc_p7.sh 2>&1) || p7_exit=$?
spin_stop
echo ""
if echo "$p7_out" | grep -q "CONNECTION_SEEN"; then
  success "Reverse connection established!"
  echo ""
  echo -e "  ${GREEN}${BOLD}Your cluster is now visible in the BYOC Logs UI:${NC}"
  echo -e "  ${CYAN}  https://app.${DD_SITE}/byoc-logs${NC}"
  echo -e "  ${WHITE}  Look for: ${NAMESPACE}-${NAMESPACE}-${CLUSTER_NAME}${NC}"
  echo -e "  ${DIM}  (may have a short suffix appended if the name already existed)${NC}"
elif echo "$p7_out" | grep -q "AUTH_ERROR"; then
  warn "Reverse connection auth failed — API key rejected by Datadog."
  echo -e "  ${RED}  The searcher could not authenticate. Check the API key is valid for this org:${NC}"
  echo -e "  ${CYAN}  https://app.${DD_SITE}/organization-settings/api-keys${NC}"
  echo ""
  echo "$p7_out" | grep -i "auth_error\|authentication" | while IFS= read -r line; do
    echo -e "  ${DIM}${line}${NC}"
  done
elif [[ $p7_exit -ne 0 ]] && echo "$p7_out" | grep -qi "not reachable via SSM\|InvalidInstanceId\|TargetNotConnected"; then
  warn "Phase 7 skipped — SSM connection to ${K8S_INSTANCE} was lost."
  echo -e "  ${YELLOW}  The instance may have restarted or the SSM agent dropped.${NC}"
  echo -e "  ${YELLOW}  Re-run install.sh — phases 1–6 are checkpointed and will be skipped.${NC}"
  echo -e "  ${YELLOW}  Phase 7 only tails logs and does not modify cluster state.${NC}"
else
  warn "Connection not confirmed in logs within 3 minutes."
  echo -e "  ${YELLOW}  Most likely cause: 'logs-cloudprem' feature flag is not enabled.${NC}"
  echo -e "  ${YELLOW}  Enable it at: ${CYAN}https://mosaic.us1.ddbuild.io/feature-flags/logs-cloudprem${NC}"
  echo -e "  ${YELLOW}  Then restart the control plane:${NC}"
  echo -e "  ${DIM}    KUBECONFIG=/etc/kubernetes/admin.conf kubectl rollout restart deployment/${NAMESPACE}-cloudprem-control-plane -n ${NAMESPACE}${NC}"
  echo ""
  echo -e "  ${DIM}  Check: ${CYAN}https://app.${DD_SITE}/byoc-logs${NC}"
  echo -e "  ${DIM}  Look for: ${WHITE}${NAMESPACE}-${NAMESPACE}-${CLUSTER_NAME}${NC}"
  echo ""
  echo -e "  ${DIM}Control-plane log tail:${NC}"
  echo "$p7_out" | tail -15 | while IFS= read -r line; do
    echo -e "  ${DIM}${line}${NC}"
  done
fi
echo ""

# ── Done ──────────────────────────────────────────────────────────────────────
arch_diagram "done"
print_dashboard

# ── Teardown prompt (dev/iteration helper) ────────────────────────────────────
echo ""
echo -e "  ${YELLOW}${BOLD}  Terminate instances?${NC}"
echo -e "  ${DIM}  K8s:      ${K8S_INSTANCE}${NC}"
echo -e "  ${DIM}  Postgres: ${PG_INSTANCE}${NC}"
echo ""
printf "  ${CYAN}▶${NC}  ${WHITE}%-38s${NC}${DIM}[no]${NC}: " "Terminate both instances now? (yes/no)"
teardown_resp=""
read -re teardown_resp < /dev/tty || true
if [[ "${teardown_resp,,}" == "yes" || "${teardown_resp,,}" == "y" ]]; then
  info "Terminating instances..."
  aws ec2 terminate-instances \
    --instance-ids "$K8S_INSTANCE" "$PG_INSTANCE" \
    --region "$REGION" --profile "$PROFILE" > /dev/null \
    && success "Instances terminated. Cleaning up checkpoint..." \
    || warn "Terminate command failed — check AWS console."
  rm -rf "$CKPT_DIR"
  success "Done. Re-run 'bash launch_instances.sh' to start fresh."
else
  echo ""
  echo -e "  ${DIM}Instances left running. To terminate later:${NC}"
  echo -e "  ${CYAN}  aws ec2 terminate-instances --instance-ids ${K8S_INSTANCE} ${PG_INSTANCE} --region ${REGION} --profile ${PROFILE}${NC}"
fi
echo ""
