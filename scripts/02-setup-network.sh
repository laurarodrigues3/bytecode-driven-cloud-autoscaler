#!/usr/bin/env bash
# =============================================================================
# 02-setup-network.sh
# Cria SSH key pair (.pem local) e 2 Security Groups (worker + LB).
# Idempotente.
# =============================================================================
set -euo pipefail
source "$(dirname "$0")/aws-config.sh"
test_aws_cli || exit 1

# --- 1) Key pair ---
if aws ec2 describe-key-pairs --key-names "$KEYPAIR_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
    if [ ! -f "$KEYPAIR_FILE" ]; then
        warn "Key pair existe na AWS mas não há .pem local. A apagar e recriar."
        aws ec2 delete-key-pair --key-name "$KEYPAIR_NAME" --region "$AWS_REGION"
    else
        info "Key pair '$KEYPAIR_NAME' já existe e .pem local presente."
    fi
fi
if [ ! -f "$KEYPAIR_FILE" ]; then
    info "A criar key pair '$KEYPAIR_NAME'..."
    # Strip CRLF — em Git Bash o AWS CLI emite \r\n e o OpenSSH 10 rejeita PEMs com CRLF.
    aws ec2 create-key-pair --key-name "$KEYPAIR_NAME" --region "$AWS_REGION" \
        --query "KeyMaterial" --output text | tr -d '\r' > "$KEYPAIR_FILE"
    chmod 400 "$KEYPAIR_FILE" 2>/dev/null || true
    ok "Key pair criada: $KEYPAIR_FILE (NÃO commitar)"
fi

# --- 2) VPC default + IP público ---
VPC_ID=$(aws ec2 describe-vpcs --filters "Name=is-default,Values=true" \
    --region "$AWS_REGION" --query "Vpcs[0].VpcId" --output text)
VPC_ID=$(sanitize "$VPC_ID")
info "VPC default: $VPC_ID"

MY_IP=$(curl -fsS https://checkip.amazonaws.com 2>/dev/null | tr -d '[:space:]' || true)
if [ -n "$MY_IP" ]; then
    MY_CIDR="$MY_IP/32"
    info "O teu IP público: $MY_IP (autorizado para SSH)"
else
    warn "Não detectei o teu IP. SSH ficará aberto para 0.0.0.0/0 (não recomendado)."
    MY_CIDR="0.0.0.0/0"
fi

ensure_sg() {
    local name="$1" desc="$2"
    local sg_id
    sg_id=$(aws ec2 describe-security-groups \
        --filters "Name=group-name,Values=$name" "Name=vpc-id,Values=$VPC_ID" \
        --region "$AWS_REGION" --query "SecurityGroups[0].GroupId" --output text 2>/dev/null || echo "None")
    if [ "$sg_id" = "None" ] || [ -z "$sg_id" ]; then
        info "A criar SG '$name'..."
        sg_id=$(aws ec2 create-security-group --group-name "$name" --description "$desc" \
            --vpc-id "$VPC_ID" --region "$AWS_REGION" --query "GroupId" --output text)
        ok "SG '$name' criado: $sg_id"
    else
        info "SG '$name' já existe: $sg_id"
    fi
    sanitize "$sg_id"
}

WORKER_SG_ID=$(ensure_sg "$WORKER_SG_NAME" "CNV worker")
LB_SG_ID=$(ensure_sg "$LB_SG_NAME" "CNV load balancer")

try_ingress() {
    aws ec2 authorize-security-group-ingress --group-id "$1" \
        --protocol "$2" --port "$3" --cidr "$4" --region "$AWS_REGION" 2>/dev/null \
        && ok "  ingress $2/$3 from $4" || true
}
try_ingress_sg() {
    aws ec2 authorize-security-group-ingress --group-id "$1" \
        --protocol "$2" --port "$3" --source-group "$4" --region "$AWS_REGION" 2>/dev/null \
        && ok "  ingress $2/$3 from SG $4" || true
}

info "Regras worker SG..."
try_ingress    "$WORKER_SG_ID" tcp 22           "$MY_CIDR"
try_ingress_sg "$WORKER_SG_ID" tcp "$WORKER_PORT" "$LB_SG_ID"
try_ingress    "$WORKER_SG_ID" tcp "$WORKER_PORT" "$MY_CIDR"

info "Regras LB SG..."
try_ingress    "$LB_SG_ID" tcp 22       "$MY_CIDR"
try_ingress    "$LB_SG_ID" tcp "$LB_PORT" "0.0.0.0/0"

WORKER_SG_ID=$(sanitize "$WORKER_SG_ID")
LB_SG_ID=$(sanitize "$LB_SG_ID")
printf '%s' "$WORKER_SG_ID" > "$WORKER_SG_ID_FILE"
printf '%s' "$LB_SG_ID"     > "$LB_SG_ID_FILE"

ok "Network concluído."
ok "  Worker SG: $WORKER_SG_ID"
ok "  LB SG:     $LB_SG_ID"
