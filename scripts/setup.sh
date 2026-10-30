#!/usr/bin/env bash
# Levanta toda la infraestructura de Concertpass y despliega los servicios.
# Orden: DynamoDB y SQS (rápidos) -> cluster EKS -> RDS en la VPC del cluster -> ECR -> Kubernetes.
# Cada paso es idempotente: si algo falla se puede volver a correr setup.sh.
# Para destruir todo: ./teardown.sh
source "$(dirname "$0")/config.sh"
require_cmd aws eksctl kubectl docker jq envsubst curl

start=$SECONDS
log "Cuenta AWS $(account_id), región $AWS_REGION"

./create-dynamodb.sh
./create-sqs.sh
./create-cluster.sh
./create-rds.sh
./create-ecr.sh
./deploy-k8s.sh

log "Listo en $(( (SECONDS - start) / 60 )) min. Siguiente paso:"
echo "  ./test-low-demand.sh    # escenario de nicho"
echo "  ./test-high-demand.sh   # escenario de alta demanda con 3 workers"
echo "  ./teardown.sh           # destruir todo al terminar (EKS cuesta dinero)"
