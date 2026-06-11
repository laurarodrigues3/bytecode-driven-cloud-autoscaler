#!/usr/bin/env bash
# =============================================================================
# Configuração partilhada para todos os scripts de provisionamento AWS.
# Source este ficheiro no topo de cada script:  source "$(dirname "$0")/aws-config.sh"
# =============================================================================

# --- Região AWS ---
# IMPORTANTE: todos os membros do grupo TÊM de usar a mesma região,
# caso contrário os recursos não se vêem entre si.
export AWS_REGION="${AWS_REGION:-eu-west-1}"

# --- Nomes lógicos dos recursos ---
export KEYPAIR_NAME="cnv-keypair"
export WORKER_SG_NAME="cnv-worker-sg"
export LB_SG_NAME="cnv-lb-sg"
export DYNAMO_TABLE_NAME="cnv-metrics"

export LB_ROLE_NAME="CNV-LoadBalancer-Role"
export LB_INSTANCE_PROFILE="CNV-LoadBalancer-Role"
export WORKER_ROLE_NAME="CNV-Worker-Role"
export WORKER_INSTANCE_PROFILE="CNV-Worker-Role"
export LAMBDA_ROLE_NAME="CNV-Lambda-ExecutionRole"

# --- Configuração das instâncias ---
export INSTANCE_TYPE="t3.micro"
# AMI base: resolvida em runtime via SSM Parameter Store (latest Amazon Linux 2023).
# Para forçar uma AMI específica, exporta BASE_AMI_ID antes de correr os scripts.
export BASE_AMI_ID="${BASE_AMI_ID:-}"

export WORKER_PORT=8000
export LB_PORT=8080

# --- Pasta de estado (não vai para git) ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export SCRIPT_DIR
export STATE_DIR="$SCRIPT_DIR/.state"
mkdir -p "$STATE_DIR"

# --- Ficheiros de output ---
# Store key in WSL home (chmod works on Linux FS, not on /mnt/c)
export KEYPAIR_FILE="$HOME/.ssh/$KEYPAIR_NAME.pem"
export WORKER_SG_ID_FILE="$STATE_DIR/worker-sg-id.txt"
export LB_SG_ID_FILE="$STATE_DIR/lb-sg-id.txt"
export WORKER_AMI_ID_FILE="$STATE_DIR/worker-ami-id.txt"
export WORKER_INSTANCE_IDS_FILE="$STATE_DIR/worker-instance-ids.txt"
export LB_INSTANCE_ID_FILE="$STATE_DIR/lb-instance-id.txt"

# --- Cores e helpers ---
if [ -t 2 ]; then
    C_INFO='\033[0;36m'; C_OK='\033[0;32m'; C_WARN='\033[0;33m'; C_ERR='\033[0;31m'; C_OFF='\033[0m'
else
    C_INFO=''; C_OK=''; C_WARN=''; C_ERR=''; C_OFF=''
fi

# Logs vão para stderr para não contaminarem $() captures.
info()  { echo -e "${C_INFO}[INFO]${C_OFF}    $*" >&2; }
ok()    { echo -e "${C_OK}[OK]${C_OFF}      $*" >&2; }
warn()  { echo -e "${C_WARN}[WARN]${C_OFF}    $*" >&2; }
err()   { echo -e "${C_ERR}[ERROR]${C_OFF}   $*" >&2; }

# --- Sanitização (workaround para AWS CLI em Git Bash que adiciona \r) ---
# Remove caracteres de controlo (\r, \n, \t, etc.) de uma string.
sanitize() { printf '%s' "$1" | tr -d '[:cntrl:]'; }
# Lê um ficheiro de estado removendo caracteres de controlo no caminho.
read_state() { [ -f "$1" ] && tr -d '[:cntrl:]' < "$1"; }

# Garante que o teu IP público actual está autorizado para SSH no SG dado.
# Idempotente — se a regra já existir, ignora o erro.
ensure_my_ip_in_sg() {
    local sg_id="$1"
    local my_ip
    my_ip=$(curl -fsS https://checkip.amazonaws.com 2>/dev/null | tr -d '[:space:]' || true)
    if [ -z "$my_ip" ]; then
        warn "Não consegui detectar o teu IP público; SSH pode falhar."
        return 0
    fi
    info "O teu IP actual: $my_ip — a garantir acesso SSH ao SG $sg_id"
    aws ec2 authorize-security-group-ingress \
        --group-id "$sg_id" --protocol tcp --port 22 \
        --cidr "$my_ip/32" --region "$AWS_REGION" >/dev/null 2>&1 || true
}

# Resolve a AMI base (latest Amazon Linux 2023) para a região actual via SSM
# Parameter Store — abordagem oficial recomendada pela AWS. Faz cache em
# .state/base-ami-id.txt para não chamar SSM em todas as execuções.
ensure_base_ami() {
    if [ -n "$BASE_AMI_ID" ]; then return 0; fi
    local cached="$STATE_DIR/base-ami-id.txt"
    if [ -f "$cached" ]; then
        BASE_AMI_ID=$(read_state "$cached")
        info "AMI base (cache): $BASE_AMI_ID"
        return 0
    fi
    local ami=""
    # Tentativa 1: SSM Parameter Store (oficial AWS).
    info "A resolver AMI base via SSM (Amazon Linux 2023)..."
    ami=$(aws ssm get-parameters \
        --names /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
        --region "$AWS_REGION" \
        --query 'Parameters[0].Value' --output text 2>&1)
    ami=$(sanitize "$ami")
    if [ -z "$ami" ] || [ "$ami" = "None" ] || [[ "$ami" == *"error"* ]] || [[ "$ami" == *"Error"* ]]; then
        warn "SSM falhou (output: $ami). A tentar fallback via describe-images..."
        # Tentativa 2: describe-images com filtro de nome.
        ami=$(aws ec2 describe-images \
            --owners amazon \
            --filters "Name=name,Values=al2023-ami-2023.*-x86_64" \
                      "Name=state,Values=available" \
                      "Name=architecture,Values=x86_64" \
            --region "$AWS_REGION" \
            --query "sort_by(Images,&CreationDate)[-1].ImageId" \
            --output text 2>&1)
        ami=$(sanitize "$ami")
    fi
    if [ -z "$ami" ] || [ "$ami" = "None" ] || [[ "$ami" != ami-* ]]; then
        err "Falha a resolver AMI base. Último output: '$ami'"
        err "Soluções:"
        err "  1. Verifica permissões SSM/EC2 do teu IAM user."
        err "  2. Procura manualmente uma AMI Amazon Linux 2023 em $AWS_REGION:"
        err "       aws ec2 describe-images --owners amazon \\"
        err "           --filters 'Name=name,Values=al2023-ami-2023.*-x86_64' \\"
        err "           --region $AWS_REGION --query 'sort_by(Images,&CreationDate)[-1].ImageId'"
        err "  3. Exporta antes do script:  export BASE_AMI_ID=ami-xxx"
        return 1
    fi
    BASE_AMI_ID="$ami"
    printf '%s' "$BASE_AMI_ID" > "$cached"
    info "AMI base resolvida: $BASE_AMI_ID"
}

test_aws_cli() {
    if ! command -v aws >/dev/null 2>&1; then
        err "AWS CLI não está instalado. Ver https://aws.amazon.com/cli/"
        return 1
    fi
    local identity
    if ! identity=$(aws sts get-caller-identity --output json 2>/dev/null); then
        err "AWS CLI não está configurado. Corre 'aws configure' primeiro."
        return 1
    fi
    local account arn
    account=$(echo "$identity" | grep -o '"Account": *"[^"]*"' | cut -d'"' -f4)
    arn=$(echo "$identity"     | grep -o '"Arn": *"[^"]*"'     | cut -d'"' -f4)
    info "Conta AWS: $account  User: $arn  Região: $AWS_REGION"
    return 0
}
