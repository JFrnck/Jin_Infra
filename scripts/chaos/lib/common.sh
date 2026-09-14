#!/usr/bin/env bash
# Helpers compartidos por los 3 chaos tests (BLUEPRINT 13.2). Se usa con
# `source`, no se ejecuta directamente. Copia deliberada de
# scripts/backup/lib/common.sh (log/require_env) en vez de compartirla
# entre directorios -- son solo 2 funciones, AGENTS.md 1.1 no pide
# abstraer hasta el tercer uso real.

log() {
  printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2
}

require_env() {
  local var missing=0
  for var in "$@"; do
    if [[ -z "${!var:-}" ]]; then
      log "ERROR: falta la variable de entorno ${var}"
      missing=1
    fi
  done
  [[ "${missing}" -eq 0 ]] || exit 1
}

# wait_for_ready <url> <max_seconds>
# Poll de /health/ready hasta 200 o timeout. Devuelve 1 (no exit) si
# nunca llegó a 200 -- el caller decide si eso es la falla esperada
# (chaos test #2) o un error real (chaos test #1/#3).
wait_for_ready() {
  local url="$1" max_seconds="$2" elapsed=0
  while (( elapsed < max_seconds )); do
    if curl -sf -o /dev/null "${url}"; then
      return 0
    fi
    sleep 5
    elapsed=$(( elapsed + 5 ))
  done
  return 1
}
