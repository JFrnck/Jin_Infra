#!/usr/bin/env bash
# GitOps: Flux vigila k8s/overlays/production de este repo (BLUEPRINT 12.1).
# Se corre AL FINAL del bootstrap, cuando el clúster ya está validado a mano.
# Requiere: flux CLI instalado y GITHUB_TOKEN con scope repo.
set -euo pipefail

FLUX_VERSION_EXPECTED="${FLUX_VERSION_EXPECTED:-2.9.2}"
GITHUB_OWNER="${GITHUB_OWNER:-JFrnck}"
GITHUB_REPO="${GITHUB_REPO:-Jin_Infra}"

if ! command -v flux >/dev/null 2>&1; then
  echo "ERROR: flux CLI no encontrado. Instala v${FLUX_VERSION_EXPECTED}:" >&2
  echo "  curl -s https://fluxcd.io/install.sh | FLUX_VERSION=${FLUX_VERSION_EXPECTED} sudo bash" >&2
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
