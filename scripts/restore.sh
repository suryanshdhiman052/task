#!/usr/bin/env bash
# Restore catalog-prod-pg from the latest *automated* snapshot after an AZ loss.
# Do NOT terraform apply against aws_db_instance.this during the outage:
# snapshot_identifier is ForceNew; deletion_protection=false + skip_final_snapshot=false
# will DeleteDBInstance and wait on catalog-prod-pg-final in the dead AZ.
set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
SRC="${SRC:-catalog-prod-pg}"
DST="${DST:-catalog-prod-pg-restored}"
CLASS="${CLASS:-db.t4g.micro}"
ZONE_DNS="${ZONE_DNS:-catalog-prod.internal}"
CNAME="${CNAME:-postgres.catalog-prod.internal}"

aws sts get-caller-identity >/dev/null

FAILED_AZ=$(aws rds describe-db-instances --region "$REGION" \
  --db-instance-identifier "$SRC" \
  --query 'DBInstances[0].AvailabilityZone' --output text)

mapfile -t AZS < <(aws rds describe-db-subnet-groups --region "$REGION" \
  --db-subnet-group-name "$SRC" \
  --query 'DBSubnetGroups[0].Subnets[].SubnetAvailabilityZone.Name' --output text | tr '\t' '\n')

HEALTHY_AZ=""
for az in "${AZS[@]}"; do
  if [[ "$az" != "$FAILED_AZ" ]]; then HEALTHY_AZ="$az"; break; fi
done
[[ -n "$HEALTHY_AZ" ]] || { echo "no second AZ in subnet group $SRC"; exit 1; }

SNAP=$(aws rds describe-db-snapshots --region "$REGION" \
  --db-instance-identifier "$SRC" --snapshot-type automated \
  --query 'sort_by(DBSnapshots[?Status==`available`],&SnapshotCreateTime)[-1].DBSnapshotIdentifier' \
  --output text)
[[ "$SNAP" != "None" && -n "$SNAP" ]] || { echo "no available automated snapshot"; exit 1; }

SG=$(aws rds describe-db-instances --region "$REGION" \
  --db-instance-identifier "$SRC" \
  --query 'DBInstances[0].VpcSecurityGroups[0].VpcSecurityGroupId' --output text)

echo "src=$SRC failed_az=$FAILED_AZ healthy_az=$HEALTHY_AZ snap=$SNAP dst=$DST"

aws rds restore-db-instance-from-db-snapshot --region "$REGION" \
  --db-instance-identifier "$DST" \
  --db-snapshot-identifier "$SNAP" \
  --db-instance-class "$CLASS" \
  --db-subnet-group-name "$SRC" \
  --availability-zone "$HEALTHY_AZ" \
  --vpc-security-group-ids "$SG" \
  --db-parameter-group-name catalog-prod-pg16 \
  --no-multi-az --no-publicly-accessible --port 5432 --storage-type gp3 \
  --copy-tags-to-snapshot

echo "waiting for $DST available (this is most of the downtime)..."
aws rds wait db-instance-available --region "$REGION" --db-instance-identifier "$DST"

NEW_HOST=$(aws rds describe-db-instances --region "$REGION" \
  --db-instance-identifier "$DST" \
  --query 'DBInstances[0].Endpoint.Address' --output text)

ZONE=$(aws route53 list-hosted-zones-by-name --dns-name "$ZONE_DNS" \
  --query 'HostedZones[0].Id' --output text)
ZONE="${ZONE##*/}"

aws route53 change-resource-record-sets --hosted-zone-id "$ZONE" --change-batch "{
  \"Changes\": [{\"Action\": \"UPSERT\", \"ResourceRecordSet\": {
    \"Name\": \"$CNAME\", \"Type\": \"CNAME\", \"TTL\": 30,
    \"ResourceRecords\": [{\"Value\": \"$NEW_HOST\"}]
  }}]
}"

echo "CNAME $CNAME -> $NEW_HOST (TTL 30)."
echo "TTL does not fail over Node/libpq caches. Bounce is required:"
aws ecs update-service --region "$REGION" --cluster catalog-prod --service catalog-prod-api --force-new-deployment
echo "RTO = restore wait + this deployment + ALB drain, not TTL 30."
echo "After the AZ returns: terraform state rm module.database.aws_db_instance.this && terraform import module.database.aws_db_instance.this $DST"
echo "Do not destroy $SRC during the outage."
