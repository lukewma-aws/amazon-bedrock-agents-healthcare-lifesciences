# Clinical Evidence Researcher Agent - CloudFormation Deployment

This document provides instructions for deploying the Clinical Evidence Researcher agent using AWS CloudFormation.

## Overview

The CloudFormation template (`clinical-evidence-researcher-cfn.yaml`) creates:
- Amazon Bedrock Agent for clinical evidence research
- AWS Lambda function for PubMed API integration
- IAM roles and permissions
- CloudWatch log groups
- Bedrock Guardrails for content filtering

## Prerequisites

1. AWS CLI configured with appropriate permissions
2. Amazon Bedrock model access enabled for Claude 3.5 Sonnet
3. (Optional) Amazon Bedrock Knowledge Base for internal literature

## Required Permissions

Your AWS user/role needs the following permissions:
- `bedrock:*`
- `lambda:*`
- `iam:CreateRole`, `iam:AttachRolePolicy`, `iam:PassRole`
- `logs:CreateLogGroup`
- `cloudformation:*`

## Deployment Steps

### 1. Deploy the CloudFormation Stack

```bash
aws cloudformation create-stack \
  --stack-name clinical-evidence-researcher-agent \
  --template-body file://clinical-evidence-researcher-cfn.yaml \
  --parameters \
    ParameterKey=BedrockModelId,ParameterValue=us.anthropic.claude-3-5-sonnet-20241022-v2:0 \
    ParameterKey=AgentAliasName,ParameterValue=Latest \
  --capabilities CAPABILITY_IAM \
  --region us-east-1
```

### 2. With Knowledge Base (Optional)

If you have a Bedrock Knowledge Base for internal literature:

```bash
aws cloudformation create-stack \
  --stack-name clinical-evidence-researcher-agent \
  --template-body file://clinical-evidence-researcher-cfn.yaml \
  --parameters \
    ParameterKey=BedrockModelId,ParameterValue=us.anthropic.claude-3-5-sonnet-20241022-v2:0 \
    ParameterKey=AgentAliasName,ParameterValue=Latest \
    ParameterKey=KnowledgeBaseId,ParameterValue=YOUR_KNOWLEDGE_BASE_ID \
  --capabilities CAPABILITY_IAM \
  --region us-east-1
```

### 3. With Custom Agent Role

If you have a pre-existing Bedrock agent role:

```bash
aws cloudformation create-stack \
  --stack-name clinical-evidence-researcher-agent \
  --template-body file://clinical-evidence-researcher-cfn.yaml \
  --parameters \
    ParameterKey=BedrockModelId,ParameterValue=us.anthropic.claude-3-5-sonnet-20241022-v2:0 \
    ParameterKey=AgentAliasName,ParameterValue=Latest \
    ParameterKey=AgentIAMRoleArn,ParameterValue=arn:aws:iam::ACCOUNT:role/YOUR_AGENT_ROLE \
  --capabilities CAPABILITY_IAM \
  --region us-east-1
```

## Parameters

| Parameter | Description | Default | Required |
|-----------|-------------|---------|----------|
| `AgentAliasName` | Name for the agent alias | Latest | No |
| `BedrockModelId` | Foundation model ID | us.anthropic.claude-3-5-sonnet-20241022-v2:0 | No |
| `AgentIAMRoleArn` | Custom agent IAM role ARN | "" | No |
| `KnowledgeBaseId` | Bedrock Knowledge Base ID | "" | No |

## Outputs

The stack provides the following outputs:
- `AgentId`: The Bedrock Agent ID
- `AgentAliasId`: The Agent Alias ID (if created)
- `AgentAliasArn`: The Agent Alias ARN (if created)
- `PubMedLambdaFunctionArn`: The Lambda function ARN

## Testing the Agent

### 1. AWS Console

1. Go to [Amazon Bedrock Console](https://console.aws.amazon.com/bedrock)
2. Navigate to **Agents**
3. Select your **Clinical-Evidence-Researcher-Agent**
4. Use the **Test** window to ask questions

### 2. Sample Questions

Try these example questions:
- "Can you search PubMed for FDA approved biomarkers for non small cell lung cancer?"
- "What are the latest research findings on EGFR mutations in lung cancer?"
- "Find recent studies on immunotherapy biomarkers for melanoma"
- "Search for research on liquid biopsy techniques for early cancer detection"

### 3. AWS CLI Testing

```bash
# Get the agent ID from stack outputs
AGENT_ID=$(aws cloudformation describe-stacks \
  --stack-name clinical-evidence-researcher-agent \
  --query 'Stacks[0].Outputs[?OutputKey==`AgentId`].OutputValue' \
  --output text)

# Test the agent
aws bedrock-agent-runtime invoke-agent \
  --agent-id $AGENT_ID \
  --agent-alias-id TSTALIASID \
  --session-id test-session-1 \
  --input-text "Search PubMed for recent studies on cancer biomarkers" \
  --region us-east-1
```

## Monitoring and Logs

### CloudWatch Logs
- Lambda function logs: `/aws/lambda/STACK_NAME-pubmed-search`
- Monitor for API errors and performance issues

### Metrics to Monitor
- Lambda function duration and errors
- Agent invocation success rates
- PubMed API response times

## Troubleshooting

### Common Issues

1. **Agent Creation Failed**
   - Check if Bedrock model access is enabled
   - Verify IAM permissions
   - Ensure the model ID is correct for your region

2. **Lambda Function Errors**
   - Check CloudWatch logs for detailed error messages
   - Verify internet connectivity for PubMed API calls
   - Check Lambda timeout settings

3. **PubMed API Issues**
   - Verify network connectivity
   - Check for API rate limiting
   - Ensure proper URL encoding of search queries

### Debugging Steps

1. Check CloudFormation stack events for deployment issues
2. Review Lambda function logs in CloudWatch
3. Test Lambda function independently
4. Verify agent configuration in Bedrock console

## Cleanup

To delete the stack and all resources:

```bash
aws cloudformation delete-stack \
  --stack-name clinical-evidence-researcher-agent \
  --region us-east-1
```

## Security Considerations

- The agent uses Bedrock Guardrails to filter harmful content
- Lambda function has minimal IAM permissions
- Only HTTPS connections are used for PubMed API calls
- No sensitive data is stored in Lambda environment variables

## Cost Optimization

- Lambda function uses appropriate memory allocation (512MB)
- CloudWatch logs have 14-day retention
- Consider using Reserved Capacity for high-volume usage
- Monitor Bedrock token usage for cost optimization
