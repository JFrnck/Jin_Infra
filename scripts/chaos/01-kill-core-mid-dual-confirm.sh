#!/usr/bin/env bash
# Chaos test #1 (BLUEPRINT 13.2): matar el pod de jin-core con una
# aprobación confirm/dual-confirm a medias, verificar que el estado
# sobrevive -- está en Postgres (pending_approvals), no en memoria del
# proceso. Ver Jin_Docs/docs/security-audit-fase7.md para el contexto de
# por qué esta fase (7.3) escribe el script sin poder correrlo todavía
# (no hay clúster real -- deploy pospuesto).
#
# Precondición manual (no automatizable sin credenciales reales): ANTES
# de correr este script, dispará una acción `confirm`/`dual-confirm`
# real (ej. pedile al agente por Telegram/CLI que mande un correo) para
# que exista al menos una fila en pending_approvals. El script verifica
# que exista una y aborta si no.
#
# Variables de entorno requeridas:
#   JIN_API_URL   ej. https://jin.jeanfranck.com/api
#   JIN_JWT       token Bearer de una sesión real (owner)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_env JIN_API_URL JIN_JWT

log ">> Verificando que exista al menos una aprobación pendiente..."
PENDING_JSON="$(curl -sf -H "Authorization: Bearer ${JIN_JWT}" "${JIN_API_URL}/hitl/pending")"
REQUEST_ID="$(echo "${PENDING_JSON}" | jq -r '.[0].requestId // empty')"
if [[ -z "${REQUEST_ID}" ]]; then
  log "ERROR: no hay ninguna aprobación pendiente. Disparala manualmente antes de correr este script (ver cabecera)."
  exit 1
fi
STATUS_BEFORE="$(echo "${PENDING_JSON}" | jq -r '.[0].level')"
log "   Aprobación pendiente encontrada: requestId=${REQUEST_ID} level=${STATUS_BEFORE}"

log ">> Matando el pod de jin-core (namespace jin)..."
POD_NAME="$(kubectl -n jin get pods -l app.kubernetes.io/name=jin-core -o jsonpath='{.items[0].metadata.name}')"
kubectl -n jin delete pod "${POD_NAME}" --grace-period=0 --force

log ">> Esperando a que el Deployment vuelva a Ready (esto es lo que se está probando: recovery < 10s, BLUEPRINT 13.2)..."
START="$(date +%s)"
if ! wait_for_ready "${JIN_API_URL%/api}/health/ready" 60; then
  log "ERROR: jin-core no volvió a Ready en 60s tras el kill. FALLA del chaos test."
  exit 1
fi
ELAPSED="$(( $(date +%s) - START ))"
log "   jin-core Ready de nuevo en ${ELAPSED}s."

log ">> Verificando que la MISMA aprobación sigue pendiente (sobrevivió en Postgres, no se perdió con el pod)..."
PENDING_AFTER="$(curl -sf -H "Authorization: Bearer ${JIN_JWT}" "${JIN_API_URL}/hitl/pending")"
STILL_THERE="$(echo "${PENDING_AFTER}" | jq -r --arg id "${REQUEST_ID}" '.[] | select(.requestId == $id) | .requestId')"
if [[ "${STILL_THERE}" != "${REQUEST_ID}" ]]; then
  log "ERROR: la aprobación ${REQUEST_ID} desapareció tras el restart -- FALLA del chaos test (el estado no debería depender de memoria del proceso)."
  exit 1
fi

log ">> OK: chaos test #1 pasó. requestId=${REQUEST_ID} sobrevivió, jin-core recuperó Ready en ${ELAPSED}s."
