#!/usr/bin/env bash
# Muestra el estado de todos los componentes (útil para el video).
source "$(dirname "$0")/config.sh"
set +e

log "kubectl get nodes"
kubectl get nodes -o wide
log "kubectl get pods,services -n $K8S_NAMESPACE"
kubectl -n "$K8S_NAMESPACE" get pods,services -o wide

log "Imágenes en ECR"
for svc in "${SERVICES[@]}"; do
  aws ecr describe-images --repository-name "$ECR_PREFIX/$svc" \
    --query "imageDetails[].[repositoryName, join(',', imageTags), imagePushedAt]" --output text
done

log "DynamoDB $DYNAMODB_TABLE"
aws dynamodb scan --table-name "$DYNAMODB_TABLE" \
  --query 'Items[].{concert_id:concert_id.S,name:name.S,date:date.S,recinto:recinto.S,floor:capacity.M.floor.N,vip:capacity.M.vip.N,general:capacity.M.general.N}' \
  --output table

log "SQS $QUEUE_NAME"
aws sqs get-queue-attributes --queue-url "$(queue_url "$QUEUE_NAME")" \
  --attribute-names FifoQueue ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible --output table

log "RDS: reservaciones por concierto, tipo y estado"
./db-query.sh "SELECT concert_id, ticket_type, status, COUNT(*) AS reservaciones, SUM(quantity) AS boletos FROM reservations GROUP BY 1,2,3 ORDER BY 1,2,3"
