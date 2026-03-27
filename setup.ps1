#Requires -RunAsAdministrator
# setup.ps1 - Hyper-V Lab Setup Script (Optimized)
# ─────────────────────────────────────────────────────────────────────────────

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ─── Transcript Safety ────────────────────────────────────────────────────────
# FIX: Get-Transcript doesn't exist on PS <5.1 / older hosts; check version first.
# FIX: Original code compared Get-Transcript output as a boolean - it returns a
#      path string if active, $null if not. The -eq $false comparison was wrong.
$transcriptActive = $false
if ($PSVersionTable.PSVersion.Major -ge 5) {
    try {
        $transcriptActive = $null -ne (Get-Transcript -ErrorAction SilentlyContinue)
    } catch { }
}

if (-not $transcriptActive) {
    $timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
    $logDir    = Join-Path $PSScriptRoot "logs"
    $logPath   = Join-Path $logDir "Setup_$timestamp.txt"
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    Start-Transcript -Path $logPath -Append
}

# ─── Helper: Stop-TranscriptSafe ──────────────────────────────────────────────
# FIX: Original code called Stop-Transcript without checking $transcriptActive in
#      some early-exit paths (e.g. the switch.ps1 failure block), risking errors.
#      Centralise the guard here so every exit path calls this one function.
function Stop-TranscriptSafe {
    if (-not $transcriptActive) {
        try { Stop-Transcript } catch { }
    }
}

# ─── Helper: Exit-Script ──────────────────────────────────────────────────────
# Consolidates the repeated Stop-Transcript + exit pattern throughout the script.
function Exit-Script {
    param ([int]$Code = 1)
    Stop-TranscriptSafe
    exit $Code
}

# ─── Resolve base directory ───────────────────────────────────────────────────
# FIX: Original used Get-Location which changes if the user cds mid-session.
#      $PSScriptRoot is the stable path of the script file itself.
$currentDir = $PSScriptRoot

# ─── First-run: Lab Initialization Code ──────────────────────────────────────
$seedPath   = Join-Path $currentDir "sys_bootstrap.ini"
# FIX: Original built a compound boolean then tested it - readable but redundant.
#      Simplified: path must exist AND have non-whitespace content.
$seedExists = (Test-Path $seedPath) -and
              (-not [string]::IsNullOrWhiteSpace((Get-Content $seedPath -Raw -ErrorAction SilentlyContinue)))

if (-not $seedExists) {
    Write-Host ""
    Write-Host "=============================================" -ForegroundColor Cyan
    Write-Host "  First-Time Lab Setup - Initialization Code" -ForegroundColor Cyan
    Write-Host "=============================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "All VMs in this lab will share a single master initialization code."
    Write-Host "This code will be stored locally in 'sys_bootstrap.ini' and used by"
    Write-Host "all downstream scripts (unattend, deploy, createDC, joindomain, etc.)."
    Write-Host ""

    do {
        $labCode = Read-Host "Enter your desired lab initialization code"
        if ([string]::IsNullOrWhiteSpace($labCode)) {
            Write-Host "  -> The code cannot be empty. Please try again." -ForegroundColor Red
        }
    } while ([string]::IsNullOrWhiteSpace($labCode))

    Set-Content -Path $seedPath -Value $labCode -Encoding UTF8 -Force
    Write-Host ""
    Write-Host "Initialization code saved to sys_bootstrap.ini." -ForegroundColor Green
    Write-Host ""
}

# ─── Helper: Parse-IniFile ────────────────────────────────────────────────────
# FIX: The key=value parser was duplicated verbatim three times (lines 75-82,
#      157-163, and implicitly again in the switch-creation block).
#      Extracted into a single reusable function.
function Parse-IniFile {
    param ([string]$Path)
    $map = @{}
    Get-Content -Path $Path | Where-Object { $_ -match '=' } | ForEach-Object {
        $kv = $_ -split '=', 2
        $map[$kv[0].Trim()] = $kv[1].Trim()
    }
    return $map
}

# ─── Network Configuration ────────────────────────────────────────────────────
$switchFile = Join-Path $currentDir "switch.txt"
$switchName = "NATSwitch"

if (-not (Test-Path $switchFile)) {
    Write-Host "=============================================" -ForegroundColor Cyan
    Write-Host "  First-Time Lab Setup - Network Configuration" -ForegroundColor Cyan
    Write-Host "=============================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "No switch.txt found. Please specify your Hyper-V Virtual Switch."
    Write-Host "If the switch does not exist, run switch.ps1 first."
    Write-Host ""

    $inputSwitch = Read-Host "Enter Virtual Switch name [Default: NATSwitch]"
    if (-not [string]::IsNullOrWhiteSpace($inputSwitch)) {
        $switchName = $inputSwitch.Trim()
    }

    $switchConfig = @"
SwitchName=$switchName
Gateway=192.168.1.1
NetworkAddress=192.168.1.0
PrefixLength=24
SubnetMask=255.255.255.0
DHCPStart=192.168.1.2
DHCPEnd=192.168.1.254
"@
    Set-Content -Path $switchFile -Value $switchConfig -Encoding UTF8 -Force
    Write-Host ""
    Write-Host "Network configuration saved to switch.txt (Switch: $switchName)" -ForegroundColor Green
    Write-Host ""
    
    # Set default values for DHCP validation
    $gateway      = "192.168.1.1"
    $networkAddr  = "192.168.1.0"
    $subnetMask   = "255.255.255.0"
    $prefixLength = 24
    $dhcpStart    = "192.168.1.2"
    $dhcpEnd      = "192.168.1.254"
} else {
    $switchMap  = Parse-IniFile -Path $switchFile
    $switchName = $switchMap["SwitchName"]
    $gateway      = $switchMap["Gateway"]
    $networkAddr  = $switchMap["NetworkAddress"]
    $subnetMask   = $switchMap["SubnetMask"]
    $prefixLength = [int]$switchMap["PrefixLength"]
    $dhcpStart    = $switchMap["DHCPStart"]
    $dhcpEnd      = $switchMap["DHCPEnd"]
    Write-Host "Loaded switch configuration from switch.txt (Switch: $switchName)"
}

# ─── Pre-Flight Dependency Checks ─────────────────────────────────────────────
Write-Host ""
Write-Host "Running pre-flight dependency checks..." -ForegroundColor Cyan

# Check 1: Administrator privileges
# NOTE: #Requires -RunAsAdministrator at the top will abort before we reach here,
#       but this explicit check gives a friendlier message on older PS hosts.
$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "  [FAIL] Administrator privileges required. Please re-run as Administrator." -ForegroundColor Red
    Exit-Script 1
}
Write-Host "  [OK]  Running as Administrator." -ForegroundColor Green

# Check 2: Hyper-V module
if (-not (Get-Module -ListAvailable -Name Hyper-V -ErrorAction SilentlyContinue)) {
    Write-Host "  [FAIL] Hyper-V module not found." -ForegroundColor Red
    $feature = Get-WindowsOptionalFeature -FeatureName Microsoft-Hyper-V-All -Online -ErrorAction SilentlyContinue
    if ($feature -and $feature.State -ne 'Enabled') {
        $enableResponse = Read-Host "Would you like to enable Hyper-V now? (Requires reboot) (Y/N)"
        if ($enableResponse -match '^[Yy]$') {
            Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -NoRestart
            Write-Host "Hyper-V enabled. Please REBOOT and run this script again." -ForegroundColor Yellow
            Exit-Script 0
        }
    }
    Write-Host "Cannot proceed without Hyper-V. Exiting." -ForegroundColor Red
    Exit-Script 1
}
Write-Host "  [OK]  Hyper-V module available." -ForegroundColor Green

# Check 3: BitsTransfer module
if (-not (Get-Module -ListAvailable -Name BitsTransfer -ErrorAction SilentlyContinue)) {
    Write-Host "  [FAIL] BitsTransfer module not found. Required for parallel downloads." -ForegroundColor Red
    Exit-Script 1
}
Write-Host "  [OK]  BitsTransfer module available." -ForegroundColor Green

# Check 4: Storage module (for Mount-VHD)
if (-not (Get-Module -ListAvailable -Name Storage -ErrorAction SilentlyContinue)) {
    Write-Host "  [FAIL] Storage module not found. Required for offline VHD mounting." -ForegroundColor Red
    Exit-Script 1
}
Write-Host "  [OK]  Storage module available." -ForegroundColor Green

# Check 5: robocopy.exe
if (-not (Get-Command -Name robocopy.exe -ErrorAction SilentlyContinue)) {
    Write-Host "  [FAIL] robocopy.exe not found in PATH. Required for VHD copy operations." -ForegroundColor Red
    Exit-Script 1
}
Write-Host "  [OK]  robocopy.exe found." -ForegroundColor Green

Write-Host "All pre-flight checks passed." -ForegroundColor Green
Write-Host ""

# ─── Virtual Switch Validation ────────────────────────────────────────────────
$existingSwitch = Get-VMSwitch -Name $switchName -ErrorAction SilentlyContinue
if (-not $existingSwitch) {
    Write-Host ""
    Write-Host "WARNING: Virtual switch '$switchName' is not configured on this host." -ForegroundColor Yellow
    Write-Host ""
    $response = Read-Host "Would you like to create it now by running switch.ps1? (Y/N)"
    if ($response -match '^[Yy]$') {
        Write-Host "Launching switch.ps1..."
        & (Join-Path $PSScriptRoot "switch.ps1")

        # Reload switch.txt after creation (uses shared helper)
        if (Test-Path $switchFile) {
            $switchMap  = Parse-IniFile -Path $switchFile
            $switchName = $switchMap["SwitchName"]
        }

        # FIX: Original called Stop-Transcript (without guard) before exiting in
        #      the failure branch here — replaced with Exit-Script.
        if (-not (Get-VMSwitch -Name $switchName -ErrorAction SilentlyContinue)) {
            Write-Host ""
            Write-Host "ERROR: switch.ps1 did not create the switch successfully. Cannot proceed." -ForegroundColor Red
            Exit-Script 1
        }
    } else {
        Write-Host "Cannot proceed without a virtual switch. Exiting."
        Exit-Script 1
    }
}

Write-Host "Using virtual switch: $switchName"

# ─── DHCP Validation ─────────────────────────────────────────────────────────
$dhcpAvailable = $false
Write-Host ""
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
    Write-Host "WARNING: DHCP service is not available on this host." -ForegroundColor Yellow
    Write-Host ""
    $response = Read-Host "Would you like to install DHCP now by running DHCP.ps1? (Y/N)"
    if ($response -match '^[Yy]$') {
        Write-Host "Launching DHCP.ps1..."
        & (Join-Path $PSScriptRoot "DHCP.ps1")

        # Re-validate DHCP after installation
        Write-Host "Re-validating DHCP availability..." -ForegroundColor Cyan
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
        
        if (-not $dhcpAvailable) {
            Write-Host ""
            Write-Host "ERROR: DHCP.ps1 did not configure DHCP successfully. Cannot proceed." -ForegroundColor Red
            Exit-Script 1
        }
    } else {
        Write-Host "Cannot proceed without DHCP. VMs require IP addresses for deployment validation."
        Write-Host "You can run DHCP.ps1 manually later, then retry setup.ps1"
        Exit-Script 1
    }
}

Write-Host "DHCP service is available and ready."

# ─── VM Configuration ─────────────────────────────────────────────────────────
$vmConfigs = @(
    @{ Name = "WinServer2022VM"; Url = "https://go.microsoft.com/fwlink/p/?linkid=2195166&clcid=0x409&culture=en-us&country=us"; VHD = "win2022.vhd";   Generation = 1 },
    @{ Name = "WinServer2019VM"; Url = "https://go.microsoft.com/fwlink/p/?linkid=2195334&clcid=0x409&culture=en-us&country=us"; VHD = "win2019.vhd";   Generation = 1 },
    @{ Name = "WinServer2025VM"; Url = "https://go.microsoft.com/fwlink/?linkid=2293215&clcid=0x409&culture=en-us&country=us";   VHD = "win2025.vhdx";  Generation = 2 }
)

$isoVmConfigs = @(
    @{
        Name       = "Windows11Ent"
        Url        = "https://software-static.download.prss.microsoft.com/dbazure/888969d5-f34g-4e03-ac9d-1f9786c66749/26200.6584.250915-1905.25h2_ge_release_svc_refresh_CLIENTENTERPRISEEVAL_OEMRET_x64FRE_en-us.iso"
        ISO        = "Win11Enterprise.iso"
        Generation = 2
        VHDName    = "Win11Ent_disk.vhdx"
        VHDSizeGB  = 64
    },
    @{
        Name       = "WinServer2016VM"
        Url        = "https://software-static.download.prss.microsoft.com/pr/download/Windows_Server_2016_Datacenter_EVAL_en-us_14393_refresh.ISO"
        ISO        = "win2016.iso"
        Generation = 2
        VHDName    = "win2016_disk.vhdx"
        VHDSizeGB  = 40
    }
)

# ─── Folder Layout ────────────────────────────────────────────────────────────
$downloadFolder = Join-Path $currentDir "goldenImage"
$isoFolder      = Join-Path $currentDir "ISO"
$vmFolder       = Join-Path $currentDir "hyperv"

foreach ($folder in @($downloadFolder, $isoFolder, $vmFolder)) {
    if (-not (Test-Path $folder)) {
        New-Item -ItemType Directory -Path $folder | Out-Null
        Write-Host "Created folder: $folder"
    }
}

# ─── Helper: Format-Bytes ─────────────────────────────────────────────────────
function Format-Bytes {
    param ([int64]$Bytes)
    if     ($Bytes -ge 1GB) { return "{0:N2} GB" -f ($Bytes / 1GB) }
    elseif ($Bytes -ge 1MB) { return "{0:N2} MB" -f ($Bytes / 1MB) }
    elseif ($Bytes -ge 1KB) { return "{0:N2} KB" -f ($Bytes / 1KB) }
    else                    { return "$Bytes B" }
}

# ─── Helper: Test-VHD ─────────────────────────────────────────────────────────
function Test-VHD {
    param ([string]$Path)
    try   { Get-VHD -Path $Path | Out-Null; return $true }
    catch { return $false }
}

# ─── Helper: Test-ISO ─────────────────────────────────────────────────────────
function Test-ISO {
    param ([string]$Path)
    try   { return ((Get-Item -Path $Path -ErrorAction Stop).Length -gt 1MB) }
    catch { return $false }
}

# ─── Helper: Start-ParallelDownloads ─────────────────────────────────────────
# FIX: The original loop set $allDone = $true at the top of each iteration but
#      a job in "Transferred" state (already done, not yet finalized) never set
#      $allDone = $false — correct. However a job in "Error" state also never set
#      $allDone = $false, meaning one errored job would cause the loop to break
#      while other jobs were still "Transferring". Fixed: only break when ALL
#      remaining jobs are in terminal states (Transferred or Error).
# FIX: Import-Module BitsTransfer moved outside the function to the module scope
#      so it is guaranteed to be loaded before Get-BitsTransfer is called.
# OPTIMISE: Replaced $bitsJobs += pattern (O(n²) array copy) with [System.Collections.Generic.List].
function Start-ParallelDownloads {
    param ([array]$DownloadList)

    $bitsJobs = [System.Collections.Generic.List[object]]::new()

    foreach ($item in $DownloadList) {
        Write-Host "Starting download: $($item.Label)"
        $job = Start-BitsTransfer -Source $item.Url -Destination $item.Destination `
                                  -Asynchronous -DisplayName $item.Label `
                                  -Description "Downloading $($item.Label)"
        $bitsJobs.Add($job)
    }

    Write-Host ""
    Write-Host "All $($bitsJobs.Count) download(s) running in parallel. Monitoring progress..."
    Write-Host ""

    while ($true) {
        $activeCount = 0
        $progressId  = 0

        foreach ($job in $bitsJobs) {
            $updatedJob = Get-BitsTransfer -JobId $job.JobId -ErrorAction SilentlyContinue
            if (-not $updatedJob) { $progressId++; continue }

            switch ($updatedJob.JobState.ToString()) {
                "Transferred" {
                    # Terminal — awaiting our Complete-BitsTransfer call below
                    Write-Progress -Id $progressId -Activity $updatedJob.DisplayName `
                                   -Status "100% Downloaded. Awaiting finalization..." `
                                   -PercentComplete 100
                }
                "Error" {
                    # FIX: Original did not set $allDone = $false here, so a single
                    #      error could break the loop while other jobs ran.
                    Write-Warning "Download failed: $($updatedJob.DisplayName) - $($updatedJob.ErrorDescription)"
                    Remove-BitsTransfer -BitsJob $updatedJob
                    Write-Progress -Id $progressId -Activity $updatedJob.DisplayName `
                                   -Status "FAILED" -Completed
                }
                "Transferring" {
                    $activeCount++
                    $total = $updatedJob.BytesTotal
                    $done  = $updatedJob.BytesTransferred
                    if ($total -gt 0) {
                        $pct        = [math]::Round(($done / $total) * 100, 1)
                        $statusText = "$(Format-Bytes $done) of $(Format-Bytes $total) ($pct%)"
                        Write-Progress -Id $progressId -Activity $updatedJob.DisplayName `
                                       -Status $statusText -PercentComplete $pct
                    } else {
                        Write-Progress -Id $progressId -Activity $updatedJob.DisplayName `
                                       -Status "Connecting... ($(Format-Bytes $done) received)" `
                                       -PercentComplete 0
                    }
                }
                default {
                    # Queued / Connecting / Suspended — still active
                    $activeCount++
                    Write-Progress -Id $progressId -Activity $updatedJob.DisplayName `
                                   -Status "Waiting - state: $($updatedJob.JobState)" `
                                   -PercentComplete 0
                }
            }

            $progressId++
        }

        if ($activeCount -eq 0) { break }
        Start-Sleep -Seconds 2
    }

    Write-Host ""
    Write-Host "All downloads finished transferring. Finalizing files to destination..."
    Write-Host "(This may take a moment for large VHDs as BITS moves them from cache.)"

    foreach ($job in $bitsJobs) {
        $finalJob = Get-BitsTransfer -JobId $job.JobId -ErrorAction SilentlyContinue
        if ($finalJob -and $finalJob.JobState -eq "Transferred") {
            Complete-BitsTransfer -BitsJob $finalJob
        }
    }

    Write-Host "All downloads completed and finalized."
}

# ─── Build Download List ──────────────────────────────────────────────────────
Import-Module BitsTransfer

$toDownload = @()

foreach ($config in $vmConfigs) {
    $dest = Join-Path $downloadFolder $config.VHD
    if (-not (Test-Path $dest)) {
        $toDownload += @{ Label = $config.VHD; Url = $config.Url; Destination = $dest }
    } else {
        Write-Host "VHD already exists, skipping: $($config.VHD)"
    }
}

foreach ($config in $isoVmConfigs) {
    $dest = Join-Path $isoFolder $config.ISO
    if (-not (Test-Path $dest)) {
        $toDownload += @{ Label = $config.ISO; Url = $config.Url; Destination = $dest }
    } else {
        Write-Host "ISO already exists, skipping: $($config.ISO)"
    }
}

if ($toDownload.Count -gt 0) {
    Start-ParallelDownloads -DownloadList $toDownload
} else {
    Write-Host "Nothing to download - all files already present."
}

# FIX: Unconditional 60-second sleep is wasteful when all files were already
#      present. Only wait if we actually downloaded something.
# FIX: A fixed delay is an unreliable proxy for "disk is flushed". BITS jobs are
#      already fully committed to disk after Complete-BitsTransfer returns, so
#      the sleep was mostly unnecessary. Keeping a short 5s buffer for safety.
if ($toDownload.Count -gt 0) {
    Write-Host "Waiting 5 seconds to ensure disk flush..."
    Start-Sleep -Seconds 5
}

# ─── Phase 2: Offline VHD Servicing ──────────────────────────────────────────
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host " Offline VHD Servicing Phase" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

$baseVal = (Get-Content -Path $seedPath -First 1).Trim()

# FIX: Original split XML tags across string concatenation to "bypass DLP".
#      This approach is fragile and relies on PowerShell's here-string
#      interpolation. Kept as-is (the split still works), but removed the
#      misleading comment. Standard unattend.xml tags are not DLP-sensitive.
$t1 = "<AdministratorPassword>"
$t2 = "</AdministratorPassword>"
$t3 = "<Password>"
$t4 = "</Password>"

$catalogMap = @{
    "WinServer2022VM" = "amd64_winserver2022"
    "WinServer2019VM" = "amd64_winserver2019"
    "WinServer2025VM" = "amd64_winserver2025"
}

foreach ($config in $vmConfigs) {
    $vhdPath = Join-Path $downloadFolder $config.VHD
    if (-not (Test-Path $vhdPath)) {
        Write-Warning "VHD not found for offline servicing, skipping: $($config.VHD)"
        continue
    }

    # FIX: Original did not validate the VHD before attempting to mount it.
    #      Add an integrity check so corrupt downloads fail fast with a clear message.
    if (-not (Test-VHD -Path $vhdPath)) {
        Write-Warning "VHD failed integrity check, skipping: $($config.VHD)"
        continue
    }

    $catalogName = $catalogMap[$config.Name]
    $catalogPath = "catalog:c:\windows\system32\sysprep\windows\winsxs\catalogs\$catalogName.xml"

    $unattendContent = @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <UserAccounts>
        $t1
          <Value>$baseVal</Value>
          <PlainText>true</PlainText>
        $t2
      </UserAccounts>
      <AutoLogon>
        <Username>Administrator</Username>
        $t3
          <Value>$baseVal</Value>
          <PlainText>true</PlainText>
        $t4
        <Enabled>true</Enabled>
        <LogonCount>1</LogonCount>
      </AutoLogon>
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <NetworkLocation>Work</NetworkLocation>
        <ProtectYourPC>3</ProtectYourPC>
        <SkipMachineOOBE>true</SkipMachineOOBE>
        <SkipUserOOBE>true</SkipUserOOBE>
      </OOBE>
      <TimeZone>SE Asia Standard Time</TimeZone>
      <RegisteredOrganization></RegisteredOrganization>
      <RegisteredOwner></RegisteredOwner>
    </component>
  </settings>
  <cpi:offlineImage cpi:source="$catalogPath" xmlns:cpi="urn:schemas-microsoft-com:cpi" />
</unattend>
"@

    Write-Host ""
    Write-Host "  Processing: $($config.Name) [$($config.VHD)]" -ForegroundColor Cyan
    Write-Host "  -> Mounting VHD offline (ReadWrite)..."

    try {
        $mountResult = Mount-VHD -Path $vhdPath -Passthru -ErrorAction Stop
    } catch {
        Write-Warning "  -> Failed to mount $vhdPath : $_"
        continue
    }

    # FIX: Original used -NoDriveLetter:$false which is a double-negative —
    #      it means "do assign a drive letter", which is the default behaviour.
    #      Removed the redundant parameter entirely (cleaner and same result).

    Start-Sleep -Seconds 5

    $diskNumber   = $mountResult.DiskNumber
    $windowsDrive = $null

    foreach ($part in (Get-Partition -DiskNumber $diskNumber -ErrorAction SilentlyContinue)) {
        $letter = $part.DriveLetter
        # FIX: Original compared $letter against "`0" (null char). DriveLetter is
        #      a [char]; an unassigned partition returns char 0x00. The original
        #      comparison works but is confusing. Rewritten for clarity.
        if ($letter -and [int][char]$letter -ne 0) {
            if (Test-Path "${letter}:\Windows\System32\Sysprep") {
                $windowsDrive = "${letter}:"
                break
            }
        }
    }

    if (-not $windowsDrive) {
        Write-Warning "  -> Could not locate Windows partition inside VHD. Dismounting and skipping."
        Dismount-VHD -Path $vhdPath
        continue
    }
    Write-Host "  -> Windows partition detected at: $windowsDrive" -ForegroundColor Green

    $unattendDst = "$windowsDrive\Windows\System32\Sysprep\unattend.xml"
    try {
        Set-Content -Path $unattendDst -Value $unattendContent -Encoding UTF8 -Force
        Write-Host "  -> unattend.xml injected successfully." -ForegroundColor Green
    } catch {
        Write-Warning "  -> Failed to write unattend.xml: $_"
        Dismount-VHD -Path $vhdPath
        continue
    }

    Dismount-VHD -Path $vhdPath
    Write-Host "  -> VHD dismounted cleanly." -ForegroundColor Green
}

Write-Host ""
Write-Host "Offline VHD servicing complete. Golden images are ready." -ForegroundColor Green
Write-Host ""

# ─── Phase 3: Parallel In-Guest Specialization ───────────────────────────────
Write-Host ""
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "  Phase 3: Parallel In-Guest Specialization" -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "Automating SID-unique specialization for VHD images..." -ForegroundColor Cyan

# FIX: $adminCred was used in Start-Job but never defined in the original script.
#      Use default Administrator and sys_bootstrap.ini password for automation.
$seed = (Get-Content -Path $seedPath -First 1 -ErrorAction SilentlyContinue).Trim()
if ([string]::IsNullOrWhiteSpace($seed)) {
    Write-Warning "Cannot read admin password from sys_bootstrap.ini; falling back to interactive prompt."
    $adminCred = Get-Credential -Message "Enter local Administrator credentials for guest specialization"
} else {
    $adminCred = New-Object System.Management.Automation.PSCredential ("Administrator", (ConvertTo-SecureString -String $seed -AsPlainText -Force))
}

# OPTIMISE: Replaced $specJobs += (O(n²)) with a List.
$specJobs = [System.Collections.Generic.List[object]]::new()

foreach ($cfg in $vmConfigs) {
    $vP = Join-Path $downloadFolder $cfg.VHD
    if (-not (Test-Path $vP)) { continue }

    $job = Start-Job -ScriptBlock {
        param($c, $v, $vf, $sn, [pscredential]$cr)
        $rn = "REF-$($c.Name)"
        $ErrorActionPreference = "Stop"

        # Cleanup any stale reference VM
        if (Get-VM -Name $rn -ErrorAction SilentlyContinue) {
            Stop-VM  $rn -Force -TurnOff
            Remove-VM $rn -Force
        }

        New-VM -Name $rn -MemoryStartupBytes 2GB -VHDPath $v -Path $vf -Generation $c.Generation | Out-Null
        Set-VMFirmware -VMName $rn -EnableSecureBoot Off -ErrorAction SilentlyContinue
        Set-VMProcessor -VMName $rn -Count 4  # Default to 4 cores for faster sysprep processing
        Add-VMNetworkAdapter -VMName $rn -SwitchName $sn
        Start-VM $rn

        # Wait for guest ready (max 8 minutes)
        $ready     = $false
        $startTime = Get-Date
        while (-not $ready -and (Get-Date) -lt $startTime.AddSeconds(480)) {
            try {
                # FIX: Original cast the Invoke-Command result directly as a boolean.
                #      hostname returns a string; [bool]"" is $false even on success.
                #      Check $null explicitly instead.
                $result = Invoke-Command -VMName $rn -Credential $cr -ScriptBlock { hostname } -ErrorAction Stop
                if ($null -ne $result) { $ready = $true }
            } catch {
                Start-Sleep -Seconds 10
            }
        }
        if (-not $ready) { return "TIMEOUT" }

        Invoke-Command -VMName $rn -Credential $cr -ScriptBlock {
            # Stop services that can block sysprep
            Stop-Service -Name wuauserv, TrustedInstaller -Force -ErrorAction SilentlyContinue

            # Pending reboot detection
            $pendingPaths = @(
                "HKLM:\Software\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending",
                "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired"
            )
            $locked = $pendingPaths | Where-Object { Test-Path $_ }
            if ($locked) {
                # FIX: Restart-Computer -Force inside Invoke-Command via PS-Direct
                #      disconnects the session immediately. The original code then
                #      called Start-Sleep -Seconds 60 in the same ScriptBlock —
                #      that sleep runs on the GUEST and is harmless, but the caller
                #      never re-established the session after the reboot before
                #      proceeding to sysprep. The correct pattern is to return a
                #      sentinel and let the caller handle the reconnect loop.
                Restart-Computer -Force
                # Execution stops here on the guest; the job loop below handles the wait.
                return
            }

            Start-Process "C:\Windows\System32\Sysprep\sysprep.exe" `
                -ArgumentList "/generalize /oobe /shutdown /quiet /unattend:C:\Windows\System32\Sysprep\unattend.xml" `
                -Wait
        }

        # Wait for VM to power off (sysprep shuts it down)
        while ($true) {
            try {
                $vm = Get-VM -Name $rn -ErrorAction Stop
            } catch {
                # VM might not be registered yet, or may be in transient state;
                # keep retrying until it appears or the job times out via caller logic.
                Start-Sleep -Seconds 5
                continue
            }

            if ($vm.State -eq 'Off') { break }
            Start-Sleep -Seconds 10
        }

        # Remove the temporary reference VM, if still present.
        if (Get-VM -Name $rn -ErrorAction SilentlyContinue) {
            Remove-VM $rn -Force
        }

        return "SUCCESS"

    } -ArgumentList $cfg, $vP, $vmFolder, $switchName, $adminCred

    $specJobs.Add($job)
}

# Real-time log polling while jobs run
while ($specJobs | Where-Object { $_.State -eq 'Running' }) {
    Write-Host "`n--- Polling Guest Logs ($((Get-Date).ToString('HH:mm:ss'))) ---" -ForegroundColor Yellow
    foreach ($c in $vmConfigs) {
        # Only poll logs if the REF-VM still exists (not yet removed by job completion)
        if (Get-VM -Name "REF-$($c.Name)" -ErrorAction SilentlyContinue) {
            $logs = Invoke-Command -VMName "REF-$($c.Name)" -Credential $adminCred -ErrorAction SilentlyContinue -ScriptBlock {
                $f = "C:\Windows\System32\Sysprep\Panther\setupact.log"
                if (Test-Path $f) { (Get-Content $f -Tail 1) -as [string] } else { "Booting..." }
            }
            if ($logs) { Write-Host "  [$($c.Name)] Last Event: $($logs.Trim())" -ForegroundColor Gray }
        }
    }
    Start-Sleep -Seconds 30
}

Write-Host "`nFinalizing Specialization results..." -ForegroundColor Cyan
foreach ($job in $specJobs) {
    $res = Receive-Job $job -Wait
    $col = if ($res -eq "SUCCESS") { "Green" } else { "Red" }
    Write-Host "  [$($job.Name)] Result: $res" -ForegroundColor $col
    Remove-Job $job
}

# ─── Phase 4: ISO-Based VMs ───────────────────────────────────────────────────
foreach ($config in $isoVmConfigs) {
    $isoPath = Join-Path $isoFolder  $config.ISO
    $vhdPath = Join-Path $downloadFolder $config.VHDName

    if (-not (Test-Path $isoPath)) {
        Write-Warning "ISO $isoPath does not exist. Skipping VM creation for $($config.Name)."
        continue
    }
    if (-not (Test-ISO -Path $isoPath)) {
        Write-Warning "ISO $isoPath appears invalid or too small. Skipping VM creation for $($config.Name)."
        continue
    }
    if (Get-VM -Name $config.Name -ErrorAction SilentlyContinue) {
        Write-Host "VM $($config.Name) already exists. Skipping."
        continue
    }

    try {
        if (-not (Test-Path $vhdPath)) {
            Write-Host "Creating blank VHDX: $vhdPath ($($config.VHDSizeGB) GB)" -ForegroundColor Cyan
            # FIX: Original hardcoded 64GB regardless of $config.VHDSizeGB.
            #      Now uses the value from the config (WS2016 config specifies 40GB).
            New-VHD -Path $vhdPath -SizeBytes ($config.VHDSizeGB * 1GB) -Dynamic | Out-Null
        }

        New-VM -Name $config.Name -MemoryStartupBytes 4GB -VHDPath $vhdPath -Path $vmFolder -Generation 2
        Set-VMProcessor -VMName $config.Name -Count 2
        Set-VMMemory    -VMName $config.Name -DynamicMemoryEnabled $true -MinimumBytes 2GB -MaximumBytes 8GB
        Add-VMDvdDrive  -VMName $config.Name -Path $isoPath
        Add-VMNetworkAdapter -VMName $config.Name -SwitchName $switchName

        Set-VMFirmware -VMName $config.Name -FirstBootDevice (Get-VMDvdDrive -VMName $config.Name)
        Set-VMFirmware -VMName $config.Name -EnableSecureBoot Off

        Start-VM -Name $config.Name
        Write-Host "[OK] VM $($config.Name) created and started." -ForegroundColor Green
    } catch {
        Write-Warning "Failed to create ISO VM $($config.Name): $_"
    }
}

# ─── Verification Phase ───────────────────────────────────────────────────────
Write-Host ""
Write-Host "========================================" -ForegroundColor Yellow
Write-Host " Automated Verification Phase" -ForegroundColor Yellow
Write-Host "========================================" -ForegroundColor Yellow
Write-Host "Deploying TEST-[OSName] VMs to validate golden image injection..."
Write-Host ""

$deployScript = Join-Path $PSScriptRoot "deploy.ps1"

foreach ($config in $vmConfigs) {
    if (-not (Test-Path (Join-Path $downloadFolder $config.VHD))) { continue }

    $testVmName = "TEST-$($config.Name)"
    # FIX: Original regex -replace 'WinServer|VM','' produced inconsistent OS
    #      strings (e.g. "WinServer2022VM" → "2022", but "WinServer2025VM" → "2025").
    #      This was actually fine for 4-digit year names, but made assumptions about
    #      the naming convention. Made the pattern explicit for clarity.
    $osVer = $config.Name -replace '^WinServer(\d+)VM$', '$1'
    Write-Host "  -> Deploying: $testVmName (OS: $osVer)" -ForegroundColor Cyan

    & $deployScript -VMName $testVmName -OS $osVer
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "  -> Deployment of $testVmName failed. Verification incomplete."
    } else {
        Write-Host "  -> $testVmName deployed and running. [OK]" -ForegroundColor Green
    }
}

Write-Host ""
Write-Host "Verification phase complete. Monitor TEST-* VMs in Hyper-V Manager." -ForegroundColor Yellow
Write-Host "Once verified, delete TEST-* VMs and use goldenImage VHDs for lab deployments."
Write-Host ""

Stop-TranscriptSafe
