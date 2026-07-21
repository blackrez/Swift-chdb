#!/bin/bash
# Build & deploy chDB Lambda to AWS.
#
# Prerequisites:
#   - AWS CLI installed and configured (aws configure)
#   - Docker installed
#   - ECR repository created: aws ecr create-repository --repository-name chdb-lambda
#
# Usage:
#   ./scripts/build-and-deploy.sh              # build + push to ECR + update Lambda
#   ./scripts/build-and-deploy.sh --build-only  # build Docker image, don't deploy

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# ── Config ──
AWS_REGION="${AWS_REGION:-eu-west-1}"
FUNCTION_NAME="${FUNCTION_NAME:-chdb-lambda}"
ECR_REPO="${ECR_REPO:-chdb-lambda}"
MEMORY_MB="${MEMORY_MB:-1024}"
TIMEOUT_SEC="${TIMEOUT_SEC:-30}"
ARCH="${ARCH:-arm64}"   # arm64 (Graviton) or x86_64
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_URI="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPO}"

cd "$PROJECT_DIR"

echo "========================================="
echo " chDB Lambda — Build & Deploy"
echo "========================================="
echo " Architecture: $ARCH"
echo " ECR:          $ECR_URI"
echo " Function:     $FUNCTION_NAME"
echo ""

# ── Build Docker image ──
echo "🐳 Building Docker image for linux/$ARCH..."
docker build \
    --platform "linux/$ARCH" \
    --build-arg TARGETARCH="$ARCH" \
    -t "$ECR_REPO:latest" \
    .

echo "✅ Image built: $ECR_REPO:latest"

if [ "${1:-}" = "--build-only" ]; then
    echo ""
    echo "Build complete. To test locally:"
    echo "  docker run --rm -p 9000:8080 $ECR_REPO:latest"
    echo "  curl -X POST http://localhost:9000/2015-03-31/functions/function/invocations -d '{\"sql\":\"SELECT 1\"}'"
    exit 0
fi

# ── Push to ECR ──
echo ""
echo "📤 Authenticating with ECR..."
aws ecr get-login-password --region "$AWS_REGION" | \
    docker login --username AWS --password-stdin "${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

echo "📤 Pushing to ECR..."
docker tag "$ECR_REPO:latest" "$ECR_URI:latest"
docker push "$ECR_URI:latest"
echo "✅ Pushed to $ECR_URI:latest"

# ── Create or update Lambda ──
echo ""
if aws lambda get-function --function-name "$FUNCTION_NAME" --region "$AWS_REGION" &>/dev/null; then
    echo "🔄 Updating Lambda function..."
    aws lambda update-function-code \
        --function-name "$FUNCTION_NAME" \
        --image-uri "$ECR_URI:latest" \
        --region "$AWS_REGION" \
        --no-cli-pager
    echo "✅ Lambda updated. Waiting for update to complete..."
    aws lambda wait function-updated --function-name "$FUNCTION_NAME" --region "$AWS_REGION"
else
    echo "🆕 Creating Lambda function..."
    aws lambda create-function \
        --function-name "$FUNCTION_NAME" \
        --package-type Image \
        --code "ImageUri=$ECR_URI:latest" \
        --role "arn:aws:iam::${AWS_ACCOUNT_ID}:role/lambda-execution-role" \
        --architectures "$ARCH" \
        --memory-size "$MEMORY_MB" \
        --timeout "$TIMEOUT_SEC" \
        --region "$AWS_REGION" \
        --no-cli-pager
    echo "✅ Lambda created."
fi

# ── Create HTTP API Gateway (idempotent) ──
echo ""
API_ID=$(aws apigatewayv2 get-apis --region "$AWS_REGION" --query "Items[?Name=='chdb-lambda-api'].ApiId" --output text 2>/dev/null || true)

if [ -z "$API_ID" ] || [ "$API_ID" = "None" ]; then
    echo "🌐 Creating HTTP API Gateway..."
    API_ID=$(aws apigatewayv2 create-api \
        --name "chdb-lambda-api" \
        --protocol-type HTTP \
        --target "arn:aws:lambda:${AWS_REGION}:${AWS_ACCOUNT_ID}:function:${FUNCTION_NAME}" \
        --region "$AWS_REGION" \
        --query ApiId --output text)

    # Grant API Gateway permission to invoke Lambda
    aws lambda add-permission \
        --function-name "$FUNCTION_NAME" \
        --statement-id api-gateway \
        --action lambda:InvokeFunction \
        --principal apigateway.amazonaws.com \
        --source-arn "arn:aws:execute-api:${AWS_REGION}:${AWS_ACCOUNT_ID}:${API_ID}/*/*" \
        --region "$AWS_REGION" \
        2>/dev/null || true
    echo "✅ API Gateway created: $API_ID"
else
    echo "🌐 API Gateway already exists: $API_ID"
fi

API_URL="https://${API_ID}.execute-api.${AWS_REGION}.amazonaws.com"

echo ""
echo "========================================="
echo " ✅ Deploy complete!"
echo ""
echo " Lambda:  $FUNCTION_NAME"
echo " API URL: $API_URL"
echo ""
echo " Test it:"
echo "   curl -X POST $API_URL \\"
echo "     -H 'Content-Type: application/json' \\"
echo "     -d '{\"sql\":\"SELECT count() FROM s3(\\\\\"s3://my-bucket/data/*.parquet\\\\\")\"}'"
echo ""
echo " To test locally first:"
echo "   docker run --rm -p 9000:8080 $ECR_REPO:latest"
echo "   curl -X POST http://localhost:9000/2015-03-31/functions/function/invocations \\"
echo "     -d '{\"body\":\"{\\\"sql\\\":\\\"SELECT 1\\\"}\"}'"
echo "========================================="
