#!/usr/bin/env bash
# Fase 8.1: siembra los Secrets de K8s con las credenciales de las
# identidades de máquina de Infisical (Universal Auth) que jin-core y
# jin-executor usan para autenticarse contra Infisical al startup
# (ver Jin_Core/src/config/secrets-loader.ts).
#
# Requiere que YA existan, creados a mano en Infisical (self-hosted,
# corriendo desde 04-apply-manifests.sh) -- no se puede scriptear a
# ciegas, es sesión interactiva contra un servicio recién levantado sin
# ningún admin todavía, mismo motivo por el que 05-flux-bootstrap.sh
# tiene un gate manual:
#   1. UI de Infisical (port-forward: kubectl -n jin port-forward
#      svc/infisical 8080:8080) -> crear la cuenta admin -> crear el
#      proyecto "jin" -> crear el environment "prod" (si no viene por
#      default).
#   2. Cargar las 13 claves reales de Jin_Core y las 2 de Jin_Executor
#      (ver Jin_Core/src/config/secrets-loader.ts y el equivalente de
#      Jin_Executor para la lista exacta) en ese proyecto/environment.
#   3. Settings del proyecto -> Identities -> crear DOS identidades
#      separadas con auth method "Universal Auth":
#        - "jin-core": acceso de lectura SOLO a las 13 claves de Core.
#        - "jin-executor": acceso de lectura SOLO a MODAL_TOKEN_ID/SECRET.
#      Cada una genera su propio Client ID + Client Secret -- son los que
#      pide este script.
#   4. Anotar el Project ID (Settings -> General) y reemplazar el
#      placeholder PENDIENTE_CREAR_PROYECTO_INFISICAL en
#      k8s/base/jin-core/deployment.yaml y k8s/base/executor/deployment.yaml
#      por el valor real (mismo flujo de PR que cualquier otro cambio de
#      manifest -- no directo a main).
#
# Variables de entorno requeridas (NUNCA se logean sus valores):
#   INFISICAL_CORE_CLIENT_ID       Client ID de la identidad "jin-core"
#   INFISICAL_CORE_CLIENT_SECRET   Client Secret de la identidad "jin-core"
#   INFISICAL_EXECUTOR_CLIENT_ID       Client ID de la identidad "jin-executor"
#   INFISICAL_EXECUTOR_CLIENT_SECRET   Client Secret de la identidad "jin-executor"
set -euo pipefail

required_vars=(
  INFISICAL_CORE_CLIENT_ID
  INFISICAL_CORE_CLIENT_SECRET
  INFISICAL_EXECUTOR_CLIENT_ID
  INFISICAL_EXECUTOR_CLIENT_SECRET
)
missing=0
for var in "${required_vars[@]}"; do
  if [[ -z "${!var:-}" ]]; then
    echo "ERROR: falta la variable de entorno ${var}" >&2
    missing=1
  fi
done
[[ "${missing}" -eq 1 ]] && exit 1

apply_secret() {
  local ns="$1" name="$2"
  shift 2
  local args=()
  local pair
  for pair in "$@"; do
    args+=("--from-literal=${pair}")
  done
  kubectl -n "${ns}" create secret generic "${name}" "${args[@]}" \
    --dry-run=client -o yaml | kubectl apply -f -
  echo "   Secret ${ns}/${name} aplicado."
}

echo ">> Creando Secrets de identidad de Infisical..."
apply_secret jin jin-core-infisical-auth \
  "INFISICAL_CLIENT_ID=${INFISICAL_CORE_CLIENT_ID}" \
  "INFISICAL_CLIENT_SECRET=${INFISICAL_CORE_CLIENT_SECRET}"

apply_secret jin-executor jin-executor-infisical-auth \
  "INFISICAL_CLIENT_ID=${INFISICAL_EXECUTOR_CLIENT_ID}" \
  "INFISICAL_CLIENT_SECRET=${INFISICAL_EXECUTOR_CLIENT_SECRET}"

echo ">> Listo. Si INFISICAL_PROJECT_ID todavía es el placeholder en los"
echo "   Deployments, jin-core/executor no van a llegar a Ready hasta que"
echo "   ese PR se mergee con el Project ID real (ver cabecera de este script)."
