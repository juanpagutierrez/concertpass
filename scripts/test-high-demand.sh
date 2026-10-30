#!/usr/bin/env bash
# Escenario de alta demanda: muchas reservaciones concurrentes para una sección con poca capacidad,
# procesadas por varias réplicas de ticket-worker. Verifica que NO haya sobreventa.
#
# Variables: CONCERT (bad-bunny-gdl), TICKET_TYPE (vip), REQUESTS (150), PARALLEL (25),
#            QUANTITY (1), WORKERS (3), RESET (0: si es 1 borra antes las reservaciones del concierto),
#            API_URL (autodetectada).
source "$(dirname "$0")/config.sh"
require_cmd curl jq aws xargs

CONCERT="${CONCERT:-bad-bunny-gdl}"
TICKET_TYPE="${TICKET_TYPE:-vip}"
REQUESTS="${REQUESTS:-150}"
PARALLEL="${PARALLEL:-25}"
QUANTITY="${QUANTITY:-1}"
WORKERS="${WORKERS:-3}"
RESET="${RESET:-0}"
API=$(api_url)
K8S=0; have_k8s && K8S=1

capacity=$(concert_capacity "$CONCERT" "$TICKET_TYPE")
[[ "$capacity" =~ ^[0-9]+$ ]] || die "No existe $CONCERT/$TICKET_TYPE en DynamoDB"

if ((K8S)); then
  if ((RESET)); then ./reset-reservations.sh "$CONCERT"; fi
  log "Escalando ticket-worker a $WORKERS réplicas"
  kubectl -n "$K8S_NAMESPACE" scale deployment ticket-worker --replicas="$WORKERS"
  kubectl -n "$K8S_NAMESPACE" rollout status deployment ticket-worker --timeout=180s
  kubectl -n "$K8S_NAMESPACE" get pods -l app=ticket-worker
fi

summary() { curl -fsS "$API/concerts/$CONCERT/summary"; }
tickets() { jq -r --arg t "$TICKET_TYPE" --arg s "$1" '.by_ticket_type[$t][$s].tickets // 0'; }

sold_before=$(( $(summary | tickets booked) + $(summary | tickets confirmed) ))
if ((sold_before > 0)); then
  warn "Ya había $sold_before boletos $TICKET_TYPE vendidos de corridas anteriores (usa RESET=1 para empezar de cero)"
fi

log "Enviando $REQUESTS reservaciones de $QUANTITY boleto(s) $TICKET_TYPE para $CONCERT (capacidad $capacity, $PARALLEL en paralelo)"
ids_file="$TMP_DIR/high-demand-ids.txt"
: > "$ids_file"
export API CONCERT TICKET_TYPE QUANTITY
reserve_one() {
  curl -sS -m 30 -X POST "$API/reserve" -H 'Content-Type: application/json' \
    -d "{\"concert_id\":\"$CONCERT\",\"user_id\":\"usr_load_$1\",\"ticket_type\":\"$TICKET_TYPE\",\"quantity\":$QUANTITY}" \
    | grep -o '"reservation_id":"[^"]*"' | cut -d'"' -f4
}
export -f reserve_one
t0=$SECONDS
seq 1 "$REQUESTS" | xargs -P "$PARALLEL" -I{} bash -c 'reserve_one {}' >> "$ids_file"
accepted=$(grep -c . "$ids_file" || true)
ok "$accepted de $REQUESTS aceptadas por ticket-api en $((SECONDS - t0)) s"

log "Esperando a que los workers procesen la cola"
for _ in $(seq 1 180); do
  s=$(summary)
  p=$(tickets pending <<<"$s"); b=$(tickets booked <<<"$s")
  c=$(tickets confirmed <<<"$s"); r=$(tickets rejected <<<"$s")
  printf '\r  boletos -> pending: %-5s booked: %-5s confirmed: %-5s rejected: %-5s' "$p" "$b" "$c" "$r"
  ((p == 0 && b == 0)) && break
  sleep 2
done
echo

log "Resultado"
summary | jq .
confirmed=$(summary | tickets confirmed)
rejected=$(summary | tickets rejected)
requested=$((sold_before + accepted * QUANTITY))
echo "  capacidad $TICKET_TYPE:  $capacity"
echo "  confirmados:       $confirmed"
echo "  rechazados:        $rejected"

if ((K8S)); then
  log "Reservaciones rechazadas en RDS (muestra)"
  ./db-query.sh "SELECT reservation_id, user_id, ticket_type, quantity, status, updated_at FROM reservations WHERE concert_id = '$CONCERT' AND status = 'rejected' ORDER BY updated_at LIMIT 10"
  log "Totales en RDS"
  ./db-query.sh "SELECT ticket_type, status, COUNT(*) AS reservaciones, SUM(quantity) AS boletos FROM reservations WHERE concert_id = '$CONCERT' GROUP BY 1,2 ORDER BY 1,2"
  log "Mensajes procesados por cada réplica de ticket-worker"
  for pod in $(kubectl -n "$K8S_NAMESPACE" get pods -l app=ticket-worker -o name); do
    n=$(kubectl -n "$K8S_NAMESPACE" logs "$pod" --since=10m | grep -cE ' -> (booked|rejected)' || true)
    echo "  $pod: $n reservaciones decididas"
  done
fi

if ((confirmed > capacity)); then
  fail "SOBREVENTA: $confirmed confirmados > capacidad $capacity"
  exit 1
elif ((requested <= capacity && confirmed != requested)); then
  fail "Había espacio para todos: se esperaban $requested confirmados y hay $confirmed"
  exit 1
elif ((requested > capacity && confirmed <= capacity - QUANTITY)); then
  fail "Se rechazaron reservaciones aunque quedaba espacio ($confirmed/$capacity vendidos)"
  exit 1
fi
ok "Sin sobreventa: $confirmed/$capacity boletos vendidos, el resto quedó rejected"
