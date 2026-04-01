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

# ─── Step 1 & 2: Parallel DC and Member VM Deployment via Start-Job ────
# FIX: Start-Job inherits the parent's elevated token, so #Requires -RunAsAdministrator
# in the child scripts is satisfied without needing -Verb RunAs or UAC prompts.
Write-Host "`n=== Starting Parallel VM Deployment ===" -ForegroundColor Cyan
Write-Host "  [1] Domain Controller: $DCName (OS: $DCOS)" -ForegroundColor Yellow
Write-Host "  [2] Member VMs: $VMNames (OS: $VMOS)" -ForegroundColor Yellow

$dcScriptPath     = Join-Path $currentDir "createDC.ps1"
$deployScriptPath = Join-Path $currentDir "deploy.ps1"

if (-not (Test-Path $dcScriptPath)) {
    Write-Error "Child script not found: $dcScriptPath"
    Exit-Script 1
}
if (-not (Test-Path $deployScriptPath)) {
    Write-Error "Child script not found: $deployScriptPath"
    Exit-Script 1
}

Write-Host "`nLaunching parallel deployment jobs..." -ForegroundColor Cyan
Write-Host "  -> Starting DC deployment job..." -ForegroundColor Gray
Write-Host "  -> Starting member VM deployment job..." -ForegroundColor Gray

# DC job
$dcJob = Start-Job -Name "DCDeploy" -ScriptBlock {
    param($script, $os, $vmName, $domainName)
    & $script -OS $os -VMName $vmName -DomainName $domainName
    $LASTEXITCODE
} -ArgumentList $dcScriptPath, $DCOS, $DCName, $DomainName

# Member VM job (only if VMs specified)
if ([string]::IsNullOrWhiteSpace($VMNames)) {
    Write-Warning "No member VMs specified. Deploying DC only."
    $deployJob = $null
} else {
    $deployJob = Start-Job -Name "MemberDeploy" -ScriptBlock {
        param($script, $vmList, $os)
        & $script -VMName $vmList -OS $os
        $LASTEXITCODE
    } -ArgumentList $deployScriptPath, $VMNames, $VMOS
}

# Stream job output live to the transcript
Write-Host "`nWaiting for deployment jobs to complete (streaming output below)..." -ForegroundColor Cyan

$pollInterval = 5   # seconds between output polls
while ($true) {
    # Flush any pending output from both jobs
    if ($dcJob) { $dcJob | Receive-Job | ForEach-Object { Write-Host "  [DC]     $_" } }
    if ($deployJob) { $deployJob | Receive-Job | ForEach-Object { Write-Host "  [MEMBER] $_" } }

    $dcDone     = $null -eq $dcJob  -or $dcJob.State     -in @('Completed','Failed','Stopped')
    $deployDone = $null -eq $deployJob -or $deployJob.State -in @('Completed','Failed','Stopped')

    if ($dcDone -and $deployDone) { break }

    Start-Sleep -Seconds $pollInterval
}

# Final flush after both jobs finish
if ($dcJob) { $dcJob | Receive-Job | ForEach-Object { Write-Host "  [DC]     $_" } }
if ($deployJob) { $deployJob | Receive-Job | ForEach-Object { Write-Host "  [MEMBER] $_" } }

# Collect results
$dcJobInfo     = Get-Job -Name "DCDeploy" -ErrorAction SilentlyContinue
$deployJobInfo = Get-Job -Name "MemberDeploy" -ErrorAction SilentlyContinue

$dcSuccess     = $null -eq $dcJobInfo  -or ($dcJobInfo.State -eq 'Completed')
$deploySuccess = $null -eq $deployJobInfo -or ($deployJobInfo.State -eq 'Completed')

Write-Host "`n=== Deployment Results ===" -ForegroundColor Cyan
if ($dcSuccess) {
    Write-Host "  [OK]   Domain Controller deployment completed" -ForegroundColor Green
} else {
    Write-Host "  [FAIL] Domain Controller deployment failed (job state: $($dcJobInfo.State))" -ForegroundColor Red
    Show-RetryMessage "DC DEPLOYMENT"
    Exit-Script 1
}

if ($null -eq $deployJobInfo) {
    Write-Host "  [SKIP] Member VM deployment skipped (no VMs specified)" -ForegroundColor Gray
} elseif ($deploySuccess) {
    Write-Host "  [OK]   Member VM deployment completed" -ForegroundColor Green
} else {
    Write-Host "  [FAIL] Member VM deployment failed (job state: $($deployJobInfo.State))" -ForegroundColor Red
    Show-RetryMessage "MEMBER VM DEPLOYMENT"
    Exit-Script 1
}

# Clean up job objects
Remove-Job -Name "DCDeploy","MemberDeploy" -Force -ErrorAction SilentlyContinue

Write-Host "`nAll VMs deployed successfully via parallel jobs." -ForegroundColor Green

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
