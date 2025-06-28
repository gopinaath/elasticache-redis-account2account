#!/bin/bash

# ElastiCache Redis Cross-Account Migration Script
# This script automates the migration process based on migration-config.yaml

set -e

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Logging functions
log_info() {
    echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')] INFO:${NC} $1" | tee -a "$LOG_FILE"
}

log_success() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] SUCCESS:${NC} $1" | tee -a "$LOG_FILE"
}

log_warning() {
    echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] WARNING:${NC} $1" | tee -a "$LOG_FILE"
}

log_error() {
    echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] ERROR:${NC} $1" | tee -a "$LOG_FILE"
}

# Check prerequisites
check_prerequisites() {
    log_info "Checking prerequisites..."
    
    # Check for required tools
    for tool in aws jq yq; do
        if ! command -v $tool &> /dev/null; then
            log_error "$tool is not installed. Please install it first."
            exit 1
        fi
    done
    
    # Check for config file
    if [[ ! -f "$CONFIG_FILE" ]]; then
        log_error "Configuration file not found: $CONFIG_FILE"
        exit 1
    fi
    
    log_success "Prerequisites check passed"
}

# Parse configuration
parse_config() {
    log_info "Parsing configuration file..."
    
    # Source configuration
    SOURCE_PROFILE=$(yq eval '.migration.source.profile' "$CONFIG_FILE")
    SOURCE_REGION=$(yq eval '.migration.source.region' "$CONFIG_FILE")
    SOURCE_INFRA_STACK=$(yq eval '.migration.source.infrastructure_stack_name' "$CONFIG_FILE")
    SOURCE_MIGRATION_STACK=$(yq eval '.migration.source.migration_setup_stack_name' "$CONFIG_FILE")
    
    # Target configuration
    TARGET_PROFILE=$(yq eval '.migration.target.profile' "$CONFIG_FILE")
    TARGET_REGION=$(yq eval '.migration.target.region' "$CONFIG_FILE")
    TARGET_INFRA_STACK=$(yq eval '.migration.target.infrastructure_stack_name' "$CONFIG_FILE")
    TARGET_MIGRATION_STACK=$(yq eval '.migration.target.migration_setup_stack_name' "$CONFIG_FILE")
    TARGET_NODE_TYPE=$(yq eval '.migration.target.cluster.node_type' "$CONFIG_FILE")
    
    # Migration options
    CREATE_NEW_SNAPSHOT=$(yq eval '.migration.options.snapshot.create_new' "$CONFIG_FILE")
    EXISTING_SNAPSHOT=$(yq eval '.migration.options.snapshot.existing_snapshot_name' "$CONFIG_FILE")
    VERIFY_DATA=$(yq eval '.migration.options.import.verify_data' "$CONFIG_FILE")
    DEPLOY_VALIDATION=$(yq eval '.validation.deploy_validation' "$CONFIG_FILE")
    
    log_success "Configuration parsed"
}

# Get stack outputs
get_stack_output() {
    local profile=$1
    local region=$2
    local stack=$3
    local output_key=$4
    
    aws cloudformation describe-stacks \
        --profile "$profile" \
        --region "$region" \
        --stack-name "$stack" \
        --query "Stacks[0].Outputs[?OutputKey=='$output_key'].OutputValue" \
        --output text 2>/dev/null
}

# Verify stacks exist
verify_stacks() {
    log_info "Verifying CloudFormation stacks..."
    
    # Check source stacks
    log_info "Checking source account stacks..."
    aws cloudformation describe-stacks \
        --profile "$SOURCE_PROFILE" \
        --region "$SOURCE_REGION" \
        --stack-name "$SOURCE_INFRA_STACK" &>/dev/null || {
        log_error "Source infrastructure stack not found: $SOURCE_INFRA_STACK"
        exit 1
    }
    
    aws cloudformation describe-stacks \
        --profile "$SOURCE_PROFILE" \
        --region "$SOURCE_REGION" \
        --stack-name "$SOURCE_MIGRATION_STACK" &>/dev/null || {
        log_error "Source migration setup stack not found: $SOURCE_MIGRATION_STACK"
        exit 1
    }
    
    # Check target stacks
    log_info "Checking target account stacks..."
    aws cloudformation describe-stacks \
        --profile "$TARGET_PROFILE" \
        --region "$TARGET_REGION" \
        --stack-name "$TARGET_MIGRATION_STACK" &>/dev/null || {
        log_error "Target migration setup stack not found: $TARGET_MIGRATION_STACK"
        exit 1
    }
    
    log_success "All required stacks found"
}

# Get cluster information
get_cluster_info() {
    log_info "Getting source cluster information..."
    
    # Get cluster ID from stack output
    CLUSTER_ID=$(get_stack_output "$SOURCE_PROFILE" "$SOURCE_REGION" "$SOURCE_INFRA_STACK" "RedisClusterId")
    
    if [[ -z "$CLUSTER_ID" ]]; then
        log_error "Could not find Redis cluster ID in stack outputs"
        exit 1
    fi
    
    # Get cluster details
    CLUSTER_INFO=$(aws elasticache describe-cache-clusters \
        --cache-cluster-id "$CLUSTER_ID" \
        --profile "$SOURCE_PROFILE" \
        --region "$SOURCE_REGION" \
        --output json)
    
    NODE_TYPE=$(echo "$CLUSTER_INFO" | jq -r '.CacheClusters[0].CacheNodeType')
    ENGINE_VERSION=$(echo "$CLUSTER_INFO" | jq -r '.CacheClusters[0].EngineVersion')
    
    log_success "Found cluster: $CLUSTER_ID (Type: $NODE_TYPE, Version: $ENGINE_VERSION)"
}

# Create snapshot
create_snapshot() {
    if [[ "$CREATE_NEW_SNAPSHOT" == "true" ]]; then
        log_info "Creating snapshot of source cluster..."
        
        SNAPSHOT_NAME="migration-$(date +%Y%m%d-%H%M%S)"
        
        aws elasticache create-snapshot \
            --cache-cluster-id "$CLUSTER_ID" \
            --snapshot-name "$SNAPSHOT_NAME" \
            --profile "$SOURCE_PROFILE" \
            --region "$SOURCE_REGION" \
            --output json > /dev/null
        
        log_info "Waiting for snapshot to complete..."
        
        # Poll snapshot status until it's available (no native wait command for snapshots)
        local max_attempts=60  # 30 minutes max
        local attempt=1
        
        while [ $attempt -le $max_attempts ]; do
            local snapshot_status=$(aws elasticache describe-snapshots \
                --snapshot-name "$SNAPSHOT_NAME" \
                --profile "$SOURCE_PROFILE" \
                --region "$SOURCE_REGION" \
                --query 'Snapshots[0].SnapshotStatus' \
                --output text 2>/dev/null || echo "not-found")
            
            if [ "$snapshot_status" = "available" ]; then
                break
            elif [ "$snapshot_status" = "failed" ]; then
                log_error "Snapshot creation failed"
                exit 1
            elif [ "$snapshot_status" = "not-found" ]; then
                log_error "Snapshot not found"
                exit 1
            fi
            
            log_info "Snapshot status: $snapshot_status (attempt $attempt/$max_attempts)"
            sleep 30
            ((attempt++))
        done
        
        if [ $attempt -gt $max_attempts ]; then
            log_error "Timeout waiting for snapshot to complete"
            exit 1
        fi
        
        log_success "Snapshot created: $SNAPSHOT_NAME"
    else
        SNAPSHOT_NAME="$EXISTING_SNAPSHOT"
        log_info "Using existing snapshot: $SNAPSHOT_NAME"
    fi
}

# Export snapshot to S3
export_to_s3() {
    log_info "Exporting snapshot to S3..."
    
    # Get export bucket from stack
    EXPORT_BUCKET=$(get_stack_output "$SOURCE_PROFILE" "$SOURCE_REGION" "$SOURCE_MIGRATION_STACK" "ExportBucketName")
    
    if [[ -z "$EXPORT_BUCKET" ]]; then
        log_error "Could not find export bucket in stack outputs"
        exit 1
    fi
    
    # Export snapshot
    EXPORT_TASK="${SNAPSHOT_NAME}-export"
    
    aws elasticache copy-snapshot \
        --source-snapshot-name "$SNAPSHOT_NAME" \
        --target-snapshot-name "$EXPORT_TASK" \
        --target-bucket "$EXPORT_BUCKET" \
        --profile "$SOURCE_PROFILE" \
        --region "$SOURCE_REGION" \
        --output json > /dev/null
    
    log_info "Waiting for export to complete..."
    
    # Monitor export progress
    while true; do
        sleep 30
        
        # Check if RDB file exists in S3
        RDB_FILE=$(aws s3 ls "s3://$EXPORT_BUCKET/" --profile "$SOURCE_PROFILE" --region "$SOURCE_REGION" | grep "${EXPORT_TASK}.*\.rdb" | awk '{print $4}' | head -1)
        
        if [[ -n "$RDB_FILE" ]]; then
            log_success "Export completed: $RDB_FILE"
            break
        fi
        
        log_info "Export still in progress..."
    done
}

# Copy to target account
copy_to_target() {
    log_info "Copying RDB file to target account..."
    
    # Get import bucket from stack
    IMPORT_BUCKET=$(get_stack_output "$TARGET_PROFILE" "$TARGET_REGION" "$TARGET_MIGRATION_STACK" "ImportBucketName")
    
    if [[ -z "$IMPORT_BUCKET" ]]; then
        log_error "Could not find import bucket in stack outputs"
        exit 1
    fi
    
    # Download from source
    TEMP_FILE="/tmp/$RDB_FILE"
    aws s3 cp "s3://$EXPORT_BUCKET/$RDB_FILE" "$TEMP_FILE" \
        --profile "$SOURCE_PROFILE" \
        --region "$SOURCE_REGION"
    
    # Upload to target
    aws s3 cp "$TEMP_FILE" "s3://$IMPORT_BUCKET/$RDB_FILE" \
        --profile "$TARGET_PROFILE" \
        --region "$TARGET_REGION"
    
    # Set ACLs for ElastiCache
    CANONICAL_ID=$(get_stack_output "$TARGET_PROFILE" "$TARGET_REGION" "$TARGET_MIGRATION_STACK" "ElastiCacheCanonicalUserId")
    
    # Get target account canonical ID for full control
    TARGET_CANONICAL_ID=$(aws s3api list-buckets \
        --profile "$TARGET_PROFILE" \
        --region "$TARGET_REGION" \
        --query 'Owner.ID' \
        --output text)
    
    aws s3api put-object-acl \
        --bucket "$IMPORT_BUCKET" \
        --key "$RDB_FILE" \
        --grant-full-control "id=$TARGET_CANONICAL_ID" \
        --grant-read "id=$CANONICAL_ID" \
        --grant-read-acp "id=$CANONICAL_ID" \
        --profile "$TARGET_PROFILE" \
        --region "$TARGET_REGION"
    
    # Clean up temp file
    rm -f "$TEMP_FILE"
    
    log_success "RDB file copied to target account"
}

# Create target cluster
create_target_cluster() {
    log_info "Creating target Redis cluster..."
    
    # Check if target infrastructure stack exists
    TARGET_STACK_EXISTS=$(aws cloudformation describe-stacks \
        --profile "$TARGET_PROFILE" \
        --region "$TARGET_REGION" \
        --stack-name "$TARGET_INFRA_STACK" \
        --query 'Stacks[0].StackStatus' \
        --output text 2>/dev/null || echo "NONE")
    
    if [[ "$TARGET_STACK_EXISTS" == "NONE" ]]; then
        log_info "Creating target infrastructure stack..."
        
        # Get source account ID
        SOURCE_ACCOUNT=$(aws sts get-caller-identity --profile "$SOURCE_PROFILE" --query 'Account' --output text)
        
        # Create stack with import
        aws cloudformation create-stack \
            --stack-name "$TARGET_INFRA_STACK" \
            --template-body "file://2-target-infrastructure.yaml" \
            --parameters \
                ParameterKey=RedisNodeType,ParameterValue="$TARGET_NODE_TYPE" \
                ParameterKey=EnablePersistence,ParameterValue=true \
                ParameterKey=ImportFromS3,ParameterValue=true \
                ParameterKey=S3ImportPath,ParameterValue="$IMPORT_BUCKET/$RDB_FILE" \
                ParameterKey=SourceAccountId,ParameterValue="$SOURCE_ACCOUNT" \
            --profile "$TARGET_PROFILE" \
            --region "$TARGET_REGION" \
            --output json > /dev/null
        
        log_info "Waiting for stack creation (this may take 10-15 minutes)..."
        aws cloudformation wait stack-create-complete \
            --stack-name "$TARGET_INFRA_STACK" \
            --profile "$TARGET_PROFILE" \
            --region "$TARGET_REGION"
        
        log_success "Target infrastructure created with imported data"
    else
        log_warning "Target infrastructure stack already exists. Manual import may be required."
    fi
}

# Generate migration report
generate_report() {
    log_info "Generating migration report..."
    
    REPORT_FILE="migration-report-$(date +%Y%m%d-%H%M%S).md"
    
    cat > "$REPORT_FILE" << EOF
# ElastiCache Redis Migration Report

**Date**: $(date)

## Source Environment
- **Profile**: $SOURCE_PROFILE
- **Region**: $SOURCE_REGION
- **Cluster ID**: $CLUSTER_ID
- **Node Type**: $NODE_TYPE
- **Engine Version**: $ENGINE_VERSION

## Target Environment
- **Profile**: $TARGET_PROFILE
- **Region**: $TARGET_REGION
- **Node Type**: $TARGET_NODE_TYPE

## Migration Details
- **Snapshot Name**: $SNAPSHOT_NAME
- **Export Bucket**: $EXPORT_BUCKET
- **Import Bucket**: $IMPORT_BUCKET
- **RDB File**: $RDB_FILE

## Status
- ✅ Snapshot created/verified
- ✅ Exported to S3
- ✅ Copied to target account
- ✅ Target cluster created

## Next Steps
1. Deploy validation infrastructure: \`./5-validate-migration.sh\`
2. Run cleanup if needed: \`./6-cleanup.sh\`
EOF
    
    log_success "Migration report saved to: $REPORT_FILE"
}

# Main execution
main() {
    echo -e "${BLUE}ElastiCache Redis Cross-Account Migration${NC}"
    echo "=========================================="
    
    # Initialize
    CONFIG_FILE="${1:-migration-config.yaml}"
    LOG_FILE="migration-$(date +%Y%m%d-%H%M%S).log"
    
    # Run migration steps
    check_prerequisites
    parse_config
    verify_stacks
    get_cluster_info
    create_snapshot
    export_to_s3
    copy_to_target
    create_target_cluster
    generate_report
    
    log_success "Migration completed successfully!"
    
    if [[ "$DEPLOY_VALIDATION" == "true" ]]; then
        log_info "Run './5-validate-migration.sh' to deploy validation infrastructure"
    fi
}

# Run main function
main "$@"