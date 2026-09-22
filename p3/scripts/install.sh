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
