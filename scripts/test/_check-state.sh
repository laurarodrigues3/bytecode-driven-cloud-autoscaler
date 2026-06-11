#!/usr/bin/env bash
# Helper temporário para inspeccionar estado AWS sem problemas de quoting do PowerShell.
set -uo pipefail
export AWS_SHARED_CREDENTIALS_FILE=${AWS_SHARED_CREDENTIALS_FILE:-/mnt/c/Users/laura/.aws/credentials}
export AWS_CONFIG_FILE=${AWS_CONFIG_FILE:-/mnt/c/Users/laura/.aws/config}
REGION=${AWS_REGION:-eu-west-1}

echo "--- IAM Roles (CNV) ---"
aws iam list-roles --query 'Roles[?contains(RoleName, `CNV`)].[RoleName]' --output text

echo "--- Instance Profiles (CNV) ---"
aws iam list-instance-profiles --query 'InstanceProfiles[?contains(InstanceProfileName, `CNV`)].[InstanceProfileName]' --output text

echo "--- EC2 (Project=NatureAtCloud) ---"
aws ec2 describe-instances \
  --filters "Name=tag:Project,Values=NatureAtCloud" \
            "Name=instance-state-name,Values=running,pending,stopping,stopped" \
  --region "$REGION" \
  --query 'Reservations[].Instances[].[InstanceId,State.Name,Tags[?Key==`Role`]|[0].Value,PublicIpAddress]' \
  --output table

echo "--- AMIs (self) ---"
aws ec2 describe-images --owners self --region "$REGION" \
  --query 'Images[].[ImageId,Name,State]' --output table

echo "--- Security Groups (cnv-*) ---"
aws ec2 describe-security-groups --filters "Name=group-name,Values=cnv-*" \
  --region "$REGION" --query 'SecurityGroups[].[GroupName,GroupId]' --output table

echo "--- Key Pair cnv-keypair ---"
aws ec2 describe-key-pairs --key-names cnv-keypair --region "$REGION" \
  --query 'KeyPairs[].KeyName' --output text 2>/dev/null || echo "(não existe)"

echo "--- DynamoDB cnv-metrics ---"
aws dynamodb describe-table --table-name cnv-metrics --region "$REGION" \
  --query 'Table.[TableName,TableStatus,ItemCount]' --output text 2>/dev/null || echo "(não existe)"
