# Compute module

ECS Fargate service, ALB, ACM, ECR, IAM, and DNS for the API tier.

| File | Responsibility |
|------|----------------|
| `locals.tf` | Container definition JSON (UID from `var.container_user`, secrets, logging) |
| `ecr.tf` | ECR repository, scan-on-push, lifecycle policy |
| `acm.tf` | ACM certificate and DNS validation |
| `dns.tf` | Internal Route53 zone, postgres CNAME, public API alias |
| `alb.tf` | Application Load Balancer, target group, HTTP→HTTPS listeners |
| `iam.tf` | Execution and task IAM roles (scoped to specific ARNs) |
| `ecs.tf` | ECS cluster, task definition, service, autoscaling |

UID 1000 is validated once at the root `variables.tf` and passed in as `var.container_user`. This module does not re-validate or hardcode the UID.
