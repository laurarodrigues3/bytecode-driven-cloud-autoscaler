#!/usr/bin/env bash
# Observa scale-down até MIN_WORKERS=1 (sem injectar carga).
set -uo pipefail
export AWS_SHARED_CREDENTIALS_FILE=${AWS_SHARED_CREDENTIALS_FILE:-/mnt/c/Users/laura/.aws/credentials}
export AWS_CONFIG_FILE=${AWS_CONFIG_FILE:-/mnt/c/Users/laura/.aws/config}
REGION=${AWS_REGION:-eu-west-1}

count_workers() {
  aws ec2 describe-instances \
    --filters "Name=tag:Project,Values=NatureAtCloud" \
              "Name=tag:Role,Values=worker" \
              "Name=instance-state-name,Values=running,pending" \
    --region "$REGION" \
    --query 'Reservations[].Instances[].InstanceId' --output text | wc -w
}

LB_IP=$(aws ec2 describe-instances \
  --filters "Name=tag:Project,Values=NatureAtCloud" \
            "Name=tag:Role,Values=loadbalancer" \
            "Name=instance-state-name,Values=running" \
  --region "$REGION" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)

# Garantir key
cp -f scripts/cnv-keypair.pem /tmp/cnv-keypair.pem
chmod 600 /tmp/cnv-keypair.pem
SSH="ssh -i /tmp/cnv-keypair.pem -o StrictHostKeyChecking=no -o ConnectTimeout=5 ec2-user@$LB_IP"

START_TS=$(date +%s)
DEADLINE=$((START_TS + 8*60))
LAST_AS_LINE=$($SSH "wc -l /opt/cnv/lb.log 2>/dev/null | awk '{print \$1}'" 2>/dev/null || echo 0)

echo "=== Watcher: scale-down até MIN_WORKERS=1 (max 8 min) ==="
echo "T=0  workers=$(count_workers)  startLogLine=$LAST_AS_LINE"

LAST_COUNT=99
while [ $(date +%s) -lt $DEADLINE ]; do
  ELAPSED=$(( $(date +%s) - START_TS ))
  W=$(count_workers)
  printf "T=%-3ds  workers=%d" "$ELAPSED" "$W"

  # Buscar linhas novas do log do LB com SCALE DOWN/UP/Workers
  NEW_LINES=$($SSH "tail -n +$((LAST_AS_LINE+1)) /opt/cnv/lb.log 2>/dev/null | grep -E '(SCALE DOWN|SCALE UP|Drenar|terminada|Workers=)' | tail -3" 2>/dev/null || echo "")
  if [ -n "$NEW_LINES" ]; then
    echo "  | log:"
    echo "$NEW_LINES" | sed 's/^/      /'
    LAST_AS_LINE=$($SSH "wc -l /opt/cnv/lb.log 2>/dev/null | awk '{print \$1}'" 2>/dev/null || echo "$LAST_AS_LINE")
  else
    echo
  fi

  if [ "$W" -le 1 ] && [ "$LAST_COUNT" -le 1 ]; then
    echo "✅ Atingiu MIN_WORKERS=1 e estabilizou."
    break
  fi
  LAST_COUNT=$W
  sleep 20
done

echo
echo "=== Estado final ==="
echo "workers running = $(count_workers)"
$SSH "grep -E '(SCALE DOWN|terminada)' /opt/cnv/lb.log | tail -10" 2>/dev/null
