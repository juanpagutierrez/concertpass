#!/usr/bin/env bash
# Crea la tabla de eventos en DynamoDB y precarga los conciertos de data/concerts/.
source "$(dirname "$0")/config.sh"
require_cmd aws

if aws dynamodb describe-table --table-name "$DYNAMODB_TABLE" >/dev/null 2>&1; then
  ok "La tabla $DYNAMODB_TABLE ya existe"
else
  log "Creando tabla DynamoDB $DYNAMODB_TABLE (llave: concert_id)"
  aws dynamodb create-table \
    --table-name "$DYNAMODB_TABLE" \
    --attribute-definitions AttributeName=concert_id,AttributeType=S \
    --key-schema AttributeName=concert_id,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST >/dev/null
  aws dynamodb wait table-exists --table-name "$DYNAMODB_TABLE"
  ok "Tabla creada"
fi

log "Precargando conciertos"
for f in data/concerts/*.json; do
  aws dynamodb put-item --table-name "$DYNAMODB_TABLE" --item "file://$f"
  ok "$(basename "$f" .json)"
done

aws dynamodb scan --table-name "$DYNAMODB_TABLE" \
  --query 'Items[].{concert_id:concert_id.S,name:name.S,date:date.S,floor:capacity.M.floor.N,vip:capacity.M.vip.N,general:capacity.M.general.N}' \
  --output table
