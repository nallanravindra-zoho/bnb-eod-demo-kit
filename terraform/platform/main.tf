# =====================================================================
# Bharat National Bank (fictional) - EOD processing platform
# Applied LIVE in Act 1 of the demo (~1 minute).
# Creates: KMS key, 2 encrypted S3 buckets, Secrets Manager secret,
#          Lambda + IAM role, S3 -> Lambda trigger, CloudWatch log group.
# =====================================================================

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws     = { source = "hashicorp/aws", version = ">= 5.60, < 7.0" }
    archive = { source = "hashicorp/archive", version = "~> 2.4" }
  }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = { Project = "bnb-eod-demo", ManagedBy = "terraform" }
  }
}

variable "region" {
  type    = string
  default = "ap-south-1" # Mumbai - data stays in India
}

variable "function_name" {
  type    = string
  default = "bnb-eod-processor"
}

data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  buckets = {
    incoming  = "bnb-eod-incoming-${local.account_id}"
    processed = "bnb-eod-processed-${local.account_id}"
  }
}

# ---------------- KMS: customer managed key (Day 5) ----------------
resource "aws_kms_key" "eod" {
  description             = "BNB - encrypts branch EOD transaction data"
  enable_key_rotation     = true
  deletion_window_in_days = 7
}

resource "aws_kms_alias" "eod" {
  name          = "alias/bnb-eod-data" # referenced by the auditor policy in foundation/
  target_key_id = aws_kms_key.eod.key_id
}

# ---------------- S3 buckets (Day 2) ----------------
resource "aws_s3_bucket" "this" {
  for_each      = local.buckets
  bucket        = each.value
  force_destroy = true # demo only: lets terraform destroy empty the bucket
}

resource "aws_s3_bucket_versioning" "this" {
  for_each = aws_s3_bucket.this
  bucket   = each.value.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  for_each = aws_s3_bucket.this
  bucket   = each.value.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.eod.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "this" {
  for_each                = aws_s3_bucket.this
  bucket                  = each.value.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ---------------- Secrets Manager (Day 5) ----------------
resource "aws_secretsmanager_secret" "compliance_api" {
  name                    = "bnb/compliance-api-key"
  description             = "API key for the (fictional) compliance case system"
  kms_key_id              = aws_kms_key.eod.arn
  recovery_window_in_days = 0 # demo only: allows immediate re-create after destroy
}

resource "aws_secretsmanager_secret_version" "compliance_api" {
  secret_id     = aws_secretsmanager_secret.compliance_api.id
  secret_string = jsonencode({ api_key = "BNB-DEMO-7F3A-91C2-A8D4" })
}

# ---------------- IAM role for Lambda: least privilege (Day 1/5) ----------------
resource "aws_iam_role" "lambda" {
  name = "${var.function_name}-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "lambda" {
  name = "least-privilege"
  role = aws_iam_role.lambda.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadIncomingOnly"
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "${aws_s3_bucket.this["incoming"].arn}/*"
      },
      {
        Sid      = "WriteProcessedOnly"
        Effect   = "Allow"
        Action   = ["s3:PutObject"]
        Resource = "${aws_s3_bucket.this["processed"].arn}/*"
      },
      {
        Sid      = "UseEodKey"
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource = aws_kms_key.eod.arn
      },
      {
        Sid      = "ReadComplianceSecret"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = aws_secretsmanager_secret.compliance_api.arn
      },
      {
        Sid      = "WriteLogs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.lambda.arn}:*"
      }
    ]
  })
}

# ---------------- Lambda (Day 4) ----------------
resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${var.function_name}"
  retention_in_days = 7
}

data "archive_file" "lambda" {
  type        = "zip"
  source_dir  = "${path.module}/../../lambda"
  output_path = "${path.module}/build/lambda.zip"
  excludes    = ["__pycache__"]
}

resource "aws_lambda_function" "processor" {
  function_name    = var.function_name
  description      = "Validates branch EOD files and flags high-value transactions"
  role             = aws_iam_role.lambda.arn
  runtime          = "python3.12"
  handler          = "handler.lambda_handler"
  timeout          = 30
  memory_size      = 256
  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256

  environment {
    variables = {
      PROCESSED_BUCKET      = aws_s3_bucket.this["processed"].id
      COMPLIANCE_SECRET_ARN = aws_secretsmanager_secret.compliance_api.arn
    }
  }

  # After creation, CODE changes are owned by CodePipeline, not Terraform.
  lifecycle {
    ignore_changes = [filename, source_code_hash]
  }

  depends_on = [aws_iam_role_policy.lambda, aws_cloudwatch_log_group.lambda]
}

# ---------------- S3 event -> Lambda trigger ----------------
resource "aws_lambda_permission" "s3" {
  statement_id   = "AllowS3Invoke"
  action         = "lambda:InvokeFunction"
  function_name  = aws_lambda_function.processor.function_name
  principal      = "s3.amazonaws.com"
  source_arn     = aws_s3_bucket.this["incoming"].arn
  source_account = local.account_id
}

resource "aws_s3_bucket_notification" "incoming" {
  bucket = aws_s3_bucket.this["incoming"].id
  lambda_function {
    lambda_function_arn = aws_lambda_function.processor.arn
    events              = ["s3:ObjectCreated:*"]
    filter_suffix       = ".csv"
  }
  depends_on = [aws_lambda_permission.s3]
}

# ---------------- Outputs ----------------
output "incoming_bucket" { value = aws_s3_bucket.this["incoming"].id }
output "processed_bucket" { value = aws_s3_bucket.this["processed"].id }
output "lambda_function" { value = aws_lambda_function.processor.function_name }
output "kms_key_alias" { value = aws_kms_alias.eod.name }
output "upload_command" {
  value = "aws s3 cp sample-data/branch_0457_eod.csv s3://${aws_s3_bucket.this["incoming"].id}/eod/ --region ${var.region}"
}
