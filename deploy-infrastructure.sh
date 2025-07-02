#!/bin/bash

# HCLS Agents Toolkit with Enhanced Biomarker Infrastructure Deployment Script
# This script deploys the complete HCLS agents toolkit with additional biomarker application infrastructure

set -e

# Configuration
STACK_NAME="hcls-agents-toolkit"
TEMPLATE_FILE="infra_cfn.yaml"
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
    
    # Check Bedrock model access
    print_status "Checking Bedrock model access..."
    if ! aws bedrock list-foundation-models --region $REGION > /dev/null 2>&1; then
        print_warning "Unable to verify Bedrock model access. Please ensure you have requested access to required models."
    fi
    
    print_success "Prerequisites check passed."
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

# Function to package the template
package_template() {
    print_status "Packaging CloudFormation template..."
    
    # Create a temporary S3 bucket for packaging if needed
    BUCKET_NAME="${STACK_NAME}-templates-${RANDOM}-$(date +%s)"
    
    if aws s3 mb s3://$BUCKET_NAME --region $REGION; then
        print_success "Created packaging bucket: $BUCKET_NAME"
        
        # Create Lambda deployment packages
        print_status "Creating Lambda deployment packages..."
        create_lambda_packages
        
        # Upload nested templates to S3
        print_status "Uploading nested templates..."
        aws s3 cp biomarker-app-infrastructure.yaml s3://$BUCKET_NAME/ --region $REGION
        aws s3 cp biomarker-lambda-functions.yaml s3://$BUCKET_NAME/ --region $REGION
        aws s3 cp healthomics-integration.yaml s3://$BUCKET_NAME/ --region $REGION
        aws s3 cp biomarker-workflows.yaml s3://$BUCKET_NAME/ --region $REGION
        
        # Upload Lambda code packages
        aws s3 cp lambda-packages/ s3://$BUCKET_NAME/lambda-packages/ --recursive --region $REGION
        
        # Set template S3 bucket parameter
        TEMPLATE_S3_BUCKET=$BUCKET_NAME
        print_success "Templates and Lambda packages uploaded successfully."
    else
        print_error "Could not create packaging bucket. Trying CloudFormation package command..."
        
        # Fallback to CloudFormation package
        BUCKET_NAME="${STACK_NAME}-cfn-package-${RANDOM}-$(date +%s)"
        aws s3 mb s3://$BUCKET_NAME --region $REGION
        
        aws cloudformation package \
            --template-file $TEMPLATE_FILE \
            --s3-bucket $BUCKET_NAME \
            --output-template-file packaged_$TEMPLATE_FILE \
            --region $REGION
        
        TEMPLATE_FILE="packaged_$TEMPLATE_FILE"
        print_success "Template packaged successfully."
    fi
}

# Function to create Lambda deployment packages
create_lambda_packages() {
    print_status "Creating Lambda deployment packages..."
    
    # Create packages directory
    mkdir -p lambda-packages
    
    # Package literature search function
    cd lambda-code
    zip -r ../lambda-packages/literature-search.zip literature-search.py
    zip -r ../lambda-packages/data-processing.zip data-processing.py
    zip -r ../lambda-packages/healthomics-integration.zip healthomics-integration.py
    cd ..
    
    print_success "Lambda packages created."
}

# Function to get user inputs
get_user_inputs() {
    print_status "Gathering deployment parameters..."
    
    # Get Redshift password
    if [ -z "$REDSHIFT_PASSWORD" ]; then
        echo -n "Enter Redshift password (8+ chars, must contain uppercase, lowercase, and number): "
        read -s REDSHIFT_PASSWORD
        echo
        
        # Validate password
        if [[ ! $REDSHIFT_PASSWORD =~ ^(?=.*[a-z])(?=.*[A-Z])(?=.*[0-9]).{8,}$ ]]; then
            print_error "Password does not meet requirements."
            exit 1
        fi
    fi
    
    # Get CIDR for React app access
    if [ -z "$REACT_APP_CIDR" ]; then
        echo -n "Enter CIDR range for React app access (e.g., 192.168.1.0/24): "
        read REACT_APP_CIDR
        
        # Basic CIDR validation
        if [[ ! $REACT_APP_CIDR =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]]; then
            print_error "Invalid CIDR format."
            exit 1
        fi
    fi
    
    # Optional API keys
    if [ -z "$TAVILY_API_KEY" ]; then
        echo -n "Enter Tavily API key (optional, press Enter to skip): "
        read TAVILY_API_KEY
    fi
    
    if [ -z "$USPTO_API_KEY" ]; then
        echo -n "Enter USPTO API key (optional, press Enter to skip): "
        read USPTO_API_KEY
    fi
    
    print_success "User inputs collected."
}

# Function to deploy the stack
deploy_stack() {
    print_status "Deploying CloudFormation stack: $STACK_NAME"
    
    # Prepare parameter overrides
    PARAMETER_OVERRIDES="RedshiftPassword=$REDSHIFT_PASSWORD ReactAppAllowedCidr=$REACT_APP_CIDR"
    PARAMETER_OVERRIDES="$PARAMETER_OVERRIDES EnableBiomarkerAppInfrastructure=true"
    PARAMETER_OVERRIDES="$PARAMETER_OVERRIDES ProjectName=$PROJECT_NAME Environment=$ENVIRONMENT"
    
    # Add S3 bucket parameter if we created one
    if [ ! -z "$TEMPLATE_S3_BUCKET" ]; then
        PARAMETER_OVERRIDES="$PARAMETER_OVERRIDES TemplateS3Bucket=$TEMPLATE_S3_BUCKET"
    fi
    
    if [ ! -z "$TAVILY_API_KEY" ]; then
        PARAMETER_OVERRIDES="$PARAMETER_OVERRIDES TavilyApiKey=$TAVILY_API_KEY"
    fi
    
    if [ ! -z "$USPTO_API_KEY" ]; then
        PARAMETER_OVERRIDES="$PARAMETER_OVERRIDES USPTOApiKey=$USPTO_API_KEY"
    fi
    
    # Deploy the stack
    aws cloudformation deploy \
        --template-file $TEMPLATE_FILE \
        --stack-name $STACK_NAME \
        --parameter-overrides $PARAMETER_OVERRIDES \
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
        --query 'Stacks[0].Outputs'
}

# Function to setup post-deployment tasks
post_deployment_setup() {
    print_status "Running post-deployment setup..."
    
    # Get the biomarker data bucket name
    BUCKET_NAME=$(aws cloudformation describe-stacks \
        --stack-name $STACK_NAME \
        --region $REGION \
        --query 'Stacks[0].Outputs[?OutputKey==`BiomarkerDataBucketName`].OutputValue' \
        --output text 2>/dev/null || echo "")
    
    if [ ! -z "$BUCKET_NAME" ] && [ "$BUCKET_NAME" != "None" ]; then
        print_status "Creating sample folder structure in S3 bucket: $BUCKET_NAME"
        
        # Create folder structure
        aws s3api put-object --bucket $BUCKET_NAME --key biomarker-data/ --region $REGION
        aws s3api put-object --bucket $BUCKET_NAME --key user-uploads/ --region $REGION
        aws s3api put-object --bucket $BUCKET_NAME --key processed-data/ --region $REGION
        
        print_success "S3 folder structure created."
    fi
    
    # Test Lambda functions
    print_status "Testing Lambda functions..."
    
    LITERATURE_FUNCTION=$(aws cloudformation describe-stacks \
        --stack-name $STACK_NAME \
        --region $REGION \
        --query 'Stacks[0].Outputs[?OutputKey==`ScientificLiteratureSearchFunctionArn`].OutputValue' \
        --output text 2>/dev/null || echo "")
    
    if [ ! -z "$LITERATURE_FUNCTION" ] && [ "$LITERATURE_FUNCTION" != "None" ]; then
        print_status "Testing literature search function..."
        aws lambda invoke \
            --function-name $LITERATURE_FUNCTION \
            --payload '{"query": "BRCA1 biomarker", "max_results": 5}' \
            --region $REGION \
            /tmp/test-output.json > /dev/null 2>&1
        
        if [ $? -eq 0 ]; then
            print_success "Literature search function test passed."
        else
            print_warning "Literature search function test failed."
        fi
    fi
    
    # Test HealthOmics integration function
    HEALTHOMICS_FUNCTION=$(aws cloudformation describe-stacks \
        --stack-name $STACK_NAME \
        --region $REGION \
        --query 'Stacks[0].Outputs[?OutputKey==`HealthOmicsIntegrationFunctionArn`].OutputValue' \
        --output text 2>/dev/null || echo "")
    
    if [ ! -z "$HEALTHOMICS_FUNCTION" ] && [ "$HEALTHOMICS_FUNCTION" != "None" ]; then
        print_status "Testing HealthOmics integration function..."
        aws lambda invoke \
            --function-name $HEALTHOMICS_FUNCTION \
            --payload '{"operation": "list_stores"}' \
            --region $REGION \
            /tmp/healthomics-test-output.json > /dev/null 2>&1
        
        if [ $? -eq 0 ]; then
            print_success "HealthOmics integration function test passed."
            
            # Test variant query
            print_status "Testing variant store query..."
            aws lambda invoke \
                --function-name $HEALTHOMICS_FUNCTION \
                --payload '{"operation": "query_variants", "biomarker": "BRCA1", "variant_store_id": "368016e44044"}' \
                --region $REGION \
                /tmp/variant-test-output.json > /dev/null 2>&1
            
            if [ $? -eq 0 ]; then
                print_success "Variant store query test passed."
            else
                print_warning "Variant store query test failed."
            fi
        else
            print_warning "HealthOmics integration function test failed."
        fi
    fi
    
    # Clean up packaging resources
    if [ ! -z "$BUCKET_NAME" ] && [[ $BUCKET_NAME == *"templates"* ]] || [[ $BUCKET_NAME == *"cfn-package"* ]]; then
        print_status "Cleaning up packaging resources..."
        aws s3 rb s3://$BUCKET_NAME --force --region $REGION 2>/dev/null || true
        rm -f packaged_infra_cfn.yaml 2>/dev/null || true
        rm -rf lambda-packages 2>/dev/null || true
    fi
}

# Function to display next steps
display_next_steps() {
    print_success "Deployment completed successfully!"
    echo ""
    echo "========================================="
    echo "HCLS Agents Toolkit with Enhanced Biomarker Infrastructure"
    echo "========================================="
    echo ""
    echo "Deployed Components:"
    echo "• Multi-agent biomarker discovery system"
    echo "• Clinical trial protocol assistant"
    echo "• Competitive intelligence agents"
    echo "• Enhanced data processing infrastructure"
    echo "• Scientific literature search capabilities"
    echo "• Automated analysis workflows"
    echo "• React web application"
    echo ""
    echo "Next Steps:"
    echo "1. Access the React application using the URL from stack outputs"
    echo "2. Upload sample biomarker data to test the system"
    echo "3. Explore the multi-agent collaboration features"
    echo "4. Configure monitoring and alerting"
    echo "5. Set up user authentication and access controls"
    echo ""
    echo "Stack Outputs:"
    get_stack_outputs
    echo ""
    echo "For detailed usage instructions, see the README.md file."
    echo "For troubleshooting, see the DEPLOYMENT.md file."
}

# Function to cleanup resources
cleanup_stack() {
    print_warning "Deleting CloudFormation stack: $STACK_NAME"
    echo "This will delete all resources including data. Are you sure? (y/N)"
    read -r response
    
    if [[ "$response" =~ ^[Yy]$ ]]; then
        aws cloudformation delete-stack --stack-name $STACK_NAME --region $REGION
        print_success "Stack deletion initiated."
        
        print_status "Waiting for stack deletion to complete..."
        aws cloudformation wait stack-delete-complete --stack-name $STACK_NAME --region $REGION
        print_success "Stack deletion completed."
    else
        print_status "Stack deletion cancelled."
    fi
}

# Main execution
main() {
    echo "========================================="
    echo "HCLS Agents Toolkit Enhanced Deployment"
    echo "========================================="
    echo ""
    
    check_prerequisites
    validate_template
    package_template
    get_user_inputs
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
        echo "  --package-only      Only package the template"
        echo ""
        echo "Environment Variables:"
        echo "  STACK_NAME          CloudFormation stack name (default: hcls-agents-toolkit)"
        echo "  REGION              AWS region (default: us-east-1)"
        echo "  ENVIRONMENT         Deployment environment (default: prod)"
        echo "  PROJECT_NAME        Project name (default: biomarker-app)"
        echo "  REDSHIFT_PASSWORD   Redshift password (will prompt if not set)"
        echo "  REACT_APP_CIDR      CIDR for React app access (will prompt if not set)"
        echo "  TAVILY_API_KEY      Tavily API key (optional)"
        echo "  USPTO_API_KEY       USPTO API key (optional)"
        exit 0
        ;;
    --validate-only)
        check_prerequisites
        validate_template
        print_success "Template validation completed."
        exit 0
        ;;
    --package-only)
        check_prerequisites
        validate_template
        package_template
        print_success "Template packaging completed."
        exit 0
        ;;
    --delete-stack)
        cleanup_stack
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
