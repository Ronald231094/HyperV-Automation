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
    [System.Security.SecureString]$InitCode
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

$fileExt = if ($OS -eq "2025" -or $OS -eq "11") { "vhdx" } else { "vhd" }
$vmGen   = if ($OS -eq "2025" -or $OS -eq "11") { 2 }      else { 1 }

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
    $newPath = Join-Path $vmPath "$vmName.$fileExt"
    
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
        Set-VMProcessor -VMName $vmName -Count 2
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
$maxRetries = 24  # 24 x 15 s = 6 minutes
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
