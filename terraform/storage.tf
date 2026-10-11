# Data the platform keeps outside the cluster: Velero's backups and the demo
# tenant's secret. One key for both.

resource "aws_kms_key" "data" {
  description             = "${var.cluster_name}: Velero backups and Secrets Manager"
  deletion_window_in_days = 7
  enable_key_rotation     = true
}

resource "aws_kms_alias" "data" {
  name          = "alias/${var.cluster_name}-data"
  target_key_id = aws_kms_key.data.key_id
}

resource "aws_s3_bucket" "velero" {
  bucket        = "${var.cluster_name}-velero-${local.account_id}"
  force_destroy = var.velero_bucket_force_destroy
}

resource "aws_s3_bucket_ownership_controls" "velero" {
  bucket = aws_s3_bucket.velero.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "velero" {
  bucket                  = aws_s3_bucket.velero.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "velero" {
  bucket = aws_s3_bucket.velero.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "velero" {
  bucket = aws_s3_bucket.velero.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.data.arn
    }
    bucket_key_enabled = true
  }
}

# Velero expires backups itself (the schedule's ttl); this only clears the
# old versions S3 keeps after Velero deletes an object.
resource "aws_s3_bucket_lifecycle_configuration" "velero" {
  bucket = aws_s3_bucket.velero.id
  rule {
    id     = "expire-noncurrent"
    status = "Enabled"
    filter {}
    noncurrent_version_expiration {
      noncurrent_days = 30
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  depends_on = [aws_s3_bucket_versioning.velero]
}

resource "aws_s3_bucket_policy" "velero" {
  bucket = aws_s3_bucket.velero.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyInsecureTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource  = [aws_s3_bucket.velero.arn, "${aws_s3_bucket.velero.arn}/*"]
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }]
  })

  depends_on = [aws_s3_bucket_public_access_block.velero]
}

# The demo tenant's banner (apps/demo/base/message.yaml). Not a secret; it is
# here to prove the path from Secrets Manager into a pod works.
resource "aws_secretsmanager_secret" "demo_message" {
  name       = "demo/message"
  kms_key_id = aws_kms_key.data.arn
  # Deleted at once on destroy, so the next `make eks-up` can create the same
  # name instead of waiting out a recovery window.
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "demo_message" {
  secret_id     = aws_secretsmanager_secret.demo_message.id
  secret_string = "Served by the reference platform on EKS, through Envoy Gateway."
}
