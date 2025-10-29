"""
Lambda Function: RabbitMQ Consumer
Processes messages from RabbitMQ queue, simulates processing, and stores metrics in S3.
Note: This function is invoked periodically via EventBridge (CloudWatch Events) to poll RabbitMQ.
"""

import json
import boto3
import os
import time
from datetime import datetime
import random
import pika

# Environment variables
S3_BUCKET = os.environ.get('S3_BUCKET_NAME')
RABBITMQ_HOST = os.environ.get('RABBITMQ_HOST')
RABBITMQ_PORT = int(os.environ.get('RABBITMQ_PORT', 5672))
RABBITMQ_USER = os.environ.get('RABBITMQ_USER', 'guest')
RABBITMQ_PASSWORD = os.environ.get('RABBITMQ_PASSWORD', 'guest')
RABBITMQ_QUEUE = os.environ.get('RABBITMQ_QUEUE', 'ride-requests')

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
        filename = f"rabbitmq/{timestamp}_{message_id}.json"
        
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


def consume_messages_from_rabbitmq(max_messages=10):
    """Connect to RabbitMQ and consume messages"""
    processed_messages = []
    
    try:
        # Create connection credentials
        credentials = pika.PlainCredentials(RABBITMQ_USER, RABBITMQ_PASSWORD)
        
        # Connection parameters
        parameters = pika.ConnectionParameters(
            host=RABBITMQ_HOST,
            port=RABBITMQ_PORT,
            credentials=credentials,
            connection_attempts=3,
            retry_delay=2,
            socket_timeout=10
        )
        
        # Establish connection
        connection = pika.BlockingConnection(parameters)
        channel = connection.channel()
        
        # Declare queue (idempotent)
        channel.queue_declare(queue=RABBITMQ_QUEUE, durable=True)
        
        # Consume messages
        messages_consumed = 0
        
        for method_frame, properties, body in channel.consume(RABBITMQ_QUEUE, auto_ack=False, inactivity_timeout=5):
            if method_frame is None:
                # No more messages
                break
            
            try:
                # Parse message
                message_body = json.loads(body.decode('utf-8'))
                
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
                    'queue_type': 'rabbitmq',
                    'timestamp_sent': timestamp_sent,
                    'timestamp_received': timestamp_received,
                    'timestamp_processed': datetime.utcnow().isoformat() + 'Z',
                    'latency_ms': round(latency_ms, 2),
                    'processing_time_ms': round(processing_time_ms, 2),
                    'status': 'successful' if success else 'failed',
                    'passenger_name': message_body.get('passenger_name', 'N/A'),
                    'current_address': message_body.get('current_address', 'N/A'),
                    'destination': message_body.get('destination', 'N/A'),
                    'delivery_tag': method_frame.delivery_tag
                }
                
                # Store metrics to S3
                if store_metrics_to_s3(metrics):
                    # Acknowledge message
                    channel.basic_ack(delivery_tag=method_frame.delivery_tag)
                    processed_messages.append(metrics)
                    print(f"✓ Message {message_id} processed successfully")
                else:
                    # Reject message (requeue)
                    channel.basic_nack(delivery_tag=method_frame.delivery_tag, requeue=True)
                    print(f"✗ Failed to store metrics for message {message_id}")
                
                messages_consumed += 1
                
                # Stop if we've reached max messages
                if messages_consumed >= max_messages:
                    break
                    
            except Exception as e:
                print(f"✗ Error processing message: {str(e)}")
                # Reject and requeue the message
                channel.basic_nack(delivery_tag=method_frame.delivery_tag, requeue=True)
        
        # Cancel the consumer and close connection
        channel.cancel()
        connection.close()
        
        return processed_messages
        
    except Exception as e:
        print(f"Error connecting to RabbitMQ: {str(e)}")
        return processed_messages


def lambda_handler(event, context):
    """
    Main Lambda handler for RabbitMQ message consumer
    Triggered periodically by EventBridge to poll RabbitMQ
    """
    
    print(f"Starting RabbitMQ consumer - Event: {json.dumps(event)}")
    
    # Get max messages from event (default 10)
    max_messages = event.get('max_messages', 10)
    
    # Consume messages from RabbitMQ
    processed_messages = consume_messages_from_rabbitmq(max_messages)
    
    # Return summary
    result = {
        'statusCode': 200,
        'processed': len(processed_messages),
        'timestamp': datetime.utcnow().isoformat() + 'Z'
    }
    
    print(f"Consumer execution complete: {json.dumps(result)}")
    return result
