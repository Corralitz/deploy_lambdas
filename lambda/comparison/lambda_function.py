"""
Lambda Function: Comparison
Retrieves all processing metrics from S3 and returns comparative statistics.
"""

import json
import boto3
import os
from datetime import datetime
from collections import defaultdict

# Environment variables
S3_BUCKET = os.environ.get('S3_BUCKET_NAME')

s3_client = boto3.client('s3')


def get_all_metrics_from_s3():
    """Retrieve all metric files from S3"""
    all_metrics = []
    
    try:
        # List all objects in the bucket
        paginator = s3_client.get_paginator('list_objects_v2')
        
        for page in paginator.paginate(Bucket=S3_BUCKET):
            if 'Contents' not in page:
                continue
            
            for obj in page['Contents']:
                key = obj['Key']
                
                # Skip if not a JSON file
                if not key.endswith('.json'):
                    continue
                
                try:
                    # Download and parse the metric file
                    response = s3_client.get_object(Bucket=S3_BUCKET, Key=key)
                    content = response['Body'].read().decode('utf-8')
                    metric = json.loads(content)
                    all_metrics.append(metric)
                except Exception as e:
                    print(f"Error reading {key}: {str(e)}")
                    continue
        
        return all_metrics
        
    except Exception as e:
        print(f"Error retrieving metrics from S3: {str(e)}")
        return []


def calculate_statistics(metrics):
    """Calculate statistics for each queue type"""
    stats_by_queue = defaultdict(lambda: {
        'count': 0,
        'latencies': [],
        'processing_times': [],
        'successful': 0,
        'failed': 0
    })
    
    # Group metrics by queue type
    for metric in metrics:
        queue_type = metric.get('queue_type', 'unknown')
        stats = stats_by_queue[queue_type]
        
        stats['count'] += 1
        stats['latencies'].append(metric.get('latency_ms', 0))
        stats['processing_times'].append(metric.get('processing_time_ms', 0))
        
        if metric.get('status') == 'successful':
            stats['successful'] += 1
        else:
            stats['failed'] += 1
    
    # Calculate summary statistics
    summary = {}
    
    for queue_type, stats in stats_by_queue.items():
        if stats['count'] == 0:
            continue
        
        latencies = sorted(stats['latencies'])
        processing_times = sorted(stats['processing_times'])
        
        summary[queue_type] = {
            'count': stats['count'],
            'latency': {
                'avg_ms': round(sum(latencies) / len(latencies), 2),
                'min_ms': round(min(latencies), 2),
                'max_ms': round(max(latencies), 2),
                'median_ms': round(latencies[len(latencies) // 2], 2),
                'p95_ms': round(latencies[int(len(latencies) * 0.95)], 2) if len(latencies) > 1 else round(latencies[0], 2),
                'p99_ms': round(latencies[int(len(latencies) * 0.99)], 2) if len(latencies) > 1 else round(latencies[0], 2)
            },
            'processing_time': {
                'avg_ms': round(sum(processing_times) / len(processing_times), 2),
                'min_ms': round(min(processing_times), 2),
                'max_ms': round(max(processing_times), 2)
            },
            'success_rate': round(stats['successful'] / stats['count'], 4),
            'successful_count': stats['successful'],
            'failed_count': stats['failed']
        }
    
    return summary


def lambda_handler(event, context):
    """
    Main Lambda handler for comparison endpoint
    Returns all metrics and comparative statistics
    """
    
    print(f"Received comparison request: {json.dumps(event)}")
    
    try:
        # Retrieve all metrics from S3
        all_metrics = get_all_metrics_from_s3()
        
        if not all_metrics:
            return {
                'statusCode': 200,
                'headers': {
                    'Content-Type': 'application/json',
                    'Access-Control-Allow-Origin': '*'
                },
                'body': json.dumps({
                    'message': 'No metrics found',
                    'total_messages': 0,
                    'statistics': {},
                    'messages': []
                })
            }
        
        # Calculate statistics
        statistics = calculate_statistics(all_metrics)
        
        # Sort messages by timestamp (newest first)
        sorted_metrics = sorted(
            all_metrics,
            key=lambda x: x.get('timestamp_received', ''),
            reverse=True
        )
        
        # Check if user wants detailed messages
        query_params = event.get('queryStringParameters') or {}
        include_details = query_params.get('details', 'false').lower() == 'true'
        limit = int(query_params.get('limit', 100))
        
        # Prepare response
        response_data = {
            'total_messages': len(all_metrics),
            'statistics': statistics,
            'timestamp': datetime.utcnow().isoformat() + 'Z'
        }
        
        # Add detailed messages if requested
        if include_details:
            response_data['messages'] = sorted_metrics[:limit]
        else:
            response_data['message'] = 'Add ?details=true to see individual messages'
        
        return {
            'statusCode': 200,
            'headers': {
                'Content-Type': 'application/json',
                'Access-Control-Allow-Origin': '*'
            },
            'body': json.dumps(response_data, indent=2)
        }
        
    except Exception as e:
        print(f"Error in comparison handler: {str(e)}")
        return {
            'statusCode': 500,
            'headers': {
                'Content-Type': 'application/json',
                'Access-Control-Allow-Origin': '*'
            },
            'body': json.dumps({
                'error': 'Internal server error',
                'details': str(e)
            })
        }
