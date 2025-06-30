import json
import logging
import urllib.request
import urllib.parse
import xml.etree.ElementTree as ET
import os
import boto3
from typing import Dict, List, Any

logger = logging.getLogger()
logger.setLevel(logging.INFO)

def lambda_handler(event, context):
    """
    Lambda function to search PubMed for biomedical literature
    """
    try:
        logger.info(f"Received event: {json.dumps(event)}")
        
        # Extract parameters from the event
        parameters = event.get('parameters', [])
        param_dict = {param['name']: param['value'] for param in parameters}
        
        query = param_dict.get('query', '')
        max_results = int(param_dict.get('max_results', 10))
        
        if not query:
            return {
                'response': {
                    'actionGroupInvocationOutput': {
                        'text': 'Error: Query parameter is required'
                    }
                }
            }
        
        # Search PubMed
        results = search_pubmed(query, max_results)
        
        return {
            'response': {
                'actionGroupInvocationOutput': {
                    'text': json.dumps(results, indent=2)
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

def search_pubmed(query: str, max_results: int = 10) -> Dict[str, Any]:
    """
    Search PubMed for articles matching the query
    """
    try:
        # URL encode the query
        encoded_query = urllib.parse.quote(query)
        
        # Search PubMed for article IDs
        search_url = f"https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esearch.fcgi?db=pubmed&term={encoded_query}&retmax={max_results}&retmode=xml"
        
        with urllib.request.urlopen(search_url) as response:
            search_data = response.read()
        
        # Parse XML response
        root = ET.fromstring(search_data)
        id_list = root.find('.//IdList')
        
        if id_list is None or len(id_list) == 0:
            return {
                'query': query,
                'total_results': 0,
                'articles': []
            }
        
        # Get article IDs
        article_ids = [id_elem.text for id_elem in id_list.findall('Id')]
        
        # Fetch article details
        if article_ids:
            ids_str = ','.join(article_ids)
            fetch_url = f"https://eutils.ncbi.nlm.nih.gov/entrez/eutils/efetch.fcgi?db=pubmed&id={ids_str}&retmode=xml"
            
            with urllib.request.urlopen(fetch_url) as response:
                fetch_data = response.read()
            
            articles = parse_pubmed_articles(fetch_data)
        else:
            articles = []
        
        return {
            'query': query,
            'total_results': len(articles),
            'articles': articles
        }
        
    except Exception as e:
        logger.error(f"Error searching PubMed: {str(e)}")
        return {
            'query': query,
            'error': str(e),
            'total_results': 0,
            'articles': []
        }

def parse_pubmed_articles(xml_data: bytes) -> List[Dict[str, Any]]:
    """
    Parse PubMed XML response to extract article information
    """
    articles = []
    
    try:
        root = ET.fromstring(xml_data)
        
        for article in root.findall('.//PubmedArticle'):
            try:
                # Extract PMID
                pmid_elem = article.find('.//PMID')
                pmid = pmid_elem.text if pmid_elem is not None else 'Unknown'
                
                # Extract title
                title_elem = article.find('.//ArticleTitle')
                title = title_elem.text if title_elem is not None else 'No title available'
                
                # Extract abstract
                abstract_elem = article.find('.//Abstract/AbstractText')
                abstract = abstract_elem.text if abstract_elem is not None else 'No abstract available'
                
                # Extract authors
                authors = []
                author_list = article.find('.//AuthorList')
                if author_list is not None:
                    for author in author_list.findall('Author'):
                        last_name = author.find('LastName')
                        first_name = author.find('ForeName')
                        if last_name is not None and first_name is not None:
                            authors.append(f"{first_name.text} {last_name.text}")
                
                # Extract journal
                journal_elem = article.find('.//Journal/Title')
                journal = journal_elem.text if journal_elem is not None else 'Unknown journal'
                
                # Extract publication date
                pub_date = article.find('.//PubDate')
                pub_year = 'Unknown'
                if pub_date is not None:
                    year_elem = pub_date.find('Year')
                    if year_elem is not None:
                        pub_year = year_elem.text
                
                articles.append({
                    'pmid': pmid,
                    'title': title,
                    'abstract': abstract,
                    'authors': authors,
                    'journal': journal,
                    'publication_year': pub_year,
                    'url': f"https://pubmed.ncbi.nlm.nih.gov/{pmid}/"
                })
                
            except Exception as e:
                logger.error(f"Error parsing individual article: {str(e)}")
                continue
        
    except Exception as e:
        logger.error(f"Error parsing XML: {str(e)}")
    
    return articles
