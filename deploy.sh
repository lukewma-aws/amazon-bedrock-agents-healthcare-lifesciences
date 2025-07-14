#!/bin/bash

# Unified Deployment Script for HCLS Agents Toolkit
# This script can deploy either:
# 1. The entire stack with all agents (default)
# 2. Individual agents by number (e.g., 22, 23, 24)
# 3. Build and package templates without deployment

set -e

# Configuration
REGION="${REGION:-us-east-1}"
S3_BUCKET="${DEPLOYMENT_BUCKET:-genovia-deployment}"
S3_PREFIX="hcls-agents-toolkit"
STACK_NAME="${STACK_NAME:-hcls-agents-toolkit}"
DEPLOY_MODE="all"  # Default to deploy all agents
AGENT_NUMBER=""    # Individual agent number to deploy
BUILD_ONLY=false   # Default to deploy after building
SKIP_BUILD=false   # Default to build before deploying

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

# Function to check AWS CLI and credentials
check_aws_cli() {
    if ! command -v aws &> /dev/null; then
        print_error "AWS CLI is not installed. Please install it first."
        exit 1
    fi
    
    if ! aws sts get-caller-identity &> /dev/null; then
        print_error "AWS CLI is not configured. Please run 'aws configure' first."
        exit 1
    fi
    
    # Get current AWS identity info
    local aws_identity=$(aws sts get-caller-identity --output text --query 'Account')
    local aws_user=$(aws sts get-caller-identity --output text --query 'Arn')
    
    print_success "AWS CLI is configured"
    print_status "AWS Account: $aws_identity"
    print_status "AWS Identity: $aws_user"
}

# Function to check Bedrock permissions and model access
check_bedrock_access() {
    print_status "Checking Bedrock service access..."
    
    # Check if Bedrock is available in the region
    if ! aws bedrock list-foundation-models --output table 2>/dev/null | head -5; then
        print_warning "Unable to list Bedrock foundation models."
        echo
    else
        print_success "Bedrock service is accessible in region: $REGION"
        
        # Check if Claude model is available
        if aws bedrock list-foundation-models --output text --query 'modelSummaries[?contains(modelId, `claude`)].modelId' | grep -q "claude"; then
            print_success "Claude models are available"
        else
            print_warning "Claude models may not be available or enabled"
            print_status "You may need to enable model access in the Bedrock console"
        fi
    fi
    echo
}

# Function to create S3 bucket if it doesn't exist
create_s3_bucket() {
    print_status "Checking S3 bucket: $S3_BUCKET"
    
    if aws s3 ls "s3://$S3_BUCKET" 2>&1 | grep -q 'NoSuchBucket'; then
        print_status "Creating S3 bucket: $S3_BUCKET"
        if [ "$REGION" = "us-east-1" ]; then
            aws s3 mb "s3://$S3_BUCKET"
        else
            aws s3 mb "s3://$S3_BUCKET" --create-bucket-configuration LocationConstraint="$REGION"
        fi
        print_success "S3 bucket created: $S3_BUCKET"
    else
        print_success "S3 bucket exists: $S3_BUCKET"
    fi
}

# Function to run build_agents.sh for template preparation
run_build_agents() {
    print_status "Running build_agents.sh to prepare and package templates..."
    
    # Check if build_agents.sh exists
    if [ ! -f "build/build_agents.sh" ]; then
        print_error "build_agents.sh not found in build directory"
        exit 1
    fi
    
    # Export S3_BUCKET for build_agents.sh
    export S3_BUCKET="$S3_BUCKET"
    
    # Run build_agents.sh
    chmod +x build/build_agents.sh
    if ! ./build/build_agents.sh; then
        print_error "Failed to run build_agents.sh"
        exit 1
    fi
    
    print_success "Templates packaged and uploaded to S3"
}

# Function to get user inputs for full stack deployment
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

# Function to format parameters for CloudFormation
format_parameters() {
    local params=""
    params="ParameterKey=RedshiftPassword,ParameterValue=$REDSHIFT_PASSWORD"
    params="$params ParameterKey=ReactAppAllowedCidr,ParameterValue=$REACT_APP_CIDR"
    echo "$params"
}

# Function to create or get IAM role for agents (used for individual agent deployment)
create_agent_role() {
    local role_name="BedrockAgentExecutionRole"
    local stack_name="${STACK_NAME}-iam-role"
    
    print_status "Checking for existing Bedrock agent IAM role..."
    
    # Check if the role already exists
    if aws iam get-role --role-name "$role_name" &>/dev/null; then
        print_status "IAM role $role_name already exists, using existing role"
        AGENT_ROLE_ARN=$(aws iam get-role --role-name "$role_name" --query 'Role.Arn' --output text)
        print_success "Using existing IAM role: $AGENT_ROLE_ARN"
        return 0
    fi
    
    print_status "Creating IAM role for Bedrock agents and Lambda functions..."
    
    # Create IAM role template
    cat > agent-iam-role.yaml << 'EOF'
AWSTemplateFormatVersion: '2010-09-09'
Description: 'IAM Role for Bedrock Agents and Lambda Functions'

Resources:
  BedrockAgentExecutionRole:
    Type: AWS::IAM::Role
    Properties:
      RoleName: BedrockAgentExecutionRole
      AssumeRolePolicyDocument:
        Version: '2012-10-17'
        Statement:
          - Effect: Allow
            Principal:
              Service: bedrock.amazonaws.com
            Action: sts:AssumeRole
          - Effect: Allow
            Principal:
              Service: lambda.amazonaws.com
            Action: sts:AssumeRole
      ManagedPolicyArns:
        - arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
        - arn:aws:iam::aws:policy/AmazonBedrockFullAccess
        - arn:aws:iam::aws:policy/AmazonAthenaFullAccess
        - arn:aws:iam::aws:policy/AmazonS3FullAccess
        - arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole
      Policies:
        - PolicyName: BedrockAgentFullAccessPolicy
          PolicyDocument:
            Version: '2012-10-17'
            Statement:
              - Effect: Allow
                Action:
                  - bedrock:*
                  - lambda:*
                  - athena:*
                  - glue:*
                  - s3:*
                  - logs:*
                  - iam:PassRole
                Resource: '*'

Parameters:
  S3Bucket:
    Type: String
    Default: genovia-deployment

Outputs:
  RoleArn:
    Description: 'ARN of the Bedrock Agent Execution Role'
    Value: !GetAtt BedrockAgentExecutionRole.Arn
    Export:
      Name: BedrockAgentExecutionRoleArn
EOF

    # Deploy IAM role stack
    print_status "Deploying IAM role stack: $stack_name"
    if ! aws cloudformation deploy \
        --template-file agent-iam-role.yaml \
        --stack-name "$stack_name" \
        --capabilities CAPABILITY_NAMED_IAM \
        --parameter-overrides S3Bucket="$S3_BUCKET"; then
        print_error "Failed to deploy IAM role stack"
        exit 1
    fi
    
    # Get role ARN
    AGENT_ROLE_ARN=$(aws cloudformation describe-stacks \
        --stack-name "$stack_name" \
        --query 'Stacks[0].Outputs[?OutputKey==`RoleArn`].OutputValue' \
        --output text)
    
    print_success "IAM role created: $AGENT_ROLE_ARN"
    
    # Clean up temporary file
    rm -f agent-iam-role.yaml
}

# Function to package and upload an individual agent template
package_agent_template() {
    local agent_dir=$1
    local agent_template=$2
    
    print_status "Packaging $agent_template..."
    
    # Create a temporary directory for packaged templates if it doesn't exist
    mkdir -p temp_packaged_templates
    
    # Package the template
    aws cloudformation package \
        --template-file "$agent_dir/$agent_template" \
        --s3-bucket "$S3_BUCKET" \
        --s3-prefix "$S3_PREFIX/code" \
        --output-template-file "temp_packaged_templates/$(basename $agent_template)" \
        --region "$REGION"
    
    # Upload the packaged template to S3
    aws s3 cp "temp_packaged_templates/$(basename $agent_template)" "s3://$S3_BUCKET/$S3_PREFIX/templates/" --region "$REGION"
    
    print_success "Template packaged and uploaded to S3"
}

# Function to deploy an individual agent
deploy_individual_agent() {
    local agent_number=$1
    local agent_dir=""
    local agent_template=""
    local agent_name=""
    local stack_name=""
    
    # Find the agent directory and template
    agent_dir=$(find agents_catalog -maxdepth 1 -type d -name "${agent_number}-*" | head -1)
    
    if [ -z "$agent_dir" ]; then
        print_error "Agent $agent_number not found"
        exit 1
    fi
    
    # Extract agent name from directory
    agent_name=$(basename "$agent_dir" | cut -d'-' -f2- | tr -d ' ')
    
    # Find the CloudFormation template in the agent directory
    agent_template=$(find "$agent_dir" -name "*-cfn.yaml" -o -name "*-agent.yaml" | head -1)
    
    if [ -z "$agent_template" ]; then
        print_error "CloudFormation template not found in $agent_dir"
        exit 1
    fi
    
    agent_template=$(basename "$agent_template")
    stack_name="${STACK_NAME}-agent-${agent_number}"
    
    print_status "Deploying agent $agent_number: $agent_name"
    print_status "Template: $agent_dir/$agent_template"
    print_status "Stack name: $stack_name"
    
    # Package and upload the template if not skipping build
    if [ "$SKIP_BUILD" = false ]; then
        package_agent_template "$agent_dir" "$agent_template"
    else
        print_status "Skipping template packaging (--skip-build option used)"
    fi
    
    # Create IAM role if needed
    create_agent_role
    
    # Additional parameters for specific agents
    local extra_params=""
    if [[ "$agent_name" == *"athena"* ]]; then
        extra_params="AthenaResultsBucket=$S3_BUCKET"
    elif [[ "$agent_name" == *"vcf"* ]]; then
        extra_params="VcfBucketName=${STACK_NAME}-vcf-data-${AWS_ACCOUNT_ID} QueryResultsBucketName=${STACK_NAME}-vcf-query-results-${AWS_ACCOUNT_ID}"
    fi
    
    # Deploy the agent
    print_status "Deploying agent stack..."
    if ! aws cloudformation deploy \
        --template-file "temp_packaged_templates/$agent_template" \
        --stack-name "$stack_name" \
        --capabilities CAPABILITY_IAM \
        --parameter-overrides \
            AgentIAMRoleArn="$AGENT_ROLE_ARN" \
            S3CodeBucket="$S3_BUCKET" \
            S3CodeKey="$S3_PREFIX" \
            $extra_params; then
        print_error "Failed to deploy agent $agent_number"
        exit 1
    fi
    
    # Get agent outputs
    local agent_id=$(aws cloudformation describe-stacks \
        --stack-name "$stack_name" \
        --query 'Stacks[0].Outputs[?OutputKey==`AgentId`].OutputValue' \
        --output text)
    
    local agent_alias_id=$(aws cloudformation describe-stacks \
        --stack-name "$stack_name" \
        --query 'Stacks[0].Outputs[?OutputKey==`AgentAliasId`].OutputValue' \
        --output text)
    
    print_success "Agent $agent_number deployed successfully"
    print_status "Agent ID: $agent_id"
    print_status "Agent Alias ID: $agent_alias_id"
    
    # Save deployment info
    echo "$agent_number,$agent_name,$agent_id,$agent_alias_id" >> deployed-agents.csv
}

# Function to deploy the full stack
deploy_full_stack() {
    print_status "Deploying full HCLS Agents Toolkit stack..."
    
    # Get user inputs
    get_user_inputs
    
    # Package the main template if not skipping build
    if [ "$SKIP_BUILD" = false ]; then
        print_status "Packaging CloudFormation template..."
        aws cloudformation package \
            --template-file infra_cfn.yaml \
            --s3-bucket $S3_BUCKET \
            --output-template-file packaged-template.yaml \
            --region $REGION
        
        # Upload packaged template to S3
        print_status "Uploading packaged template to S3..."
        TEMPLATE_KEY="packaged-template-$(date +%s).yaml"
        aws s3 cp packaged-template.yaml s3://$S3_BUCKET/$TEMPLATE_KEY --region $REGION
        TEMPLATE_URL="https://${S3_BUCKET}.s3.${REGION}.amazonaws.com/${TEMPLATE_KEY}"
    else
        print_status "Skipping template packaging (--skip-build option used)"
        # Use the latest packaged template from S3
        print_status "Finding latest packaged template in S3..."
        TEMPLATE_KEY=$(aws s3 ls s3://$S3_BUCKET/ --region $REGION | grep packaged-template | sort -r | head -1 | awk '{print $4}')
        if [ -z "$TEMPLATE_KEY" ]; then
            print_error "No packaged template found in S3. Please run without --skip-build first."
            exit 1
        fi
        TEMPLATE_URL="https://${S3_BUCKET}.s3.${REGION}.amazonaws.com/${TEMPLATE_KEY}"
        print_status "Using template: $TEMPLATE_URL"
    fi
    
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
            --capabilities CAPABILITY_AUTO_EXPAND CAPABILITY_NAMED_IAM \
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
        --query 'Stacks[0].Outputs' \
        --output table
    
    # Cleanup temporary files
    if [ "$SKIP_BUILD" = false ]; then
        print_status "Cleaning up temporary files..."
        rm -f packaged-template.yaml
    fi
    print_success "Templates remain in s3://$S3_BUCKET for future use"
}

# Function to display deployment summary for individual agents
display_summary() {
    print_success "Deployment completed successfully!"
    echo
    print_status "Deployed Agents Summary:"
    echo "=========================="
    
    if [ -f deployed-agents.csv ]; then
        echo "Agent Number,Agent Name,Agent ID,Agent Alias ID"
        echo "=============================================="
        cat deployed-agents.csv
        echo
        
        print_status "You can now test your agents using the AWS CLI or SDK:"
        echo "aws bedrock-agent-runtime invoke-agent --agent-id <AGENT_ID> --agent-alias-id <AGENT_ALIAS_ID> --session-id test-session --input-text 'Hello'"
    fi
}

# Function to list available agents
list_available_agents() {
    print_status "Available agents:"
    echo "================="
    
    # Find all agent directories and extract their numbers and names
    find agents_catalog -maxdepth 1 -type d -name "[0-9][0-9]-*" | sort | while read dir; do
        agent_number=$(basename "$dir" | cut -d'-' -f1)
        agent_name=$(basename "$dir" | cut -d'-' -f2- | sed 's/-/ /g')
        echo "$agent_number: $agent_name"
    done
}

# Script usage
usage() {
    echo "Usage: $0 [OPTIONS]"
    echo
    echo "Options:"
    echo "  -r, --region REGION     AWS region (default: us-east-1)"
    echo "  -b, --bucket BUCKET     S3 bucket name (default: genovia-deployment)"
    echo "  -s, --stack-name NAME   Stack name prefix (default: hcls-agents-toolkit)"
    echo "  -a, --agent NUMBER      Deploy specific agent by number (e.g., 22, 23, 24)"
    echo "  -l, --list              List available agents"
    echo "  --build-only            Build and package templates without deploying"
    echo "  --skip-build            Skip building and use existing packaged templates"
    echo "  --use-build-agents      Use build_agents.sh for template preparation"
    echo "  -h, --help              Show this help message"
    echo
    echo "Environment Variables:"
    echo "  REGION                  AWS region"
    echo "  DEPLOYMENT_BUCKET       S3 bucket for templates"
    echo "  STACK_NAME              CloudFormation stack name"
    echo "  REDSHIFT_PASSWORD       Redshift password (to skip prompt)"
    echo "  REACT_APP_CIDR          CIDR for React app access (to skip prompt)"
    echo
    echo "Examples:"
    echo "  $0                      # Deploy full stack with all agents"
    echo "  $0 --agent 24           # Deploy only agent #24 (VCF Analysis)"
    echo "  $0 --list               # List all available agents"
    echo "  $0 --build-only         # Build and package templates without deploying"
    echo "  $0 --use-build-agents   # Use build_agents.sh for template preparation"
    echo "  $0 --skip-build         # Skip building and use existing packaged templates"
    echo "  $0 --region us-west-2   # Deploy to us-west-2"
    echo "  $0 --bucket my-bucket   # Use custom bucket"
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -r|--region)
            REGION="$2"
            shift 2
            ;;
        -b|--bucket)
            S3_BUCKET="$2"
            shift 2
            ;;
        -s|--stack-name)
            STACK_NAME="$2"
            shift 2
            ;;
        -a|--agent)
            DEPLOY_MODE="individual"
            AGENT_NUMBER="$2"
            shift 2
            ;;
        -l|--list)
            list_available_agents
            exit 0
            ;;
        --build-only)
            BUILD_ONLY=true
            shift
            ;;
        --skip-build)
            SKIP_BUILD=true
            shift
            ;;
        --use-build-agents)
            USE_BUILD_AGENTS=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            print_error "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

# Main function
main() {
    print_status "Starting HCLS Agents Toolkit Deployment"
    print_status "Region: $REGION"
    print_status "S3 Bucket: $S3_BUCKET"
    print_status "Stack Name: $STACK_NAME"
    
    if [ "$BUILD_ONLY" = true ]; then
        print_status "Mode: Build Only (No Deployment)"
    elif [ "$DEPLOY_MODE" = "individual" ]; then
        print_status "Deployment Mode: Individual Agent #$AGENT_NUMBER"
    else
        print_status "Deployment Mode: Full Stack"
    fi
    echo
    
    # Set AWS region for all CLI commands
    export AWS_DEFAULT_REGION="$REGION"
    
    # Get AWS account ID
    AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
    
    # Check prerequisites
    check_aws_cli
    
    if [ "$BUILD_ONLY" = false ]; then
        check_bedrock_access
    fi
    
    # Create S3 bucket
    create_s3_bucket
    
    # Initialize deployment tracking for individual agents
    if [ "$DEPLOY_MODE" = "individual" ]; then
        rm -f deployed-agents.csv
    fi
    
    # Run build_agents.sh if requested
    if [ "$USE_BUILD_AGENTS" = true ]; then
        run_build_agents
        
        # If build-only mode, exit after building
        if [ "$BUILD_ONLY" = true ]; then
            print_success "Build completed successfully!"
            exit 0
        fi
        
        # Set skip-build to true since we've already built
        SKIP_BUILD=true
    fi
    
    # If build-only mode and not using build_agents.sh, run appropriate build steps
    if [ "$BUILD_ONLY" = true ] && [ "$USE_BUILD_AGENTS" != true ]; then
        if [ "$DEPLOY_MODE" = "individual" ]; then
            # Find the agent directory and template
            agent_dir=$(find agents_catalog -maxdepth 1 -type d -name "${AGENT_NUMBER}-*" | head -1)
            
            if [ -z "$agent_dir" ]; then
                print_error "Agent $AGENT_NUMBER not found"
                exit 1
            fi
            
            # Find the CloudFormation template in the agent directory
            agent_template=$(find "$agent_dir" -name "*-cfn.yaml" -o -name "*-agent.yaml" | head -1)
            
            if [ -z "$agent_template" ]; then
                print_error "CloudFormation template not found in $agent_dir"
                exit 1
            fi
            
            agent_template=$(basename "$agent_template")
            package_agent_template "$agent_dir" "$agent_template"
        else
            # Package the main template
            print_status "Packaging CloudFormation template..."
            aws cloudformation package \
                --template-file infra_cfn.yaml \
                --s3-bucket $S3_BUCKET \
                --output-template-file packaged-template.yaml \
                --region $REGION
            
            # Upload packaged template to S3
            print_status "Uploading packaged template to S3..."
            TEMPLATE_KEY="packaged-template-$(date +%s).yaml"
            aws s3 cp packaged-template.yaml s3://$S3_BUCKET/$TEMPLATE_KEY --region $REGION
            
            # Cleanup temporary files
            rm -f packaged-template.yaml
        fi
        
        print_success "Build completed successfully!"
        exit 0
    fi
    
    # Deploy based on mode
    if [ "$DEPLOY_MODE" = "individual" ]; then
        deploy_individual_agent "$AGENT_NUMBER"
        display_summary
    else
        deploy_full_stack
    fi
    
    print_success "Deployment script completed!"
}

# Run main function
main
