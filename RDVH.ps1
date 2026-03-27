#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Automated deployment of an RDS Virtual Desktop Infrastructure (VDI) farm.
.DESCRIPTION
    Chains DC creation, VM deployment, domain join, nested-virtualisation setup,
    Hyper-V role install inside RDVH guests, and RDS VDI role configuration.
#>

param(
    [string]   $DCName         = $null,
    [string]   $DomainName     = $null,
    [string]   $DCOS           = $null,
    [string[]] $VMNames        = $null,
    [string]   $MemberOS       = $null,
    [string]   $CBName         = $null,
    [string[]] $VHNames        = $null,
    [string]   $WAName         = $null,
    [string[]] $LicNames       = $null,
    [string[]] $GWNames        = $null,
    [string]   $DomainAdmin    = "Administrator",
    [string]   $DomainInitCode = ""
)

# ─── Transcript ───────────────────────────────────────────────────────────────
$transcriptActive = $false
try { $transcriptActive = $null -ne (Get-Transcript -ErrorAction SilentlyContinue) } catch { }
if (-not $transcriptActive) {
    $timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
    $logsDir   = Join-Path $PSScriptRoot "logs"
    New-Item -ItemType Directory -Path $logsDir -Force | Out-Null
    Start-Transcript -Path (Join-Path $logsDir "RDS_VDI_$timestamp.txt") -Append
}

function Stop-Safe { if (-not $transcriptActive) { try { Stop-Transcript } catch { } } }
function Exit-Script ([int]$Code = 1) { 
    Write-ReplayCommand
    Stop-Safe
    exit $Code 
}

function Write-ReplayCommand {
    Write-Host "`n" -ForegroundColor Cyan
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host "  REPLAY COMMAND (copy-paste to rerun)" -ForegroundColor Cyan
    Write-Host "==========================================" -ForegroundColor Cyan
    
    $vmNamesStr = $VMNames -join ','
    $vhNamesStr = $VHNames -join ','
    $licNamesStr = $LicNames -join ','
    $gwNamesStr = $GWNames -join ','
    
    $cmd = "& '$($MyInvocation.ScriptName)'"
    $cmd += " -DCName '$DCName'"
    $cmd += " -DomainName '$DomainName'"
    $cmd += " -DCOS '$DCOS'"
    $cmd += " -VMNames '$vmNamesStr'"
    $cmd += " -MemberOS '$MemberOS'"
    $cmd += " -CBName '$CBName'"
    $cmd += " -VHNames '$vhNamesStr'"
    $cmd += " -WAName '$WAName'"
    $cmd += " -LicNames '$licNamesStr'"
    $cmd += " -GWNames '$gwNamesStr'"
    
    Write-Host $cmd -ForegroundColor Yellow
    Write-Host "`n" -ForegroundColor Cyan
}

$currentDir = $PSScriptRoot

# ─── Prompt for missing parameters ───────────────────────────────────────────
if (-not $DCName)    { $DCName     = Read-Host "Enter Domain Controller VM Name" }
if (-not $DomainName){ $DomainName = Read-Host "Enter Domain Name (e.g., corp.local)" }
if (-not $DCOS)      { $DCOS       = Read-Host "Enter OS for Domain Controller" }

if ($null -eq $VMNames) {
    $VMNames = @((Read-Host "Enter all domain member VM names (comma-separated)") -split ',' |
                 ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
} else {
    # Convert comma-separated string parameter to array
    $VMNames = @($VMNames -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
}
if (-not $MemberOS) { $MemberOS = Read-Host "Enter OS for all member VMs" }

if (-not $CBName) { $CBName = Read-Host "Enter Connection Broker VM Name" }
if (-not ($VMNames -contains $CBName)) {
    Write-Host "Error: Connection Broker '$CBName' is not in the member VM list." -ForegroundColor Red
    Exit-Script 1
}

if ($null -eq $VHNames) {
    $VHNames = @((Read-Host "Enter RD Virtualization Host VM Names (comma-separated)") -split ',' |
                 ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
} else {
    # Convert comma-separated string parameter to array
    $VHNames = @($VHNames -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
}
foreach ($vh in $VHNames) {
    if (-not ($VMNames -contains $vh)) {
        Write-Host "Error: Virtualization Host '$vh' is not in the member VM list." -ForegroundColor Red
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
} else {
    # Convert comma-separated string parameter to array
    $LicNames = @($LicNames -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
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
} else {
    # Convert comma-separated string parameter to array
    $GWNames = @($GWNames -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
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
    if (-not (Test-Path $seedPath)) { Write-Error "sys_bootstrap.ini not found."; Exit-Script 1 }
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

# VMs are already verified reachable and hostname-correct by deploy.ps1
# No additional initialization wait needed

# ─── Step 3: Domain Join ──────────────────────────────────────────────────────
$allToJoin = ($VMNames + @($CBName) | Select-Object -Unique) -join ','
Write-Host "`nJoining all VMs to domain '$DomainName'..." -ForegroundColor Cyan
& (Join-Path $currentDir "joindomain.ps1") `
    -DcVmName $DCName -DomainToJoin $DomainName -VmNames $allToJoin
if ($LASTEXITCODE -ne 0) { Write-Error "joindomain.ps1 failed."; Exit-Script 1 }

# Allow AD services to stabilise before proceeding with nested-virt setup
Write-Host "`nWaiting 60 s for domain services to stabilise on all VMs..." -ForegroundColor Cyan
Start-Sleep -Seconds 60

# ─── Step 4: Enable Nested Virtualisation on RDVH VMs (host-side) ─────────────
Write-Host "`n[Pre-RDS] Enabling nested virtualisation on RDVH VMs..." -ForegroundColor Cyan
foreach ($vh in $VHNames) {
    Write-Host "  -> Processing: '$vh'..." -ForegroundColor Cyan
    try {
        $vmObj = Get-VM -Name $vh -ErrorAction Stop
        $wasRunning = $vmObj.State -eq 'Running'

        if ($wasRunning) {
            Write-Host "     Stopping '$vh' to apply processor setting..."
            Stop-VM -Name $vh -Force -ErrorAction Stop
            # BUG FIX: Wait until the VM actually reaches the Off state rather than
            # sleeping a fixed 15 s (which may be insufficient on slow storage).
            $stopTimeout = (Get-Date).AddMinutes(2)
            while ((Get-VM -Name $vh).State -ne 'Off') {
                if ((Get-Date) -gt $stopTimeout) {
                    throw "Timed out waiting for '$vh' to stop."
                }
                Start-Sleep -Seconds 3
            }
        }

        Set-VMProcessor -VMName $vh -ExposeVirtualizationExtensions $true -ErrorAction Stop
        Write-Host "     Nested virtualisation enabled." -ForegroundColor Green

        if ($wasRunning) {
            Start-VM -Name $vh -ErrorAction Stop
            # BUG FIX: Similarly wait for the VM to reach Running before continuing.
            $startTimeout = (Get-Date).AddMinutes(2)
            while ((Get-VM -Name $vh).State -ne 'Running') {
                if ((Get-Date) -gt $startTimeout) {
                    throw "Timed out waiting for '$vh' to start."
                }
                Start-Sleep -Seconds 3
            }
            Write-Host "     '$vh' is running again." -ForegroundColor Green
        }
    } catch {
        Write-Error "Failed to enable nested virtualisation on '$vh': $_"
        Exit-Script 1
    }
}

Write-Host "`n[Pre-RDS] Waiting 60 s for RDVH VMs to fully boot..." -ForegroundColor Cyan
Start-Sleep -Seconds 60

# ─── Step 5: Install Hyper-V inside each RDVH guest ──────────────────────────
Write-Host "`n[Pre-RDS] Installing Hyper-V role inside RDVH guests..." -ForegroundColor Cyan
foreach ($vh in $VHNames) {
    Write-Host "  -> Installing Hyper-V on '$vh'..." -ForegroundColor Cyan
    try {
        Invoke-Command -VMName $vh -Credential $domainAdminCred -ErrorAction Stop -ScriptBlock {
            $feature = Get-WindowsFeature -Name Hyper-V
            if ($feature.InstallState -ne 'Installed') {
                # BUG FIX: Install-WindowsFeature -Restart inside PS Direct reboots
                # the guest and abruptly kills the session, which PowerShell reports as
                # an error. Install without -Restart and reboot manually so the caller can handle it.
                $result = Install-WindowsFeature -Name Hyper-V -IncludeManagementTools `
                                                 -ErrorAction Stop
                if (-not $result.Success) { throw "Hyper-V feature install failed." }
                Restart-Computer -Force
            } else {
                Write-Host "     Hyper-V already installed."
            }
        }
    } catch {
        $exType = $_.Exception.GetType().Name
        $exMsg  = $_.Exception.Message
        $isExpectedDisconnect =
            ($exType -match 'PSRemotingTransportException|PipelineStoppedException') -or
            ($exMsg  -match 'The pipeline has been stopped|connection.*closed|virtual machine.*turned off')
        if (-not $isExpectedDisconnect) {
            Write-Error "Failed to install Hyper-V on '$vh': $_"
            Exit-Script 1
        }
        Write-Host "     '$vh' rebooting after Hyper-V install (expected)." -ForegroundColor Yellow
    }
}

Write-Host "`n[Pre-RDS] Waiting 90 s for RDVH guests to reboot..." -ForegroundColor Cyan
Start-Sleep -Seconds 90

# ─── Step 6: RDS VDI Deployment ───────────────────────────────────────────────
$CBFQDN  = "$CBName.$DomainName"
$WAFQDN  = "$WAName.$DomainName"
$VHFQDNs = $VHNames | ForEach-Object { "$_.$DomainName" }

Write-Host "`nCreating RDS Virtual Desktop Deployment..." -ForegroundColor Cyan
# BUG FIX: Same issue as RDS.ps1 — run this on the CB, not the DC.
try {
    Invoke-Command -VMName $CBName -Credential $domainAdminCred -ErrorAction Stop -ScriptBlock {
        param($cb, $wa, $vhs)
        Import-Module RemoteDesktop -ErrorAction Stop
        New-RDVirtualDesktopDeployment `
            -ConnectionBroker    $cb  `
            -WebAccessServer     $wa  `
            -VirtualizationHost  $vhs
    } -ArgumentList $CBFQDN, $WAFQDN, $VHFQDNs
} catch {
    Write-Error "New-RDVirtualDesktopDeployment failed: $_"
    Exit-Script 1
}

# ─── Step 7: Gateway roles ────────────────────────────────────────────────────
foreach ($gw in $GWNames) {
    $gwFQDN = "$gw.$DomainName"
    Write-Host "`nAdding RD Gateway role: $gwFQDN..." -ForegroundColor Cyan
    try {
        Invoke-Command -VMName $CBName -Credential $domainAdminCred -ErrorAction Stop -ScriptBlock {
            param($fqdn)
            Import-Module RemoteDesktop -ErrorAction Stop
            Add-RDServer -Server $fqdn -Role 'RDS-GATEWAY' -GatewayExternalFqdn $fqdn
        } -ArgumentList $gwFQDN
    } catch { Write-Warning "Failed to add Gateway '$gwFQDN': $_" }
}

# ─── Step 8: Licensing roles ──────────────────────────────────────────────────
foreach ($lic in $LicNames) {
    $licFQDN = "$lic.$DomainName"
    Write-Host "`nAdding RD Licensing role: $licFQDN..." -ForegroundColor Cyan
    try {
        Invoke-Command -VMName $CBName -Credential $domainAdminCred -ErrorAction Stop -ScriptBlock {
            param($fqdn)
            Import-Module RemoteDesktop -ErrorAction Stop
            Add-RDServer -Server $fqdn -Role 'RDS-LICENSING'
        } -ArgumentList $licFQDN
    } catch { Write-Warning "Failed to add Licensing '$licFQDN': $_" }
}

Write-Host "`nRDS VDI deployment completed successfully." -ForegroundColor Green
Exit-Script 0
