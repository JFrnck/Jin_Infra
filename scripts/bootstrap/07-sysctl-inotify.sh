#!/usr/bin/env bash
# Sube fs.inotify.max_user_watches en el NODO (Fase 5.5, ADR 0006 punto 5).
# No es un sysctl "namespaced" — no se puede setear vía securityContext.sysctls
# de un pod sin privilegios, así que se sube una vez acá. Sin esto, el hot
# reload de los pods de servicio (npm run dev, etc.) deja de funcionar EN
# SILENCIO al agotarse el límite default del kernel (~8192 en la mayoría de
# distros), sin ningún error claro del lado de la app.
set -euo pipefail

MAX_USER_WATCHES="${MAX_USER_WATCHES:-524288}"
SYSCTL_FILE="/etc/sysctl.d/99-jin-inotify.conf"

echo ">> Configurando fs.inotify.max_user_watches=${MAX_USER_WATCHES}..."
echo "fs.inotify.max_user_watches=${MAX_USER_WATCHES}" | sudo tee "${SYSCTL_FILE}" > /dev/null
sudo sysctl -p "${SYSCTL_FILE}"

echo ">> Verificando..."
CURRENT_VALUE="$(sysctl -n fs.inotify.max_user_watches)"
if [ "${CURRENT_VALUE}" != "${MAX_USER_WATCHES}" ]; then
  echo "ERROR: fs.inotify.max_user_watches quedó en ${CURRENT_VALUE}, se esperaba ${MAX_USER_WATCHES}." >&2
  exit 1
fi
echo ">> OK: fs.inotify.max_user_watches=${CURRENT_VALUE} (persistente en ${SYSCTL_FILE})."
