#!/usr/bin/env bash
# Smoke-test rápido do LB e da infra já existente.
set -uo pipefail
export AWS_SHARED_CREDENTIALS_FILE=${AWS_SHARED_CREDENTIALS_FILE:-/mnt/c/Users/laura/.aws/credentials}
export AWS_CONFIG_FILE=${AWS_CONFIG_FILE:-/mnt/c/Users/laura/.aws/config}
REGION=${AWS_REGION:-eu-west-1}

LB_IP=${1:-}
if [[ -z "$LB_IP" ]]; then
  LB_IP=$(aws ec2 describe-instances \
    --filters "Name=tag:Project,Values=NatureAtCloud" \
              "Name=tag:Role,Values=loadbalancer" \
              "Name=instance-state-name,Values=running" \
    --region "$REGION" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' --output text 2>/dev/null)
fi
echo "LB_IP=$LB_IP"

echo "--- 1) Root / (health, deve responder com 200) ---"
curl -s -m 5 -o /dev/null -w 'HTTP %{http_code} time=%{time_total}s\n' "http://$LB_IP:8080/" || echo "FAILED root"

echo "--- 2) /fractals small ---"
RESP=$(curl -s -m 30 "http://$LB_IP:8080/fractals?w=100&h=100&iterations=20")
echo "len=${#RESP} prefix=$(echo "$RESP" | head -c 50)"

echo "--- 3) /grayscott small ---"
RESP=$(curl -s -m 30 "http://$LB_IP:8080/grayscott?size=64&maxIterations=200")
echo "len=${#RESP} prefix=$(echo "$RESP" | head -c 50)"

echo "--- 4) /dna ---"
RESP=$(curl -s -m 30 "http://$LB_IP:8080/dna?seq1=seq1:ATGC&seq2=seq2:ATGC&minLength=2&stopOnFirst=false")
echo "len=${#RESP} prefix=$(echo "$RESP" | head -c 80)"

echo "--- 5) DynamoDB count ---"
aws dynamodb scan --table-name cnv-metrics --select COUNT --region "$REGION" --query Count --output text

echo "--- 6) Workers a responder directamente (porta 8000) ---"
WORKERS=$(aws ec2 describe-instances \
  --filters "Name=tag:Project,Values=NatureAtCloud" \
            "Name=tag:Role,Values=worker" \
            "Name=instance-state-name,Values=running" \
  --region "$REGION" \
  --query 'Reservations[].Instances[].PublicIpAddress' --output text)
for W in $WORKERS; do
  STATUS=$(curl -s -m 5 -o /dev/null -w '%{http_code}' "http://$W:8000/" 2>/dev/null || echo "TIMEOUT")
  echo "Worker $W:8000  ->  $STATUS"
done

echo "--- DONE ---"
