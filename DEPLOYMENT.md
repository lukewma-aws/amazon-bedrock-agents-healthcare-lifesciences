# Biomarker Application Infrastructure Deployment Guide

This guide provides comprehensive instructions for deploying the healthcare biomarker discovery application infrastructure on AWS.

## Overview

Based on the analysis of your existing AWS infrastructure, this deployment adds complementary components to your already sophisticated multi-agent biomarker system. Your current setup includes:

- **6 Active Bedrock Agents**: Including biomarker database analyst, clinical evidence researcher, medical imaging expert, and supervisor agent
- **3 Knowledge Bases**: For variant storage, NCBI data, and Step Functions testing
- **80+ Lambda Functions**: For scientific literature search, SQL queries, and imaging analysis
- **30+ S3 Buckets**: For biomarker data, Athena outputs, and knowledge base storage
- **Active Redshift Cluster**: `biomarker-redshift-cluster` with encryption and VPC isolation

## Architecture Components

The deployment creates the following additional infrastructure:

### Core Services
- **S3 Buckets**: Data storage with encryption and lifecycle policies
- **DynamoDB Tables**: Metadata and configuration storage
- **Lambda Functions**: Data processing and API integration
- **Step Functions**: Workflow orchestration
- **API Gateway**: RESTful API endpoints
- **Amplify**: Web application hosting

### Security & Compliance
- **VPC Integration**: Leverages your existing VPC (`vpc-0640bbe32a3af7163`)
- **KMS Encryption**: All data encrypted at rest and in transit
- **IAM Roles**: Least privilege access policies
- **CloudWatch**: Comprehensive logging and monitoring

## Prerequisites

1. **AWS CLI**: Version 2.x or higher
2. **AWS Credentials**: Configured with appropriate permissions
3. **Existing Infrastructure**: Your current biomarker multi-agent system
4. **GitHub Repository**: For Amplify deployment (optional)

### Required AWS Permissions

Your AWS user/role needs the following permissions:
- CloudFormation full access
- IAM role creation and management
- S3, DynamoDB, Lambda, Step Functions, API Gateway, Amplify access
- VPC and EC2 describe permissions
- Bedrock agent access (already configured)

## Quick Start

1. **Clone and Navigate**:
   ```bash
   cd /Users/lukewma/Documents/github/amazon-bedrock-agents-cancer-biomarker-discovery
   ```

2. **Run Deployment**:
   ```bash
   ./deploy-infrastructure.sh
   ```

3. **Monitor Progress**:
   The script will provide real-time status updates and validate prerequisites.

## Deployment Options

### Standard Deployment
```bash
./deploy-infrastructure.sh
```

### Validation Only
```bash
./deploy-infrastructure.sh --validate-only
```

### Custom Configuration
```bash
STACK_NAME=my-biomarker-app REGION=us-west-2 ./deploy-infrastructure.sh
```

### Delete Stack
```bash
./deploy-infrastructure.sh --delete-stack
```

## Configuration Parameters

The deployment script accepts these environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `STACK_NAME` | `biomarker-app-infrastructure` | CloudFormation stack name |
| `REGION` | `us-east-1` | AWS deployment region |
| `ENVIRONMENT` | `prod` | Environment tag (dev/staging/prod) |
| `PROJECT_NAME` | `biomarker-app` | Project identifier |

## Integration with Existing Infrastructure

### Bedrock Agents Integration
The new infrastructure integrates with your existing agents:

- **Biomarker Database Analyst** (`UR5AFSSQXN`): Connects to new DynamoDB tables
- **Clinical Evidence Researcher** (`Q3Y7J9OP5Q`): Uses new S3 buckets for document storage
- **Medical Imaging Expert** (`IXQHQHQHQH`): Processes images through new Lambda functions
- **Supervisor Agent** (`SUPERVISOR123`): Orchestrates workflows via Step Functions

### Data Flow Architecture
```
User Request → API Gateway → Lambda → Bedrock Agents → Knowledge Bases → S3/DynamoDB
                ↓
Step Functions → Processing → Results → Amplify Frontend
```

## Post-Deployment Configuration

### 1. Amplify Application Setup
```bash
# Get Amplify app details
aws cloudformation describe-stacks \
  --stack-name biomarker-app-infrastructure \
  --query 'Stacks[0].Outputs[?OutputKey==`AmplifyAppId`].OutputValue' \
  --output text
```

### 2. Cognito User Pool Configuration
```bash
# Create test user
aws cognito-idp admin-create-user \
  --user-pool-id <USER_POOL_ID> \
  --username testuser \
  --user-attributes Name=email,Value=test@example.com \
  --temporary-password TempPass123!
```

### 3. S3 Data Upload
```bash
# Upload sample biomarker data
aws s3 cp sample-data/ s3://<BUCKET_NAME>/biomarker-data/ --recursive
```

### 4. Test API Endpoints
```bash
# Test health check
curl -X GET https://<API_GATEWAY_URL>/health

# Test biomarker analysis
curl -X POST https://<API_GATEWAY_URL>/analyze \
  -H "Content-Type: application/json" \
  -d '{"biomarker": "BRCA1", "analysis_type": "variant"}'
```

## Security Considerations

### HIPAA Compliance
- All data encrypted with KMS
- VPC isolation for sensitive workloads
- Audit logging enabled
- Access controls implemented

### Best Practices Implemented
- Least privilege IAM policies
- Resource-based policies
- Network segmentation
- Encryption in transit and at rest

## Monitoring and Troubleshooting

### CloudWatch Dashboards
The deployment creates dashboards for:
- Lambda function performance
- API Gateway metrics
- Step Functions execution status
- Bedrock agent invocations

### Common Issues

1. **VPC Connectivity**: Ensure your existing VPC has proper routing
2. **IAM Permissions**: Verify Bedrock agent roles have necessary permissions
3. **Resource Limits**: Check AWS service quotas in your region

### Debugging Commands
```bash
# Check stack status
aws cloudformation describe-stacks --stack-name biomarker-app-infrastructure

# View stack events
aws cloudformation describe-stack-events --stack-name biomarker-app-infrastructure

# Check Lambda logs
aws logs describe-log-groups --log-group-name-prefix /aws/lambda/biomarker

# Test Bedrock agent connectivity
aws bedrock-agent get-agent --agent-id UR5AFSSQXN
```

## Cost Optimization

### Resource Sizing
- Lambda functions: Optimized memory allocation
- DynamoDB: On-demand billing for variable workloads
- S3: Intelligent tiering enabled
- Step Functions: Express workflows for high-frequency operations

### Estimated Monthly Costs
- Development: $50-100
- Production: $200-500
- Enterprise: $500-1000+

*Costs vary based on usage patterns and data volume*

## Cleanup

To remove all deployed resources:
```bash
./deploy-infrastructure.sh --delete-stack
```

**Warning**: This will delete all data in the created resources. Ensure you have backups if needed.

## Support and Troubleshooting

### Log Locations
- CloudFormation: AWS Console → CloudFormation → Events
- Lambda: CloudWatch → Log Groups → `/aws/lambda/`
- API Gateway: CloudWatch → Log Groups → `API-Gateway-Execution-Logs`

### Getting Help
1. Check CloudFormation stack events for deployment issues
2. Review CloudWatch logs for runtime errors
3. Validate IAM permissions for access issues
4. Ensure VPC configuration allows required connectivity

## Next Steps

After successful deployment:

1. **Configure Monitoring**: Set up CloudWatch alarms and notifications
2. **Load Test**: Validate performance with expected workloads
3. **Security Review**: Conduct security assessment
4. **Documentation**: Update team documentation with new endpoints
5. **Training**: Train users on new application features

## Integration Examples

### Python SDK Usage
```python
import boto3

# Initialize clients
bedrock = boto3.client('bedrock-agent-runtime')
s3 = boto3.client('s3')

# Invoke biomarker analysis agent
response = bedrock.invoke_agent(
    agentId='UR5AFSSQXN',
    agentAliasId='TSTALIASID',
    sessionId='session-123',
    inputText='Analyze BRCA1 variants for patient cohort'
)
```

### API Integration
```javascript
// Frontend integration example
const analyzeData = async (biomarkerData) => {
  const response = await fetch('/api/analyze', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'Authorization': `Bearer ${authToken}`
    },
    body: JSON.stringify(biomarkerData)
  });
  return response.json();
};
```

This deployment enhances your existing sophisticated biomarker discovery platform with additional automation, user interfaces, and workflow capabilities while maintaining the security and compliance standards already established in your infrastructure.
