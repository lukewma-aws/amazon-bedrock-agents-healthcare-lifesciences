# Deployment Verification Checklist

Use this checklist to manually verify that your deployed CloudFormation template matches your existing environment.

## Pre-Deployment Baseline

### Current Environment Snapshot (From Analysis)
- ✅ **6 Active Bedrock Agents**: Including biomarker database analyst, clinical evidence researcher, medical imaging expert, supervisor agent
- ✅ **3 Knowledge Bases**: For variant storage, NCBI data, Step Functions testing  
- ✅ **80+ Lambda Functions**: For scientific literature search, SQL queries, imaging analysis
- ✅ **30+ S3 Buckets**: For biomarker data, Athena outputs, knowledge base storage
- ✅ **Active Redshift Cluster**: `biomarker-redshift-cluster` with encryption and VPC isolation
- ✅ **VPC**: `vpc-0640bbe32a3af7163` with proper isolation
- ✅ **HealthOmics Resources**: Reference store, 3 variant stores, annotation store, 2 workflows

## Post-Deployment Verification

### 1. CloudFormation Stack Status
```bash
aws cloudformation describe-stacks --stack-name hcls-agents-toolkit --region us-east-1
```
- [ ] Stack Status: `CREATE_COMPLETE` or `UPDATE_COMPLETE`
- [ ] No failed resources in stack events
- [ ] All expected outputs present

### 2. Bedrock Agents Verification
```bash
# Test existing agents (from conversation summary)
aws bedrock-agent get-agent --agent-id UR5AFSSQXN --region us-east-1  # Biomarker Database Analyst
aws bedrock-agent get-agent --agent-id Q3Y7J9OP5Q --region us-east-1  # Clinical Evidence Researcher
aws bedrock-agent get-agent --agent-id IXQHQHQHQH --region us-east-1  # Medical Imaging Expert

# List all agents to verify count
aws bedrock-agent list-agents --region us-east-1
```
- [ ] All existing agents still accessible
- [ ] New agents created by stack are active
- [ ] Agent count matches expected (6+ agents)

### 3. HealthOmics Resources Verification
```bash
# Verify reference store
aws omics get-reference-store --id "2289344333" --region us-east-1

# Verify variant stores
aws omics get-variant-store --name "2980d1e0d667" --region us-east-1  # my_variant_store_2
aws omics get-variant-store --name "8cd35661f78f" --region us-east-1  # my_variant_store_3  
aws omics get-variant-store --name "368016e44044" --region us-east-1  # my_variant_store_4

# Verify annotation store
aws omics get-annotation-store --name "1aead2db2d7f" --region us-east-1

# Verify workflows
aws omics get-workflow --id "2403822" --region us-east-1  # GATKVariantDiscovery
aws omics get-workflow --id "8567133" --region us-east-1  # Sample
```
- [ ] Reference store accessible: `2289344333`
- [ ] All 3 variant stores accessible with expected data sizes
- [ ] Annotation store accessible: `1aead2db2d7f` (59MB VCF)
- [ ] Both workflows accessible and active

### 4. Lambda Functions Verification
```bash
# Count total functions
aws lambda list-functions --region us-east-1 --query 'Functions | length(@)'

# Test new HealthOmics integration function
aws lambda invoke \
  --function-name biomarker-app-healthomics-integration-prod \
  --payload '{"operation": "list_stores"}' \
  test-response.json

# Test literature search function
aws lambda invoke \
  --function-name biomarker-app-literature-search-prod \
  --payload '{"query": "BRCA1", "max_results": 5}' \
  literature-response.json
```
- [ ] Total Lambda functions ≥ 80 (maintaining existing count)
- [ ] New functions created by stack are accessible
- [ ] HealthOmics integration function works
- [ ] Literature search function works

### 5. S3 Buckets Verification
```bash
# Count total buckets
aws s3api list-buckets --query 'Buckets | length(@)'

# Verify new buckets created by stack
aws s3api head-bucket --bucket biomarker-app-data-ACCOUNT-REGION
aws s3api head-bucket --bucket biomarker-app-processed-ACCOUNT-REGION

# Check encryption on new buckets
aws s3api get-bucket-encryption --bucket biomarker-app-data-ACCOUNT-REGION
```
- [ ] Total S3 buckets ≥ 30 (maintaining existing count)
- [ ] New buckets created with proper naming
- [ ] KMS encryption enabled on new buckets
- [ ] Lifecycle policies configured

### 6. DynamoDB Tables Verification
```bash
# Verify new tables
aws dynamodb describe-table --table-name biomarker-app-metadata-prod
aws dynamodb describe-table --table-name biomarker-app-results-prod

# Check encryption
aws dynamodb describe-table --table-name biomarker-app-metadata-prod \
  --query 'Table.SSEDescription.Status'
```
- [ ] Metadata table created and accessible
- [ ] Results table created and accessible  
- [ ] Both tables have encryption enabled
- [ ] On-demand billing configured

### 7. Redshift Cluster Verification
```bash
# Verify existing cluster still accessible
aws redshift describe-clusters --cluster-identifier "biomarker-redshift-cluster" --region us-east-1
```
- [ ] Existing Redshift cluster still accessible
- [ ] Cluster status: `available`
- [ ] Encryption still enabled

### 8. Step Functions Verification
```bash
# Count total state machines
aws stepfunctions list-state-machines --region us-east-1 --query 'stateMachines | length(@)'

# Test new biomarker analysis workflow
aws stepfunctions start-execution \
  --state-machine-arn "arn:aws:states:us-east-1:ACCOUNT:stateMachine:biomarker-app-analysis-workflow-prod" \
  --input '{"biomarker": "BRCA1", "analysis_type": "test"}'
```
- [ ] Total Step Functions ≥ 5 (maintaining existing count)
- [ ] New biomarker analysis workflow created
- [ ] Workflow can be executed successfully

### 9. VPC and Networking Verification
```bash
# Verify existing VPC
aws ec2 describe-vpcs --vpc-ids "vpc-0640bbe32a3af7163" --region us-east-1

# Check if stack used existing VPC or created new one
aws cloudformation describe-stack-resources \
  --stack-name hcls-agents-toolkit \
  --resource-type AWS::EC2::VPC
```
- [ ] Existing VPC still accessible: `vpc-0640bbe32a3af7163`
- [ ] Stack either used existing VPC or created new one properly
- [ ] Security groups configured correctly

### 10. IAM Roles and Permissions Verification
```bash
# Verify new roles created
aws iam get-role --role-name biomarker-app-lambda-role-prod
aws iam get-role --role-name biomarker-app-healthomics-lambda-role-prod

# Check policies attached
aws iam list-attached-role-policies --role-name biomarker-app-lambda-role-prod
```
- [ ] New IAM roles created with proper naming
- [ ] Least privilege policies attached
- [ ] HealthOmics permissions included

### 11. API Gateway Verification
```bash
# List API Gateways
aws apigateway get-rest-apis --region us-east-1

# Get specific API created by stack
aws cloudformation describe-stack-resources \
  --stack-name hcls-agents-toolkit \
  --resource-type AWS::ApiGateway::RestApi
```
- [ ] New API Gateway created
- [ ] Regional endpoint configured
- [ ] Proper naming convention used

### 12. KMS Key Verification
```bash
# Verify KMS key created
aws cloudformation describe-stack-resources \
  --stack-name hcls-agents-toolkit \
  --resource-type AWS::KMS::Key

# Check key alias
aws kms list-aliases --region us-east-1 | grep biomarker-app
```
- [ ] KMS key created for encryption
- [ ] Key alias configured properly
- [ ] Key policy allows required services

## Integration Testing

### 13. End-to-End Workflow Test
```bash
# Test complete workflow
aws stepfunctions start-execution \
  --state-machine-arn "arn:aws:states:us-east-1:ACCOUNT:stateMachine:biomarker-app-analysis-workflow-prod" \
  --input '{
    "biomarker": "BRCA1",
    "analysis_type": "comprehensive",
    "include_genomics": true,
    "include_literature": true
  }'
```
- [ ] Workflow executes successfully
- [ ] Data flows through all components
- [ ] Results stored in DynamoDB
- [ ] HealthOmics integration works

### 14. React Application Verification
```bash
# Get React app URL
aws cloudformation describe-stacks \
  --stack-name hcls-agents-toolkit \
  --query 'Stacks[0].Outputs[?OutputKey==`ReactAppExternalURL`].OutputValue' \
  --output text
```
- [ ] React application accessible via URL
- [ ] All agents visible in UI
- [ ] New HealthOmics features available
- [ ] Authentication working (if configured)

## Performance and Security Verification

### 15. Security Configuration Check
- [ ] All data encrypted at rest (S3, DynamoDB, EBS)
- [ ] All data encrypted in transit (HTTPS, TLS)
- [ ] VPC isolation maintained
- [ ] Security groups properly configured
- [ ] IAM roles follow least privilege

### 16. Monitoring and Logging Check
```bash
# Verify CloudWatch log groups created
aws logs describe-log-groups --log-group-name-prefix "/aws/lambda/biomarker-app"

# Check CloudWatch dashboards
aws cloudwatch list-dashboards
```
- [ ] CloudWatch log groups created for new functions
- [ ] Monitoring dashboards available
- [ ] Alarms configured (if applicable)

## Troubleshooting Common Issues

### If Verification Fails:

1. **Check CloudFormation Events**:
   ```bash
   aws cloudformation describe-stack-events --stack-name hcls-agents-toolkit
   ```

2. **Review Lambda Function Logs**:
   ```bash
   aws logs describe-log-streams --log-group-name "/aws/lambda/FUNCTION_NAME"
   ```

3. **Validate IAM Permissions**:
   ```bash
   aws iam simulate-principal-policy --policy-source-arn ROLE_ARN --action-names ACTION
   ```

4. **Check Resource Dependencies**:
   ```bash
   aws cloudformation describe-stack-resources --stack-name hcls-agents-toolkit
   ```

## Sign-off Checklist

- [ ] All existing resources remain accessible and functional
- [ ] New resources created successfully with proper configuration
- [ ] HealthOmics integration working correctly
- [ ] Security and compliance maintained
- [ ] Performance within expected parameters
- [ ] Monitoring and logging operational

**Verification Completed By**: ________________  
**Date**: ________________  
**Environment**: Production/Staging/Development  
**Notes**: ________________
