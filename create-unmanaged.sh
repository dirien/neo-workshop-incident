#!/usr/bin/env bash
# Create the resource that no Pulumi program describes.
#
# This stands in for "somebody opened the console at 2am during an incident and
# never came back". It is created with the raw AWS CLI on purpose: nothing in
# demo/pulumi-ts mentions it, so it exists in the account and not in state.
#
# That is the whole point. Neo cannot find this by reading the program. It can
# only find it by running `aws` against the live account -- which is what a CLI
# integration is for.
#
# Run this BEFORE the session, during setup. Not live.
set -euo pipefail
cd "$(dirname "$0")"

SG_NAME="payments-db-emergency-access"
DB_ID=$(pulumi stack output dbIdentifier)

echo "Looking up the database's VPC..."
read -r VPC_ID EXISTING_SGS <<<"$(aws rds describe-db-instances \
    --db-instance-identifier "$DB_ID" \
    --query 'DBInstances[0].[DBSubnetGroup.VpcId, join(` `, VpcSecurityGroups[].VpcSecurityGroupId)]' \
    --output text)"

echo "  vpc: $VPC_ID"
echo "  existing security groups: $EXISTING_SGS"

if aws ec2 describe-security-groups --filters "Name=group-name,Values=$SG_NAME" \
    "Name=vpc-id,Values=$VPC_ID" --query 'SecurityGroups[0].GroupId' \
    --output text 2>/dev/null | grep -q '^sg-'; then
    echo "Already exists. Nothing to do -- run ./remove-unmanaged.sh first to recreate."
    exit 0
fi

echo "Creating the security group out-of-band..."
SG_ID=$(aws ec2 create-security-group \
    --group-name "$SG_NAME" \
    --vpc-id "$VPC_ID" \
    --description "temp access for payment incident - REMOVE AFTER" \
    --query 'GroupId' --output text)

# Open to the world on the Postgres port. This is the finding.
aws ec2 authorize-security-group-ingress \
    --group-id "$SG_ID" \
    --protocol tcp --port 5432 --cidr 0.0.0.0/0 \
    --no-cli-pager >/dev/null

# Tag it the way a hurried human would, so the story reads on screen.
aws ec2 create-tags --resources "$SG_ID" --tags \
    "Key=Name,Value=$SG_NAME" \
    "Key=CreatedBy,Value=console" \
    "Key=Note,Value=temporary - payments incident" \
    --no-cli-pager

echo "Attaching it to $DB_ID..."
aws rds modify-db-instance \
    --db-instance-identifier "$DB_ID" \
    --vpc-security-group-ids $EXISTING_SGS "$SG_ID" \
    --apply-immediately --no-cli-pager >/dev/null

echo
echo "Created $SG_ID ($SG_NAME) and attached it to $DB_ID."
echo
echo "It allows 0.0.0.0/0 on tcp/5432, and no Pulumi program mentions it."
echo "Confirm Pulumi does not know about it:"
echo "    pulumi stack --show-urns | grep -i security   # expect nothing"
echo
echo "Undo with ./remove-unmanaged.sh"
