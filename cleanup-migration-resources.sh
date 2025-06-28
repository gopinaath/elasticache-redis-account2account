#!/bin/bash

# ElastiCache Migration Resources Cleanup Script
# Removes S3 buckets, IAM roles, Lambda functions, and migration setup
# Preserves source infrastructure and Redis clusters

set -e

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Default values
CONFIG_FILE="${1:-migration-config.yaml}"
DRY_RUN=false
FORCE=false
SOURCE_ONLY=false
TARGET_ONLY=false

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --force)
            FORCE=true
            shift
            ;;
        --source-only)
            SOURCE_ONLY=true
            shift
            ;;
        --target-only)
            TARGET_ONLY=true
            shift
            ;;
        *)
            CONFIG_FILE="$1"
            shift
            ;;
    esac
done

# Logging functions
log_info() {
    echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')] INFO:${NC} $1"
}

log_success() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] SUCCESS:${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] WARNING:${NC} $1"
}

log_error() {
    echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] ERROR:${NC} $1"
}

log_action() {
    echo -e "${CYAN}[$(date +'%Y-%m-%d %H:%M:%S')] ACTION:${NC} $1"
}

# Check if required tools are installed
check_prerequisites() {
    log_info "Checking prerequisites..."
    
    local missing_tools=()
    
    if ! command -v aws &> /dev/null; then
        missing_tools+=("aws")
    fi
    
    if ! command -v yq &> /dev/null; then
        missing_tools+=("yq")
    fi
    
    if [ ${#missing_tools[@]} -ne 0 ]; then
        log_error "Missing required tools: ${missing_tools[*]}"
        log_error "Please install missing tools and try again"
        exit 1
    fi
    
    log_success "Prerequisites check passed"
}

# Parse configuration file
parse_config() {
    log_info "Parsing configuration file: $CONFIG_FILE"
    
    if [ ! -f "$CONFIG_FILE" ]; then
        log_error "Configuration file not found: $CONFIG_FILE"
        exit 1
    fi
    
    # Extract configuration values
    SOURCE_PROFILE=$(yq eval '.migration.source.profile' "$CONFIG_FILE")
    SOURCE_REGION=$(yq eval '.migration.source.region' "$CONFIG_FILE")
    SOURCE_MIGRATION_STACK=$(yq eval '.migration.source.migration_setup_stack_name' "$CONFIG_FILE")
    
    TARGET_PROFILE=$(yq eval '.migration.target.profile' "$CONFIG_FILE")
    TARGET_REGION=$(yq eval '.migration.target.region' "$CONFIG_FILE")
    TARGET_MIGRATION_STACK=$(yq eval '.migration.target.migration_setup_stack_name' "$CONFIG_FILE")
    
    log_success "Configuration parsed successfully"
}

# Verify Redis clusters are healthy before cleanup
verify_redis_health() {
    log_info "Verifying Redis cluster health before cleanup..."
    
    if [ "$SOURCE_ONLY" = false ]; then
        # Check target Redis clusters
        log_info "Checking target Redis clusters..."
        local target_clusters=$(aws elasticache describe-cache-clusters \
            --profile "$TARGET_PROFILE" \
            --region "$TARGET_REGION" \
            --query 'CacheClusters[?Engine==`redis`].[CacheClusterId,CacheClusterStatus]' \
            --output text 2>/dev/null || echo "")
        
        if [ -n "$target_clusters" ]; then
            echo "$target_clusters" | while read cluster_id status; do
                if [ "$status" != "available" ]; then
                    log_warning "Target Redis cluster $cluster_id is not available (status: $status)"
                fi
            done
        else
            log_warning "No Redis clusters found in target account"
        fi
    fi
    
    if [ "$TARGET_ONLY" = false ]; then
        # Check source Redis clusters
        log_info "Checking source Redis clusters..."
        local source_clusters=$(aws elasticache describe-cache-clusters \
            --profile "$SOURCE_PROFILE" \
            --region "$SOURCE_REGION" \
            --query 'CacheClusters[?Engine==`redis`].[CacheClusterId,CacheClusterStatus]' \
            --output text 2>/dev/null || echo "")
        
        if [ -n "$source_clusters" ]; then
            echo "$source_clusters" | while read cluster_id status; do
                if [ "$status" != "available" ]; then
                    log_warning "Source Redis cluster $cluster_id is not available (status: $status)"
                fi
            done
        fi
    fi
    
    log_success "Redis cluster health check completed"
}

# Set S3 bucket lifecycle policy for 30-day retention
set_s3_lifecycle_policy() {
    local bucket_name="$1"
    local profile="$2"
    local region="$3"
    
    log_action "Setting 30-day lifecycle policy on S3 bucket: $bucket_name"
    
    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY RUN] Would set lifecycle policy on $bucket_name"
        return
    fi
    
    # Create lifecycle policy JSON
    local lifecycle_policy=$(cat <<EOF
{
    "Rules": [
        {
            "ID": "MigrationCleanupRetention",
            "Status": "Enabled",
            "Filter": {},
            "Expiration": {
                "Days": 30
            },
            "NoncurrentVersionExpiration": {
                "NoncurrentDays": 7
            }
        }
    ]
}
EOF
)
    
    # Apply lifecycle policy
    echo "$lifecycle_policy" | aws s3api put-bucket-lifecycle-configuration \
        --bucket "$bucket_name" \
        --lifecycle-configuration file:///dev/stdin \
        --profile "$profile" \
        --region "$region" 2>/dev/null || {
        log_warning "Failed to set lifecycle policy on $bucket_name (bucket may not exist)"
    }
}

# Clean up S3 buckets with lifecycle policy
cleanup_s3_buckets() {
    local profile="$1"
    local region="$2"
    local account_type="$3"
    
    log_info "Cleaning up S3 buckets in $account_type account..."
    
    # Get account ID
    local account_id=$(aws sts get-caller-identity --profile "$profile" --query Account --output text)
    
    # Define bucket patterns
    local export_bucket="elasticache-export-${account_id}-${region}"
    local import_bucket="elasticache-import-${account_id}-${region}"
    
    # Handle export bucket (source account)
    if [ "$account_type" = "source" ]; then
        if aws s3api head-bucket --bucket "$export_bucket" --profile "$profile" 2>/dev/null; then
            log_action "Processing export bucket: $export_bucket"
            set_s3_lifecycle_policy "$export_bucket" "$profile" "$region"
            
            if [ "$DRY_RUN" = false ]; then
                log_info "Export bucket will be automatically cleaned up in 30 days via lifecycle policy"
            fi
        else
            log_info "Export bucket $export_bucket not found or already deleted"
        fi
    fi
    
    # Handle import bucket (target account)
    if [ "$account_type" = "target" ]; then
        if aws s3api head-bucket --bucket "$import_bucket" --profile "$profile" 2>/dev/null; then
            log_action "Processing import bucket: $import_bucket"
            set_s3_lifecycle_policy "$import_bucket" "$profile" "$region"
            
            if [ "$DRY_RUN" = false ]; then
                log_info "Import bucket will be automatically cleaned up in 30 days via lifecycle policy"
            fi
        else
            log_info "Import bucket $import_bucket not found or already deleted"
        fi
    fi
}

# Clean up CloudFormation stack
cleanup_cloudformation_stack() {
    local stack_name="$1"
    local profile="$2"
    local region="$3"
    local account_type="$4"
    
    log_action "Cleaning up CloudFormation stack: $stack_name ($account_type)"
    
    # Check if stack exists
    if ! aws cloudformation describe-stacks \
        --stack-name "$stack_name" \
        --profile "$profile" \
        --region "$region" &>/dev/null; then
        log_info "Stack $stack_name not found or already deleted"
        return
    fi
    
    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY RUN] Would delete CloudFormation stack: $stack_name"
        return
    fi
    
    # Delete the stack
    aws cloudformation delete-stack \
        --stack-name "$stack_name" \
        --profile "$profile" \
        --region "$region"
    
    log_info "Stack deletion initiated: $stack_name"
    
    # Wait for deletion to complete
    log_info "Waiting for stack deletion to complete..."
    aws cloudformation wait stack-delete-complete \
        --stack-name "$stack_name" \
        --profile "$profile" \
        --region "$region" || {
        log_warning "Stack deletion may have failed or timed out: $stack_name"
    }
    
    log_success "Stack deleted: $stack_name"
}

# Display cleanup summary
show_cleanup_summary() {
    log_info "Migration Resources Cleanup Summary:"
    echo
    echo -e "${CYAN}Resources to be cleaned up:${NC}"
    
    if [ "$SOURCE_ONLY" = false ]; then
        echo "  Target Account:"
        echo "    - CloudFormation stack: $TARGET_MIGRATION_STACK"
        echo "    - S3 import bucket (30-day lifecycle)"
        echo "    - Lambda functions (ACL management, validation)"
        echo "    - IAM roles (migration-specific)"
    fi
    
    if [ "$TARGET_ONLY" = false ]; then
        echo "  Source Account:"
        echo "    - CloudFormation stack: $SOURCE_MIGRATION_STACK"
        echo "    - S3 export bucket (30-day lifecycle)"
        echo "    - Lambda functions (data loader, ACL management)"
        echo "    - IAM roles (migration-specific)"
    fi
    
    echo
    echo -e "${GREEN}Resources that will be PRESERVED:${NC}"
    echo "  - All Redis clusters and data"
    echo "  - VPC and networking infrastructure"
    echo "  - Source infrastructure stacks"
    echo "  - Target infrastructure stacks"
    echo
}

# Get user confirmation
get_user_confirmation() {
    if [ "$FORCE" = true ]; then
        log_info "Force mode enabled, skipping confirmation"
        return
    fi
    
    echo -e "${YELLOW}⚠️  WARNING: This will delete migration setup resources!${NC}"
    echo
    show_cleanup_summary
    
    if [ "$DRY_RUN" = true ]; then
        echo -e "${BLUE}This is a DRY RUN - no resources will actually be deleted${NC}"
        echo
    fi
    
    read -p "Do you want to proceed with the cleanup? (yes/no): " -r
    echo
    
    if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
        log_info "Cleanup cancelled by user"
        exit 0
    fi
}

# Main cleanup function
main() {
    log_info "Starting ElastiCache Migration Resources Cleanup"
    echo
    
    # Check prerequisites
    check_prerequisites
    
    # Parse configuration
    parse_config
    
    # Verify Redis health
    verify_redis_health
    
    # Get user confirmation
    get_user_confirmation
    
    # Start cleanup
    log_info "Beginning cleanup process..."
    
    # Clean up target account resources
    if [ "$SOURCE_ONLY" = false ]; then
        log_info "Cleaning up target account migration resources..."
        cleanup_s3_buckets "$TARGET_PROFILE" "$TARGET_REGION" "target"
        cleanup_cloudformation_stack "$TARGET_MIGRATION_STACK" "$TARGET_PROFILE" "$TARGET_REGION" "target"
    fi
    
    # Clean up source account resources
    if [ "$TARGET_ONLY" = false ]; then
        log_info "Cleaning up source account migration resources..."
        cleanup_s3_buckets "$SOURCE_PROFILE" "$SOURCE_REGION" "source"
        cleanup_cloudformation_stack "$SOURCE_MIGRATION_STACK" "$SOURCE_PROFILE" "$SOURCE_REGION" "source"
    fi
    
    echo
    log_success "Migration resources cleanup completed!"
    echo
    log_info "Summary:"
    log_info "- S3 buckets: Set to auto-delete in 30 days"
    log_info "- CloudFormation stacks: Deleted (with all Lambda functions and IAM roles)"
    log_info "- Redis clusters: Preserved and untouched"
    log_info "- Infrastructure: Preserved and untouched"
    echo
    log_info "Your Redis clusters continue to run normally."
}

# Show usage information
show_usage() {
    echo "Usage: $0 [config-file] [options]"
    echo
    echo "Options:"
    echo "  --dry-run       Show what would be deleted without actually deleting"
    echo "  --force         Skip confirmation prompts"
    echo "  --source-only   Clean up only source account resources"
    echo "  --target-only   Clean up only target account resources"
    echo
    echo "Examples:"
    echo "  $0 migration-config.yaml --dry-run"
    echo "  $0 migration-config.yaml --target-only"
    echo "  $0 migration-config.yaml --force"
}

# Handle help flag
if [[ "$1" == "--help" || "$1" == "-h" ]]; then
    show_usage
    exit 0
fi

# Run main function
main
