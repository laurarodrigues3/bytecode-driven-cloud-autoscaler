#!/usr/bin/env bash
# Fase 3.1 do runbook — validar que SSH está restrito ao IP do owner (não 0.0.0.0/0)
set -uo pipefail
export AWS_SHARED_CREDENTIALS_FILE=${AWS_SHARED_CREDENTIALS_FILE:-/mnt/c/Users/laura/.aws/credentials}
export AWS_CONFIG_FILE=${AWS_CONFIG_FILE:-/mnt/c/Users/laura/.aws/config}
REGION=${AWS_REGION:-eu-west-1}

for SG_NAME in cnv-worker-sg cnv-lb-sg; do
  echo "--- $SG_NAME ---"
  SG_ID=$(aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=$SG_NAME" \
    --region "$REGION" --query 'SecurityGroups[0].GroupId' --output text)
  echo "  Id: $SG_ID"

  echo "  Regras ingress (todas):"
  aws ec2 describe-security-groups --group-ids "$SG_ID" --region "$REGION" \
    --query 'SecurityGroups[0].IpPermissions[].[IpProtocol,FromPort,ToPort,IpRanges[].CidrIp|join(`,`,@)]' \
    --output table

  SSH_CIDRS=$(aws ec2 describe-security-groups --group-ids "$SG_ID" --region "$REGION" \
    --query 'SecurityGroups[0].IpPermissions[?FromPort==`22`].IpRanges[].CidrIp' --output text)
  echo "  SSH CIDRs: '$SSH_CIDRS'"

  if echo "$SSH_CIDRS" | grep -q '0.0.0.0/0'; then
    echo "  ❌ FAIL: SSH aberto ao mundo (0.0.0.0/0)"
  elif [[ -z "$SSH_CIDRS" ]]; then
    echo "  ⚠️  Sem regras SSH (talvez intencional para SG do LB)"
  else
    echo "  ✅ OK: SSH restrito a $SSH_CIDRS"
  fi
done
