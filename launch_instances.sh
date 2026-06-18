#!/usr/bin/env bash
# =============================================================================
#  BYOC CloudPrem Lab — EC2 Instance Launcher
#  Launches the two EC2 instances required by install.sh:
#    • Kubernetes node  (m5zn.metal or m5.4xlarge)  — bare-metal k8s + CloudPrem
#    • PostgreSQL node  (t3.micro)                   — QuickWit metastore
#
#  No SSH keys required. All access is via AWS SSM SendCommand.
#  Run this first, then run install.sh once both instances appear Online in SSM.
# =============================================================================
set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; WHITE='\033[1;37m'; DIM='\033[2m'; NC='\033[0m'; BOLD='\033[1m'

info()    { echo -e "  ${CYAN}▸${NC}  $1"; }
success() { echo -e "  ${GREEN}✓${NC}  $1"; }
warn()    { echo -e "  ${YELLOW}⚠${NC}  $1"; }
abort()   { echo -e "\n  ${RED}${BOLD}✗  $1${NC}\n"; exit 1; }

# ── Defaults ─────────────────────────────────────────────────────────────────
PROFILE="${BYOC_PROFILE:-byoc}"
REGION="${BYOC_REGION:-us-east-1}"
K8S_TYPE="${BYOC_K8S_TYPE:-m5.4xlarge}"   # m5zn.metal requires dedicated tenancy
PG_TYPE="${BYOC_PG_TYPE:-t3.micro}"
K8S_DISK="${BYOC_K8S_DISK:-300}"
PG_DISK="${BYOC_PG_DISK:-20}"

echo ""
echo -e "${WHITE}${BOLD}  BYOC CloudPrem — EC2 Instance Launcher${NC}"
echo -e "${DIM}  ─────────────────────────────────────────────────────${NC}"
echo ""

# ── 1. Validate AWS credentials ───────────────────────────────────────────────
info "Checking AWS credentials (profile: $PROFILE, region: $REGION)..."
ACCOUNT_ID=$(aws sts get-caller-identity \
  --profile "$PROFILE" --region "$REGION" \
  --query "Account" --output text 2>/dev/null) \
  || abort "AWS credentials invalid or expired. Refresh them first:\n\n  aws configure set aws_access_key_id     \"\$AWS_ACCESS_KEY_ID\"     --profile ${PROFILE}\n  aws configure set aws_secret_access_key \"\$AWS_SECRET_ACCESS_KEY\" --profile ${PROFILE}\n  aws configure set aws_session_token     \"\$AWS_SESSION_TOKEN\"     --profile ${PROFILE}"
success "Credentials OK (account: $ACCOUNT_ID)"

# ── 2. Find Ubuntu 22.04 AMI ──────────────────────────────────────────────────
info "Finding latest Ubuntu 22.04 LTS AMI in $REGION..."
# Use Canonical's official AWS SSM path — always points to the current 22.04 AMI
AMI_ID=$(aws ssm get-parameter \
  --name "/aws/service/canonical/ubuntu/server/22.04/stable/current/amd64/hvm/ebs-gp2/ami-id" \
  --region "$REGION" --profile "$PROFILE" \
  --query "Parameter.Value" --output text 2>/dev/null) \
  || abort "Could not resolve Ubuntu 22.04 AMI. Check region '$REGION' is supported."
success "AMI: $AMI_ID (Ubuntu 22.04 LTS)"

# ── 3. Find or create SSM instance profile ────────────────────────────────────
PROFILE_NAME="AmazonSSMManagedInstanceCoreProfile"

info "Checking for SSM instance profile..."
EXISTING_PROFILE=$(aws iam get-instance-profile \
  --instance-profile-name "$PROFILE_NAME" \
  --profile "$PROFILE" --region "$REGION" \
  --query "InstanceProfile.InstanceProfileName" --output text 2>/dev/null || true)

if [[ "$EXISTING_PROFILE" == "$PROFILE_NAME" ]]; then
  success "Using existing instance profile: $PROFILE_NAME"
else
  info "Creating IAM role and instance profile for SSM..."

  # Create role
  aws iam create-role \
    --role-name "$PROFILE_NAME" \
    --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}' \
    --profile "$PROFILE" --region "$REGION" \
    --output text > /dev/null 2>&1 \
    || warn "Role may already exist — continuing."

  # Attach SSM policy
  aws iam attach-role-policy \
    --role-name "$PROFILE_NAME" \
    --policy-arn "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore" \
    --profile "$PROFILE" --region "$REGION" \
    --output text > /dev/null 2>&1 \
    || warn "Policy may already be attached — continuing."

  # Create instance profile
  aws iam create-instance-profile \
    --instance-profile-name "$PROFILE_NAME" \
    --profile "$PROFILE" --region "$REGION" \
    --output text > /dev/null 2>&1 \
    || warn "Instance profile may already exist — continuing."

  # Add role to instance profile
  aws iam add-role-to-instance-profile \
    --instance-profile-name "$PROFILE_NAME" \
    --role-name "$PROFILE_NAME" \
    --profile "$PROFILE" --region "$REGION" \
    --output text > /dev/null 2>&1 \
    || warn "Role may already be in profile — continuing."

  # IAM is eventually consistent — give it a moment
  info "Waiting for IAM to propagate..."
  sleep 10
  success "Instance profile ready: $PROFILE_NAME"
fi

# ── 4. Find or create security group ─────────────────────────────────────────
SG_NAME="byoc-cloudprem-lab"

info "Checking for security group '$SG_NAME'..."
SG_ID=$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=$SG_NAME" \
  --query "SecurityGroups[0].GroupId" \
  --output text --region "$REGION" --profile "$PROFILE" 2>/dev/null)

if [[ "$SG_ID" == "None" || -z "$SG_ID" ]]; then
  info "Creating security group '$SG_NAME'..."
  SG_ID=$(aws ec2 create-security-group \
    --group-name "$SG_NAME" \
    --description "BYOC CloudPrem lab — k8s and postgres nodes" \
    --region "$REGION" --profile "$PROFILE" \
    --query "GroupId" --output text)

  # Allow all traffic within the SG (k8s ↔ postgres communication)
  aws ec2 authorize-security-group-ingress \
    --group-id "$SG_ID" \
    --protocol all \
    --source-group "$SG_ID" \
    --region "$REGION" --profile "$PROFILE" \
    --output text > /dev/null

  # Allow outbound HTTPS for SSM, helm repos, docker images
  # (All outbound is allowed by default — no egress rule needed)

  success "Security group created: $SG_ID"
else
  success "Using existing security group: $SG_ID ($SG_NAME)"
fi

# ── 5. Launch Kubernetes node ─────────────────────────────────────────────────
echo ""
info "Launching Kubernetes node ($K8S_TYPE, ${K8S_DISK}GB gp3)..."

K8S_INSTANCE_ID=$(aws ec2 run-instances \
  --image-id "$AMI_ID" \
  --instance-type "$K8S_TYPE" \
  --iam-instance-profile "Name=$PROFILE_NAME" \
  --security-group-ids "$SG_ID" \
  --block-device-mappings "[{\"DeviceName\":\"/dev/sda1\",\"Ebs\":{\"VolumeSize\":${K8S_DISK},\"VolumeType\":\"gp3\",\"DeleteOnTermination\":true}}]" \
  --metadata-options "HttpTokens=optional,HttpEndpoint=enabled" \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=byoc-k8s},{Key=Project,Value=byoc-cloudprem-lab}]" \
  --region "$REGION" --profile "$PROFILE" \
  --query "Instances[0].InstanceId" --output text) \
  || abort "Failed to launch Kubernetes node. Check instance type availability and quotas."

success "Kubernetes node launched: $K8S_INSTANCE_ID"

# ── 6. Launch PostgreSQL node ─────────────────────────────────────────────────
info "Launching PostgreSQL node ($PG_TYPE, ${PG_DISK}GB gp2)..."

PG_INSTANCE_ID=$(aws ec2 run-instances \
  --image-id "$AMI_ID" \
  --instance-type "$PG_TYPE" \
  --iam-instance-profile "Name=$PROFILE_NAME" \
  --security-group-ids "$SG_ID" \
  --block-device-mappings "[{\"DeviceName\":\"/dev/sda1\",\"Ebs\":{\"VolumeSize\":${PG_DISK},\"VolumeType\":\"gp2\",\"DeleteOnTermination\":true}}]" \
  --metadata-options "HttpTokens=optional,HttpEndpoint=enabled" \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=byoc-postgres},{Key=Project,Value=byoc-cloudprem-lab}]" \
  --region "$REGION" --profile "$PROFILE" \
  --query "Instances[0].InstanceId" --output text) \
  || abort "Failed to launch PostgreSQL node."

success "PostgreSQL node launched: $PG_INSTANCE_ID"

# ── 7. Wait for SSM registration ─────────────────────────────────────────────
echo ""
info "Waiting for both instances to register with SSM..."
info "(This takes 2–4 minutes while cloud-init installs the SSM agent)"
echo ""

K8S_ONLINE=false
PG_ONLINE=false
WAIT_COUNT=0

while true; do
  sleep 15
  ((WAIT_COUNT++)) || true

  K8S_STATUS=$(aws ssm describe-instance-information \
    --filters "Key=InstanceIds,Values=$K8S_INSTANCE_ID" \
    --query "InstanceInformationList[0].PingStatus" \
    --output text --region "$REGION" --profile "$PROFILE" 2>/dev/null || echo "Pending")

  PG_STATUS=$(aws ssm describe-instance-information \
    --filters "Key=InstanceIds,Values=$PG_INSTANCE_ID" \
    --query "InstanceInformationList[0].PingStatus" \
    --output text --region "$REGION" --profile "$PROFILE" 2>/dev/null || echo "Pending")

  printf "  ${DIM}[%2ds]  k8s: %-10s  postgres: %-10s${NC}\r" \
    $((WAIT_COUNT * 15)) "$K8S_STATUS" "$PG_STATUS"

  [[ "$K8S_STATUS" == "Online" ]] && K8S_ONLINE=true
  [[ "$PG_STATUS" == "Online" ]]  && PG_ONLINE=true
  [[ "$K8S_ONLINE" == true && "$PG_ONLINE" == true ]] && break

  if [[ "$WAIT_COUNT" -ge 40 ]]; then
    echo ""
    abort "Timed out waiting for SSM. Check the instances in the EC2 console.\nVerify the IAM profile '$PROFILE_NAME' is attached and SSM agent is running."
  fi
done

echo ""
echo ""

# ── 8. Summary ────────────────────────────────────────────────────────────────
echo -e "${GREEN}${BOLD}  ✓  Both instances are Online in SSM${NC}"
echo ""
echo -e "${DIM}  ─────────────────────────────────────────────────────${NC}"
echo ""
printf "  ${WHITE}%-22s${NC}  %s\n" "Kubernetes node:" "$K8S_INSTANCE_ID"
printf "  ${WHITE}%-22s${NC}  %s\n" "PostgreSQL node:" "$PG_INSTANCE_ID"
echo ""
echo -e "${DIM}  ─────────────────────────────────────────────────────${NC}"
echo ""
echo -e "  ${YELLOW}${BOLD}  Next step:${NC}"
echo ""
echo -e "  ${CYAN}  bash install.sh${NC}"
echo ""
echo -e "  ${DIM}  Select '$K8S_INSTANCE_ID' as the Kubernetes node${NC}"
echo -e "  ${DIM}  Select '$PG_INSTANCE_ID' as the PostgreSQL node${NC}"
echo ""

# ── 9. Cleanup hint ───────────────────────────────────────────────────────────
echo -e "  ${DIM}To terminate when done:${NC}"
printf "  ${DIM}  aws ec2 terminate-instances --instance-ids %s %s --region %s --profile %s${NC}\n" \
  "$K8S_INSTANCE_ID" "$PG_INSTANCE_ID" "$REGION" "$PROFILE"
echo ""
