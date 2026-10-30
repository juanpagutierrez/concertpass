#!/usr/bin/env bash
# Crea los repositorios de ECR, construye las 3 imágenes y las publica.
source "$(dirname "$0")/config.sh"
require_cmd aws docker

REGISTRY=$(ecr_registry)

log "Repositorios ECR"
for svc in "${SERVICES[@]}"; do
  repo="$ECR_PREFIX/$svc"
  if aws ecr describe-repositories --repository-names "$repo" >/dev/null 2>&1; then
    ok "$repo ya existe"
  else
    aws ecr create-repository --repository-name "$repo" \
      --image-scanning-configuration scanOnPush=true >/dev/null
    ok "$repo creado"
  fi
done

log "Login de Docker en $REGISTRY"
aws ecr get-login-password | docker login --username AWS --password-stdin "$REGISTRY"

for svc in "${SERVICES[@]}"; do
  image="$REGISTRY/$ECR_PREFIX/$svc:$IMAGE_TAG"
  log "Build y push de $image"
  # Los nodos de EKS son x86_64; se fuerza la plataforma por si se construye desde una Mac ARM.
  # --provenance=false: sin manifiestos de attestation, ECR muestra solo la imagen con su tag.
  docker build --platform linux/amd64 --provenance=false -t "$image" "../$svc"
  docker push "$image"
done

log "Imágenes publicadas"
for svc in "${SERVICES[@]}"; do
  aws ecr describe-images --repository-name "$ECR_PREFIX/$svc" \
    --query 'imageDetails[?imageTags].{repo:repositoryName,tags:join(`,`,imageTags),pushed:imagePushedAt}' --output table
done
