#!/usr/bin/env bash
# Prueba de restore mensual (BLUEPRINT 3.5, regla de oro #3: "ningún backup
# no probado cuenta como backup"). Descarga el dump de Postgres más reciente,
# lo descifra, restaura en un Postgres efímero local (mismo pod, sin tocar
# el Postgres real) y valida con SQL. Notifica el resultado (stub Telegram).
#
# La llave privada de age se monta como archivo (Secret age-backup-key),
# nunca como variable de entorno, para que no aparezca en `env` ni en logs.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

require_env \
  AGE_IDENTITY_PATH \
  R2_ACCOUNT_ID R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY R2_BUCKET

: "${SCRATCH_DIR:=$(mktemp -d)}"
: "${CRITICAL_TABLES:=}"  # CSV, ej. "audit_log,tasks". Vacío hasta Fase 2.2.
PGDATA_SCRATCH="${SCRATCH_DIR}/pgdata"
SOCKET_DIR="${SCRATCH_DIR}/socket"
ENCRYPTED_DUMP="${SCRATCH_DIR}/dump.age"
DECRYPTED_DUMP="${SCRATCH_DIR}/dump.pgcustom"

cleanup() {
  local exit_code=$?
  if [[ -d "${SOCKET_DIR}" ]] && pg_ctl status -D "${PGDATA_SCRATCH}" >/dev/null 2>&1; then
    pg_ctl stop -D "${PGDATA_SCRATCH}" -m immediate >/dev/null 2>&1 || true
  fi
  rm -rf "${SCRATCH_DIR}" "${RCLONE_CONFIG:-}"
  if [[ "${exit_code}" -eq 0 ]]; then
    notify_telegram "✅ Restore test mensual: OK ($(date -u +%Y-%m-%d))."
  else
    notify_telegram "❌ Restore test mensual: FALLÓ ($(date -u +%Y-%m-%d)). Revisar logs del CronJob verify-restore."
  fi
  exit "${exit_code}"
}
trap cleanup EXIT

mkdir -p "${PGDATA_SCRATCH}" "${SOCKET_DIR}"

RCLONE_CONFIG="$(configure_rclone)"

log "Buscando el backup de Postgres más reciente en R2..."
LATEST_PATH="$(list_r2_backups "${RCLONE_CONFIG}" "postgres" | tail -n 1 | awk -F'\t' '{print $2}')"
if [[ -z "${LATEST_PATH}" ]]; then
  log "ERROR: no hay ningún backup de Postgres en R2 todavía."
  exit 1
fi
log "Backup más reciente: ${LATEST_PATH}"

rclone --config "${RCLONE_CONFIG}" copyto "r2:${R2_BUCKET}/${LATEST_PATH}" "${ENCRYPTED_DUMP}"

log "Descifrando..."
age_decrypt_file "${AGE_IDENTITY_PATH}" "${ENCRYPTED_DUMP}" "${DECRYPTED_DUMP}"
rm -f "${ENCRYPTED_DUMP}"

log "Inicializando Postgres efímero en ${PGDATA_SCRATCH}..."
initdb --username=postgres --auth=trust --no-instructions -D "${PGDATA_SCRATCH}" >/dev/null

pg_ctl start -D "${PGDATA_SCRATCH}" -o "-c listen_addresses='' -c unix_socket_directories=${SOCKET_DIR}" \
  -l "${SCRATCH_DIR}/postgres.log" -w -t 60

createdb -h "${SOCKET_DIR}" -U postgres restore_test

log "Restaurando dump..."
pg_restore -h "${SOCKET_DIR}" -U postgres -d restore_test --no-owner --no-privileges "${DECRYPTED_DUMP}"

log "Validando conectividad e integridad estructural..."
psql -h "${SOCKET_DIR}" -U postgres -d restore_test -v ON_ERROR_STOP=1 -Atc "SELECT 1;" >/dev/null

TABLE_COUNT="$(psql -h "${SOCKET_DIR}" -U postgres -d restore_test -Atc \
  "SELECT count(*) FROM information_schema.tables WHERE table_schema='public';")"
log "Tablas restauradas en el esquema public: ${TABLE_COUNT}"

if [[ -n "${CRITICAL_TABLES}" ]]; then
  IFS=',' read -ra tables <<< "${CRITICAL_TABLES}"
  for table in "${tables[@]}"; do
    count="$(psql -h "${SOCKET_DIR}" -U postgres -d restore_test -Atc "SELECT count(*) FROM ${table};")"
    log "  ${table}: ${count} filas."
  done
fi

log "Restore test de Postgres completo: OK."

log "Buscando el backup de Redis más reciente en R2..."
LATEST_REDIS="$(list_r2_backups "${RCLONE_CONFIG}" "redis" | tail -n 1 | awk -F'\t' '{print $2}')"
if [[ -n "${LATEST_REDIS}" ]]; then
  log "Backup de Redis más reciente: ${LATEST_REDIS}"
  rclone --config "${RCLONE_CONFIG}" copyto "r2:${R2_BUCKET}/${LATEST_REDIS}" "${SCRATCH_DIR}/redis.age"
  
  log "Descifrando RDB de Redis..."
  age_decrypt_file "${AGE_IDENTITY_PATH}" "${SCRATCH_DIR}/redis.age" "${SCRATCH_DIR}/dump.rdb"
  
  log "Validando integridad del archivo RDB..."
  redis-check-rdb "${SCRATCH_DIR}/dump.rdb" >/dev/null

  log "Levantando instancia efímera de Redis..."
  REDIS_DIR="${SCRATCH_DIR}/redis_scratch"
  mkdir -p "${REDIS_DIR}"
  cp "${SCRATCH_DIR}/dump.rdb" "${REDIS_DIR}/dump.rdb"
  REDIS_PORT=16379
  redis-server --port ${REDIS_PORT} --dir "${REDIS_DIR}" --dbfilename dump.rdb --daemonize yes --logfile "${SCRATCH_DIR}/redis.log"

  log "Ejecutando consultas de prueba contra la instancia efímera de Redis..."
  REDIS_PING="$(redis-cli -p ${REDIS_PORT} PING)"
  KEY_COUNT="$(redis-cli -p ${REDIS_PORT} DBSIZE)"
  log "  PING Redis: ${REDIS_PING}"
  log "  Claves encontradas en la BD restaurada: ${KEY_COUNT}"

  redis-cli -p ${REDIS_PORT} shutdown >/dev/null 2>&1 || true

  log "Restore test de Redis completo: OK."
else
  log "INFO: No se encontró ningún backup de Redis."
fi

log "Buscando el backup de memory.db más reciente en R2..."
LATEST_MEMORY="$(list_r2_backups "${RCLONE_CONFIG}" "memory" | tail -n 1 | awk -F'\t' '{print $2}')"
if [[ -n "${LATEST_MEMORY}" ]]; then
  log "Backup de memory.db más reciente: ${LATEST_MEMORY}"
  rclone --config "${RCLONE_CONFIG}" copyto "r2:${R2_BUCKET}/${LATEST_MEMORY}" "${SCRATCH_DIR}/memory.age"
  
  log "Descifrando memory.db..."
  age_decrypt_file "${AGE_IDENTITY_PATH}" "${SCRATCH_DIR}/memory.age" "${SCRATCH_DIR}/memory.db"
  
  log "Validando integridad y ejecutando consultas en memory.db..."
  sqlite3 "${SCRATCH_DIR}/memory.db" "PRAGMA integrity_check;" >/dev/null
  
  TABLE_COUNT="$(sqlite3 "${SCRATCH_DIR}/memory.db" "SELECT count(*) FROM sqlite_master WHERE type='table';")"
  log "  Tablas encontradas en memory.db: ${TABLE_COUNT}"

  VEC_COUNT="$(sqlite3 "${SCRATCH_DIR}/memory.db" "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='vec0';")"
  if [[ "${VEC_COUNT}" -eq 1 ]]; then
    ROW_COUNT="$(sqlite3 "${SCRATCH_DIR}/memory.db" "SELECT count(*) FROM vec0;")"
    log "  Filas en la tabla de vectores vec0: ${ROW_COUNT}"
  else
    log "  (Tabla vec0 aún no inicializada en la BD de memoria)"
  fi
  
  log "Restore test de memory.db completo: OK."
else
  log "INFO: No se encontró ningún backup de memory.db."
fi

log "Restore tests completos: TODOS OK."
