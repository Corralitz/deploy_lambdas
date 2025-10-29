#!/bin/bash

# Deploy All Lambda Functions Script
# This script packages and deploys all Lambda functions for the ride-request system

set -e  # Exit on any error

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
REGION="us-east-1"
ROLE_NAME="RideRequestLambdaRole"

# Get these from your AWS setup
echo -e "${YELLOW}Please provide the following configuration:${NC}"
read -p "S3 Bucket Name (for metrics): " S3_BUCKET
read -p "SQS Queue URL: " SQS_QUEUE_URL
read -p "RabbitMQ EC2 Host (IP or DNS): " RABBITMQ_HOST
read -p "RabbitMQ Username (default: guest): " RABBITMQ_USER
RABBITMQ_USER=${RABBITMQ_USER:-guest}
read -sp "RabbitMQ Password (default: guest): " RABBITMQ_PASSWORD
echo
RABBITMQ_PASSWORD=${RABBITMQ_PASSWORD:-guest}

# Get IAM Role ARN
echo -e "\n${YELLOW}Getting IAM Role ARN...${NC}"
ROLE_ARN=$(aws iam get-role --role-name $ROLE_NAME --query 'Role.Arn' --output text)
echo -e "${GREEN}Role ARN: $ROLE_ARN${NC}"

# Function to deploy a Lambda
deploy_lambda() {
    local FUNCTION_NAME=$1
    local HANDLER=$2
    local TIMEOUT=$3
    local MEMORY=$4
    local ENV_VARS=$5
    local DIR=$6
    
    echo -e "\n${YELLOW}========================================${NC}"
    echo -e "${YELLOW}Deploying: $FUNCTION_NAME${NC}"
    echo -e "${YELLOW}========================================${NC}"
    
    # Save current directory
    ORIGINAL_DIR=$(pwd)
    
    # Create deployment package
    cd $DIR
    
    # Create a clean deployment directory
    rm -rf package
    mkdir -p package
    
    # Install dependencies if requirements.txt exists
    if [ -f "requirements.txt" ]; then
        echo "Installing dependencies..."
        pip install -r requirements.txt -t package/ --quiet --break-system-packages 2>/dev/null || \
        pip install -r requirements.txt -t package/ --quiet
    fi
    
    # Copy Lambda function
    cp lambda_function.py package/
    
    # Create ZIP file
    cd package
    zip -r ../deployment.zip . > /dev/null
    cd ..
    
    # Check if Lambda function exists
    if aws lambda get-function --function-name $FUNCTION_NAME --region $REGION 2>/dev/null; then
        echo "Updating existing Lambda function..."
        aws lambda update-function-code \
            --function-name $FUNCTION_NAME \
            --zip-file fileb://deployment.zip \
            --region $REGION > /dev/null
        
        aws lambda update-function-configuration \
            --function-name $FUNCTION_NAME \
            --handler $HANDLER \
            --runtime python3.11 \
            --timeout $TIMEOUT \
            --memory-size $MEMORY \
            --environment "Variables={$ENV_VARS}" \
            --region $REGION > /dev/null
    else
        echo "Creating new Lambda function..."
        aws lambda create-function \
            --function-name $FUNCTION_NAME \
            --runtime python3.11 \
            --role $ROLE_ARN \
            --handler $HANDLER \
            --zip-file fileb://deployment.zip \
            --timeout $TIMEOUT \
            --memory-size $MEMORY \
            --environment "Variables={$ENV_VARS}" \
            --region $REGION > /dev/null
    fi
    
    # Cleanup
    rm -rf package deployment.zip
    
    echo -e "${GREEN}✓ $FUNCTION_NAME deployed successfully${NC}"
    
    # Return to original directory
    cd "$ORIGINAL_DIR"
}

# Deploy Producer Lambda
deploy_lambda \
    "ride-request-producer" \
    "lambda_function.lambda_handler" \
    30 \
    512 \
    "SQS_QUEUE_URL=$SQS_QUEUE_URL,RABBITMQ_HOST=$RABBITMQ_HOST,RABBITMQ_PORT=5672,RABBITMQ_USER=$RABBITMQ_USER,RABBITMQ_PASSWORD=$RABBITMQ_PASSWORD,RABBITMQ_QUEUE=ride-requests" \
    "lambda/producer"

# Deploy SQS Consumer Lambda
deploy_lambda \
    "ride-request-consumer-sqs" \
    "lambda_function.lambda_handler" \
    60 \
    512 \
    "S3_BUCKET_NAME=$S3_BUCKET" \
    "lambda/consumer_sqs"

# Deploy RabbitMQ Consumer Lambda
deploy_lambda \
    "ride-request-consumer-rabbitmq" \
    "lambda_function.lambda_handler" \
    60 \
    512 \
    "S3_BUCKET_NAME=$S3_BUCKET,RABBITMQ_HOST=$RABBITMQ_HOST,RABBITMQ_PORT=5672,RABBITMQ_USER=$RABBITMQ_USER,RABBITMQ_PASSWORD=$RABBITMQ_PASSWORD,RABBITMQ_QUEUE=ride-requests" \
    "lambda/consumer_rabbitmq"

# Deploy Comparison Lambda
deploy_lambda \
    "ride-request-comparison" \
    "lambda_function.lambda_handler" \
    30 \
    256 \
    "S3_BUCKET_NAME=$S3_BUCKET" \
    "lambda/comparison"

echo -e "\n${YELLOW}========================================${NC}"
echo -e "${YELLOW}Setting up SQS Trigger...${NC}"
echo -e "${YELLOW}========================================${NC}"

# Get SQS Queue ARN
SQS_QUEUE_ARN=$(aws sqs get-queue-attributes \
    --queue-url $SQS_QUEUE_URL \
    --attribute-names QueueArn \
    --query 'Attributes.QueueArn' \
    --output text \
    --region $REGION)

# Add SQS trigger to consumer Lambda
aws lambda create-event-source-mapping \
    --function-name ride-request-consumer-sqs \
    --event-source-arn $SQS_QUEUE_ARN \
    --batch-size 10 \
    --region $REGION 2>/dev/null || echo "SQS trigger already exists"

echo -e "${GREEN}✓ SQS trigger configured${NC}"

echo -e "\n${YELLOW}========================================${NC}"
echo -e "${YELLOW}Setting up EventBridge for RabbitMQ Consumer...${NC}"
echo -e "${YELLOW}========================================${NC}"

# Create EventBridge rule to trigger RabbitMQ consumer every minute
aws events put-rule \
    --name ride-request-rabbitmq-consumer-trigger \
    --schedule-expression "rate(1 minute)" \
    --region $REGION > /dev/null

# Add Lambda permission for EventBridge
aws lambda add-permission \
    --function-name ride-request-consumer-rabbitmq \
    --statement-id EventBridgeInvoke \
    --action lambda:InvokeFunction \
    --principal events.amazonaws.com \
    --source-arn $(aws events describe-rule --name ride-request-rabbitmq-consumer-trigger --query 'Arn' --output text --region $REGION) \
    --region $REGION 2>/dev/null || echo "Permission already exists"

# Add target to EventBridge rule
aws events put-targets \
    --rule ride-request-rabbitmq-consumer-trigger \
    --targets "Id"="1","Arn"="$(aws lambda get-function --function-name ride-request-consumer-rabbitmq --query 'Configuration.FunctionArn' --output text --region $REGION)" \
    --region $REGION > /dev/null

echo -e "${GREEN}✓ EventBridge trigger configured (1-minute interval)${NC}"

echo -e "\n${GREEN}========================================${NC}"
echo -e "${GREEN}All Lambda functions deployed!${NC}"
echo -e "${GREEN}========================================${NC}"

echo -e "\n${YELLOW}Next steps:${NC}"
echo "1. Configure API Gateway (see scripts/setup_api_gateway.sh)"
echo "2. Test the endpoints"
echo "3. Monitor CloudWatch Logs"

echo -e "\n${YELLOW}Function ARNs:${NC}"
aws lambda get-function --function-name ride-request-producer --query 'Configuration.FunctionArn' --output text --region $REGION
aws lambda get-function --function-name ride-request-consumer-sqs --query 'Configuration.FunctionArn' --output text --region $REGION
aws lambda get-function --function-name ride-request-consumer-rabbitmq --query 'Configuration.FunctionArn' --output text --region $REGION
aws lambda get-function --function-name ride-request-comparison --query 'Configuration.FunctionArn' --output text --region $REGION
