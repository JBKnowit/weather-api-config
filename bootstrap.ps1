#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Bootstrap ArgoCD and the App-of-Apps root application.
.DESCRIPTION
    Installs ArgoCD via Helm into the cluster, then applies the root Application
    which triggers ArgoCD to manage everything else (including itself).
.EXAMPLE
    ./bootstrap.ps1              # Bootstrap using dev values (default)
    ./bootstrap.ps1 -Env prod    # Bootstrap using prod values
#>

param(
    [string]$Env = "dev"
)

$ErrorActionPreference = "Stop"

$valuesFile = "env/$Env/argocd/values.yaml"
if (-not (Test-Path $valuesFile)) {
    Write-Error "Values file not found: $valuesFile"
    exit 1
}

Write-Host "==> Adding ArgoCD Helm repo..." -ForegroundColor Cyan
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

Write-Host "==> Installing ArgoCD via Helm..." -ForegroundColor Cyan
helm install argocd argo/argo-cd `
    --namespace argocd `
    --create-namespace `
    --version 9.4.17 `
    -f $valuesFile `
    --wait

Write-Host "==> Applying root App-of-Apps..." -ForegroundColor Cyan
kubectl apply -f application.yaml

Write-Host ""
Write-Host "Bootstrap complete!" -ForegroundColor Green
Write-Host "ArgoCD will now manage all applications defined in apps/."
Write-Host ""
Write-Host "To access the ArgoCD UI:" -ForegroundColor Cyan
Write-Host "  kubectl port-forward svc/argocd-server -n argocd 8080:443"
Write-Host "  Username: admin"
Write-Host "  Password: kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath='{.data.password}' | base64 -d"
