set -e


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

echo "==> Disabling TLS on argocd-server so it works behind a plain-HTTP Ingress"
kubectl patch configmap argocd-cmd-params-cm -n argocd \
    --type merge -p '{"data":{"server.insecure":"true"}}'
kubectl rollout restart deployment argocd-server -n argocd
kubectl rollout status deployment argocd-server -n argocd --timeout=300s

echo "==> Deploying the Argo CD Application (points at the GitOps repo)"
kubectl apply -f "$(dirname "$0")/../confs/application.yaml"

echo "==> Creating the service for argocd"
kubectl apply -f "$(dirname "$0")/../confs/ingress.yaml"

echo "==> Argo CD initial admin password:"
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
echo ""

echo "==> Done. All tools, Argo CD, and the Application are installed and ready."