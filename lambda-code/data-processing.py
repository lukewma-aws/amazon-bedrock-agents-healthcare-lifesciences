import json
import boto3
import os
import pandas as pd
from io import StringIO
import uuid
from datetime import datetime

def lambda_handler(event, context):
    """
    Data processing function for biomarker analysis
    """
    try:
        # Initialize AWS clients
        s3 = boto3.client('s3')
        dynamodb = boto3.resource('dynamodb')
        stepfunctions = boto3.client('stepfunctions')
        
        # Get environment variables
        metadata_table = dynamodb.Table(os.environ['METADATA_TABLE'])
        results_table = dynamodb.Table(os.environ['RESULTS_TABLE'])
        data_bucket = os.environ['DATA_BUCKET']
        processed_bucket = os.environ['PROCESSED_BUCKET']
        
        # Parse input
        if 'Records' in event:
            # S3 trigger
            for record in event['Records']:
                bucket = record['s3']['bucket']['name']
                key = record['s3']['object']['key']
                process_s3_file(s3, bucket, key, processed_bucket, metadata_table, results_table)
        else:
            # Direct invocation
            data = event.get('data', {})
            analysis_type = event.get('analysis_type', 'general')
            result = process_biomarker_data(data, analysis_type)
            
            # Store results
            analysis_id = str(uuid.uuid4())
            timestamp = datetime.utcnow().isoformat()
            
            metadata_table.put_item(
                Item={
                    'biomarker_id': data.get('biomarker_id', 'unknown'),
                    'analysis_type': analysis_type,
                    'analysis_id': analysis_id,
                    'timestamp': timestamp,
                    'status': 'completed'
                }
            )
            
            results_table.put_item(
                Item={
                    'analysis_id': analysis_id,
                    'timestamp': timestamp,
                    'results': result,
                    'ttl': int((datetime.utcnow().timestamp() + 86400 * 30))
                }
            )
            
            return {
                'statusCode': 200,
                'body': json.dumps({
                    'analysis_id': analysis_id,
                    'results': result
                })
            }
        
        return {
            'statusCode': 200,
            'body': json.dumps({'message': 'Processing completed'})
        }
        
    except Exception as e:
        print(f"Error: {str(e)}")
        return {
            'statusCode': 500,
            'body': json.dumps({'error': str(e)})
        }

def process_s3_file(s3, bucket, key, processed_bucket, metadata_table, results_table):
    """Process a file from S3"""
    try:
        # Download file
        response = s3.get_object(Bucket=bucket, Key=key)
        content = response['Body'].read().decode('utf-8')
        
        # Process based on file type
        if key.endswith('.csv'):
            df = pd.read_csv(StringIO(content))
            result = analyze_csv_data(df)
        elif key.endswith('.json'):
            data = json.loads(content)
            result = analyze_json_data(data)
        else:
            result = {'message': 'File type not supported for automated processing'}
        
        # Save processed result
        processed_key = f"processed/{key}.json"
        s3.put_object(
            Bucket=processed_bucket,
            Key=processed_key,
            Body=json.dumps(result),
            ServerSideEncryption='aws:kms',
            SSEKMSKeyId=os.environ['KMS_KEY_ID']
        )
        
        # Store metadata
        analysis_id = str(uuid.uuid4())
        timestamp = datetime.utcnow().isoformat()
        
        metadata_table.put_item(
            Item={
                'biomarker_id': key,
                'analysis_type': 'file_processing',
                'analysis_id': analysis_id,
                'timestamp': timestamp,
                'source_file': f"s3://{bucket}/{key}",
                'processed_file': f"s3://{processed_bucket}/{processed_key}",
                'status': 'completed'
            }
        )
        
    except Exception as e:
        print(f"Error processing file {key}: {str(e)}")

def process_biomarker_data(data, analysis_type):
    """Process biomarker data"""
    # Placeholder for biomarker analysis logic
    return {
        'analysis_type': analysis_type,
        'processed_at': datetime.utcnow().isoformat(),
        'summary': 'Data processed successfully',
        'data_points': len(data) if isinstance(data, list) else 1
    }

def analyze_csv_data(df):
    """Analyze CSV data"""
    return {
        'rows': len(df),
        'columns': len(df.columns),
        'column_names': df.columns.tolist(),
        'summary_stats': df.describe().to_dict() if not df.empty else {}
    }

def analyze_json_data(data):
    """Analyze JSON data"""
    return {
        'data_type': type(data).__name__,
        'keys': list(data.keys()) if isinstance(data, dict) else [],
        'length': len(data) if hasattr(data, '__len__') else 0
    }
