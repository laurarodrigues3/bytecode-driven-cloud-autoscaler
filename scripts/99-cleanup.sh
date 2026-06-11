#!/usr/bin/env bash
# =============================================================================
# 99-cleanup.sh
# Termina todas as EC2s do projecto (default).
# Com --deep apaga TAMBÉM SGs, key pair, IAM roles, AMI worker e tabela DynamoDB.
# =============================================================================
set -euo pipefail
source "$(dirname "$0")/aws-config.sh"
test_aws_cli || exit 1

DEEP=false
[ "${1:-}" = "--deep" ] && DEEP=true

# --- 1) Terminar instâncias EC2 do projecto ---
info "A procurar instâncias EC2 do projecto..."
IDS=$(aws ec2 describe-instances \
    --filters "Name=tag:Project,Values=NatureAtCloud" \
              "Name=instance-state-name,Values=running,pending,stopped,stopping" \
    --region "$AWS_REGION" \
    --query "Reservations[].Instances[].InstanceId" --output text)
IDS=$(echo "$IDS" | tr -d '\r')

if [ -z "$IDS" ] || [ "$IDS" = "None" ]; then
    info "Nenhuma instância para terminar."
else
    info "A terminar: $IDS"
    aws ec2 terminate-instances --instance-ids $IDS --region "$AWS_REGION" >/dev/null
    aws ec2 wait instance-terminated --instance-ids $IDS --region "$AWS_REGION"
    ok "Instâncias terminadas."
fi
rm -f "$WORKER_INSTANCE_IDS_FILE" "$LB_INSTANCE_ID_FILE" "$STATE_DIR/lb-ip.txt"

if [ "$DEEP" != "true" ]; then
    ok "Cleanup superficial concluído. Infra (SG/KeyPair/IAM/Dynamo/AMI) preservada."
    info "Para apagar TUDO:  ./99-cleanup.sh --deep"
    exit 0
fi

warn "DEEP CLEAN: vou apagar SGs, key pair, IAM roles, AMI worker e tabela DynamoDB."
read -r -p "Tens a certeza? (escreve YES) " CONFIRM
if [ "$CONFIRM" != "YES" ]; then info "Cancelado."; exit 0; fi

# --- 2) AMIs worker + snapshots associados ---
# Apaga TODAS as AMIs deste owner cujo nome comece por "cnv-worker-ami-",
# não apenas a registada em .state/. Isto evita acumulação de AMIs órfãs
# quando 03-create-ami.sh é re-executado e gera uma nova AMI.
info "A procurar AMIs do projecto (name=cnv-worker-ami-*)..."
ALL_AMIS=$(aws ec2 describe-images --owners self --region "$AWS_REGION" \
    --filters "Name=name,Values=cnv-worker-ami-*" \
    --query "Images[].ImageId" --output text 2>/dev/null || true)
for AMI_ID in $ALL_AMIS; do
    [ -z "$AMI_ID" ] && continue
    SNAPS=$(aws ec2 describe-images --image-ids "$AMI_ID" --region "$AWS_REGION" \
        --query "Images[0].BlockDeviceMappings[].Ebs.SnapshotId" --output text 2>/dev/null || true)
    aws ec2 deregister-image --image-id "$AMI_ID" --region "$AWS_REGION" 2>/dev/null \
        && ok "AMI $AMI_ID desregistada." || warn "Falha a desregistar AMI $AMI_ID."
    for s in $SNAPS; do
        [ -z "$s" ] && continue
        aws ec2 delete-snapshot --snapshot-id "$s" --region "$AWS_REGION" 2>/dev/null \
            && ok "  snapshot $s apagado." || true
    done
done
rm -f "$WORKER_AMI_ID_FILE"

# --- 3) Security Groups ---
for sg_name in "$WORKER_SG_NAME" "$LB_SG_NAME"; do
    sg_id=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=$sg_name" \
        --region "$AWS_REGION" --query "SecurityGroups[0].GroupId" --output text 2>/dev/null || echo "None")
    if [ -n "$sg_id" ] && [ "$sg_id" != "None" ]; then
        aws ec2 delete-security-group --group-id "$sg_id" --region "$AWS_REGION" 2>/dev/null \
            && ok "SG '$sg_name' apagado." || warn "Falha a apagar SG '$sg_name'."
    fi
done
rm -f "$WORKER_SG_ID_FILE" "$LB_SG_ID_FILE"

# --- 4) Key pair ---
aws ec2 delete-key-pair --key-name "$KEYPAIR_NAME" --region "$AWS_REGION" 2>/dev/null \
    && rm -f "$KEYPAIR_FILE" && ok "Key pair apagada." || true

# --- 5) IAM roles ---
remove_role() {
    local role="$1" has_profile="$2"
    local arns inline_policies
    # Detach managed policies
    arns=$(aws iam list-attached-role-policies --role-name "$role" \
        --query "AttachedPolicies[].PolicyArn" --output text 2>/dev/null || true)
    for p in $arns; do
        aws iam detach-role-policy --role-name "$role" --policy-arn "$p" 2>/dev/null || true
    done
    # Delete inline policies (e.g. CNV-AllowPassWorkerRole no LB Role)
    inline_policies=$(aws iam list-role-policies --role-name "$role" \
        --query "PolicyNames[]" --output text 2>/dev/null || true)
    for ip in $inline_policies; do
        aws iam delete-role-policy --role-name "$role" --policy-name "$ip" 2>/dev/null || true
    done
    if [ "$has_profile" = "true" ]; then
        aws iam remove-role-from-instance-profile --instance-profile-name "$role" --role-name "$role" 2>/dev/null || true
        aws iam delete-instance-profile --instance-profile-name "$role" 2>/dev/null || true
    fi
    aws iam delete-role --role-name "$role" 2>/dev/null && ok "Role '$role' apagada." || warn "Falha a apagar role '$role'."
}
remove_role "$LB_ROLE_NAME"     "true"
remove_role "$WORKER_ROLE_NAME" "true"
remove_role "$LAMBDA_ROLE_NAME" "false"

# --- 6) Lambda functions ---
for fn in cnv-fractals cnv-grayscott cnv-dna; do
    aws lambda delete-function --function-name "$fn" --region "$AWS_REGION" 2>/dev/null \
        && ok "Lambda '$fn' apagada." || true
done
rm -f "$STATE_DIR/lambda-role-arn.txt"

# --- 7) DynamoDB ---
aws dynamodb delete-table --table-name "$DYNAMO_TABLE_NAME" --region "$AWS_REGION" 2>/dev/null \
    && ok "Tabela DynamoDB apagada." || warn "Falha a apagar tabela DynamoDB."

ok "Deep clean concluído."

# --- 7) Verificação final ---
echo ""
info "Verificação final — EC2s restantes do projeto:"
REMAINING=$(aws ec2 describe-instances \
    --filters "Name=tag:Project,Values=NatureAtCloud" "Name=instance-state-name,Values=running,pending,stopping,stopped" \
    --region "$AWS_REGION" \
    --query "Reservations[].Instances[].[InstanceId,State.Name]" \
    --output text 2>/dev/null || true)
if [ -z "$REMAINING" ]; then
    ok "Nenhuma EC2 do projeto encontrada. Cleanup completo."
else
    warn "Ainda existem EC2s do projeto:"
    echo "$REMAINING"
fi
