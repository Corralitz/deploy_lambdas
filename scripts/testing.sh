#!/bin/bash

# Diagnostic Script: Check Message Processing Status

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${YELLOW}=== Checking Message Processing Status ===${NC}\n"

BUCKET="ride-latencies-1761760055"
REGION="us-east-1"

# 1. Check SQS Queue
echo -e "${YELLOW}1. Checking SQS Queue...${NC}"
SQS_URL="https://sqs.us-east-1.amazonaws.com/106774395794/ride-requests-sqs"

QUEUE_DEPTH=$(aws sqs get-queue-attributes \
  --queue-url "$SQS_URL" \
  --attribute-names ApproximateNumberOfMessages \
  --query 'Attributes.ApproximateNumberOfMessages' \
  --output text \
  --region $REGION)

echo "Messages in SQS queue: $QUEUE_DEPTH"

if [ "$QUEUE_DEPTH" -gt 0 ]; then
    echo -e "${RED}⚠ Messages are stuck in SQS - consumer not processing${NC}"
else
    echo -e "${GREEN}✓ SQS queue is empty (messages processed or none sent)${NC}"
fi
echo ""

# 2. Check RabbitMQ Queue
echo -e "${YELLOW}2. Checking RabbitMQ Queue...${NC}"
echo "To check RabbitMQ, SSH to EC2 and run:"
echo "  ssh ubuntu@54.163.15.246"
echo "  sudo rabbitmqctl list_queues"
echo ""

# 3. Check S3 Bucket
echo -e "${YELLOW}3. Checking S3 Bucket for Metrics...${NC}"
SQS_FILES=$(aws s3 ls s3://$BUCKET/sqs/ --recursive 2>/dev/null | wc -l)
RMQ_FILES=$(aws s3 ls s3://$BUCKET/rabbitmq/ --recursive 2>/dev/null | wc -l)

echo "Files in s3://$BUCKET/sqs/: $SQS_FILES"
echo "Files in s3://$BUCKET/rabbitmq/: $RMQ_FILES"

if [ "$SQS_FILES" -eq 0 ] && [ "$RMQ_FILES" -eq 0 ]; then
    echo -e "${RED}⚠ No metrics files in S3 - consumers haven't processed anything${NC}"
else
    echo -e "${GREEN}✓ Found $((SQS_FILES + RMQ_FILES)) total metrics files${NC}"
fi
echo ""

# 4. Check Lambda Functions
echo -e "${YELLOW}4. Checking Lambda Consumer Functions...${NC}"

# SQS Consumer
echo "SQS Consumer:"
SQS_STATE=$(aws lambda get-function \
  --function-name ride-request-consumer-sqs \
  --query 'Configuration.State' \
  --output text \
  --region $REGION 2>/dev/null)

if [ "$SQS_STATE" = "Active" ]; then
    echo -e "  State: ${GREEN}$SQS_STATE${NC}"
    
    # Check if trigger is configured
    TRIGGER=$(aws lambda list-event-source-mappings \
      --function-name ride-request-consumer-sqs \
      --query 'EventSourceMappings[0].State' \
      --output text \
      --region $REGION 2>/dev/null)
    
    if [ "$TRIGGER" = "Enabled" ]; then
        echo -e "  Trigger: ${GREEN}$TRIGGER${NC}"
    else
        echo -e "  Trigger: ${RED}$TRIGGER (NOT ENABLED!)${NC}"
    fi
else
    echo -e "  State: ${RED}$SQS_STATE${NC}"
fi

# Check recent invocations
INVOCATIONS=$(aws cloudwatch get-metric-statistics \
  --namespace AWS/Lambda \
  --metric-name Invocations \
  --dimensions Name=FunctionName,Value=ride-request-consumer-sqs \
  --start-time $(date -u -d '10 minutes ago' +%Y-%m-%dT%H:%M:%S) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
  --period 600 \
  --statistics Sum \
  --query 'Datapoints[0].Sum' \
  --output text \
  --region $REGION 2>/dev/null)

if [ "$INVOCATIONS" != "None" ] && [ -n "$INVOCATIONS" ]; then
    echo -e "  Recent invocations (last 10 min): ${GREEN}$INVOCATIONS${NC}"
else
    echo -e "  Recent invocations (last 10 min): ${RED}0${NC}"
fi
echo ""

# RabbitMQ Consumer
echo "RabbitMQ Consumer:"
RMQ_STATE=$(aws lambda get-function \
  --function-name ride-request-consumer-rabbitmq \
  --query 'Configuration.State' \
  --output text \
  --region $REGION 2>/dev/null)

if [ "$RMQ_STATE" = "Active" ]; then
    echo -e "  State: ${GREEN}$RMQ_STATE${NC}"
    
    # Check EventBridge rule
    RULE_STATE=$(aws events describe-rule \
      --name ride-request-rabbitmq-consumer-trigger \
      --query 'State' \
      --output text \
      --region $REGION 2>/dev/null)
    
    if [ "$RULE_STATE" = "ENABLED" ]; then
        echo -e "  EventBridge Rule: ${GREEN}$RULE_STATE${NC}"
    else
        echo -e "  EventBridge Rule: ${RED}$RULE_STATE${NC}"
    fi
else
    echo -e "  State: ${RED}$RMQ_STATE${NC}"
fi

RMQ_INVOCATIONS=$(aws cloudwatch get-metric-statistics \
  --namespace AWS/Lambda \
  --metric-name Invocations \
  --dimensions Name=FunctionName,Value=ride-request-consumer-rabbitmq \
  --start-time $(date -u -d '10 minutes ago' +%Y-%m-%dT%H:%M:%S) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
  --period 600 \
  --statistics Sum \
  --query 'Datapoints[0].Sum' \
  --output text \
  --region $REGION 2>/dev/null)

if [ "$RMQ_INVOCATIONS" != "None" ] && [ -n "$RMQ_INVOCATIONS" ]; then
    echo -e "  Recent invocations (last 10 min): ${GREEN}$RMQ_INVOCATIONS${NC}"
else
    echo -e "  Recent invocations (last 10 min): ${RED}0${NC}"
fi
echo ""

# 5. Check Lambda Logs
echo -e "${YELLOW}5. Recent Lambda Logs...${NC}"

echo "SQS Consumer logs (last 5 minutes):"
aws logs tail /aws/lambda/ride-request-consumer-sqs \
  --since 5m \
  --format short \
  --region $REGION 2>/dev/null | tail -10 || echo "No recent logs"
echo ""

echo "RabbitMQ Consumer logs (last 5 minutes):"
aws logs tail /aws/lambda/ride-request-consumer-rabbitmq \
  --since 5m \
  --format short \
  --region $REGION 2>/dev/null | tail -10 || echo "No recent logs"
echo ""

# 6. Recommendations
echo -e "${YELLOW}=== Recommendations ===${NC}"

if [ "$QUEUE_DEPTH" -gt 0 ]; then
    echo -e "${RED}• SQS messages not being consumed - check SQS consumer logs${NC}"
    echo "  Run: aws logs tail /aws/lambda/ride-request-consumer-sqs --follow"
fi

if [ "$SQS_FILES" -eq 0 ] && [ "$RMQ_FILES" -eq 0 ]; then
    echo -e "${RED}• No metrics in S3 - consumers haven't run or failed${NC}"
    echo "  • Wait 1-2 minutes for RabbitMQ consumer (runs every minute)"
    echo "  • Check consumer logs for errors"
    echo "  • Verify IAM permissions for S3 write"
fi

if [ "$INVOCATIONS" = "None" ] || [ -z "$INVOCATIONS" ]; then
    echo -e "${RED}• SQS Consumer not being invoked - check trigger configuration${NC}"
    echo "  Run: aws lambda list-event-source-mappings --function-name ride-request-consumer-sqs"
fi

if [ "$RMQ_INVOCATIONS" = "None" ] || [ -z "$RMQ_INVOCATIONS" ]; then
    echo -e "${RED}• RabbitMQ Consumer not being invoked - check EventBridge rule${NC}"
    echo "  Run: aws events list-targets-by-rule --rule ride-request-rabbitmq-consumer-trigger"
fi

echo ""
echo -e "${YELLOW}Quick Actions:${NC}"
echo "• View live SQS consumer logs: aws logs tail /aws/lambda/ride-request-consumer-sqs --follow"
echo "• View live RabbitMQ consumer logs: aws logs tail /aws/lambda/ride-request-consumer-rabbitmq --follow"
echo "• List S3 files: aws s3 ls s3://$BUCKET/ --recursive"
echo "• Test comparison endpoint: curl https://clmtlmde81.execute-api.us-east-1.amazonaws.com/prod/comparison"
