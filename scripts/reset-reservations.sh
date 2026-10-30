#!/usr/bin/env bash
# Borra las reservaciones de un concierto para repetir una prueba desde cero.
# Uso: ./reset-reservations.sh bad-bunny-gdl     (sin argumento borra todas)
source "$(dirname "$0")/config.sh"

if [[ -n "${1:-}" ]]; then
  [[ "$1" =~ ^[A-Za-z0-9_-]+$ ]] || die "concert_id inválido: $1"
  log "Borrando reservaciones de $1"
  ./db-query.sh "DELETE FROM reservations WHERE concert_id = '$1'"
else
  log "Borrando TODAS las reservaciones"
  ./db-query.sh "TRUNCATE reservations"
fi
