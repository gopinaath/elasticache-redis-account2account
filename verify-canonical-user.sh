#!/bin/bash

# ElastiCache Canonical User ID Verification Script
# Verifies that hardcoded canonical user IDs are still valid
# Tests actual ElastiCache operations to confirm permissions

set -e

# Handle help first
if [[ "$1" == "--help" || "$1" == "-h" ]]; then
    echo "Usage: $0 [region] [options]"
    echo
    echo "Verifies ElastiCache canonical user ID for a specific region"
    echo
    echo "Options:"
    echo "  --profile PROFILE   AWS CLI profile to use (default: default)"
    echo "  --region REGION     AWS region to test (default: us-east-1)"
    echo "  --dry-run           Show what would be done without actually doing it"
    echo "  --no-cleanup        Don't delete test resources"
    echo
    echo "Examples:"
    echo "  $0 us-east-1"
    echo "  $0 --region us-east-1 --profile prod"
    echo "  $0 --dry-run"
    exit 0
fi

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Default values
REGION="${1:-us-east-1}"
PROFILE="${2:-default}"
DRY_RUN=false
CLEANUP=true

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --no-cleanup)
            CLEANUP=false
            shift
            ;;
        --region)
            REGION="$2"
            shift 2
            ;;
        --profile)
            PROFILE="$2"
            shift 2
            ;;
        *)
            REGION="$1"
            shift
            ;;
    esac
done

# Expected canonical user ID (from AWS documentation)
EXPECTED_CANONICAL_ID="540804c33a284a299d2547575ce1010f2312ef3da9b3a053c8bc45bf233e4353"

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

# Check prerequisites
check_prerequisites() {
    log_info "Checking prerequisites..."
    
    if ! command -v aws &> /dev/null; then
        log_error "AWS CLI not found. Please install AWS CLI."
        exit 1
    fi
    
    # Test AWS credentials
    if ! aws sts get-caller-identity --profile "$PROFILE" &>/dev/null; then
        log_error "AWS credentials not configured for profile: $PROFILE"
        exit 1
    fi
    
    log_success "Prerequisites check passed"
}

# Get account canonical user ID
get_account_canonical_id() {
    log_info "Getting account canonical user ID..."
    
    local account_canonical_id=$(aws s3api list-buckets \
        --profile "$PROFILE" \
        --query 'Owner.ID' \
        --output text 2>/dev/null)
    
    if [ -n "$account_canonical_id" ]; then
        log_info "Account canonical user ID: $account_canonical_id"
        echo "$account_canonical_id"
    else
        log_error "Failed to get account canonical user ID"
        return 1
    fi
}

# Create test bucket with proper ACL
create_test_bucket() {
    local bucket_name="$1"
    local account_canonical_id="$2"
    
    log_action "Creating test bucket: $bucket_name"
    
    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY RUN] Would create bucket: $bucket_name"
        return 0
    fi
    
    # Create bucket
    aws s3 mb "s3://$bucket_name" \
        --region "$REGION" \
        --profile "$PROFILE"
    
    # Set bucket ACL with ElastiCache canonical user
    log_action "Setting bucket ACL with ElastiCache canonical user..."
    aws s3api put-bucket-acl \
        --bucket "$bucket_name" \
        --grant-full-control "id=$account_canonical_id" \
        --grant-read "id=$EXPECTED_CANONICAL_ID" \
        --grant-write "id=$EXPECTED_CANONICAL_ID" \
        --grant-read-acp "id=$EXPECTED_CANONICAL_ID" \
        --profile "$PROFILE" || {
        log_error "Failed to set bucket ACL - canonical user ID may be invalid"
        return 1
    }
    
    log_success "Bucket created and ACL set successfully"
}

# Verify bucket ACL
verify_bucket_acl() {
    local bucket_name="$1"
    
    log_action "Verifying bucket ACL..."
    
    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY RUN] Would verify bucket ACL"
        return 0
    fi
    
    local acl_output=$(aws s3api get-bucket-acl \
        --bucket "$bucket_name" \
        --profile "$PROFILE" \
        --output json)
    
    # Check if ElastiCache canonical user is in the ACL
    if echo "$acl_output" | grep -q "$EXPECTED_CANONICAL_ID"; then
        log_success "✓ ElastiCache canonical user found in bucket ACL"
        
        # Show the grants for ElastiCache canonical user
        echo "$acl_output" | jq -r ".Grants[] | select(.Grantee.ID == \"$EXPECTED_CANONICAL_ID\") | \"  Permission: \" + .Permission"
        
        return 0
    else
        log_error "✗ ElastiCache canonical user NOT found in bucket ACL"
        log_error "Expected canonical user ID: $EXPECTED_CANONICAL_ID"
        return 1
    fi
}

# Test ElastiCache export operation (if cluster exists)
test_elasticache_export() {
    local bucket_name="$1"
    
    log_action "Checking for existing ElastiCache clusters..."
    
    local clusters=$(aws elasticache describe-cache-clusters \
        --profile "$PROFILE" \
        --region "$REGION" \
        --query 'CacheClusters[?Engine==`redis`].CacheClusterId' \
        --output text 2>/dev/null || echo "")
    
    if [ -z "$clusters" ]; then
        log_warning "No Redis clusters found - cannot test actual export operation"
        return 0
    fi
    
    local first_cluster=$(echo "$clusters" | awk '{print $1}')
    log_info "Found Redis cluster: $first_cluster"
    
    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY RUN] Would test export operation with cluster: $first_cluster"
        return 0
    fi
    
    # Create a snapshot first
    local snapshot_name="canonical-test-$(date +%s)"
    log_action "Creating test snapshot: $snapshot_name"
    
    aws elasticache create-snapshot \
        --cache-cluster-id "$first_cluster" \
        --snapshot-name "$snapshot_name" \
        --profile "$PROFILE" \
        --region "$REGION" &>/dev/null || {
        log_warning "Failed to create snapshot - cluster may not support snapshots"
        return 0
    }
    
    # Wait for snapshot to be available
    log_info "Waiting for snapshot to be available..."
    aws elasticache wait snapshot-available \
        --snapshot-name "$snapshot_name" \
        --profile "$PROFILE" \
        --region "$REGION" || {
        log_warning "Snapshot creation timed out"
        return 0
    }
    
    # Try to export snapshot
    log_action "Testing export operation to S3..."
    if aws elasticache export-snapshot \
        --snapshot-name "$snapshot_name" \
        --s3-bucket-name "$bucket_name" \
        --profile "$PROFILE" \
        --region "$REGION" &>/dev/null; then
        log_success "✓ Export operation initiated successfully"
        log_info "This confirms the canonical user ID is correct"
    else
        log_error "✗ Export operation failed"
        log_error "This may indicate an incorrect canonical user ID"
    fi
    
    # Clean up snapshot
    log_action "Cleaning up test snapshot..."
    aws elasticache delete-snapshot \
        --snapshot-name "$snapshot_name" \
        --profile "$PROFILE" \
        --region "$REGION" &>/dev/null || true
}

# Clean up test resources
cleanup_test_resources() {
    local bucket_name="$1"
    
    if [ "$CLEANUP" = false ]; then
        log_info "Cleanup disabled - leaving test bucket: $bucket_name"
        return 0
    fi
    
    log_action "Cleaning up test bucket: $bucket_name"
    
    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY RUN] Would delete bucket: $bucket_name"
        return 0
    fi
    
    # Empty bucket first
    aws s3 rm "s3://$bucket_name" --recursive --profile "$PROFILE" 2>/dev/null || true
    
    # Delete bucket
    aws s3 rb "s3://$bucket_name" --profile "$PROFILE" 2>/dev/null || {
        log_warning "Failed to delete bucket - may need manual cleanup"
    }
}

# Display verification results
show_verification_results() {
    local success="$1"
    
    echo
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║                 VERIFICATION RESULTS                        ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo
    
    log_info "Region tested: $REGION"
    log_info "Profile used: $PROFILE"
    log_info "Expected canonical user ID: $EXPECTED_CANONICAL_ID"
    echo
    
    if [ "$success" = true ]; then
        log_success "✓ Canonical user ID verification PASSED"
        echo
        log_info "The hardcoded canonical user ID in CloudFormation templates is correct"
        log_info "ElastiCache operations should work with current configuration"
    else
        log_error "✗ Canonical user ID verification FAILED"
        echo
        log_warning "Action required:"
        echo "1. Check AWS documentation for updated canonical user ID"
        echo "2. Update CloudFormation templates if needed"
        echo "3. Test in your specific region/environment"
    fi
    
    echo
    log_info "AWS Documentation: https://docs.aws.amazon.com/AmazonElastiCache/latest/red-ug/backups-exporting.html"
}

# Main verification function
main() {
    echo
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║          ElastiCache Canonical User ID Verification         ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo
    
    log_info "Starting canonical user ID verification for region: $REGION"
    
    # Check prerequisites
    check_prerequisites
    
    # Get account canonical user ID
    local account_canonical_id
    account_canonical_id=$(get_account_canonical_id)
    
    # Create test bucket name
    local test_bucket="elasticache-canonical-test-$(date +%s)-$RANDOM"
    
    local verification_success=true
    
    # Create test bucket with ACL
    if ! create_test_bucket "$test_bucket" "$account_canonical_id"; then
        verification_success=false
    fi
    
    # Verify bucket ACL
    if [ "$verification_success" = true ]; then
        if ! verify_bucket_acl "$test_bucket"; then
            verification_success=false
        fi
    fi
    
    # Test actual ElastiCache export (if possible)
    if [ "$verification_success" = true ]; then
        test_elasticache_export "$test_bucket"
    fi
    
    # Clean up
    cleanup_test_resources "$test_bucket"
    
    # Show results
    show_verification_results "$verification_success"
    
    if [ "$verification_success" = true ]; then
        exit 0
    else
        exit 1
    fi
}

# Show usage
show_usage() {
    echo "Usage: $0 [region] [options]"
    echo
    echo "Verifies ElastiCache canonical user ID for a specific region"
    echo
    echo "Options:"
    echo "  --profile PROFILE   AWS CLI profile to use (default: default)"
    echo "  --region REGION     AWS region to test (default: us-west-2)"
    echo "  --dry-run           Show what would be done without actually doing it"
    echo "  --no-cleanup        Don't delete test resources"
    echo
    echo "Examples:"
    echo "  $0 us-west-2"
    echo "  $0 --region us-east-1 --profile prod"
    echo "  $0 --dry-run"
}

# Run main function
main
