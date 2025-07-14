import json
import boto3
import time
import re
from datetime import datetime
import os

athena_client = boto3.client('athena')
glue_client = boto3.client('glue')
s3_client = boto3.client('s3')

def lambda_handler(event, context):
    """
    Athena SQL Generator function that creates and executes SQL queries
    """
    try:
        print(f"Received event: {json.dumps(event)}")
        
        # Extract the action and parameters from the request
        request_body = event.get('requestBody', {})
        api_path = event.get('apiPath', '')
        
        if api_path == '/generate':
            return generate_sql(request_body)
        elif api_path == '/execute':
            return execute_sql(request_body)
        elif api_path == '/describe-tables':
            return describe_tables(request_body)
        elif api_path == '/get-schema':
            return get_table_schema(request_body)
        else:
            return {
                'statusCode': 400,
                'body': json.dumps({'error': f'Unknown API path: {api_path}'})
            }
            
    except Exception as e:
        print(f"Error in Athena SQL generator: {str(e)}")
        return {
            'statusCode': 500,
            'body': json.dumps({'error': str(e)})
        }

def generate_sql(event):
    """Generate SQL query based on natural language description"""
    try:
        description = event.get('description', '')
        database = event.get('database', 'default')
        tables = event.get('tables', [])
        
        if not description:
            return {
                'statusCode': 400,
                'body': json.dumps({'error': 'Description parameter is required'})
            }
        
        # Get table schemas if tables are specified
        table_schemas = {}
        if tables:
            for table in tables:
                try:
                    schema = get_table_columns(database, table)
                    table_schemas[table] = schema
                except Exception as e:
                    print(f"Error getting schema for {table}: {str(e)}")
        
        # Generate SQL based on description and schemas
        sql_query = create_sql_from_description(description, database, table_schemas)
        
        return {
            'statusCode': 200,
            'body': json.dumps({
                'description': description,
                'database': database,
                'generated_sql': sql_query,
                'table_schemas': table_schemas,
                'timestamp': datetime.utcnow().isoformat()
            })
        }
        
    except Exception as e:
        print(f"Error generating SQL: {str(e)}")
        return {
            'statusCode': 500,
            'body': json.dumps({'error': str(e)})
        }

def execute_sql(event):
    """Execute SQL query in Athena"""
    try:
        sql_query = event.get('sql_query', '')
        database = event.get('database', 'default')
        
        if not sql_query:
            return {
                'statusCode': 400,
                'body': json.dumps({'error': 'SQL query is required'})
            }
        
        # Validate SQL query
        if not is_safe_query(sql_query):
            return {
                'statusCode': 400,
                'body': json.dumps({'error': 'Query contains potentially unsafe operations'})
            }
        
        # Execute query
        workgroup = os.environ.get('ATHENA_WORKGROUP', 'primary')
        results_bucket = os.environ.get('ATHENA_RESULTS_BUCKET')
        results_prefix = os.environ.get('ATHENA_RESULTS_PREFIX', 'athena-results/')
        
        response = athena_client.start_query_execution(
            QueryString=sql_query,
            QueryExecutionContext={'Database': database},
            ResultConfiguration={
                'OutputLocation': f's3://{results_bucket}/{results_prefix}'
            },
            WorkGroup=workgroup
        )
        
        query_execution_id = response['QueryExecutionId']
        
        # Wait for query completion (with timeout)
        max_wait_time = 60  # seconds
        wait_time = 0
        
        while wait_time < max_wait_time:
            status_response = athena_client.get_query_execution(
                QueryExecutionId=query_execution_id
            )
            
            status = status_response['QueryExecution']['Status']['State']
            
            if status in ['SUCCEEDED', 'FAILED', 'CANCELLED']:
                break
            
            time.sleep(2)
            wait_time += 2
        
        if status == 'SUCCEEDED':
            # Get query results
            results = athena_client.get_query_results(
                QueryExecutionId=query_execution_id,
                MaxResults=100
            )
            
            # Format results
            formatted_results = format_query_results(results)
            
            return {
                'statusCode': 200,
                'body': json.dumps({
                    'query_execution_id': query_execution_id,
                    'status': status,
                    'results': formatted_results,
                    'row_count': len(formatted_results.get('rows', [])),
                    'execution_time_ms': status_response['QueryExecution'].get('Statistics', {}).get('EngineExecutionTimeInMillis', 0)
                })
            }
        else:
            error_reason = status_response['QueryExecution']['Status'].get('StateChangeReason', 'Unknown error')
            return {
                'statusCode': 500,
                'body': json.dumps({
                    'query_execution_id': query_execution_id,
                    'status': status,
                    'error': error_reason
                })
            }
            
    except Exception as e:
        print(f"Error executing SQL: {str(e)}")
        return {
            'statusCode': 500,
            'body': json.dumps({'error': str(e)})
        }

def describe_tables(event):
    """List tables in a database"""
    try:
        database = event.get('database', 'default')
        
        response = glue_client.get_tables(DatabaseName=database)
        
        tables = []
        for table in response.get('TableList', []):
            tables.append({
                'name': table['Name'],
                'location': table.get('StorageDescriptor', {}).get('Location', ''),
                'input_format': table.get('StorageDescriptor', {}).get('InputFormat', ''),
                'output_format': table.get('StorageDescriptor', {}).get('OutputFormat', ''),
                'columns': len(table.get('StorageDescriptor', {}).get('Columns', [])),
                'partitions': len(table.get('PartitionKeys', [])),
                'created': table.get('CreateTime', '').isoformat() if table.get('CreateTime') else ''
            })
        
        return {
            'statusCode': 200,
            'body': json.dumps({
                'database': database,
                'tables': tables,
                'table_count': len(tables)
            })
        }
        
    except Exception as e:
        print(f"Error describing tables: {str(e)}")
        return {
            'statusCode': 500,
            'body': json.dumps({'error': str(e)})
        }

def get_table_schema(event):
    """Get detailed schema for a specific table"""
    try:
        database = event.get('database', 'default')
        table_name = event.get('table_name', '')
        
        if not table_name:
            return {
                'statusCode': 400,
                'body': json.dumps({'error': 'Table name is required'})
            }
        
        schema = get_table_columns(database, table_name)
        
        return {
            'statusCode': 200,
            'body': json.dumps({
                'database': database,
                'table_name': table_name,
                'schema': schema
            })
        }
        
    except Exception as e:
        print(f"Error getting table schema: {str(e)}")
        return {
            'statusCode': 500,
            'body': json.dumps({'error': str(e)})
        }

def get_table_columns(database, table_name):
    """Get column information for a table"""
    try:
        response = glue_client.get_table(
            DatabaseName=database,
            Name=table_name
        )
        
        table = response['Table']
        columns = []
        
        # Regular columns
        for col in table.get('StorageDescriptor', {}).get('Columns', []):
            columns.append({
                'name': col['Name'],
                'type': col['Type'],
                'comment': col.get('Comment', ''),
                'partition': False
            })
        
        # Partition columns
        for col in table.get('PartitionKeys', []):
            columns.append({
                'name': col['Name'],
                'type': col['Type'],
                'comment': col.get('Comment', ''),
                'partition': True
            })
        
        return {
            'columns': columns,
            'location': table.get('StorageDescriptor', {}).get('Location', ''),
            'input_format': table.get('StorageDescriptor', {}).get('InputFormat', ''),
            'serde': table.get('StorageDescriptor', {}).get('SerdeInfo', {}).get('SerializationLibrary', '')
        }
        
    except Exception as e:
        print(f"Error getting table columns: {str(e)}")
        raise e

def create_sql_from_description(description, database, table_schemas):
    """Create SQL query from natural language description"""
    # This is a simplified SQL generation logic
    # In a production system, you might use more sophisticated NLP or ML models
    
    description_lower = description.lower()
    
    # Basic query patterns
    if 'count' in description_lower:
        if table_schemas:
            table_name = list(table_schemas.keys())[0]
            return f"SELECT COUNT(*) as total_count FROM {database}.{table_name};"
        else:
            return f"-- Please specify table name for count query\nSELECT COUNT(*) as total_count FROM {database}.<table_name>;"
    
    elif 'select' in description_lower or 'show' in description_lower:
        if table_schemas:
            table_name = list(table_schemas.keys())[0]
            columns = [col['name'] for col in table_schemas[table_name]['columns'][:5]]  # First 5 columns
            column_list = ', '.join(columns) if columns else '*'
            return f"SELECT {column_list} FROM {database}.{table_name} LIMIT 10;"
        else:
            return f"-- Please specify table name and columns\nSELECT * FROM {database}.<table_name> LIMIT 10;"
    
    elif 'group by' in description_lower or 'aggregate' in description_lower:
        if table_schemas:
            table_name = list(table_schemas.keys())[0]
            # Find a suitable column for grouping (string type preferred)
            group_column = None
            for col in table_schemas[table_name]['columns']:
                if 'string' in col['type'].lower() or 'varchar' in col['type'].lower():
                    group_column = col['name']
                    break
            
            if group_column:
                return f"SELECT {group_column}, COUNT(*) as count FROM {database}.{table_name} GROUP BY {group_column} ORDER BY count DESC LIMIT 10;"
            else:
                return f"-- No suitable grouping column found\nSELECT COUNT(*) FROM {database}.{table_name};"
        else:
            return f"-- Please specify table name for aggregation\nSELECT <column>, COUNT(*) FROM {database}.<table_name> GROUP BY <column>;"
    
    else:
        # Generic select query
        if table_schemas:
            table_name = list(table_schemas.keys())[0]
            return f"SELECT * FROM {database}.{table_name} LIMIT 10;"
        else:
            return f"-- Generated query based on: {description}\nSELECT * FROM {database}.<table_name> LIMIT 10;"

def is_safe_query(sql_query):
    """Basic SQL safety check"""
    sql_lower = sql_query.lower().strip()
    
    # Block potentially dangerous operations
    dangerous_keywords = [
        'drop', 'delete', 'truncate', 'alter', 'create', 'insert', 'update',
        'grant', 'revoke', 'exec', 'execute', 'sp_', 'xp_'
    ]
    
    for keyword in dangerous_keywords:
        if keyword in sql_lower:
            return False
    
    # Only allow SELECT statements
    if not sql_lower.startswith('select'):
        return False
    
    return True

def format_query_results(results):
    """Format Athena query results"""
    try:
        result_set = results.get('ResultSet', {})
        rows = result_set.get('Rows', [])
        
        if not rows:
            return {'columns': [], 'rows': []}
        
        # Extract column names from first row
        columns = []
        if rows:
            for col in rows[0].get('Data', []):
                columns.append(col.get('VarCharValue', ''))
        
        # Extract data rows (skip header row)
        data_rows = []
        for row in rows[1:]:
            row_data = []
            for cell in row.get('Data', []):
                row_data.append(cell.get('VarCharValue', ''))
            data_rows.append(row_data)
        
        return {
            'columns': columns,
            'rows': data_rows
        }
        
    except Exception as e:
        print(f"Error formatting results: {str(e)}")
        return {'columns': [], 'rows': [], 'error': str(e)}
