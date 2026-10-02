#!/usr/bin/env bash
# Pre-pull de las imágenes de las bases de datos de DEMO (Redis, PostgreSQL,
# MongoDB) en el nodo. Sin esto, la primera demo con cada motor baja la imagen
# al arrancar (mongo ~250 MB: más de un minuto). Las versiones deben coincidir
# con las de Jin_Executor `src/k8s/demo-db.builder.ts`.
# Re-ejecutar tras cambiar una versión allá.
set -euo pipefail

IMAGES=(
  "${REDIS_IMAGE:-docker.io/library/redis:7.4-alpine}"
  "${POSTGRES_IMAGE:-docker.io/library/postgres:16.4-alpine}"
  "${MONGO_IMAGE:-docker.io/library/mongo:7.0}"
)

for image in "${IMAGES[@]}"; do
  echo ">> Pre-pulling ${image} en el containerd de K3s..."
  sudo k3s ctr images pull "${image}"
  sudo k3s ctr images ls | grep -F "${image#docker.io/}" >/dev/null || {
    echo "ERROR: ${image} no aparece en el cache del nodo." >&2
    exit 1
  }
done
echo ">> OK: imágenes de bases de datos de demo cacheadas en el nodo."
