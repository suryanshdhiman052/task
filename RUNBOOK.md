# Catalog prod — Terraform runbook

Stack: VPC (public + private-app + private-db), ECS Fargate API, single-AZ RDS Postgres, HTTPS ALB, S3 assets, remote state in S3 + DynamoDB.

Layout: `modules/networking`, `modules/compute`, `modules/database` (assignment minimum) plus `modules/storage` for the assets bucket. `observability.tf` is root (SNS / EventBridge). `bootstrap/` creates the S3 state bucket + DynamoDB lock — that is **configure first**, not the environment apply. After `backend.hcl` exists, the VPC→ECS stack is **one** `terraform apply`.

## 0. Configure first (requirement 7)

| Need | Why |
|---|---|
| AWS account + IAM that can manage VPC, ECS, RDS, ALB, ACM, Route53, S3, IAM, Secrets Manager, ECR, SNS, events | First missing permission fails apply |
| Creds in the environment (`AWS_PROFILE` or access-key env vars). Nothing in tfvars. | No hardcoded secrets |
| Route53 **public** hosted zone + hostname (`api.yourdomain.com`) | ACM DNS validation + ALB alias |
| An ops email (`alert_email`) | SNS subscription is email; you must click Confirm |
| Terraform >= 1.6, AWS CLI v2, Docker (only when pushing `app/`) | |
| Remote state (`bootstrap/` once, then `backend.hcl`) | Requirement 4: S3 + DynamoDB lock |

Default region is `us-east-1`. Change it in **both** bootstrap and the root stack.

## 1. Clone, configure remote state, apply the environment

```bash
git clone git@github.com:suryanshdhiman052/task.git
cd task
aws sts get-caller-identity

# --- configure first (once per account) ---
terraform -chdir=bootstrap init
terraform -chdir=bootstrap apply
terraform -chdir=bootstrap output -raw backend_hcl > backend.hcl

cp terraform.tfvars.example terraform.tfvars
# set domain_name, hosted_zone_id, alert_email

# --- environment: init → plan → apply (one apply) ---
terraform init -backend-config=backend.hcl
terraform plan -out=prod.tfplan
terraform apply prod.tfplan
# terraform destroy   # when tearing down
```

`bootstrap/` creates a **versioned, AES256, public-blocked, TLS-only** bucket and a DynamoDB table hashed on `LockID`. It uses local state on purpose (a backend cannot create itself). Teammates clone, copy `backend.hcl`, and run **one** `terraform apply` for the environment. ACM stays `CREATE` until the validation CNAME appears (1–5 min). RDS is ~8–12 min.

First apply uses public `node:20.18-alpine` with an inline 8080 listener so the target group is healthy before anyone has pushed `app/`. The task **user is UID 1000** (validated once in root `variables.tf`, then passed into compute as `var.container_user`). `DB_HOST` is the private CNAME `postgres.<stack>.internal`, not the RDS endpoint. DB password never enters Terraform: `manage_master_user_password` writes Secrets Manager; the execution role can `GetSecretValue` on **that ARN only**.

Confirm the SNS email before you rely on alarms.

## 2. Point the service at the real API

```bash
chmod +x scripts/push-api.sh
./scripts/push-api.sh
```

Then in `terraform.tfvars`:

```hcl
container_image   = "<ecr_url>:<gitsha>"
container_command = []
health_path       = "/healthz"
```

`terraform apply` again. Tags are immutable; the script tags with the git SHA.

## 3. Destroy

```bash
terraform destroy                    # final RDS snapshot is forced
terraform -chdir=bootstrap destroy   # only if you also want the state bucket gone
```

`deletion_protection` is off so destroy matches the Terraform lifecycle you are supposed to demonstrate. Flip it to `true` in a real account.

Do **not** `terraform apply` against the original RDS identifier during an AZ outage (see §5).

---

## Budget ($150/mo) — what is in HCL

us-east-1 list, 730 h, quiet traffic:

| Piece | Choice | ~USD/mo |
|---|---|---|
| RDS | single-AZ `db.t4g.micro`, 20 GB gp3, no PI / enhanced monitoring | 12–16 |
| NAT | **one** NAT in `public[0]` | ~32 + data + $3.60 EIP |
| Interface endpoints | `ecr.api`, `ecr.dkr`, `secretsmanager` in **both app AZs** | ~22 (3 × $0.01/hr) |
| ALB | one internet-facing | ~16 + LCU |
| ECS | 256/512, **Fargate base 1 + Spot weight 1:1**, autoscaling 2–4 | 5–18 |
| Insights + logs + S3 + secrets | 14-day logs, S3 gateway (free) | 5–10 |
| **Total** | | **~$90–120** |

Autoscaling is `aws_appautoscaling_target` min=2 max=4 **plus** `aws_appautoscaling_policy` CPU 60% target tracking. A target with no policy does nothing. Spot reclaim: ECS replaces the task; extras split Spot/Fargate 1:1 so Spot scarcity does not dominate (`weight = 1` on both). `lifecycle.ignore_changes = [desired_count]` so the next apply does not fight the scaler.

A second NAT is **not** how we spend the remaining headroom: $0.045/hr × 730 = $32.85 + $3.60 extra EIP ≈ **$36.45 idle before bytes**. Two NATs + 2 EIPs ≈ $73. The current stack is already $90–120 with endpoints; two NATs plus NAT GB plus Spot falling back to on-demand (~$18 vs ~$5) blows the cap on a noisy month. A second NAT on the **shared** `aws_route_table.app` also still dies with AZ[0] — you would have to split route tables.

Multi-AZ `db.t3.small` is already ~$50–70 before NAT+ALB. That is why `multi_az = false`.

---

## 4. NAT AZ failure — detect, don't 5xx-alarm

Existing tasks keep serving RDS and the target group. ALB `HealthyHostCount` stays quiet. New placements fail because execution-role ECR + Secrets Manager used to go out through the single NAT.

Mitigation already in networking: interface endpoints in **both** app subnets for `ecr.api` / `ecr.dkr` / `secretsmanager`. Layers use the S3 gateway. `awslogs` still needs NAT (no logs endpoint — that would be another ~$7.30).

Detection (root `observability.tf`):

1. Container Insights `PendingTaskCount` ≥ 1 for 3 minutes → SNS.
2. EventBridge `ECS Task State Change` STOPPED with `CannotPullContainerError` or `ResourceInitializationError` → SNS (the NAT/endpoint fingerprint). Spot capacity looks like PENDING too; the EventBridge prefixes are what distinguish init failure.

Confirm the SNS email. Terraform cannot auto-confirm.

---

## 5. RDS AZ failure — restore runbook (do not ForceNew the dead instance)

`backup_retention_period = 7`, `backup_window = "07:00-08:00"` UTC, `multi_az = false`, `skip_final_snapshot = false`, `deletion_protection = false`.

**Do not** set `snapshot_identifier` on `aws_db_instance.this`. That attribute is ForceNew. Combined with `deletion_protection = false`, Terraform will `DeleteDBInstance` and wait on `catalog-prod-pg-final` against an instance in a **dead AZ**. That hang is how you miss the RTO.

Snapshots are regional. The instance can be down; the snapshot is still listable.

### RPO / RTO (put these on the incident ticket)

| Mode | RPO | RTO | Notes |
|---|---|---|---|
| Automated snapshot restore (this runbook) | **Up to 24 hours** | **~25–45 min** | Restore 20–40 min on 20 GB **plus** force-new-deployment **plus** ALB drain. TTL 30 is not RTO. Fail at 06:59 UTC and you restore yesterday's snapshot. |
| PITR (`restore-db-instance-to-point-in-time --use-latest-restorable-time`) | **~5 min** (WAL, 7-day retention) | same ~25–45 min | Not what `snapshot_identifier` does. Prefer PITR if the WAL window is intact. |
| Multi-AZ failover | n/a | n/a | **Not this stack.** There is no standby. Not 60 seconds. |

`deletion_protection = false` does **not** change restore time. It only makes it easy for `terraform apply` to delete `catalog-prod-pg` mid-incident.

Full API outage the whole window (`/healthz` postgres ping → 503). Unlike NAT, running tasks cannot keep serving.

### (1) Restore into the same subnet group (CLI)

```bash
FAILED_AZ=$(aws rds describe-db-instances --db-instance-identifier catalog-prod-pg \
  --query 'DBInstances[0].AvailabilityZone' --output text)

aws rds describe-db-subnet-groups --db-subnet-group-name catalog-prod-pg \
  --query 'DBSubnetGroups[0].Subnets[].SubnetAvailabilityZone.Name' --output text
# pick the AZ that is not $FAILED_AZ

SNAP=$(aws rds describe-db-snapshots --db-instance-identifier catalog-prod-pg \
  --snapshot-type automated \
  --query 'sort_by(DBSnapshots[?Status==`available`],&SnapshotCreateTime)[-1].DBSnapshotIdentifier' \
  --output text)

SG=$(aws rds describe-db-instances --db-instance-identifier catalog-prod-pg \
  --query 'DBInstances[0].VpcSecurityGroups[0].VpcSecurityGroupId' --output text)

aws rds restore-db-instance-from-db-snapshot \
  --db-instance-identifier catalog-prod-pg-restored \
  --db-snapshot-identifier "$SNAP" \
  --db-instance-class db.t4g.micro \
  --db-subnet-group-name catalog-prod-pg \
  --availability-zone "$HEALTHY_AZ" \
  --vpc-security-group-ids "$SG" \
  --db-parameter-group-name catalog-prod-pg16 \
  --no-multi-az --no-publicly-accessible --port 5432 --storage-type gp3 \
  --copy-tags-to-snapshot

aws rds wait db-instance-available --db-instance-identifier catalog-prod-pg-restored
NEW_HOST=$(aws rds describe-db-instances --db-instance-identifier catalog-prod-pg-restored \
  --query 'DBInstances[0].Endpoint.Address' --output text)
```

Password: `manage_master_user_password = true` and no rotation resource. The snapshot still has that password; the existing Secrets Manager ARN stays valid. If rotation was enabled after the snapshot, restore with `--manage-master-user-password` and switch the task to the new secret ARN (execution role `DbSecret` is pinned to one ARN).

Prefer PITR when the source instance is still describing:

```bash
aws rds restore-db-instance-to-point-in-time \
  --source-db-instance-identifier catalog-prod-pg \
  --target-db-instance-identifier catalog-prod-pg-restored \
  --use-latest-restorable-time \
  --db-instance-class db.t4g.micro \
  --db-subnet-group-name catalog-prod-pg \
  --availability-zone "$HEALTHY_AZ" \
  --vpc-security-group-ids "$SG" \
  --no-multi-az --no-publicly-accessible
```

### (2) Repoint ECS — flip the private CNAME, do not rewrite the task JSON

`DB_HOST` is `postgres.catalog-prod.internal` (`aws_route53_record.postgres`, TTL 30). It is **not** `module.database.address`. TTL 30 is **not** the failover time. Node `net.connect` / `dns.lookup` and libpq cache the resolved IP for the process and the connection. `/healthz` in `app/server.js` opens a new TCP socket each check, but c-ares / glibc can still return the dead AZ until the task is replaced. After CNAME UPSERT, **`update-service --force-new-deployment` is required**, not optional. Recycle is a reconnect, not a new env var.

Keep `aws_db_instance.this` in state. After the restored instance is `available`:

```bash
ZONE=$(aws route53 list-hosted-zones-by-name --dns-name catalog-prod.internal \
  --query 'HostedZones[0].Id' --output text)
aws route53 change-resource-record-sets --hosted-zone-id "$ZONE" --change-batch "{
  \"Changes\": [{\"Action\": \"UPSERT\", \"ResourceRecordSet\": {
    \"Name\": \"postgres.catalog-prod.internal\", \"Type\": \"CNAME\", \"TTL\": 30,
    \"ResourceRecords\": [{\"Value\": \"$NEW_HOST\"}]
  }}]
}"
```

Then bounce:

```bash
aws ecs update-service --cluster catalog-prod --service catalog-prod-api --force-new-deployment
```

New tasks resolve the CNAME; ALB drains old 503s (`interval=30`, `unhealthy_threshold=3`, ~90s). RTO is **restore 20–40 min + deploy bounce + drain**, not restore + 30s TTL. Without this CNAME, swapping host still required `terraform apply` plus a new task revision because the RDS hostname was frozen in `containerDefinitions`.

After the AZ is back: `terraform state rm module.database.aws_db_instance.this`, then `terraform import module.database.aws_db_instance.this catalog-prod-pg-restored`, then align `identifier` in a planned change. Do **not** apply a destroy of the original during the outage.

`delete_automated_backups = false` is why the 7 daily snapshots remain after you eventually remove the dead instance.

---

## Security that is in the code

- RDS `publicly_accessible = false`, db subnets have **no** `0.0.0.0/0` route, SG ingress is ECS on 5432 only.
- Task user is **UID 1000** (root `var.container_user` validation only; compute consumes it with no duplicate check). `readonlyRootFilesystem`, cap drop ALL, `privileged = false` (those do not set UID).
- Execution role: this log group, this ECR repo, this secret ARN. Task role: this assets bucket. Only `*` is `ecr:GetAuthorizationToken`.
- ALB HTTP → 301 HTTPS. `ELBSecurityPolicy-TLS13-1-2-2021-06`.
- State bucket: TLS-only policy, versioning, encryption, public access block. DynamoDB lock.

## Workflow

`init` → `plan` → `apply`. CI (`terraform.yml`) is fmt + `init -backend=false` + validate on bootstrap and root. No apply creds in CI.
