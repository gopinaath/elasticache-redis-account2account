#!/bin/bash

# ElastiCache Complete Migration Cleanup Script
# Master script that orchestrates cleanup of all migration resources
# Preserves Redis clusters and source infrastructure

set -e

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

# Default values
CONFIG_FILE="${1:-migration-config.yaml}"
DRY_RUN=false
FORCE=false
SKIP_MIGRATION=false
SKIP_VALIDATION=false

# Handle help flag first
if [[ "$1" == "--help" || "$1" == "-h" ]]; then
    echo "Usage: $0 [config-file] [options]"
    echo
    echo "This script orchestrates complete cleanup of ElastiCache migration resources."
    echo "It runs both migration and validation cleanup scripts in sequence."
    echo
    echo "Options:"
    echo "  --dry-run           Show what would be deleted without actually deleting"
    echo "  --force             Skip confirmation prompts"
    echo "  --skip-migration    Skip migration resources cleanup"
    echo "  --skip-validation   Skip validation resources cleanup"
    echo
    echo "Examples:"
    echo "  $0 migration-config.yaml --dry-run"
    echo "  $0 migration-config.yaml --force"
    echo "  $0 migration-config.yaml --skip-validation"
    echo
    echo "Required files:"
    echo "  - cleanup-migration-resources.sh"
    echo "  - cleanup-validation-resources.sh"
    echo "  - migration-config.yaml (or specified config file)"
    exit 0
fi

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
        --skip-migration)
            SKIP_MIGRATION=true
            shift
            ;;
        --skip-validation)
            SKIP_VALIDATION=true
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

log_header() {
    echo -e "${MAGENTA}[$(date +'%Y-%m-%d %H:%M:%S')] PHASE:${NC} $1"
}

# Check if cleanup scripts exist
check_cleanup_scripts() {
    log_info "Checking for cleanup scripts..."
    
    local missing_scripts=()
    
    if [ ! -f "cleanup-migration-resources.sh" ]; then
        missing_scripts+=("cleanup-migration-resources.sh")
    fi
    
    if [ ! -f "cleanup-validation-resources.sh" ]; then
        missing_scripts+=("cleanup-validation-resources.sh")
    fi
    
    if [ ${#missing_scripts[@]} -ne 0 ]; then
        log_error "Missing required cleanup scripts: ${missing_scripts[*]}"
        log_error "Please ensure all cleanup scripts are in the current directory"
        exit 1
    fi
    
    # Make scripts executable
    chmod +x cleanup-migration-resources.sh
    chmod +x cleanup-validation-resources.sh
    
    log_success "Cleanup scripts found and ready"
}

# Display comprehensive cleanup summary
show_complete_cleanup_summary() {
    echo
    echo -e "${MAGENTA}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${MAGENTA}║                 COMPLETE MIGRATION CLEANUP                  ║${NC}"
    echo -e "${MAGENTA}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo
    
    log_info "This script will perform a complete cleanup of migration resources:"
    echo
    
    if [ "$SKIP_MIGRATION" = false ]; then
        echo -e "${CYAN}Phase 1: Migration Resources Cleanup${NC}"
        echo "  ✓ S3 export/import buckets (30-day lifecycle)"
        echo "  ✓ Migration CloudFormation stacks"
        echo "  ✓ Lambda functions (data loaders, ACL managers)"
        echo "  ✓ Migration-specific IAM roles and policies"
        echo
    fi
    
    if [ "$SKIP_VALIDATION" = false ]; then
        echo -e "${CYAN}Phase 2: Validation Resources Cleanup${NC}"
        echo "  ✓ Validation CloudFormation stacks"
        echo "  ✓ Lambda validation functions"
        echo "  ✓ Orphaned IAM roles from validation"
        echo "  ✓ Test and validation infrastructure"
        echo
    fi
    
    echo -e "${GREEN}Resources that will be PRESERVED:${NC}"
    echo "  ✓ All Redis clusters and data"
    echo "  ✓ Source infrastructure (VPC, networking, Redis)"
    echo "  ✓ Target infrastructure (VPC, networking)"
    echo "  ✓ Production applications and services"
    echo
    
    if [ "$DRY_RUN" = true ]; then
        echo -e "${BLUE}🔍 DRY RUN MODE: No resources will actually be deleted${NC}"
        echo
    fi
}

# Get comprehensive user confirmation
get_user_confirmation() {
    if [ "$FORCE" = true ]; then
        log_info "Force mode enabled, skipping confirmation"
        return
    fi
    
    show_complete_cleanup_summary
    
    echo -e "${YELLOW}⚠️  IMPORTANT SAFETY CHECKS:${NC}"
    echo
    echo "Before proceeding, please confirm:"
    echo "1. Your Redis migration was successful"
    echo "2. Applications are connecting to the new Redis cluster"
    echo "3. You have verified data integrity in the target cluster"
    echo "4. You no longer need the migration scaffolding"
    echo
    
    read -p "Have you verified that your migration was successful? (yes/no): " -r
    if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
        log_warning "Please verify your migration success before running cleanup"
        exit 0
    fi
    
    echo
    read -p "Do you want to proceed with the complete cleanup? (yes/no): " -r
    echo
    
    if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
        log_info "Cleanup cancelled by user"
        exit 0
    fi
}

# Run migration resources cleanup
run_migration_cleanup() {
    log_header "PHASE 1: Migration Resources Cleanup"
    echo
    
    local cleanup_args=("$CONFIG_FILE")
    
    if [ "$DRY_RUN" = true ]; then
        cleanup_args+=("--dry-run")
    fi
    
    if [ "$FORCE" = true ]; then
        cleanup_args+=("--force")
    fi
    
    log_action "Executing migration resources cleanup..."
    
    if ./cleanup-migration-resources.sh "${cleanup_args[@]}"; then
        log_success "Migration resources cleanup completed successfully"
    else
        log_error "Migration resources cleanup failed"
        return 1
    fi
    
    echo
}

# Run validation resources cleanup
run_validation_cleanup() {
    log_header "PHASE 2: Validation Resources Cleanup"
    echo
    
    local cleanup_args=("$CONFIG_FILE")
    
    if [ "$DRY_RUN" = true ]; then
        cleanup_args+=("--dry-run")
    fi
    
    if [ "$FORCE" = true ]; then
        cleanup_args+=("--force")
    fi
    
    log_action "Executing validation resources cleanup..."
    
    if ./cleanup-validation-resources.sh "${cleanup_args[@]}"; then
        log_success "Validation resources cleanup completed successfully"
    else
        log_error "Validation resources cleanup failed"
        return 1
    fi
    
    echo
}

# Display final summary
show_final_summary() {
    echo
    echo -e "${MAGENTA}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${MAGENTA}║                    CLEANUP COMPLETED                        ║${NC}"
    echo -e "${MAGENTA}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo
    
    log_success "Complete migration cleanup finished successfully!"
    echo
    
    log_info "What was cleaned up:"
    if [ "$SKIP_MIGRATION" = false ]; then
        echo "  ✓ Migration setup resources (S3, Lambda, IAM)"
    fi
    if [ "$SKIP_VALIDATION" = false ]; then
        echo "  ✓ Validation infrastructure (Lambda, CloudFormation)"
    fi
    echo "  ✓ Temporary migration scaffolding"
    echo
    
    log_info "What remains:"
    echo "  ✓ Your Redis clusters with all data intact"
    echo "  ✓ VPC and networking infrastructure"
    echo "  ✓ Production-ready environment"
    echo
    
    if [ "$DRY_RUN" = false ]; then
        log_info "S3 buckets will be automatically cleaned up in 30 days via lifecycle policies"
        echo
        log_success "Your ElastiCache migration is now complete and cleaned up!"
    else
        log_info "This was a dry run - no actual resources were deleted"
    fi
    
    echo
}

# Main function
main() {
    echo
    echo -e "${MAGENTA}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${MAGENTA}║            ElastiCache Migration Complete Cleanup           ║${NC}"
    echo -e "${MAGENTA}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo
    
    log_info "Starting complete migration cleanup process..."
    
    # Check for required scripts
    check_cleanup_scripts
    
    # Get user confirmation
    get_user_confirmation
    
    # Track success/failure
    local cleanup_success=true
    
    # Phase 1: Migration resources cleanup
    if [ "$SKIP_MIGRATION" = false ]; then
        if ! run_migration_cleanup; then
            cleanup_success=false
            log_error "Migration resources cleanup failed"
        fi
    else
        log_info "Skipping migration resources cleanup (--skip-migration)"
    fi
    
    # Phase 2: Validation resources cleanup
    if [ "$SKIP_VALIDATION" = false ]; then
        if ! run_validation_cleanup; then
            cleanup_success=false
            log_error "Validation resources cleanup failed"
        fi
    else
        log_info "Skipping validation resources cleanup (--skip-validation)"
    fi
    
    # Final summary
    if [ "$cleanup_success" = true ]; then
        show_final_summary
        exit 0
    else
        log_error "Some cleanup operations failed. Please check the logs above."
        exit 1
    fi
}

# Show usage information
show_usage() {
    echo "Usage: $0 [config-file] [options]"
    echo
    echo "This script orchestrates complete cleanup of ElastiCache migration resources."
    echo "It runs both migration and validation cleanup scripts in sequence."
    echo
    echo "Options:"
    echo "  --dry-run           Show what would be deleted without actually deleting"
    echo "  --force             Skip confirmation prompts"
    echo "  --skip-migration    Skip migration resources cleanup"
    echo "  --skip-validation   Skip validation resources cleanup"
    echo
    echo "Examples:"
    echo "  $0 migration-config.yaml --dry-run"
    echo "  $0 migration-config.yaml --force"
    echo "  $0 migration-config.yaml --skip-validation"
    echo
    echo "Required files:"
    echo "  - cleanup-migration-resources.sh"
    echo "  - cleanup-validation-resources.sh"
    echo "  - migration-config.yaml (or specified config file)"
}

# Handle help flag
if [[ "$1" == "--help" || "$1" == "-h" ]]; then
    show_usage
    exit 0
fi

# Run main function
main
