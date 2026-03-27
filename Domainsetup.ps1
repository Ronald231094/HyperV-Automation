#Requires -RunAsAdministrator
param (
    [string]$DCName,
    [string]$DomainName,
    [string]$DCOS,
    [string]$VMNames,
    [string]$VMOS,
    [string]$JoinDomain
)

# ─── Transcript Safety ────────────────────────────────────────────────────────
$transcriptActive = $false
try { $transcriptActive = $null -ne (Get-Transcript -ErrorAction SilentlyContinue) } catch { }
if (-not $transcriptActive) {
    $timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
    $logsDir   = Join-Path $PSScriptRoot "logs"
    New-Item -ItemType Directory -Path $logsDir -Force | Out-Null
    Start-Transcript -Path (Join-Path $logsDir "Domainsetup_$timestamp.txt") -Append
}

function Stop-Safe { if (-not $transcriptActive) { try { Stop-Transcript } catch { } } }
function Exit-Script ([int]$Code = 1) { Stop-Safe; exit $Code }

# ─── Prompt for missing parameters ───────────────────────────────────────────
if (-not $DCName)     { $DCName     = Read-Host "Enter Domain Controller VM Name" }
if (-not $DomainName) { $DomainName = Read-Host "Enter Domain Name (e.g., corp.local)" }
if (-not $DCOS)       { $DCOS       = Read-Host "Enter OS for Domain Controller (2016, 2019, 2022, 2025)" }
if (-not $VMNames)    { $VMNames    = Read-Host "Enter VM Names (comma-separated, e.g., VM1,VM2)" }
if (-not $VMOS)       { $VMOS       = Read-Host "Enter OS for the VMs (2016, 2019, 2022, 2025)" }

if (-not $JoinDomain) {
    $JoinDomain = (Read-Host "Join VMs to the domain? (yes/no)").Trim().ToLower()
}

# BUG FIX: Normalize variations ("y", "yes", "YES") once here instead of
# relying on -in @('yes','y') which is already correct but this also trims
# any accidental whitespace from interactive input.
$shouldJoin = $JoinDomain -in @('yes', 'y')

# ─── Build retry command (quoted for safe re-execution) ───────────────────────
$retryCmd = ".\Domainsetup.ps1 -DCName `"$DCName`" -DomainName `"$DomainName`" -DCOS `"$DCOS`" -VMNames `"$VMNames`" -VMOS `"$VMOS`" -JoinDomain `"$JoinDomain`""

function Show-RetryMessage ([string]$Stage) {
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Red
    Write-Host " $Stage FAILED"                          -ForegroundColor Red
    Write-Host "========================================" -ForegroundColor Red
    Write-Host "Fix the issue above, then re-run:"       -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  $retryCmd"                             -ForegroundColor Cyan
    Write-Host ""
}

$currentDir = $PSScriptRoot

# ─── Step 1: Deploy Domain Controller ────────────────────────────────────────
Write-Host "`nStarting Domain Controller creation..." -ForegroundColor Cyan
& (Join-Path $currentDir "createDC.ps1") -OS $DCOS -VMName $DCName -DomainName $DomainName
if ($LASTEXITCODE -ne 0) {
    Show-RetryMessage "DC DEPLOYMENT"
    Exit-Script $LASTEXITCODE
}

# ─── Step 2: Deploy member VMs ────────────────────────────────────────────────
# BUG FIX: The original checked "$VMNames.Count -eq 0" — but $VMNames is a
# [string], not an array, so .Count is always 1 for a non-empty string.
# Check IsNullOrWhiteSpace instead.
if ([string]::IsNullOrWhiteSpace($VMNames)) {
    Write-Warning "No member VMs specified. Skipping member VM deployment."
} else {
    Write-Host "`nDeploying member VMs..." -ForegroundColor Cyan
    & (Join-Path $currentDir "deploy.ps1") -VMName $VMNames -OS $VMOS
    if ($LASTEXITCODE -ne 0) {
        Show-RetryMessage "MEMBER VM DEPLOYMENT"
        Exit-Script $LASTEXITCODE
    }
}

# Give VMs time to fully boot before attempting domain join
Write-Host "`nWaiting 60 seconds for VMs to initialise..." -ForegroundColor Cyan
Start-Sleep -Seconds 60

# ─── Step 3: Domain join (optional) ──────────────────────────────────────────
if ($shouldJoin) {
    if ([string]::IsNullOrWhiteSpace($VMNames)) {
        Write-Warning "No member VMs to join. Skipping domain join step."
    } else {
        Write-Host "`nJoining VMs to domain '$DomainName'..." -ForegroundColor Cyan
        & (Join-Path $currentDir "joindomain.ps1") `
            -DcVmName $DCName -DomainToJoin $DomainName -VmNames $VMNames
        if ($LASTEXITCODE -ne 0) {
            Show-RetryMessage "DOMAIN JOIN"
            Exit-Script $LASTEXITCODE
        }
    }
} else {
    Write-Host "`nSkipping domain join (JoinDomain=$JoinDomain)." -ForegroundColor Gray
}

Write-Host ""
Write-Host "Domain setup completed successfully." -ForegroundColor Green
Exit-Script 0
