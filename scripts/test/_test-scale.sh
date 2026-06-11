#!/usr/bin/env bash
# Fase 4.1 do runbook — força scale-up e regista evolução do número de workers.
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

list_workers() {
  aws ec2 describe-instances \
    --filters "Name=tag:Project,Values=NatureAtCloud" \
              "Name=tag:Role,Values=worker" \
              "Name=instance-state-name,Values=running,pending" \
    --region "$REGION" \
    --query 'Reservations[].Instances[].[InstanceId,State.Name,LaunchTime]' --output text
}

LB_IP=$(aws ec2 describe-instances \
  --filters "Name=tag:Project,Values=NatureAtCloud" \
            "Name=tag:Role,Values=loadbalancer" \
            "Name=instance-state-name,Values=running" \
  --region "$REGION" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
echo "LB_IP=$LB_IP"

BEFORE=$(count_workers)
echo "[BEFORE] workers = $BEFORE"
list_workers

echo "--- Lançar burst pesado durante 150s ---"
END=$(( $(date +%s) + 150 ))
ITER=0
while [ $(date +%s) -lt $END ]; do
  for i in 1 2 3 4 5; do
    curl -s -o /dev/null -m 60 "http://$LB_IP:8080/fractals?w=2000&h=2000&iterations=2000" &
  done
  ITER=$((ITER+1))
  if (( ITER % 5 == 0 )); then
    NOW=$(count_workers)
    echo "  t=$ITER*2s  workers=$NOW"
  fi
  sleep 2
done
echo "--- Aguardar curls em background terminarem (até 60s) ---"
# Damos algum tempo a terminar, mas matamos o que sobrar para não bloquear
sleep 30
for pid in $(jobs -pr); do
  kill -9 "$pid" 2>/dev/null || true
done
wait 2>/dev/null || true

AFTER=$(count_workers)
echo "[AFTER] workers = $AFTER"
list_workers

if (( AFTER > BEFORE )); then
  echo "✅ Scale-up detectado: $BEFORE -> $AFTER"
else
  echo "⚠️ AFTER == BEFORE; pode ser que o LB já tivesse o pool máximo, ou as requests não foram suficientes."
fi
