#!/bin/bash

# Simple Deployment Script - Fixed Version
# Uses CloudFormation package + create-stack/update-stack to handle large templates

set -e

# Configuration
STACK_NAME="${STACK_NAME:-hcls-agents-toolkit}"
TEMPLATE_FILE="infra_cfn.yaml"
REGION="${REGION:-us-east-1}"
BUCKET_NAME="${DEPLOYMENT_BUCKET:-genovia-deployment}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_status() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Get user inputs
get_user_inputs() {
    print_status "Gathering deployment parameters..."
    
    if [ -z "$REDSHIFT_PASSWORD" ]; then
        echo -n "Enter Redshift password (8+ chars, mixed case, numbers): "
        read -s REDSHIFT_PASSWORD
        echo
    fi
    
    if [ -z "$REACT_APP_CIDR" ]; then
        echo -n "Enter CIDR range for React app access (e.g., 192.168.1.0/24): "
        read REACT_APP_CIDR
    fi
}

# Convert parameters to CloudFormation format
format_parameters() {
    local params=""
    params="ParameterKey=RedshiftPassword,ParameterValue=$REDSHIFT_PASSWORD"
    params="$params ParameterKey=ReactAppAllowedCidr,ParameterValue=$REACT_APP_CIDR"
    params="$params ParameterKey=EnableBiomarkerAppInfrastructure,ParameterValue=true"
    echo "$params"
}

# Main deployment
main() {
    echo "========================================="
    echo "HCLS Agents Toolkit Simple Deployment"
    echo "========================================="
    echo ""
    echo "Using deployment bucket: $BUCKET_NAME"
    echo "Using region: $REGION"
    echo "Using stack name: $STACK_NAME"
    echo ""
    
    # Check prerequisites
    if ! command -v aws &> /dev/null; then
        print_error "AWS CLI is not installed."
        exit 1
    fi
    
    if ! aws sts get-caller-identity &> /dev/null; then
        print_error "AWS credentials not configured."
        exit 1
    fi
    
    # Get inputs
    get_user_inputs
    
    # Create or verify packaging bucket
    print_status "Checking packaging bucket..."
    if aws s3api head-bucket --bucket $BUCKET_NAME --region $REGION 2>/dev/null; then
        print_success "Using existing bucket: $BUCKET_NAME"
    else
        print_status "Creating packaging bucket: $BUCKET_NAME"
        aws s3 mb s3://$BUCKET_NAME --region $REGION
        print_success "Created bucket: $BUCKET_NAME"
    fi
    
    # Package template
    print_status "Packaging CloudFormation template..."
    aws cloudformation package \
        --template-file $TEMPLATE_FILE \
        --s3-bucket $BUCKET_NAME \
        --output-template-file packaged-template.yaml \
        --region $REGION
    
    # Upload packaged template to S3
    print_status "Uploading packaged template to S3..."
    TEMPLATE_KEY="packaged-template-$(date +%s).yaml"
    aws s3 cp packaged-template.yaml s3://$BUCKET_NAME/$TEMPLATE_KEY --region $REGION
    TEMPLATE_URL="https://${BUCKET_NAME}.s3.${REGION}.amazonaws.com/${TEMPLATE_KEY}"
    
    # Format parameters
    FORMATTED_PARAMS=$(format_parameters)
    
    # Deploy stack
    print_status "Deploying CloudFormation stack..."
    
    # Check if stack exists
    if aws cloudformation describe-stacks --stack-name $STACK_NAME --region $REGION >/dev/null 2>&1; then
        print_status "Stack exists, updating..."
        aws cloudformation update-stack \
            --stack-name $STACK_NAME \
            --template-url "$TEMPLATE_URL" \
            --parameters $FORMATTED_PARAMS \
            --capabilities CAPABILITY_AUTO_EXPAND \
            --region $REGION
        
        # Wait for update to complete
        print_status "Waiting for stack update to complete..."
        aws cloudformation wait stack-update-complete --stack-name $STACK_NAME --region $REGION
        
        if [ $? -eq 0 ]; then
            print_success "Stack update completed successfully!"
        else
            print_error "Stack update failed."
            exit 1
        fi
    else
        print_status "Creating new stack..."
        aws cloudformation create-stack \
            --stack-name $STACK_NAME \
            --template-url "$TEMPLATE_URL" \
            --parameters $FORMATTED_PARAMS \
            --capabilities CAPABILITY_AUTO_EXPAND CAPABILITY_NAMED_IAM \
            --region $REGION
        
        # Wait for creation to complete
        print_status "Waiting for stack creation to complete..."
        aws cloudformation wait stack-create-complete --stack-name $STACK_NAME --region $REGION
        
        if [ $? -eq 0 ]; then
            print_success "Stack creation completed successfully!"
        else
            print_error "Stack creation failed."
            exit 1
        fi
    fi
    
    # Get outputs
    print_status "Stack outputs:"
    aws cloudformation describe-stacks \
        --stack-name $STACK_NAME \
        --region $REGION \
        --query 'Stacks[0].Outputs[?OutputKey==`DeploymentInstructions`].OutputValue' \
        --output text
    
    # Cleanup temporary files
    print_status "Cleaning up temporary files..."
    rm -f packaged-template.yaml
    print_success "Templates remain in s3://$BUCKET_NAME for future use"
    
    print_success "Deployment script completed!"
}

# Handle command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --bucket)
            BUCKET_NAME="$2"
            shift 2
            ;;
        --region)
            REGION="$2"
            shift 2
            ;;
        --stack-name)
            STACK_NAME="$2"
            shift 2
            ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --bucket BUCKET_NAME    S3 bucket for templates (default: genovia-deployment)"
            echo "  --region REGION         AWS region (default: us-east-1)"
            echo "  --stack-name NAME       CloudFormation stack name (default: hcls-agents-toolkit)"
            echo "  --help, -h              Show this help message"
            echo ""
            echo "Environment Variables:"
            echo "  DEPLOYMENT_BUCKET       S3 bucket for templates"
            echo "  REGION                  AWS region"
            echo "  STACK_NAME              CloudFormation stack name"
            echo "  REDSHIFT_PASSWORD       Redshift password (to skip prompt)"
            echo "  REACT_APP_CIDR          CIDR for React app access (to skip prompt)"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage information."
            exit 1
            ;;
    esac
done

main "$@"
