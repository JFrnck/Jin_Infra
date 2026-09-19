#!/usr/bin/env bash
# Instala K3s en la VM (Ubuntu 24.04 ARM). Correr como usuario con sudo.
# - servicelb deshabilitado: la única entrada al clúster es el Cloudflare
#   Tunnel; no queremos puertos 80/443 escuchando en la IP pública de OCI.
# - Traefik queda habilitado (es nuestro Ingress controller).
# - system-reserved + eviction-hard: en una VM de 12GB/2vCPU, sin reserva
#   explícita el kubelet reparte TODA la máquina entre pods y un pico puede
#   dejar sin memoria a k3s/sshd. Con esto el allocatable queda en
#   ~10.5Gi / 1750m (BLUEPRINT 3.1.1) y el kubelet desaloja pods antes de
#   que el kernel llegue al OOM killer.
set -euo pipefail

K3S_VERSION="${K3S_VERSION:-v1.36.2+k3s1}"
# Hash del install.sh de k3s-io/k3s en el commit 2977c525 (2026-09-03).
# Verificado el 2026-09-19: el pin anterior (ed01f89f...) era exactamente el
# install.sh del commit 2d0f82fa, y entre ambos solo cambió un bloque de
# setup_selinux() para coreos/flatcar (2 líneas, irrelevante en Ubuntu).
# Si k3s-io actualiza el instalador legítimamente, este script fallará
# ("sha256sum: WARNING: 1 computed checksum did NOT match"). Para solucionarlo:
# 1. Ver qué cambió: gh api "repos/k3s-io/k3s/commits?path=install.sh&since=<fecha del pin>"
#    y revisar el patch de cada commit -- NO actualizar el hash sin leerlo.
# 2. Confirmar que lo que sirve get.k3s.io es ese commit:
#    curl -sL https://get.k3s.io | sha256sum   (debe igualar el install.sh del commit)
# 3. Actualizar el valor de INSTALL_SH_SHA256 aquí y anotar el commit arriba.
INSTALL_SH_SHA256="e5cc3b3d9dfc1662c2d9be6da5abc9a4cd317d6abc3a5ffc02e3dd3248207fee"

echo ">> Descargando y verificando instalador de K3s ${K3S_VERSION} (servicelb deshabilitado)..."
curl -sfL https://get.k3s.io -o install.sh
echo "${INSTALL_SH_SHA256}  install.sh" | sha256sum -c -

INSTALL_K3S_VERSION="${K3S_VERSION}" sh install.sh server \
  --disable=servicelb \
  --write-kubeconfig-mode=0600 \
  --kubelet-arg=system-reserved=cpu=250m,memory=768Mi \
  '--kubelet-arg=eviction-hard=memory.available<300Mi'
rm -f install.sh

echo ">> Esperando a que el nodo esté Ready..."
sudo k3s kubectl wait --for=condition=Ready node --all --timeout=300s

echo ">> Configurando kubeconfig para el usuario actual..."
mkdir -p "${HOME}/.kube"
sudo cp /etc/rancher/k3s/k3s.yaml "${HOME}/.kube/config"
sudo chown "$(id -u):$(id -g)" "${HOME}/.kube/config"
chmod 0600 "${HOME}/.kube/config"

echo ">> K3s instalado:"
kubectl get nodes -o wide
