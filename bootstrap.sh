#!/usr/bin/env bash

# Bootstrap ArgoCD and the App-of-Apps root application on Linux/WSL.
# Usage:
#   ./bootstrap.sh            # Bootstrap using dev values (default)
#   ./bootstrap.sh prod       # Bootstrap using prod values
#   ./bootstrap.sh -e prod    # Bootstrap using prod values

set -euo pipefail

ENV="dev"

# Simple arg parsing: allow positional ENV or -e/--env
if [[ $# -gt 0 ]]; then
  case "$1" in
    -e|--env)
      if [[ $# -lt 2 ]]; then
        echo "Error: Missing value for $1" >&2
        exit 1
      fi
      ENV="$2"
      ;;
    *)
      ENV="$1"
      ;;
  esac
fi

VALUES_FILE="env/${ENV}/argocd/values.yaml"
if [[ ! -f "$VALUES_FILE" ]]; then
  echo "Values file not found: $VALUES_FILE" >&2
  exit 1
fi

echo "==> Adding ArgoCD Helm repo..."
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

echo "==> Installing ArgoCD via Helm..."
helm install argocd argo/argo-cd \
  --namespace argocd \
  --create-namespace \
  --version 9.4.17 \
  -f "$VALUES_FILE" \
  --wait
  
echo "==> Applying root App-of-Apps..."
kubectl apply -f application.yaml

echo
echo "Bootstrap complete!"
echo "ArgoCD will now manage all applications defined in apps/."
echo

echo "To access the ArgoCD UI:"
echo "  kubectl port-forward svc/argocd-server -n argocd 8080:443"
echo "  Username: admin"
echo "  Password: kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath='{.data.password}' | base64 -d"
