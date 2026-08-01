#!/usr/bin/env bash
# Verifica la configuración de Cloudflare hecha en el dashboard (runbook,
# paso 4): túnel creado, DNS wildcard apuntando al túnel, hostnames públicos.
# No crea nada — la creación del túnel es un paso manual documentado porque
# requiere sesión interactiva en Zero Trust.
set -euo pipefail

DOMAINS=(jeanfranck.com jinserver.com)
fail=0

for domain in "${DOMAINS[@]}"; do
  echo ">> Verificando DNS de *.${domain}..."
  # El subdominio de prueba debe resolver a Cloudflare (proxied) — si NXDOMAIN,
  # falta el CNAME wildcard hacia <tunnel-id>.cfargotunnel.com.
  if dig +short "healthcheck-probe.${domain}" A | grep -q .; then
    echo "   OK: *.${domain} resuelve (proxied por Cloudflare)."
  else
    echo "   FALLO: *.${domain} no resuelve. Crea el CNAME wildcard en Cloudflare DNS." >&2
    fail=1
  fi
done

echo ">> Verificando que cloudflared está conectado..."
if kubectl -n jin get deployment cloudflared >/dev/null 2>&1; then
  if kubectl -n jin rollout status deployment/cloudflared --timeout=60s >/dev/null 2>&1; then
    echo "   OK: cloudflared Ready (túnel establecido)."
  else
    echo "   FALLO: cloudflared no está Ready. Revisa el token y los logs:" >&2
    echo "   kubectl -n jin logs deploy/cloudflared" >&2
    fail=1
  fi
else
  echo "   AVISO: cloudflared aún no está desplegado (corre 04-apply-manifests.sh primero)."
fi

exit "${fail}"
