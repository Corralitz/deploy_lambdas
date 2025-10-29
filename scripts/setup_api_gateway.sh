#!/bin/bash

# API Gateway Setup Script
# Creates REST API with two endpoints: POST /request-ride and GET /comparison

set -e

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

REGION="us-east-1"
API_NAME="ride-request-api"

echo -e "${YELLOW}========================================${NC}"
echo -e "${YELLOW}Creating API Gateway${NC}"
echo -e "${YELLOW}========================================${NC}"

# Get Lambda ARNs
PRODUCER_ARN=$(aws lambda get-function --function-name ride-request-producer --query 'Configuration.FunctionArn' --output text --region $REGION)
COMPARISON_ARN=$(aws lambda get-function --function-name ride-request-comparison --query 'Configuration.FunctionArn' --output text --region $REGION)

echo -e "Producer Lambda ARN: ${GREEN}$PRODUCER_ARN${NC}"
echo -e "Comparison Lambda ARN: ${GREEN}$COMPARISON_ARN${NC}"

# Create REST API
echo -e "\n${YELLOW}Creating REST API...${NC}"
API_ID=$(aws apigateway create-rest-api \
    --name "$API_NAME" \
    --description "API for ride request comparison system" \
    --endpoint-configuration types=REGIONAL \
    --region $REGION \
    --query 'id' \
    --output text)

echo -e "${GREEN}✓ API Created with ID: $API_ID${NC}"

# Get root resource ID
ROOT_ID=$(aws apigateway get-resources \
    --rest-api-id $API_ID \
    --region $REGION \
    --query 'items[0].id' \
    --output text)

# Create /request-ride resource
echo -e "\n${YELLOW}Creating /request-ride endpoint...${NC}"
REQUEST_RIDE_ID=$(aws apigateway create-resource \
    --rest-api-id $API_ID \
    --parent-id $ROOT_ID \
    --path-part "request-ride" \
    --region $REGION \
    --query 'id' \
    --output text)

# Create POST method for /request-ride
aws apigateway put-method \
    --rest-api-id $API_ID \
    --resource-id $REQUEST_RIDE_ID \
    --http-method POST \
    --authorization-type NONE \
    --request-parameters "method.request.querystring.queue=false" \
    --region $REGION > /dev/null

# Integrate with Producer Lambda
aws apigateway put-integration \
    --rest-api-id $API_ID \
    --resource-id $REQUEST_RIDE_ID \
    --http-method POST \
    --type AWS_PROXY \
    --integration-http-method POST \
    --uri "arn:aws:apigateway:$REGION:lambda:path/2015-03-31/functions/$PRODUCER_ARN/invocations" \
    --region $REGION > /dev/null

# Add Lambda permission for API Gateway
aws lambda add-permission \
    --function-name ride-request-producer \
    --statement-id apigateway-invoke-post \
    --action lambda:InvokeFunction \
    --principal apigateway.amazonaws.com \
    --source-arn "arn:aws:execute-api:$REGION:$(aws sts get-caller-identity --query Account --output text):$API_ID/*/POST/request-ride" \
    --region $REGION 2>/dev/null || echo "Permission already exists"

# Enable CORS for POST
aws apigateway put-method-response \
    --rest-api-id $API_ID \
    --resource-id $REQUEST_RIDE_ID \
    --http-method POST \
    --status-code 200 \
    --response-parameters "method.response.header.Access-Control-Allow-Origin=true" \
    --region $REGION > /dev/null

# Create OPTIONS method for CORS
aws apigateway put-method \
    --rest-api-id $API_ID \
    --resource-id $REQUEST_RIDE_ID \
    --http-method OPTIONS \
    --authorization-type NONE \
    --region $REGION > /dev/null

aws apigateway put-integration \
    --rest-api-id $API_ID \
    --resource-id $REQUEST_RIDE_ID \
    --http-method OPTIONS \
    --type MOCK \
    --request-templates '{"application/json": "{\"statusCode\": 200}"}' \
    --region $REGION > /dev/null

aws apigateway put-method-response \
    --rest-api-id $API_ID \
    --resource-id $REQUEST_RIDE_ID \
    --http-method OPTIONS \
    --status-code 200 \
    --response-parameters '{"method.response.header.Access-Control-Allow-Headers": true, "method.response.header.Access-Control-Allow-Methods": true, "method.response.header.Access-Control-Allow-Origin": true}' \
    --region $REGION > /dev/null

aws apigateway put-integration-response \
    --rest-api-id $API_ID \
    --resource-id $REQUEST_RIDE_ID \
    --http-method OPTIONS \
    --status-code 200 \
    --response-parameters '{"method.response.header.Access-Control-Allow-Headers": "'\''Content-Type,X-Amz-Date,Authorization,X-Api-Key,X-Amz-Security-Token'\''", "method.response.header.Access-Control-Allow-Methods": "'\''POST,OPTIONS'\''", "method.response.header.Access-Control-Allow-Origin": "'\''*'\''"}' \
    --region $REGION > /dev/null

echo -e "${GREEN}✓ /request-ride endpoint configured${NC}"

# Create /comparison resource
echo -e "\n${YELLOW}Creating /comparison endpoint...${NC}"
COMPARISON_ID=$(aws apigateway create-resource \
    --rest-api-id $API_ID \
    --parent-id $ROOT_ID \
    --path-part "comparison" \
    --region $REGION \
    --query 'id' \
    --output text)

# Create GET method for /comparison
aws apigateway put-method \
    --rest-api-id $API_ID \
    --resource-id $COMPARISON_ID \
    --http-method GET \
    --authorization-type NONE \
    --request-parameters "method.request.querystring.details=false,method.request.querystring.limit=false" \
    --region $REGION > /dev/null

# Integrate with Comparison Lambda
aws apigateway put-integration \
    --rest-api-id $API_ID \
    --resource-id $COMPARISON_ID \
    --http-method GET \
    --type AWS_PROXY \
    --integration-http-method POST \
    --uri "arn:aws:apigateway:$REGION:lambda:path/2015-03-31/functions/$COMPARISON_ARN/invocations" \
    --region $REGION > /dev/null

# Add Lambda permission for API Gateway
aws lambda add-permission \
    --function-name ride-request-comparison \
    --statement-id apigateway-invoke-get \
    --action lambda:InvokeFunction \
    --principal apigateway.amazonaws.com \
    --source-arn "arn:aws:execute-api:$REGION:$(aws sts get-caller-identity --query Account --output text):$API_ID/*/GET/comparison" \
    --region $REGION 2>/dev/null || echo "Permission already exists"

# Enable CORS for GET
aws apigateway put-method-response \
    --rest-api-id $API_ID \
    --resource-id $COMPARISON_ID \
    --http-method GET \
    --status-code 200 \
    --response-parameters "method.response.header.Access-Control-Allow-Origin=true" \
    --region $REGION > /dev/null

# Create OPTIONS method for CORS
aws apigateway put-method \
    --rest-api-id $API_ID \
    --resource-id $COMPARISON_ID \
    --http-method OPTIONS \
    --authorization-type NONE \
    --region $REGION > /dev/null

aws apigateway put-integration \
    --rest-api-id $API_ID \
    --resource-id $COMPARISON_ID \
    --http-method OPTIONS \
    --type MOCK \
    --request-templates '{"application/json": "{\"statusCode\": 200}"}' \
    --region $REGION > /dev/null

aws apigateway put-method-response \
    --rest-api-id $API_ID \
    --resource-id $COMPARISON_ID \
    --http-method OPTIONS \
    --status-code 200 \
    --response-parameters '{"method.response.header.Access-Control-Allow-Headers": true, "method.response.header.Access-Control-Allow-Methods": true, "method.response.header.Access-Control-Allow-Origin": true}' \
    --region $REGION > /dev/null

aws apigateway put-integration-response \
    --rest-api-id $API_ID \
    --resource-id $COMPARISON_ID \
    --http-method OPTIONS \
    --status-code 200 \
    --response-parameters '{"method.response.header.Access-Control-Allow-Headers": "'\''Content-Type,X-Amz-Date,Authorization,X-Api-Key,X-Amz-Security-Token'\''", "method.response.header.Access-Control-Allow-Methods": "'\''GET,OPTIONS'\''", "method.response.header.Access-Control-Allow-Origin": "'\''*'\''"}' \
    --region $REGION > /dev/null

echo -e "${GREEN}✓ /comparison endpoint configured${NC}"

# Deploy API to 'prod' stage
echo -e "\n${YELLOW}Deploying API to 'prod' stage...${NC}"
aws apigateway create-deployment \
    --rest-api-id $API_ID \
    --stage-name prod \
    --stage-description "Production stage" \
    --description "Initial deployment" \
    --region $REGION > /dev/null

echo -e "${GREEN}✓ API deployed to prod stage${NC}"

# Get invoke URL
INVOKE_URL="https://$API_ID.execute-api.$REGION.amazonaws.com/prod"

echo -e "\n${GREEN}========================================${NC}"
echo -e "${GREEN}API Gateway Setup Complete!${NC}"
echo -e "${GREEN}========================================${NC}"

echo -e "\n${YELLOW}API Endpoints:${NC}"
echo -e "POST: ${GREEN}$INVOKE_URL/request-ride?queue=sqs${NC}"
echo -e "POST: ${GREEN}$INVOKE_URL/request-ride?queue=rabbitmq${NC}"
echo -e "GET:  ${GREEN}$INVOKE_URL/comparison${NC}"

echo -e "\n${YELLOW}Test Commands:${NC}"
echo -e "\n# Test SQS:"
cat << EOF
curl -X POST "$INVOKE_URL/request-ride?queue=sqs" \\
  -H "Content-Type: application/json" \\
  -d '{
    "passenger_name": "John Doe",
    "current_address": "123 Main St",
    "destination": "456 Oak Ave",
    "phone": "+1234567890"
  }'
EOF

echo -e "\n\n# Test RabbitMQ:"
cat << EOF
curl -X POST "$INVOKE_URL/request-ride?queue=rabbitmq" \\
  -H "Content-Type: application/json" \\
  -d '{
    "passenger_name": "Jane Smith",
    "current_address": "789 Pine St",
    "destination": "321 Elm St",
    "phone": "+1987654321"
  }'
EOF

echo -e "\n\n# Get comparison:"
echo "curl $INVOKE_URL/comparison"

echo -e "\n\n# Get detailed comparison:"
echo "curl '$INVOKE_URL/comparison?details=true&limit=50'"

echo -e "\n${YELLOW}API Gateway Console:${NC}"
echo "https://console.aws.amazon.com/apigateway/home?region=$REGION#/apis/$API_ID/resources"
