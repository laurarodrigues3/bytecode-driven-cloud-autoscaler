#!/usr/bin/env bash
# Identifica orphan instances (running na AWS mas não no pool do LB).
set -uo pipefail
export AWS_SHARED_CREDENTIALS_FILE=${AWS_SHARED_CREDENTIALS_FILE:-/mnt/c/Users/laura/.aws/credentials}
export AWS_CONFIG_FILE=${AWS_CONFIG_FILE:-/mnt/c/Users/laura/.aws/config}
REGION=${AWS_REGION:-eu-west-1}

LB_IP=$(aws ec2 describe-instances \
  --filters "Name=tag:Project,Values=NatureAtCloud" \
            "Name=tag:Role,Values=loadbalancer" \
            "Name=instance-state-name,Values=running" \
  --region "$REGION" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)

echo "=== Workers running na AWS (tag Role=worker) ==="
aws ec2 describe-instances \
  --filters "Name=tag:Project,Values=NatureAtCloud" \
            "Name=tag:Role,Values=worker" \
            "Name=instance-state-name,Values=running" \
  --region "$REGION" \
  --query 'Reservations[].Instances[].[InstanceId,PublicIpAddress,LaunchTime]' --output table

echo
echo "=== Workers no pool do LB (último Added / Removed grep) ==="
cp -f scripts/cnv-keypair.pem /tmp/cnv-keypair.pem
chmod 600 /tmp/cnv-keypair.pem
ssh -i /tmp/cnv-keypair.pem -o StrictHostKeyChecking=no ec2-user@$LB_IP \
  "echo '--- All Added/Removed events ---'; grep -E '(Added worker|Removed worker)' /opt/cnv/lb.log; echo; echo '--- Last AutoScaler line ---'; grep 'AutoScaler.*Workers=' /opt/cnv/lb.log | tail -1"
