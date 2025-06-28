# ElastiCache Redis Cross-Account Migration: A Complete Guide

Migrating ElastiCache Redis clusters between AWS accounts can be challenging, but with the right approach and automation, it becomes a streamlined process. This guide walks you through setting up migration infrastructure, executing the migration, and validating the results.

## Prerequisites

Before starting the migration, ensure you have:

- **AWS CLI** configured with profiles for both source and target accounts
- **Required tools**: `aws`, `jq`, `yq` installed on your system
- **IAM permissions** in both accounts for:
  - ElastiCache operations (create snapshots, restore clusters)
  - S3 bucket management and cross-account access
  - IAM role creation and management
- **Redis instance types** that support persistence (e.g., r7g.large, r6g.large)
  - ⚠️ **Important**: t3.micro does NOT support persistence and will lose data

## Migration Setup

### Source Account Setup

The source account needs an S3 bucket with specific ElastiCache canonical user permissions for RDB export operations:

```bash
aws cloudformation create-stack \
  --stack-name source-migration-setup \
  --template-body file://3a-source-migration-setup.yaml \
  --parameters \
    ParameterKey=TargetAccountId,ParameterValue=<target-account-id> \
  --profile source-profile \
  --region us-east-1
```

**Key Configuration**: The CloudFormation template automatically configures the critical canonical user ID permissions:

```yaml
# Critical: ElastiCache canonical user for RDB operations
CanonicalUserId: "540804c33a284a299d2547575ce1010f2312ef3da9b3a053c8bc45bf233e4353"
Permissions:
  - READ
  - WRITE  
  - READ_ACP
```

### Target Account Setup

The target account requires similar S3 infrastructure with cross-account access:

```bash
aws cloudformation create-stack \
  --stack-name target-migration-setup \
  --template-body file://3b-target-migration-setup.yaml \
  --parameters \
    ParameterKey=SourceAccountId,ParameterValue=<source-account-id> \
  --profile target-profile \
  --region us-east-1
```

## Migration Configuration

Create your migration configuration file:

```bash
cp migration-config.yaml.template migration-config.yaml
```

Configure the key parameters:

```yaml
migration:
  source:
    profile: "source-profile"
    region: "us-east-1"
    account_id: "<source-account-id>"
    infrastructure_stack_name: "elasticache-source-stack"
    migration_setup_stack_name: "source-migration-setup"
    
  target:
    profile: "target-profile"
    region: "us-east-1"  # Must match source region
    account_id: "<target-account-id>"
    infrastructure_stack_name: "elasticache-target-stack"
    migration_setup_stack_name: "target-migration-setup"
```

## Executing the Migration

The automated migration script handles the entire process:

```bash
./4-migrate-redis.sh migration-config.yaml
```

### Migration Process Overview

The script performs these key operations:

**1. Snapshot Creation**
```bash
# Creates manual snapshot of source Redis cluster
aws elasticache create-snapshot \
  --cache-cluster-id "$SOURCE_CLUSTER_ID" \
  --snapshot-name "$SNAPSHOT_NAME"
```

**2. RDB Export to S3**
```bash
# Exports snapshot to S3 with proper canonical user permissions
aws elasticache copy-snapshot \
  --source-snapshot-name "$SNAPSHOT_NAME" \
  --target-snapshot-name "$EXPORT_SNAPSHOT_NAME" \
  --target-bucket "$SOURCE_BUCKET"
```

**3. Cross-Account S3 Copy**
```bash
# Copies RDB file from source to target account bucket
aws s3 cp "s3://$SOURCE_BUCKET/$RDB_FILE" \
  "s3://$TARGET_BUCKET/$RDB_FILE" \
  --source-region "$REGION" \
  --region "$REGION"
```

**4. Target Redis Restoration**
```bash
# Creates new Redis cluster from imported RDB
aws elasticache create-cache-cluster \
  --cache-cluster-id "$TARGET_CLUSTER_ID" \
  --snapshot-name "$IMPORT_SNAPSHOT_NAME"
```

## Validation

### Deploy Validation Infrastructure

```bash
aws cloudformation create-stack \
  --stack-name migration-validation \
  --template-body file://5-simple-validator.yaml \
  --parameters \
    ParameterKey=TargetRedisEndpoint,ParameterValue=your-target-redis-endpoint \
    ParameterKey=VPCId,ParameterValue=your-vpc-id \
    ParameterKey=SubnetIds,ParameterValue=subnet-1,subnet-2 \
  --capabilities CAPABILITY_IAM \
  --profile target-profile \
  --region us-east-1
```

### Run Validation

The Lambda validator performs comprehensive data verification:

```bash
aws lambda invoke \
  --function-name migration-validator \
  --payload '{}' \
  --profile target-profile \
  --region us-east-1 \
  response.json
```

**Validation Logic** (from the Lambda function):
```python
def validate_migration(redis_client):
    # Check basic connectivity
    redis_client.ping()
    
    # Validate key patterns and data integrity
    sample_keys = redis_client.scan(match="*", count=100)
    
    # Verify data types and values
    for key in sample_keys:
        key_type = redis_client.type(key)
        # Validate based on data type (string, hash, list, etc.)
```

## Cleanup (Recommended)

### Complete Cleanup
Remove all migration resources while preserving your Redis clusters:

```bash
./cleanup-all-migration.sh migration-config.yaml
```

### Selective Cleanup Options

**Migration Resources Only** (S3, IAM, Lambda with 30-day S3 retention):
```bash
./cleanup-migration-resources.sh migration-config.yaml
```

**Validation Resources Only**:
```bash
./cleanup-validation-resources.sh migration-config.yaml
```

**Dry Run** (see what would be deleted):
```bash
./cleanup-all-migration.sh migration-config.yaml --dry-run
```

### Cleanup Process

The cleanup scripts intelligently remove resources:

```bash
# S3 bucket lifecycle for gradual deletion
aws s3api put-bucket-lifecycle-configuration \
  --bucket "$BUCKET_NAME" \
  --lifecycle-configuration '{
    "Rules": [{
      "Status": "Enabled",
      "ExpirationInDays": 30
    }]
  }'

# Remove CloudFormation stacks
aws cloudformation delete-stack \
  --stack-name "$MIGRATION_SETUP_STACK"
```

## Key Success Factors

1. **Canonical User IDs**: The solution automatically handles ElastiCache-specific S3 permissions
2. **Instance Types**: Use persistence-capable instances for successful data migration
3. **Cross-Account Permissions**: Automated S3 bucket policies handle secure cross-account access
4. **Validation**: Lambda-based validation ensures data integrity post-migration
5. **Cleanup**: Structured cleanup prevents resource sprawl and unexpected costs

This migration approach provides a production-ready, automated solution for ElastiCache Redis cross-account migrations with built-in validation and cleanup capabilities.

---

**Repository**: [elasticache-redis-account2account](https://github.com/gopinaath/elasticache-redis-account2account)
