# ElastiCache Redis Cross-Account Migration Guide

*A complete, automated solution for safely migrating Redis data between AWS accounts with zero downtime to your source cluster.*

## Overview

This guide helps you migrate ElastiCache Redis clusters between AWS accounts by creating a new cluster in the target account and populating it with data from your source cluster. This approach ensures zero data loss while maintaining full control over the migration timing.

## Migration Strategy

**What this solution does:**
- Takes a snapshot of your existing Redis cluster in the source account
- Exports the snapshot to S3 with proper permissions
- Copies the data cross-account to the target account's S3 bucket
- Creates a brand new Redis cluster in the target account using the imported data

**What this means for you:**
- Your source cluster remains unchanged and operational
- You can validate the new cluster before switching over
- No in-place migration risks or downtime until you're ready to switch

## Prerequisites & IAM Setup

### Required IAM Permissions

Both AWS accounts need specific permissions for the migration to work. Here's what each account needs:

**Source Account Permissions:**
- **ElastiCache**: Create and export snapshots
- **S3**: Create buckets and manage cross-account permissions
- **IAM**: Create roles for migration automation

**Target Account Permissions:**
- **ElastiCache**: Import snapshots and create new clusters
- **S3**: Read from source account buckets
- **IAM**: Create roles for migration automation

### The ElastiCache Canonical User

ElastiCache has a special requirement - it needs specific S3 permissions using something called a "canonical user ID". Think of this as ElastiCache's special identity for accessing S3 buckets.

```yaml
CanonicalUserId: "540804c33a284a299d2547575ce1010f2312ef3da9b3a053c8bc45bf233e4353"
Required Permissions: READ, WRITE, READ_ACP
```

The Canonical User Id may differ for GovCloud regions.  You can find more information here: https://docs.aws.amazon.com/AmazonElastiCache/latest/dg/backups-exporting.html

 The CloudFormation templates linked can handle this automatically, or provide a jump start for your own template.

## Step-by-Step Migration Process

### Step 1: Set Up Migration Infrastructure

First, we need to create S3 buckets and IAM roles in both accounts. These resources enable secure cross-account data transfer.

**In your source account:**
```bash
# This creates an S3 bucket with proper ElastiCache permissions
aws cloudformation create-stack \
  --stack-name source-migration-setup \
  --template-body file://3a-source-migration-setup.yaml \
  --parameters ParameterKey=TargetAccountId,ParameterValue=YOUR_TARGET_ACCOUNT_ID \
  --profile source-profile
```

**In your target account:**
```bash
# This creates an S3 bucket that can receive data from the source account
aws cloudformation create-stack \
  --stack-name target-migration-setup \
  --template-body file://3b-target-migration-setup.yaml \
  --parameters ParameterKey=SourceAccountId,ParameterValue=YOUR_SOURCE_ACCOUNT_ID \
  --profile target-profile
```

### Step 2: Configure Your Migration

Create a configuration file that tells the migration script about your environment:

```bash
# Copy the template
cp migration-config.yaml.template migration-config.yaml

# Edit it with your specific values
vim migration-config.yaml
```

The configuration file needs:
- Your AWS account IDs
- AWS CLI profile names for each account
- The names of your CloudFormation stacks
- The AWS region (must be the same for both accounts)

### Step 3: Run the Migration

Now for the magic - a single command that handles the entire migration:

```bash
./4-migrate-redis.sh migration-config.yaml
```

**What happens during migration:**

1. **📸 Snapshot Creation** - Creates a point-in-time backup of your source Redis cluster
2. **📤 Export to S3** - Exports the snapshot as an RDB file with proper permissions
3. **📋 Cross-Account Copy** - Securely copies the RDB file to the target account
4. **📥 Import & Restore** - Creates a new Redis cluster in the target account with your data

The script provides progress updates throughout the process.

```
Source Account                     Target Account
--------------                     --------------
1. Redis Cluster                   
2. Create Snapshot                 
3. Export to S3 -----------------> 4. Copy to Target S3
                                   5. Import to new Redis
                                   6. Validate data
```


### Step 4: Validate Your New Cluster

Before switching your applications to the new cluster, validate that the data migrated correctly:

```bash
# Deploy the validation Lambda function
aws cloudformation create-stack \
  --stack-name migration-validation \
  --template-body file://5-simple-validator.yaml \
  --parameters ParameterKey=TargetRedisEndpoint,ParameterValue=YOUR_NEW_REDIS_ENDPOINT \
  --profile target-profile

# Run the validation
aws lambda invoke \
  --function-name migration-validator \
  --payload '{}' \
  --profile target-profile \
  response.json

# Check the results
cat response.json
```

The validator checks:
- Connection to the new Redis cluster
- Presence of expected keys
- Data integrity and patterns

### Step 5: Clean Up Migration Resources

Once you've validated the migration and switched to the new cluster, clean up the temporary migration resources:

```bash
# This removes S3 buckets, IAM roles, and other migration resources
# but preserves your Redis clusters
./cleanup-all-migration.sh migration-config.yaml

# Want to see what will be deleted first?
./cleanup-all-migration.sh migration-config.yaml --dry-run
```

## Important Considerations

### Instance Type Requirements
⚠️ **Critical**: Your Redis instance must support persistence to create snapshots. 
- ✅ **Good**: r7g.large, r6g.large, m6g.large (support persistence)
- ❌ **Bad**: t3.micro, t4g.micro (no persistence support - data will be lost!)

### Timing Considerations
- **Snapshot creation**: Usually takes 5-15 minutes depending on data size
- **S3 transfer**: Varies based on RDB file size
- **Cluster restoration**: Similar to snapshot creation time
- **Total time**: Plan for 30-60 minutes for a typical migration

### Security Notes
- All S3 transfers use encryption
- Cross-account access uses temporary, least-privilege permissions
- No credentials are stored in scripts or configuration files

## Troubleshooting

**Migration script fails at snapshot export:**
- Check the ElastiCache canonical user ID is correct for your region
- Verify S3 bucket permissions were created successfully

**No data in target cluster:**
- Ensure you're using a persistence-capable instance type
- Check CloudFormation events for restore failures
- Verify the RDB file exists in the target S3 bucket

**Cannot connect to new cluster:**
- Verify security groups allow access from your application
- Check the new cluster is in the correct subnets
- Ensure the endpoint URL is updated in your application

## Full Documentation

For complete documentation, all templates, and source code:

📘 **[GitHub Repository](https://github.com/gopinaath/elasticache-redis-account2account)**

The repository includes:
- All CloudFormation templates with detailed comments
- Bash scripts for automation
- Python code for validation
- Advanced troubleshooting guides
- Security best practices
- Multi-region migration examples

## Wrapping Up

Congratulations! You now have a clear path to migrate your ElastiCache Redis clusters between AWS accounts. This solution takes care of the complex parts - like canonical user permissions and cross-account access - so you can focus on what matters: getting your data safely to its new home.

Remember, your source cluster stays running throughout the migration, giving you time to validate everything before making the switch. Take your time, test thoroughly, and don't hesitate to use the dry-run options to see what will happen before committing.

If you found this guide helpful or have suggestions for improvements, I'd love to hear from you! Feel free to open an issue or submit a pull request.

Happy migrating! 🚀

---

**GitHub**: [github.com/gopinaath/elasticache-redis-account2account](https://github.com/gopinaath/elasticache-redis-account2account)