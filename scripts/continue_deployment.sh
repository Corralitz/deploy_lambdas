#!/bin/bash

# Quick Fix: Continue Lambda Deployment
# Use this if the main deployment script failed mid-way

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

REGION="us-east-1"

echo -e "${YELLOW}=== Continuing Lambda Deployment ===${NC}\n"

# Get configuration from you
read -p "S3 Bucket Name: " S3_BUCKET
read -p "SQS Queue URL: " SQS_QUEUE_URL
read -p "RabbitMQ Host: " RABBITMQ_HOST
read -p "RabbitMQ Username [admin]: " RABBITMQ_USER
RABBITMQ_USER=${RABBITMQ_USER:-admin}
read -sp "RabbitMQ Password: " RABBITMQ_PASSWORD
echo -e "\n"

ROLE_ARN=$(aws iam get-role --role-name RideRequestLambdaRole --query 'Role.Arn' --output text --region $REGION)

echo -e "${YELLOW}Checking existing deployments...${NC}\n"

# Check which functions exist
PRODUCER_EXISTS=$(aws lambda get-function --function-name ride-request-producer --region $REGION 2>/dev/null && echo "yes" || echo "no")
SQS_CONSUMER_EXISTS=$(aws lambda get-function --function-name ride-request-consumer-sqs --region $REGION 2>/dev/null && echo "yes" || echo "no")
RMQ_CONSUMER_EXISTS=$(aws lambda get-function --function-name ride-request-consumer-rabbitmq --region $REGION 2>/dev/null && echo "yes" || echo "no")
COMPARISON_EXISTS=$(aws lambda get-function --function-name ride-request-comparison --region $REGION 2>/dev/null && echo "yes" || echo "no")

echo "Producer Lambda: $PRODUCER_EXISTS"
echo "SQS Consumer Lambda: $SQS_CONSUMER_EXISTS"
echo "RabbitMQ Consumer Lambda: $RMQ_CONSUMER_EXISTS"
echo "Comparison Lambda: $COMPARISON_EXISTS"
echo ""

# Function to deploy if not exists
deploy_if_needed() {
    local FUNC_NAME=$1
    local EXISTS=$2
    local DIR=$3
    local TIMEOUT=$4
    local MEMORY=$5
    local ENV_VARS=$6
    
    if [ "$EXISTS" = "yes" ]; then
        echo -e "${GREEN}✓ $FUNC_NAME already deployed${NC}"
        return
    fi
    
    echo -e "${YELLOW}Deploying $FUNC_NAME...${NC}"
    
    cd "$DIR"
    rm -rf build deployment.zip
    mkdir -p build
    
    cp lambda_function.py build/
    
    if [ -f "requirements.txt" ]; then
        echo "Installing dependencies..."
        pip install -q -r requirements.txt -t build/ --break-system-packages 2>/dev/null || \
        pip install -q -r requirements.txt -t build/
    fi
    
    cd build
    zip -q -r ../deployment.zip .
    cd ..
    
    aws lambda create-function \
        --function-name "$FUNC_NAME" \
        --runtime python3.11 \
        --role "$ROLE_ARN" \
        --handler lambda_function.lambda_handler \
        --timeout $TIMEOUT \
        --memory-size $MEMORY \
        --zip-file fileb://deployment.zip \
        --environment "$ENV_VARS" \
        --region $REGION &>/dev/null
    
    rm -rf build deployment.zip
    cd - > /dev/null
    
    echo -e "${GREEN}✓ $FUNC_NAME deployed${NC}\n"
}

PROJECT_ROOT=$(pwd)

# Deploy missing functions
deploy_if_needed \
    "ride-request-producer" \
    "$PRODUCER_EXISTS" \
    "$PROJECT_ROOT/lambda/producer" \
    30 \
    512 \
    "Variables={SQS_QUEUE_URL=$SQS_QUEUE_URL,RABBITMQ_HOST=$RABBITMQ_HOST,RABBITMQ_PORT=5672,RABBITMQ_USER=$RABBITMQ_USER,RABBITMQ_PASSWORD=$RABBITMQ_PASSWORD,RABBITMQ_QUEUE=ride-requests}"

deploy_if_needed \
    "ride-request-consumer-sqs" \
    "$SQS_CONSUMER_EXISTS" \
    "$PROJECT_ROOT/lambda/consumer_sqs" \
    60 \
    512 \
    "Variables={S3_BUCKET_NAME=$S3_BUCKET}"

deploy_if_needed \
    "ride-request-consumer-rabbitmq" \
    "$RMQ_CONSUMER_EXISTS" \
    "$PROJECT_ROOT/lambda/consumer_rabbitmq" \
    60 \
    512 \
    "Variables={S3_BUCKET_NAME=$S3_BUCKET,RABBITMQ_HOST=$RABBITMQ_HOST,RABBITMQ_PORT=5672,RABBITMQ_USER=$RABBITMQ_USER,RABBITMQ_PASSWORD=$RABBITMQ_PASSWORD,RABBITMQ_QUEUE=ride-requests}"

deploy_if_needed \
    "ride-request-comparison" \
    "$COMPARISON_EXISTS" \
    "$PROJECT_ROOT/lambda/comparison" \
    30 \
    256 \
    "Variables={S3_BUCKET_NAME=$S3_BUCKET}"

# Configure triggers
echo -e "${YELLOW}Configuring triggers...${NC}"

# SQS Trigger
SQS_QUEUE_ARN=$(aws sqs get-queue-attributes \
    --queue-url "$SQS_QUEUE_URL" \
    --attribute-names QueueArn \
    --query 'Attributes.QueueArn' \
    --output text \
    --region $REGION)

EXISTING_MAPPING=$(aws lambda list-event-source-mappings \
    --function-name ride-request-consumer-sqs \
    --event-source-arn "$SQS_QUEUE_ARN" \
    --region $REGION \
    --query 'EventSourceMappings[0].UUID' \
    --output text 2>/dev/null)

if [ "$EXISTING_MAPPING" != "None" ] && [ -n "$EXISTING_MAPPING" ]; then
    echo -e "${GREEN}✓ SQS trigger already configured${NC}"
else
    aws lambda create-event-source-mapping \
        --function-name ride-request-consumer-sqs \
        --event-source-arn "$SQS_QUEUE_ARN" \
        --batch-size 10 \
        --region $REGION &>/dev/null
    echo -e "${GREEN}✓ SQS trigger configured${NC}"
fi

# EventBridge for RabbitMQ
aws events put-rule \
    --name ride-request-rabbitmq-consumer-trigger \
    --schedule-expression "rate(1 minute)" \
    --state ENABLED \
    --region $REGION &>/dev/null

RULE_ARN=$(aws events describe-rule \
    --name ride-request-rabbitmq-consumer-trigger \
    --query 'Arn' \
    --output text \
    --region $REGION 2>/dev/null)

LAMBDA_ARN=$(aws lambda get-function \
    --function-name ride-request-consumer-rabbitmq \
    --query 'Configuration.FunctionArn' \
    --output text \
    --region $REGION 2>/dev/null)

aws lambda add-permission \
    --function-name ride-request-consumer-rabbitmq \
    --statement-id EventBridgeInvoke \
    --action lambda:InvokeFunction \
    --principal events.amazonaws.com \
    --source-arn "$RULE_ARN" \
    --region $REGION &>/dev/null 2>&1 || true

aws events put-targets \
    --rule ride-request-rabbitmq-consumer-trigger \
    --targets "Id=1,Arn=$LAMBDA_ARN" \
    --region $REGION &>/dev/null

echo -e "${GREEN}✓ EventBridge trigger configured${NC}\n"

# Final status
echo -e "${GREEN}=== Deployment Status ===${NC}\n"

aws lambda list-functions \
    --query 'Functions[?starts_with(FunctionName, `ride-request`)].{Name:FunctionName,Status:State}' \
    --output table \
    --region $REGION

echo -e "\n${GREEN}All Lambda functions deployed successfully!${NC}"
echo -e "\n${YELLOW}Next step: Run ./scripts/setup_api_gateway.sh${NC}\n"
