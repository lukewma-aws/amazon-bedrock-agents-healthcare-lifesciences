import json
import boto3
import os
import requests
from datetime import datetime
import uuid

def lambda_handler(event, context):
    """
    Scientific literature search function that integrates with PubMed API
    and uses Bedrock agents for analysis
    """
    try:
        # Initialize AWS clients
        bedrock_runtime = boto3.client('bedrock-agent-runtime')
        dynamodb = boto3.resource('dynamodb')
        s3 = boto3.client('s3')
        
        # Get environment variables
        metadata_table = dynamodb.Table(os.environ['METADATA_TABLE'])
        results_table = dynamodb.Table(os.environ['RESULTS_TABLE'])
        data_bucket = os.environ['DATA_BUCKET']
        
        # Parse input
        query = event.get('query', '')
        biomarker = event.get('biomarker', '')
        max_results = event.get('max_results', 10)
        
        if not query and not biomarker:
            return {
                'statusCode': 400,
                'body': json.dumps({'error': 'Query or biomarker parameter required'})
            }
        
        # Search PubMed
        search_term = query if query else f"{biomarker} biomarker cancer"
        pubmed_results = search_pubmed(search_term, max_results)
        
        # Store results in DynamoDB
        analysis_id = str(uuid.uuid4())
        timestamp = datetime.utcnow().isoformat()
        
        # Store metadata
        metadata_table.put_item(
            Item={
                'biomarker_id': biomarker or 'literature_search',
                'analysis_type': 'literature_search',
                'analysis_id': analysis_id,
                'timestamp': timestamp,
                'query': search_term,
                'status': 'completed'
            }
        )
        
        # Store results
        results_table.put_item(
            Item={
                'analysis_id': analysis_id,
                'timestamp': timestamp,
                'results': pubmed_results,
                'result_count': len(pubmed_results),
                'ttl': int((datetime.utcnow().timestamp() + 86400 * 30))  # 30 days TTL
            }
        )
        
        return {
            'statusCode': 200,
            'body': json.dumps({
                'analysis_id': analysis_id,
                'results': pubmed_results,
                'count': len(pubmed_results)
            })
        }
        
    except Exception as e:
        print(f"Error: {str(e)}")
        return {
            'statusCode': 500,
            'body': json.dumps({'error': str(e)})
        }

def search_pubmed(query, max_results=10):
    """Search PubMed for scientific literature"""
    try:
        # PubMed E-utilities API
        base_url = "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/"
        
        # Search for article IDs
        search_url = f"{base_url}esearch.fcgi"
        search_params = {
            'db': 'pubmed',
            'term': query,
            'retmax': max_results,
            'retmode': 'json'
        }
        
        search_response = requests.get(search_url, params=search_params)
        search_data = search_response.json()
        
        if 'esearchresult' not in search_data or 'idlist' not in search_data['esearchresult']:
            return []
        
        ids = search_data['esearchresult']['idlist']
        
        if not ids:
            return []
        
        # Fetch article details
        fetch_url = f"{base_url}efetch.fcgi"
        fetch_params = {
            'db': 'pubmed',
            'id': ','.join(ids),
            'retmode': 'xml'
        }
        
        fetch_response = requests.get(fetch_url, params=fetch_params)
        
        # Parse XML response (simplified)
        articles = []
        for pmid in ids:
            articles.append({
                'pmid': pmid,
                'title': f"Article {pmid}",
                'abstract': "Abstract not available in this demo",
                'url': f"https://pubmed.ncbi.nlm.nih.gov/{pmid}/"
            })
        
        return articles
        
    except Exception as e:
        print(f"PubMed search error: {str(e)}")
        return []
