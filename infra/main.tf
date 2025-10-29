terraform {
  required_version = ">= 1.6.0"
  required_providers {
    aws     = { source = "hashicorp/aws", version = "~> 5.0" }
    archive = { source = "hashicorp/archive", version = "~> 2.4" }
  }
}

# Providers
provider "aws" {
  region = var.aws_region
}

# CloudFront/ACM must be in us-east-1
provider "aws" {
  alias  = "use1"
  region = "us-east-1"
}

############################
# ACM certificate (managed)
############################
resource "aws_acm_certificate" "cert" {
  provider                  = aws.use1
  domain_name               = var.domain_name
  subject_alternative_names = ["www.${var.domain_name}"]
  validation_method         = "DNS"
}

resource "aws_route53_record" "cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.cert.domain_validation_options :
    dvo.domain_name => {
      name   = dvo.resource_record_name
      type   = dvo.resource_record_type
      record = dvo.resource_record_value
    }
  }
  zone_id         = var.hosted_zone_id
  name            = each.value.name
  type            = each.value.type
  ttl             = 60
  allow_overwrite = true
  records         = [each.value.record]
}

resource "aws_acm_certificate_validation" "cert_valid" {
  provider                = aws.use1
  certificate_arn         = aws_acm_certificate.cert.arn
  validation_record_fqdns = [for r in aws_route53_record.cert_validation : r.fqdn]
}

############################
# S3 (private site bucket)
############################
resource "aws_s3_bucket" "site" {
  bucket        = "resume-site-${var.account_suffix}"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "site_block" {
  bucket                  = aws_s3_bucket.site.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

############################
# CloudFront (OAC + distro)
############################
resource "aws_cloudfront_origin_access_control" "oac" {
  name                              = "oac-resume-site-${var.account_suffix}"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_distribution" "cdn" {
  provider            = aws.use1
  enabled             = true
  is_ipv6_enabled     = true
  price_class         = "PriceClass_100"
  default_root_object = "index.html"

  aliases = [var.domain_name, "www.${var.domain_name}"]

  origin {
    domain_name = aws_s3_bucket.site.bucket_regional_domain_name
    origin_id   = "s3-site-origin"

    # Keep S3OriginConfig (required in schema) even when using OAC
    s3_origin_config {
      origin_access_identity = ""
    }

    origin_access_control_id = aws_cloudfront_origin_access_control.oac.id
  }

  default_cache_behavior {
    target_origin_id       = "s3-site-origin"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]

    # AWS managed cache policy: CachingOptimized
    cache_policy_id = "658327ea-f89d-4fab-a63d-7e88639e58f6"
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate_validation.cert_valid.certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  depends_on = [aws_acm_certificate_validation.cert_valid]
}

# S3 bucket policy to allow CloudFront (via OAC) to read objects
resource "aws_s3_bucket_policy" "site" {
  bucket = aws_s3_bucket.site.id
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Sid : "AllowCloudFrontRead",
      Effect : "Allow",
      Principal : { Service : "cloudfront.amazonaws.com" },
      Action : "s3:GetObject",
      Resource : "${aws_s3_bucket.site.arn}/*",
      Condition : { StringEquals : { "AWS:SourceArn" : aws_cloudfront_distribution.cdn.arn } }
    }]
  })
}

############################
# Route53 A/ALIAS to CF
############################
resource "aws_route53_record" "root_a" {
  zone_id = var.hosted_zone_id
  name    = var.domain_name
  type    = "A"
  alias {
    name                   = aws_cloudfront_distribution.cdn.domain_name
    zone_id                = aws_cloudfront_distribution.cdn.hosted_zone_id
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "www_a" {
  zone_id = var.hosted_zone_id
  name    = "www.${var.domain_name}"
  type    = "A"
  alias {
    name                   = aws_cloudfront_distribution.cdn.domain_name
    zone_id                = aws_cloudfront_distribution.cdn.hosted_zone_id
    evaluate_target_health = false
  }
}

############################
# DynamoDB (counter)
############################
resource "aws_dynamodb_table" "counter" {
  name         = "resume-visitor-counter-${var.account_suffix}"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "pk"
  attribute {
    name = "pk"
    type = "S"
  }
}

resource "aws_dynamodb_table_item" "seed" {
  table_name = aws_dynamodb_table.counter.name
  hash_key   = aws_dynamodb_table.counter.hash_key
  item       = jsonencode({ pk = { S = "counter" }, count = { N = "0" } })
}

############################
# Lambda (Python 3.11)
############################
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../backend"
  output_path = "${path.module}/../backend.zip"
}

resource "aws_iam_role" "lambda_role" {
  name = "resume-counter-lambda-role-${var.account_suffix}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect : "Allow",
      Principal : { Service : "lambda.amazonaws.com" },
      Action : "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_policy" "ddb_policy" {
  name = "resume-ddb-access-${var.account_suffix}"
  policy = jsonencode({
    Version : "2012-10-17",
    Statement : [{
      Effect : "Allow",
      Action : ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem"],
      Resource : aws_dynamodb_table.counter.arn
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_ddb_attach" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = aws_iam_policy.ddb_policy.arn
}

resource "aws_lambda_function" "counter" {
  function_name = "resume-visitor-counter"
  role          = aws_iam_role.lambda_role.arn
  handler       = "app.handler"
  runtime       = "python3.11"
  filename      = data.archive_file.lambda_zip.output_path
  timeout       = 10
  environment {
    variables = {
      TABLE_NAME = aws_dynamodb_table.counter.name
    }
  }
  depends_on = [
    aws_iam_role_policy_attachment.lambda_basic,
    aws_iam_role_policy_attachment.lambda_ddb_attach
  ]
}

############################
# API Gateway v2 (HTTP API)
############################
resource "aws_apigatewayv2_api" "api" {
  name          = "resume-counter-api"
  protocol_type = "HTTP"
  cors_configuration {
    allow_methods = ["GET", "OPTIONS"]
    allow_origins = ["https://${var.domain_name}", "https://www.${var.domain_name}"]
    allow_headers = ["*"]
  }
}

resource "aws_apigatewayv2_integration" "lambda_int" {
  api_id                 = aws_apigatewayv2_api.api.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.counter.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "get_count" {
  api_id    = aws_apigatewayv2_api.api.id
  route_key = "GET /count"
  target    = "integrations/${aws_apigatewayv2_integration.lambda_int.id}"
}

resource "aws_lambda_permission" "apigw_invoke" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.counter.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.api.execution_arn}/*/*"
}

resource "aws_apigatewayv2_stage" "prod" {
  api_id      = aws_apigatewayv2_api.api.id
  name        = "$default"
  auto_deploy = true
}

############################
# Outputs
############################
output "site_url" {
  value = "https://${var.domain_name}"
}

output "api_url_example" {
  value = "${aws_apigatewayv2_api.api.api_endpoint}/count"
}

output "cloudfront_distribution_id" {
  value = aws_cloudfront_distribution.cdn.id
}
