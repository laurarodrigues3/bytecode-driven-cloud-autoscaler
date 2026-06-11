#!/usr/bin/env bash
# =============================================================================
# 04-launch-worker.sh
# Lança UMA instância worker a partir da AMI pré-cozida pelo 03-create-ami.sh.
# O systemd unit dentro da AMI arranca o worker automaticamente no boot.
# =============================================================================
set -euo pipefail
source "$(dirname "$0")/aws-config.sh"
test_aws_cli || exit 1

if [ ! -f "$WORKER_SG_ID_FILE" ]; then
    err "Worker SG não encontrado. Corre primeiro:  ./02-setup-network.sh"
    exit 1
fi
if [ ! -f "$WORKER_AMI_ID_FILE" ]; then
    err "Worker AMI não encontrada. Corre primeiro:  ./03-create-ami.sh"
    exit 1
fi
WORKER_SG_ID=$(read_state "$WORKER_SG_ID_FILE")
WORKER_AMI_ID=$(read_state "$WORKER_AMI_ID_FILE")
ensure_my_ip_in_sg "$WORKER_SG_ID"

info "A lançar worker a partir de $WORKER_AMI_ID..."
INSTANCE_ID=$(aws ec2 run-instances \
    --image-id "$WORKER_AMI_ID" \
    --instance-type "$INSTANCE_TYPE" \
    --key-name "$KEYPAIR_NAME" \
    --security-group-ids "$WORKER_SG_ID" \
    --iam-instance-profile "Name=$WORKER_INSTANCE_PROFILE" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Project,Value=NatureAtCloud},{Key=Role,Value=worker}]" \
    --region "$AWS_REGION" \
    --query "Instances[0].InstanceId" --output text)
INSTANCE_ID=$(sanitize "$INSTANCE_ID")
ok "Lançada: $INSTANCE_ID"

info "A aguardar estado 'running'..."
aws ec2 wait instance-running --instance-ids "$INSTANCE_ID" --region "$AWS_REGION"
PUBLIC_IP=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" --region "$AWS_REGION" \
    --query "Reservations[0].Instances[0].PublicIpAddress" --output text)
PUBLIC_IP=$(sanitize "$PUBLIC_IP")

# Append e deduplicar (evita acumular IDs de execuções repetidas).
echo "$INSTANCE_ID" >> "$WORKER_INSTANCE_IDS_FILE"
if [ -f "$WORKER_INSTANCE_IDS_FILE" ]; then
    sort -u "$WORKER_INSTANCE_IDS_FILE" -o "$WORKER_INSTANCE_IDS_FILE"
fi

ok ""
ok "============================================================"
ok " Worker UP"
ok "   Instance ID : $INSTANCE_ID"
ok "   Public IP   : $PUBLIC_IP"
ok "   Endpoint    : http://$PUBLIC_IP:$WORKER_PORT"
ok "============================================================"
ok ""
info "O systemd da AMI já arrancou o worker. Testa em ~30s:"
echo "  curl \"http://$PUBLIC_IP:$WORKER_PORT/fractals?w=200&h=200&iterations=100\" --output fractal.png"
echo ""
info "Para SSH (debug):"
echo "  ssh -i $KEYPAIR_FILE ec2-user@$PUBLIC_IP"
echo "  tail -f /var/log/cnv-worker.log"
