import json
import logging
import boto3
import time
import os
from typing import Dict, List, Any, Optional

logger = logging.getLogger()
logger.setLevel(logging.INFO)

# Initialize AWS clients
redshift_data = boto3.client('redshift-data')

def lambda_handler(event, context):
    """
    Lambda function to execute SQL queries on Redshift database
    """
    try:
        logger.info(f"Received event: {json.dumps(event)}")
        
        # Extract parameters from the event
        parameters = event.get('parameters', [])
        param_dict = {param['name']: param['value'] for param in parameters}
        
        action = param_dict.get('action', '')
        
        if action == 'get_schema':
            result = get_database_schema()
        elif action == 'execute_query':
            query = param_dict.get('query', '')
            result = execute_sql_query(query)
        elif action == 'validate_query':
            query = param_dict.get('query', '')
            result = validate_sql_query(query)
        else:
            result = {'error': f'Unknown action: {action}'}
        
        return {
            'response': {
                'actionGroupInvocationOutput': {
                    'text': json.dumps(result, indent=2, default=str)
                }
            }
        }
        
    except Exception as e:
        logger.error(f"Error in lambda_handler: {str(e)}")
        return {
            'response': {
                'actionGroupInvocationOutput': {
                    'text': f'Error processing request: {str(e)}'
                }
            }
        }

def get_database_schema() -> Dict[str, Any]:
    """
    Get the database schema information
    """
    try:
        cluster_id = os.environ.get('REDSHIFT_CLUSTER_ID')
        database = os.environ.get('REDSHIFT_DATABASE')
        username = os.environ.get('REDSHIFT_USERNAME')
        
        if not all([cluster_id, database, username]):
            return {'error': 'Redshift configuration not complete'}
        
        # Query to get table information
        schema_query = """
        SELECT 
            schemaname,
            tablename,
            column_name,
            data_type,
            is_nullable
        FROM information_schema.columns 
        WHERE schemaname NOT IN ('information_schema', 'pg_catalog')
        ORDER BY schemaname, tablename, ordinal_position;
        """
        
        response = redshift_data.execute_statement(
            ClusterIdentifier=cluster_id,
            Database=database,
            DbUser=username,
            Sql=schema_query
        )
        
        statement_id = response['Id']
        
        # Wait for query completion
        result = wait_for_query_completion(statement_id)
        
        if result.get('error'):
            return result
        
        # Get query results
        result_response = redshift_data.get_statement_result(Id=statement_id)
        
        # Process schema information
        schema_info = {}
        for record in result_response['Records']:
            schema_name = record[0]['stringValue']
            table_name = record[1]['stringValue']
            column_name = record[2]['stringValue']
            data_type = record[3]['stringValue']
            is_nullable = record[4]['stringValue']
            
            if schema_name not in schema_info:
                schema_info[schema_name] = {}
            
            if table_name not in schema_info[schema_name]:
                schema_info[schema_name][table_name] = []
            
            schema_info[schema_name][table_name].append({
                'column_name': column_name,
                'data_type': data_type,
                'is_nullable': is_nullable
            })
        
        return {
            'action': 'get_schema',
            'schema': schema_info,
            'message': 'Database schema retrieved successfully'
        }
        
    except Exception as e:
        logger.error(f"Error getting database schema: {str(e)}")
        return {'error': f'Failed to get database schema: {str(e)}'}

def execute_sql_query(query: str) -> Dict[str, Any]:
    """
    Execute SQL query on Redshift
    """
    try:
        cluster_id = os.environ.get('REDSHIFT_CLUSTER_ID')
        database = os.environ.get('REDSHIFT_DATABASE')
        username = os.environ.get('REDSHIFT_USERNAME')
        
        if not all([cluster_id, database, username]):
            return {'error': 'Redshift configuration not complete'}
        
        if not query.strip():
            return {'error': 'Query cannot be empty'}
        
        # Execute the query
        response = redshift_data.execute_statement(
            ClusterIdentifier=cluster_id,
            Database=database,
            DbUser=username,
            Sql=query
        )
        
        statement_id = response['Id']
        
        # Wait for query completion
        result = wait_for_query_completion(statement_id)
        
        if result.get('error'):
            return result
        
        # Get query results
        result_response = redshift_data.get_statement_result(Id=statement_id)
        
        # Process results
        columns = [col['name'] for col in result_response.get('ColumnMetadata', [])]
        rows = []
        
        for record in result_response.get('Records', []):
            row = []
            for field in record:
                if 'stringValue' in field:
                    row.append(field['stringValue'])
                elif 'longValue' in field:
                    row.append(field['longValue'])
                elif 'doubleValue' in field:
                    row.append(field['doubleValue'])
                elif 'booleanValue' in field:
                    row.append(field['booleanValue'])
                elif 'isNull' in field:
                    row.append(None)
                else:
                    row.append(str(field))
            rows.append(row)
        
        return {
            'action': 'execute_query',
            'query': query,
            'columns': columns,
            'rows': rows,
            'row_count': len(rows),
            'message': 'Query executed successfully'
        }
        
    except Exception as e:
        logger.error(f"Error executing SQL query: {str(e)}")
        return {'error': f'Failed to execute query: {str(e)}'}

def validate_sql_query(query: str) -> Dict[str, Any]:
    """
    Validate SQL query syntax without executing it
    """
    try:
        # Basic SQL validation
        query = query.strip()
        
        if not query:
            return {'valid': False, 'error': 'Query cannot be empty'}
        
        # Check for potentially dangerous operations
        dangerous_keywords = ['DROP', 'DELETE', 'TRUNCATE', 'ALTER', 'CREATE', 'INSERT', 'UPDATE']
        query_upper = query.upper()
        
        for keyword in dangerous_keywords:
            if keyword in query_upper:
                return {
                    'valid': False, 
                    'error': f'Query contains potentially dangerous operation: {keyword}'
                }
        
        # Check if it's a SELECT statement
        if not query_upper.strip().startswith('SELECT'):
            return {
                'valid': False,
                'error': 'Only SELECT queries are allowed'
            }
        
        return {
            'valid': True,
            'message': 'Query validation passed'
        }
        
    except Exception as e:
        logger.error(f"Error validating SQL query: {str(e)}")
        return {'valid': False, 'error': f'Validation error: {str(e)}'}

def wait_for_query_completion(statement_id: str, max_wait_time: int = 60) -> Dict[str, Any]:
    """
    Wait for query completion with timeout
    """
    start_time = time.time()
    
    while time.time() - start_time < max_wait_time:
        try:
            response = redshift_data.describe_statement(Id=statement_id)
            status = response['Status']
            
            if status == 'FINISHED':
                return {'status': 'completed'}
            elif status == 'FAILED':
                error_msg = response.get('Error', 'Unknown error')
                return {'error': f'Query failed: {error_msg}'}
            elif status == 'ABORTED':
                return {'error': 'Query was aborted'}
            
            # Wait before checking again
            time.sleep(2)
            
        except Exception as e:
            logger.error(f"Error checking query status: {str(e)}")
            return {'error': f'Error checking query status: {str(e)}'}
    
    return {'error': 'Query timed out'}
