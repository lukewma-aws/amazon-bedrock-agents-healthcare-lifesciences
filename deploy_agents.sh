#!/bin/bash

# Unified Deployment Script for HCLS Agents Toolkit
# This script combines functionality from deploy.sh, deploy_local.sh, and deploy_packaged.sh
# It can:
# 1. Deploy the entire stack with all agents (default)
# 2. Deploy individual agents by number (e.g., 22, 23, 24)
# 3. Deploy agents with local changes
# 4. Deploy pre-packaged agents without rebuilding
# 5. Build and package templates without deployment

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
USE_LOCAL=false    # Default to not use local changes
USE_PACKAGED=false # Default to not use pre-packaged templates

# Array to store parameter overrides for CloudFormation
declare -a PARAMETER_OVERRIDES=()

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
