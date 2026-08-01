#!/usr/bin/env bash
# Instala cert-manager (manifest oficial pinneado) y aplica el overlay de
# producción. Orden importa: los CRDs de cert-manager deben existir antes
# de nuestros ClusterIssuer/Certificates.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CERT_MANAGER_VERSION="${CERT_MANAGER_VERSION:-v1.21.0}"

echo ">> Instalando cert-manager ${CERT_MANAGER_VERSION}..."
kubectl apply -f "https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml"

echo ">> Esperando a cert-manager..."
for deploy in cert-manager cert-manager-webhook cert-manager-cainjector; do
  kubectl -n cert-manager rollout status "deployment/${deploy}" --timeout=300s
done

echo ">> Validando manifests contra el API server (dry-run)..."
kubectl apply -k "${REPO_ROOT}/k8s/overlays/production" --dry-run=server

echo ">> Aplicando overlay de producción..."
kubectl apply -k "${REPO_ROOT}/k8s/overlays/production"

echo ">> Esperando rollouts..."
kubectl -n jin rollout status statefulset/postgres --timeout=600s
kubectl -n jin rollout status statefulset/redis --timeout=300s
kubectl -n jin rollout status deployment/infisical --timeout=600s
kubectl -n jin rollout status deployment/cloudflared --timeout=300s
kubectl -n observability rollout status deployment/prometheus --timeout=300s
kubectl -n observability rollout status deployment/loki --timeout=300s
kubectl -n observability rollout status deployment/grafana --timeout=300s
kubectl -n observability rollout status daemonset/promtail --timeout=300s

echo ">> Estado de los certificados wildcard (DNS-01 puede tardar ~2 min):"
kubectl get certificate -A

echo ">> Listo. Verifica con: kubectl get pods -A"
