# ElastiCache Redis Cross-Account Migration Solution

This solution provides a complete, production-ready approach for migrating ElastiCache Redis clusters between AWS accounts.

## 📁 Solution Components

### 1. Infrastructure Templates
- **`1-source-infrastructure.yaml`** - Basic source account Redis cluster with optional demo app
- **`1-a-redis-data-loader.yaml`** - ✨ **Lambda function to load test data into existing Redis cluster**
- **`2-target-infrastructure.yaml`** - Target account VPC and supporting infrastructure (no Redis cluster)

### 2. Migration Setup Templates  
- **`3a-source-migration-setup.yaml`** - S3 bucket and IAM roles for source account
- **`3b-target-migration-setup.yaml`** - S3 bucket and IAM roles for target account

### 3. Migration Automation
- **`migration-config.yaml`** - Configuration file for migration parameters
- **`4-migrate-redis.sh`** - Automated migration script

### 4. Validation
- **`5-simple-validator.yaml`** - Lambda function for validating successful migration

### 5. Cleanup Scripts
- **`cleanup-migration-resources.sh`** - ✨ **Remove S3, IAM, Lambda migration setup (30-day S3 retention)**
- **`cleanup-validation-resources.sh`** - ✨ **Remove validation infrastructure and test resources**
- **`cleanup-all-migration.sh`** - ✨ **Master script for complete migration cleanup**

### 6. Documentation & Utilities
- **`verify-canonical-user.sh`** - ✨ **Script to verify canonical user ID validity**

**Note**: Additional documentation files (`CANONICAL-USER-GUIDE.md`, `ELASTICACHE-CANONICAL-IDS.md`) referenced in this README are planned but not yet created. The canonical user ID information is embedded in the CloudFormation templates.

## 🚀 Quick Start

### Prerequisites
- AWS CLI configured with profiles for both accounts
- Required tools: `aws`, `jq`, `yq`
- Sufficient IAM permissions in both accounts

### Step-by-Step Migration

#### 1️⃣ Deploy Source Infrastructure with Data Loader
```bash
aws cloudformation create-stack \
  --stack-name elasticache-source-stack \
  --template-body file://1-a-redis-data-loader.yaml \
  --parameters \
    ParameterKey=RedisEndpoint,ParameterValue=your-redis-endpoint \
    ParameterKey=VPCId,ParameterValue=your-vpc-id \
    ParameterKey=SubnetIds,ParameterValue=subnet-1,subnet-2 \
  --capabilities CAPABILITY_IAM \
  --profile source-profile \
  --region us-east-1
```

#### 1️⃣-alt Deploy Basic Source Infrastructure (without data loader)
```bash
aws cloudformation create-stack \
  --stack-name elasticache-source-stack \
  --template-body file://1-source-infrastructure.yaml \
  --parameters \
    ParameterKey=RedisNodeType,ParameterValue=cache.r7g.large \
    ParameterKey=EnablePersistence,ParameterValue=true \
    ParameterKey=EnableDemoApp,ParameterValue=true \
  --capabilities CAPABILITY_IAM \
  --profile source-profile \
  --region us-east-1
```

#### 2️⃣ Deploy Target Infrastructure
```bash
aws cloudformation create-stack \
  --stack-name elasticache-target-stack \
  --template-body file://2-target-infrastructure.yaml \
  --parameters \
    ParameterKey=EnableDemoApp,ParameterValue=true \
  --capabilities CAPABILITY_IAM \
  --profile target-profile \
  --region us-east-1
```

#### 3️⃣ Set Up Migration Resources
```bash
# Source account
aws cloudformation create-stack \
  --stack-name source-migration-setup \
  --template-body file://3a-source-migration-setup.yaml \
  --parameters \
    ParameterKey=TargetAccountId,ParameterValue=<target-account-id> \
  --profile source-profile \
  --region us-east-1

# Target account  
aws cloudformation create-stack \
  --stack-name target-migration-setup \
  --template-body file://3b-target-migration-setup.yaml \
  --parameters \
    ParameterKey=SourceAccountId,ParameterValue=<source-account-id> \
  --profile target-profile \
  --region us-east-1
```

#### 4️⃣ Configure and Run Migration
```bash
# Copy and edit migration configuration template
cp migration-config.yaml.template migration-config.yaml
vim migration-config.yaml

# Run migration
./4-migrate-redis.sh migration-config.yaml
```

#### 5️⃣ Validate Migration
```bash
# Deploy validation infrastructure
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

# Invoke validation Lambda
aws lambda invoke \
  --function-name migration-validator \
  --payload '{}' \
  --profile target-profile \
  --region us-east-1 \
  response.json
```

#### 6️⃣ Cleanup (Recommended)
```bash
# Complete cleanup of all migration resources (recommended)
./cleanup-all-migration.sh migration-config.yaml

# Or clean up specific components:
# Migration resources only (S3, IAM, Lambda)
./cleanup-migration-resources.sh migration-config.yaml

# Validation resources only (test infrastructure)
./cleanup-validation-resources.sh migration-config.yaml

# Dry run to see what would be deleted
./cleanup-all-migration.sh migration-config.yaml --dry-run
```

## 📋 Configuration File

Copy the template and customize for your environment:

```bash
cp migration-config.yaml.template migration-config.yaml
```

The `migration-config.yaml` file controls the entire migration process:

```yaml
migration:
  source:
    profile: "source-profile"      # AWS CLI profile
    region: "us-east-1"
    account_id: "<source-account-id>"
    infrastructure_stack_name: "elasticache-source-stack"
    migration_setup_stack_name: "source-migration-setup"
    
  target:
    profile: "target-profile"      # AWS CLI profile
    region: "us-east-1"           # Must match source
    account_id: "<target-account-id>"
    infrastructure_stack_name: "elasticache-target-stack"
    migration_setup_stack_name: "target-migration-setup"
```

## 🔍 Important Considerations

### ⚠️ **Critical: ElastiCache Canonical User Requirements**
ElastiCache RDB export/import operations require **specific S3 bucket ACL permissions** using canonical user IDs. This is **different** from regular IAM policies.

- **See**: CloudFormation templates for canonical user ID requirements
- **Canonical User ID**: `540804c33a284a299d2547575ce1010f2312ef3da9b3a053c8bc45bf233e4353`
- **Required Permissions**: READ, WRITE, READ_ACP on S3 buckets + READ on RDB files
- **Automated Setup**: Included in migration setup templates (`3a` & `3b`)

### Instance Type Requirements
- Use persistence-capable instance types (e.g., r7g.large, r6g.large)
- t3.micro does NOT support persistence and will lose data during migration

### Security
- All resources are deployed in private subnets
- Security groups restrict access appropriately
- S3 buckets have encryption and access controls

### Cross-Account Permissions
- The solution handles S3 bucket policies and ACLs automatically
- ElastiCache canonical IDs are region-specific and handled by templates

### Data Validation
- Lambda validation runs in the target VPC
- EC2 validation provides SSH/SSM access for manual checks
- Both options compare keys and data patterns

### Canonical User ID Verification
- **Verify canonical user IDs**: `./verify-canonical-user.sh us-east-1`
- **Test with dry-run**: `./verify-canonical-user.sh --dry-run --region us-east-1`
- **Enhanced error handling**: CloudFormation templates validate canonical user IDs automatically

## 🛠️ Troubleshooting

### Common Issues

1. **"Stack creation failed"**
   - Check IAM permissions
   - Verify parameter values
   - Review CloudFormation events

2. **"Snapshot export failed"**
   - Ensure S3 bucket has correct ACLs
   - Check ElastiCache canonical ID for region

3. **"No data in target Redis"**
   - Verify instance type supports persistence
   - Check S3 permissions were set correctly
   - Review ElastiCache events for restore status

### Debug Commands
```bash
# Check source Redis
aws elasticache describe-cache-clusters \
  --cache-cluster-id <cluster-id> \
  --show-cache-node-info \
  --profile source-profile

# Check S3 export
aws s3 ls s3://<export-bucket>/ \
  --profile source-profile

# Check target Redis events  
aws elasticache describe-events \
  --source-identifier <cluster-id> \
  --source-type cache-cluster \
  --profile target-profile
```

## 📊 Migration Flow

```
Source Account                     Target Account
--------------                     --------------
1. Redis Cluster                   
2. Create Snapshot                 
3. Export to S3 -----------------> 4. Copy to Target S3
                                   5. Import to new Redis
                                   6. Validate data
```

## 🔒 Security Best Practices

1. Use separate IAM roles for automation
2. Enable encryption for S3 buckets
3. Restrict security groups to minimum required access
4. Use VPC endpoints for AWS services when possible
5. Enable CloudTrail for audit logging

## 📝 License

This solution is provided as-is for demonstration purposes. Test thoroughly before using in production.