#!/usr/bin/env bash
# Crea los Secrets semilla que existen ANTES de que Infisical esté operativo
# (huevo-gallina: Infisical corre dentro del clúster). Todo secreto posterior
# vive en Infisical (AGENTS.md 5.2). Idempotente: re-ejecutable sin drama.
#
# Variables de entorno requeridas (NUNCA se logean sus valores):
#   POSTGRES_PASSWORD          password del usuario jin de Postgres
#   REDIS_PASSWORD             requirepass de Redis
#   INFISICAL_ENCRYPTION_KEY   hex de 16 bytes:  openssl rand -hex 16
#   INFISICAL_AUTH_SECRET      base64 de 32 bytes: openssl rand -base64 32
#   CLOUDFLARE_API_TOKEN       token con Zone.DNS Edit en ambas zonas
#   CLOUDFLARED_TUNNEL_TOKEN   token del túnel (Zero Trust → Tunnels)
#   GRAFANA_ADMIN_PASSWORD     password admin de Grafana
#   AGE_PUBLIC_KEY             `age-keygen` — cifra los backups (no sensible)
#   AGE_PRIVATE_KEY            `age-keygen` — descifra en verify-restore
#   R2_ACCOUNT_ID              ID de cuenta de Cloudflare (para el endpoint R2)
#   R2_ACCESS_KEY_ID           API token de R2 (scoped al bucket de backups)
#   R2_SECRET_ACCESS_KEY       secret del API token de R2
#   GHCR_USERNAME              usuario de GitHub (pull de imágenes privadas)
#   GHCR_PAT                   PAT con scope read:packages
#
# jin-core/jin-executor: solo DATABASE_URL/REDIS_URL siguen acá (mismo
# huevo-gallina de infra). Las 13 claves reales de Core y las 2 de
# Executor migraron a Infisical en Fase 8.1 -- ver
# scripts/bootstrap/08-seed-infisical-app-secrets.sh, que corre después
# de este (Infisical recién existe tras 04-apply-manifests.sh).
#
# Opcional:
#   R2_BUCKET                  default "jin-backups" (BLUEPRINT 3.6)
set -euo pipefail

: "${R2_BUCKET:=jin-backups}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

required_vars=(
  POSTGRES_PASSWORD
  REDIS_PASSWORD
  INFISICAL_ENCRYPTION_KEY
  INFISICAL_AUTH_SECRET
  CLOUDFLARE_API_TOKEN
  CLOUDFLARED_TUNNEL_TOKEN
  GRAFANA_ADMIN_PASSWORD
  AGE_PUBLIC_KEY
  AGE_PRIVATE_KEY
  R2_ACCOUNT_ID
  R2_ACCESS_KEY_ID
  R2_SECRET_ACCESS_KEY
  GHCR_USERNAME
  GHCR_PAT
)
missing=0
for var in "${required_vars[@]}"; do
  if [[ -z "${!var:-}" ]]; then
    echo "ERROR: falta la variable de entorno ${var}" >&2
    missing=1
  fi
done
[[ "${missing}" -eq 1 ]] && exit 1

echo ">> Aplicando namespaces..."
kubectl apply -k "${REPO_ROOT}/k8s/base/namespaces"
kubectl create namespace cert-manager --dry-run=client -o yaml | kubectl apply -f -

# apply_secret <namespace> <nombre> <key=value>...
apply_secret() {
  local ns="$1" name="$2"
  shift 2
  local args=()
  local pair
  for pair in "$@"; do
    args+=("--from-literal=${pair}")
  done
  kubectl -n "${ns}" create secret generic "${name}" "${args[@]}" \
    --dry-run=client -o yaml | kubectl apply -f -
  echo "   Secret ${ns}/${name} aplicado."
}

# apply_ghcr_pull_secret <namespace>
apply_ghcr_pull_secret() {
  local ns="$1"
  kubectl -n "${ns}" create secret docker-registry ghcr-pull-secret \
    --docker-server=ghcr.io \
    --docker-username="${GHCR_USERNAME}" \
    --docker-password="${GHCR_PAT}" \
    --dry-run=client -o yaml | kubectl apply -f -
  echo "   Secret ${ns}/ghcr-pull-secret aplicado."
}

echo ">> Creando Secrets semilla..."
apply_secret jin postgres-credentials \
  "password=${POSTGRES_PASSWORD}"

apply_secret jin redis-credentials \
  "password=${REDIS_PASSWORD}"

apply_secret jin infisical-secrets \
  "ENCRYPTION_KEY=${INFISICAL_ENCRYPTION_KEY}" \
  "AUTH_SECRET=${INFISICAL_AUTH_SECRET}" \
  "DB_CONNECTION_URI=postgres://jin:${POSTGRES_PASSWORD}@postgres.jin.svc.cluster.local:5432/infisical?sslmode=disable" \
  "REDIS_URL=redis://:${REDIS_PASSWORD}@redis.jin.svc.cluster.local:6379"

apply_secret jin cloudflared-token \
  "token=${CLOUDFLARED_TUNNEL_TOKEN}"

apply_secret cert-manager cloudflare-api-token \
  "api-token=${CLOUDFLARE_API_TOKEN}"

apply_secret observability grafana-admin \
  "user=admin" \
  "password=${GRAFANA_ADMIN_PASSWORD}"

apply_secret jin age-backup-key \
  "public-key=${AGE_PUBLIC_KEY}" \
  "private-key=${AGE_PRIVATE_KEY}"

apply_secret jin r2-credentials \
  "account-id=${R2_ACCOUNT_ID}" \
  "access-key-id=${R2_ACCESS_KEY_ID}" \
  "secret-access-key=${R2_SECRET_ACCESS_KEY}" \
  "bucket=${R2_BUCKET}"

# jin-core: solo DATABASE_URL/REDIS_URL (huevo-gallina de infra). Las 13
# claves reales migraron a Infisical en Fase 8.1 -- ver
# 08-seed-infisical-app-secrets.sh, que corre después de este (una vez
# que Infisical esté operativo). jin-executor-secrets se eliminó por
# completo: sus 2 valores (Modal) migraron también.
apply_secret jin jin-core-secrets \
  "DATABASE_URL=postgres://jin:${POSTGRES_PASSWORD}@postgres.jin.svc.cluster.local:5432/jin" \
  "REDIS_URL=redis://:${REDIS_PASSWORD}@redis.jin.svc.cluster.local:6379"

apply_ghcr_pull_secret jin
apply_ghcr_pull_secret jin-executor

echo ">> Listo. Guarda las credenciales en tu llavero (Bitwarden/1Password)."
echo ">> Recuerda: rotación trimestral obligatoria (BLUEPRINT 11)."
