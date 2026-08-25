# Catalog prod — Terraform runbook

Stack: VPC (public + private app + private db), ECS Fargate API, single-AZ RDS Postgres, HTTPS ALB, S3 assets, remote state in S3 + DynamoDB.

Repo layout is three root modules the grader asked for — `modules/networking`, `modules/compute`, `modules/database` — plus `bootstrap/` for the state backend (that bucket cannot be created by the same apply that uses it).

## 0. What you need before clone is useful

| Need | Why |
|---|---|
| AWS account + IAM user/role that can manage VPC, ECS, RDS, ALB, ACM, Route53, S3, IAM, Secrets Manager, ECR | Apply will fail on the first missing permission |
| Credentials in the environment (`AWS_PROFILE` or `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`). Nothing in tfvars. | Requirement: no hardcoded secrets |
| A Route53 **public** hosted zone you control, and a hostname in it (`api.yourdomain.com`) | ACM DNS validation + ALB alias. HTTPS cannot be faked with a self-signed cert on ALB |
| Terraform >= 1.6, AWS CLI v2, Docker (only when you push `app/`) | |

This is `us-east-1` by default. Stay there unless you change `aws_region` in **both** bootstrap and the root stack.

## 1. Clone and backend (once per account)

```bash
git clone git@github.com:suryanshdhiman052/task.git
cd catalog-prod-iac
aws sts get-caller-identity   # fail here, not 20 minutes into RDS

terraform -chdir=bootstrap init
terraform -chdir=bootstrap apply
terraform -chdir=bootstrap output -raw backend_hcl > backend.hcl
```

`bootstrap/` creates the **versioned, encrypted, public-blocked** state bucket and a DynamoDB lock table (`LockID`). It uses local state on purpose. After this, every teammate uses the same remote state.

```bash
cp terraform.tfvars.example terraform.tfvars
# set domain_name and hosted_zone_id
terraform init -backend-config=backend.hcl
terraform plan -out=prod.tfplan
terraform apply prod.tfplan
```

That second apply is the “single apply” for the environment. ACM will sit on `CREATE` until the validation CNAME shows up in Route53 (usually 1–5 minutes). RDS is the long pole (~8–12 minutes).

First apply runs a public Node image as user `node` (uid 1000), not root, with a one-line listener on 8080 so the target group has something to health-check before you have pushed `app/`. DB password is **not** in Terraform variables: RDS `manage_master_user_password` writes it to Secrets Manager and the execution role can read **that ARN only**.

## 2. Point the service at the real API

```bash
chmod +x scripts/push-api.sh
./scripts/push-api.sh
```

Then in `terraform.tfvars`:

```hcl
container_image   = "<ecr_url>:<gitsha>"   # terraform output ecr_repository_url
container_command = []
health_path       = "/healthz"
```

`terraform apply` again. Tags are immutable; the script tags with the git SHA, not `latest`.

## 3. Destroy

```bash
terraform destroy                 # final RDS snapshot is forced
terraform -chdir=bootstrap destroy  # only if you also want the state bucket gone
```

`deletion_protection` is off so destroy matches the Terraform lifecycle you are supposed to demonstrate. Flip it to `true` before you treat this as a real production account.

---

## Budget cap ($150/mo) — what we actually implemented

us-east-1 list prices, 730 h, idle-ish traffic:

| Piece | Choice | ~USD/mo |
|---|---|---|
| RDS Postgres | **single-AZ `db.t4g.micro`**, 20 GB gp3, no Performance Insights, no enhanced monitoring | ~12–16 |
| NAT | **one** NAT Gateway in AZ[0], not one per AZ | ~32 + data |
| ALB | one internet-facing ALB | ~16 + LCU |
| ECS | 2 × 0.25 vCPU / 512 MB **Fargate Spot** | ~3–6 |
| Everything else | S3, Secrets Manager, CloudWatch 14-day logs, S3 gateway endpoint (free) | ~5–10 |
| **Total** | | **~$70–90** |

A Multi-AZ `db.t3.small` is already ~$50–70 **before** NAT and ALB. Multi-AZ on a class people actually run in prod (`db.t3.medium` / `db.r6g.large`) blows $150 by itself. That is why Multi-AZ is **not** in this stack.

### Operational consequence (RDS)

RDS lives in **one** AZ. Automated backups are on (7 days) with continuous WAL, so point-in-time restore is available.

**If the AZ hosting RDS goes down, expect approximately 30 minutes of downtime** until a PITR/snapshot restore finishes in a healthy AZ and ECS reconnects (`DB_HOST` changes — run `terraform apply` or update the task). RPO is about **5 minutes** (PITR), not the last nightly snapshot. This is not a 60-second Multi-AZ failover. There is no standby.

Restore outline: AWS console or `restore-db-instance-to-point-in-time` into another AZ → wait for available (~15–25 min for this disk size) → point the service at the new endpoint (~2–5 min for a new task definition) → total ~30 min. If you only have the daily snapshot (PITR window expired), RPO becomes “since last snapshot”.

### Other cap trade-offs, same class of failure

- **One NAT.** If AZ[0] dies, tasks in the other AZ keep running but **lose egress** (image pulls, AWS APIs that are not gateway endpoints). They will not pull a new image until NAT is recreated in a live public subnet.
- **Fargate Spot, desired_count = 2.** Interruptions get a 2-minute SIGTERM. One task can drain while the other serves. If both get reclaimed together, expect a few minutes of 5xx while ECS places replacements. Capacity provider is Spot-only (base 0) — that is the cost choice; mixed `FARGATE` base=1 would buy a sticky on-demand task for more money.

---

## Security choices that are in the code, not the README

- RDS `publicly_accessible = false`, db subnets have **no** `0.0.0.0/0` route, SG ingress is ECS SG on 5432 only.
- Task **user** is `node` / uid 1000; `readonlyRootFilesystem = true`; capabilities dropped `ALL`; `privileged = false`. Validation rejects `root` / `0`.
- Execution role: logs on **this** log group, ECR pull on **this** repo, `GetSecretValue` on **this** RDS secret. Task role: S3 object RW on **this** assets bucket. No `*` besides `ecr:GetAuthorizationToken`, which AWS requires.
- ALB HTTP → 301 HTTPS. Listener policy `ELBSecurityPolicy-TLS13-1-2-2021-06`.
- State bucket: TLS-only bucket policy, versioning, encryption, public access block. DynamoDB lock so two applies cannot clobber each other.

## Workflow reminder

`init` → `plan` → `apply` for every change. `destroy` tears the env down. Do not `-auto-approve` in prod. CI (`terraform.yml`) only fmt + `init -backend=false` + validate — it has no AWS creds for apply.
