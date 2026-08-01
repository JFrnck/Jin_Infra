#!/usr/bin/env bash
# Backup de la memoria extendida sqlite-vec (BLUEPRINT 3.3.1 y 3.5).
# Requiere el archivo en MEMORY_DB_PATH (montaje read-only de la PVC
# jin-core-data — ver k8s/base/backup/cronjob-memory.yaml).
#
# El módulo src/memory/ de Jin_Core no existe hasta la Fase 4: si el
# archivo aún no existe, esto NO es un fallo (orden temporal esperado),
# se registra y se sale 0 para no disparar alertas falsas.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

MEMORY_DB_PATH="${MEMORY_DB_PATH:-/data/memory/memory.db}"

if [[ ! -f "${MEMORY_DB_PATH}" ]]; then
  log "memory.db no existe aún en ${MEMORY_DB_PATH} (módulo memory pendiente de Fase 4). Nada que respaldar."
  exit 0
fi

require_env \
  AGE_RECIPIENT_PUBLIC_KEY \
  R2_ACCOUNT_ID R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY R2_BUCKET

RCLONE_CONFIG="$(configure_rclone)"
BACKUP_FILE="$(mktemp)"
trap 'rm -f "${RCLONE_CONFIG}" "${BACKUP_FILE}"' EXIT

DATE="$(date -u +%Y-%m-%d)"
REMOTE_PATH="memory/${DATE}.age"

log "Iniciando backup de memory.db (${MEMORY_DB_PATH}) -> r2:${R2_BUCKET}/${REMOTE_PATH}"

# sqlite3 .backup es seguro con WAL activo y con un writer concurrente
# (usa la Online Backup API de SQLite, no una copia de archivo cruda).
sqlite3 "${MEMORY_DB_PATH}" ".backup '${BACKUP_FILE}'"

age_encrypt_stream "${AGE_RECIPIENT_PUBLIC_KEY}" < "${BACKUP_FILE}" \
  | upload_to_r2 "${RCLONE_CONFIG}" "${REMOTE_PATH}"

log "Backup de memory.db subido correctamente."

enforce_retention "${RCLONE_CONFIG}" "memory"

log "Backup de memoria extendida completo."
