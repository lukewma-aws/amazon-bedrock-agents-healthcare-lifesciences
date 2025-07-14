#!/bin/bash

# Default values
AGENT_NUMBER=""
STACK_NAME=""
REGION="${REGION:-us-east-1}"
S3_BUCKET="${DEPLOYMENT_BUCKET:-genovia-deployment}"
declare -a PARAMETER_OVERRIDES=()

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
      PARAMETER_OVERRIDES+=("$2")
      shift 2
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
done

# Check if agent number is provided
if [ -z "$AGENT_NUMBER" ]; then
  echo "Agent number is required. Use --agent <number>"
  exit 1
fi

# Set default stack name if not provided
if [ -z "$STACK_NAME" ]; then
  STACK_NAME="agent-${AGENT_NUMBER}"
fi

# Find the agent directory to determine template name
agent_dir=$(find agents_catalog -maxdepth 1 -type d -name "${AGENT_NUMBER}-*" | head -1)
if [ -z "$agent_dir" ]; then
  echo "Agent #${AGENT_NUMBER} not found"
  exit 1
fi

# Find the template file in the agent directory
template_file=$(find "$agent_dir" -name "*-cfn.yaml" | head -1)
if [ -z "$template_file" ]; then
  echo "Template file not found in $agent_dir"
  exit 1
fi

template_name=$(basename "$template_file")
packaged_template="packaged_${template_name%.yaml}.yaml"

# Download the packaged template from S3
echo "Downloading packaged template from S3..."
aws s3 cp "s3://${S3_BUCKET}/agents_catalog/${packaged_template}" .

# Deploy the agent
echo "Deploying agent #$AGENT_NUMBER with stack name $STACK_NAME..."

# Check if we have any parameter overrides
if [ ${#PARAMETER_OVERRIDES[@]} -gt 0 ]; then
  PARAMS=""
  for param in "${PARAMETER_OVERRIDES[@]}"; do
    PARAMS="$PARAMS $param"
  done
  
  echo "Deploying with custom parameters: $PARAMS"
  
  aws cloudformation deploy \
    --template-file "$packaged_template" \
    --stack-name "$STACK_NAME" \
    --capabilities CAPABILITY_IAM \
    --region "$REGION" \
    --parameter-overrides $PARAMS \
    --no-fail-on-empty-changeset
else
  aws cloudformation deploy \
    --template-file "$packaged_template" \
    --stack-name "$STACK_NAME" \
    --capabilities CAPABILITY_IAM \
    --region "$REGION" \
    --no-fail-on-empty-changeset
fi

# Clean up
rm -f "$packaged_template"
echo "Cleaned up temporary files"

# Get stack outputs
echo "Stack outputs:"
aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" \
  --region "$REGION" \
  --query "Stacks[0].Outputs" \
  --output table

