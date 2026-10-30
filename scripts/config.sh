#!/usr/bin/env bash
# Configuración compartida por todos los scripts. Cualquier valor se puede sobrescribir con una
# variable de entorno antes de correr el script, p. ej.  AWS_REGION=us-west-2 ./setup.sh
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPTS_DIR")"
# Todos los scripts trabajan desde scripts/ y usan rutas relativas (funciona igual en Linux,
# macOS y Git Bash en Windows, donde aws.exe/docker.exe no entienden rutas tipo /c/Users/...).
cd "$SCRIPTS_DIR"

export AWS_REGION="${AWS_REGION:-us-east-1}"
export AWS_DEFAULT_REGION="$AWS_REGION"
export AWS_PAGER=""

CLUSTER_NAME="${CLUSTER_NAME:-concertpass}"
NODE_TYPE="${NODE_TYPE:-t3.medium}"
K8S_NAMESPACE="concertpass"
export NODE_PORT="${NODE_PORT:-30080}"

QUEUE_NAME="${QUEUE_NAME:-concertpass-reservations.fifo}"
DLQ_NAME="${DLQ_NAME:-concertpass-reservations-dlq.fifo}"
export DYNAMODB_TABLE="${DYNAMODB_TABLE:-concertpass-events}"

DB_INSTANCE_ID="${DB_INSTANCE_ID:-concertpass-db}"
DB_INSTANCE_CLASS="${DB_INSTANCE_CLASS:-db.t3.micro}"
DB_NAME="${DB_NAME:-concertpass}"
DB_USER="${DB_USER:-concertpass}"
DB_SUBNET_GROUP="concertpass-db-subnets"
DB_SECURITY_GROUP="concertpass-db-sg"
SECRET_NAME="${SECRET_NAME:-concertpass/rds-credentials}"

ECR_PREFIX="concertpass"
SERVICES=(ticket-api ticket-worker ticket-checkout)
export IMAGE_TAG="${IMAGE_TAG:-v1}"

TMP_DIR="$SCRIPTS_DIR/.tmp"
mkdir -p "$TMP_DIR"

# En Git Bash (Windows) aws.exe y jq.exe imprimen \r\n; se limpia para no ensuciar las variables.
if [[ "${OSTYPE:-}" == msys* || "${OSTYPE:-}" == cygwin* ]]; then
  aws() { command aws "$@" | tr -d '\r'; }
  jq() { command jq "$@" | tr -d '\r'; }
fi

log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m  ✔ %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m  ! %s\033[0m\n' "$*"; }
fail() { printf '\033[1;31m  ✘ %s\033[0m\n' "$*"; }
die()  { fail "$*"; exit 1; }

require_cmd() {
  local missing=()
  for c in "$@"; do command -v "$c" >/dev/null 2>&1 || missing+=("$c"); done
  ((${#missing[@]} == 0)) || die "Faltan comandos: ${missing[*]} (ver README, sección Requisitos)"
}

account_id()   { aws sts get-caller-identity --query Account --output text; }
ecr_registry() { echo "$(account_id).dkr.ecr.${AWS_REGION}.amazonaws.com"; }
queue_url()    { aws sqs get-queue-url --queue-name "$1" --query QueueUrl --output text; }
cluster_exists() { aws eks describe-cluster --name "$CLUSTER_NAME" >/dev/null 2>&1; }

# URL pública de ticket-api: IP externa de un nodo + NodePort. Se puede forzar con API_URL=...
api_url() {
  if [[ -n "${API_URL:-}" ]]; then echo "${API_URL%/}"; return; fi
  local ip
  ip=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="ExternalIP")].address}')
  [[ -n "$ip" ]] || die "No se encontró la IP externa de los nodos; define API_URL manualmente"
  echo "http://${ip}:${NODE_PORT}"
}

# Capacidad de una sección según DynamoDB.
concert_capacity() {
  aws dynamodb get-item --table-name "$DYNAMODB_TABLE" --key "{\"concert_id\":{\"S\":\"$1\"}}" \
    --query "Item.capacity.M.$2.N" --output text
}

# kubectl está disponible y apunta al cluster (en pruebas locales con API_URL no lo está).
have_k8s() { command -v kubectl >/dev/null 2>&1 && kubectl -n "$K8S_NAMESPACE" get deploy ticket-worker >/dev/null 2>&1; }
