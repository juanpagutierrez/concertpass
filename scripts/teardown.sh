#!/usr/bin/env bash
# Destruye TODOS los recursos creados por setup.sh y al final verifica que ya no existen.
# Orden: Kubernetes -> RDS (y su SG/subnet group, deben irse antes de que eksctl borre la VPC)
#        -> Secrets Manager -> SQS -> DynamoDB -> ECR -> cluster EKS.
source "$(dirname "$0")/config.sh"
set +e  # seguir aunque algún recurso ya no exista
require_cmd aws eksctl kubectl

if cluster_exists; then
  log "Borrando namespace $K8S_NAMESPACE"
  aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$AWS_REGION" >/dev/null
  kubectl delete namespace "$K8S_NAMESPACE" --ignore-not-found --wait=true --timeout=180s
fi

log "Borrando RDS $DB_INSTANCE_ID (tarda ~5-10 min)"
if aws rds describe-db-instances --db-instance-identifier "$DB_INSTANCE_ID" >/dev/null 2>&1; then
  aws rds delete-db-instance --db-instance-identifier "$DB_INSTANCE_ID" \
    --skip-final-snapshot --delete-automated-backups >/dev/null
  aws rds wait db-instance-deleted --db-instance-identifier "$DB_INSTANCE_ID"
fi
aws rds delete-db-subnet-group --db-subnet-group-name "$DB_SUBNET_GROUP" 2>/dev/null
for sg in $(aws ec2 describe-security-groups --filters "Name=group-name,Values=$DB_SECURITY_GROUP" \
              --query 'SecurityGroups[].GroupId' --output text); do
  aws ec2 delete-security-group --group-id "$sg"
done

log "Borrando secreto $SECRET_NAME"
aws secretsmanager delete-secret --secret-id "$SECRET_NAME" --force-delete-without-recovery >/dev/null 2>&1

log "Borrando colas SQS"
for q in "$QUEUE_NAME" "$DLQ_NAME"; do
  url=$(aws sqs get-queue-url --queue-name "$q" --query QueueUrl --output text 2>/dev/null)
  [[ -n "$url" ]] && aws sqs delete-queue --queue-url "$url"
done

log "Borrando tabla DynamoDB $DYNAMODB_TABLE"
if aws dynamodb delete-table --table-name "$DYNAMODB_TABLE" >/dev/null 2>&1; then
  aws dynamodb wait table-not-exists --table-name "$DYNAMODB_TABLE"
fi

log "Borrando repositorios ECR"
for svc in "${SERVICES[@]}"; do
  aws ecr delete-repository --repository-name "$ECR_PREFIX/$svc" --force >/dev/null 2>&1
done

log "Borrando cluster EKS $CLUSTER_NAME (tarda ~10-15 min)"
if cluster_exists; then
  eksctl delete cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" --wait
fi

log "Verificación: recursos restantes"
check() {  # check <descripción> <comando que imprime algo si el recurso todavía existe>
  local out
  out=$(eval "$2" 2>/dev/null)
  if [[ -z "$out" || "$out" == "None" ]]; then ok "$1 eliminado"; else fail "$1 TODAVÍA EXISTE: $out"; leftovers=1; fi
}
leftovers=0
check "Cluster EKS $CLUSTER_NAME" "aws eks list-clusters --query \"clusters[?@=='$CLUSTER_NAME']\" --output text"
check "RDS $DB_INSTANCE_ID" "aws rds describe-db-instances --query \"DBInstances[?DBInstanceIdentifier=='$DB_INSTANCE_ID'].DBInstanceStatus\" --output text"
check "DB subnet group" "aws rds describe-db-subnet-groups --query \"DBSubnetGroups[?DBSubnetGroupName=='$DB_SUBNET_GROUP'].DBSubnetGroupName\" --output text"
check "Secreto $SECRET_NAME" "aws secretsmanager list-secrets --query \"SecretList[?Name=='$SECRET_NAME'].Name\" --output text"
check "Colas SQS concertpass-*" "aws sqs list-queues --queue-name-prefix concertpass --query QueueUrls --output text"
check "Tabla DynamoDB $DYNAMODB_TABLE" "aws dynamodb list-tables --query \"TableNames[?@=='$DYNAMODB_TABLE']\" --output text"
check "Repositorios ECR $ECR_PREFIX/*" "aws ecr describe-repositories --query \"repositories[?starts_with(repositoryName,'$ECR_PREFIX/')].repositoryName\" --output text"

if ((leftovers)); then
  fail "Quedaron recursos (ver arriba). Algunos tardan unos segundos en desaparecer; vuelve a correr ./teardown.sh"
  exit 1
fi
ok "Todos los recursos de Concertpass fueron eliminados"
