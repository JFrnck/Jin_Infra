#!/usr/bin/env bash
# Genera los secretos INTERNOS que 02-seed-secrets.sh necesita y que no
# vienen de ninguna cuenta externa: contraseñas de Postgres/Redis/Grafana,
# claves de Infisical y el par de claves age de los backups. Los valores se
# escriben a un archivo 0600 y NUNCA se imprimen (ni acá ni en ningún log).
#
# NO genera lo que sale de cuentas de terceros (Cloudflare, R2, GitHub): esas
# 7 variables las pone el owner a mano en el mismo archivo (queda un molde
# comentado al final). Ver oci-deploy-prep.md §6.
#
# Uso:
#   bash scripts/bootstrap/00-generate-local-secrets.sh          # ~/.jin-secrets.env
#   SECRETS_FILE=/ruta bash scripts/bootstrap/00-generate-local-secrets.sh
#   # completar las variables externas en el archivo, y luego:
#   set -a; source ~/.jin-secrets.env; set +a
#   bash scripts/bootstrap/02-seed-secrets.sh
set -euo pipefail

SECRETS_FILE="${SECRETS_FILE:-${HOME}/.jin-secrets.env}"

for cmd in openssl age-keygen; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "ERROR: falta '${cmd}'. En Ubuntu: sudo apt-get install -y openssl age" >&2
    exit 1
  fi
done

# Nunca pisar un archivo existente: regenerar la clave privada de age dejaría
# ilegibles los backups ya cifrados con la anterior.
if [[ -e "${SECRETS_FILE}" ]]; then
  echo "ERROR: ${SECRETS_FILE} ya existe; no se sobrescribe (los backups cifrados" >&2
  echo "       con la age key anterior quedarían irrecuperables). Borralo a mano" >&2
  echo "       solo si estás seguro de que no hay nada cifrado todavía." >&2
  exit 1
fi

umask 077
# age-keygen se niega a escribir sobre un archivo que ya existe (por eso un
# directorio temporal y no `mktemp` a secas), y su stderr no se oculta: un
# fallo acá tiene que verse.
age_dir="$(mktemp -d)"
trap 'rm -rf "${age_dir}"' EXIT
age_identity="${age_dir}/identity.txt"
age-keygen -o "${age_identity}" >/dev/null
age_secret="$(grep -E '^AGE-SECRET-KEY-' "${age_identity}")"
age_public="$(age-keygen -y "${age_identity}")"

# hex: seguro dentro de una URL (DATABASE_URL embebe POSTGRES_PASSWORD).
{
  echo "# Generado el $(date -u +%Y-%m-%dT%H:%M:%SZ) por 00-generate-local-secrets.sh"
  echo "# Permisos 0600. RESPALDÁ ESTE ARCHIVO FUERA DE LA VM (gestor de contraseñas):"
  echo "# sin AGE_PRIVATE_KEY los backups en R2 no se pueden descifrar."
  echo
  echo "export POSTGRES_PASSWORD='$(openssl rand -hex 24)'"
  echo "export REDIS_PASSWORD='$(openssl rand -hex 24)'"
  echo "export INFISICAL_ENCRYPTION_KEY='$(openssl rand -hex 16)'"
  echo "export INFISICAL_AUTH_SECRET='$(openssl rand -base64 32)'"
  echo "export GRAFANA_ADMIN_PASSWORD='$(openssl rand -hex 16)'"
  echo "export AGE_PUBLIC_KEY='${age_public}'"
  echo "export AGE_PRIVATE_KEY='${age_secret}'"
  echo
  echo "# --- Completá estas 7 (salen de tus cuentas; oci-deploy-prep.md §6). Sin comillas vacías. ---"
  echo "# export CLOUDFLARE_API_TOKEN='...'       # Zone.DNS Edit en jeanfranck.com y jinserver.com"
  echo "# export CLOUDFLARED_TUNNEL_TOKEN='...'   # Zero Trust -> Tunnels"
  echo "# export R2_ACCOUNT_ID='...'"
  echo "# export R2_ACCESS_KEY_ID='...'           # API token de R2 scoped al bucket jin-backups"
  echo "# export R2_SECRET_ACCESS_KEY='...'"
  echo "# export GHCR_USERNAME='...'"
  echo "# export GHCR_PAT='...'                   # scope read:packages"
} > "${SECRETS_FILE}"
chmod 600 "${SECRETS_FILE}"

echo ">> Secretos internos generados en ${SECRETS_FILE} (0600). Valores NO impresos."
echo ">> Siguiente: descomentá y completá las 7 variables externas, respaldá el archivo"
echo "   fuera de la VM, y corré 02-seed-secrets.sh (ver el encabezado de este script)."
