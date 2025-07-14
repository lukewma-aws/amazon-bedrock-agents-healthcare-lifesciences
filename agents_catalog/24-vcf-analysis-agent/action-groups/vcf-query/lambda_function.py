import json
import boto3
import os
import time
import logging
from typing import Dict, List, Any, Optional

# Configure logging
logger = logging.getLogger()
logger.setLevel(logging.INFO)

# Initialize AWS clients
athena_client = boto3.client('athena')
bedrock_runtime = boto3.client('bedrock-runtime')

# Environment variables
ATHENA_DATABASE = os.environ.get('ATHENA_DATABASE', 'vcf_database')
ATHENA_TABLE = os.environ.get('ATHENA_TABLE', 'vcf_variants')
ATHENA_OUTPUT_BUCKET = os.environ.get('ATHENA_OUTPUT_BUCKET', '')
BEDROCK_MODEL_ID = 'anthropic.claude-3-haiku-20240307-v1:0'

def lambda_handler(event, context):
    """
    Lambda function for VCF Analysis Agent.
    This function processes natural language queries about VCF data and converts them to SQL queries.
    
    Parameters:
    - event: The event dict containing the request
    - context: The context object provided by AWS Lambda
    
    Returns:
    - API Gateway compatible response
    """
    logger.info(f"Received event: {json.dumps(event)}")
    
    try:
        # Extract the query from the request
        if 'parameters' in event:
            # Bedrock Agent format
            parameters = event.get('parameters', [])
            param_dict = {param['name']: param['value'] for param in parameters}
            query = param_dict.get('query', '')
            
            # Process the query
            result = process_vcf_query(query)
            
            # Return in Bedrock Agent format
            return {
                'response': {
                    'actionGroupInvocationOutput': {
                        'text': json.dumps(result, indent=2, default=str)
                    }
                }
            }
        else:
            # API Gateway format
            request_body = event.get('requestBody', {})
            api_path = event.get('apiPath', '')
            
            if api_path == '/query-vcf':
                query = request_body.get('query', '')
                
                if not query:
                    return {
                        'statusCode': 400,
                        'body': json.dumps({'error': 'Missing query parameter'})
                    }
                
                # Process the query
                result = process_vcf_query(query)
                
                return {
                    'statusCode': 200,
                    'body': json.dumps(result, default=str)
                }
            else:
                return {
                    'statusCode': 404,
                    'body': json.dumps({'error': f'Unknown API path: {api_path}'})
                }
            
    except Exception as e:
        logger.error(f"Error processing request: {str(e)}")
        return {
            'statusCode': 500,
            'body': json.dumps({'error': f'Internal server error: {str(e)}'})
        }

def process_vcf_query(query: str) -> Dict[str, Any]:
    """
    Process a natural language query about VCF data
    
    Parameters:
    - query: Natural language query about VCF data
    
    Returns:
    - Dictionary with query results
    """
    try:
        # Step 1: Convert natural language to SQL using Bedrock
        sql_query = nl_to_sql(query)
        
        # Step 2: Execute the SQL query using Athena
        query_results = execute_athena_query(sql_query)
        
        # Step 3: Return the results
        return {
            'query': query,
            'sql': sql_query,
            'results': query_results
        }
    except Exception as e:
        logger.error(f"Error processing VCF query: {str(e)}")
        return {
            'query': query,
            'error': str(e)
        }

def nl_to_sql(query: str) -> str:
    """
    Convert natural language query to SQL using Amazon Bedrock
    
    Parameters:
    - query: Natural language query
    
    Returns:
    - SQL query string
    """
    try:
        # Create a prompt for Bedrock
        prompt = f"""
        You are an expert in genomics and SQL. Convert the following natural language query about VCF (Variant Call Format) data into a SQL query.

        The database schema is:
        - Table name: {ATHENA_TABLE}
        - Columns:
          - chrom: string (chromosome, e.g., '1', '2', 'X')
          - pos: bigint (position on chromosome)
          - id: string (variant identifier, e.g., 'rs123')
          - ref: string (reference allele)
          - alt: string (alternate allele)
          - qual: double (quality score)
          - filter: string (filter status)
          - info: string (additional information)
          - format: string (format of sample data)
          - sample_data: string (sample-specific data)

        Natural language query: {query}

        Return ONLY the SQL query without any explanation or additional text. The query should be valid for Amazon Athena (which uses Presto SQL).
        """

        # Call Bedrock to generate SQL
        response = bedrock_runtime.invoke_model(
            modelId=BEDROCK_MODEL_ID,
            contentType='application/json',
            accept='application/json',
            body=json.dumps({
                "anthropic_version": "bedrock-2023-05-31",
                "max_tokens": 1000,
                "temperature": 0,
                "messages": [
                    {
                        "role": "user",
                        "content": prompt
                    }
                ]
            })
        )
        
        # Parse the response
        response_body = json.loads(response['body'].read())
        sql_query = response_body['content'][0]['text'].strip()
        
        # Ensure the query is safe (only SELECT statements)
        if not sql_query.upper().startswith('SELECT'):
            raise ValueError("Generated query is not a SELECT statement")
        
        # Add a LIMIT clause if not present to prevent large result sets
        if 'LIMIT' not in sql_query.upper():
            sql_query += ' LIMIT 100'
            
        return sql_query
        
    except Exception as e:
        logger.error(f"Error converting natural language to SQL: {str(e)}")
        raise ValueError(f"Failed to convert query to SQL: {str(e)}")

def execute_athena_query(sql_query: str) -> List[Dict[str, Any]]:
    """
    Execute SQL query on Athena
    
    Parameters:
    - sql_query: SQL query string
    
    Returns:
    - List of result rows
    """
    try:
        if not ATHENA_OUTPUT_BUCKET:
            raise ValueError("Athena output bucket not configured")
        
        # Start query execution
        response = athena_client.start_query_execution(
            QueryString=sql_query,
            QueryExecutionContext={
                'Database': ATHENA_DATABASE
            },
            ResultConfiguration={
                'OutputLocation': f's3://{ATHENA_OUTPUT_BUCKET}/athena-results/'
            }
        )
        
        query_execution_id = response['QueryExecutionId']
        
        # Wait for query completion
        status = wait_for_query_completion(query_execution_id)
        
        if status != 'SUCCEEDED':
            raise ValueError(f"Query execution failed with status: {status}")
        
        # Get query results
        results = []
        next_token = None
        
        while True:
            if next_token:
                response = athena_client.get_query_results(
                    QueryExecutionId=query_execution_id,
                    NextToken=next_token
                )
            else:
                response = athena_client.get_query_results(
                    QueryExecutionId=query_execution_id
                )
            
            # Process results
            result_set = response['ResultSet']
            
            # Get column names from the first row
            if 'Rows' in result_set and len(result_set['Rows']) > 0:
                column_names = []
                header_row = result_set['Rows'][0]
                for col in header_row['Data']:
                    column_names.append(col.get('VarCharValue', ''))
                
                # Process data rows (skip header)
                for row in result_set['Rows'][1:]:
                    row_data = {}
                    for i, col in enumerate(row['Data']):
                        if i < len(column_names):
                            row_data[column_names[i]] = col.get('VarCharValue', '')
                    results.append(row_data)
            
            # Check if there are more results
            if 'NextToken' in response:
                next_token = response['NextToken']
            else:
                break
        
        return results
        
    except Exception as e:
        logger.error(f"Error executing Athena query: {str(e)}")
        raise ValueError(f"Failed to execute query: {str(e)}")

def wait_for_query_completion(query_execution_id: str, max_attempts: int = 30) -> str:
    """
    Wait for Athena query completion
    
    Parameters:
    - query_execution_id: Athena query execution ID
    - max_attempts: Maximum number of attempts to check status
    
    Returns:
    - Query execution status
    """
    for attempt in range(max_attempts):
        response = athena_client.get_query_execution(
            QueryExecutionId=query_execution_id
        )
        
        state = response['QueryExecution']['Status']['State']
        
        if state in ['SUCCEEDED', 'FAILED', 'CANCELLED']:
            return state
        
        # Wait before checking again
        time.sleep(1)
    
    return 'TIMEOUT'
