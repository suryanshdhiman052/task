# Security posture

This document describes the intentional security controls in the Terraform stack.

## Network isolation

| Tier | Subnets | Internet access | Ingress |
|------|---------|-----------------|---------|
| Public | 2 AZs | IGW | ALB: 80/443 from `0.0.0.0/0` only |
| App (ECS) | 2 AZs | NAT gateway (single AZ) + VPC endpoints | ALB SG only on `app_port` |
| DB (RDS) | 2 AZs | None (isolated route table) | ECS SG only on 5432 |

Security groups use **peer-by-reference** rules (no `0.0.0.0/0` on ECS or RDS). ECS egress to the internet is limited to TCP 443 (CloudWatch Logs and other AWS APIs via NAT). DNS egress is scoped to the VPC CIDR.

Interface VPC endpoints (`ecr.api`, `ecr.dkr`, `secretsmanager`) are placed in **both** app subnets so image pulls and secret retrieval survive a NAT AZ outage. An S3 gateway endpoint covers layer storage.

## IAM least privilege

| Role | Scoped permissions |
|------|-------------------|
| ECS execution | CloudWatch log group ARN, ECR repo ARN, DB secret ARN |
| ECS task | Assets bucket ARN + `/*` for Get/Put/Delete only |
| SNS publish | `events.amazonaws.com` and `cloudwatch.amazonaws.com` with `aws:SourceAccount` condition |

No wildcard S3, no `secretsmanager:*`, no hardcoded credentials. RDS password is managed by `manage_master_user_password` (Secrets Manager).

## Container hardening

- **UID 1000** enforced once at root via `var.container_user` validation; compute receives it as a module input (no re-validation).
- `readonlyRootFilesystem = true`
- `privileged = false`
- Linux capabilities: drop `ALL`
- `initProcessEnabled = true` for signal handling

## Storage encryption

- S3 assets bucket: SSE-S3 (AES256), public access blocked, TLS-only bucket policy.
- RDS: `storage_encrypted = true`, `rds.force_ssl = 1`, not publicly accessible.
- Remote state bucket (bootstrap): versioned, encrypted, public-blocked, TLS-only.

## ECR

- Immutable tags, scan-on-push enabled.
- Lifecycle policy expires untagged images after 7 days.

## Known trade-offs ($150 cap)

- Single-AZ RDS: AZ failure requires snapshot restore (see RUNBOOK §5).
- Single NAT gateway: AZ failure blocks private internet egress; endpoints mitigate ECR/secrets.
- Fargate Spot weighting (1:1 with on-demand for extras): Spot reclaim can cause brief task churn; 1 on-demand task always runs (`base = 1`).
