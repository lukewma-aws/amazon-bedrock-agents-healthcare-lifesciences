import json
import boto3
import os
from datetime import datetime
import uuid

def lambda_handler(event, context):
    """
    HealthOmics integration function for genomic variant analysis
    """
    try:
        # Initialize AWS clients
        omics = boto3.client('omics')
        dynamodb = boto3.resource('dynamodb')
        s3 = boto3.client('s3')
        
        # Get environment variables
        metadata_table = dynamodb.Table(os.environ['METADATA_TABLE'])
        results_table = dynamodb.Table(os.environ['RESULTS_TABLE'])
        
        # Parse input
        operation = event.get('operation', 'query_variants')
        biomarker = event.get('biomarker', '')
        variant_store_id = event.get('variant_store_id', os.environ['VARIANT_STORE_4_ID'])  # Use largest store by default
        
        if operation == 'query_variants':
            result = query_variants(omics, biomarker, variant_store_id)
        elif operation == 'get_annotations':
            result = get_annotations(omics, biomarker)
        elif operation == 'start_workflow':
            result = start_workflow(omics, event)
        elif operation == 'list_stores':
            result = list_stores(omics)
        else:
            result = {'error': f'Unknown operation: {operation}'}
        
        # Store results in DynamoDB
        analysis_id = str(uuid.uuid4())
        timestamp = datetime.utcnow().isoformat()
        
        # Store metadata
        metadata_table.put_item(
            Item={
                'biomarker_id': biomarker or 'healthomics_query',
                'analysis_type': f'healthomics_{operation}',
                'analysis_id': analysis_id,
                'timestamp': timestamp,
                'variant_store_id': variant_store_id,
                'status': 'completed'
            }
        )
        
        # Store results
        results_table.put_item(
            Item={
                'analysis_id': analysis_id,
                'timestamp': timestamp,
                'results': result,
                'operation': operation,
                'ttl': int((datetime.utcnow().timestamp() + 86400 * 30))  # 30 days TTL
            }
        )
        
        return {
            'statusCode': 200,
            'body': json.dumps({
                'analysis_id': analysis_id,
                'operation': operation,
                'results': result
            })
        }
        
    except Exception as e:
        print(f"Error: {str(e)}")
        return {
            'statusCode': 500,
            'body': json.dumps({'error': str(e)})
        }

def query_variants(omics, biomarker, variant_store_id):
    """Query variants from HealthOmics variant store"""
    try:
        # Get variant store details
        store_response = omics.get_variant_store(name=variant_store_id)
        
        # For demonstration - in practice you'd use list_variant_import_jobs
        # and get_variant_import_job to access actual variant data
        import_jobs = omics.list_variant_import_jobs(
            ids=[variant_store_id],
            maxResults=10
        )
        
        return {
            'variant_store_id': variant_store_id,
            'store_details': {
                'name': store_response.get('name', ''),
                'status': store_response.get('status', ''),
                'size_bytes': store_response.get('storeSizeBytes', 0)
            },
            'import_jobs': import_jobs.get('variantImportJobs', []),
            'biomarker_query': biomarker,
            'message': 'Variant store queried successfully'
        }
        
    except Exception as e:
        return {'error': f'Error querying variants: {str(e)}'}

def get_annotations(omics, biomarker):
    """Get annotations from HealthOmics annotation store"""
    try:
        annotation_store_id = os.environ['ANNOTATION_STORE_ID']
        
        # Get annotation store details
        store_response = omics.get_annotation_store(name=annotation_store_id)
        
        # List annotation import jobs
        import_jobs = omics.list_annotation_import_jobs(
            ids=[annotation_store_id],
            maxResults=10
        )
        
        return {
            'annotation_store_id': annotation_store_id,
            'store_details': {
                'name': store_response.get('name', ''),
                'status': store_response.get('status', ''),
                'format': store_response.get('storeFormat', ''),
                'size_bytes': store_response.get('storeSizeBytes', 0)
            },
            'import_jobs': import_jobs.get('annotationImportJobs', []),
            'biomarker_query': biomarker,
            'message': 'Annotation store queried successfully'
        }
        
    except Exception as e:
        return {'error': f'Error getting annotations: {str(e)}'}

def start_workflow(omics, event):
    """Start a HealthOmics workflow"""
    try:
        workflow_id = event.get('workflow_id', os.environ['GATK_WORKFLOW_ID'])
        workflow_name = event.get('workflow_name', f'biomarker-analysis-{datetime.utcnow().strftime("%Y%m%d-%H%M%S")}')
        
        # Get workflow details first
        workflow_details = omics.get_workflow(id=workflow_id)
        
        # Note: Starting a workflow requires proper parameters and input files
        # This is a placeholder - actual implementation would need specific parameters
        return {
            'workflow_id': workflow_id,
            'workflow_details': {
                'name': workflow_details.get('name', ''),
                'status': workflow_details.get('status', ''),
                'type': workflow_details.get('type', '')
            },
            'message': 'Workflow details retrieved (start requires specific parameters)',
            'note': 'To start workflow, provide proper input parameters and S3 paths'
        }
        
    except Exception as e:
        return {'error': f'Error with workflow: {str(e)}'}

def list_stores(omics):
    """List all HealthOmics stores"""
    try:
        # List all stores
        variant_stores = omics.list_variant_stores()
        annotation_stores = omics.list_annotation_stores()
        reference_stores = omics.list_reference_stores()
        workflows = omics.list_workflows()
        
        return {
            'variant_stores': variant_stores.get('variantStores', []),
            'annotation_stores': annotation_stores.get('annotationStores', []),
            'reference_stores': reference_stores.get('referenceStores', []),
            'workflows': workflows.get('items', []),
            'message': 'All HealthOmics resources listed successfully'
        }
        
    except Exception as e:
        return {'error': f'Error listing stores: {str(e)}'}
