provider "aws" {
  region = "us-east-1"
}


# ==========================================
# RAW DATA ZONE
# ==========================================


resource "aws_s3_bucket" "raw_data" {
  bucket_prefix = "datalake-raw-"
  force_destroy = true 
}


resource "aws_s3_bucket_public_access_block" "raw_data_block" {
  bucket = aws_s3_bucket.raw_data.id

  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}


resource "aws_s3_bucket_server_side_encryption_configuration" "raw_data_encrypt" {
  bucket = aws_s3_bucket.raw_data.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# ==========================================
# PROCESSED DATA ZONE
# ==========================================


resource "aws_s3_bucket" "processed_data" {
  bucket_prefix = "datalake-processed-"
  force_destroy = true 
}


resource "aws_s3_bucket_public_access_block" "processed_data_block" {
  bucket = aws_s3_bucket.processed_data.id

  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}


resource "aws_s3_bucket_server_side_encryption_configuration" "processed_data_encrypt" {
  bucket = aws_s3_bucket.processed_data.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# ==========================================
# SECURITY LAYER (IAM FOR GLUE)
# ==========================================

# Create the Role for Glue
resource "aws_iam_role" "glue_crawler_role" {
  name = "AWSGlueServiceRole-DataLake"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "glue.amazonaws.com"
      }
    }]
  })
}

# Attach the "AWSGlueServiceRole" managed policy
resource "aws_iam_role_policy_attachment" "glue_service_attachment" {
  role       = aws_iam_role.glue_crawler_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole"
}

# Custom Policy: Allow Access to   Buckets
resource "aws_iam_policy" "s3_access_policy" {
  name        = "GlueS3AccessPolicy"
  description = "Allow Glue to read raw data and write processed data"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject", 
          "s3:PutObject", 
          "s3:ListBucket"
        ]
        Resource = [
          aws_s3_bucket.raw_data.arn,             # The Raw Bucket
          "${aws_s3_bucket.raw_data.arn}/*",      # Contents of Raw
          aws_s3_bucket.processed_data.arn,       # The Processed Bucket
          "${aws_s3_bucket.processed_data.arn}/*" # Contents of Processed
        ]
      }
    ]
  })
}

# Attach the Custom Policy to the Role
resource "aws_iam_role_policy_attachment" "s3_access_attachment" {
  role       = aws_iam_role.glue_crawler_role.name
  policy_arn = aws_iam_policy.s3_access_policy.arn
}


# ==========================================
# DATA CATALOG & CRAWLER
# ==========================================

# The Glue Database
resource "aws_glue_catalog_database" "datalake_db" {
  name = "security_logs_db"
}

# The Crawler
resource "aws_glue_crawler" "raw_data_crawler" {
  database_name = aws_glue_catalog_database.datalake_db.name
  name          = "security_log_crawler"
  role          = aws_iam_role.glue_crawler_role.arn

  s3_target {
    path = "s3://${aws_s3_bucket.raw_data.bucket}/raw"
  }
}


# ==========================================
# ANALYTICS LAYER (ATHENA)
# ==========================================

# Bucket for Athena Query Results
resource "aws_s3_bucket" "athena_results" {
  bucket_prefix = "athena-query-results-"
  force_destroy = true
}

resource "aws_s3_bucket_versioning" "athena_results_versioning" {
  bucket = aws_s3_bucket.athena_results.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "athena_results_encryption" {
  bucket = aws_s3_bucket.athena_results.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "athena_results_access" {
  bucket = aws_s3_bucket.athena_results.id

  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}



# Athena Workgroup (The Configuration)
resource "aws_athena_workgroup" "datalake_workgroup" {
  name = "datalake-workgroup"
  force_destroy = true

  configuration {
    result_configuration {
      output_location = "s3://${aws_s3_bucket.athena_results.bucket}/"
    }
  }
}


# ==========================================
# ETL LAYER (GLUE JOB)
# ==========================================

# Upload the Python script to the RAW bucket
resource "aws_s3_object" "etl_script" {
  bucket = aws_s3_bucket.raw_data.id
  key    = "scripts/etl_script.py" 
  source = "etl_script.py"         
  etag   = filemd5("etl_script.py") 
}

# Create the Glue Job
resource "aws_glue_job" "json_to_parquet" {
  name     = "json-to-parquet-job"
  role_arn = aws_iam_role.glue_crawler_role.arn # Re-using the same role

  command {
    name            = "glueetl"
    script_location = "s3://${aws_s3_bucket.raw_data.id}/scripts/etl_script.py"
    python_version  = "3"
  }


  default_arguments = {
    "--source_bucket" = aws_s3_bucket.raw_data.id
    "--target_bucket" = aws_s3_bucket.processed_data.id
    "--job-language"  = "python"
  }

  glue_version = "4.0"
  worker_type  = "G.1X" # Smallest worker type to save money
  number_of_workers = 2
}


# ==========================================
# PROCESSED DATA CRAWLER
# ==========================================

resource "aws_glue_crawler" "processed_data_crawler" {
  database_name = aws_glue_catalog_database.datalake_db.name
  name          = "processed-log-crawler"
  role          = aws_iam_role.glue_crawler_role.arn

  s3_target {
    path = "s3://${aws_s3_bucket.processed_data.bucket}"
  }
}