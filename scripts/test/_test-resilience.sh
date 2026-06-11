#!/usr/bin/env bash
# Fases 4.2 schema + 4.4 (health check remove worker morto) + 4.5 (scale-down).
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
echo "LB_IP=$LB_IP"

# === Fase 4.2 schema =====================================================
echo
echo "=== Fase 4.2 — DynamoDB schema ==="
COUNT=$(aws dynamodb scan --table-name cnv-metrics --select COUNT \
          --region "$REGION" --query Count --output text)
echo "Count = $COUNT"
echo "Sample (1 item, todos os atributos):"
aws dynamodb scan --table-name cnv-metrics --limit 1 --region "$REGION" \
  --output json | python3 -c "import json,sys; d=json.load(sys.stdin); items=d.get('Items',[]); print(json.dumps(items[0] if items else {}, indent=2))"

# === Fase 4.4 — Kill 1 worker ============================================
echo
echo "=== Fase 4.4 — Health check remove worker morto ==="
WORKER_IDS=( $(aws ec2 describe-instances \
  --filters "Name=tag:Project,Values=NatureAtCloud" \
            "Name=tag:Role,Values=worker" \
            "Name=instance-state-name,Values=running" \
  --region "$REGION" \
  --query 'Reservations[].Instances[].InstanceId' --output text) )

BEFORE=${#WORKER_IDS[@]}
echo "Workers running antes: $BEFORE  -> [${WORKER_IDS[*]}]"

if (( BEFORE < 2 )); then
  echo "⚠️ Só $BEFORE worker(s) running — saltar kill"
else
  KILL_ID="${WORKER_IDS[-1]}"
  echo "Vou matar: $KILL_ID"
  aws ec2 terminate-instances --instance-ids "$KILL_ID" --region "$REGION" \
    --query 'TerminatingInstances[].[InstanceId,CurrentState.Name]' --output text

  echo "A esperar ~50s para o LB detectar a falha (health check de 15s × 3 falhas)..."
  sleep 50

  echo "LB ainda serve pedidos? (3 curls)"
  for i in 1 2 3; do
    OK=$(curl -s -o /dev/null -w '%{http_code}' -m 30 "http://$LB_IP:8080/fractals?w=200&h=200&iterations=50")
    echo "  curl $i -> HTTP $OK"
  done
fi

# === Fase 4.5 — Scale-down ===============================================
echo
echo "=== Fase 4.5 — Scale-down (aguardar 4 min sem carga) ==="
echo "t=0  workers=$(count_workers)"
for MIN in 1 2 3 4; do
  sleep 60
  echo "t=${MIN}m  workers=$(count_workers)"
done

echo
echo "--- DynamoDB count final ---"
aws dynamodb scan --table-name cnv-metrics --select COUNT --region "$REGION" --query Count --output text
echo "DONE"
