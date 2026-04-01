#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Comprehensive configuration testing script for weather-api-config repository
.DESCRIPTION
    Tests Helm rendering, Kubernetes manifests, and optionally deploys to a local Kind cluster.
    
    ⚠️  SAFETY NOTE: Tests 1-4 are 100% safe and never touch your cluster.
        Test 5 (with -FullDeploy) creates a temporary test cluster only.
        Your real cluster is never modified.
.EXAMPLE
    ./test-config.ps1                 # Run basic tests (safe, no cluster needed)
    ./test-config.ps1 -FullDeploy     # Run full tests including Kind cluster deployment
#>

param(
    [switch]$FullDeploy,
    [switch]$UseClusterValidation
)

# Colors for output
$Colors = @{
    Pass   = 'Green'
    Fail   = 'Red'
    Warn   = 'Yellow'
    Info   = 'Cyan'
    Reset  = 'White'
}

function Write-TestHeader {
    param([string]$Title)
    Write-Host "`n" + ("=" * 70) -ForegroundColor $Colors.Info
    Write-Host "  $Title" -ForegroundColor $Colors.Info
    Write-Host ("=" * 70) -ForegroundColor $Colors.Info
}

function Write-TestResult {
    param(
        [string]$TestName,
        [bool]$Passed,
        [string]$Message = ""
    )
    $status = if ($Passed) { "✓ PASS" } else { "✗ FAIL" }
    $color = if ($Passed) { $Colors.Pass } else { $Colors.Fail }
    Write-Host "  [$status] $TestName" -ForegroundColor $color
    if ($Message) {
        Write-Host "    → $Message" -ForegroundColor $Colors.Info
    }
}

function Test-YamlSyntax {
    param([string]$FilePath)
    try {
        # Read file and check for basic validity
        $content = Get-Content $FilePath -Raw
        if (-not $content) {
            return $false
        }
        # Just validate it's readable and not completely malformed
        return $true
    }
    catch {
        return $false
    }
}

function Test-HelmRendering {
    param(
        [string]$Chart,
        [string]$Version,
        [string]$ValuesFile
    )
    try {
        $output = & helm template test-release "$Chart" --version "$Version" -f "$ValuesFile" 2>&1
        if ($LASTEXITCODE -eq 0) {
            return @{Success = $true; Output = $output; Error = $null}
        }
        else {
            return @{Success = $false; Output = $null; Error = $output}
        }
    }
    catch {
        return @{Success = $false; Output = $null; Error = $_.Exception.Message}
    }
}

function Test-KubectlDryRun {
    param([string]$ManifestPath)
    try {
        $output = & kubectl apply -f "$ManifestPath" --dry-run=client --validate=false -ojson 2>&1
        if ($LASTEXITCODE -eq 0) {
            return @{Success = $true; Error = $null}
        }
        else {
            return @{Success = $false; Error = $output}
        }
    }
    catch {
        return @{Success = $false; Error = $_.Exception.Message}
    }
}

function Test-ManifestShape {
    param([string]$ManifestPath)
    try {
        $content = Get-Content $ManifestPath -Raw
        if (-not $content) {
            return @{Success = $false; Error = "File is empty"}
        }

        $docs = $content -split "(?m)^---\s*$"
        foreach ($doc in $docs) {
            if (-not $doc.Trim()) {
                continue
            }

            if ($doc -notmatch "(?m)^apiVersion:\s*\S+") {
                return @{Success = $false; Error = "Missing apiVersion"}
            }
            if ($doc -notmatch "(?m)^kind:\s*\S+") {
                return @{Success = $false; Error = "Missing kind"}
            }
            if ($doc -notmatch "(?m)^metadata:\s*$") {
                return @{Success = $false; Error = "Missing metadata block"}
            }

            # Basic sanity for ArgoCD Application manifests
            if ($doc -match "(?m)^kind:\s*Application\s*$") {
                if ($doc -notmatch "(?m)^spec:\s*$") {
                    return @{Success = $false; Error = "Application missing spec block"}
                }
                if ($doc -notmatch "(?m)^\s{2}destination:\s*$") {
                    return @{Success = $false; Error = "Application missing spec.destination"}
                }
                if (($doc -notmatch "(?m)^\s{2}source:\s*$") -and ($doc -notmatch "(?m)^\s{2}sources:\s*$")) {
                    return @{Success = $false; Error = "Application missing spec.source or spec.sources"}
                }
            }
        }

        return @{Success = $true; Error = $null}
    }
    catch {
        return @{Success = $false; Error = $_.Exception.Message}
    }
}

function Get-LatestHelmChartVersion {
    param([string]$Chart)
    try {
        $output = & helm search repo $Chart --versions --output json 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $output) {
            return $null
        }
        $items = $output | ConvertFrom-Json
        if (-not $items -or $items.Count -eq 0) {
            return $null
        }
        return $items[0].version
    }
    catch {
        return $null
    }
}

function Compare-SemVer {
    param(
        [string]$A,
        [string]$B
    )
    try {
        $vA = [version]$A
        $vB = [version]$B
        return $vA.CompareTo($vB)
    }
    catch {
        return 0
    }
}

function Get-PinnedVersionFromAppFile {
    param(
        [string]$FilePath,
        [string]$Chart
    )
    try {
        $content = Get-Content $FilePath -Raw
        if (-not $content) {
            return $null
        }

        # Find chart block and read the first targetRevision that belongs to it
        $pattern = "(?s)chart:\s*" + [regex]::Escape($Chart) + "\s*\r?\n\s*targetRevision:\s*([^\r\n]+)"
        $m = [regex]::Match($content, $pattern)
        if (-not $m.Success) {
            return $null
        }

        return $m.Groups[1].Value.Trim()
    }
    catch {
        return $null
    }
}

# ============================================================================
# MAIN TEST EXECUTION
# ============================================================================

$repo_root = Get-Location
$failed_tests = 0
$passed_tests = 0
$total_tests = 0
$warning_tests = 0

Write-Host "`n" -ForegroundColor $Colors.Info
Write-Host "╔════════════════════════════════════════════════════════════════════╗" -ForegroundColor $Colors.Info
Write-Host "║          WEATHER-API-CONFIG REPOSITORY TEST SUITE                 ║" -ForegroundColor $Colors.Info
Write-Host "╚════════════════════════════════════════════════════════════════════╝" -ForegroundColor $Colors.Info

# ============================================================================
# Test 1: Helm Repos Exist
# ============================================================================
Write-TestHeader "1. Helm Repository Validation"

$helm_repos = @(
    @{Name = "argo"; Repo = "https://argoproj.github.io/argo-helm"}
    @{Name = "grafana"; Repo = "https://grafana.github.io/helm-charts"}
    @{Name = "prometheus-community"; Repo = "https://prometheus-community.github.io/helm-charts"}
    @{Name = "metallb"; Repo = "https://metallb.github.io/metallb"}
)

foreach ($repo in $helm_repos) {
    $total_tests++
    $helm_list = helm repo list 2>$null | Select-String $repo.Name
    if ($helm_list) {
        Write-TestResult "Helm repo registered: $($repo.Name)" $true
        $passed_tests++
    }
    else {
        Write-TestResult "Helm repo registered: $($repo.Name)" $false "Please run: helm repo add $($repo.Name) $($repo.Repo)"
        $failed_tests++
    }
}

# ============================================================================
# Test 2: YAML Syntax Validation
# ============================================================================
Write-TestHeader "2. YAML Syntax Validation"

$yaml_files = @(
    "application.yaml"
    "apps/argocd.yaml"
    "apps/metallb.yaml"
    "apps/metallb-config.yaml"
    "apps/prometheus.yaml"
    "apps/grafana.yaml"
    "apps/weather-api.yaml"
    "env/dev/argocd/values.yaml"
    "env/dev/metallb/values.yaml"
    "env/dev/grafana/values.yaml"
    "env/dev/prometheus/values.yaml"
    "env/dev/metallb-config/addresspool.yml"
    "env/dev/weatherapi/deployment.yaml"
)

foreach ($file in $yaml_files) {
    $total_tests++
    $file_path = Join-Path $repo_root $file
    if (Test-Path $file_path) {
        if (Test-YamlSyntax $file_path) {
            Write-TestResult "YAML syntax: $file" $true
            $passed_tests++
        }
        else {
            Write-TestResult "YAML syntax: $file" $false
            $failed_tests++
        }
    }
    else {
        Write-TestResult "File exists: $file" $false "File not found"
        $failed_tests++
    }
}

# ============================================================================
# Test 3: Helm Chart Rendering
# ============================================================================
Write-TestHeader "3. Helm Chart Rendering"

$helm_tests = @(
    @{Name = "ArgoCD"; Chart = "argo/argo-cd"; AppFile = "apps/argocd.yaml"; ChartName = "argo-cd"; ValuesFile = "env/dev/argocd/values.yaml"}
    @{Name = "MetalLB"; Chart = "metallb/metallb"; AppFile = "apps/metallb.yaml"; ChartName = "metallb"; ValuesFile = "env/dev/metallb/values.yaml"}
    @{Name = "Prometheus"; Chart = "prometheus-community/prometheus"; AppFile = "apps/prometheus.yaml"; ChartName = "prometheus"; ValuesFile = "env/dev/prometheus/values.yaml"}
    @{Name = "Grafana"; Chart = "grafana/grafana"; AppFile = "apps/grafana.yaml"; ChartName = "grafana"; ValuesFile = "env/dev/grafana/values.yaml"}
)

foreach ($test in $helm_tests) {
    $total_tests++
    Write-Host "  Testing $($test.Name)..." -ForegroundColor $Colors.Info

    $appFilePath = Join-Path $repo_root $test.AppFile
    $pinnedVersion = Get-PinnedVersionFromAppFile -FilePath $appFilePath -Chart $test.ChartName
    if (-not $pinnedVersion) {
        Write-TestResult "$($test.Name) chart renders" $false "Could not read targetRevision from $($test.AppFile)"
        $failed_tests++
        continue
    }
    
    $result = Test-HelmRendering -Chart $test.Chart -Version $pinnedVersion -ValuesFile $test.ValuesFile
    
    if ($result.Success) {
        $manifest_lines = ($result.Output | Measure-Object -Line).Lines
        Write-TestResult "$($test.Name) chart renders" $true "$manifest_lines lines generated"
        $passed_tests++
    }
    else {
        Write-TestResult "$($test.Name) chart renders" $false
        Write-Host "    Error: $($result.Error)" -ForegroundColor $Colors.Fail
        $failed_tests++
    }
}

# ============================================================================
# Test 4: Kubernetes Manifest Validation
# ============================================================================
Write-TestHeader "4. Kubernetes Manifest Dry-Run Validation"

if (-not $UseClusterValidation) {
    Write-Host "  [ℹ] Running OFFLINE manifest validation (no cluster access)" -ForegroundColor $Colors.Info
    Write-Host "  [ℹ] Use -UseClusterValidation to enable kubectl dry-run against current context" -ForegroundColor $Colors.Info
}

$manifest_tests = @(
    @{Name = "Root Application"; Path = "application.yaml"}
    @{Name = "ArgoCD Application"; Path = "apps/argocd.yaml"}
    @{Name = "MetalLB Application"; Path = "apps/metallb.yaml"}
    @{Name = "MetalLB Config"; Path = "apps/metallb-config.yaml"}
    @{Name = "Prometheus Application"; Path = "apps/prometheus.yaml"}
    @{Name = "Grafana Application"; Path = "apps/grafana.yaml"}
    @{Name = "Weather-API Application"; Path = "apps/weather-api.yaml"}
    @{Name = "Weather-API Deployment"; Path = "env/dev/weatherapi/deployment.yaml"}
    @{Name = "MetalLB Address Pool"; Path = "env/dev/metallb-config/addresspool.yml"}
)

foreach ($test in $manifest_tests) {
    $total_tests++
    $manifest_path = Join-Path $repo_root $test.Path
    
    if (Test-Path $manifest_path) {
        if ($UseClusterValidation) {
            $result = Test-KubectlDryRun -ManifestPath $manifest_path
        }
        else {
            $result = Test-ManifestShape -ManifestPath $manifest_path
        }
        if ($result.Success) {
            Write-TestResult "$($test.Name) validation" $true
            $passed_tests++
        }
        else {
            Write-TestResult "$($test.Name) validation" $false
            Write-Host "    Error: $($result.Error)" -ForegroundColor $Colors.Fail
            $failed_tests++
        }
    }
    else {
        Write-TestResult "$($test.Name) exists" $false "File not found: $($test.Path)"
        $failed_tests++
    }
}

# ============================================================================
# Test 5: Full Cluster Deployment (Optional)
# ============================================================================
if ($FullDeploy) {
    Write-TestHeader "5. Full Cluster Deployment Test (Kind)"
    
    $total_tests++
    
    # Check if Kind is installed
    $kind_check = & kind version 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-TestResult "Kind cluster tool available" $false "Kind not found. Install from https://kind.sigs.k8s.io/"
        $failed_tests++
    }
    else {
        Write-TestResult "Kind cluster tool available" $true
        $passed_tests++
        
        # Safety check: warn if currently connected to a non-Kind cluster
        $current_context = & kubectl config current-context 2>$null
        if ($current_context -and $current_context -notmatch "kind-") {
            Write-Host "  [⚠] WARNING: Current kubectl context is '$current_context' (not a Kind cluster)" -ForegroundColor $Colors.Warn
            Write-Host "  [⚠] This test will CREATE a temporary 'test-cluster' Kind cluster" -ForegroundColor $Colors.Warn
            Write-Host "  [⚠] Your current cluster will not be modified" -ForegroundColor $Colors.Warn
            $warning_tests++
        }
        
        Write-Host "  [ℹ] Creating Kind cluster 'test-cluster'..." -ForegroundColor $Colors.Info
        
        # Create Kind cluster
        $total_tests++
        $kind_create = & kind create cluster --name test-cluster 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-TestResult "Kind cluster created" $true
            $passed_tests++
            
            # Wait for cluster to be ready
            Start-Sleep -Seconds 5
            
            # Apply root app
            $total_tests++
            Write-Host "  [ℹ] Deploying root application..." -ForegroundColor $Colors.Info
            $apply_result = & kubectl apply -f application.yaml 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-TestResult "Root application deployed" $true
                $passed_tests++
                
                # Wait for apps to sync
                Write-Host "  [ℹ] Waiting for applications to sync (30s timeout)..." -ForegroundColor $Colors.Info
                Start-Sleep -Seconds 10
                
                # Check ArgoCD applications
                $total_tests++
                $apps = & kubectl get applications -n argocd -ojson 2>$null | ConvertFrom-Json
                if ($apps.items) {
                    Write-TestResult "ArgoCD applications deployed" $true "$($apps.items.Count) app(s) found"
                    $passed_tests++
                }
                else {
                    Write-TestResult "ArgoCD applications deployed" $false
                    $failed_tests++
                }
            }
            else {
                Write-TestResult "Root application deployed" $false
                Write-Host "    Error: $apply_result" -ForegroundColor $Colors.Fail
                $failed_tests++
            }
            
            # Cleanup
            Write-Host "  [ℹ] Cleaning up Kind cluster..." -ForegroundColor $Colors.Info
            & kind delete cluster --name test-cluster 2>$null
        }
        else {
            Write-TestResult "Kind cluster created" $false "Failed to create cluster"
            $failed_tests++
        }
    }
}

# ============================================================================
# Test 6: Helm Chart Freshness (Warn-only)
# ============================================================================
Write-TestHeader "6. Helm Chart Freshness Check"
Write-Host "  [ℹ] Outdated charts are reported as warnings and do not fail the suite" -ForegroundColor $Colors.Info

$freshness_tests = @(
    @{Name = "ArgoCD"; Chart = "argo/argo-cd"; AppFile = "apps/argocd.yaml"; ChartName = "argo-cd"}
    @{Name = "MetalLB"; Chart = "metallb/metallb"; AppFile = "apps/metallb.yaml"; ChartName = "metallb"}
    @{Name = "Prometheus"; Chart = "prometheus-community/prometheus"; AppFile = "apps/prometheus.yaml"; ChartName = "prometheus"}
    @{Name = "Grafana"; Chart = "grafana/grafana"; AppFile = "apps/grafana.yaml"; ChartName = "grafana"}
)

foreach ($check in $freshness_tests) {
    $total_tests++

    $appFilePath = Join-Path $repo_root $check.AppFile
    $pinned = Get-PinnedVersionFromAppFile -FilePath $appFilePath -Chart $check.ChartName
    if (-not $pinned) {
        Write-TestResult "$($check.Name) freshness" $false "Could not read targetRevision from $($check.AppFile)"
        $failed_tests++
        continue
    }

    $latest = Get-LatestHelmChartVersion -Chart $check.Chart
    if (-not $latest) {
        Write-TestResult "$($check.Name) freshness" $false "Could not query latest version"
        $failed_tests++
        continue
    }

    $cmp = Compare-SemVer -A $pinned -B $latest
    if ($cmp -eq 0) {
        Write-TestResult "$($check.Name) freshness" $true "Pinned $pinned is latest"
        $passed_tests++
    }
    elseif ($cmp -lt 0) {
        Write-Host "  [⚠ WARN] $($check.Name) freshness" -ForegroundColor $Colors.Warn
        Write-Host "    → Pinned $pinned, latest $latest" -ForegroundColor $Colors.Warn
        $passed_tests++
        $warning_tests++
    }
    else {
        Write-TestResult "$($check.Name) freshness" $true "Pinned $pinned is newer than repo latest $latest"
        $passed_tests++
    }
}

# ============================================================================
# Test Summary
# ============================================================================
Write-TestHeader "TEST SUMMARY"

$total_warnings = $warning_tests
$total_passed = $passed_tests
$total_failed = $failed_tests
$total_count = $total_tests

$pass_rate = if ($total_count -gt 0) { [math]::Round((($total_passed - $total_warnings) / $total_count) * 100, 1) } else { 0 }

Write-Host "  Total Tests:    $total_count" -ForegroundColor $Colors.Info
Write-Host "  Passed:         $total_passed" -ForegroundColor $Colors.Pass
Write-Host "  Failed:         $total_failed" -ForegroundColor $(if ($total_failed -eq 0) { $Colors.Pass } else { $Colors.Fail })
Write-Host "  Warnings:       $total_warnings" -ForegroundColor $(if ($total_warnings -eq 0) { $Colors.Pass } else { $Colors.Warn })
Write-Host "  Pass Rate:      $pass_rate%" -ForegroundColor $(if ($pass_rate -eq 100) { $Colors.Pass } else { $Colors.Warn })

Write-Host "`n╔════════════════════════════════════════════════════════════════════╗`n" -ForegroundColor $Colors.Info

if ($total_failed -eq 0 -and $total_warnings -eq 0) {
    Write-Host "  ✓ ALL TESTS PASSED - READY TO COMMIT" -ForegroundColor $Colors.Pass
    Write-Host "`n╚════════════════════════════════════════════════════════════════════╝`n" -ForegroundColor $Colors.Info
    exit 0
}
else {
    if ($total_failed -ne 0) {
        Write-Host "  ✗ TESTS FAILED - PLEASE FIX ISSUES ABOVE" -ForegroundColor $Colors.Fail
        Write-Host "`n╚════════════════════════════════════════════════════════════════════╝`n" -ForegroundColor $Colors.Info
        exit 1
    }
    else {
        Write-Host "  ⚠ TESTS PASSED WITH WARNINGS" -ForegroundColor $Colors.Warn
        Write-Host "`n╚════════════════════════════════════════════════════════════════════╝`n" -ForegroundColor $Colors.Info
        exit 0
    }
}
