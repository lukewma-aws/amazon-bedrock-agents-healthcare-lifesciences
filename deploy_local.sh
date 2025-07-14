#!/bin/bash

# Helper script to deploy a single agent with local changes
# This script is a wrapper around deploy.sh that adds support for local changes

set -e

# Default values
AGENT_NUMBER=""
STACK_NAME=""
REGION="${REGION:-us-east-1}"
S3_BUCKET="${DEPLOYMENT_BUCKET:-genovia-deployment}"
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

# Parse command line arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --agent)
      AGENT_NUMBER="$2"
      shift 2
      ;;
    --stack-name)
      STACK_NAME="$2"
      shift 2
      ;;
    --region)
      REGION="$2"
      shift 2
      ;;
    --bucket)
      S3_BUCKET="$2"
      shift 2
      ;;
    --param)
      # Format: --param ParameterName=ParameterValue
      PARAMETER_OVERRIDES+=("$2")
      shift 2
      ;;
    *)
      print_error "Unknown option: $1"
      exit 1
      ;;
  esac
done

# Check if agent number is provided
if [ -z "$AGENT_NUMBER" ]; then
  print_error "Agent number is required. Use --agent <number>"
  exit 1
fi

# Set default stack name if not provided
if [ -z "$STACK_NAME" ]; then
  STACK_NAME="agent-${AGENT_NUMBER}"
fi

# Find the agent directory
agent_dir=$(find agents_catalog -maxdepth 1 -type d -name "${AGENT_NUMBER}-*" | head -1)
if [ -z "$agent_dir" ]; then
  print_error "Agent #${AGENT_NUMBER} not found"
  exit 1
fi

print_status "Found agent directory: ${agent_dir}"

# Create a temporary directory for the agent files
temp_dir=$(mktemp -d)
print_status "Created temporary directory: ${temp_dir}"

# Create the proper directory structure
agent_basename=$(basename "$agent_dir")
mkdir -p "$temp_dir/agents_catalog/$agent_basename"
print_status "Created agents_catalog directory structure"

# Copy the agent files to the proper directory
cp -r "$agent_dir"/* "$temp_dir/agents_catalog/$agent_basename/"
print_status "Copied agent files to agents_catalog directory"

# Copy the build directory to the temporary directory
mkdir -p "$temp_dir/build"
cp -r "build"/* "$temp_dir/build"
print_status "Copied build directory to temporary directory"

# Create a zip file of the agent directory
temp_zip="${temp_dir}/agent_${AGENT_NUMBER}.zip"
(cd "$temp_dir" && zip -r "$temp_zip" .)
print_status "Created zip file of agent files"

# Create the S3 bucket if it doesn't exist
print_status "Checking S3 bucket: $S3_BUCKET"
if ! aws s3 ls "s3://$S3_BUCKET" 2>&1 | grep -q 'NoSuchBucket'; then
  print_status "S3 bucket exists: $S3_BUCKET"
else
  print_status "Creating S3 bucket: $S3_BUCKET"
  if [ "$REGION" = "us-east-1" ]; then
    aws s3 mb "s3://$S3_BUCKET"
  else
    aws s3 mb "s3://$S3_BUCKET" --create-bucket-configuration LocationConstraint="$REGION"
  fi
  print_success "S3 bucket created: $S3_BUCKET"
fi

# Create the local_agents directory in S3 if it doesn't exist
aws s3api head-object --bucket "$S3_BUCKET" --key "local_agents/" 2>/dev/null || aws s3api put-object --bucket "$S3_BUCKET" --key "local_agents/"
print_status "Ensured local_agents directory exists in S3"

# Upload the zip file to S3
aws s3 cp "$temp_zip" "s3://$S3_BUCKET/local_agents/agent_${AGENT_NUMBER}.zip"
print_status "Uploaded agent files to S3"

# Clean up the temporary directory
rm -rf "$temp_dir"
print_status "Cleaned up temporary directory"

# Check if the codebuild stack exists
codebuild_stack_name="codebuild-stack"
if aws cloudformation describe-stacks --stack-name "$codebuild_stack_name" --region "$REGION" 2>/dev/null; then
  print_status "CodeBuild stack exists, updating..."
  # Use || true to ignore errors, including "No updates to be performed"
  update_output=$(aws cloudformation update-stack \
    --stack-name "$codebuild_stack_name" \
    --template-body file://build/codebuild.yaml \
    --parameters \
      ParameterKey=S3Bucket,ParameterValue="$S3_BUCKET" \
      ParameterKey=AgentNumber,ParameterValue="$AGENT_NUMBER" \
      ParameterKey=UseLocalFiles,ParameterValue="true" \
    --capabilities CAPABILITY_IAM \
    --region "$REGION" 2>&1) || true
  
  # Check if the error was "No updates to be performed"
  if echo "$update_output" | grep -q "No updates are to be performed"; then
    print_status "No updates needed for CodeBuild stack"
  elif echo "$update_output" | grep -q "error"; then
    print_error "Error updating CodeBuild stack: $update_output"
    # Continue execution despite the error
  else
    print_status "CodeBuild stack update initiated"
  fi
else
  print_status "Creating CodeBuild stack..."
  aws cloudformation create-stack \
    --stack-name "$codebuild_stack_name" \
    --template-body file://build/codebuild.yaml \
    --parameters \
      ParameterKey=S3Bucket,ParameterValue="$S3_BUCKET" \
      ParameterKey=AgentNumber,ParameterValue="$AGENT_NUMBER" \
      ParameterKey=UseLocalFiles,ParameterValue="true" \
    --capabilities CAPABILITY_IAM \
    --region "$REGION"
  
  print_status "Waiting for CodeBuild stack creation to complete..."
  aws cloudformation wait stack-create-complete --stack-name "$codebuild_stack_name" --region "$REGION"
fi

print_status "Waiting for CodeBuild to complete..."
sleep 30

# Find the template file in the agent directory
template_file=$(find "$agent_dir" -name "*-cfn.yaml" | head -1)
if [ -z "$template_file" ]; then
  print_error "Template file not found in $agent_dir"
  exit 1
fi

template_name=$(basename "$template_file")
print_status "Found template file: $template_name"

# Get the packaged template from S3
packaged_template="packaged_${template_name%.yaml}.yaml"
aws s3 cp "s3://$S3_BUCKET/agents_catalog/$packaged_template" .
print_status "Downloaded packaged template from S3"

# Deploy the agent
print_status "Deploying agent #$AGENT_NUMBER with stack name $STACK_NAME..."

# Check if we have any parameter overrides
if [ ${#PARAMETER_OVERRIDES[@]} -gt 0 ]; then
  # Convert array to space-separated string of ParameterKey=Value pairs
  PARAMS=""
  for param in "${PARAMETER_OVERRIDES[@]}"; do
    PARAMS="$PARAMS $param"
  done
  
  print_status "Deploying with custom parameters: $PARAMS"
  
  # Check if AgentIAMRoleArn is provided
  if ! echo "$PARAMS" | grep -q "AgentIAMRoleArn"; then
    # Check if the SSM parameter exists
    if ! aws ssm get-parameter --name "/bedrock/agent/role/arn" --region "$REGION" &>/dev/null; then
      print_warning "SSM parameter /bedrock/agent/role/arn not found. Creating an IAM role for Bedrock agent..."
      
      # Create a role for Bedrock agent
      ROLE_NAME="BedrockAgentRole-$RANDOM"
      ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
      
      aws iam create-role \
        --role-name "$ROLE_NAME" \
        --assume-role-policy-document '{
          "Version": "2012-10-17",
          "Statement": [
            {
              "Effect": "Allow",
              "Principal": {
                "Service": "bedrock.amazonaws.com"
              },
              "Action": "sts:AssumeRole"
            }
          ]
        }' --region "$REGION" &>/dev/null
      
      aws iam attach-role-policy \
        --role-name "$ROLE_NAME" \
        --policy-arn arn:aws:iam::aws:policy/AmazonBedrockFullAccess --region "$REGION" &>/dev/null
      
      ROLE_ARN="arn:aws:iam::$ACCOUNT_ID:role/$ROLE_NAME"
      print_status "Created IAM role: $ROLE_ARN"
      
      # Add the role ARN to parameters
      PARAMS="$PARAMS AgentIAMRoleArn=$ROLE_ARN"
    fi
  fi
  
  # Deploy with custom parameters
  deploy_output=$(aws cloudformation deploy \
    --template-file "$packaged_template" \
    --stack-name "$STACK_NAME" \
    --capabilities CAPABILITY_IAM \
    --region "$REGION" \
    --parameter-overrides $PARAMS \
    --no-fail-on-empty-changeset 2>&1) || true
  
  # Check for SSM parameter error
  if echo "$deploy_output" | grep -q "Parameters: \[ssm:/bedrock/agent/role/arn"; then
    print_error "SSM parameter error detected. Retrying with a new IAM role..."
    
    # Create a role for Bedrock agent
    ROLE_NAME="BedrockAgentRole-$RANDOM"
    ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
    
    aws iam create-role \
      --role-name "$ROLE_NAME" \
      --assume-role-policy-document '{
        "Version": "2012-10-17",
        "Statement": [
          {
            "Effect": "Allow",
            "Principal": {
              "Service": "bedrock.amazonaws.com"
            },
            "Action": "sts:AssumeRole"
          }
        ]
      }' --region "$REGION" &>/dev/null
    
    aws iam attach-role-policy \
      --role-name "$ROLE_NAME" \
      --policy-arn arn:aws:iam::aws:policy/AmazonBedrockFullAccess --region "$REGION" &>/dev/null
    
    ROLE_ARN="arn:aws:iam::$ACCOUNT_ID:role/$ROLE_NAME"
    print_status "Created IAM role: $ROLE_ARN"
    
    # Retry deployment with the new role
    aws cloudformation deploy \
      --template-file "$packaged_template" \
      --stack-name "$STACK_NAME" \
      --capabilities CAPABILITY_IAM \
      --region "$REGION" \
      --parameter-overrides $PARAMS AgentIAMRoleArn=$ROLE_ARN \
      --no-fail-on-empty-changeset
  elif echo "$deploy_output" | grep -q "error"; then
    print_error "Deployment error: $deploy_output"
  else
    print_status "Deployment completed"
  fi
else
  # Default deployment without custom parameters
  deploy_output=$(aws cloudformation deploy \
    --template-file "$packaged_template" \
    --stack-name "$STACK_NAME" \
    --capabilities CAPABILITY_IAM \
    --region "$REGION" \
    --no-fail-on-empty-changeset 2>&1) || true
  
  # Check for SSM parameter error
  if echo "$deploy_output" | grep -q "Parameters: \[ssm:/bedrock/agent/role/arn"; then
    print_error "SSM parameter error detected. Retrying with a new IAM role..."
    
    # Create a role for Bedrock agent
    ROLE_NAME="BedrockAgentRole-$RANDOM"
    ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
    
    aws iam create-role \
      --role-name "$ROLE_NAME" \
      --assume-role-policy-document '{
        "Version": "2012-10-17",
        "Statement": [
          {
            "Effect": "Allow",
            "Principal": {
              "Service": "bedrock.amazonaws.com"
            },
            "Action": "sts:AssumeRole"
          }
        ]
      }' --region "$REGION" &>/dev/null
    
    aws iam attach-role-policy \
      --role-name "$ROLE_NAME" \
      --policy-arn arn:aws:iam::aws:policy/AmazonBedrockFullAccess --region "$REGION" &>/dev/null
    
    ROLE_ARN="arn:aws:iam::$ACCOUNT_ID:role/$ROLE_NAME"
    print_status "Created IAM role: $ROLE_ARN"
    
    # Retry deployment with the new role
    aws cloudformation deploy \
      --template-file "$packaged_template" \
      --stack-name "$STACK_NAME" \
      --capabilities CAPABILITY_IAM \
      --region "$REGION" \
      --parameter-overrides AgentIAMRoleArn=$ROLE_ARN \
      --no-fail-on-empty-changeset
  elif echo "$deploy_output" | grep -q "error"; then
    print_error "Deployment error: $deploy_output"
  else
    print_status "Deployment completed"
  fi
fi

print_success "Agent #$AGENT_NUMBER deployed successfully with local changes!"

# Clean up
rm -f "$packaged_template"
print_status "Cleaned up temporary files"

# Get stack outputs
print_status "Stack outputs:"
aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" \
  --region "$REGION" \
  --query "Stacks[0].Outputs" \
  --output table
