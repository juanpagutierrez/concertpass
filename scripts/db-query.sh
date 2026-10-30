#!/usr/bin/env bash
# Ejecuta una consulta SQL en RDS desde un pod temporal dentro del cluster (RDS no es público).
# Uso: ./db-query.sh "SELECT status, COUNT(*) FROM reservations GROUP BY status"
source "$(dirname "$0")/config.sh"
require_cmd kubectl jq

sql="${1:-SELECT status, COUNT(*) AS reservaciones, SUM(quantity) AS boletos FROM reservations GROUP BY status ORDER BY status}"

# El pod toma las credenciales del Secret rds-credentials (que viene de Secrets Manager).
overrides=$(jq -cn --arg sql "$sql" '{
  spec: {
    containers: [{
      name: "psql",
      image: "postgres:16-alpine",
      stdin: true,
      command: ["sh", "-c", "PGPASSWORD=\"$DB_PASSWORD\" psql \"host=$DB_HOST port=$DB_PORT dbname=$DB_NAME user=$DB_USER sslmode=require\" -v ON_ERROR_STOP=1 -c \"$SQL\""],
      env: [{name: "SQL", value: $sql}],
      envFrom: [{secretRef: {name: "rds-credentials"}}]
    }]
  }
}')

kubectl -n "$K8S_NAMESPACE" run "psql-client-$RANDOM" --rm -i --quiet --restart=Never \
  --image=postgres:16-alpine --overrides="$overrides"
