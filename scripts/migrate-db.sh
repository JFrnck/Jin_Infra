#!/usr/bin/env bash
# Aplica las migraciones de DB de jin-core con la MISMA imagen que corre el
# Deployment jin-core. Idempotente: drizzle solo aplica lo que falta, así que
# es seguro re-correrlo (bootstrap, o antes de cada release con migraciones).
#
# Requiere: Postgres arriba y el Secret jin-core-secrets (02-seed-secrets.sh).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAMESPACE="${NAMESPACE:-jin}"
TIMEOUT="${MIGRATE_TIMEOUT:-300s}"

CORE_IMAGE="$(kubectl -n "${NAMESPACE}" get deployment jin-core \
  -o jsonpath='{.spec.template.spec.containers[0].image}')"
if [[ -z "${CORE_IMAGE}" ]]; then
  echo "!! No se pudo leer la imagen del Deployment jin-core." >&2
  exit 1
fi

echo ">> Migrando DB con la imagen ${CORE_IMAGE}"
# Los Jobs son inmutables: se borra el anterior (si existe) antes de crear.
kubectl -n "${NAMESPACE}" delete job jin-core-migrate --ignore-not-found --wait=true
sed "s|__JIN_CORE_IMAGE__|${CORE_IMAGE}|" "${REPO_ROOT}/k8s/jobs/jin-core-migrate.yaml" \
  | kubectl apply -f -

if ! kubectl -n "${NAMESPACE}" wait --for=condition=complete job/jin-core-migrate --timeout="${TIMEOUT}"; then
  echo "!! La migración no completó. Logs:" >&2
  kubectl -n "${NAMESPACE}" logs job/jin-core-migrate --all-containers --tail=100 >&2 || true
  exit 1
fi

echo ">> Migraciones aplicadas:"
kubectl -n "${NAMESPACE}" logs job/jin-core-migrate --tail=5
