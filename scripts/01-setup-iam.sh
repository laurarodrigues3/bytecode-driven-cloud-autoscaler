#!/usr/bin/env bash
# =============================================================================
# 01-setup-iam.sh
# Cria as 3 IAM Roles do projecto + 2 Instance Profiles.
# Idempotente.
# =============================================================================
set -euo pipefail
source "$(dirname "$0")/aws-config.sh"
test_aws_cli || exit 1

EC2_TRUST=$(cat <<'JSON'
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}
JSON
)
LAMBDA_TRUST=$(cat <<'JSON'
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}
JSON
)

ensure_role() {
    local role_name="$1"
    local trust_json="$2"
    local create_profile="$3"  # "true"/"false"
    shift 3
    local policy_arns=("$@")

    info "A processar role: $role_name"
    if ! aws iam get-role --role-name "$role_name" >/dev/null 2>&1; then
        aws iam create-role \
            --role-name "$role_name" \
            --assume-role-policy-document "$trust_json" \
            --tags "Key=Project,Value=NatureAtCloud" >/dev/null
        ok "  Role '$role_name' criada."
    else
        info "  Role '$role_name' já existe."
    fi

    for arn in "${policy_arns[@]}"; do
        aws iam attach-role-policy --role-name "$role_name" --policy-arn "$arn" 2>/dev/null || true
        ok "  attached: $arn"
    done

    if [ "$create_profile" = "true" ]; then
        if ! aws iam get-instance-profile --instance-profile-name "$role_name" >/dev/null 2>&1; then
            aws iam create-instance-profile --instance-profile-name "$role_name" >/dev/null
            aws iam add-role-to-instance-profile --instance-profile-name "$role_name" --role-name "$role_name"
            ok "  instance-profile '$role_name' criado."
        else
            info "  instance-profile '$role_name' já existe."
        fi
    fi
}

# 1) Load Balancer Role
ensure_role "$LB_ROLE_NAME" "$EC2_TRUST" "true" \
    "arn:aws:iam::aws:policy/AmazonEC2FullAccess" \
    "arn:aws:iam::aws:policy/AmazonDynamoDBFullAccess" \
    "arn:aws:iam::aws:policy/AWSLambda_FullAccess" \
    "arn:aws:iam::aws:policy/CloudWatchLogsFullAccess"

# 2) Worker Role
ensure_role "$WORKER_ROLE_NAME" "$EC2_TRUST" "true" \
    "arn:aws:iam::aws:policy/AmazonDynamoDBFullAccess" \
    "arn:aws:iam::aws:policy/CloudWatchLogsFullAccess"

# 3) Lambda Execution Role
ensure_role "$LAMBDA_ROLE_NAME" "$LAMBDA_TRUST" "false" \
    "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole" \
    "arn:aws:iam::aws:policy/AmazonDynamoDBFullAccess"

# 4) Inline policy: o LB precisa de iam:PassRole para lançar EC2s worker
#    com o Worker Instance Profile (auto-scaling).
#    AmazonEC2FullAccess NÃO inclui PassRole por design (princípio do menor privilégio).
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
PASS_ROLE_POLICY=$(cat <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "iam:PassRole",
      "Resource": "arn:aws:iam::${ACCOUNT_ID}:role/${WORKER_ROLE_NAME}"
    }
  ]
}
JSON
)
aws iam put-role-policy \
    --role-name "$LB_ROLE_NAME" \
    --policy-name "CNV-AllowPassWorkerRole" \
    --policy-document "$PASS_ROLE_POLICY" >/dev/null
ok "  inline policy 'CNV-AllowPassWorkerRole' adicionada à $LB_ROLE_NAME"

# Persist Lambda role ARN for 06-deploy-lambdas.sh.
LAMBDA_ROLE_ARN=$(aws iam get-role --role-name "$LAMBDA_ROLE_NAME" \
    --query "Role.Arn" --output text)
LAMBDA_ROLE_ARN=$(sanitize "$LAMBDA_ROLE_ARN")
printf '%s' "$LAMBDA_ROLE_ARN" > "$STATE_DIR/lambda-role-arn.txt"
ok "  Lambda role ARN persistida: $LAMBDA_ROLE_ARN"

ok "IAM concluído. Aguarda ~10s antes de lançar EC2s (propagação IAM)."
