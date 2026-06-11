#!/usr/bin/env bash
# =============================================================================
# 03-create-ami.sh
# Cria uma AMI worker pré-configurada:
#   1. Lança EC2 temporária a partir do Amazon Linux 2023
#   2. Instala Java 11
#   3. Copia os JARs (webserver + javassist agent) para /opt/cnv
#   4. Instala um systemd unit que arranca o worker no boot
#   5. Cria a AMI (snapshot) e termina a EC2 temporária
#   6. Guarda o AMI ID em .state/worker-ami-id.txt
#
# Esta AMI é usada pelo AutoScaler em runInstances() — quando o LB decide
# fazer SCALE UP, o worker fica pronto a servir em ~30s sem intervenção.
# =============================================================================
set -euo pipefail
source "$(dirname "$0")/aws-config.sh"
test_aws_cli || exit 1

# --- 0) Pré-requisitos ---
WEBSERVER_JAR="$SCRIPT_DIR/../webserver/target/webserver-1.0.0-SNAPSHOT-jar-with-dependencies.jar"
AGENT_JAR="$SCRIPT_DIR/../javassist/target/javassist-agent-1.0.0-SNAPSHOT-jar-with-dependencies.jar"

if [ ! -f "$WEBSERVER_JAR" ] || [ ! -f "$AGENT_JAR" ]; then
    err "JARs em falta. Corre primeiro:  mvn clean package -DskipTests"
    err "  Esperava: $WEBSERVER_JAR"
    err "  Esperava: $AGENT_JAR"
    exit 1
fi
if [ ! -f "$WORKER_SG_ID_FILE" ]; then
    err "Worker SG não encontrado. Corre primeiro:  ./02-setup-network.sh"
    exit 1
fi
WORKER_SG_ID=$(read_state "$WORKER_SG_ID_FILE")
ensure_base_ami || exit 1
ensure_my_ip_in_sg "$WORKER_SG_ID"

# --- 1) Lançar EC2 temporária ---
info "A lançar EC2 temporária (builder)..."
BUILDER_ID=$(aws ec2 run-instances \
    --image-id "$BASE_AMI_ID" \
    --instance-type "$INSTANCE_TYPE" \
    --key-name "$KEYPAIR_NAME" \
    --security-group-ids "$WORKER_SG_ID" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Project,Value=NatureAtCloud},{Key=Role,Value=ami-builder}]" \
    --region "$AWS_REGION" \
    --query "Instances[0].InstanceId" --output text)
BUILDER_ID=$(sanitize "$BUILDER_ID")
ok "Builder lançado: $BUILDER_ID"

info "A aguardar estado 'running'..."
aws ec2 wait instance-running --instance-ids "$BUILDER_ID" --region "$AWS_REGION"

BUILDER_IP=$(aws ec2 describe-instances --instance-ids "$BUILDER_ID" \
    --region "$AWS_REGION" \
    --query "Reservations[0].Instances[0].PublicIpAddress" --output text)
BUILDER_IP=$(sanitize "$BUILDER_IP")
info "IP público: $BUILDER_IP"

# --- 2) Esperar que o SSH responda (máx ~4 min) ---
info "A aguardar SSH (Amazon Linux 2023 demora até ~3 min no primeiro arranque)..."
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10 -i "$KEYPAIR_FILE")
SSH_OK=false
for i in {1..80}; do
    if ssh "${SSH_OPTS[@]}" "ec2-user@$BUILDER_IP" "echo ok" >/dev/null 2>&1; then
        ok "SSH responde (após $i tentativas)."
        SSH_OK=true
        break
    fi
    if [ $((i % 10)) -eq 0 ]; then
        info "  ainda à espera... tentativa $i/80"
    fi
    sleep 3
done
if [ "$SSH_OK" != "true" ]; then
    err "Timeout SSH (4 min). Builder ainda viva: $BUILDER_ID @ $BUILDER_IP"
    err "Diagnóstico manual:"
    err "  ssh -v -i $KEYPAIR_FILE ec2-user@$BUILDER_IP"
    err "Quando acabares, termina a builder:"
    err "  aws ec2 terminate-instances --instance-ids $BUILDER_ID --region $AWS_REGION"
    exit 1
fi

# --- 3) Bootstrap remoto: Java + dir + systemd unit ---
info "A instalar Java 11 no builder..."
ssh "${SSH_OPTS[@]}" "ec2-user@$BUILDER_IP" "sudo dnf install -y java-11-amazon-corretto-headless && sudo mkdir -p /opt/cnv && sudo chown ec2-user:ec2-user /opt/cnv"

info "A copiar JARs (~80 MB no total)..."
scp "${SSH_OPTS[@]}" "$WEBSERVER_JAR" "ec2-user@$BUILDER_IP:/opt/cnv/webserver.jar"
scp "${SSH_OPTS[@]}" "$AGENT_JAR"     "ec2-user@$BUILDER_IP:/opt/cnv/javassist-agent.jar"

info "A instalar systemd unit cnv-worker.service..."
SYSTEMD_UNIT=$(cat <<UNIT
[Unit]
Description=CNV Worker (Nature@Cloud)
After=network.target

[Service]
Type=simple
User=ec2-user
WorkingDirectory=/opt/cnv
ExecStart=/usr/bin/java -javaagent:/opt/cnv/javassist-agent.jar -cp /opt/cnv/webserver.jar pt.ulisboa.tecnico.cnv.webserver.WebServer $WORKER_PORT
Restart=on-failure
StandardOutput=append:/var/log/cnv-worker.log
StandardError=append:/var/log/cnv-worker.log

[Install]
WantedBy=multi-user.target
UNIT
)

ssh "${SSH_OPTS[@]}" "ec2-user@$BUILDER_IP" "sudo tee /etc/systemd/system/cnv-worker.service > /dev/null <<'UNITEOF'
$SYSTEMD_UNIT
UNITEOF
sudo systemctl daemon-reload
sudo systemctl enable cnv-worker.service
sudo touch /var/log/cnv-worker.log && sudo chown ec2-user:ec2-user /var/log/cnv-worker.log
echo '[builder] cnv-worker.service instalado e enabled (não iniciado nesta builder).'"

ok "Builder preparado."

# --- 4) Criar AMI ---
AMI_NAME="cnv-worker-ami-$(date +%Y%m%d-%H%M%S)"
info "A criar AMI '$AMI_NAME'..."
AMI_ID=$(aws ec2 create-image \
    --instance-id "$BUILDER_ID" \
    --name "$AMI_NAME" \
    --description "Nature@Cloud worker pre-baked (Java 11 + JARs + systemd)" \
    --tag-specifications "ResourceType=image,Tags=[{Key=Project,Value=NatureAtCloud},{Key=Role,Value=worker-ami}]" \
    --region "$AWS_REGION" \
    --query "ImageId" --output text)
AMI_ID=$(sanitize "$AMI_ID")
ok "AMI a criar: $AMI_ID"

info "A aguardar AMI ACTIVE (pode demorar 2-5 min)..."
aws ec2 wait image-available --image-ids "$AMI_ID" --region "$AWS_REGION"
ok "AMI pronta: $AMI_ID"

# --- 5) Terminar builder ---
info "A terminar builder $BUILDER_ID..."
aws ec2 terminate-instances --instance-ids "$BUILDER_ID" --region "$AWS_REGION" >/dev/null
aws ec2 wait instance-terminated --instance-ids "$BUILDER_ID" --region "$AWS_REGION"
ok "Builder terminado."

# --- 6) Guardar AMI ID ---
printf '%s' "$AMI_ID" > "$WORKER_AMI_ID_FILE"
ok ""
ok "============================================================"
ok " AMI worker pronta!"
ok "   AMI ID  : $AMI_ID"
ok "   Ficheiro: $WORKER_AMI_ID_FILE"
ok "============================================================"
ok ""
info "Próximos passos:"
echo "  ./04-launch-worker.sh    # lança worker a partir desta AMI"
echo "  ./05-launch-lb.sh        # arranca o LB (que usa esta AMI no AutoScaler)"
