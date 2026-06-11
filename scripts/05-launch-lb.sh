#!/usr/bin/env bash
# =============================================================================
# 05-launch-lb.sh
# Lança a EC2 do Load Balancer e copia o JAR para lá.
# O LB arranca em foreground via nohup; o seu AutoScaler usa a AMI worker
# (criada em 03-create-ami.sh) para fazer scale up/down.
#
# Uso:
#   ./05-launch-lb.sh                       # LB sem workers iniciais (AutoScaler vai criar)
#   ./05-launch-lb.sh i-xxxx i-yyyy ...     # LB já apontando para workers existentes
# =============================================================================
set -euo pipefail
source "$(dirname "$0")/aws-config.sh"
test_aws_cli || exit 1

if [ ! -f "$LB_SG_ID_FILE" ];     then err "Corre 02-setup-network.sh primeiro."; exit 1; fi
if [ ! -f "$WORKER_AMI_ID_FILE" ];then err "Corre 03-create-ami.sh primeiro."; exit 1; fi
if [ ! -f "$WORKER_SG_ID_FILE" ]; then err "Corre 02-setup-network.sh primeiro."; exit 1; fi

LB_SG_ID=$(read_state "$LB_SG_ID_FILE")
WORKER_AMI_ID=$(read_state "$WORKER_AMI_ID_FILE")
WORKER_SG_ID=$(read_state "$WORKER_SG_ID_FILE")
ensure_base_ami || exit 1
ensure_my_ip_in_sg "$LB_SG_ID"
LB_JAR="$SCRIPT_DIR/../loadbalancer/target/loadbalancer-1.0.0-SNAPSHOT-jar-with-dependencies.jar"

if [ ! -f "$LB_JAR" ]; then
    err "JAR do LB em falta. Corre:  mvn clean package -DskipTests"
    exit 1
fi

# Argumentos opcionais: instance IDs de workers já existentes (para o LB conhecer ao arrancar)
WORKER_ARGS=""
if [ "$#" -gt 0 ]; then
    info "Workers existentes a registar no arranque: $*"
    for iid in "$@"; do
        ip=$(aws ec2 describe-instances --instance-ids "$iid" --region "$AWS_REGION" \
            --query "Reservations[0].Instances[0].PrivateIpAddress" --output text 2>/dev/null || echo "")
        ip=$(sanitize "$ip")
        if [ -n "$ip" ] && [ "$ip" != "None" ]; then
            WORKER_ARGS="$WORKER_ARGS $ip:$WORKER_PORT"
            info "  $iid -> $ip"
        fi
    done
fi

info "A lançar EC2 do LB..."
USER_DATA=$(cat <<'BOOTSTRAP'
#!/bin/bash
exec > /var/log/cnv-bootstrap.log 2>&1
dnf install -y java-11-amazon-corretto-headless
mkdir -p /opt/cnv && chown ec2-user:ec2-user /opt/cnv
BOOTSTRAP
)

LB_INSTANCE_ID=$(aws ec2 run-instances \
    --image-id "$BASE_AMI_ID" \
    --instance-type "$INSTANCE_TYPE" \
    --key-name "$KEYPAIR_NAME" \
    --security-group-ids "$LB_SG_ID" \
    --iam-instance-profile "Name=$LB_INSTANCE_PROFILE" \
    --user-data "$USER_DATA" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Project,Value=NatureAtCloud},{Key=Role,Value=loadbalancer}]" \
    --region "$AWS_REGION" \
    --query "Instances[0].InstanceId" --output text)
LB_INSTANCE_ID=$(sanitize "$LB_INSTANCE_ID")
ok "LB lançado: $LB_INSTANCE_ID"

aws ec2 wait instance-running --instance-ids "$LB_INSTANCE_ID" --region "$AWS_REGION"
LB_IP=$(aws ec2 describe-instances --instance-ids "$LB_INSTANCE_ID" --region "$AWS_REGION" \
    --query "Reservations[0].Instances[0].PublicIpAddress" --output text)
LB_IP=$(sanitize "$LB_IP")
printf '%s' "$LB_INSTANCE_ID" > "$LB_INSTANCE_ID_FILE"
printf '%s' "$LB_IP" > "$STATE_DIR/lb-ip.txt"

info "A aguardar SSH + Java instalado (~60s)..."
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10 -i "$KEYPAIR_FILE")
for i in {1..40}; do
    if ssh "${SSH_OPTS[@]}" "ec2-user@$LB_IP" "command -v java" >/dev/null 2>&1; then
        ok "Java instalado."
        break
    fi
    sleep 3
done

info "A copiar JAR do LB..."
scp "${SSH_OPTS[@]}" "$LB_JAR" "ec2-user@$LB_IP:/opt/cnv/loadbalancer.jar"

info "A arrancar LB em background..."
ssh "${SSH_OPTS[@]}" "ec2-user@$LB_IP" "nohup java \\
    -Daws.region=$AWS_REGION \
    -Dcnv.ami.id=$WORKER_AMI_ID \
    -Dcnv.worker.sg.id=$WORKER_SG_ID \
    -Dcnv.keypair.name=$KEYPAIR_NAME \
    -Dcnv.worker.instance.profile=$WORKER_INSTANCE_PROFILE \
    -Dcnv.instance.type=$INSTANCE_TYPE \
    -Dcnv.worker.port=$WORKER_PORT \
    -cp /opt/cnv/loadbalancer.jar pt.ulisboa.tecnico.cnv.loadbalancer.LoadBalancer $LB_PORT $WORKER_ARGS \
    > /opt/cnv/lb.log 2>&1 &"

ok ""
ok "============================================================"
ok " Load Balancer UP"
ok "   Instance ID : $LB_INSTANCE_ID"
ok "   Public IP   : $LB_IP"
ok "   Endpoint    : http://$LB_IP:$LB_PORT"
ok "============================================================"
ok ""
info "Teste do PC:"
echo "  curl \"http://$LB_IP:$LB_PORT/\"   # página de status"
echo "  curl \"http://$LB_IP:$LB_PORT/fractals?w=200&h=200&iterations=100\" --output fractal.png"
echo ""
info "Logs:"
echo "  ssh -i $KEYPAIR_FILE ec2-user@$LB_IP 'tail -f /opt/cnv/lb.log'"
