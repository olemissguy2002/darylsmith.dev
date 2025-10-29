data "aws_caller_identity" "current" {}

# Create only when explicitly enabled (local bootstrap). Default is off in CI.
resource "aws_iam_openid_connect_provider" "github" {
  count           = var.manage_oidc_provider ? 1 : 0
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

# Look up the existing provider (normal path for CI)
data "aws_iam_openid_connect_provider" "github" {
  arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/token.actions.githubusercontent.com"
}

# Resolve the OIDC provider ARN to use in the trust policy
locals {
  gha_oidc_arn = var.manage_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : data.aws_iam_openid_connect_provider.github.arn
}

data "aws_iam_policy_document" "terraform_policy_doc" {
  # S3 + CloudFront (+ OAC create)
  statement {
    effect  = "Allow"
    actions = [
      "s3:*",
      "cloudfront:CreateInvalidation",
      "cloudfront:GetDistribution",
      "cloudfront:GetDistributionConfig",
      "cloudfront:UpdateDistribution",
      "cloudfront:ListDistributions",
      "cloudfront:CreateOriginAccessControl",
      "cloudfront:TagResource"
    ]
    resources = ["*"]
  }

  # Route53 + ACM (add ListTagsForCertificate)
  statement {
    effect  = "Allow"
    actions = [
      "route53:*",
      "acm:RequestCertificate",
      "acm:DescribeCertificate",
      "acm:ListCertificates",
      "acm:AddTagsToCertificate",
      "acm:DeleteCertificate",
      "acm:ListTagsForCertificate"
    ]
    resources = ["*"]
  }

  # Lambda / API GW / DynamoDB / Logs
  statement {
    effect  = "Allow"
    actions = [
      "lambda:*",
      "apigateway:*",
      "dynamodb:*",
      "logs:*",
      "cloudwatch:*"
    ]
    resources = ["*"]
  }

  # IAM (but not OIDC provider creation)
  statement {
    effect  = "Allow"
    actions = [
      "iam:CreateRole","iam:DeleteRole","iam:GetRole","iam:PassRole",
      "iam:PutRolePolicy","iam:DeleteRolePolicy",
      "iam:AttachRolePolicy","iam:DetachRolePolicy",
      "iam:CreatePolicy","iam:DeletePolicy","iam:GetPolicy",
      "iam:GetPolicyVersion","iam:CreatePolicyVersion","iam:DeletePolicyVersion",
      "iam:ListAttachedRolePolicies","iam:ListRolePolicies","iam:ListPolicyVersions"
    ]
    resources = ["*"]
  }
}

# Avoid name collision by suffixing the policy name
resource "aws_iam_policy" "terraform_policy" {
  name        = "CloudResumeTerraformPolicy-${var.account_suffix}"
  description = "Permissions for GitHub Actions to manage Cloud Resume stack"
  policy      = data.aws_iam_policy_document.terraform_policy_doc.json
}

data "aws_iam_policy_document" "gha_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.gha_oidc_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Allow pushes to any branch, PRs, and env=Production in this repo
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:olemissguy2002/darylsmith.dev:ref:refs/heads/*",
        "repo:olemissguy2002/darylsmith.dev:pull_request",
        "repo:olemissguy2002/darylsmith.dev:environment:Production"
      ]
    }
  }
}

resource "aws_iam_role" "github_actions_role" {
  name                 = "CloudResume-GitHubActionsRole"
  assume_role_policy   = data.aws_iam_policy_document.gha_trust.json
  description          = "Role assumed by GitHub Actions via OIDC for CI/CD"
  max_session_duration = 3600
}

resource "aws_iam_role_policy_attachment" "attach_terraform_policy" {
  role       = aws_iam_role.github_actions_role.name
  policy_arn = aws_iam_policy.terraform_policy.arn
}

output "github_actions_role_arn" { value = aws_iam_role.github_actions_role.arn }
