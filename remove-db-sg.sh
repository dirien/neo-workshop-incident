#!/usr/bin/env bash
# Detach and delete the security group created by ./add-db-sg.sh.
# Safe to run repeatedly.
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
# The instance reports available before its network interface drops the old
# group, so the first delete can fail with DependencyViolation. Retry for ~3 min.
for i in $(seq 1 18); do
    if aws ec2 delete-security-group --group-id "$SG_ID" --no-cli-pager 2>/dev/null; then
        echo "Removed. Re-create with ./add-db-sg.sh"
        exit 0
    fi
    echo "  still attached to a network interface; retrying in 10s ($i/18)"
    sleep 10
done
echo "Could not delete $SG_ID after 3 minutes; delete it by hand." >&2
exit 1
