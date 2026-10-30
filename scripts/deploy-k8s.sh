#!/usr/bin/env bash
# Crea el Secret (desde Secrets Manager) y la ConfigMap, y despliega los 3 servicios en el cluster.
source "$(dirname "$0")/config.sh"
require_cmd aws kubectl jq envsubst curl

export ECR_REGISTRY SQS_QUEUE_URL
ECR_REGISTRY=$(ecr_registry)
SQS_QUEUE_URL=$(queue_url "$QUEUE_NAME")
SUBST_VARS='${AWS_REGION} ${SQS_QUEUE_URL} ${DYNAMODB_TABLE} ${ECR_REGISTRY} ${IMAGE_TAG} ${NODE_PORT}'

apply() { envsubst "$SUBST_VARS" < "../k8s/$1" | kubectl apply -f -; }

aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$AWS_REGION" >/dev/null

log "Namespace y ConfigMap"
apply namespace.yaml
apply configmap.yaml

log "Secret rds-credentials (leído de AWS Secrets Manager: $SECRET_NAME)"
secret=$(aws secretsmanager get-secret-value --secret-id "$SECRET_NAME" --query SecretString --output text)
kubectl -n "$K8S_NAMESPACE" create secret generic rds-credentials \
  --from-literal=DB_HOST="$(jq -r .host <<<"$secret")" \
  --from-literal=DB_PORT="$(jq -r .port <<<"$secret")" \
  --from-literal=DB_NAME="$(jq -r .dbname <<<"$secret")" \
  --from-literal=DB_USER="$(jq -r .username <<<"$secret")" \
  --from-literal=DB_PASSWORD="$(jq -r .password <<<"$secret")" \
  --dry-run=client -o yaml | kubectl apply -f -

log "Deployments y Services"
for f in ticket-checkout-deployment.yaml ticket-checkout-service.yaml \
         ticket-api-deployment.yaml ticket-api-service.yaml \
         ticket-worker-deployment.yaml; do
  apply "$f"
done

# Fuerza a que los pods tomen la imagen y el secreto más recientes aunque el manifiesto no cambie.
kubectl -n "$K8S_NAMESPACE" rollout restart deployment ticket-checkout ticket-api ticket-worker
for d in ticket-checkout ticket-api ticket-worker; do
  kubectl -n "$K8S_NAMESPACE" rollout status deployment "$d" --timeout=300s
done

log "Abriendo el NodePort $NODE_PORT a tu IP pública"
# HTTP simple: en Git Bash (schannel) el HTTPS puede fallar al revisar revocación de certificados.
my_ip=$(curl -fsS http://checkip.amazonaws.com | tr -d '[:space:]')
node_sgs=$(aws ec2 describe-instances \
  --filters "Name=tag:eks:cluster-name,Values=$CLUSTER_NAME" "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].SecurityGroups[].GroupId' --output text | tr '\t' '\n' | sort -u)
for sg in $node_sgs; do
  if aws ec2 authorize-security-group-ingress --group-id "$sg" --protocol tcp \
       --port "$NODE_PORT" --cidr "$my_ip/32" >/dev/null 2>&1; then
    ok "$sg: $NODE_PORT abierto a $my_ip/32"
  else
    ok "$sg: la regla ya existía"
  fi
done

log "Estado del cluster"
kubectl get nodes
kubectl -n "$K8S_NAMESPACE" get pods,services -o wide

url=$(api_url)
log "ticket-api disponible en $url"
curl -fsS --retry 5 --retry-delay 3 --retry-all-errors "$url/health" && echo
