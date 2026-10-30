#!/usr/bin/env bash
# Crea la cola SQS FIFO de reservaciones (más una DLQ para mensajes que fallan repetidamente).
source "$(dirname "$0")/config.sh"
require_cmd aws

log "Creando DLQ $DLQ_NAME"
dlq_url=$(aws sqs create-queue --queue-name "$DLQ_NAME" \
  --attributes FifoQueue=true,MessageRetentionPeriod=1209600 --query QueueUrl --output text)
dlq_arn=$(aws sqs get-queue-attributes --queue-url "$dlq_url" --attribute-names QueueArn \
  --query Attributes.QueueArn --output text)
ok "$dlq_url"

log "Creando cola FIFO $QUEUE_NAME"
# MessageGroupId (concert_id) y MessageDeduplicationId (reservation_id) los pone ticket-api en cada mensaje.
cat > "$TMP_DIR/sqs-attributes.json" <<EOF
{
  "FifoQueue": "true",
  "ContentBasedDeduplication": "false",
  "VisibilityTimeout": "60",
  "ReceiveMessageWaitTimeSeconds": "20",
  "RedrivePolicy": "{\"deadLetterTargetArn\":\"$dlq_arn\",\"maxReceiveCount\":\"5\"}"
}
EOF
url=$(aws sqs create-queue --queue-name "$QUEUE_NAME" \
  --attributes "file://.tmp/sqs-attributes.json" --query QueueUrl --output text)
ok "$url"

aws sqs get-queue-attributes --queue-url "$url" \
  --attribute-names FifoQueue ContentBasedDeduplication VisibilityTimeout RedrivePolicy --output table
