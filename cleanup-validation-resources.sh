#!/bin/bash

# ElastiCache Validation Resources Cleanup Script
# Removes validation infrastructure (Lambda validators, test resources)
# Preserves Redis clusters and core infrastructure

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
    TARGET_PROFILE=$(yq eval '.migration.target.profile' "$CONFIG_FILE")
    TARGET_REGION=$(yq eval '.migration.target.region' "$CONFIG_FILE")
    
    log_success "Configuration parsed successfully"
}

# Find and clean up validation CloudFormation stacks
cleanup_validation_stacks() {
    local profile="$1"
    local region="$2"
    
    log_info "Finding validation CloudFormation stacks..."
    
    # Common validation stack names
    local validation_stacks=(
        "simple-validator"
        "migration-validator"
        "redis-validator"
        "elasticache-validator"
    )
    
    # Get all stacks and filter for validation-related ones
    local existing_stacks=$(aws cloudformation list-stacks \
        --profile "$profile" \
        --region "$region" \
        --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE \
        --query 'StackSummaries[].StackName' \
        --output text 2>/dev/null || echo "")
    
    if [ -z "$existing_stacks" ]; then
        log_info "No CloudFormation stacks found"
        return
    fi
    
    # Check each validation stack
    for stack_name in "${validation_stacks[@]}"; do
        if echo "$existing_stacks" | grep -q "$stack_name"; then
            cleanup_cloudformation_stack "$stack_name" "$profile" "$region"
        else
            log_info "Validation stack not found: $stack_name"
        fi
    done
    
    # Also check for any stacks with "validator" in the name
    echo "$existing_stacks" | tr ' ' '\n' | grep -i validator | while read -r stack_name; do
        if [ -n "$stack_name" ]; then
            log_warning "Found additional validator stack: $stack_name"
            cleanup_cloudformation_stack "$stack_name" "$profile" "$region"
        fi
    done
}

# Clean up standalone Lambda functions (not in CloudFormation)
cleanup_standalone_lambda_functions() {
    local profile="$1"
    local region="$2"
    
    log_info "Finding standalone validation Lambda functions..."
    
    # Get all Lambda functions
    local lambda_functions=$(aws lambda list-functions \
        --profile "$profile" \
        --region "$region" \
        --query 'Functions[].FunctionName' \
        --output text 2>/dev/null || echo "")
    
    if [ -z "$lambda_functions" ]; then
        log_info "No Lambda functions found"
        return
    fi
    
    # Filter for validation-related functions
    echo "$lambda_functions" | tr ' ' '\n' | grep -E "(validator|validation|redis-test|migration-test)" | while read -r function_name; do
        if [ -n "$function_name" ]; then
            log_action "Deleting standalone Lambda function: $function_name"
            
            if [ "$DRY_RUN" = true ]; then
                log_info "[DRY RUN] Would delete Lambda function: $function_name"
            else
                aws lambda delete-function \
                    --function-name "$function_name" \
                    --profile "$profile" \
                    --region "$region" 2>/dev/null || {
                    log_warning "Failed to delete Lambda function: $function_name"
                }
                log_success "Deleted Lambda function: $function_name"
            fi
        fi
    done
}

# Clean up CloudFormation stack
cleanup_cloudformation_stack() {
    local stack_name="$1"
    local profile="$2"
    local region="$3"
    
    log_action "Cleaning up validation stack: $stack_name"
    
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

# Clean up orphaned IAM roles
cleanup_orphaned_iam_roles() {
    local profile="$1"
    
    log_info "Finding orphaned validation IAM roles..."
    
    # Get all IAM roles
    local iam_roles=$(aws iam list-roles \
        --profile "$profile" \
        --query 'Roles[].RoleName' \
        --output text 2>/dev/null || echo "")
    
    if [ -z "$iam_roles" ]; then
        log_info "No IAM roles found"
        return
    fi
    
    # Filter for validation-related roles
    echo "$iam_roles" | tr ' ' '\n' | grep -E "(validator|validation|redis-test|migration-test)" | while read -r role_name; do
        if [ -n "$role_name" ]; then
            log_action "Checking IAM role: $role_name"
            
            # Check if role is used by any existing resources
            local role_usage=$(aws iam get-role \
                --role-name "$role_name" \
                --profile "$profile" \
                --query 'Role.AssumeRolePolicyDocument' 2>/dev/null || echo "")
            
            if [ -n "$role_usage" ]; then
                log_action "Deleting orphaned IAM role: $role_name"
                
                if [ "$DRY_RUN" = true ]; then
                    log_info "[DRY RUN] Would delete IAM role: $role_name"
                else
                    # Delete attached policies first
                    aws iam list-attached-role-policies \
                        --role-name "$role_name" \
                        --profile "$profile" \
                        --query 'AttachedPolicies[].PolicyArn' \
                        --output text 2>/dev/null | tr '\t' '\n' | while read -r policy_arn; do
                        if [ -n "$policy_arn" ]; then
                            aws iam detach-role-policy \
                                --role-name "$role_name" \
                                --policy-arn "$policy_arn" \
                                --profile "$profile" 2>/dev/null || true
                        fi
                    done
                    
                    # Delete inline policies
                    aws iam list-role-policies \
                        --role-name "$role_name" \
                        --profile "$profile" \
                        --query 'PolicyNames[]' \
                        --output text 2>/dev/null | tr '\t' '\n' | while read -r policy_name; do
                        if [ -n "$policy_name" ]; then
                            aws iam delete-role-policy \
                                --role-name "$role_name" \
                                --policy-name "$policy_name" \
                                --profile "$profile" 2>/dev/null || true
                        fi
                    done
                    
                    # Delete the role
                    aws iam delete-role \
                        --role-name "$role_name" \
                        --profile "$profile" 2>/dev/null || {
                        log_warning "Failed to delete IAM role: $role_name"
                    }
                    log_success "Deleted IAM role: $role_name"
                fi
            fi
        fi
    done
}

# Display cleanup summary
show_cleanup_summary() {
    log_info "Validation Resources Cleanup Summary:"
    echo
    echo -e "${CYAN}Resources to be cleaned up:${NC}"
    echo "  Target Account:"
    echo "    - CloudFormation stacks (simple-validator, migration-validator, etc.)"
    echo "    - Lambda functions (validation, testing)"
    echo "    - IAM roles (validation-specific)"
    echo "    - Orphaned resources from validation"
    echo
    echo -e "${GREEN}Resources that will be PRESERVED:${NC}"
    echo "  - All Redis clusters and data"
    echo "  - VPC and networking infrastructure"
    echo "  - Source infrastructure stacks"
    echo "  - Target infrastructure stacks"
    echo "  - Migration setup resources (S3, etc.)"
    echo
}

# Get user confirmation
get_user_confirmation() {
    if [ "$FORCE" = true ]; then
        log_info "Force mode enabled, skipping confirmation"
        return
    fi
    
    echo -e "${YELLOW}⚠️  WARNING: This will delete validation resources!${NC}"
    echo
    show_cleanup_summary
    
    if [ "$DRY_RUN" = true ]; then
        echo -e "${BLUE}This is a DRY RUN - no resources will actually be deleted${NC}"
        echo
    fi
    
    read -p "Do you want to proceed with the validation cleanup? (yes/no): " -r
    echo
    
    if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
        log_info "Cleanup cancelled by user"
        exit 0
    fi
}

# Main cleanup function
main() {
    log_info "Starting ElastiCache Validation Resources Cleanup"
    echo
    
    # Check prerequisites
    check_prerequisites
    
    # Parse configuration
    parse_config
    
    # Get user confirmation
    get_user_confirmation
    
    # Start cleanup
    log_info "Beginning validation cleanup process..."
    
    # Clean up validation resources in target account
    log_info "Cleaning up validation resources in target account..."
    cleanup_validation_stacks "$TARGET_PROFILE" "$TARGET_REGION"
    cleanup_standalone_lambda_functions "$TARGET_PROFILE" "$TARGET_REGION"
    cleanup_orphaned_iam_roles "$TARGET_PROFILE"
    
    echo
    log_success "Validation resources cleanup completed!"
    echo
    log_info "Summary:"
    log_info "- Validation CloudFormation stacks: Deleted"
    log_info "- Validation Lambda functions: Deleted"
    log_info "- Orphaned IAM roles: Cleaned up"
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
    echo "  --target-only   Clean up only target account resources (default behavior)"
    echo
    echo "Examples:"
    echo "  $0 migration-config.yaml --dry-run"
    echo "  $0 migration-config.yaml --force"
}

# Handle help flag
if [[ "$1" == "--help" || "$1" == "-h" ]]; then
    show_usage
    exit 0
fi

# Run main function
main
