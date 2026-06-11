#!/usr/bin/env bash
# =============================================================================
# 06-deploy-lambdas.sh
# Deploy (or update) the 3 Lambda functions for Nature@Cloud workloads.
# Idempotent: creates functions on first run, updates code on subsequent runs.
# =============================================================================
set -euo pipefail
source "$(dirname "$0")/aws-config.sh"
test_aws_cli || exit 1

LAMBDA_ROLE_ARN_FILE="$STATE_DIR/lambda-role-arn.txt"

# --- Resolve Lambda execution role ARN ---
if [ -f "$LAMBDA_ROLE_ARN_FILE" ]; then
    LAMBDA_ROLE_ARN=$(read_state "$LAMBDA_ROLE_ARN_FILE")
    info "Lambda role ARN (cache): $LAMBDA_ROLE_ARN"
else
    info "A resolver ARN da role '$LAMBDA_ROLE_NAME'..."
    LAMBDA_ROLE_ARN=$(aws iam get-role --role-name "$LAMBDA_ROLE_NAME" \
        --query "Role.Arn" --output text 2>/dev/null || true)
    LAMBDA_ROLE_ARN=$(sanitize "$LAMBDA_ROLE_ARN")
    if [ -z "$LAMBDA_ROLE_ARN" ] || [ "$LAMBDA_ROLE_ARN" = "None" ]; then
        err "Role '$LAMBDA_ROLE_NAME' nao encontrada. Corre 01-setup-iam.sh primeiro."
        exit 1
    fi
    printf '%s' "$LAMBDA_ROLE_ARN" > "$LAMBDA_ROLE_ARN_FILE"
    ok "Lambda role ARN resolvida: $LAMBDA_ROLE_ARN"
fi

# --- Project root (scripts/ is one level below root) ---
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# --- Deploy each workload ---
deploy_lambda() {
    local workload="$1"
    local handler="$2"
    local jar_path="$3"

    local func_name="cnv-${workload}"
    local abs_jar="$PROJECT_ROOT/$jar_path"

    if [ ! -f "$abs_jar" ]; then
        err "JAR nao encontrado: $abs_jar"
        err "Corre 'mvn package -DskipTests' primeiro."
        return 1
    fi

    info "A processar Lambda: $func_name"

    if aws lambda get-function --function-name "$func_name" --region "$AWS_REGION" >/dev/null 2>&1; then
        # Function exists — update code only.
        info "  Funcao '$func_name' ja existe. A atualizar codigo..."
        aws lambda update-function-code \
            --function-name "$func_name" \
            --zip-file "fileb://$abs_jar" \
            --region "$AWS_REGION" >/dev/null
        ok "  Codigo de '$func_name' atualizado."
    else
        # Create new function.
        info "  A criar funcao '$func_name'..."
        aws lambda create-function \
            --function-name "$func_name" \
            --runtime java11 \
            --role "$LAMBDA_ROLE_ARN" \
            --handler "$handler" \
            --zip-file "fileb://$abs_jar" \
            --memory-size 512 \
            --timeout 120 \
            --region "$AWS_REGION" \
            --tags "Project=NatureAtCloud" >/dev/null
        ok "  Funcao '$func_name' criada."
    fi
}

deploy_lambda "fractals" \
    "pt.ulisboa.tecnico.cnv.fractals.FractalsHandler::handleRequest" \
    "fractals/target/fractals-1.0.0-SNAPSHOT-jar-with-dependencies.jar"

deploy_lambda "grayscott" \
    "pt.ulisboa.tecnico.cnv.grayscott.GrayScottHandler::handleRequest" \
    "grayscott/target/grayscott-1.0.0-SNAPSHOT-jar-with-dependencies.jar"

deploy_lambda "dna" \
    "pt.ulisboa.tecnico.cnv.dna.DnaHandler::handleRequest" \
    "dna/target/dna-1.0.0-SNAPSHOT-jar-with-dependencies.jar"

ok "Todas as 3 Lambdas deployed/updated."
info "Verifica no console: https://${AWS_REGION}.console.aws.amazon.com/lambda/home?region=${AWS_REGION}#/functions"
