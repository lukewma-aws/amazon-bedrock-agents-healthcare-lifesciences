#!/bin/bash

# Simple Deployment Script using CloudFormation Package
# This automatically handles template size limits and nested templates

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
    
    if [ -z "$TAVILY_API_KEY" ]; then
        echo -n "Enter Tavily API key (optional, press Enter to skip): "
        read TAVILY_API_KEY
    fi
    
    if [ -z "$USPTO_API_KEY" ]; then
        echo -n "Enter USPTO API key (optional, press Enter to skip): "
        read USPTO_API_KEY
    fi
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
    
    # Prepare parameters
    PARAMETERS="RedshiftPassword=$REDSHIFT_PASSWORD ReactAppAllowedCidr=$REACT_APP_CIDR"
    PARAMETERS="$PARAMETERS EnableBiomarkerAppInfrastructure=true"
    
    if [ ! -z "$TAVILY_API_KEY" ]; then
        PARAMETERS="$PARAMETERS TavilyApiKey=$TAVILY_API_KEY"
    fi
    
    if [ ! -z "$USPTO_API_KEY" ]; then
        PARAMETERS="$PARAMETERS USPTOApiKey=$USPTO_API_KEY"
    fi
    
    # Deploy
    print_status "Deploying CloudFormation stack..."
    
    # Check if stack exists
    if aws cloudformation describe-stacks --stack-name $STACK_NAME --region $REGION >/dev/null 2>&1; then
        print_status "Stack exists, updating..."
        aws cloudformation update-stack \
            --stack-name $STACK_NAME \
            --capabilities CAPABILITY_NAMED_IAM CAPABILITY_AUTO_EXPAND \
            --template-url "https://${BUCKET_NAME}.s3.${REGION}.amazonaws.com/$(basename packaged-template.yaml)" \
            --parameters $(echo $PARAMETERS | sed 's/ /,/g' | sed 's/=/,/g' | sed 's/,/ ParameterKey=/g' | sed 's/=/ ParameterValue=/g' | sed 's/^/ ParameterKey=/') \
            --region $REGION
        
        # Wait for update to complete
        print_status "Waiting for stack update to complete..."
        aws cloudformation wait stack-update-complete --stack-name $STACK_NAME --region $REGION
    else
        print_status "Creating new stack..."
        
        # Upload the packaged template to S3
        aws s3 cp packaged-template.yaml s3://$BUCKET_NAME/ --region $REGION
        
        # Create stack using S3 URL
        aws cloudformation create-stack \
            --stack-name $STACK_NAME \
            --template-url "https://${BUCKET_NAME}.s3.${REGION}.amazonaws.com/packaged-template.yaml" \
            --parameters $(echo $PARAMETERS | sed 's/ /,/g' | sed 's/=/,/g' | sed 's/,/ ParameterKey=/g' | sed 's/=/ ParameterValue=/g' | sed 's/^/ ParameterKey=/') \
            --capabilities CAPABILITY_NAMED_IAM CAPABILITY_AUTO_EXPAND \
            --region $REGION
        
        # Wait for creation to complete
        print_status "Waiting for stack creation to complete..."
        aws cloudformation wait stack-create-complete --stack-name $STACK_NAME --region $REGION
    fi
    
    if [ $? -eq 0 ]; then
        print_success "Deployment completed successfully!"
        
        # Get outputs
        print_status "Stack outputs:"
        aws cloudformation describe-stacks \
            --stack-name $STACK_NAME \
            --region $REGION \
            --query 'Stacks[0].Outputs'
    else
        print_error "Deployment failed."
        exit 1
    fi
    
    # Cleanup (don't delete the bucket since it's persistent)
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
            echo "  TAVILY_API_KEY          Tavily API key (optional)"
            echo "  USPTO_API_KEY           USPTO API key (optional)"
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
