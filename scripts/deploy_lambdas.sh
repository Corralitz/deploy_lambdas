#!/bin/bash

# Simple Lambda Deployment Script
# Deploys Lambda functions one at a time with better error handling

set -e  # Exit on error

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Configuration
REGION="us-east-1"
ROLE_NAME="RideRequestLambdaRole"

echo -e "${YELLOW}=== Lambda Deployment Script ===${NC}\n"

# Check if we're in the project root
if [ ! -d "lambda" ]; then
    echo -e "${RED}Error: lambda/ directory not found${NC}"
    echo "Please run this script from the project root directory"
    exit 1
fi

# Get configuration
echo -e "${YELLOW}Configuration:${NC}"
read -p "S3 Bucket Name: " S3_BUCKET
read -p "SQS Queue URL: " SQS_QUEUE_URL
read -p "RabbitMQ Host (IP): " RABBITMQ_HOST
read -p "RabbitMQ Username [admin]: " RABBITMQ_USER
RABBITMQ_USER=${RABBITMQ_USER:-admin}
read -sp "RabbitMQ Password: " RABBITMQ_PASSWORD
echo -e "\n"

# Validate inputs
if [ -z "$S3_BUCKET" ] || [ -z "$SQS_QUEUE_URL" ] || [ -z "$RABBITMQ_HOST" ] || [ -z "$RABBITMQ_PASSWORD" ]; then
    echo -e "${RED}Error: All configuration values are required${NC}"
    exit 1
fi

# Get IAM Role ARN
echo -e "${YELLOW}Getting IAM Role...${NC}"
ROLE_ARN=$(aws iam get-role --role-name $ROLE_NAME --query 'Role.Arn' --output text --region $REGION)
if [ -z "$ROLE_ARN" ]; then
    echo -e "${RED}Error: Could not find IAM role $ROLE_NAME${NC}"
    exit 1
fi
echo -e "${GREEN}✓ Found role: $ROLE_ARN${NC}\n"

# Function to deploy a single Lambda
deploy_function() {
    local FUNC_NAME=$1
    local DIR=$2
    local HANDLER="lambda_function.lambda_handler"
    local TIMEOUT=$3
    local MEMORY=$4
    local ENV_VARS=$5
    
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}Deploying: $FUNC_NAME${NC}"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    
    # Navigate to function directory
    cd "$DIR"
    echo "Working directory: $(pwd)"
    
    # Clean up any previous builds
    rm -rf build package deployment.zip
    mkdir -p build
    
    # Copy Lambda function
    cp lambda_function.py build/
    
    # Install dependencies if they exist
    if [ -f "requirements.txt" ]; then
        echo "Installing dependencies..."
        pip install -q -r requirements.txt -t build/ --break-system-packages 2>/dev/null || \
        pip install -q -r requirements.txt -t build/
    fi
    
    # Create deployment package
    echo "Creating deployment package..."
    cd build
    zip -q -r ../deployment.zip .
    cd ..
    
    # Check deployment size
    SIZE=$(ls -lh deployment.zip | awk '{print $5}')
    echo "Deployment package size: $SIZE"
    
    # Check if function exists
    if aws lambda get-function --function-name "$FUNC_NAME" --region $REGION &>/dev/null; then
        echo "Updating existing function..."
        
        aws lambda update-function-code \
            --function-name "$FUNC_NAME" \
            --zip-file fileb://deployment.zip \
            --region $REGION &>/dev/null
        
        # Wait for update to complete
        aws lambda wait function-updated --function-name "$FUNC_NAME" --region $REGION
        
        aws lambda update-function-configuration \
            --function-name "$FUNC_NAME" \
            --runtime python3.11 \
            --handler "$HANDLER" \
            --timeout $TIMEOUT \
            --memory-size $MEMORY \
            --environment "$ENV_VARS" \
            --region $REGION &>/dev/null
            
        echo -e "${GREEN}✓ Function updated successfully${NC}"
    else
        echo "Creating new function..."
        
        aws lambda create-function \
            --function-name "$FUNC_NAME" \
            --runtime python3.11 \
            --role "$ROLE_ARN" \
            --handler "$HANDLER" \
            --timeout $TIMEOUT \
            --memory-size $MEMORY \
            --zip-file fileb://deployment.zip \
            --environment "$ENV_VARS" \
            --region $REGION &>/dev/null
            
        echo -e "${GREEN}✓ Function created successfully${NC}"
    fi
    
    # Cleanup
    rm -rf build deployment.zip
    
    # Return to project root
    cd - > /dev/null
    echo ""
}

# Start deployment
echo -e "${YELLOW}Starting Lambda deployment...${NC}\n"
PROJECT_ROOT=$(pwd)

# 1. Deploy Producer Lambda
deploy_function \
    "ride-request-producer" \
    "$PROJECT_ROOT/lambda/producer" \
    30 \
    512 \
    "Variables={SQS_QUEUE_URL=$SQS_QUEUE_URL,RABBITMQ_HOST=$RABBITMQ_HOST,RABBITMQ_PORT=5672,RABBITMQ_USER=$RABBITMQ_USER,RABBITMQ_PASSWORD=$RABBITMQ_PASSWORD,RABBITMQ_QUEUE=ride-requests}"

# 2. Deploy SQS Consumer Lambda
deploy_function \
    "ride-request-consumer-sqs" \
    "$PROJECT_ROOT/lambda/consumer_sqs" \
    60 \
    512 \
    "Variables={S3_BUCKET_NAME=$S3_BUCKET}"

# 3. Deploy RabbitMQ Consumer Lambda
deploy_function \
    "ride-request-consumer-rabbitmq" \
    "$PROJECT_ROOT/lambda/consumer_rabbitmq" \
    60 \
    512 \
    "Variables={S3_BUCKET_NAME=$S3_BUCKET,RABBITMQ_HOST=$RABBITMQ_HOST,RABBITMQ_PORT=5672,RABBITMQ_USER=$RABBITMQ_USER,RABBITMQ_PASSWORD=$RABBITMQ_PASSWORD,RABBITMQ_QUEUE=ride-requests}"

# 4. Deploy Comparison Lambda
deploy_function \
    "ride-request-comparison" \
    "$PROJECT_ROOT/lambda/comparison" \
    30 \
    256 \
    "Variables={S3_BUCKET_NAME=$S3_BUCKET}"

# Configure SQS Trigger
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YELLOW}Configuring SQS Trigger...${NC}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

SQS_QUEUE_ARN=$(aws sqs get-queue-attributes \
    --queue-url "$SQS_QUEUE_URL" \
    --attribute-names QueueArn \
    --query 'Attributes.QueueArn' \
    --output text \
    --region $REGION)

# Check if mapping already exists
EXISTING_MAPPING=$(aws lambda list-event-source-mappings \
    --function-name ride-request-consumer-sqs \
    --event-source-arn "$SQS_QUEUE_ARN" \
    --region $REGION \
    --query 'EventSourceMappings[0].UUID' \
    --output text)

if [ "$EXISTING_MAPPING" != "None" ] && [ -n "$EXISTING_MAPPING" ]; then
    echo "SQS trigger already exists"
else
    aws lambda create-event-source-mapping \
        --function-name ride-request-consumer-sqs \
        --event-source-arn "$SQS_QUEUE_ARN" \
        --batch-size 10 \
        --region $REGION &>/dev/null
    echo -e "${GREEN}✓ SQS trigger created${NC}"
fi
echo ""

# Configure EventBridge for RabbitMQ Consumer
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YELLOW}Configuring EventBridge Trigger...${NC}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

# Create/update EventBridge rule
aws events put-rule \
    --name ride-request-rabbitmq-consumer-trigger \
    --schedule-expression "rate(1 minute)" \
    --state ENABLED \
    --region $REGION &>/dev/null

# Get rule ARN
RULE_ARN=$(aws events describe-rule \
    --name ride-request-rabbitmq-consumer-trigger \
    --query 'Arn' \
    --output text \
    --region $REGION)

# Get Lambda ARN
LAMBDA_ARN=$(aws lambda get-function \
    --function-name ride-request-consumer-rabbitmq \
    --query 'Configuration.FunctionArn' \
    --output text \
    --region $REGION)

# Add Lambda permission for EventBridge
aws lambda add-permission \
    --function-name ride-request-consumer-rabbitmq \
    --statement-id EventBridgeInvoke \
    --action lambda:InvokeFunction \
    --principal events.amazonaws.com \
    --source-arn "$RULE_ARN" \
    --region $REGION &>/dev/null || echo "Permission already exists"

# Add Lambda as target
aws events put-targets \
    --rule ride-request-rabbitmq-consumer-trigger \
    --targets "Id=1,Arn=$LAMBDA_ARN" \
    --region $REGION &>/dev/null

echo -e "${GREEN}✓ EventBridge trigger configured (1-minute interval)${NC}\n"

# Summary
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}Deployment Complete!${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"

echo -e "${YELLOW}Deployed Functions:${NC}"
aws lambda list-functions \
    --query 'Functions[?starts_with(FunctionName, `ride-request`)].FunctionName' \
    --output table \
    --region $REGION

echo -e "\n${YELLOW}Next Steps:${NC}"
echo "1. Configure API Gateway (run: ./scripts/setup_api_gateway.sh)"
echo "2. Test the endpoints"
echo "3. Monitor CloudWatch Logs"

echo -e "\n${YELLOW}Monitor Logs:${NC}"
echo "aws logs tail /aws/lambda/ride-request-producer --follow"
echo "aws logs tail /aws/lambda/ride-request-consumer-sqs --follow"
echo "aws logs tail /aws/lambda/ride-request-consumer-rabbitmq --follow"
