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

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
CYAN=$'\033[0;36m'; WHITE=$'\033[1;37m'; DIM=$'\033[2m'; NC=$'\033[0m'; BOLD=$'\033[1m'

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
CALLER_EMAIL=$(aws sts get-caller-identity \
  --profile "$PROFILE" --region "$REGION" \
  --query "Arn" --output text 2>/dev/null \
  | sed 's/.*\///')   # extract session name (email for SSO, username otherwise)

# ── 2. Find Ubuntu 22.04 AMI ──────────────────────────────────────────────────
info "Finding latest Ubuntu 22.04 LTS AMI in $REGION..."
AMI_ID=$(aws ssm get-parameter \
  --name "/aws/service/canonical/ubuntu/server/22.04/stable/current/amd64/hvm/ebs-gp2/ami-id" \
  --region "$REGION" --profile "$PROFILE" \
  --query "Parameter.Value" --output text 2>/dev/null) \
  || abort "Could not resolve Ubuntu 22.04 AMI. Check region '$REGION' is supported."
success "AMI: $AMI_ID (Ubuntu 22.04 LTS)"

# ── 3. VPC + subnet selection ────────────────────────────────────────────────
#
# Preference order:
#   1. Default VPC (most accounts have one)
#   2. Any VPC that has an internet gateway attached
#   3. Any VPC at all (warn that SSM may not work without internet access)
#
info "Locating VPC..."

VPC_ID=$(aws ec2 describe-vpcs \
  --filters "Name=is-default,Values=true" \
  --query "Vpcs[0].VpcId" --output text \
  --region "$REGION" --profile "$PROFILE" 2>/dev/null)

if [[ "$VPC_ID" == "None" || -z "$VPC_ID" ]]; then
  warn "No default VPC found — scanning for a VPC with an internet gateway..."

  # Find all VPCs that have an IGW attached
  VPC_ID=$(aws ec2 describe-internet-gateways \
    --query "InternetGateways[?Attachments[0].State=='available'].Attachments[0].VpcId | [0]" \
    --output text --region "$REGION" --profile "$PROFILE" 2>/dev/null)

  if [[ "$VPC_ID" == "None" || -z "$VPC_ID" ]]; then
    warn "No VPC with an internet gateway found. Picking the first available VPC."
    warn "SSM and apt-get both need outbound internet (port 443)."
    warn "Ensure this VPC has either a NAT gateway or SSM VPC endpoints:"
    warn "  com.amazonaws.${REGION}.ssm"
    warn "  com.amazonaws.${REGION}.ssmmessages"
    warn "  com.amazonaws.${REGION}.ec2messages"
    echo ""
    VPC_ID=$(aws ec2 describe-vpcs \
      --query "Vpcs[0].VpcId" --output text \
      --region "$REGION" --profile "$PROFILE" 2>/dev/null)
    [[ "$VPC_ID" == "None" || -z "$VPC_ID" ]] \
      && abort "No VPC found in $REGION. Create one first:\n  aws ec2 create-default-vpc --region $REGION --profile $PROFILE"
    warn "Using VPC $VPC_ID — verify internet access before continuing."
  else
    success "Found VPC with internet gateway: $VPC_ID"
  fi
else
  success "Default VPC: $VPC_ID"
fi

# ── 4. Check internet gateway ────────────────────────────────────────────────
IGW_ID=$(aws ec2 describe-internet-gateways \
  --filters "Name=attachment.vpc-id,Values=$VPC_ID" \
  --query "InternetGateways[0].InternetGatewayId" --output text \
  --region "$REGION" --profile "$PROFILE" 2>/dev/null)

if [[ "$IGW_ID" == "None" || -z "$IGW_ID" ]]; then
  warn "No internet gateway attached to VPC $VPC_ID."
  warn "The SSM agent and package installs (apt-get, helm, containerd) all require"
  warn "outbound HTTPS. Without an IGW (or NAT gateway + SSM VPC endpoints),"
  warn "instances will launch but SSM will never register."
  warn ""
  warn "To attach the default IGW or create one:"
  warn "  aws ec2 create-internet-gateway --region $REGION --profile $PROFILE"
  warn "  aws ec2 attach-internet-gateway --internet-gateway-id igw-xxx --vpc-id $VPC_ID ..."
  echo ""
  read -rp "  Continue anyway? [y/N] " yn < /dev/tty
  [[ "$yn" =~ ^[Yy]$ ]] || abort "Aborted. Attach an internet gateway to $VPC_ID and retry."
else
  success "Internet gateway: $IGW_ID"
fi

# ── 5. Find subnet ────────────────────────────────────────────────────────────
# Prefer a subnet with auto-assign public IP (the instances need public IPs to
# reach SSM and the internet for package downloads).
info "Selecting subnet in VPC $VPC_ID..."

SUBNET_ID=$(aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=map-public-ip-on-launch,Values=true" \
  --query "Subnets[0].SubnetId" --output text \
  --region "$REGION" --profile "$PROFILE" 2>/dev/null)

if [[ "$SUBNET_ID" == "None" || -z "$SUBNET_ID" ]]; then
  warn "No subnet with auto-assign public IP found in $VPC_ID — using first available subnet."
  warn "If instances don't register with SSM, verify the subnet has a route to the IGW"
  warn "and that 'Auto-assign public IPv4' is enabled:"
  warn "  aws ec2 modify-subnet-attribute --subnet-id <id> --map-public-ip-on-launch"
  SUBNET_ID=$(aws ec2 describe-subnets \
    --filters "Name=vpc-id,Values=$VPC_ID" \
    --query "Subnets[0].SubnetId" --output text \
    --region "$REGION" --profile "$PROFILE" 2>/dev/null)
  [[ "$SUBNET_ID" == "None" || -z "$SUBNET_ID" ]] \
    && abort "No subnets found in VPC $VPC_ID. Check the VPC configuration."
fi
success "Subnet: $SUBNET_ID"

# ── 6. Find or create SSM instance profile ────────────────────────────────────
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

  # Create role — AlreadyExists is not an error
  CREATE_ROLE_OUT=$(aws iam create-role \
    --role-name "$PROFILE_NAME" \
    --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}' \
    --profile "$PROFILE" --region "$REGION" \
    --output text 2>&1) || {
      if echo "$CREATE_ROLE_OUT" | grep -q "EntityAlreadyExists"; then
        true  # expected on re-run
      else
        abort "Failed to create IAM role: $CREATE_ROLE_OUT"
      fi
    }

  # Attach SSM policy — if already attached, ignore
  aws iam attach-role-policy \
    --role-name "$PROFILE_NAME" \
    --policy-arn "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore" \
    --profile "$PROFILE" --region "$REGION" 2>/dev/null || true

  # Create instance profile — AlreadyExists is fine
  aws iam create-instance-profile \
    --instance-profile-name "$PROFILE_NAME" \
    --profile "$PROFILE" --region "$REGION" \
    --output text > /dev/null 2>&1 || true

  # Add role — if already added, ignore
  aws iam add-role-to-instance-profile \
    --instance-profile-name "$PROFILE_NAME" \
    --role-name "$PROFILE_NAME" \
    --profile "$PROFILE" --region "$REGION" 2>/dev/null || true

  # Verify the profile actually exists and has the role attached before continuing
  VERIFY=$(aws iam get-instance-profile \
    --instance-profile-name "$PROFILE_NAME" \
    --profile "$PROFILE" --region "$REGION" \
    --query "InstanceProfile.Roles[0].RoleName" --output text 2>/dev/null || true)
  [[ "$VERIFY" == "$PROFILE_NAME" ]] \
    || abort "Instance profile creation failed or role not attached. Check IAM permissions:\n  Required: iam:CreateRole, iam:AttachRolePolicy, iam:CreateInstanceProfile, iam:AddRoleToInstanceProfile"

  # IAM is eventually consistent
  info "Waiting for IAM to propagate..."
  sleep 10
  success "Instance profile ready: $PROFILE_NAME"
fi

# ── 7. Find or create security group (scoped to the selected VPC) ─────────────
SG_NAME="byoc-cloudprem-lab"

info "Checking for security group '$SG_NAME' in VPC $VPC_ID..."
SG_ID=$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=$SG_NAME" "Name=vpc-id,Values=$VPC_ID" \
  --query "SecurityGroups[0].GroupId" \
  --output text --region "$REGION" --profile "$PROFILE" 2>/dev/null)

if [[ "$SG_ID" == "None" || -z "$SG_ID" ]]; then
  info "Creating security group '$SG_NAME'..."
  SG_ID=$(aws ec2 create-security-group \
    --group-name "$SG_NAME" \
    --description "BYOC CloudPrem lab - k8s and postgres nodes" \
    --vpc-id "$VPC_ID" \
    --region "$REGION" --profile "$PROFILE" \
    --query "GroupId" --output text) \
    || abort "Failed to create security group."
  [[ "$SG_ID" =~ ^sg- ]] || abort "Security group creation returned unexpected value: '$SG_ID'"

  # Allow all traffic within the SG (k8s ↔ postgres communication)
  aws ec2 authorize-security-group-ingress \
    --group-id "$SG_ID" \
    --protocol all \
    --source-group "$SG_ID" \
    --region "$REGION" --profile "$PROFILE" \
    --output text > /dev/null

  success "Security group created: $SG_ID"
else
  success "Using existing security group: $SG_ID ($SG_NAME)"
fi

# ── 8. Launch Kubernetes node ─────────────────────────────────────────────────
echo ""
info "Launching Kubernetes node ($K8S_TYPE, ${K8S_DISK}GB gp3)..."

K8S_INSTANCE_ID=$(aws ec2 run-instances \
  --image-id "$AMI_ID" \
  --instance-type "$K8S_TYPE" \
  --subnet-id "$SUBNET_ID" \
  --iam-instance-profile "Name=$PROFILE_NAME" \
  --security-group-ids "$SG_ID" \
  --block-device-mappings "[{\"DeviceName\":\"/dev/sda1\",\"Ebs\":{\"VolumeSize\":${K8S_DISK},\"VolumeType\":\"gp3\",\"DeleteOnTermination\":true}}]" \
  --metadata-options "HttpTokens=optional,HttpEndpoint=enabled" \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=byoc-k8s},{Key=Project,Value=byoc-cloudprem-lab},{Key=byoc-role,Value=k8s},{Key=CreatedBy,Value=${CALLER_EMAIL}}]" \
  --region "$REGION" --profile "$PROFILE" \
  --query "Instances[0].InstanceId" --output text) \
  || abort "Failed to launch Kubernetes node. Check instance type availability and quotas in $REGION.\nTo check quota: aws service-quotas get-service-quota --service-code ec2 --quota-code L-1216C47A --region $REGION --profile $PROFILE"

[[ "$K8S_INSTANCE_ID" =~ ^i-[0-9a-f]+ ]] \
  || abort "Kubernetes node launch returned invalid ID: '$K8S_INSTANCE_ID'"
success "Kubernetes node launched: $K8S_INSTANCE_ID"

# ── 9. Launch PostgreSQL node ─────────────────────────────────────────────────
info "Launching PostgreSQL node ($PG_TYPE, ${PG_DISK}GB gp2)..."

PG_INSTANCE_ID=$(aws ec2 run-instances \
  --image-id "$AMI_ID" \
  --instance-type "$PG_TYPE" \
  --subnet-id "$SUBNET_ID" \
  --iam-instance-profile "Name=$PROFILE_NAME" \
  --security-group-ids "$SG_ID" \
  --block-device-mappings "[{\"DeviceName\":\"/dev/sda1\",\"Ebs\":{\"VolumeSize\":${PG_DISK},\"VolumeType\":\"gp2\",\"DeleteOnTermination\":true}}]" \
  --metadata-options "HttpTokens=optional,HttpEndpoint=enabled" \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=byoc-postgres},{Key=Project,Value=byoc-cloudprem-lab},{Key=byoc-role,Value=postgres},{Key=CreatedBy,Value=${CALLER_EMAIL}}]" \
  --region "$REGION" --profile "$PROFILE" \
  --query "Instances[0].InstanceId" --output text) \
  || abort "Failed to launch PostgreSQL node."

[[ "$PG_INSTANCE_ID" =~ ^i-[0-9a-f]+ ]] \
  || abort "PostgreSQL node launch returned invalid ID: '$PG_INSTANCE_ID'"
success "PostgreSQL node launched: $PG_INSTANCE_ID"

# ── 10. Wait for SSM registration ─────────────────────────────────────────────
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
  [[ "$PG_STATUS"  == "Online" ]] && PG_ONLINE=true
  [[ "$K8S_ONLINE" == true && "$PG_ONLINE" == true ]] && break

  if [[ "$WAIT_COUNT" -ge 40 ]]; then
    echo ""
    echo ""
    warn "Timed out waiting for SSM after $((WAIT_COUNT * 15))s."
    echo ""
    echo -e "  ${WHITE}Common causes:${NC}"
    echo -e "  ${DIM}1. No internet access — subnet has no route to IGW or NAT gateway${NC}"
    echo -e "     ${CYAN}aws ec2 describe-route-tables --filters Name=association.subnet-id,Values=${SUBNET_ID} --region ${REGION} --profile ${PROFILE}${NC}"
    echo ""
    echo -e "  ${DIM}2. SSM agent not started — check instance console output${NC}"
    echo -e "     ${CYAN}aws ec2 get-console-output --instance-id ${K8S_INSTANCE_ID} --region ${REGION} --profile ${PROFILE} --latest | jq -r .Output | tail -30${NC}"
    echo ""
    echo -e "  ${DIM}3. IAM instance profile not attached properly${NC}"
    echo -e "     ${CYAN}aws ec2 describe-instances --instance-ids ${K8S_INSTANCE_ID} --query 'Reservations[0].Instances[0].IamInstanceProfile' --region ${REGION} --profile ${PROFILE}${NC}"
    echo ""
    exit 1
  fi
done

echo ""
echo ""

# ── 11. Summary ───────────────────────────────────────────────────────────────
echo -e "${GREEN}${BOLD}  ✓  Both instances are Online in SSM${NC}"
echo ""
echo -e "${DIM}  ─────────────────────────────────────────────────────${NC}"
echo ""
printf "  ${WHITE}%-22s${NC}  %s\n" "Kubernetes node:" "$K8S_INSTANCE_ID"
printf "  ${WHITE}%-22s${NC}  %s\n" "PostgreSQL node:" "$PG_INSTANCE_ID"
printf "  ${WHITE}%-22s${NC}  %s\n" "VPC:"             "$VPC_ID"
printf "  ${WHITE}%-22s${NC}  %s\n" "Subnet:"          "$SUBNET_ID"
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

# ── 12. Cleanup hint ──────────────────────────────────────────────────────────
echo -e "  ${DIM}To terminate when done:${NC}"
printf "  ${DIM}  aws ec2 terminate-instances --instance-ids %s %s --region %s --profile %s${NC}\n" \
  "$K8S_INSTANCE_ID" "$PG_INSTANCE_ID" "$REGION" "$PROFILE"
echo ""
