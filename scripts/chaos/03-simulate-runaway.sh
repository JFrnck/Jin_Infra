#!/usr/bin/env bash
# Chaos test #3 (BLUEPRINT 13.2): simular un consumo runaway real y
# verificar que el kill switch corta y la alerta de Telegram sale
# (BudgetGuardedModelRouter / KillSwitchService, ADR y BLUEPRINT 9.6).
#
# Forzar un runaway REAL (quemar tokens de verdad hasta pasar el umbral)
# es caro e innecesario -- en vez de eso se insertan filas directo en
# budget_hourly_usage simulando 24h de consumo bajo + 1 hora de consumo
# disparado (config/budget.yaml: runaway_multiplier × runaway_lookback_hours
# reales del clúster, no hardcodeados acá). KillSwitchService corre cada
# 5 minutos (@Cron), así que este script hace polling hasta 6 minutos.
#
# Variables de entorno requeridas:
#   JIN_API_URL         ej. https://jin.jeanfranck.com/api
#   JIN_JWT             token Bearer de una sesión real (owner)
#   POSTGRES_PASSWORD   password del usuario jin de Postgres
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_env JIN_API_URL JIN_JWT POSTGRES_PASSWORD

psql_exec() {
  kubectl -n jin exec -i statefulset/postgres -- env PGPASSWORD="${POSTGRES_PASSWORD}" \
    psql -U jin -d jin -Atc "$1"
}

log ">> Estado del kill switch ANTES de simular el runaway..."
BEFORE_ACTIVE="$(curl -sf -H "Authorization: Bearer ${JIN_JWT}" "${JIN_API_URL}/budget" | jq -r '.killSwitchActive')"
if [[ "${BEFORE_ACTIVE}" == "true" ]]; then
  log "ERROR: el kill switch ya está activo antes de empezar -- corré /api/budget/unpause primero (owner) o el test no es concluyente."
  exit 1
fi

log ">> Insertando 24 horas de consumo bajo (línea base) + 1 hora de consumo disparado..."
psql_exec "
  INSERT INTO budget_hourly_usage (hour_bucket, input_tokens, output_tokens, cost_usd)
  SELECT date_trunc('hour', now()) - (n || ' hours')::interval, 1000, 1000, 0.01
  FROM generate_series(1, 24) AS n
  ON CONFLICT (hour_bucket) DO NOTHING;

  INSERT INTO budget_hourly_usage (hour_bucket, input_tokens, output_tokens, cost_usd)
  VALUES (date_trunc('hour', now()), 50000000, 50000000, 500)
  ON CONFLICT (hour_bucket) DO UPDATE SET
    input_tokens = EXCLUDED.input_tokens,
    output_tokens = EXCLUDED.output_tokens,
    cost_usd = EXCLUDED.cost_usd;
"

log ">> Esperando a que KillSwitchService (corre cada 5 min) detecte el runaway..."
TRIPPED=0
for _ in $(seq 1 8); do
  ACTIVE="$(curl -sf -H "Authorization: Bearer ${JIN_JWT}" "${JIN_API_URL}/budget" | jq -r '.killSwitchActive')"
  if [[ "${ACTIVE}" == "true" ]]; then
    TRIPPED=1
    break
  fi
  sleep 45
done

if [[ "${TRIPPED}" -ne 1 ]]; then
  log "ERROR: el kill switch no se activó en ~6 minutos -- FALLA del chaos test."
  exit 1
fi
log "   OK: killSwitchActive=true."

log ">> Verificación manual pendiente (no automatizable desde este script): confirmá que llegó la alerta al chat de Telegram del owner (BLUEPRINT 9.6/10.4)."

log ">> Revirtiendo: unpause del kill switch + borrando las filas simuladas..."
curl -sf -X POST -H "Authorization: Bearer ${JIN_JWT}" "${JIN_API_URL}/budget/unpause" > /dev/null
psql_exec "
  DELETE FROM budget_hourly_usage
  WHERE hour_bucket >= date_trunc('hour', now()) - interval '24 hours';
"

log ">> OK: chaos test #3 pasó (kill switch se activó). Confirmá la alerta de Telegram a mano."
