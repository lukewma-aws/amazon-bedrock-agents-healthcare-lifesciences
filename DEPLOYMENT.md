# HCLS Agents Toolkit with Enhanced Biomarker Infrastructure

This deployment guide covers the complete HCLS (Healthcare and Life Sciences) Agents Toolkit with enhanced biomarker application infrastructure, integrated directly into the main `infra_cfn.yaml` template.

## Overview

Based on the analysis of your existing AWS infrastructure, this enhanced deployment includes:

### Core HCLS Agents Toolkit
- **Multi-agent biomarker discovery system** with supervisor agent
- **Clinical trial protocol assistant** with research capabilities  
- **Competitive intelligence agents** for market analysis
- **Scientific literature search** and curation agents
- **React web application** for user interaction

### Enhanced Biomarker Infrastructure (New)
- **Additional S3 buckets** for data processing and storage
- **DynamoDB tables** for metadata and results tracking
- **Lambda functions** for scientific literature search and data processing
- **Step Functions workflows** for automated analysis pipelines
- **API Gateway** for programmatic access
- **KMS encryption** for all data at rest and in transit
- **HealthOmics integration** for genomic variant analysis

### Existing HealthOmics Resources (Integrated)
- **Reference Store**: `2289344333` (Reference store)
- **Variant Stores**: 3 active stores with genomic variant data
  - `my_variant_store_2` (2980d1e0d667) - 1MB data
  - `my_variant_store_3` (8cd35661f78f) - 67MB data  
  - `my_variant_store_4` (368016e44044) - 67MB data
- **Annotation Store**: `my_annotation_store` (1aead2db2d7f) - 59MB VCF format
- **Workflows**: GATK Variant Discovery and Sample workflows

## Architecture Integration

The enhanced infrastructure integrates seamlessly with your existing components:

```
Existing Agents → Enhanced Lambda Functions → New DynamoDB Tables
      ↓                    ↓                        ↓
Step Functions Workflows → API Gateway → React Application
      ↓                    ↓                        ↓
S3 Data Processing → Knowledge Bases → Redshift Analytics
      ↓                    ↓                        ↓
HealthOmics Variant Stores → Genomic Analysis → Clinical Insights
```

## Prerequisites

### 1. AWS Account Setup
- AWS CLI v2.x installed and configured
- Appropriate IAM permissions for CloudFormation, Bedrock, and other services
- Access to required AWS regions (us-east-1 or us-west-2 recommended)

### 2. Bedrock Model Access
Request access to these foundation models via the [AWS Console](https://docs.aws.amazon.com/bedrock/latest/userguide/model-access.html):
- Amazon Titan Embeddings G1 - Text
- Amazon Nova Pro  
- Anthropic Claude 3.5 Sonnet
- Anthropic Claude 3.5 Sonnet v2
- Anthropic Claude 3 Sonnet

### 3. Service Quotas
[Request an increase](https://docs.aws.amazon.com/servicequotas/latest/userguide/request-quota-increase.html) for:
- Amazon Bedrock "Parameters per function" quota to at least 10
- Lambda concurrent executions (if needed)
- Step Functions state transitions (if needed)

## Deployment Options

### Option 1: One-Click Deployment (Recommended)

Use the CloudFormation launch buttons from the README.md:

| Region | Launch Stack |
|--------|--------------|
| us-east-1 | [![launch-stack](https://s3.amazonaws.com/cloudformation-examples/cloudformation-launch-stack.png)](https://console.aws.amazon.com/cloudformation/home?region=us-east-1#/stacks/new?stackName=hcls-agent-toolkit&templateURL=https://5d1a4b76751b4c8a994ce96bafd91ec9-us-east-1.s3.us-east-1.amazonaws.com/public_assets_support_materials/hcls_agents_toolkit/Infra_cfn.yaml) |
| us-west-2 | [![launch-stack](https://s3.amazonaws.com/cloudformation-examples/cloudformation-launch-stack.png)](https://console.aws.amazon.com/cloudformation/home?region=us-west-2#/stacks/new?stackName=hcls-agent-toolkit&templateURL=https://5d1a4b76751b4c8a994ce96bafd91ec9-us-west-2.s3.us-west-2.amazonaws.com/public_assets_support_materials/hcls_agents_toolkit/Infra_cfn.yaml) |

**Important Parameters:**
- **ReactAppAllowedCidr**: Your IP address with /32 suffix (e.g., `192.168.1.100/32`)
- **RedshiftPassword**: Secure password (8+ chars, mixed case, numbers)
- **EnableBiomarkerAppInfrastructure**: Set to `true` (default)
- **TavilyApiKey**: Optional, for web search capabilities
- **USPTOApiKey**: Optional, for patent search capabilities

### Option 2: Enhanced Deployment Script

Use the provided deployment script for guided setup:

```bash
cd /Users/lukewma/Documents/github/amazon-bedrock-agents-cancer-biomarker-discovery
./deploy-infrastructure.sh
```

The script will:
- Validate prerequisites and template
- Prompt for required parameters
- Package and deploy the infrastructure
- Set up post-deployment configurations
- Provide next steps and outputs

### Option 3: AWS CLI Deployment

For advanced users or CI/CD integration:

```bash
# Set environment variables
export BUCKET_NAME="your-packaging-bucket"
export REGION="us-east-1"
export STACK_NAME="hcls-agents-toolkit"
export REDSHIFT_PASSWORD="YourSecurePassword123!"
export REACT_APP_CIDR="192.168.1.0/24"

# Package and deploy
aws cloudformation package \
  --template-file "infra_cfn.yaml" \
  --s3-bucket $BUCKET_NAME \
  --output-template-file "packaged_infra_cfn.yaml" \
  --region $REGION

aws cloudformation deploy \
  --template-file "packaged_infra_cfn.yaml" \
  --capabilities CAPABILITY_NAMED_IAM \
  --stack-name $STACK_NAME \
  --region $REGION \
  --parameter-overrides \
    RedshiftPassword="$REDSHIFT_PASSWORD" \
    ReactAppAllowedCidr="$REACT_APP_CIDR" \
    EnableBiomarkerAppInfrastructure="true" \
    ProjectName="biomarker-app" \
    Environment="prod"
```

## Configuration Parameters

### Required Parameters
| Parameter | Description | Example |
|-----------|-------------|---------|
| `RedshiftPassword` | Redshift master password | `SecurePass123!` |
| `ReactAppAllowedCidr` | CIDR for React app access | `192.168.1.0/24` |

### Optional Parameters  
| Parameter | Default | Description |
|-----------|---------|-------------|
| `EnableBiomarkerAppInfrastructure` | `true` | Deploy enhanced infrastructure |
| `ProjectName` | `biomarker-app` | Project identifier |
| `Environment` | `prod` | Environment tag |
| `TavilyApiKey` | `""` | Web search API key |
| `USPTOApiKey` | `""` | Patent search API key |
| `ExistingVpcId` | `""` | Use existing VPC |
| `ExistingPublicSubnets` | `""` | Use existing public subnets |
| `ExistingPrivateSubnets` | `""` | Use existing private subnets |

## Post-Deployment Setup

### 1. Access the React Application
```bash
# Get the application URL
aws cloudformation describe-stacks \
  --stack-name hcls-agents-toolkit \
  --query 'Stacks[0].Outputs[?OutputKey==`ReactAppExternalURL`].OutputValue' \
  --output text
```

Add `http://` prefix to the URL and access in your browser.

### 2. Test Enhanced Infrastructure
```bash
# Test literature search function
aws lambda invoke \
  --function-name biomarker-app-literature-search-prod \
  --payload '{"query": "BRCA1 biomarker cancer", "max_results": 5}' \
  response.json

# Test HealthOmics integration function
aws lambda invoke \
  --function-name biomarker-app-healthomics-integration-prod \
  --payload '{"operation": "list_stores"}' \
  healthomics-response.json

# Query specific variant store
aws lambda invoke \
  --function-name biomarker-app-healthomics-integration-prod \
  --payload '{"operation": "query_variants", "biomarker": "BRCA1", "variant_store_id": "368016e44044"}' \
  variant-response.json

# Get genomic annotations
aws lambda invoke \
  --function-name biomarker-app-healthomics-integration-prod \
  --payload '{"operation": "get_annotations", "biomarker": "BRCA1"}' \
  annotation-response.json

# Check DynamoDB tables
aws dynamodb scan \
  --table-name biomarker-app-metadata-prod \
  --max-items 5

# Test Step Functions workflow
aws stepfunctions start-execution \
  --state-machine-arn "arn:aws:states:region:account:stateMachine:biomarker-app-analysis-workflow-prod" \
  --input '{"biomarker": "BRCA1", "analysis_type": "genomic_literature_review"}'
```

### 3. Upload Sample Data
```bash
# Get bucket name
BUCKET_NAME=$(aws cloudformation describe-stacks \
  --stack-name hcls-agents-toolkit \
  --query 'Stacks[0].Outputs[?OutputKey==`BiomarkerDataBucketName`].OutputValue' \
  --output text)

# Upload sample data
aws s3 cp sample-data/ s3://$BUCKET_NAME/biomarker-data/ --recursive
```

## Integration with Existing Agents

The enhanced infrastructure automatically integrates with your existing Bedrock agents:

### Biomarker Database Analyst
- **Agent ID**: Available in stack outputs
- **Integration**: Connects to new DynamoDB tables for metadata storage
- **Usage**: Invoke via Lambda functions or Step Functions

### Clinical Evidence Researcher  
- **Agent ID**: Available in stack outputs
- **Integration**: Uses new S3 buckets for document processing
- **Usage**: Automated literature search and analysis

### Medical Imaging Expert
- **Agent ID**: Available in stack outputs  
- **Integration**: Processes images through enhanced Lambda functions
- **Usage**: Integrated into analysis workflows

## Monitoring and Troubleshooting

### CloudWatch Dashboards
The deployment creates monitoring dashboards for:
- Lambda function performance and errors
- Step Functions execution status
- API Gateway request metrics
- DynamoDB table operations
- S3 bucket access patterns

### Common Issues and Solutions

1. **Template Validation Errors**
   ```bash
   aws cloudformation validate-template --template-body file://infra_cfn.yaml
   ```

2. **Bedrock Model Access Issues**
   - Verify model access in Bedrock console
   - Check IAM permissions for Bedrock service

3. **VPC Connectivity Problems**
   - Ensure subnets have proper routing
   - Check security group configurations
   - Verify NAT Gateway for private subnets

4. **Lambda Function Timeouts**
   - Check CloudWatch logs for specific errors
   - Increase memory allocation if needed
   - Verify VPC configuration for external API access

### Debugging Commands
```bash
# Check stack status
aws cloudformation describe-stack-events --stack-name hcls-agents-toolkit

# View Lambda logs
aws logs describe-log-groups --log-group-name-prefix /aws/lambda/biomarker-app

# Test agent connectivity
aws bedrock-agent list-agents --region us-east-1

# Check Step Functions executions
aws stepfunctions list-executions --state-machine-arn <STATE_MACHINE_ARN>
```

## Security and Compliance

### HIPAA Compliance Features
- **Encryption**: All data encrypted with KMS at rest and in transit
- **Access Control**: IAM roles with least privilege principles
- **Audit Logging**: CloudTrail and CloudWatch logging enabled
- **Network Isolation**: VPC deployment with private subnets
- **Data Retention**: Configurable TTL for temporary data

### Security Best Practices
- Regular security assessments
- Monitoring for unusual access patterns
- Automated backup and recovery procedures
- Incident response planning

## Cost Optimization

### Resource Sizing
- **Lambda**: Right-sized memory allocation based on workload
- **DynamoDB**: On-demand billing for variable workloads  
- **S3**: Intelligent tiering and lifecycle policies
- **Step Functions**: Express workflows for high-frequency operations

### Estimated Monthly Costs
- **Development Environment**: $100-200
- **Production Environment**: $300-800
- **Enterprise Scale**: $800-2000+

*Costs vary significantly based on usage patterns, data volume, and agent invocation frequency*

## Cleanup and Maintenance

### Complete Stack Deletion
```bash
./deploy-infrastructure.sh --delete-stack
```

**Warning**: This deletes all resources and data. Ensure backups exist.

### Selective Resource Management
```bash
# Disable enhanced infrastructure only
aws cloudformation update-stack \
  --stack-name hcls-agents-toolkit \
  --use-previous-template \
  --parameters ParameterKey=EnableBiomarkerAppInfrastructure,ParameterValue=false
```

## Support and Next Steps

### Getting Help
1. **AWS Documentation**: [Bedrock Agents User Guide](https://docs.aws.amazon.com/bedrock/latest/userguide/agents.html)
2. **CloudFormation Events**: Check stack events for deployment issues
3. **CloudWatch Logs**: Review function logs for runtime errors
4. **AWS Support**: Contact AWS Support for infrastructure issues

### Recommended Next Steps
1. **Configure Monitoring**: Set up CloudWatch alarms and SNS notifications
2. **Load Testing**: Validate performance with expected workloads
3. **Security Review**: Conduct thorough security assessment
4. **User Training**: Train team members on new capabilities
5. **Documentation**: Update internal documentation with new endpoints and workflows

### Integration Examples

#### Python SDK Usage
```python
import boto3
import json

# Initialize clients
bedrock_runtime = boto3.client('bedrock-agent-runtime')
lambda_client = boto3.client('lambda')
stepfunctions = boto3.client('stepfunctions')

# Invoke literature search
response = lambda_client.invoke(
    FunctionName='biomarker-app-literature-search-prod',
    Payload=json.dumps({
        'query': 'BRCA1 variants clinical significance',
        'max_results': 10
    })
)

# Start analysis workflow
execution = stepfunctions.start_execution(
    stateMachineArn='arn:aws:states:region:account:stateMachine:biomarker-app-analysis-workflow-prod',
    input=json.dumps({
        'biomarker': 'BRCA1',
        'analysis_type': 'comprehensive'
    })
)
```

#### REST API Usage
```bash
# Get API Gateway URL from stack outputs
API_URL=$(aws cloudformation describe-stacks \
  --stack-name hcls-agents-toolkit \
  --query 'Stacks[0].Outputs[?OutputKey==`BiomarkerAPIId`].OutputValue' \
  --output text)

# Make API calls (when endpoints are configured)
curl -X POST https://$API_URL.execute-api.region.amazonaws.com/prod/analyze \
  -H "Content-Type: application/json" \
  -d '{"biomarker": "BRCA1", "analysis_type": "variant"}'
```

This enhanced deployment provides a comprehensive platform for healthcare and life sciences research, combining the power of multi-agent AI systems with robust data processing and analysis capabilities.
