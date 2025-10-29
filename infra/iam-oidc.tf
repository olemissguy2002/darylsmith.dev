
resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

data "aws_iam_policy_document" "terraform_policy_doc" {
  statement {
    effect    = "Allow"
    actions   = ["s3:*", "cloudfront:CreateInvalidation", "cloudfront:GetDistribution", "cloudfront:GetDistributionConfig", "cloudfront:UpdateDistribution", "cloudfront:ListDistributions"]
    resources = ["*"]
  }
  statement {
    effect    = "Allow"
    actions   = ["route53:*", "acm:RequestCertificate", "acm:DescribeCertificate", "acm:ListCertificates", "acm:AddTagsToCertificate", "acm:DeleteCertificate"]
    resources = ["*"]
  }
  statement {
    effect    = "Allow"
    actions   = ["lambda:*", "apigateway:*", "dynamodb:*", "logs:*", "cloudwatch:*"]
    resources = ["*"]
  }
  statement {
    effect    = "Allow"
    actions   = ["iam:CreateRole", "iam:DeleteRole", "iam:GetRole", "iam:PassRole", "iam:PutRolePolicy", "iam:DeleteRolePolicy", "iam:AttachRolePolicy", "iam:DetachRolePolicy", "iam:CreatePolicy", "iam:DeletePolicy", "iam:GetPolicy", "iam:GetPolicyVersion", "iam:CreatePolicyVersion", "iam:DeletePolicyVersion", "iam:ListAttachedRolePolicies", "iam:ListRolePolicies", "iam:ListPolicyVersions"]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "terraform_policy" {
  name        = "CloudResumeTerraformPolicy"
  description = "Permissions for GitHub Actions to manage Cloud Resume stack"
  policy      = data.aws_iam_policy_document.terraform_policy_doc.json
}

data "aws_iam_policy_document" "gha_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = [
        "repo:olemissguy2002/darylsmith.dev:ref:refs/heads/*",  # pushes to main
        "repo:olemissguy2002/darylsmith.dev:pull_request",
        "repo:olemissguy2002/darylsmith.dev:environment:Production"          # PR workflows
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
