#!/bin/bash

# Fix Lambda Triggers Script

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${YELLOW}=== Fixing Lambda Triggers ===${NC}\n"

REGION="us-east-1"
SQS_QUEUE_URL="https://sqs.us-east-1.amazonaws.com/106774395794/ride-requests-sqs"

# Fix 1: Configure SQS Trigger
echo -e "${YELLOW}1. Configuring SQS Trigger...${NC}"

# Get SQS ARN
SQS_ARN=$(aws sqs get-queue-attributes \
  --queue-url "$SQS_QUEUE_URL" \
  --attribute-names QueueArn \
  --query 'Attributes.QueueArn' \
  --output text \
  --region $REGION)

echo "SQS ARN: $SQS_ARN"

# Check if trigger already exists
EXISTING=$(aws lambda list-event-source-mappings \
  --function-name ride-request-consumer-sqs \
  --event-source-arn "$SQS_ARN" \
  --region $REGION \
  --query 'EventSourceMappings[0].UUID' \
  --output text 2>/dev/null)

if [ "$EXISTING" != "None" ] && [ -n "$EXISTING" ]; then
    echo "Trigger exists, enabling it..."
    aws lambda update-event-source-mapping \
      --uuid "$EXISTING" \
      --enabled \
      --region $REGION
    echo -e "${GREEN}✓ SQS trigger enabled${NC}\n"
else
    echo "Creating new trigger..."
    aws lambda create-event-source-mapping \
      --function-name ride-request-consumer-sqs \
      --event-source-arn "$SQS_ARN" \
      --batch-size 10 \
      --enabled \
      --region $REGION
    echo -e "${GREEN}✓ SQS trigger created${NC}\n"
fi

# Fix 2: Configure EventBridge Rule for RabbitMQ
echo -e "${YELLOW}2. Configuring EventBridge Rule...${NC}"

# Create/update the rule
aws events put-rule \
  --name ride-request-rabbitmq-consumer-trigger \
  --schedule-expression "rate(1 minute)" \
  --state ENABLED \
  --region $REGION

echo "Rule created/updated"

# Get Lambda ARN
LAMBDA_ARN=$(aws lambda get-function \
  --function-name ride-request-consumer-rabbitmq \
  --query 'Configuration.FunctionArn' \
  --output text \
  --region $REGION)

echo "Lambda ARN: $LAMBDA_ARN"

# Get Rule ARN
RULE_ARN=$(aws events describe-rule \
  --name ride-request-rabbitmq-consumer-trigger \
  --query 'Arn' \
  --output text \
  --region $REGION)

echo "Rule ARN: $RULE_ARN"

# Add permission for EventBridge to invoke Lambda
echo "Adding Lambda permission..."
aws lambda add-permission \
  --function-name ride-request-consumer-rabbitmq \
  --statement-id EventBridgeInvoke \
  --action lambda:InvokeFunction \
  --principal events.amazonaws.com \
  --source-arn "$RULE_ARN" \
  --region $REGION 2>/dev/null || echo "Permission already exists"

# Add Lambda as target
echo "Setting Lambda as target..."
aws events put-targets \
  --rule ride-request-rabbitmq-consumer-trigger \
  --targets "Id=1,Arn=$LAMBDA_ARN" \
  --region $REGION

echo -e "${GREEN}✓ EventBridge rule configured${NC}\n"

# Verify
echo -e "${YELLOW}=== Verification ===${NC}\n"

echo "SQS Trigger Status:"
aws lambda list-event-source-mappings \
  --function-name ride-request-consumer-sqs \
  --region $REGION \
  --query 'EventSourceMappings[0].{State:State,BatchSize:BatchSize}' \
  --output table

echo -e "\nEventBridge Rule Status:"
aws events describe-rule \
  --name ride-request-rabbitmq-consumer-trigger \
  --region $REGION \
  --query '{Name:Name,State:State,Schedule:ScheduleExpression}' \
  --output table

echo -e "\nEventBridge Targets:"
aws events list-targets-by-rule \
  --rule ride-request-rabbitmq-consumer-trigger \
  --region $REGION \
  --query 'Targets[0].{Id:Id,Arn:Arn}' \
  --output table

echo -e "\n${GREEN}=== Triggers Fixed! ===${NC}\n"

echo -e "${YELLOW}What happens now:${NC}"
echo "1. SQS consumer will immediately start processing the 3 stuck messages"
echo "2. RabbitMQ consumer will run within the next 60 seconds"
echo "3. Metrics will be saved to S3"
echo "4. Comparison endpoint will show results"

echo -e "\n${YELLOW}Monitor processing:${NC}"
echo "• SQS Consumer: aws logs tail /aws/lambda/ride-request-consumer-sqs --follow"
echo "• RabbitMQ Consumer: aws logs tail /aws/lambda/ride-request-consumer-rabbitmq --follow"

echo -e "\n${YELLOW}Wait 2 minutes, then check results:${NC}"
echo "curl https://clmtlmde81.execute-api.us-east-1.amazonaws.com/prod/comparison | jq"
