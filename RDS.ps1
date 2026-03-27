#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Automated deployment of a full RDS Session Host farm.
.DESCRIPTION
    Chains DC creation, VM deployment, domain join, and RDS role configuration
    (Connection Broker, Web Access, Session Hosts, Gateway, Licensing).
#>

param(
    [string]   $DCName       = $null,
    [string]   $DomainName   = $null,
    [string]   $DCOS         = $null,
    [string[]] $VMNames      = $null,
    [string]   $MemberOS     = $null,
    [string]   $CBName       = $null,
    [string[]] $SHNames      = $null,
    [string]   $WAName       = $null,
    [string[]] $LicNames     = $null,
    [string[]] $GWNames      = $null,
    [string]   $DomainAdmin  = "Administrator",
    [string]   $DomainInitCode = ""
)

# ─── Transcript ───────────────────────────────────────────────────────────────
$transcriptActive = $false
try { $transcriptActive = $null -ne (Get-Transcript -ErrorAction SilentlyContinue) } catch { }
if (-not $transcriptActive) {
    $timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
    $logsDir   = Join-Path $PSScriptRoot "logs"
    New-Item -ItemType Directory -Path $logsDir -Force | Out-Null
    Start-Transcript -Path (Join-Path $logsDir "RDS_$timestamp.txt") -Append
}

function Stop-Safe { if (-not $transcriptActive) { try { Stop-Transcript } catch { } } }
function Exit-Script ([int]$Code = 1) { Stop-Safe; exit $Code }

$currentDir = $PSScriptRoot

# ─── Prompt for missing parameters ───────────────────────────────────────────
if (-not $DCName)    { $DCName    = Read-Host "Enter Domain Controller VM Name" }
if (-not $DomainName){ $DomainName= Read-Host "Enter Domain Name (e.g., corp.local)" }
if (-not $DCOS)      { $DCOS      = Read-Host "Enter OS for Domain Controller" }

if ($null -eq $VMNames) {
    $VMNames = @((Read-Host "Enter all domain member VM names (comma-separated)") -split ',' |
                 ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
}
if (-not $MemberOS) { $MemberOS = Read-Host "Enter OS for all member VMs" }

if (-not $CBName) { $CBName = Read-Host "Enter Connection Broker VM Name" }
if (-not ($VMNames -contains $CBName)) {
    Write-Host "Error: Connection Broker '$CBName' is not in the member VM list." -ForegroundColor Red
    Exit-Script 1
}

if ($null -eq $SHNames) {
    $SHNames = @((Read-Host "Enter Session Host VM Names (comma-separated)") -split ',' |
                 ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
}
foreach ($sh in $SHNames) {
    if (-not ($VMNames -contains $sh)) {
        Write-Host "Error: Session Host '$sh' is not in the member VM list." -ForegroundColor Red
        Exit-Script 1
    }
}

if (-not $WAName) { $WAName = Read-Host "Enter RD Web Access VM Name" }
if (-not ($VMNames -contains $WAName)) {
    Write-Host "Error: Web Access VM '$WAName' is not in the member VM list." -ForegroundColor Red
    Exit-Script 1
}

if ($null -eq $LicNames) {
    $LicNames = @((Read-Host "Enter RD Licensing VM Names (comma-separated)") -split ',' |
                  ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
}
foreach ($lic in $LicNames) {
    if (-not ($VMNames -contains $lic)) {
        Write-Host "Error: Licensing VM '$lic' is not in the member VM list." -ForegroundColor Red
        Exit-Script 1
    }
}

if ($null -eq $GWNames) {
    $GWNames = @((Read-Host "Enter RD Gateway VM Names (comma-separated)") -split ',' |
                 ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
}
foreach ($gw in $GWNames) {
    if (-not ($VMNames -contains $gw)) {
        Write-Host "Error: Gateway VM '$gw' is not in the member VM list." -ForegroundColor Red
        Exit-Script 1
    }
}

# ─── Credentials ──────────────────────────────────────────────────────────────
$seedPath = Join-Path $currentDir "sys_bootstrap.ini"
if ([string]::IsNullOrWhiteSpace($DomainInitCode)) {
    if (-not (Test-Path $seedPath)) {
        Write-Error "sys_bootstrap.ini not found."
        Exit-Script 1
    }
    $DomainInitCode = (Get-Content -Path $seedPath | Select-Object -First 1).Trim()
    if ([string]::IsNullOrWhiteSpace($DomainInitCode)) {
        Write-Error "sys_bootstrap.ini is empty."
        Exit-Script 1
    }
}
$secureCode      = ConvertTo-SecureString $DomainInitCode -AsPlainText -Force
$domainAdminCred = New-Object System.Management.Automation.PSCredential ("$DomainName\$DomainAdmin", $secureCode)

# ─── Step 1: Domain Controller ────────────────────────────────────────────────
Write-Host "`nCreating Domain Controller '$DCName'..." -ForegroundColor Cyan
& (Join-Path $currentDir "createDC.ps1") -OS $DCOS -VMName $DCName -DomainName $DomainName
if ($LASTEXITCODE -ne 0) { Write-Error "createDC.ps1 failed."; Exit-Script 1 }

# ─── Step 2: Member VMs ───────────────────────────────────────────────────────
$VMListString = $VMNames -join ','
Write-Host "`nDeploying member VMs: $VMListString (OS: $MemberOS)..." -ForegroundColor Cyan
& (Join-Path $currentDir "deploy.ps1") -VMName $VMListString -OS $MemberOS
if ($LASTEXITCODE -ne 0) { Write-Error "deploy.ps1 failed."; Exit-Script 1 }

Write-Host "`nWaiting 2 minutes for all VMs to initialise..." -ForegroundColor Cyan
Start-Sleep -Seconds 120

# ─── Step 3: Domain Join ──────────────────────────────────────────────────────
# BUG FIX: The original built $AllVMsToJoin but the logic was wrong — if CBName
# was already in $VMNames the result was just $VMNames, but it used array +
# string concatenation which can produce unexpected results in PowerShell.
# Use Select-Object -Unique on a clean array instead.
$allToJoin = ($VMNames + @($CBName) | Select-Object -Unique) -join ','
Write-Host "`nJoining all VMs to domain '$DomainName'..." -ForegroundColor Cyan
& (Join-Path $currentDir "joindomain.ps1") `
    -DcVmName $DCName -DomainToJoin $DomainName -VmNames $allToJoin
if ($LASTEXITCODE -ne 0) { Write-Error "joindomain.ps1 failed."; Exit-Script 1 }

# Allow AD services to fully start on all domain members before attempting RDS deployment
Write-Host "`nWaiting 60 s for domain services to stabilise on all VMs..." -ForegroundColor Cyan
Start-Sleep -Seconds 60

# ─── Step 4: RDS Session Deployment ──────────────────────────────────────────
$CBFQDN  = "$CBName.$DomainName"
$WAFQDN  = "$WAName.$DomainName"
$SHFQDNs = $SHNames | ForEach-Object { "$_.$DomainName" }

Write-Host "`nCreating RDS Session Deployment..." -ForegroundColor Cyan
# BUG FIX: New-RDSessionDeployment must be invoked on the Connection Broker, not
# the DC. The original ran it on $DCName which would fail unless the DC also had
# the RDS role. Changed to run on $CBName (which is the CB itself).
try {
    Invoke-Command -VMName $CBName -Credential $domainAdminCred -ErrorAction Stop -ScriptBlock {
        param($cb, $wa, $shs)
        Import-Module RemoteDesktop -ErrorAction Stop
        New-RDSessionDeployment -ConnectionBroker $cb -WebAccessServer $wa -SessionHost $shs
    } -ArgumentList $CBFQDN, $WAFQDN, $SHFQDNs
} catch {
    Write-Error "New-RDSessionDeployment failed: $_"
    Exit-Script 1
}

# ─── Step 5: Add Gateway roles ────────────────────────────────────────────────
foreach ($gw in $GWNames) {
    $gwFQDN = "$gw.$DomainName"
    Write-Host "`nAdding RD Gateway role: $gwFQDN..." -ForegroundColor Cyan
    try {
        Invoke-Command -VMName $CBName -Credential $domainAdminCred -ErrorAction Stop -ScriptBlock {
            param($fqdn)
            Import-Module RemoteDesktop -ErrorAction Stop
            Add-RDServer -Server $fqdn -Role 'RDS-GATEWAY' -GatewayExternalFqdn $fqdn
        } -ArgumentList $gwFQDN
    } catch {
        Write-Warning "Failed to add Gateway '$gwFQDN': $_"
    }
}

# ─── Step 6: Add Licensing roles ──────────────────────────────────────────────
foreach ($lic in $LicNames) {
    $licFQDN = "$lic.$DomainName"
    Write-Host "`nAdding RD Licensing role: $licFQDN..." -ForegroundColor Cyan
    try {
        Invoke-Command -VMName $CBName -Credential $domainAdminCred -ErrorAction Stop -ScriptBlock {
            param($fqdn)
            Import-Module RemoteDesktop -ErrorAction Stop
            Add-RDServer -Server $fqdn -Role 'RDS-LICENSING'
        } -ArgumentList $licFQDN
    } catch {
        Write-Warning "Failed to add Licensing '$licFQDN': $_"
    }
}

Write-Host "`nRDS deployment completed successfully." -ForegroundColor Green
Exit-Script 0
