#!/usr/bin/env bash
# Detach and delete the out-of-band security group created by
# ./create-unmanaged.sh. Safe to run repeatedly.
set -euo pipefail
cd "$(dirname "$0")"

SG_NAME="payments-db-emergency-access"
DB_ID=$(pulumi stack output dbIdentifier)

read -r VPC_ID <<<"$(aws rds describe-db-instances \
    --db-instance-identifier "$DB_ID" \
    --query 'DBInstances[0].DBSubnetGroup.VpcId' --output text)"

SG_ID=$(aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=$SG_NAME" "Name=vpc-id,Values=$VPC_ID" \
    --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || true)

if [[ -z "$SG_ID" || "$SG_ID" == "None" ]]; then
    echo "No $SG_NAME in $VPC_ID. Nothing to do."
    exit 0
fi

REMAINING=$(aws rds describe-db-instances \
    --db-instance-identifier "$DB_ID" \
    --query "join(\` \`, DBInstances[0].VpcSecurityGroups[?VpcSecurityGroupId!='$SG_ID'].VpcSecurityGroupId)" \
    --output text)

if [[ -n "$REMAINING" ]]; then
    echo "Detaching $SG_ID from $DB_ID..."
    aws rds modify-db-instance \
        --db-instance-identifier "$DB_ID" \
        --vpc-security-group-ids $REMAINING \
        --apply-immediately --no-cli-pager >/dev/null

    echo "Waiting for the instance to finish modifying (a security-group swap"
    echo "is quick, but delete-security-group fails while it is still attached)..."
    aws rds wait db-instance-available --db-instance-identifier "$DB_ID"
fi

echo "Deleting $SG_ID..."
aws ec2 delete-security-group --group-id "$SG_ID" --no-cli-pager
echo "Removed. Re-create with ./create-unmanaged.sh"
