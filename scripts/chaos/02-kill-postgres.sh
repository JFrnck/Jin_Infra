#!/usr/bin/env bash
# Chaos test #2 (BLUEPRINT 13.2): tirar el pod de Postgres, verificar
# que jin-core falla RUIDOSO (readinessProbe cae a NotReady, nunca sigue
# operando a medias sin DB) y que el audit log no queda corrupto al
# volver.
#
# LIMITACIÓN CONOCIDA, documentada a propósito: la verificación COMPLETA
# del hash chain (verifyChain(), todas las filas) corre vía @Cron a las
# 4am UTC dentro de jin-core (ChainVerificationService) -- no hay
# endpoint HTTP para dispararla a demanda. Este script hace un
# spot-check directo por SQL de las últimas filas (linkage
# prev_hash/current_hash), suficiente para detectar una corrupción
# introducida por el crash/restart mismo, pero NO reemplaza la
# verificación nocturna completa.
#
# Variables de entorno requeridas:
#   JIN_API_URL         ej. https://jin.jeanfranck.com/api (health check)
#   POSTGRES_PASSWORD   password del usuario jin de Postgres
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_env JIN_API_URL POSTGRES_PASSWORD

psql_chain_tail() {
  kubectl -n jin exec -i statefulset/postgres -- env PGPASSWORD="${POSTGRES_PASSWORD}" \
    psql -U jin -d jin -Atc \
    "SELECT id, prev_hash, current_hash FROM audit_log ORDER BY id DESC LIMIT 5;"
}

check_chain_tail_linkage() {
  local rows="$1"
  # Cada fila (salvo la más vieja del lote) debe tener su prev_hash
  # igual al current_hash de la fila anterior (id-1) -- mismo invariante
  # que hash-chain.ts::verifyChain, aplicado solo a este lote como
  # spot-check rápido, no como sustituto de la verificación completa.
  python3 - "$rows" <<'PY'
import sys
rows = [l.split('|') for l in sys.stdin.read().strip().splitlines() if l]
rows_by_id = {int(r[0]): (r[1], r[2]) for r in rows}
ids = sorted(rows_by_id, reverse=True)
for i in range(len(ids) - 1):
    cur_id, prev_id = ids[i], ids[i + 1]
    cur_prev_hash, _ = rows_by_id[cur_id]
    _, prev_current_hash = rows_by_id[prev_id]
    if cur_prev_hash != prev_current_hash:
        print(f"MISMATCH: audit_log id={cur_id}.prev_hash != id={prev_id}.current_hash", file=sys.stderr)
        sys.exit(1)
print("OK: linkage intacto en las filas revisadas.", file=sys.stderr)
PY
}

log ">> Spot-check del audit log ANTES del kill..."
BEFORE="$(psql_chain_tail)"
check_chain_tail_linkage "${BEFORE}"

log ">> Matando el pod de Postgres (namespace jin)..."
kubectl -n jin delete pod -l app.kubernetes.io/name=postgres --grace-period=0 --force

log ">> Verificando que jin-core reporte NotReady mientras Postgres está caído (fail ruidoso, no a medias)..."
sleep 5
if curl -sf -o /dev/null "${JIN_API_URL%/api}/health/ready"; then
  log "ERROR: jin-core sigue reportando Ready sin Postgres -- FALLA del chaos test (debería fallar ruidoso, AGENTS.md 1.4)."
  exit 1
fi
log "   OK: jin-core reporta NotReady mientras Postgres está caído, como se espera."

log ">> Esperando a que Postgres (StatefulSet, mismo PVC) vuelva a estar listo..."
kubectl -n jin rollout status statefulset/postgres --timeout=120s

log ">> Esperando a que jin-core vuelva a Ready..."
if ! wait_for_ready "${JIN_API_URL%/api}/health/ready" 60; then
  log "ERROR: jin-core no volvió a Ready tras la recuperación de Postgres."
  exit 1
fi

log ">> Spot-check del audit log DESPUÉS de la recuperación (mismo invariante)..."
AFTER="$(psql_chain_tail)"
check_chain_tail_linkage "${AFTER}"

log ">> OK: chaos test #2 pasó. Recordatorio: esto NO reemplaza la verificación nocturna completa de ChainVerificationService (4am UTC)."
