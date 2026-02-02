import sys
from awsglue.transforms import *
from awsglue.utils import getResolvedOptions  # Fixed import
from pyspark.context import SparkContext
from awsglue.context import GlueContext
from awsglue.job import Job

# 1. Initialize Glue Context
args = getResolvedOptions(sys.argv, ['JOB_NAME', 'source_bucket', 'target_bucket']) # Fixed usage
sc = SparkContext()
glueContext = GlueContext(sc)
spark = glueContext.spark_session
job = Job(glueContext)
job.init(args['JOB_NAME'], args)

# 2. Read from RAW Bucket (JSON)
source_path = "s3://" + args['source_bucket'] + "/raw/"
target_path = "s3://" + args['target_bucket'] + "/"

# Read the JSON files
datasource0 = glueContext.create_dynamic_frame.from_options(
    format_options={"multiline": False},
    connection_type="s3",
    format="json",
    connection_options={"paths": [source_path], "recurse": True},
    transformation_ctx="datasource0"
)

# 3. Write to PROCESSED Bucket (Parquet)
datasink1 = glueContext.write_dynamic_frame.from_options(
    frame=datasource0,
    connection_type="s3",
    connection_options={"path": target_path},
    format="parquet",
    transformation_ctx="datasink1"
)

job.commit()