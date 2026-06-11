#!/usr/bin/env bash
# Recolhe logs do LB via SSH para validar Fases 3.2, 3.3, 4.3, 4.5 do runbook.
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

# Garante key com permissões correctas em /tmp (NTFS não permite chmod 600)
cp -f scripts/cnv-keypair.pem /tmp/cnv-keypair.pem
chmod 600 /tmp/cnv-keypair.pem

SSH="ssh -i /tmp/cnv-keypair.pem -o StrictHostKeyChecking=no -o ConnectTimeout=10 ec2-user@$LB_IP"

echo "=== Ficheiros de log no LB ==="
$SSH 'ls -la /var/log/cnv* /opt/cnv/lb.log 2>&1; echo; wc -l /opt/cnv/lb.log 2>/dev/null' || true

echo
echo "=== Header do log (init do LB / sem worker fantasma) ==="
$SSH 'cat /opt/cnv/lb.log 2>/dev/null | head -60'

echo
echo "=== Procura: Added worker | AWS mode | localhost:8000 ==="
$SSH "grep -E '(Added worker|AWS mode|localhost:8000|Pool inicial)' /opt/cnv/lb.log 2>/dev/null | head -40 || true"

echo
echo "=== Grace period (procura grace= e Health checks) ==="
$SSH "grep -E '(grace=|Health checks ignorados|Health checks started)' /opt/cnv/lb.log 2>/dev/null | head -30 || true"

echo
echo "=== Remoções de workers ==="
$SSH "grep -E '(Removendo|Removed)' /opt/cnv/lb.log 2>/dev/null | tail -20 || true"

echo
echo "=== ComplexityEstimator ==="
$SSH "grep 'ComplexityEstimator' /opt/cnv/lb.log 2>/dev/null | tail -25 || true"

echo
echo "=== AutoScaler — últimos 40 ==="
$SSH "grep 'AutoScaler' /opt/cnv/lb.log 2>/dev/null | tail -40 || true"

echo
echo "=== WorkerPool — últimos 20 ==="
$SSH "grep 'WorkerPool' /opt/cnv/lb.log 2>/dev/null | tail -20 || true"
