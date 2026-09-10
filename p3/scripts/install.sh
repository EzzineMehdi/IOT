#!/bin/bash
# Inception-of-Things - Part 3
# Installs everything needed for K3d + Argo CD: Docker, k3d, kubectl.
# Safe to re-run: skips anything already installed.

set -e

echo "==> Updating package lists"
sudo apt-get update -y

echo "==> Installing prerequisite packages"
sudo apt-get install -y ca-certificates curl gnupg lsb-release

echo "==> Installing Docker Engine"
if ! command -v docker &> /dev/null; then
    curl -fsSL https://get.docker.com | sh
    sudo usermod -aG docker "$USER"
    echo "Docker installed. Log out/in (or run 'newgrp docker') for group changes to apply without sudo."
else
    echo "Docker already installed, skipping."
fi

echo "==> Installing k3d"
if ! command -v k3d &> /dev/null; then
    curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash
else
    echo "k3d already installed, skipping."
fi

echo "==> Installing kubectl"
if ! command -v kubectl &> /dev/null; then
    KUBECTL_VERSION=$(curl -L -s https://dl.k8s.io/release/stable.txt)
    curl -LO "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl"
    chmod +x kubectl
    sudo mv kubectl /usr/local/bin/
else
    echo "kubectl already installed, skipping."
fi

echo "==> Verifying installations"
docker --version
k3d version
kubectl version --client

echo "==> Creating k3d cluster"
if ! k3d cluster list | grep -q "^inception"; then
    k3d cluster create inception -p "8080:80@loadbalancer" #-p "8443:443@loadbalancer"
else
    echo "Cluster 'inception' already exists, skipping."
fi

echo "==> Waiting for cluster to be ready"
kubectl wait --for=condition=Ready nodes --all --timeout=120s

echo "==> Creating namespaces"
kubectl apply -f "$(dirname "$0")/../confs/namespaces.yaml"

echo "==> Installing Argo CD"
# --server-side avoids "metadata.annotations too long" on the
# applicationsets.argoproj.io CRD, which is too big for the normal
# client-side apply's last-applied-configuration annotation.
kubectl apply -n argocd --server-side --force-conflicts \
    -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

echo "==> Waiting for Argo CD to be ready (this can take a few minutes)"
kubectl wait --for=condition=Ready pods --all -n argocd --timeout=300s

echo "==> Deploying the Argo CD Application (points at the GitOps repo)"
kubectl apply -f "$(dirname "$0")/../confs/application.yaml"

echo "==> Argo CD initial admin password:"
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
echo ""

echo "==> Done. All tools, Argo CD, and the Application are installed and ready."