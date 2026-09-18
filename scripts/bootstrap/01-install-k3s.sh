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
# Hash obtenido en 2026-08-05. Si k3s-io actualiza el instalador legítimamente,
# este script fallará ("sha256sum: WARNING: 1 computed checksum did NOT match").
# Para solucionarlo: 
# 1. Verificar el cambio en https://github.com/k3s-io/k3s/commits/master/install.sh
# 2. curl -sL https://get.k3s.io | sha256sum
# 3. Actualizar el valor de INSTALL_SH_SHA256 aquí.
INSTALL_SH_SHA256="ed01f89fd977bf20ac1516bbebf8370bf3ddbaa55dac8aba610956a4c78cc00b"

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
