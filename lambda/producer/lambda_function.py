"""
Lambda Function: Producer (request-ride)
Receives ride requests and sends them to RabbitMQ or SQS based on query parameter.
"""

import json
import boto3
import os
import uuid
from datetime import datetime
import pika

# Environment variables
SQS_QUEUE_URL = os.environ.get('SQS_QUEUE_URL')
RABBITMQ_HOST = os.environ.get('RABBITMQ_HOST')
RABBITMQ_PORT = int(os.environ.get('RABBITMQ_PORT', 5672))
RABBITMQ_USER = os.environ.get('RABBITMQ_USER', 'guest')
RABBITMQ_PASSWORD = os.environ.get('RABBITMQ_PASSWORD', 'guest')
RABBITMQ_QUEUE = os.environ.get('RABBITMQ_QUEUE', 'ride-requests')

sqs_client = boto3.client('sqs')


def send_to_sqs(message_body):
    """Send message to SQS queue"""
    try:
        response = sqs_client.send_message(
            QueueUrl=SQS_QUEUE_URL,
            MessageBody=json.dumps(message_body)
        )
        return {
            'success': True,
            'message_id': response['MessageId'],
            'queue_type': 'sqs'
        }
    except Exception as e:
        print(f"Error sending to SQS: {str(e)}")
        return {
            'success': False,
            'error': str(e)
        }


def send_to_rabbitmq(message_body):
    """Send message to RabbitMQ queue"""
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
        
        # Publish message
        channel.basic_publish(
            exchange='',
            routing_key=RABBITMQ_QUEUE,
            body=json.dumps(message_body),
            properties=pika.BasicProperties(
                delivery_mode=2,  # Make message persistent
                content_type='application/json'
            )
        )
        
        connection.close()
        
        return {
            'success': True,
            'message_id': message_body['message_id'],
            'queue_type': 'rabbitmq'
        }
    except Exception as e:
        print(f"Error sending to RabbitMQ: {str(e)}")
        return {
            'success': False,
            'error': str(e)
        }


def validate_request_body(body):
    """Validate required fields in request body"""
    required_fields = ['passenger_name', 'current_address', 'destination']
    
    if not body:
        return False, "Request body is empty"
    
    for field in required_fields:
        if field not in body or not body[field]:
            return False, f"Missing required field: {field}"
    
    return True, None


def lambda_handler(event, context):
    """
    Main Lambda handler for ride request producer
    
    Expected event structure:
    {
        "queryStringParameters": {"queue": "sqs" or "rabbitmq"},
        "body": "{...passenger info...}"
    }
    """
    
    print(f"Received event: {json.dumps(event)}")
    
    try:
        # Extract queue type from query parameters
        queue_params = event.get('queryStringParameters', {})
        queue_type = queue_params.get('queue', 'sqs').lower() if queue_params else 'sqs'
        
        if queue_type not in ['sqs', 'rabbitmq']:
            return {
                'statusCode': 400,
                'headers': {
                    'Content-Type': 'application/json',
                    'Access-Control-Allow-Origin': '*'
                },
                'body': json.dumps({
                    'error': 'Invalid queue parameter. Use "sqs" or "rabbitmq"'
                })
            }
        
        # Parse request body
        body = json.loads(event.get('body', '{}'))
        
        # Validate request body
        is_valid, error_message = validate_request_body(body)
        if not is_valid:
            return {
                'statusCode': 400,
                'headers': {
                    'Content-Type': 'application/json',
                    'Access-Control-Allow-Origin': '*'
                },
                'body': json.dumps({'error': error_message})
            }
        
        # Create message with metadata
        message_id = str(uuid.uuid4())
        timestamp = datetime.utcnow().isoformat() + 'Z'
        
        message = {
            'message_id': message_id,
            'timestamp_sent': timestamp,
            'queue_type': queue_type,
            'passenger_name': body['passenger_name'],
            'current_address': body['current_address'],
            'destination': body['destination'],
            'phone': body.get('phone', 'N/A')
        }
        
        # Send to appropriate queue
        if queue_type == 'sqs':
            result = send_to_sqs(message)
        else:
            result = send_to_rabbitmq(message)
        
        if not result['success']:
            return {
                'statusCode': 500,
                'headers': {
                    'Content-Type': 'application/json',
                    'Access-Control-Allow-Origin': '*'
                },
                'body': json.dumps({
                    'error': f"Failed to queue message: {result.get('error', 'Unknown error')}"
                })
            }
        
        # Success response
        return {
            'statusCode': 200,
            'headers': {
                'Content-Type': 'application/json',
                'Access-Control-Allow-Origin': '*'
            },
            'body': json.dumps({
                'message_id': message_id,
                'timestamp': timestamp,
                'queue_type': queue_type,
                'status': 'queued',
                'passenger_name': body['passenger_name']
            })
        }
        
    except json.JSONDecodeError:
        return {
            'statusCode': 400,
            'headers': {
                'Content-Type': 'application/json',
                'Access-Control-Allow-Origin': '*'
            },
            'body': json.dumps({'error': 'Invalid JSON in request body'})
        }
    except Exception as e:
        print(f"Unexpected error: {str(e)}")
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
