"""
Lambda Function: SQS Consumer
Processes messages from SQS queue, simulates processing, and stores metrics in S3.
"""

import json
import boto3
import os
import time
from datetime import datetime
import random

# Environment variables
S3_BUCKET = os.environ.get('S3_BUCKET_NAME')

s3_client = boto3.client('s3')


def calculate_latency(timestamp_sent, timestamp_received):
    """Calculate latency in milliseconds"""
    try:
        sent = datetime.fromisoformat(timestamp_sent.replace('Z', '+00:00'))
        received = datetime.fromisoformat(timestamp_received.replace('Z', '+00:00'))
        latency_ms = (received - sent).total_seconds() * 1000
        return latency_ms
    except Exception as e:
        print(f"Error calculating latency: {str(e)}")
        return 0


def simulate_processing():
    """Simulate ride processing with random delay"""
    # Random processing time between 100-500ms
    processing_time = random.uniform(0.1, 0.5)
    time.sleep(processing_time)
    
    # 98% success rate
    success = random.random() > 0.02
    
    return success, processing_time * 1000  # Convert to ms


def store_metrics_to_s3(metrics):
    """Store processing metrics to S3"""
    try:
        # Create filename with timestamp
        timestamp = datetime.utcnow().strftime('%Y%m%d_%H%M%S')
        message_id = metrics['message_id']
        filename = f"sqs/{timestamp}_{message_id}.json"
        
        # Upload to S3
        s3_client.put_object(
            Bucket=S3_BUCKET,
            Key=filename,
            Body=json.dumps(metrics, indent=2),
            ContentType='application/json'
        )
        
        print(f"Metrics stored to s3://{S3_BUCKET}/{filename}")
        return True
    except Exception as e:
        print(f"Error storing metrics to S3: {str(e)}")
        return False


def lambda_handler(event, context):
    """
    Main Lambda handler for SQS message consumer
    Triggered automatically by SQS
    """
    
    print(f"Received event: {json.dumps(event)}")
    
    processed_count = 0
    failed_count = 0
    
    # Process each record from SQS
    for record in event.get('Records', []):
        try:
            # Parse message body
            message_body = json.loads(record['body'])
            
            # Extract message details
            message_id = message_body.get('message_id', 'unknown')
            timestamp_sent = message_body.get('timestamp_sent')
            timestamp_received = datetime.utcnow().isoformat() + 'Z'
            
            print(f"Processing message {message_id}")
            
            # Calculate latency
            latency_ms = calculate_latency(timestamp_sent, timestamp_received)
            
            # Simulate processing
            success, processing_time_ms = simulate_processing()
            
            # Create metrics object
            metrics = {
                'message_id': message_id,
                'queue_type': 'sqs',
                'timestamp_sent': timestamp_sent,
                'timestamp_received': timestamp_received,
                'timestamp_processed': datetime.utcnow().isoformat() + 'Z',
                'latency_ms': round(latency_ms, 2),
                'processing_time_ms': round(processing_time_ms, 2),
                'status': 'successful' if success else 'failed',
                'passenger_name': message_body.get('passenger_name', 'N/A'),
                'current_address': message_body.get('current_address', 'N/A'),
                'destination': message_body.get('destination', 'N/A'),
                'sqs_message_id': record.get('messageId'),
                'receipt_handle': record.get('receiptHandle')
            }
            
            # Store metrics to S3
            if store_metrics_to_s3(metrics):
                processed_count += 1
                print(f"✓ Message {message_id} processed successfully")
            else:
                failed_count += 1
                print(f"✗ Failed to store metrics for message {message_id}")
            
        except Exception as e:
            failed_count += 1
            print(f"✗ Error processing message: {str(e)}")
    
    # Return summary
    result = {
        'statusCode': 200,
        'processed': processed_count,
        'failed': failed_count,
        'total': len(event.get('Records', []))
    }
    
    print(f"Batch processing complete: {json.dumps(result)}")
    return result
