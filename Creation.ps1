#Requires -Version 5.1
<#
.SYNOPSIS
    Hyper-V Automation Lab Suite v3.0 "Enterprise-Ready" - Self-Extracting Installer

.DESCRIPTION
    Run this single script to write every file in the Hyper-V Lab Suite into the
    current directory, just like a `git clone` / GitHub pull experience.

    Files written:
      cleanup.ps1, createDC.ps1, deploy.ps1, DHCP.ps1, Domainsetup.ps1, joindomain.ps1, RDS.ps1, RDVH.ps1, switch.ps1, Guidance.txt, readme.txt, Walkthrough.md

.EXAMPLE
    .\Creation.ps1
    # All suite files are extracted to the current folder.

.NOTES
    Version : 3.0
    Build   : 2026.04.03
    Rebuilt : 2026-04-03 15:10:50
    Encoding: UTF-8 (no BOM) - compatible with all PowerShell consoles
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$targetDir = $PSScriptRoot
if (-not $targetDir) { $targetDir = (Get-Location).Path }

Write-Host ""
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "  Hyper-V Lab Suite v3.0 - Self-Extractor  " -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "  Target directory: $targetDir"
Write-Host ""

$written  = 0
$skipped  = 0
$errors   = 0

function Write-SuiteFile {
    param(
        [string]$FileName,
        [string]$Content
    )

    $dest = Join-Path $targetDir $FileName
    $exists = Test-Path $dest

    try {
        # Write with UTF-8 encoding, no BOM (overwrites if already present)
        [System.IO.File]::WriteAllText($dest, $Content, [System.Text.UTF8Encoding]::new($false))
        if ($exists) {
            Write-Host "  [OVER]  $FileName  (overwritten)" -ForegroundColor Cyan
            $script:skipped++
        } else {
            Write-Host "  [NEW]   $FileName" -ForegroundColor Green
        }
        $script:written++
    }
    catch {
        Write-Host "  [ERR]   $FileName  -> $_" -ForegroundColor Red
        $script:errors++
    }
}

# ---------------------------------------------------------------------------
# FILE: cleanup.ps1
# ---------------------------------------------------------------------------
Write-SuiteFile -FileName 'cleanup.ps1' -Content @'
#Requires -RunAsAdministrator
# ─── Transcript Safety ────────────────────────────────────────────────────────
$transcriptActive = $false
try { $transcriptActive = $null -ne (Get-Transcript -ErrorAction SilentlyContinue) } catch { }
if (-not $transcriptActive) {
    $timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
    $logsDir   = Join-Path $PSScriptRoot "logs"
    New-Item -ItemType Directory -Path $logsDir -Force | Out-Null
    Start-Transcript -Path (Join-Path $logsDir "cleanup_$timestamp.txt") -Append
}

function Stop-Safe { if (-not $transcriptActive) { try { Stop-Transcript } catch { } } }

# ─── Fetch registered VM names safely ────────────────────────────────────────
try {
    $vmNames = @(Get-VM -ErrorAction Stop | Select-Object -ExpandProperty Name)
} catch {
    Write-Warning "Failed to query Hyper-V VMs. Aborting to prevent accidental data loss."
    Write-Warning "Error: $_"
    Stop-Safe; exit 1
}

if ($vmNames.Count -eq 0) {
    Write-Warning "No VMs found in Hyper-V. Skipping cleanup to avoid deleting all VM folders."
    Stop-Safe; exit 0
}

# ─── Check each storage path ──────────────────────────────────────────────────
# Resolve paths relative to the script's own location, not the caller's CWD.
$basePaths = @(
    (Join-Path $PSScriptRoot "hyperv"),
    (Join-Path $PSScriptRoot "VM")
)

foreach ($basePath in $basePaths) {
    Write-Host "`nChecking: $basePath" -ForegroundColor Cyan

    if (-not (Test-Path $basePath)) {
        Write-Host "  -> Path does not exist. Skipping." -ForegroundColor Gray
        continue
    }

    $folders = @(Get-ChildItem -Path $basePath -Directory -ErrorAction SilentlyContinue |
                 Select-Object -ExpandProperty Name)

    if ($folders.Count -eq 0) {
        Write-Host "  -> No subfolders found." -ForegroundColor Gray
        continue
    }

    $orphaned = $folders | Where-Object { $vmNames -notcontains $_ }

    if ($orphaned.Count -eq 0) {
        Write-Host "  -> No orphaned folders found." -ForegroundColor Green
        continue
    }

    foreach ($folder in $orphaned) {
        $fullPath = Join-Path $basePath $folder
        Write-Host "  -> Removing orphaned folder: $fullPath" -ForegroundColor Yellow
        try {
            Remove-Item -Path $fullPath -Recurse -Force -ErrorAction Stop
            Write-Host "     Removed." -ForegroundColor DarkGray
        } catch {
            Write-Warning "  Could not remove '$fullPath': $_ (may be in use)"
        }
    }
}

Write-Host "`nCleanup complete." -ForegroundColor Green
Stop-Safe; exit 0

'@

# ---------------------------------------------------------------------------
# FILE: createDC.ps1
# ---------------------------------------------------------------------------
Write-SuiteFile -FileName 'createDC.ps1' -Content @'
#Requires -RunAsAdministrator
# -----------------------------------------------------------------------------
#  Domain Controller Provisioning Engine
# -----------------------------------------------------------------------------

param (
    [Parameter(Mandatory = $true)]
    [ValidateSet("2016","2019","2022","2025")]
    [string]$OS,

    [Parameter(Mandatory = $true)]
    [string]$VMName,

    [Parameter(Mandatory = $true)]
    [string]$DomainName,

    [Parameter(Mandatory = $false)]
    [System.Security.SecureString]$InitCode
)

# ─── Transcript Safety ────────────────────────────────────────────────────────
$transcriptActive = $false
try { $transcriptActive = $null -ne (Get-Transcript -ErrorAction SilentlyContinue) } catch { }
if (-not $transcriptActive) {
    $timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
    $logsDir   = Join-Path $PSScriptRoot "logs"
    New-Item -ItemType Directory -Path $logsDir -Force | Out-Null
    Start-Transcript -Path (Join-Path $logsDir "CreateDC_$timestamp.txt") -Append
}

function Stop-Safe { if (-not $transcriptActive) { try { Stop-Transcript } catch { } } }
function Exit-Script ([int]$Code = 1) { Stop-Safe; exit $Code }

Write-Host "`n=============================================" -ForegroundColor Cyan
Write-Host "  Domain Controller Provisioning"              -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan

# ─── Credentials ──────────────────────────────────────────────────────────────
$currentDir = $PSScriptRoot
$seedPath   = Join-Path $currentDir "sys_bootstrap.ini"

if (-not $InitCode) {
    if (-not (Test-Path $seedPath)) {
        Write-Error "sys_bootstrap.ini not found at: $seedPath"
        Exit-Script 1
    }
    $baseVal = (Get-Content -Path $seedPath | Select-Object -First 1).Trim()
    if ([string]::IsNullOrWhiteSpace($baseVal)) {
        Write-Error "sys_bootstrap.ini is empty. Add your master initialization code first."
        Exit-Script 1
    }
    $InitCode = ConvertTo-SecureString $baseVal -AsPlainText -Force
}
$adminCred = New-Object System.Management.Automation.PSCredential ("Administrator", $InitCode)

# ─── Step 1: Deploy base VM ───────────────────────────────────────────────────
Write-Host "`nStep 1: Deploying base VM..." -ForegroundColor Cyan
& (Join-Path $currentDir "deploy.ps1") -VMName $VMName -OS $OS -InitCode $InitCode
if ($LASTEXITCODE -ne 0) {
    Write-Error "deploy.ps1 failed with exit code $LASTEXITCODE."
    Exit-Script 1
}

# ─── Step 2: Wait for guest IP ────────────────────────────────────────────────
Write-Host "`nStep 2: Waiting for guest IP address (up to 2 minutes)..." -ForegroundColor Cyan
$ip         = $null
$maxRetries = 24   # 24 x 5 s = 2 minutes
$attempt    = 0

while (-not $ip -and $attempt -lt $maxRetries) {
    $attempt++
    try {
        $ip = Invoke-Command -VMName $VMName -Credential $adminCred -ErrorAction Stop -ScriptBlock {
            Get-NetIPAddress -AddressFamily IPv4 |
                Where-Object { $_.IPAddress -notlike '169.*' -and $_.IPAddress -ne '127.0.0.1' } |
                Select-Object -First 1 -ExpandProperty IPAddress
        }
    } catch {
        Write-Host "  -> Attempt $attempt/$maxRetries guest not ready yet. Retrying in 5 s..." -ForegroundColor Yellow
        Start-Sleep -Seconds 5
    }
}

if (-not $ip) {
    Write-Error "Guest did not return a valid IP after 2 minutes. Check integration services and network."
    Exit-Script 1
}
Write-Host "  [OK]  Guest IP: $ip" -ForegroundColor Green

# ─── Step 3: Promote to Domain Controller ────────────────────────────────────
Write-Host "`nStep 3: Promoting to Domain Controller (domain: $DomainName)..." -ForegroundColor Cyan

# BUG FIX: Install-ADDSForest triggers an automatic reboot. The original code
# had no error handling here — any failure (e.g. feature install issue) would
# silently continue. Added try/catch and checked that the command ran at all.
# Also, Install-ADDSForest must be called AFTER Install-WindowsFeature completes
# and the feature is fully available; the original had no intermediate check.
try {
    Invoke-Command -VMName $VMName -Credential $adminCred -ErrorAction Stop -ScriptBlock {
        param($domainName, [System.Security.SecureString]$safeModePassword)

        $feat = Install-WindowsFeature -Name AD-Domain-Services -IncludeManagementTools
        if (-not $feat.Success) {
            throw "Failed to install AD-Domain-Services. Feature install result: $($feat.ExitCode)"
        }

        # Import the module explicitly — it may not auto-load inside PS Direct
        Import-Module ADDSDeployment -ErrorAction Stop

        Install-ADDSForest `
            -DomainName                    $domainName `
            -SafeModeAdministratorPassword $safeModePassword `
            -InstallDns                    `
            -Force                         `
            -NoRebootOnCompletion:$false   # allow the automatic reboot
    } -ArgumentList $DomainName, $InitCode
} catch {
    # After Install-ADDSForest the DC reboots, which breaks the PS Direct pipe.
    # PSRemotingTransportException / pipeline-stopped errors are expected here.
    $exType = $_.Exception.GetType().Name
    $exMsg  = $_.Exception.Message
    $isExpectedDisconnect = ($exType -match 'PSRemotingTransportException|PipelineStoppedException') -or
                            ($exMsg  -match 'The pipeline has been stopped|connection.*closed|virtual machine.*turned off')
    if (-not $isExpectedDisconnect) {
        Write-Error "DC promotion failed unexpectedly: $_"
        Exit-Script 1
    }
    Write-Host "  -> DC is rebooting as part of domain promotion (expected)." -ForegroundColor Yellow
}

# ─── Step 4: Wait for DC to come back up and be AD-ready ─────────────────────
# After Install-ADDSForest the DC reboots. We must wait until:
#   (a) PS Direct can reconnect (guest OS is up), AND
#   (b) the ADWS / Netlogon services are running (AD is functional)
# Without this wait, callers would immediately try to create AD objects or join
# the domain and fail because the DC is still mid-boot.
Write-Host "`nStep 4: Waiting for DC to finish booting and AD services to start..." -ForegroundColor Cyan

# The DC credential after promotion uses the DOMAIN\Administrator account.
# However immediately after reboot the local Administrator account is also valid
# (domain DB is still loading). Start with local then fall back to domain creds.
$domainAdminCred = New-Object System.Management.Automation.PSCredential ("$DomainName\Administrator", $InitCode)
$currentCred = $adminCred

$dcReadyTimeout = (Get-Date).AddMinutes(15)
$dcReady        = $false

while (-not $dcReady -and (Get-Date) -lt $dcReadyTimeout) {
    try {
        $svcStatus = Invoke-Command -VMName $VMName -Credential $currentCred -ErrorAction Stop -ScriptBlock {
            $adws    = Get-Service -Name ADWS -ErrorAction SilentlyContinue
            $netlogon = Get-Service -Name Netlogon -ErrorAction SilentlyContinue
            [PSCustomObject]@{
                ADWSRunning     = ($adws     -and $adws.Status     -eq 'Running')
                NetlogonRunning = ($netlogon -and $netlogon.Status -eq 'Running')
            }
        }

        if ($svcStatus.ADWSRunning -and $svcStatus.NetlogonRunning) {
            $dcReady = $true
            break
        }

        Write-Host "  -> AD services not yet running (ADWS=$($svcStatus.ADWSRunning), Netlogon=$($svcStatus.NetlogonRunning)). Waiting..." -ForegroundColor Yellow
        Start-Sleep -Seconds 15
    } catch {
        if ($currentCred -eq $adminCred) {
            Write-Host "  -> Local admin access not ready, switching to domain credentials and retrying..." -ForegroundColor Yellow
            $currentCred = $domainAdminCred
        } else {
            Write-Host "  -> DC not yet reachable via PS Direct using domain creds. Retrying in 15 s... ($((Get-Date).ToString('HH:mm:ss')) )" -ForegroundColor Yellow
            Start-Sleep -Seconds 15
        }
    }
}

if (-not $dcReady) {
    Write-Error "DC did not become AD-ready within 10 minutes. Check the VM manually."
    Exit-Script 1
}
Write-Host "  [OK]  DC is up and AD services are running." -ForegroundColor Green

Write-Host "`n[SUCCESS] Domain '$DomainName' is live on VM '$VMName'." -ForegroundColor Green
Exit-Script 0

'@

# ---------------------------------------------------------------------------
# FILE: deploy.ps1
# ---------------------------------------------------------------------------
Write-SuiteFile -FileName 'deploy.ps1' -Content @'
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Deploys one or more Hyper-V virtual machines from a golden image.
.DESCRIPTION
    Standardized deployment engine. Copies golden VHDs via parallel robocopy,
    creates and starts Hyper-V VMs. Validates DHCP availability before proceeding.
.PARAMETER VMName
    Mandatory. One or more VM names, comma-separated.
.PARAMETER OS
    Mandatory. OS year: 2016, 2019, 2022, or 2025.
.PARAMETER InitCode
    Optional. Administrator SecureString. Read from sys_bootstrap.ini if omitted.
#>

param (
    [Parameter(Mandatory = $true)]
    [string]$VMName,

    [Parameter(Mandatory = $true)]
    [ValidateSet("2016","2019","2022","2025","11")]
    [string]$OS,

    [Parameter(Mandatory = $false)]
    [System.Security.SecureString]$InitCode,

    # Skip the DHCP availability gate. Used by DHCP.ps1 when deploying the
    # DHCP VM itself — at that point no DHCP server exists yet by definition.
    [Parameter(Mandatory = $false)]
    [switch]$SkipDHCPCheck
)

# ─── Transcript Safety ────────────────────────────────────────────────────────
$transcriptActive = $false
try { $transcriptActive = $null -ne (Get-Transcript -ErrorAction SilentlyContinue) } catch { }
if (-not $transcriptActive) {
    $timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
    $logsDir   = Join-Path $PSScriptRoot "logs"
    New-Item -ItemType Directory -Path $logsDir -Force | Out-Null
    Start-Transcript -Path (Join-Path $logsDir "Deploy_$timestamp.txt") -Append
}

function Stop-Safe { if (-not $transcriptActive) { try { Stop-Transcript } catch { } } }
function Exit-Script ([int]$Code = 1) { Stop-Safe; exit $Code }

Write-Host "`n=============================================" -ForegroundColor Cyan
Write-Host "  VM Deployment Engine" -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan

# ─── Helper: Format-Bytes ─────────────────────────────────────────────────────
function Format-Bytes ([int64]$Bytes) {
    if     ($Bytes -ge 1GB) { "{0:N2} GB" -f ($Bytes / 1GB) }
    elseif ($Bytes -ge 1MB) { "{0:N2} MB" -f ($Bytes / 1MB) }
    elseif ($Bytes -ge 1KB) { "{0:N2} KB" -f ($Bytes / 1KB) }
    else                    { "$Bytes B" }
}

# ─── Pre-flight ───────────────────────────────────────────────────────────────
Write-Host "Running pre-flight checks..." -ForegroundColor Cyan

$currentPrincipal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "  [FAIL] Administrator privileges required." -ForegroundColor Red
    Exit-Script 1
}
if (-not (Get-Module -ListAvailable -Name Hyper-V -ErrorAction SilentlyContinue)) {
    Write-Host "  [FAIL] Hyper-V module not found." -ForegroundColor Red
    Exit-Script 1
}
Write-Host "  [OK]  Pre-flight checks passed." -ForegroundColor Green

# ─── Paths ────────────────────────────────────────────────────────────────────
$currentDir      = $PSScriptRoot
$goldImageFolder = Join-Path $currentDir "goldenImage"
$vmBasePath      = Join-Path $currentDir "hyperv"

# ─── Resolve VM names and image extension early (needed for disk check) ───────
$vmNames = $VMName.Split(",") | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
if ($vmNames.Count -eq 0) {
    Write-Error "No VM names provided."
    Exit-Script 1
}

# BUG FIX: Windows Server 2016 is Gen 2 and uses .vhdx format (win2016_disk.vhdx)
# Original code treated 2016 as Gen 1 (.vhd), causing VHD not found errors.
$fileExt = if ($OS -eq "2025" -or $OS -eq "11" -or $OS -eq "2016") { "vhdx" } else { "vhd" }
$vmGen   = if ($OS -eq "2025" -or $OS -eq "11" -or $OS -eq "2016") { 2 }      else { 1 }

# ─── Locate golden image ──────────────────────────────────────────────────────
if (-not (Test-Path $goldImageFolder)) {
    Write-Error "Golden image folder not found: $goldImageFolder"
    Exit-Script 1
}
if (-not (Test-Path $goldImageFolder -PathType Container)) {
    Write-Error "Golden image path is not a directory: $goldImageFolder"
    Exit-Script 1
}

$goldImages = Get-ChildItem -Path $goldImageFolder -Filter "*${OS}*.$fileExt" -ErrorAction SilentlyContinue
if ($goldImages.Count -eq 0) {
    Write-Error "No golden image found for OS=$OS (.$fileExt) in $goldImageFolder"
    Write-Host "Available files:" -ForegroundColor Yellow
    Get-ChildItem $goldImageFolder -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "  - $($_.Name)" }
    Exit-Script 1
}
$goldImage = $goldImages[0]
if ($goldImages.Count -gt 1) {
    Write-Warning "Multiple golden images found for OS=$OS. Using: $($goldImage.Name)"
}

# ─── Disk space validation ────────────────────────────────────────────────────
Write-Host "Validating disk space..." -ForegroundColor Cyan

# BUG FIX: Substring(0,1) assumes a drive-letter path. Use Split-Path + Get-Item
# to get the root drive regardless of UNC or relative path weirdness.
$vmDriveLetter = (Get-Item $currentDir).PSDrive.Name
$diskSpace     = (Get-PSDrive -Name $vmDriveLetter -ErrorAction SilentlyContinue).Free

if ($null -eq $diskSpace) {
    Write-Warning "Could not determine free disk space. Proceeding without space check."
} else {
    $vhdSize       = $goldImage.Length
    $requiredSpace = [long]($vhdSize * $vmNames.Count * 1.2)   # 20 % buffer
    if ($diskSpace -lt $requiredSpace) {
        Write-Error "Insufficient disk space on ${vmDriveLetter}:"
        Write-Host "  Need: $(Format-Bytes $requiredSpace)" -ForegroundColor Yellow
        Write-Host "  Have: $(Format-Bytes $diskSpace)"     -ForegroundColor Red
        Exit-Script 1
    }
    Write-Host "  [OK]  Sufficient disk space ($(Format-Bytes $diskSpace) free)" -ForegroundColor Green
}

# ─── Read switch configuration ────────────────────────────────────────────────
$switchFile = Join-Path $currentDir "switch.txt"
$switchName = "NATSwitch"
$dhcpStart  = "192.168.1.2"
$dhcpEnd    = "192.168.1.254"
if (Test-Path $switchFile) {
    Get-Content -Path $switchFile | Where-Object { $_ -match '=' } | ForEach-Object {
        $kv = $_ -split '=', 2
        switch ($kv[0].Trim()) {
            "SwitchName" { $switchName = $kv[1].Trim() }
            "DHCPStart"  { $dhcpStart  = $kv[1].Trim() }
            "DHCPEnd"    { $dhcpEnd    = $kv[1].Trim() }
        }
    }
}
Write-Host "Using virtual switch: $switchName"

# ─── DHCP availability check ──────────────────────────────────────────────────
# Skipped when -SkipDHCPCheck is passed (e.g. DHCP.ps1 bootstrapping the DHCP VM).
if ($SkipDHCPCheck) {
    Write-Host "Skipping DHCP availability check (-SkipDHCPCheck specified)." -ForegroundColor Yellow
} else {
    $dhcpAvailable = $false
    Write-Host "Validating DHCP availability..." -ForegroundColor Cyan

    $osCaption = (Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue).Caption
    $hasSM     = [bool](Get-Command -Name Get-WindowsFeature -ErrorAction SilentlyContinue)

    if ($osCaption -match "Server" -and $hasSM) {
        Write-Host "  -> Checking host-based DHCP role..."
        try {
            $dhcpFeat = Get-WindowsFeature -Name DHCP -ErrorAction SilentlyContinue
            if ($dhcpFeat -and $dhcpFeat.Installed) {
                $scope = Get-DhcpServerv4Scope -ErrorAction SilentlyContinue | Where-Object {
                    $_.StartRange.ToString() -eq $dhcpStart -and $_.EndRange.ToString() -eq $dhcpEnd
                }
                if ($scope) {
                    $dhcpAvailable = $true
                    Write-Host "  [OK]  Host DHCP role active with matching scope." -ForegroundColor Green
                }
            }
        } catch { }
    }

    if (-not $dhcpAvailable) {
        Write-Host "  -> Checking for DHCP VM..."
        $dhcpVm = Get-VM -Name "DHCP" -ErrorAction SilentlyContinue
        if ($dhcpVm) {
            if ($dhcpVm.State -ne 'Running') {
                Write-Host "  -> DHCP VM found but not running. Auto-starting..." -ForegroundColor Yellow
                Start-VM -Name "DHCP" -ErrorAction SilentlyContinue
            }
            Write-Host "  -> Waiting up to 60 s for DHCP VM to report an IP..." -ForegroundColor Cyan
            for ($i = 0; $i -lt 12; $i++) {
                # BUG FIX: Re-fetch the VM object each iteration; the IP list is only
                # populated after Integration Services updates the KVP, so using the
                # stale $dhcpVm object always returns empty on the first few polls.
                $ips = (Get-VM -Name "DHCP" -ErrorAction SilentlyContinue).NetworkAdapters.IPAddresses |
                       Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' }
                if ($ips) { $dhcpAvailable = $true; break }
                Start-Sleep -Seconds 5
            }
            if ($dhcpAvailable) {
                Write-Host "  [OK]  DHCP VM is running." -ForegroundColor Green
            } else {
                Write-Warning "DHCP VM did not report an IP within 60 s."
            }
        }
    }

    if (-not $dhcpAvailable) {
        Write-Host ""
        Write-Host "========================================" -ForegroundColor Red
        Write-Host " DHCP SERVICE NOT AVAILABLE"             -ForegroundColor Red
        Write-Host "========================================" -ForegroundColor Red
        Write-Host ""
        Write-Host "VMs require DHCP to obtain IP addresses. Please run one of:" -ForegroundColor Yellow
        Write-Host "  1. .\DHCP.ps1   (Install DHCP on this host)"          -ForegroundColor Cyan
        Write-Host "  2. Deploy a VM named 'DHCP' (VM-based DHCP)"          -ForegroundColor Cyan
        Write-Host ""
        Write-Host "Then retry: .\deploy.ps1 -VMName `"$VMName`" -OS $OS"  -ForegroundColor Cyan
        Write-Host ""
        Exit-Script 1
    }
}

# ─── Credentials ──────────────────────────────────────────────────────────────
if (-not $InitCode) {
    $seedPath = Join-Path $currentDir "sys_bootstrap.ini"
    if (-not (Test-Path $seedPath)) {
        Write-Error "sys_bootstrap.ini not found. Cannot build credentials."
        Exit-Script 1
    }
    $baseVal = (Get-Content -Path $seedPath | Select-Object -First 1).Trim()
    if ([string]::IsNullOrWhiteSpace($baseVal)) {
        Write-Error "sys_bootstrap.ini is empty."
        Exit-Script 1
    }
    $InitCode = ConvertTo-SecureString $baseVal -AsPlainText -Force
}

# Build administrator credentials for guest OS access
$adminCred = New-Object System.Management.Automation.PSCredential ("Administrator", $InitCode)

# ─── Pre-validate: no VM name collisions ──────────────────────────────────────
foreach ($vmName in $vmNames) {
    if (Get-VM -Name $vmName -ErrorAction SilentlyContinue) {
        Write-Error "VM '$vmName' already exists in Hyper-V. Remove it first or use a different name."
        Exit-Script 1
    }
}

# ─── Prepare destination folders ──────────────────────────────────────────────
if (-not (Test-Path $vmBasePath)) {
    New-Item -Path $vmBasePath -ItemType Directory | Out-Null
}

foreach ($vmName in $vmNames) {
    $vmPath = Join-Path $vmBasePath $vmName
    if (Test-Path $vmPath) {
        Write-Warning "Stale folder found: $vmPath (no matching Hyper-V VM). Removing..."
        Remove-Item -Path $vmPath -Recurse -Force -ErrorAction SilentlyContinue
    }
    New-Item -Path $vmPath -ItemType Directory | Out-Null
}

# ─── Parallel robocopy ────────────────────────────────────────────────────────
Write-Host "`nStarting parallel VHD copy for $($vmNames.Count) VM(s)..." -ForegroundColor Cyan

# Diagnostic: Verify golden image and destination paths before starting robocopy
Write-Host "  Golden image source: $($goldImage.DirectoryName)\$($goldImage.Name)" -ForegroundColor Gray
Write-Host "  Golden image size: $(Format-Bytes $goldImage.Length)" -ForegroundColor Gray
if (-not (Test-Path -Path (Join-Path $goldImage.DirectoryName $goldImage.Name))) {
    Write-Error "Golden image file not found: $(Join-Path $goldImage.DirectoryName $goldImage.Name)"
    Exit-Script 1
}

$copyProcesses = @{}
$vmProgress    = @{}

foreach ($vmName in $vmNames) {
    $vmPath = Join-Path $vmBasePath $vmName
    # Use proven robocopy flags from v2.9 (simpler, more reliable)
    $rArgs  = "`"$($goldImage.DirectoryName)`" `"$vmPath`" `"$($goldImage.Name)`" /MT:4 /TEE /BYTES"
    $si     = New-Object System.Diagnostics.ProcessStartInfo
    $si.FileName               = "robocopy.exe"
    $si.Arguments              = $rArgs
    $si.RedirectStandardOutput = $true
    $si.UseShellExecute        = $false
    $si.CreateNoWindow         = $true
    
    try {
        $p = New-Object System.Diagnostics.Process
        $p.StartInfo = $si
        $p.Start() | Out-Null
        $copyProcesses[$vmName] = $p
        $vmProgress[$vmName] = "0%"
    } catch {
        Write-Error "Failed to start robocopy for '$vmName': $_"
        Exit-Script 1
    }
}

# Read output synchronously, line-by-line (proven method from v2.9)
while ($copyProcesses.Values | Where-Object { -not $_.HasExited }) {
    foreach ($vmName in $vmNames) {
        $p = $copyProcesses[$vmName]
        if ($p -and -not $p.HasExited) {
            $line = $p.StandardOutput.ReadLine()
            if ($line -match '\s+(\d+)%') { 
                $vmProgress[$vmName] = "$($matches[1])%" 
            }
        }
    }
    $statusLine = ($vmNames | ForEach-Object { "$_ : $($vmProgress[$_])" }) -join " | "
    Write-Host "`r  $statusLine" -NoNewline
    Start-Sleep -Milliseconds 500
}
Write-Host ""
Write-Host "  [OK]  Disk copy complete." -ForegroundColor Green

# Robocopy exit codes: 0-7 = success/info, 8+ = errors
foreach ($vmName in $vmNames) {
    $exitCode = $copyProcesses[$vmName].ExitCode
    if ($exitCode -gt 7) {
        Write-Error "Robocopy failed for '$vmName' (exit code $exitCode)"
        Write-Host "  Source: $($goldImage.DirectoryName)\$($goldImage.Name)" -ForegroundColor Yellow
        Write-Host "  Dest:   $(Join-Path $vmBasePath $vmName)" -ForegroundColor Yellow
        Exit-Script 1
    }
}

# Rename VHD files to VM-specific names (proven method from v2.9)
foreach ($vmName in $vmNames) {
    $vmPath = Join-Path $vmBasePath $vmName
    $oldPath = Join-Path $vmPath $goldImage.Name
    
    if (Test-Path $oldPath) {
        Rename-Item -Path $oldPath -NewName "$vmName.$fileExt" -ErrorAction Stop
        Write-Host "  -> Renamed VHD: $($goldImage.Name) -> $vmName.$fileExt" -ForegroundColor Green
    }
}

# ─── Create VMs ───────────────────────────────────────────────────────────────
foreach ($vmName in $vmNames) {
    $vmPath = Join-Path $vmBasePath $vmName
    $vhdPath = Join-Path $vmPath "$vmName.$fileExt"

    Write-Host "  -> Instantiating $vmName..." -ForegroundColor Cyan
    try {
        New-VM -Name $vmName -Generation $vmGen -MemoryStartupBytes 2GB `
               -VHDPath $vhdPath -SwitchName $switchName -Path $vmPath | Out-Null
        Set-VMProcessor -VMName $vmName -Count 4
        # Set-VMFirmware only applies to Gen 2 VMs; silently skip for Gen 1.
        if ($vmGen -eq 2) {
            Set-VMFirmware -VMName $vmName -EnableSecureBoot Off -ErrorAction SilentlyContinue
        }
        Start-VM $vmName
        Write-Host "   [OK]  $vmName started." -ForegroundColor Green
    } catch {
        Write-Error "Failed to create or start VM '$vmName': $_"
        Exit-Script 1
    }
}

# ─── Verify and fix computer names in OS ──────────────────────────────────────
Write-Host "`nVerifying computer names in guest OS..." -ForegroundColor Cyan
$hostnameVerified = $false
$maxRetries = 72  # 72 x 15 s = 18 minutes
$retryCount = 0

while (-not $hostnameVerified -and $retryCount -lt $maxRetries) {
    $hostnameVerified = $true
    $retryCount++
    
    foreach ($vmName in $vmNames) {
        try {
            $hostname = Invoke-Command -VMName $vmName -Credential $adminCred -ErrorAction Stop -ScriptBlock { hostname }
            $hostname = $hostname.Trim()
            
            if ($hostname -eq $vmName) {
                Write-Host "  [$vmName] Hostname OK: $hostname" -ForegroundColor Green
            } else {
                Write-Host "  [$vmName] Hostname mismatch: is '$hostname', should be '$vmName'. Renaming..." -ForegroundColor Yellow
                Invoke-Command -VMName $vmName -Credential $adminCred -ErrorAction Stop -ScriptBlock {
                    param($newName)
                    Rename-Computer -NewName $newName -Force -Restart
                } -ArgumentList $vmName
                
                Write-Host "  [$vmName] Restarting (waiting 30 seconds)..." -ForegroundColor Yellow
                Start-Sleep -Seconds 30
                $hostnameVerified = $false
            }
        } catch {
            Write-Host "  [$vmName] Not yet reachable. Retrying... ($retryCount/$maxRetries)" -ForegroundColor Yellow
            $hostnameVerified = $false
        }
    }
    
    if (-not $hostnameVerified -and $retryCount -lt $maxRetries) {
        Start-Sleep -Seconds 15
    }
}

if ($hostnameVerified) {
    Write-Host "`n[OK]  All VM hostnames verified and correct." -ForegroundColor Green
} else {
    Write-Warning "Hostname verification timed out. Some VMs may still be updating."
}

Write-Host "`nDeployment complete for: $($vmNames -join ', ')" -ForegroundColor Green
Exit-Script 0

'@

# ---------------------------------------------------------------------------
# FILE: DHCP.ps1
# ---------------------------------------------------------------------------
Write-SuiteFile -FileName 'DHCP.ps1' -Content @'
#Requires -RunAsAdministrator
# ─── Transcript Safety ────────────────────────────────────────────────────────
$transcriptActive = $false
try { $transcriptActive = $null -ne (Get-Transcript -ErrorAction SilentlyContinue) } catch { }
if (-not $transcriptActive) {
    $timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
    $logsDir   = Join-Path $PSScriptRoot "logs"
    New-Item -ItemType Directory -Path $logsDir -Force | Out-Null
    Start-Transcript -Path (Join-Path $logsDir "DHCP_$timestamp.txt") -Append
}

function Stop-Safe { if (-not $transcriptActive) { try { Stop-Transcript } catch { } } }
function Exit-Script ([int]$Code = 1) { Stop-Safe; exit $Code }

$currentDir = $PSScriptRoot

# ─── Read network config from switch.txt ──────────────────────────────────────
$switchFile = Join-Path $currentDir "switch.txt"
if (Test-Path $switchFile) {
    $switchMap = @{}
    Get-Content -Path $switchFile | Where-Object { $_ -match '=' } | ForEach-Object {
        $kv = $_ -split '=', 2
        $switchMap[$kv[0].Trim()] = $kv[1].Trim()
    }
    $switchName   = $switchMap["SwitchName"]
    $gateway      = $switchMap["Gateway"]
    $networkAddr  = $switchMap["NetworkAddress"]
    $subnetMask   = $switchMap["SubnetMask"]
    $prefixLength = [int]$switchMap["PrefixLength"]
    $dhcpStart    = $switchMap["DHCPStart"]
    $dhcpEnd      = $switchMap["DHCPEnd"]
    Write-Host "Loaded network config: Network=$networkAddr, Gateway=$gateway"
} else {
    Write-Host "No switch.txt found. Using default network values." -ForegroundColor Yellow
    $switchName   = "NATSwitch"
    $gateway      = "192.168.1.1"
    $networkAddr  = "192.168.1.0"
    $subnetMask   = "255.255.255.0"
    $prefixLength = 24
    $dhcpStart    = "192.168.1.2"
    $dhcpEnd      = "192.168.1.254"
}

# ─── Detect host OS type ──────────────────────────────────────────────────────
$osInfo    = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
$isServer  = $osInfo.ProductType -ne 1   # 1 = Workstation; 2 = DC; 3 = Server
$installOnHost = $false

if ($isServer) {
    Write-Host ""
    Write-Host "=========================================="
    Write-Host "  Windows Server detected: $($osInfo.Caption)"
    Write-Host "=========================================="
    Write-Host ""
    Write-Host "  DHCP Scope : $dhcpStart - $dhcpEnd"
    Write-Host "  Gateway    : $gateway"
    Write-Host "  Subnet     : $subnetMask"
    Write-Host ""
    $response = Read-Host "Install DHCP role directly on this host? (Y/N)"
    if ($response -match '^[Yy]$') { $installOnHost = $true }
}

# ─── Option A: Install DHCP on host ───────────────────────────────────────────
if ($installOnHost) {
    Write-Host "`nInstalling DHCP role on local host..." -ForegroundColor Cyan

    try {
        $featResult = Install-WindowsFeature -Name DHCP -IncludeManagementTools -ErrorAction Stop
        if (-not $featResult.Success) {
            Write-Error "DHCP feature install failed."
            Exit-Script 1
        }

        Add-DhcpServerSecurityGroup -ErrorAction SilentlyContinue

        # BUG FIX: "netsh dhcp server init" is deprecated and unreliable on Server 2019+.
        # Use Set-DhcpServerv4Binding to bind the DHCP service to the lab adapter instead.
        $labAdapter = Get-NetIPAddress -IPAddress $gateway -ErrorAction SilentlyContinue
        if ($labAdapter) {
            Set-DhcpServerv4Binding -InterfaceAlias $labAdapter.InterfaceAlias -BindingState $true -ErrorAction SilentlyContinue
        }

        # BUG FIX: Add-DhcpServerv4Scope will throw if the scope already exists.
        # Check first to make this idempotent.
        $existingScope = Get-DhcpServerv4Scope -ErrorAction SilentlyContinue |
                         Where-Object { $_.StartRange.ToString() -eq $dhcpStart }
        if (-not $existingScope) {
            Add-DhcpServerv4Scope -Name "LabScope" `
                                  -StartRange $dhcpStart `
                                  -EndRange   $dhcpEnd `
                                  -SubnetMask $subnetMask `
                                  -State Active -ErrorAction Stop
        } else {
            Write-Host "  -> DHCP scope already exists. Skipping creation." -ForegroundColor Yellow
        }

        Set-DhcpServerv4OptionValue -ScopeId $networkAddr -Router    @($gateway)  -ErrorAction Stop
        Set-DhcpServerv4OptionValue -ScopeId $networkAddr -DnsServer @("8.8.8.8") -ErrorAction Stop

        # Suppress Server Manager post-install notification
        Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\ServerManager\Roles\12" `
                         -Name "ConfigurationState" -Value 2 -ErrorAction SilentlyContinue

        Write-Host ""
        Write-Host "  [OK]  DHCP role installed on host." -ForegroundColor Green
        Write-Host "        Scope  : $dhcpStart - $dhcpEnd"
        Write-Host "        Router : $gateway"
        Write-Host "        DNS    : 8.8.8.8"
    } catch {
        Write-Error "DHCP host installation failed: $_"
        Exit-Script 1
    }

# ─── Option B: Deploy DHCP as a standalone VM ─────────────────────────────────
} else {
    $vmName = "DHCP"

    $osYear = Read-Host "Enter OS year for the DHCP VM (2016, 2019, 2022, 2025)"
    if ($osYear -notin @("2016","2019","2022","2025")) {
        Write-Error "Invalid OS year: $osYear"
        Exit-Script 1
    }

    $seedPath = Join-Path $currentDir "sys_bootstrap.ini"
    if (-not (Test-Path $seedPath)) {
        Write-Error "sys_bootstrap.ini not found."
        Exit-Script 1
    }
    $baseVal = (Get-Content -Path $seedPath | Select-Object -First 1).Trim()
    if ([string]::IsNullOrWhiteSpace($baseVal)) {
        Write-Error "sys_bootstrap.ini is empty."
        Exit-Script 1
    }
    $initStr   = ConvertTo-SecureString $baseVal -AsPlainText -Force
    $adminCred = New-Object System.Management.Automation.PSCredential ("Administrator", $initStr)

    Write-Host "`nDeploying DHCP VM..." -ForegroundColor Cyan
    # -SkipDHCPCheck: we are creating the DHCP VM itself, so no DHCP server
    # exists yet. Without this flag deploy.ps1 would abort at the DHCP gate.
    & (Join-Path $currentDir "deploy.ps1") -VMName $vmName -OS $osYear -InitCode $initStr -SkipDHCPCheck
    if ($LASTEXITCODE -ne 0) {
        Write-Error "deploy.ps1 failed for DHCP VM."
        Exit-Script 1
    }

    # BUG FIX: The original script fired Invoke-Command immediately after deploy.ps1
    # without waiting for the VM to be reachable. Added a boot-wait loop.
    Write-Host "Waiting for DHCP VM to become reachable (up to 2 minutes)..." -ForegroundColor Cyan
    $ready   = $false
    $timeout = (Get-Date).AddMinutes(2)
    while (-not $ready -and (Get-Date) -lt $timeout) {
        try {
            Invoke-Command -VMName $vmName -Credential $adminCred -ErrorAction Stop `
                           -ScriptBlock { $true } | Out-Null
            $ready = $true   # success — exit loop immediately
        } catch {
            Start-Sleep -Seconds 5   # only sleep on genuine failure
        }
    }
    if (-not $ready) {
        Write-Error "DHCP VM did not become reachable within 2 minutes."
        Exit-Script 1
    }

    # ── Phase 1: install feature + set static IP, then reboot ───────────────────
    # ALL DHCP service cmdlets (Add-DhcpServerv4Scope, Set-DhcpServerv4OptionValue,
    # Set-DhcpServerv4Binding) require the DHCP Windows Service to be running.
    # That service only starts after the post-feature-install reboot completes.
    # Calling any of them here produces terminating WMI errors regardless of
    # -ErrorAction. Phase 1 therefore only touches things that don't need the
    # service: feature install, security group, static IP assignment, then reboot.
    Write-Host "Configuring DHCP VM (Phase 1: install feature + static IP)..." -ForegroundColor Cyan
    try {
        Invoke-Command -VMName $vmName -Credential $adminCred -ErrorAction Stop -ScriptBlock {
            param($gw, $start, $prefix)

            # ── Step 1: assign static IP before installing anything ────────────────
            # The DHCP VM has no DHCP server to get a lease from (it IS the DHCP
            # server). Its NIC will stay APIPA indefinitely. Find the first non-
            # loopback physical adapter by interface index and assign the static IP
            # immediately — no waiting for a lease required.
            $staticIp = ($start -replace '\.\d+$', '.253')
            $adapter  = Get-NetAdapter -ErrorAction SilentlyContinue |
                        Where-Object { $_.Status -eq 'Up' -and $_.InterfaceDescription -notmatch 'Loopback' } |
                        Sort-Object -Property ifIndex |
                        Select-Object -First 1
            if (-not $adapter) { throw "No active network adapter found inside the VM." }
            $alias = $adapter.Name
            Write-Host "  -> Adapter found: '$alias'. Assigning static IP $staticIp..."

            # Remove any existing addresses (APIPA or otherwise) then set static.
            Get-NetIPAddress -InterfaceAlias $alias -AddressFamily IPv4 `
                             -ErrorAction SilentlyContinue |
                Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
            New-NetIPAddress -InterfaceAlias $alias `
                             -IPAddress      $staticIp `
                             -PrefixLength   $prefix `
                             -DefaultGateway $gw `
                             -ErrorAction Stop
            # Set-DnsClientServerAddress so the VM can resolve names post-domain-join.
            Set-DnsClientServerAddress -InterfaceAlias $alias -ServerAddresses @('8.8.8.8') `
                                       -ErrorAction SilentlyContinue
            Write-Host "  -> Static IP $staticIp set on '$alias'."

            # ── Step 2: install DHCP feature now that the NIC is configured ────────
            $feat = Install-WindowsFeature -Name DHCP -IncludeManagementTools -ErrorAction Stop
            if (-not $feat.Success) { throw "DHCP feature install failed." }

            # Security group is a local group — safe to add pre-reboot.
            Add-DhcpServerSecurityGroup -ErrorAction SilentlyContinue

            Write-Host "Feature installed. Rebooting..."
            Restart-Computer -Force
        } -ArgumentList $gateway, $dhcpStart, $prefixLength
    } catch {
        $exType = $_.Exception.GetType().Name
        $exMsg  = $_.Exception.Message
        $isExpectedDisconnect = ($exType -match 'PSRemotingTransportException|PipelineStoppedException') -or
                                ($exMsg  -match 'The pipeline has been stopped|connection.*closed|virtual machine.*turned off')
        if (-not $isExpectedDisconnect) {
            Write-Error "DHCP VM configuration failed (Phase 1): $_"
            Exit-Script 1
        }
        Write-Host "  -> DHCP VM rebooting after feature install (expected)." -ForegroundColor Yellow
    }

    # ── Phase 2: scope, options, and binding — DHCP service is now running ───────
    Write-Host "Waiting for DHCP VM to come back up after reboot (up to 3 minutes)..." -ForegroundColor Cyan
    $staticIp = ($dhcpStart -replace '\.\d+$', '.253')
    $ready2   = $false
    $timeout2 = (Get-Date).AddMinutes(3)
    while (-not $ready2 -and (Get-Date) -lt $timeout2) {
        try {
            Invoke-Command -VMName $vmName -Credential $adminCred -ErrorAction Stop `
                           -ScriptBlock { $true } | Out-Null
            $ready2 = $true
        } catch { Start-Sleep -Seconds 5 }
    }
    if (-not $ready2) {
        Write-Error "DHCP VM did not come back up within 3 minutes after reboot."
        Exit-Script 1
    }

    Write-Host "Configuring DHCP scope, options, and binding (Phase 2)..." -ForegroundColor Cyan
    try {
        Invoke-Command -VMName $vmName -Credential $adminCred -ErrorAction Stop -ScriptBlock {
            param($gw, $netAddr, $mask, $start, $end)

            # The static IP was set in Phase 1, so discover the adapter the same
            # way — first non-loopback adapter by index, no IP polling needed.
            $labAdapter = Get-NetAdapter -ErrorAction SilentlyContinue |
                          Where-Object { $_.Status -eq 'Up' -and $_.InterfaceDescription -notmatch 'Loopback' } |
                          Sort-Object -Property ifIndex |
                          Select-Object -First 1
            if (-not $labAdapter) { throw "No active network adapter found in VM for DHCP binding." }

            # Bind the DHCP service — service is now running post-reboot.
            Set-DhcpServerv4Binding -InterfaceAlias $labAdapter.InterfaceAlias `
                                    -BindingState $true -ErrorAction Stop
            Write-Host "  [OK]  DHCP bound to adapter: $($labAdapter.InterfaceAlias)"

            # Create scope if not already present (idempotent).
            $existing = Get-DhcpServerv4Scope -ErrorAction SilentlyContinue |
                        Where-Object { $_.StartRange.ToString() -eq $start }
            if (-not $existing) {
                Add-DhcpServerv4Scope -Name "DefaultScope" `
                                      -StartRange $start `
                                      -EndRange   $end `
                                      -SubnetMask $mask `
                                      -State Active -ErrorAction Stop
            }

            Set-DhcpServerv4OptionValue -ScopeId $netAddr -Router    @($gw)       -ErrorAction Stop
            Set-DhcpServerv4OptionValue -ScopeId $netAddr -DnsServer @("8.8.8.8") -ErrorAction Stop

            # Suppress Server Manager post-install nag.
            Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\ServerManager\Roles\12" `
                             -Name "ConfigurationState" -Value 2 -ErrorAction SilentlyContinue

            Write-Host "  [OK]  Scope $start - $end configured. Router: $gw"
        } -ArgumentList $gateway, $networkAddr, $subnetMask, $dhcpStart, $dhcpEnd
    } catch {
        Write-Error "DHCP VM configuration failed (Phase 2): $_"
        Exit-Script 1
    }

    Write-Host "  [OK]  DHCP VM fully configured. Static IP: $staticIp" -ForegroundColor Green
}

Write-Host "`nDHCP setup complete." -ForegroundColor Green
Exit-Script 0

'@

# ---------------------------------------------------------------------------
# FILE: Domainsetup.ps1
# ---------------------------------------------------------------------------
Write-SuiteFile -FileName 'Domainsetup.ps1' -Content @'
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

'@

# ---------------------------------------------------------------------------
# FILE: joindomain.ps1
# ---------------------------------------------------------------------------
Write-SuiteFile -FileName 'joindomain.ps1' -Content @'
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Joins multiple VMs to a domain using PowerShell Direct.
.PARAMETER DcVmName
    Mandatory. The name of the Domain Controller VM.
.PARAMETER DomainToJoin
    Mandatory. The domain name (e.g., corp.local).
.PARAMETER DomainAdminUser
    Optional. Defaults to "<DomainToJoin>\Administrator".
.PARAMETER DomainInitCode
    Optional. SecureString. Read from sys_bootstrap.ini if omitted.
.PARAMETER VmInitCode
    Optional. SecureString for local Admin on member VMs. Defaults to DomainInitCode.
.PARAMETER VmNames
    Mandatory. Comma-separated list of VM names to join.
.EXAMPLE
    .\joindomain.ps1 -DcVmName DC01 -DomainToJoin corp.local -VmNames "VM1,VM2"
#>

param (
    [Parameter(Mandatory = $true)]  [string]$DcVmName,
    [Parameter(Mandatory = $true)]  [string]$DomainToJoin,
    [Parameter(Mandatory = $false)] [string]$DomainAdminUser,
    [Parameter(Mandatory = $false)] [System.Security.SecureString]$DomainInitCode,
    [Parameter(Mandatory = $false)] [System.Security.SecureString]$VmInitCode,
    [Parameter(Mandatory = $true)]  [string]$VmNames
)

# ─── Transcript Safety ────────────────────────────────────────────────────────
$transcriptActive = $false
try { $transcriptActive = $null -ne (Get-Transcript -ErrorAction SilentlyContinue) } catch { }
if (-not $transcriptActive) {
    $timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
    $logsDir   = Join-Path $PSScriptRoot "logs"
    New-Item -ItemType Directory -Path $logsDir -Force | Out-Null
    Start-Transcript -Path (Join-Path $logsDir "joindomain_$timestamp.txt") -Append
}

function Stop-Safe { if (-not $transcriptActive) { try { Stop-Transcript } catch { } } }
function Exit-Script ([int]$Code = 1) { Stop-Safe; exit $Code }

# ─── Credentials ──────────────────────────────────────────────────────────────
$currentDir = $PSScriptRoot
$seedPath   = Join-Path $currentDir "sys_bootstrap.ini"

# BUG FIX: The original read sys_bootstrap.ini unconditionally at the top, then
# checked whether codes were needed. If the file was missing this threw a
# terminating error before the check. Now only read the file when actually needed.
if (-not $DomainInitCode -or -not $VmInitCode) {
    if (-not (Test-Path $seedPath)) {
        Write-Error "sys_bootstrap.ini not found and no InitCode parameters were supplied."
        Exit-Script 1
    }
    $baseVal = (Get-Content -Path $seedPath | Select-Object -First 1).Trim()
    if ([string]::IsNullOrWhiteSpace($baseVal)) {
        Write-Error "sys_bootstrap.ini is empty."
        Exit-Script 1
    }
    $fallback = ConvertTo-SecureString $baseVal -AsPlainText -Force
    if (-not $DomainInitCode) { $DomainInitCode = $fallback }
    if (-not $VmInitCode)     { $VmInitCode     = $fallback }
}

if (-not $DomainAdminUser) { $DomainAdminUser = "$DomainToJoin\Administrator" }
$domainAdminCred = New-Object System.Management.Automation.PSCredential ($DomainAdminUser, $DomainInitCode)

# ─── Validate DC connectivity ─────────────────────────────────────────────────
Write-Host "Validating Domain Controller connectivity..." -ForegroundColor Cyan
try {
    $testSession = New-PSSession -VMName $DcVmName -Credential $domainAdminCred -ErrorAction Stop
    Remove-PSSession -Session $testSession -ErrorAction SilentlyContinue
    Write-Host "  [OK]  DC '$DcVmName' is reachable." -ForegroundColor Green
} catch {
    Write-Error "Cannot connect to DC '$DcVmName': $_"
    Exit-Script 1
}

# ─── Retrieve DC info ─────────────────────────────────────────────────────────
$dcInfo = Invoke-Command -VMName $DcVmName -Credential $domainAdminCred -ErrorAction Stop -ScriptBlock {
    $ip = Get-NetIPAddress -AddressFamily IPv4 |
          Where-Object { $_.IPAddress -notlike '169.*' -and $_.IPAddress -ne '127.0.0.1' } |
          Select-Object -First 1 -ExpandProperty IPAddress
    $domain = (Get-CimInstance Win32_ComputerSystem).Domain
    [PSCustomObject]@{ IP = $ip; Domain = $domain }
}

Write-Host "  DC IP     : $($dcInfo.IP)"
Write-Host "  DC Domain : $($dcInfo.Domain)"

# ─── Parse VM list ────────────────────────────────────────────────────────────
$vmNamesArray = $VmNames -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
if ($vmNamesArray.Count -eq 0) {
    Write-Error "No VM names were provided to join."
    Exit-Script 1
}

# ─── Helper: Invoke-DomainJoin ────────────────────────────────────────────────
# Encapsulates the full join sequence for a single VM so it can be called both
# on first attempt and on retry from inside the verify loop.
function Invoke-DomainJoin {
    param(
        [string]$VmName,
        [string]$DcIp,
        [string]$Domain,
        [pscredential]$LocalCred,
        [pscredential]$DomainCred
    )

    try {
        Invoke-Command -VMName $VmName -Credential $LocalCred -ErrorAction Stop -ScriptBlock {
            param($dcIp, $domain, [pscredential]$domCred)

            # Step 1: Point DNS at the DC so the domain name resolves during join.
            $upAdapters = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' }
            $upAdapters | Set-DnsClientServerAddress -ServerAddresses $dcIp

            # Step 2: Switch network profile from Public to Private.
            # FIX: Windows 11 defaults to Public firewall profile on first boot.
            # Public mode blocks Kerberos (TCP 88), LDAP (TCP 389), SMB (TCP 445)
            # which are all required by Add-Computer. DNS/ping still work because
            # UDP 53 is permitted — which is why nslookup succeeds but the join
            # fails with "domain does not exist or could not be contacted".
            foreach ($adapter in $upAdapters) {
                try {
                    Set-NetConnectionProfile -InterfaceAlias $adapter.Name `
                                             -NetworkCategory Private -ErrorAction Stop
                } catch {
                    Write-Warning "  -> Could not set Private profile on '$($adapter.Name)': $_"
                }
            }

            # BUG FIX: -Restart in Add-Computer inside PS Direct disconnects the
            # session immediately, which PowerShell misreads as an error. Use
            # Restart-Computer separately so the error surface is clean.
            Add-Computer -DomainName $domain -Credential $domCred -Force -ErrorAction Stop
            Start-Sleep -Seconds 2
            Restart-Computer -Force

        } -ArgumentList $DcIp, $Domain, $DomainCred

        # If Invoke-Command returned without throwing, join + reboot fired cleanly.
        Write-Host "  [OK]  Domain join initiated for '$VmName'." -ForegroundColor Green
        return 'initiated'

    } catch {
        $exType = $_.Exception.GetType().Name
        $exMsg  = $_.Exception.Message
        $isExpectedDisconnect =
            ($exType -match 'PSRemotingTransportException|PipelineStoppedException') -or
            ($exMsg  -match 'The pipeline has been stopped|connection.*closed|virtual machine.*turned off')

        if ($isExpectedDisconnect) {
            # Restart-Computer dropping the pipe is normal — join succeeded.
            Write-Host "  [OK]  '$VmName' is rebooting to complete domain join." -ForegroundColor Green
            return 'initiated'
        } else {
            Write-Host "  [FAIL] Join attempt failed for '$VmName': $_" -ForegroundColor Red
            return 'failed'
        }
    }
}

# ─── Helper: Wait-DCReady ─────────────────────────────────────────────────────
# Blocks until the DC responds to PS Direct AND ADWS (AD Web Services, port 9389)
# is running inside the guest. ADWS is the last AD service to start after reboot
# and is required for Add-Computer to succeed. Waiting only for PS Direct
# reachability is not sufficient — the DC can accept a shell session while AD
# services are still initialising, causing the join to fail with "domain could
# not be contacted" even though DNS and ping are working.
function Wait-DCReady {
    param(
        [string]$DcVmName,
        [pscredential]$Cred,
        [int]$TimeoutSeconds = 300
    )

    Write-Host "  -> Waiting for DC '$DcVmName' AD services to be fully ready..." -ForegroundColor Cyan
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)

    while ((Get-Date) -lt $deadline) {
        try {
            $adwsRunning = Invoke-Command -VMName $DcVmName -Credential $Cred `
                                          -ErrorAction Stop -ScriptBlock {
                $svc = Get-Service -Name ADWS -ErrorAction SilentlyContinue
                $svc -and $svc.Status -eq 'Running'
            }
            if ($adwsRunning) {
                Write-Host "  [OK]  DC AD services are ready." -ForegroundColor Green
                return $true
            }
            Write-Host "  -> DC reachable but ADWS not running yet. Retrying in 10s..." -ForegroundColor Yellow
        } catch {
            Write-Host "  -> DC not yet reachable via PS Direct. Retrying in 10s..." -ForegroundColor Yellow
        }
        Start-Sleep -Seconds 10
    }

    Write-Warning "DC did not become fully ready within $TimeoutSeconds seconds."
    return $false
}

# ─── Build shared credentials ─────────────────────────────────────────────────
$vmAdminCred  = New-Object System.Management.Automation.PSCredential ("Administrator", $VmInitCode)
$domainAdminCred = New-Object System.Management.Automation.PSCredential ($DomainAdminUser, $DomainInitCode)

# ─── Wait for DC to be fully ready before attempting any joins ────────────────
$dcReady = Wait-DCReady -DcVmName $DcVmName -Cred $domainAdminCred -TimeoutSeconds 300
if (-not $dcReady) {
    Write-Host ""
    Write-Host "  [FAIL] DC did not become ready in time. Cannot proceed with domain join." -ForegroundColor Red
    Exit-Script 1
}

# ─── Initiate domain join on each VM ─────────────────────────────────────────
# joinAttemptState tracks whether a join was ever successfully *initiated*
# (meaning Add-Computer ran without error). A VM that never got a clean join
# attempt needs a retry in the verify loop — not just polling.
$joinAttemptState = @{}
foreach ($vm in $vmNamesArray) {
    Write-Host "`nProcessing VM: $vm" -ForegroundColor Cyan
    $joinAttemptState[$vm] = Invoke-DomainJoin `
        -VmName    $vm `
        -DcIp      $dcInfo.IP `
        -Domain    $DomainToJoin `
        -LocalCred $vmAdminCred `
        -DomainCred $domainAdminCred
}

# ─── Verify domain join — with automatic retry on stalled VMs ────────────────
Write-Host "`nWaiting for VMs to reboot and confirm domain membership..." -ForegroundColor Cyan

$joinedState   = @{}
$stalledCount  = @{}   # consecutive verify-cycles where VM is still WORKGROUP
foreach ($vm in $vmNamesArray) {
    $joinedState[$vm]  = $false
    $stalledCount[$vm] = 0
}

$domainVmCred = New-Object System.Management.Automation.PSCredential ("$DomainToJoin\Administrator", $DomainInitCode)
$domainLabel  = $DomainToJoin.Split('.')[0]   # e.g. "testdaidai" from "testdaidai.lab"

# No hard timeout — loop until every VM confirms membership.
# Each VM gets an automatic re-join attempt after 5 consecutive stalled cycles
# (5 x 15s = 75s), which handles the case where the DC was rebooting during the
# first attempt and Add-Computer errored out silently.
while ($joinedState.Values -contains $false) {

    foreach ($vm in $vmNamesArray) {
        if ($joinedState[$vm]) { continue }

        $domainStatus  = $null
        $vmReachable   = $false

        # Try local creds first, fall back to domain creds
        foreach ($cred in @($vmAdminCred, $domainVmCred)) {
            try {
                $domainStatus = Invoke-Command -VMName $vm -Credential $cred `
                                               -ErrorAction Stop -ScriptBlock {
                    (Get-CimInstance Win32_ComputerSystem).Domain
                }
                $vmReachable = $true
                break
            } catch { }
        }

        if (-not $vmReachable) {
            Write-Host "  -> '$vm' unreachable (still rebooting). Waiting..." -ForegroundColor Yellow
            # Don't increment stalled count while unreachable — VM may just be mid-reboot.
            continue
        }

        if ($domainStatus -match [regex]::Escape($domainLabel)) {
            Write-Host "  [OK]  '$vm' is now a member of '$domainStatus'." -ForegroundColor Green
            $joinedState[$vm]  = $true
            $stalledCount[$vm] = 0
            continue
        }

        # VM is reachable but still reports WORKGROUP.
        $stalledCount[$vm]++
        Write-Host "  -> '$vm' reports '$domainStatus' (stall $($stalledCount[$vm])/5). Still waiting..." -ForegroundColor Yellow

        # After 5 consecutive stalled cycles, re-attempt the join.
        # This fires when the original attempt failed because the DC was mid-reboot,
        # or when the Add-Computer silently failed and the VM never rebooted.
        if ($stalledCount[$vm] -ge 5) {
            Write-Host "  -> '$vm' stalled too long. Verifying DC is ready then re-attempting join..." -ForegroundColor Yellow

            $dcStillReady = Wait-DCReady -DcVmName $DcVmName -Cred $domainAdminCred -TimeoutSeconds 120
            if ($dcStillReady) {
                $retryResult = Invoke-DomainJoin `
                    -VmName     $vm `
                    -DcIp       $dcInfo.IP `
                    -Domain     $DomainToJoin `
                    -LocalCred  $vmAdminCred `
                    -DomainCred $domainAdminCred

                if ($retryResult -eq 'initiated') {
                    Write-Host "  -> '$vm' join re-initiated. Resetting stall counter." -ForegroundColor Cyan
                    $stalledCount[$vm] = 0
                } else {
                    Write-Host "  -> '$vm' re-join attempt failed. Will retry in next cycle." -ForegroundColor Yellow
                    $stalledCount[$vm] = 0   # reset so we try again after another 5 cycles
                }
            } else {
                Write-Host "  -> DC not ready for retry. Will try again in next cycle." -ForegroundColor Yellow
                $stalledCount[$vm] = 0
            }
        }
    }

    if ($joinedState.Values -contains $false) { Start-Sleep -Seconds 15 }
}

Write-Host "`nAll VMs have joined the domain." -ForegroundColor Green
Exit-Script 0

'@

# ---------------------------------------------------------------------------
# FILE: RDS.ps1
# ---------------------------------------------------------------------------
Write-SuiteFile -FileName 'RDS.ps1' -Content @'
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

# ─── Step 1 & 2: Parallel DC and Member VM Deployment via Start-Job ────
# FIX: Start-Job inherits the parent's elevated token, so #Requires -RunAsAdministrator
# in the child scripts is satisfied without needing -Verb RunAs or UAC prompts.
Write-Host "`n=== Starting Parallel VM Deployment ===" -ForegroundColor Cyan
Write-Host "  [1] Domain Controller: $DCName (OS: $DCOS)" -ForegroundColor Yellow
Write-Host "  [2] Member VMs: $($VMNames -join ', ') (OS: $MemberOS)" -ForegroundColor Yellow

$dcScriptPath     = Join-Path $currentDir "createDC.ps1"
$deployScriptPath = Join-Path $currentDir "deploy.ps1"
$VMListString     = $VMNames -join ','

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

# Member VM job
$deployJob = Start-Job -Name "MemberDeploy" -ScriptBlock {
    param($script, $vmList, $os)
    & $script -VMName $vmList -OS $os
    $LASTEXITCODE
} -ArgumentList $deployScriptPath, $VMListString, $MemberOS

# Stream job output live to the transcript
Write-Host "`nWaiting for deployment jobs to complete (streaming output below)..." -ForegroundColor Cyan

$pollInterval = 5   # seconds between output polls
while ($true) {
    # Flush any pending output from both jobs
    $dcJob     | Receive-Job | ForEach-Object { Write-Host "  [DC]     $_" }
    $deployJob | Receive-Job | ForEach-Object { Write-Host "  [MEMBER] $_" }

    $dcDone     = $dcJob.State     -in @('Completed','Failed','Stopped')
    $deployDone = $deployJob.State -in @('Completed','Failed','Stopped')

    if ($dcDone -and $deployDone) { break }

    Start-Sleep -Seconds $pollInterval
}

# Final flush after both jobs finish
$dcJob     | Receive-Job | ForEach-Object { Write-Host "  [DC]     $_" }
$deployJob | Receive-Job | ForEach-Object { Write-Host "  [MEMBER] $_" }

# Collect results
$dcJobInfo     = Get-Job -Name "DCDeploy"
$deployJobInfo = Get-Job -Name "MemberDeploy"

$dcSuccess     = ($dcJobInfo.State -eq 'Completed')
$deploySuccess = ($deployJobInfo.State -eq 'Completed')

Write-Host "`n=== Deployment Results ===" -ForegroundColor Cyan
if ($dcSuccess) {
    Write-Host "  [OK]   Domain Controller deployment completed" -ForegroundColor Green
} else {
    Write-Host "  [FAIL] Domain Controller deployment failed (job state: $($dcJobInfo.State))" -ForegroundColor Red
    Write-Error "createDC.ps1 failed."
    Exit-Script 1
}

if ($deploySuccess) {
    Write-Host "  [OK]   Member VM deployment completed" -ForegroundColor Green
} else {
    Write-Host "  [FAIL] Member VM deployment failed (job state: $($deployJobInfo.State))" -ForegroundColor Red
    Write-Error "deploy.ps1 failed."
    Exit-Script 1
}

# Clean up job objects
Remove-Job -Name "DCDeploy","MemberDeploy" -Force -ErrorAction SilentlyContinue

Write-Host "`nAll VMs deployed successfully via parallel jobs." -ForegroundColor Green

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

'@

# ---------------------------------------------------------------------------
# FILE: RDVH.ps1
# ---------------------------------------------------------------------------
Write-SuiteFile -FileName 'RDVH.ps1' -Content @'
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Automated deployment of an RDS Virtual Desktop Infrastructure (VDI) farm.
.DESCRIPTION
    Chains DC creation, VM deployment, domain join, nested-virtualisation setup,
    Hyper-V role install inside RDVH guests, and RDS VDI role configuration.

    Parallel deployment uses Start-Job (not Start-Process) so that child
    jobs inherit the elevated token of the parent session — fixing the
    -196608 / #Requires -RunAsAdministrator failure that occurs when
    Start-Process spawns new windows without -Verb RunAs.
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
    Write-Host "  REPLAY COMMAND (copy-paste to rerun)"   -ForegroundColor Cyan
    Write-Host "==========================================" -ForegroundColor Cyan

    $vmNamesStr  = $VMNames  -join ','
    $vhNamesStr  = $VHNames  -join ','
    $licNamesStr = $LicNames -join ','
    $gwNamesStr  = $GWNames  -join ','

    $cmd  = "& '$($MyInvocation.ScriptName)'"
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
if (-not $DCName)     { $DCName     = Read-Host "Enter Domain Controller VM Name" }
if (-not $DomainName) { $DomainName = Read-Host "Enter Domain Name (e.g., corp.local)" }
if (-not $DCOS)       { $DCOS       = Read-Host "Enter OS for Domain Controller" }

if ($null -eq $VMNames) {
    $VMNames = @((Read-Host "Enter all domain member VM names (comma-separated)") -split ',' |
                 ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
} else {
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

# ─── Step 1 & 2: Parallel DC and Member VM Deployment via Start-Job ──────────
# FIX: Start-Job inherits the parent's elevated token, so #Requires -RunAsAdministrator
# in the child scripts is satisfied without needing -Verb RunAs or UAC prompts.
# Start-Process without -Verb RunAs spawns a non-elevated child (exit code -196608).
Write-Host "`n=== Starting Parallel VM Deployment ===" -ForegroundColor Cyan
Write-Host "  [1] Domain Controller: $DCName (OS: $DCOS)" -ForegroundColor Yellow
Write-Host "  [2] Member VMs: $($VMNames -join ', ') (OS: $MemberOS)" -ForegroundColor Yellow

$dcScriptPath     = Join-Path $currentDir "createDC.ps1"
$deployScriptPath = Join-Path $currentDir "deploy.ps1"
$VMListString     = $VMNames -join ','

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

# DC job — dot-sources createDC.ps1 inside the job runspace
$dcJob = Start-Job -Name "DCDeploy" -ScriptBlock {
    param($script, $os, $vmName, $domainName)
    & $script -OS $os -VMName $vmName -DomainName $domainName
    # Return the exit code as the last output value so the parent can inspect it
    $LASTEXITCODE
} -ArgumentList $dcScriptPath, $DCOS, $DCName, $DomainName

# Member VM job — dot-sources deploy.ps1 inside the job runspace
$deployJob = Start-Job -Name "MemberDeploy" -ScriptBlock {
    param($script, $vmList, $os)
    & $script -VMName $vmList -OS $os
    $LASTEXITCODE
} -ArgumentList $deployScriptPath, $VMListString, $MemberOS

# ─── Stream job output live to the transcript ─────────────────────────────────
Write-Host "`nWaiting for deployment jobs to complete (streaming output below)..." -ForegroundColor Cyan

$pollInterval = 5   # seconds between output polls
while ($true) {
    # Flush any pending output from both jobs
    $dcJob     | Receive-Job | ForEach-Object { Write-Host "  [DC]     $_" }
    $deployJob | Receive-Job | ForEach-Object { Write-Host "  [MEMBER] $_" }

    $dcDone     = $dcJob.State     -in @('Completed','Failed','Stopped')
    $deployDone = $deployJob.State -in @('Completed','Failed','Stopped')

    if ($dcDone -and $deployDone) { break }

    Start-Sleep -Seconds $pollInterval
}

# Final flush after both jobs finish
$dcJob     | Receive-Job | ForEach-Object { Write-Host "  [DC]     $_" }
$deployJob | Receive-Job | ForEach-Object { Write-Host "  [MEMBER] $_" }

# ─── Collect results ──────────────────────────────────────────────────────────
# The last value emitted by each job scriptblock is $LASTEXITCODE from the child script.
# Receive-Job was already flushed above, so inspect child info directly.
$dcJobInfo     = Get-Job -Name "DCDeploy"
$deployJobInfo = Get-Job -Name "MemberDeploy"

# A job that throws an unhandled terminating error lands in Failed state.
# Treat anything other than Completed as a failure.
$dcSuccess     = ($dcJobInfo.State     -eq 'Completed') -and ($dcJobInfo.ChildJobs[0].Error.Count -eq 0)
$deploySuccess = ($deployJobInfo.State -eq 'Completed') -and ($deployJobInfo.ChildJobs[0].Error.Count -eq 0)

Write-Host "`n=== Deployment Results ===" -ForegroundColor Cyan
if ($dcSuccess) {
    Write-Host "  [OK]   Domain Controller deployment completed" -ForegroundColor Green
} else {
    Write-Host "  [FAIL] Domain Controller deployment failed (job state: $($dcJobInfo.State))" -ForegroundColor Red
    # Surface any terminating errors from the job
    $dcJobInfo.ChildJobs[0].Error | ForEach-Object { Write-Host "         Error: $_" -ForegroundColor Red }
}

if ($deploySuccess) {
    Write-Host "  [OK]   Member VM deployment completed" -ForegroundColor Green
} else {
    Write-Host "  [FAIL] Member VM deployment failed (job state: $($deployJobInfo.State))" -ForegroundColor Red
    $deployJobInfo.ChildJobs[0].Error | ForEach-Object { Write-Host "         Error: $_" -ForegroundColor Red }
}

# Clean up job objects
Remove-Job -Name "DCDeploy","MemberDeploy" -Force -ErrorAction SilentlyContinue

if (-not $dcSuccess -or -not $deploySuccess) {
    Write-Error "One or more deployment jobs failed. Review the output above."
    Exit-Script 1
}

Write-Host "`nAll VMs deployed successfully via parallel jobs." -ForegroundColor Green

# ─── Verify all VMs are reachable before domain join ─────────────────────────
Write-Host "`n=== Verifying VM Readiness ===" -ForegroundColor Cyan
$allVMs              = @($DCName) + $VMNames
$verificationTimeout = 300   # 5 minutes total
$verificationInterval = 10   # check every 10 seconds
$elapsed             = 0
$allReady            = $false

while (-not $allReady -and $elapsed -lt $verificationTimeout) {
    $allReady    = $true
    $readyCount  = 0

    foreach ($vmName in $allVMs) {
        try {
            $testResult = Invoke-Command -VMName $vmName -Credential $domainAdminCred `
                -ErrorAction Stop -ScriptBlock { "OK" }

            if ($testResult -eq "OK") {
                Write-Host "  [OK] $vmName - Ready" -ForegroundColor Green
                $readyCount++
            }
        } catch {
            $progressMsg = "${elapsed}/${verificationTimeout} seconds"
            Write-Host "  [X] $vmName - Not reachable yet ($progressMsg)" -ForegroundColor Yellow
            $allReady = $false
        }
    }

    if (-not $allReady) {
        $retryMsg = "Retrying in ${verificationInterval} s"
        Write-Host "  Progress: $readyCount/$($allVMs.Count) VMs ready. $retryMsg" -ForegroundColor Gray
        Start-Sleep -Seconds $verificationInterval
        $elapsed += $verificationInterval
    }
}

if ($allReady) {
    Write-Host "`n[OK] All $($allVMs.Count) VMs are ready for domain join." -ForegroundColor Green
} else {
    $timeoutMsg = "${verificationTimeout}s"
    Write-Error "VM verification timed out after $timeoutMsg. Some VMs may not be ready."
    Exit-Script 1
}

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
        $vmObj     = Get-VM -Name $vh -ErrorAction Stop
        $wasRunning = $vmObj.State -eq 'Running'

        if ($wasRunning) {
            Write-Host "     Stopping '$vh' to apply processor setting..."
            Stop-VM -Name $vh -Force -ErrorAction Stop
            $stopTimeout = (Get-Date).AddMinutes(2)
            while ((Get-VM -Name $vh).State -ne 'Off') {
                if ((Get-Date) -gt $stopTimeout) { throw "Timed out waiting for '$vh' to stop." }
                Start-Sleep -Seconds 3
            }
        }

        Set-VMProcessor -VMName $vh -ExposeVirtualizationExtensions $true -ErrorAction Stop
        Write-Host "     Nested virtualisation enabled." -ForegroundColor Green

        if ($wasRunning) {
            Start-VM -Name $vh -ErrorAction Stop
            $startTimeout = (Get-Date).AddMinutes(2)
            while ((Get-VM -Name $vh).State -ne 'Running') {
                if ((Get-Date) -gt $startTimeout) { throw "Timed out waiting for '$vh' to start." }
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
try {
    Invoke-Command -VMName $CBName -Credential $domainAdminCred -ErrorAction Stop -ScriptBlock {
        param($cb, $wa, $vhs)
        Import-Module RemoteDesktop -ErrorAction Stop
        New-RDVirtualDesktopDeployment `
            -ConnectionBroker   $cb  `
            -WebAccessServer    $wa  `
            -VirtualizationHost $vhs
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

'@

# ---------------------------------------------------------------------------
# FILE: switch.ps1
# ---------------------------------------------------------------------------
Write-SuiteFile -FileName 'switch.ps1' -Content @'
#Requires -RunAsAdministrator
param (
    [switch]$Default
)

# ─── Transcript Safety ────────────────────────────────────────────────────────
$transcriptActive = $false
try { $transcriptActive = $null -ne (Get-Transcript -ErrorAction SilentlyContinue) } catch { }
if (-not $transcriptActive) {
    $timestamp  = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
    # Use script-relative logs folder so the log always lands next to the script,
    # not wherever the caller's working directory happens to be.
    $logsDir    = Join-Path $PSScriptRoot "logs"
    New-Item -ItemType Directory -Path $logsDir -Force | Out-Null
    Start-Transcript -Path (Join-Path $logsDir "Switch_$timestamp.txt") -Append
}

function Stop-Safe { if (-not $transcriptActive) { try { Stop-Transcript } catch { } } }
function Exit-Script ([int]$Code = 1) { Stop-Safe; exit $Code }

# ─── Hyper-V pre-flight check ─────────────────────────────────────────────────
if (-not (Get-Module -ListAvailable -Name Hyper-V -ErrorAction SilentlyContinue)) {
    Write-Host ""
    Write-Host "ERROR: Hyper-V is not installed or not enabled on this host." -ForegroundColor Red
    Write-Host ""
    $feature = Get-WindowsOptionalFeature -FeatureName Microsoft-Hyper-V-All -Online -ErrorAction SilentlyContinue
    if ($feature -and $feature.State -ne 'Enabled') {
        $enableResponse = Read-Host "Would you like to enable Hyper-V now? (Requires reboot) (Y/N)"
        if ($enableResponse -match '^[Yy]$') {
            Write-Host "Enabling Hyper-V..."
            Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -NoRestart
            Write-Host ""
            Write-Host "Hyper-V has been enabled. Please REBOOT and run this script again." -ForegroundColor Yellow
            Exit-Script 0
        }
    }
    Write-Host "Cannot proceed without Hyper-V. Please install and enable Hyper-V, then try again."
    Exit-Script 1
}

$currentDir = $PSScriptRoot
$switchName = "NATSwitch"

# ─── Determine switch name ────────────────────────────────────────────────────
if ($Default) {
    Write-Host "Using default network range: 192.168.1.0/24 and switch name: $switchName"
    $networkInput = "192.168.1.0/24"
} else {
    Write-Host ""
    Write-Host "=========================================="
    Write-Host "  Hyper-V Virtual Switch Configuration"
    Write-Host "=========================================="
    Write-Host ""
    $switchInput = Read-Host "Enter virtual switch name [Default: $switchName]"
    if (-not [string]::IsNullOrWhiteSpace($switchInput)) { $switchName = $switchInput.Trim() }
}

# NAT name derived from switch name (set once, used throughout)
$natName      = "${switchName}_NAT"
$skipCreation = $false

# ─── Check if switch already exists ───────────────────────────────────────────
$existingSwitch = Get-VMSwitch -Name $switchName -ErrorAction SilentlyContinue
if ($existingSwitch) {
    Write-Host ""
    Write-Host "Virtual switch '$switchName' already exists." -ForegroundColor Yellow
    Write-Host "Attempting to extract existing network configuration..."

    # BUG FIX: Get-NetIPAddress can return multiple addresses; take only the first
    # valid one to avoid "Cannot convert array" errors downstream.
    $adapter = Get-NetIPAddress -InterfaceAlias "vEthernet ($switchName)" `
                                -AddressFamily IPv4 -ErrorAction SilentlyContinue |
               Where-Object { $_.IPAddress -ne '127.0.0.1' } |
               Select-Object -First 1

    if (-not $adapter) {
        Write-Error "Virtual switch '$switchName' exists but has no IPv4 address on its host adapter."
        Exit-Script 1
    }

    $gateway   = $adapter.IPAddress
    $prefixLen = [int]$adapter.PrefixLength

    if ($prefixLen -ne 24) {
        Write-Error "Switch '$switchName' uses a /$prefixLen prefix. Only /24 is supported."
        Exit-Script 1
    }

    $octets      = $gateway -split '\.'
    $networkAddr = "$($octets[0]).$($octets[1]).$($octets[2]).0"
    $cidr        = "$networkAddr/$prefixLen"

    $existingNat = Get-NetNat -ErrorAction SilentlyContinue |
                   Where-Object { $_.InternalIPInterfaceAddressPrefix -eq $cidr }
    if (-not $existingNat) {
        Write-Warning "Switch '$switchName' has IP $gateway but no NAT rule exists for $cidr."
        $createNat = Read-Host "Would you like to create the NAT rule now? (Y/N)"
        if ($createNat -match '^[Yy]$') {
            try {
                New-NetNat -Name $natName -InternalIPInterfaceAddressPrefix $cidr -ErrorAction Stop
                Write-Host "NAT rule created." -ForegroundColor Green
            } catch {
                Write-Error "Failed to create NAT rule: $_"
                Exit-Script 1
            }
        } else {
            Write-Error "Cannot proceed without a NAT rule."
            Exit-Script 1
        }
    }

    $dhcpStart  = "$($octets[0]).$($octets[1]).$($octets[2]).2"
    $dhcpEnd    = "$($octets[0]).$($octets[1]).$($octets[2]).254"
    $subnetMask = "255.255.255.0"

    Write-Host "  [OK]  Extracted configuration from existing switch '$switchName':" -ForegroundColor Green
    Write-Host "        Network     : $cidr"
    Write-Host "        Gateway     : $gateway"
    Write-Host "        Subnet Mask : $subnetMask"
    Write-Host "        DHCP Range  : $dhcpStart - $dhcpEnd"

    $skipCreation = $true
}

# ─── Prompt for network range (only when creating a new switch) ───────────────
if (-not $skipCreation -and -not $Default) {
    Write-Host ""
    Write-Host "Enter the network range in CIDR notation (private /24 only)."
    Write-Host "Examples: 192.168.1.0/24  10.0.1.0/24  172.16.5.0/24"
    Write-Host "Press Enter to accept default (192.168.1.0/24)"
    Write-Host ""
    $networkInput = Read-Host "Network range"
    if ([string]::IsNullOrWhiteSpace($networkInput)) {
        $networkInput = "192.168.1.0/24"
        Write-Host "Using default: $networkInput"
    }
}

# ─── Validate and create switch ───────────────────────────────────────────────
if (-not $skipCreation) {
    # Auto-append /24 for bare IPs
    if ($networkInput -match '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$') {
        $networkInput = "$networkInput/24"
        Write-Host "No prefix specified. Appending /24: $networkInput"
    }

    if ($networkInput -notmatch '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}/\d{1,2}$') {
        Write-Error "Invalid CIDR format: '$networkInput'. Expected: x.x.x.0/24"
        Exit-Script 1
    }

    $parts       = $networkInput -split '/'
    $networkAddr = $parts[0]
    $prefixLen   = [int]$parts[1]

    if ($prefixLen -ne 24) {
        Write-Error "Only /24 prefix is supported. Got: /$prefixLen"
        Exit-Script 1
    }

    $octets = $networkAddr -split '\.'
    # BUG FIX: Validate each octet is a valid integer 0-255 using [int]::TryParse
    # to avoid exceptions when the user types non-numeric characters.
    foreach ($o in $octets) {
        $val = 0
        if (-not [int]::TryParse($o, [ref]$val) -or $val -lt 0 -or $val -gt 255) {
            Write-Error "Invalid IP address in network range: $networkAddr"
            Exit-Script 1
        }
    }

    if ($octets[3] -ne '0') {
        Write-Warning "Last octet is $($octets[3]) for a /24 network. Adjusting to .0"
        $octets[3] = '0'
        $networkAddr = $octets -join '.'
    }

    $firstOctet  = [int]$octets[0]
    $secondOctet = [int]$octets[1]
    $isPrivate   = ($firstOctet -eq 10) -or
                   ($firstOctet -eq 172 -and $secondOctet -ge 16 -and $secondOctet -le 31) -or
                   ($firstOctet -eq 192 -and $secondOctet -eq 168)
    if (-not $isPrivate) {
        Write-Error "Not a private IP range (RFC 1918). Use 10.x.x.0, 172.16-31.x.0, or 192.168.x.0"
        Exit-Script 1
    }

    $base       = "$($octets[0]).$($octets[1]).$($octets[2])"
    $gateway    = "$base.1"
    $dhcpStart  = "$base.2"
    $dhcpEnd    = "$base.254"
    $subnetMask = "255.255.255.0"
    $cidr       = "$networkAddr/$prefixLen"

    Write-Host ""
    Write-Host "Network Configuration:"
    Write-Host "  Switch Name : $switchName"
    Write-Host "  Network     : $cidr"
    Write-Host "  Gateway     : $gateway"
    Write-Host "  Subnet Mask : $subnetMask"
    Write-Host "  DHCP Range  : $dhcpStart - $dhcpEnd"
    Write-Host ""

    try {
        Write-Host "Creating Internal Virtual Switch '$switchName'..."
        New-VMSwitch -SwitchName $switchName -SwitchType Internal -ErrorAction Stop

        Write-Host "Assigning gateway IP $gateway to adapter..."
        New-NetIPAddress -IPAddress $gateway -PrefixLength $prefixLen `
                         -InterfaceAlias "vEthernet ($switchName)" -ErrorAction Stop

        Write-Host "Configuring NAT for $cidr..."
        New-NetNat -Name $natName -InternalIPInterfaceAddressPrefix $cidr -ErrorAction Stop
    } catch {
        Write-Host ""
        Write-Host "ERROR: Failed to create virtual switch or configure NAT." -ForegroundColor Red
        Write-Host "  Detail: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host ""
        Write-Host "Please ensure:" -ForegroundColor Yellow
        Write-Host "  - You are running as Administrator"
        Write-Host "  - No switch named '$switchName' or NAT named '$natName' already exists"
        Exit-Script 1
    }
}

# ─── Write switch.txt ─────────────────────────────────────────────────────────
$switchFile   = Join-Path $currentDir "switch.txt"
$switchConfig = @"
SwitchName=$switchName
Gateway=$gateway
NetworkAddress=$networkAddr
PrefixLength=$prefixLen
SubnetMask=$subnetMask
DHCPStart=$dhcpStart
DHCPEnd=$dhcpEnd
"@

Set-Content -Path $switchFile -Value $switchConfig -Encoding UTF8
Write-Host ""
Write-Host "Network configuration saved to: $switchFile" -ForegroundColor Green
Write-Host "Switch setup complete." -ForegroundColor Green
Exit-Script 0

'@

# ---------------------------------------------------------------------------
# FILE: Guidance.txt
# ---------------------------------------------------------------------------
Write-SuiteFile -FileName 'Guidance.txt' -Content @'
# Hyper-V Automation Scripts Guidance (v3.0 "Enterprise-Ready")

This directory contains a suite of PowerShell scripts designed to automate the deployment of a Hyper-V based lab environment. The v3.0 release introduces enterprise-grade RDS VDI automation and enhanced reliability features.

## Centralized Configuration Files

*   `sys_bootstrap.ini` — Single-line file containing the master Administrator initialization code. Created automatically by `setup.ps1` on first run.
*   `switch.txt` — Stores the virtual switch name and NAT network settings. Generated by `switch.ps1` or `setup.ps1`.

## Deployment Sequence (v3.0)

1. Run `setup.ps1` to establish network infrastructure, set initialization code, and download golden images.
   - **First Run**: Prompts for master initialization code (saved to `sys_bootstrap.ini`)
   - **Network Setup**: Automatically validates/creates virtual switches and DHCP services
   - **Downloads**: Downloads and prepares golden images (stored in `.\goldenImage`)
2. (ISO Only) Boot into ISO-based reference VMs (e.g., Win11) to complete manual installation using the password from `sys_bootstrap.ini`.
3. Run `unattend.ps1` to sysprep ISO-based reference VMs (Windows 11 and Server 2016) into reusable golden images.
   - VHD-based VMs (2019, 2022, 2025) are already sysprepped by `setup.ps1`
4. Run `RDVH.ps1` for complete RDS Virtual Desktop Infrastructure deployment.
5. Or run individual scripts: `deploy.ps1`, `Domainsetup.ps1`, or `RDS.ps1` for specific labs.

---

## Key Enterprise Features (v3.0 New)

### 1. Complete RDS VDI Automation
`RDVH.ps1` provides end-to-end RDS Virtual Desktop Infrastructure deployment including:
- Domain Controller creation with credential fallbacks
- Member VM deployment with hostname verification
- Domain joining with enhanced error handling
- Hyper-V role installation on virtualization hosts
- RDS deployment creation and role configuration

### 2. Enhanced Credential Management
- Automatic fallback between local and domain credentials
- Context-aware credential switching during DC promotion and reboots
- Improved error handling for authentication issues

### 3. Replay Command System
All major scripts now output complete, copy-paste ready commands for:
- Easy lab recreation
- Failure recovery
- Parameter reuse across deployments

---

## 1. Network Preparation (switch.ps1)
**Function:** Sets up "NATSwitch" and NAT networking.
- **Auto-Discovery**: Automatically detects existing switches and NAT rules to avoid conflicts.
- **Output**: Generates `switch.txt` with calculated DHCP ranges (.2 to .254).

## 2. Base VM Configuration (setup.ps1)
**Function:** Complete lab initialization, network setup, and golden image preparation.
- **First-Time Setup**: Prompts for and saves master initialization code to `sys_bootstrap.ini`
- **Auto-Network Setup**: Automatically validates and sets up virtual switches and DHCP services
- **Interactive Prompts**: Offers to run `switch.ps1` and `DHCP.ps1` if network infrastructure is missing
- **Parallel Downloads**: Optimized download process with progress tracking
- **Verification**: Post-setup, the script deploys `TEST-` VMs to verify golden image health.

## 3. Image Sysprep (unattend.ps1)
**Function:** Generalizes ISO-based reference VMs into reusable golden images.
- **Target VMs**: Only Windows 11 and Server 2016 (ISO-based VMs that require manual installation)
- **VHD-based VMs**: Windows Server 2019, 2022, and 2025 are already sysprepped by `setup.ps1`
- **Auto-Reboot**: Detects and clears pending Windows Updates or CBS locks before sysprepping
- **Log Polling**: Provides live 20-line tail of `setupact.log` for visibility

## 4. Core VM Instantiation (deploy.ps1)
**Function:** The central engine that copies golden images and instantiates VMs.
- **Auto-DHCP**: Automatically starts the DHCP VM if needed.
- **KVP Check**: Verifies guest IP address via host-side Integration Services.
- **Hostname Sync**: Continuously retries renaming until the guest OS acknowledges the new name.

## 5. Domain Controller Creation (createDC.ps1)
**Function:** Provisions Windows Domain Controllers with enhanced reliability.
- **Credential Fallbacks**: Handles context changes during DC promotion and reboots
- **AD Service Verification**: Waits for Active Directory services to be fully ready

## 6. Domain Joining (joindomain.ps1)
**Function:** Joins VMs to domains with robust error handling.
- **Parallel Processing**: Joins multiple VMs simultaneously
- **Credential Switching**: Falls back between local and domain credentials as needed

## 7. RDS VDI Deployment (RDVH.ps1)
**Function:** Complete RDS Virtual Desktop Infrastructure automation.
- **End-to-End**: DC creation → VM deployment → Domain join → Hyper-V install → RDS setup
- **Role Configuration**: Automatically configures Connection Broker, Web Access, Virtualization Hosts, Gateways, and Licensing servers
- **Replay Commands**: Outputs complete command lines for lab recreation

## 5. Domain Controller Creation (createDC.ps1)
**Function:** Deploys a VM, assigns a static IP, and promotes it to a Domain Controller.
- **Chained Logic**: Uses `deploy.ps1` for the initial build and then runs AD DS forest installation.

## 6. General Domain Setup (Domainsetup.ps1)
**Function:** Multi-VM lab orchestrator.
- **v2.9 Recovery**: Prints a top-level **Retry Command** on failure for rapid resume.
- **Workflow**: Chained deployment and domain joining in a single execution.

## 7. Cleanup Utility (cleanup.ps1)
**Function:** Safely removes orphaned VM folders and configuration files across `.\hyperv` and `.\VM` directories.

---
**Version**: 2.9 (Build 2026.03.26)
**Encoding**: Standard ASCII (Compatible with all PowerShell consoles).

'@

# ---------------------------------------------------------------------------
# FILE: readme.txt
# ---------------------------------------------------------------------------
Write-SuiteFile -FileName 'readme.txt' -Content @'
=============================================================================
HYPER-V AUTOMATION LAB SUITE - v3.0 "ENTERPRISE-READY" DEVELOPER WIKI
=============================================================================

This document provides technical logic and infrastructure details for the v3.0 release.

-----------------------------------------------------------------------------
v3.0 CORE ENHANCEMENTS
-----------------------------------------------------------------------------
1. RDS VDI AUTOMATION: Complete RDS Virtual Desktop Infrastructure deployment with `RDVH.ps1`
2. ENHANCED CREDENTIAL HANDLING: Improved domain credential fallbacks and context switching
3. PARAMETER ARRAY FIXES: Proper handling of comma-separated parameters in PowerShell
4. STREAMLINED DEPLOYMENT: Removed redundant waits and optimized timing
5. REPLAY COMMAND FEATURE: All scripts now output copy-paste commands for easy lab recreation

-----------------------------------------------------------------------------
CENTRALIZED CONFIGURATION FILES
-----------------------------------------------------------------------------
* sys_bootstrap.ini: Master Administrator authorization string (created automatically by setup.ps1)
* switch.txt: FABRIC config. SwitchName, Gateway, NetworkAddress, PrefixLength, DHCPRange.

-----------------------------------------------------------------------------
SCRIPT LOGIC SUMMARY
-----------------------------------------------------------------------------

SCRIPT: RDVH.ps1
- Complete RDS Virtual Desktop Infrastructure deployment orchestrator.
- Logic: createDC.ps1 -> deploy.ps1 -> joindomain.ps1 -> Hyper-V role installation -> RDS deployment creation
- Features: Credential fallbacks, hostname verification, replay command output
- Failure: Prints complete retry command with all parameters

SCRIPT: deploy.ps1
- Foundational engine. Handles Robocopy-based VHD cloning and parallel background jobs for VM creation.
- Logic: Verifies DHCP availability (Host role or VM) -> Auto-starts DHCP VM if needed -> Copies VHD -> Instantiates VM -> Polling Rename until guest confirms.
- Features: Hostname verification with auto-rename, parallel deployment, credential fallbacks
- Failure: Prints retry command `.\deploy.ps1 -VMName "..." -OS "..."`.

SCRIPT: setup.ps1
- Lab preparation, network infrastructure setup, and golden image verification.
- Logic: Validates network infrastructure -> Downloads evaluation images -> Creates reference VMs -> Deploys 'TEST-' VMs via deploy.ps1 to verify golden image health.
- Features: Auto-network setup (virtual switches & DHCP), parallel downloads, offline VHD servicing, comprehensive verification phases

SCRIPT: Domainsetup.ps1
- High-level orchestrator for full environments.
- Logic: createDC.ps1 (DC) -> deploy.ps1 (Members) -> joindomain.ps1 (Join).
- Failure: Prints top-level retry command including all domain parameters.

SCRIPT: createDC.ps1
- Domain Controller provisioning with credential fallbacks.
- Logic: Deploy base VM -> Promote to DC -> Wait for AD services -> Handle credential context changes
- Features: Local/domain credential fallbacks, AD service verification

SCRIPT: joindomain.ps1
- Domain join engine with enhanced error handling.
- Logic: Validate DC connectivity -> Initiate domain joins -> Verify membership with credential fallbacks
- Features: Parallel domain joins, credential context switching, timeout handling

SCRIPT: unattend.ps1
- Sysprep engine for ISO-based VMs. Injects unattend.xml via PowerShell Direct and triggers generalization.
- Targets: Windows 11 and Server 2016 (VHD-based VMs are already sysprepped by setup.ps1)
- Features real-time log tailing of `setupact.log` inside the guest.

SCRIPT: cleanup.ps1
- Resource reclamation. Targets orphaned artifacts in both `.\hyperv` and `.\VM` paths.

-----------------------------------------------------------------------------
TRANSCRIPT & ERROR HANDLING
-----------------------------------------------------------------------------
- Suite-wide `$transcriptActive` guards prevent transcript nesting conflicts.
- Strict `$LASTEXITCODE` checks in orchestrator scripts ensure fail-fast behavior.

=============================================================================
END OF WIKI
=============================================================================

'@

# ---------------------------------------------------------------------------
# FILE: Walkthrough.md
# ---------------------------------------------------------------------------
Write-SuiteFile -FileName 'Walkthrough.md' -Content @'
# v2.9 "Bulletproof" Lab Walkthrough

This walkthrough demonstrates the new resiliency features implemented in the v2.9 Hyper-V Lab Automation Suite.

## 1. Automated DHCP Resiliency
When deploying a lab, the suite now ensures networking is ready without manual intervention.

- **Scenario**: The 'DHCP' VM is turned off.
- **Workflow**: 
    1. Run `.\deploy.ps1` or `.\domainsetup.ps1`.
    2. Script detects `DHCP` VM is `Off`.
    3. Console: `-> VM 'DHCP' found but not running. Auto-starting...`
    4. Script waits until Hyper-V Integration Services (KVP) report a valid IP address.
    5. Deployment proceeds automatically once networking is validated.

## 2. Failure Recovery (Copy-Paste Resume)
Scripts now "remember" your intent in case of environment failures.

- **Scenario**: Deployment fails (e.g., Host DHCP scope missing or disk space full).
- **Workflow**:
    1. Script executes fail-fast logic to halt operations.
    2. Console output:
       ```
       ========================================
        DEPLOYMENT FAILED
       ========================================
       Domain Controller creation failed. Fix the issue, then re-run:
       
       .\domainsetup.ps1 -DCName "testdc" -DomainName "lab.local" -DCOS "2025" ...
       ```
    3. User simply copies the pre-filled command and pastes it to resume.

## 3. Storage Consolidation
All golden images are now unified for easier management.

- **ISO-Based Masters**: Reference VHDs for Windows 11 or Server 2016 (ISO installs) are now created directly in `.\goldenImage`.
- **Verification VMs**: The `setup.ps1` script now deploys `TEST-` prefixed VMs to verify that your golden images are ready for production use.

## 4. Universal Compatibility
Console artifacts (like emojis or non-breaking spaces) have been removed to ensure the suite looks and feels premium on all terminals, including legacy PowerShell consoles and RDP sessions.

---
**Build**: v2.9.2 Final (March 2026)

'@

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "---------------------------------------------" -ForegroundColor Cyan
Write-Host "  Extraction complete" -ForegroundColor Cyan
Write-Host "  Written : $written" -ForegroundColor Green
if ($skipped -gt 0) {
    Write-Host "  Skipped : $skipped  (files already present)" -ForegroundColor Yellow
}
if ($errors -gt 0) {
    Write-Host "  Errors  : $errors" -ForegroundColor Red
}
Write-Host "---------------------------------------------" -ForegroundColor Cyan
Write-Host ""
Write-Host "Next step:  Run .\setup.ps1 to begin lab initialization." -ForegroundColor White
Write-Host ""
