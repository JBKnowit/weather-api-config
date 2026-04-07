#!/usr/bin/env bash

# Tears down everything created by application.yaml and bootstrap.sh.
# Usage:
#   ./teardown.sh            # dev (default)
#   ./teardown.sh prod

set -euo pipefail

ENV="dev"
if [[ $# -gt 0 ]]; then
  case "$1" in
    -e|--env) ENV="$2" ;;
    *) ENV="$1" ;;
  esac
fi

echo "==> WARNING: Deletes all ArgoCD-managed apps and namespaces for env: $ENV"
read -r -p "Are you sure? (yes/N): " confirm
if [[ "$confirm" != "yes" ]]; then echo "Aborted."; exit 0; fi

# Delete ArgoCD Applications in reverse sync-wave order
echo "==> Deleting ArgoCD Application resources..."
for app in weather-api grafana prometheus metallb-config metallb argocd root-app; do
  if kubectl get application "$app" -n argocd &>/dev/null; then
    echo "  Deleting: $app"
    kubectl delete application "$app" -n argocd --timeout=60s
  else
    echo "  Skipping (not found): $app"
  fi
done

# Uninstall Helm releases
echo "==> Uninstalling Helm releases..."
for release_ns in "weather-api:weatherapi" "grafana:monitoring" "prometheus:monitoring" "metallb:metallb-system"; do
  release="${release_ns%%:*}"; ns="${release_ns##*:}"
  if helm status "$release" -n "$ns" &>/dev/null; then
    echo "  Uninstalling: $release ($ns)"
    helm uninstall "$release" -n "$ns" --wait
  else
    echo "  Skipping (not found): $release in $ns"
  fi
done

# Delete namespaces
echo "==> Deleting namespaces..."
for ns in weatherapi monitoring metallb-system; do
  if kubectl get namespace "$ns" &>/dev/null; then
    echo "  Deleting namespace: $ns"
    kubectl delete namespace "$ns" --timeout=120s
  fi
done

# Uninstall ArgoCD
echo "==> Uninstalling ArgoCD..."
if helm status argocd -n argocd &>/dev/null; then
  helm uninstall argocd -n argocd --wait
fi
if kubectl get namespace argocd &>/dev/null; then
  kubectl delete namespace argocd --timeout=120s
fi

echo; echo "Teardown complete!"
EOF
chmod +x teardown.sh