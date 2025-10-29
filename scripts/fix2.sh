#!/bin/bash

# Fix SQS Visibility Timeout and Configure Triggers

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${YELLOW}=== Fixing SQS Configuration and Triggers ===${NC}\n"

REGION="us-east-1"
SQS_QUEUE_URL="https://sqs.us-east-1.amazonaws.com/106774395794/ride-requests-sqs"

# Fix 1: Update SQS Visibility Timeout
echo -e "${YELLOW}1. Updating SQS Visibility Timeout...${NC}"
echo "Setting visibility timeout to 360 seconds (6 minutes)"
echo "This is 6x the Lambda timeout (60 seconds) as recommended by AWS"

aws sqs set-queue-attributes \
  --queue-url "$SQS_QUEUE_URL" \
  --attributes VisibilityTimeout=360 \
  --region $REGION

echo -e "${GREEN}✓ SQS visibility timeout updated${NC}\n"

# Verify
VISIBILITY=$(aws sqs get-queue-attributes \
  --queue-url "$SQS_QUEUE_URL" \
  --attribute-names VisibilityTimeout \
  --query 'Attributes.VisibilityTimeout' \
  --output text \
  --region $REGION)

echo "Current visibility timeout: $VISIBILITY seconds"
echo ""

# Fix 2: Configure SQS Trigger
echo -e "${YELLOW}2. Configuring SQS Trigger...${NC}"

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
      --region $REGION > /dev/null
    echo -e "${GREEN}✓ SQS trigger enabled${NC}\n"
else
    echo "Creating new trigger..."
    aws lambda create-event-source-mapping \
      --function-name ride-request-consumer-sqs \
      --event-source-arn "$SQS_ARN" \
      --batch-size 10 \
      --enabled \
      --region $REGION > /dev/null
    echo -e "${GREEN}✓ SQS trigger created${NC}\n"
fi

# Fix 3: Configure EventBridge Rule for RabbitMQ
echo -e "${YELLOW}3. Configuring EventBridge Rule...${NC}"

# Create/update the rule
aws events put-rule \
  --name ride-request-rabbitmq-consumer-trigger \
  --schedule-expression "rate(1 minute)" \
  --state ENABLED \
  --region $REGION > /dev/null

echo "Rule created/updated"

# Get Lambda ARN
LAMBDA_ARN=$(aws lambda get-function \
  --function-name ride-request-consumer-rabbitmq \
  --query 'Configuration.FunctionArn' \
  --output text \
  --region $REGION)

# Get Rule ARN
RULE_ARN=$(aws events describe-rule \
  --name ride-request-rabbitmq-consumer-trigger \
  --query 'Arn' \
  --output text \
  --region $REGION)

# Add permission for EventBridge to invoke Lambda
aws lambda add-permission \
  --function-name ride-request-consumer-rabbitmq \
  --statement-id EventBridgeInvoke \
  --action lambda:InvokeFunction \
  --principal events.amazonaws.com \
  --source-arn "$RULE_ARN" \
  --region $REGION 2>/dev/null || echo "Permission already exists"

# Add Lambda as target
aws events put-targets \
  --rule ride-request-rabbitmq-consumer-trigger \
  --targets "Id=1,Arn=$LAMBDA_ARN" \
  --region $REGION > /dev/null

echo -e "${GREEN}✓ EventBridge rule configured${NC}\n"

# Verification
echo -e "${YELLOW}=== Verification ===${NC}\n"

echo "SQS Queue Configuration:"
aws sqs get-queue-attributes \
  --queue-url "$SQS_QUEUE_URL" \
  --attribute-names VisibilityTimeout,ApproximateNumberOfMessages \
  --query 'Attributes' \
  --output table \
  --region $REGION

echo -e "\nSQS Trigger Status:"
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
  --query 'Targets[0].{Id:Id}' \
  --output table

echo -e "\n${GREEN}=== All Fixed! ===${NC}\n"

echo -e "${YELLOW}What happens now:${NC}"
echo "1. ✓ SQS visibility timeout increased to 360 seconds"
echo "2. ✓ SQS consumer will start processing messages immediately"
echo "3. ✓ RabbitMQ consumer will run every 1 minute"
echo "4. ✓ Messages will be processed and metrics saved to S3"

echo -e "\n${YELLOW}Watch processing in real-time:${NC}"
echo "aws logs tail /aws/lambda/ride-request-consumer-sqs --follow"

echo -e "\n${YELLOW}After 2 minutes, check results:${NC}"
echo "curl https://clmtlmde81.execute-api.us-east-1.amazonaws.com/prod/comparison | jq"

echo -e "\n${YELLOW}Check S3 files:${NC}"
echo "aws s3 ls s3://ride-latencies-1761760055/ --recursive"
