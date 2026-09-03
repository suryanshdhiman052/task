# Root on purpose: compute is ECS/ALB/IAM. ALB health will not catch NAT death.
data "aws_caller_identity" "current" {}

resource "aws_sns_topic" "ops" {
  name = "${var.project}-${var.environment}-ops"
}

resource "aws_sns_topic_subscription" "ops_email" {
  topic_arn = aws_sns_topic.ops.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

resource "aws_sns_topic_policy" "ops" {
  arn = aws_sns_topic.ops.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "AllowCloudWatchAndEventsPublish"
      Effect = "Allow"
      Principal = {
        Service = ["events.amazonaws.com", "cloudwatch.amazonaws.com"]
      }
      Action   = "sns:Publish"
      Resource = aws_sns_topic.ops.arn
      Condition = {
        StringEquals = {
          "aws:SourceAccount" = data.aws_caller_identity.current.account_id
        }
      }
    }]
  })
}

resource "aws_cloudwatch_metric_alarm" "ecs_pending" {
  alarm_name          = "${var.project}-${var.environment}-ecs-pending"
  alarm_description   = "PENDING tasks — NAT/ECR/Secrets Manager init path"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 3
  threshold           = 1
  metric_name         = "PendingTaskCount"
  namespace           = "ECS/ContainerInsights"
  period              = 60
  statistic           = "Maximum"
  treat_missing_data  = "notBreaching"
  dimensions = {
    ClusterName = module.compute.cluster_name
    ServiceName = module.compute.service_name
  }
  alarm_actions = [aws_sns_topic.ops.arn]
}

# NAT-down fingerprint: STOPPED + CannotPullContainerError / ResourceInitializationError.
resource "aws_cloudwatch_event_rule" "ecs_init_fail" {
  name = "${var.project}-${var.environment}-ecs-init-fail"
  event_pattern = jsonencode({
    source      = ["aws.ecs"]
    detail-type = ["ECS Task State Change"]
    detail = {
      clusterArn = [module.compute.cluster_arn]
      lastStatus = ["STOPPED"]
      stoppedReason = [
        { prefix = "CannotPullContainerError" },
        { prefix = "ResourceInitializationError" },
      ]
    }
  })
}

resource "aws_cloudwatch_event_target" "ecs_init_fail_sns" {
  rule       = aws_cloudwatch_event_rule.ecs_init_fail.name
  arn        = aws_sns_topic.ops.arn
  depends_on = [aws_sns_topic_policy.ops]
}

resource "aws_cloudwatch_metric_alarm" "rds_credits" {
  alarm_name          = "${var.project}-${var.environment}-rds-cpu-credits"
  alarm_description   = "t4g.micro credit exhaustion — throttle before 5xx"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 3
  threshold           = 20
  metric_name         = "CPUCreditBalance"
  namespace           = "AWS/RDS"
  period              = 300
  statistic           = "Average"
  treat_missing_data  = "notBreaching"
  dimensions = {
    DBInstanceIdentifier = module.database.identifier
  }
  alarm_actions = [aws_sns_topic.ops.arn]
}
