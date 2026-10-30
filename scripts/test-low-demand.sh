#!/usr/bin/env bash
# Escenario de nicho: pocas reservaciones en un concierto con poca demanda. Todas se confirman.
#
# Si hay acceso al cluster, primero pausa ticket-worker (0 réplicas) para mostrar que las
# reservaciones quedan pending y los mensajes llegan a SQS; después lo reanuda.
# Variables: CONCERT (jazz-nicho-cdmx), PAUSE_WORKER (1), API_URL (autodetectada).
source "$(dirname "$0")/config.sh"
require_cmd curl jq aws

CONCERT="${CONCERT:-jazz-nicho-cdmx}"
PAUSE_WORKER="${PAUSE_WORKER:-1}"
API=$(api_url)
K8S=0; have_k8s && K8S=1

# user_id ticket_type quantity
REQUESTS=(
  "usr_101 floor 2"
  "usr_102 vip 1"
  "usr_103 general 3"
  "usr_104 floor 1"
)

log "Concierto en DynamoDB"
aws dynamodb get-item --table-name "$DYNAMODB_TABLE" --key "{\"concert_id\":{\"S\":\"$CONCERT\"}}" --output json \
  | jq '.Item | {concert_id: .concert_id.S, name: .name.S, date: .date.S, recinto: .recinto.S,
                 capacity: (.capacity.M | map_values(.N | tonumber))}'

if ((K8S && PAUSE_WORKER)); then
  log "Pausando ticket-worker para ver los mensajes en SQS"
  trap 'kubectl -n "$K8S_NAMESPACE" scale deployment ticket-worker --replicas=1 >/dev/null' EXIT
  kubectl -n "$K8S_NAMESPACE" scale deployment ticket-worker --replicas=0
  kubectl -n "$K8S_NAMESPACE" wait --for=delete pod -l app=ticket-worker --timeout=90s 2>/dev/null || true
fi

log "Enviando ${#REQUESTS[@]} reservaciones a $API/reserve"
ids=()
for r in "${REQUESTS[@]}"; do
  read -r user type qty <<<"$r"
  body=$(jq -cn --arg c "$CONCERT" --arg u "$user" --arg t "$type" --argjson q "$qty" \
    '{concert_id:$c, user_id:$u, ticket_type:$t, quantity:$q}')
  resp=$(curl -fsS -X POST "$API/reserve" -H 'Content-Type: application/json' -d "$body")
  echo "  POST $body -> $resp"
  ids+=("$(jq -r .reservation_id <<<"$resp")")
done

if ((K8S && PAUSE_WORKER)); then
  log "Mensajes en SQS FIFO (worker pausado)"
  sleep 2
  aws sqs get-queue-attributes --queue-url "$(queue_url "$QUEUE_NAME")" \
    --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible --output table
  log "Estado mientras el worker está pausado"
  for id in "${ids[@]}"; do curl -fsS "$API/reservation/$id" | jq -c '{reservation_id, status}'; done

  log "Reanudando ticket-worker"
  kubectl -n "$K8S_NAMESPACE" scale deployment ticket-worker --replicas=1
  trap - EXIT
fi

log "Esperando el estado final de cada reservación"
for id in "${ids[@]}"; do
  for _ in $(seq 1 60); do
    st=$(curl -fsS "$API/reservation/$id" | jq -r .status)
    [[ "$st" == "confirmed" || "$st" == "rejected" ]] && break
    sleep 1
  done
done
printf '\n  %-38s %-9s %-8s %-4s %s\n' RESERVATION_ID USER TYPE QTY STATUS
for id in "${ids[@]}"; do
  curl -fsS "$API/reservation/$id" \
    | jq -r '"  \(.reservation_id)   \(.user_id)   \(.ticket_type | .[0:8])\t\(.quantity)    \(.status)"'
done

log "Resumen del concierto (GET /concerts/$CONCERT/summary)"
curl -fsS "$API/concerts/$CONCERT/summary" | jq .

if ((K8S)); then
  log "Reservaciones en RDS"
  ./db-query.sh "SELECT reservation_id, user_id, ticket_type, quantity, status, created_at, updated_at FROM reservations WHERE concert_id = '$CONCERT' ORDER BY created_at DESC LIMIT 20"
fi

confirmed=0
for id in "${ids[@]}"; do [[ $(curl -fsS "$API/reservation/$id" | jq -r .status) == confirmed ]] && confirmed=$((confirmed + 1)); done
if ((confirmed == ${#ids[@]})); then
  ok "Las ${#ids[@]} reservaciones quedaron confirmed"
else
  fail "Solo $confirmed de ${#ids[@]} quedaron confirmed"
  exit 1
fi
