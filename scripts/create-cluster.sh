#!/usr/bin/env bash
# Crea el cluster de EKS con 2 nodos worker y configura kubectl.
source "$(dirname "$0")/config.sh"
require_cmd aws eksctl kubectl envsubst

if cluster_exists; then
  ok "El cluster $CLUSTER_NAME ya existe"
else
  log "Creando cluster EKS $CLUSTER_NAME en $AWS_REGION (tarda ~15-20 min)"
  export CLUSTER_NAME NODE_TYPE QUEUE_NAME AWS_ACCOUNT_ID LAB_ROLE_ARN
  AWS_ACCOUNT_ID=$(account_id)
  # En AWS Academy no se pueden crear roles: si existe LabRole se usa para el cluster y los nodos.
  LAB_ROLE_ARN="${LAB_ROLE_ARN:-$(aws iam get-role --role-name LabRole --query Role.Arn --output text 2>/dev/null || true)}"
  if [[ -n "$LAB_ROLE_ARN" ]]; then
    ok "Usando $LAB_ROLE_ARN (AWS Academy)"
    template=eksctl-cluster-labrole.yaml
  else
    template=eksctl-cluster.yaml
  fi
  envsubst '${CLUSTER_NAME} ${AWS_REGION} ${NODE_TYPE} ${AWS_ACCOUNT_ID} ${QUEUE_NAME} ${DYNAMODB_TABLE} ${LAB_ROLE_ARN}' \
    < "$template" | eksctl create cluster -f -
fi

log "Configurando kubeconfig"
aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$AWS_REGION"

log "Esperando a que los nodos estén Ready"
kubectl wait --for=condition=Ready nodes --all --timeout=300s
kubectl get nodes -o wide
