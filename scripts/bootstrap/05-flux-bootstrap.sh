#!/usr/bin/env bash
# GitOps: Flux vigila k8s/overlays/production de este repo (BLUEPRINT 12.1).
# Se corre AL FINAL del bootstrap, cuando el clúster ya está validado a mano.
# Requiere: flux CLI instalado y GITHUB_TOKEN con scope repo.
set -euo pipefail

FLUX_VERSION_EXPECTED="${FLUX_VERSION_EXPECTED:-2.9.2}"
GITHUB_OWNER="${GITHUB_OWNER:-JFrnck}"
GITHUB_REPO="${GITHUB_REPO:-Jin_Infra}"

if ! command -v flux >/dev/null 2>&1; then
  # Hash obtenido en 2026-08-05. Si Flux actualiza el instalador legítimamente,
  # la verificación de abajo fallará ("sha256sum: WARNING: ... did NOT match").
  # Para solucionarlo:
  # 1. Verificar el cambio en https://github.com/fluxcd/flux2/commits/main/install/install.sh
  # 2. curl -s https://fluxcd.io/install.sh | sha256sum
  # 3. Actualizar el valor de INSTALL_SH_SHA256 aquí.
  INSTALL_SH_SHA256="bd7765225b731a1df952456eced0abb5dbbf5e11bc70cf6ab5fddd1476088b7e"
  echo "ERROR: flux CLI no encontrado. Instala v${FLUX_VERSION_EXPECTED} manualmente:" >&2
  echo "  curl -s https://fluxcd.io/install.sh -o install-flux.sh" >&2
  echo "  echo \"${INSTALL_SH_SHA256}  install-flux.sh\" | sha256sum -c -" >&2
  echo "  FLUX_VERSION=${FLUX_VERSION_EXPECTED} sudo bash install-flux.sh" >&2
  echo "Este paso es intencionalmente manual: instalar un controlador GitOps con" >&2
  echo "permisos cluster-wide no debe quedar desatendido dentro de un script." >&2
  exit 1
fi

if [[ -z "${GITHUB_TOKEN:-}" ]]; then
  echo "ERROR: exporta GITHUB_TOKEN (PAT con scope repo) antes de correr esto." >&2
  exit 1
fi

echo ">> Pre-check de Flux..."
flux check --pre

echo ">> Bootstrapping Flux sobre ${GITHUB_OWNER}/${GITHUB_REPO} (path k8s/overlays/production)..."
flux bootstrap github \
  --owner="${GITHUB_OWNER}" \
  --repository="${GITHUB_REPO}" \
  --branch=main \
  --path=k8s/overlays/production \
  --personal \
  --interval=5m

echo ">> Flux instalado. A partir de ahora: git push a main => deploy."
flux get kustomizations
