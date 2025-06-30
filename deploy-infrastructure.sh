#!/bin/bash

# Biomarker Application Infrastructure Deployment Script
# This script deploys the complete infrastructure for the healthcare biomarker discovery application

set -e

# Configuration
STACK_NAME="biomarker-app-infrastructure"
TEMPLATE_FILE="biomarker-app-infrastructure.yaml"
REGION="us-east-1"
ENVIRONMENT="prod"
PROJECT_NAME="biomarker-app"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to check prerequisites
check_prerequisites() {
    print_status "Checking prerequisites..."
    
    # Check AWS CLI
    if ! command -v aws &> /dev/null; then
        print_error "AWS CLI is not installed. Please install it first."
        exit 1
    fi
    
    # Check AWS credentials
    if ! aws sts get-caller-identity &> /dev/null; then
        print_error "AWS credentials not configured. Please run 'aws configure'."
        exit 1
    fi
    
    # Check if template file exists
    if [ ! -f "$TEMPLATE_FILE" ]; then
        print_error "CloudFormation template file '$TEMPLATE_FILE' not found."
        exit 1
    fi
    
    print_success "Prerequisites check passed."
}

# Function to get VPC and subnet information
get_vpc_info() {
    print_status "Retrieving VPC and subnet information..."
    
    # Get default VPC (or use existing one)
    VPC_ID=$(aws ec2 describe-vpcs \
        --filters "Name=tag:Name,Values=*biomarker*" \
        --query 'Vpcs[0].VpcId' \
        --output text \
        --region $REGION 2>/dev/null || echo "")
    
    if [ "$VPC_ID" == "None" ] || [ -z "$VPC_ID" ]; then
        # Use the existing VPC from the infrastructure analysis
        VPC_ID="vpc-0640bbe32a3af7163"
        print_warning "Using existing VPC: $VPC_ID"
    fi
    
    # Get private subnets
    PRIVATE_SUBNETS=$(aws ec2 describe-subnets \
        --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:Type,Values=Private" \
        --query 'Subnets[].SubnetId' \
        --output text \
        --region $REGION 2>/dev/null || echo "")
    
    if [ -z "$PRIVATE_SUBNETS" ]; then
        # Get any available subnets
        PRIVATE_SUBNETS=$(aws ec2 describe-subnets \
            --filters "Name=vpc-id,Values=$VPC_ID" \
            --query 'Subnets[0:2].SubnetId' \
            --output text \
            --region $REGION)
    fi
    
    # Get public subnets
    PUBLIC_SUBNETS=$(aws ec2 describe-subnets \
        --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:Type,Values=Public" \
        --query 'Subnets[].SubnetId' \
        --output text \
        --region $REGION 2>/dev/null || echo "")
    
    if [ -z "$PUBLIC_SUBNETS" ]; then
        # Use the same subnets as private if no public subnets found
        PUBLIC_SUBNETS=$PRIVATE_SUBNETS
    fi
    
    print_success "VPC Info - VPC: $VPC_ID, Private Subnets: $PRIVATE_SUBNETS, Public Subnets: $PUBLIC_SUBNETS"
}

# Function to validate CloudFormation template
validate_template() {
    print_status "Validating CloudFormation template..."
    
    if aws cloudformation validate-template \
        --template-body file://$TEMPLATE_FILE \
        --region $REGION > /dev/null; then
        print_success "Template validation passed."
    else
        print_error "Template validation failed."
        exit 1
    fi
}

# Function to deploy the stack
deploy_stack() {
    print_status "Deploying CloudFormation stack: $STACK_NAME"
    
    # Convert subnet lists to comma-separated format
    PRIVATE_SUBNET_LIST=$(echo $PRIVATE_SUBNETS | tr ' ' ',')
    PUBLIC_SUBNET_LIST=$(echo $PUBLIC_SUBNETS | tr ' ' ',')
    
    # Deploy the stack
    aws cloudformation deploy \
        --template-file $TEMPLATE_FILE \
        --stack-name $STACK_NAME \
        --parameter-overrides \
            Environment=$ENVIRONMENT \
            ProjectName=$PROJECT_NAME \
            VpcId=$VPC_ID \
            PrivateSubnetIds=$PRIVATE_SUBNET_LIST \
            PublicSubnetIds=$PUBLIC_SUBNET_LIST \
        --capabilities CAPABILITY_NAMED_IAM \
        --region $REGION \
        --no-fail-on-empty-changeset
    
    if [ $? -eq 0 ]; then
        print_success "Stack deployment completed successfully."
    else
        print_error "Stack deployment failed."
        exit 1
    fi
}

# Function to get stack outputs
get_stack_outputs() {
    print_status "Retrieving stack outputs..."
    
    aws cloudformation describe-stacks \
        --stack-name $STACK_NAME \
        --region $REGION \
        --query 'Stacks[0].Outputs[?OutputKey==`DeploymentInstructions`].OutputValue' \
        --output text
}

# Function to setup post-deployment tasks
post_deployment_setup() {
    print_status "Running post-deployment setup..."
    
    # Get the S3 bucket name
    BUCKET_NAME=$(aws cloudformation describe-stacks \
        --stack-name $STACK_NAME \
        --region $REGION \
        --query 'Stacks[0].Outputs[?OutputKey==`BiomarkerDataBucketName`].OutputValue' \
        --output text)
    
    if [ ! -z "$BUCKET_NAME" ]; then
        print_status "Creating sample folder structure in S3 bucket: $BUCKET_NAME"
        
        # Create folder structure
        aws s3api put-object --bucket $BUCKET_NAME --key biomarker-data/ --region $REGION
        aws s3api put-object --bucket $BUCKET_NAME --key user-uploads/ --region $REGION
        aws s3api put-object --bucket $BUCKET_NAME --key processed-data/ --region $REGION
        
        print_success "S3 folder structure created."
    fi
    
    # Check if Bedrock agents are accessible
    print_status "Validating Bedrock agent access..."
    
    if aws bedrock-agent get-agent --agent-id UR5AFSSQXN --region $REGION > /dev/null 2>&1; then
        print_success "Biomarker database analyst agent is accessible."
    else
        print_warning "Biomarker database analyst agent may not be accessible."
    fi
    
    if aws bedrock-agent get-agent --agent-id Q3Y7J9OP5Q --region $REGION > /dev/null 2>&1; then
        print_success "Clinical evidence researcher agent is accessible."
    else
        print_warning "Clinical evidence researcher agent may not be accessible."
    fi
}

# Function to display next steps
display_next_steps() {
    print_success "Deployment completed successfully!"
    echo ""
    echo "Next Steps:"
    echo "1. Configure your Amplify application with your GitHub repository"
    echo "2. Set up Cognito user pool users for testing"
    echo "3. Upload sample biomarker data to the S3 bucket"
    echo "4. Test the application functionality"
    echo "5. Configure monitoring and alerting"
    echo ""
    echo "Stack Outputs:"
    get_stack_outputs
    echo ""
    echo "To view all stack outputs, run:"
    echo "aws cloudformation describe-stacks --stack-name $STACK_NAME --region $REGION --query 'Stacks[0].Outputs'"
}

# Main execution
main() {
    echo "========================================="
    echo "Biomarker Application Infrastructure Deployment"
    echo "========================================="
    echo ""
    
    check_prerequisites
    get_vpc_info
    validate_template
    deploy_stack
    post_deployment_setup
    display_next_steps
    
    print_success "Deployment script completed successfully!"
}

# Handle script arguments
case "${1:-}" in
    --help|-h)
        echo "Usage: $0 [OPTIONS]"
        echo ""
        echo "Options:"
        echo "  --help, -h          Show this help message"
        echo "  --validate-only     Only validate the template"
        echo "  --delete-stack      Delete the CloudFormation stack"
        echo ""
        echo "Environment Variables:"
        echo "  STACK_NAME          CloudFormation stack name (default: biomarker-app-infrastructure)"
        echo "  REGION              AWS region (default: us-east-1)"
        echo "  ENVIRONMENT         Deployment environment (default: prod)"
        echo "  PROJECT_NAME        Project name (default: biomarker-app)"
        exit 0
        ;;
    --validate-only)
        check_prerequisites
        validate_template
        print_success "Template validation completed."
        exit 0
        ;;
    --delete-stack)
        print_warning "Deleting CloudFormation stack: $STACK_NAME"
        aws cloudformation delete-stack --stack-name $STACK_NAME --region $REGION
        print_success "Stack deletion initiated."
        exit 0
        ;;
    "")
        main
        ;;
    *)
        print_error "Unknown option: $1"
        echo "Use --help for usage information."
        exit 1
        ;;
esac
