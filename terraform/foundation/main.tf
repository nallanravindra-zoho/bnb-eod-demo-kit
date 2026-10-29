# =====================================================================
# Foundation - applied the day BEFORE the demo and left running.
# Creates: CodePipeline (Source -> Test & Package -> Manual Approval -> Deploy),
#          2 CodeBuild projects, artifact bucket, and the read-only
#          "branch auditor" IAM user used for the AccessDenied moment.
# =====================================================================

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = { source = "hashicorp/aws", version = ">= 5.60, < 7.0" }
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
  default = "ap-south-1"
}

variable "connection_arn" {
  description = "ARN of the GitHub connection (Developer Tools > Settings > Connections), status must be Available"
  type        = string
}

variable "repository_id" {
  description = "GitHub repo as owner/name, e.g. ravinallan/bnb-eod-demo-kit"
  type        = string
}

variable "branch" {
  type    = string
  default = "main"
}

variable "function_name" {
  type    = string
  default = "bnb-eod-processor" # must match terraform/platform
}

data "aws_caller_identity" "current" {}

locals {
  account_id       = data.aws_caller_identity.current.account_id
  function_arn     = "arn:aws:lambda:${var.region}:${local.account_id}:function:${var.function_name}"
  processed_bucket = "bnb-eod-processed-${local.account_id}" # created later by platform/
  incoming_bucket  = "bnb-eod-incoming-${local.account_id}"
}

# ---------------- Artifact store ----------------
resource "aws_s3_bucket" "artifacts" {
  bucket        = "bnb-eod-pipeline-artifacts-${local.account_id}"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket                  = aws_s3_bucket.artifacts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ---------------- CodeBuild role ----------------
resource "aws_iam_role" "codebuild" {
  name = "bnb-eod-codebuild-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "codebuild.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "codebuild" {
  name = "codebuild-least-privilege"
  role = aws_iam_role.codebuild.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:GetObjectVersion", "s3:PutObject"]
        Resource = "${aws_s3_bucket.artifacts.arn}/*"
      },
      {
        Sid      = "DeployOnlyThisFunction"
        Effect   = "Allow"
        Action   = ["lambda:UpdateFunctionCode", "lambda:GetFunction", "lambda:GetFunctionConfiguration", "lambda:PublishVersion"]
        Resource = local.function_arn
      }
    ]
  })
}

resource "aws_codebuild_project" "test_package" {
  name          = "bnb-eod-test-and-package"
  description   = "Runs compliance unit tests and packages the Lambda"
  service_role  = aws_iam_role.codebuild.arn
  build_timeout = 10
  artifacts { type = "CODEPIPELINE" }
  environment {
    compute_type = "BUILD_GENERAL1_SMALL"
    image        = "aws/codebuild/standard:7.0"
    type         = "LINUX_CONTAINER"
  }
  source {
    type      = "CODEPIPELINE"
    buildspec = "buildspec.yml"
  }
}

resource "aws_codebuild_project" "deploy" {
  name          = "bnb-eod-deploy"
  description   = "Deploys the approved package to the production Lambda"
  service_role  = aws_iam_role.codebuild.arn
  build_timeout = 10
  artifacts { type = "CODEPIPELINE" }
  environment {
    compute_type = "BUILD_GENERAL1_SMALL"
    image        = "aws/codebuild/standard:7.0"
    type         = "LINUX_CONTAINER"
    environment_variable {
      name  = "FUNCTION_NAME"
      value = var.function_name
    }
  }
  source {
    type      = "CODEPIPELINE"
    buildspec = "buildspec-deploy.yml"
  }
}

# ---------------- CodePipeline role ----------------
resource "aws_iam_role" "pipeline" {
  name = "bnb-eod-pipeline-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "codepipeline.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "pipeline" {
  name = "pipeline-least-privilege"
  role = aws_iam_role.pipeline.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:GetObjectVersion", "s3:PutObject", "s3:GetBucketVersioning"]
        Resource = [aws_s3_bucket.artifacts.arn, "${aws_s3_bucket.artifacts.arn}/*"]
      },
      {
        Effect   = "Allow"
        Action   = ["codebuild:StartBuild", "codebuild:BatchGetBuilds"]
        Resource = [aws_codebuild_project.test_package.arn, aws_codebuild_project.deploy.arn]
      },
      {
        Effect   = "Allow"
        Action   = ["codestar-connections:UseConnection", "codeconnections:UseConnection"]
        Resource = var.connection_arn
      }
    ]
  })
}

# ---------------- The pipeline (Day 4) ----------------
resource "aws_codepipeline" "release" {
  name          = "bnb-eod-compliance-release"
  role_arn      = aws_iam_role.pipeline.arn
  pipeline_type = "V2"

  artifact_store {
    location = aws_s3_bucket.artifacts.bucket
    type     = "S3"
  }

  stage {
    name = "Source"
    action {
      name             = "Source"
      category         = "Source"
      owner            = "AWS"
      provider         = "CodeStarSourceConnection"
      version          = "1"
      output_artifacts = ["source_output"]
      configuration = {
        ConnectionArn    = var.connection_arn
        FullRepositoryId = var.repository_id
        BranchName       = var.branch
      }
    }
  }

  stage {
    name = "Test-and-Package"
    action {
      name             = "Unit-Tests"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      version          = "1"
      input_artifacts  = ["source_output"]
      output_artifacts = ["build_output"]
      configuration    = { ProjectName = aws_codebuild_project.test_package.name }
    }
  }

  stage {
    name = "Change-Approval"
    action {
      name     = "Compliance-Head-Approval"
      category = "Approval"
      owner    = "AWS"
      provider = "Manual"
      version  = "1"
      configuration = {
        CustomData = "Maker-checker: approve change to the high-value transaction review rule before it goes to production."
      }
    }
  }

  stage {
    name = "Deploy-to-Production"
    action {
      name            = "Update-Lambda"
      category        = "Build"
      owner           = "AWS"
      provider        = "CodeBuild"
      version         = "1"
      input_artifacts = ["build_output"]
      configuration   = { ProjectName = aws_codebuild_project.deploy.name }
    }
  }

  trigger {
    provider_type = "CodeStarSourceConnection"
    git_configuration {
      source_action_name = "Source"
      push {
        branches { includes = [var.branch] }
      }
    }
  }
}

# ---------------- Read-only branch auditor (Day 1/5: least privilege) ----------------
# Can READ the processed bucket only. Raw incoming files -> AccessDenied.
resource "aws_iam_user" "auditor" {
  name          = "bnb-branch-auditor"
  force_destroy = true
}

resource "aws_iam_user_login_profile" "auditor" {
  user                    = aws_iam_user.auditor.name
  password_length         = 20
  password_reset_required = false
}

resource "aws_iam_user_policy" "auditor" {
  name = "read-processed-only"
  user = aws_iam_user.auditor.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ConsoleBucketList"
        Effect   = "Allow"
        Action   = ["s3:ListAllMyBuckets", "s3:GetBucketLocation"]
        Resource = "*"
      },
      {
        Sid      = "ReadProcessedReports"
        Effect   = "Allow"
        Action   = ["s3:ListBucket", "s3:GetObject", "s3:GetObjectVersion"]
        Resource = ["arn:aws:s3:::${local.processed_bucket}", "arn:aws:s3:::${local.processed_bucket}/*"]
      },
      {
        Sid      = "DecryptWithEodKeyOnly"
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = "*"
        Condition = {
          "ForAnyValue:StringEquals" = { "kms:ResourceAliases" = "alias/bnb-eod-data" }
        }
      }
    ]
  })
}

output "pipeline_name" { value = aws_codepipeline.release.name }
output "auditor_username" { value = aws_iam_user.auditor.name }
output "auditor_signin_url" { value = "https://${local.account_id}.signin.aws.amazon.com/console" }
output "auditor_password" {
  value     = aws_iam_user_login_profile.auditor.password
  sensitive = true
}
