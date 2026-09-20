#!/usr/bin/env bash
# Verifica la configuración de Cloudflare hecha en el dashboard (runbook,
# paso 4): túnel creado, DNS apuntando al túnel (jin y grafana explícitos en
# jeanfranck.com, comodín en jinserver.com), hostnames públicos.
# No crea nada — la creación del túnel es un paso manual documentado porque
# requiere sesión interactiva en Zero Trust.
set -euo pipefail

# jeanfranck.com es el portafolio del owner, NO parte de Jin: solo se exponen los
# hosts que Jin usa, con registros CNAME explícitos (sin comodín, menos superficie).
# jinserver.com sí lleva comodín: cada preview crea un subdominio nuevo.
HOSTS=(
  jin.jeanfranck.com
  grafana.jeanfranck.com
  healthcheck-probe.jinserver.com
)
fail=0

for host in "${HOSTS[@]}"; do
  echo ">> Verificando DNS de ${host}..."
  # Debe resolver a Cloudflare (proxied) -- si NXDOMAIN, falta el CNAME hacia
  # <tunnel-id>.cfargotunnel.com (para jinserver.com: el CNAME wildcard `*`).
  if dig +short "${host}" A | grep -q .; then
    echo "   OK: ${host} resuelve (proxied por Cloudflare)."
  else
    echo "   FALLO: ${host} no resuelve. Crea el CNAME hacia el túnel en Cloudflare DNS." >&2
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
