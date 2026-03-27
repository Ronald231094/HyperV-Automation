# Hyper-V Automation Lab Suite - Error Handling Patterns

## 🚨 Error Handling Philosophy

The Hyper-V Automation Lab Suite implements comprehensive error handling to ensure reliable automation in complex infrastructure environments. Our approach emphasizes **graceful degradation**, **user-friendly recovery**, and **detailed diagnostics**.

## 🎯 Core Principles

### **Fail Fast, Recover Easy**
- Stop execution immediately on critical errors
- Provide clear error messages and recovery instructions
- Generate replay commands for failed operations

### **Defense in Depth**
- Multiple validation layers
- Fallback mechanisms for common issues
- Comprehensive logging for post-mortem analysis

### **User-Centric Design**
- Error messages explain what went wrong and how to fix it
- Recovery commands are copy-paste ready
- Progress indicators keep users informed

## 📋 Error Handling Patterns

### **1. Script-Level Error Handling**

#### **Transcript Safety**
```powershell
# ─── Transcript Safety ────────────────────────────────────────────────────────
$transcriptActive = $false
try { $transcriptActive = $null -ne (Get-Transcript -ErrorAction SilentlyContinue) } catch { }
if (-not $transcriptActive) {
    $timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
    $logsDir   = Join-Path $PSScriptRoot "logs"
    New-Item -ItemType Directory -Path $logsDir -Force | Out-Null
    Start-Transcript -Path (Join-Path $logsDir "Script_$timestamp.txt") -Append
}

function Stop-Safe { if (-not $transcriptActive) { try { Stop-Transcript } catch { } } }
function Exit-Script ([int]$Code = 1) {
    Write-ReplayCommand
    Stop-Safe
    exit $Code
}
```

#### **Global Error Preference**
```powershell
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
```

### **2. Parameter Validation**

#### **Required Parameter Checks**
```powershell
# ─── Prompt for missing parameters ───────────────────────────────────────────
if (-not $DCName)    { $DCName     = Read-Host "Enter Domain Controller VM Name" }
if (-not $DomainName){ $DomainName = Read-Host "Enter Domain Name (e.g., corp.local)" }

# ─── Parameter validation ────────────────────────────────────────────────────
if ([string]::IsNullOrWhiteSpace($VMNames)) {
    Write-Error "No VM names provided."
    Exit-Script 1
}
```

#### **Array Parameter Conversion**
```powershell
if ($null -eq $VMNames) {
    $VMNames = @((Read-Host "Enter VM names (comma-separated)") -split ',' |
                 ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
} else {
    # Convert comma-separated string parameter to array
    $VMNames = @($VMNames -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
}
```

### **3. External Operation Error Handling**

#### **VM Operations**
```powershell
try {
    $vm = Get-VM -Name $VMName -ErrorAction Stop
    Start-VM -Name $VMName -ErrorAction Stop
    Write-Host "  [OK]  '$VMName' started successfully." -ForegroundColor Green
} catch {
    Write-Error "Failed to start VM '$VMName': $_"
    Exit-Script 1
}
```

#### **PowerShell Direct Operations**
```powershell
try {
    $result = Invoke-Command -VMName $vmName -Credential $cred -ErrorAction Stop -ScriptBlock {
        # Guest operations here
        Get-Service -Name $serviceName
    }
} catch {
    Write-Error "Failed to execute command on VM '$vmName': $_"
    Exit-Script 1
}
```

#### **Network Operations**
```powershell
$maxRetries = 3
$retryCount = 0

do {
    $retryCount++
    try {
        $response = Invoke-WebRequest -Uri $url -ErrorAction Stop
        break
    } catch {
        Write-Warning "Download attempt $retryCount/$maxRetries failed: $_"
        if ($retryCount -lt $maxRetries) {
            Start-Sleep -Seconds (5 * $retryCount)  # Exponential backoff
        }
    }
} while ($retryCount -lt $maxRetries)

if ($retryCount -gt $maxRetries) {
    Write-Error "Failed to download from $url after $maxRetries attempts."
    Exit-Script 1
}
```

### **4. Recovery Mechanisms**

#### **Replay Command Generation**
```powershell
function Write-ReplayCommand {
    Write-Host "`n" -ForegroundColor Cyan
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host "  REPLAY COMMAND (copy-paste to rerun)" -ForegroundColor Cyan
    Write-Host "==========================================" -ForegroundColor Cyan

    $vmNamesStr = $VMNames -join ','
    $cmd = "& '$($MyInvocation.ScriptName)'"
    $cmd += " -DCName '$DCName'"
    $cmd += " -DomainName '$DomainName'"
    # Add other parameters...

    Write-Host $cmd -ForegroundColor Yellow
    Write-Host "`n" -ForegroundColor Cyan
}
```

#### **Retry Command for Orchestrators**
```powershell
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
```

### **5. Expected Error Handling**

#### **Domain Controller Promotion**
```powershell
try {
    Invoke-Command -VMName $VMName -Credential $adminCred -ErrorAction Stop -ScriptBlock {
        # DC promotion logic
        Install-ADDSForest -DomainName $domainName -SafeModeAdministratorPassword $safeModePassword
    }
} catch {
    # BUG FIX: Install-ADDSForest triggers an automatic reboot. The original code
    # had no error handling here — any failure would silently continue.
    $exType = $_.Exception.GetType().Name
    $exMsg  = $_.Exception.Message
    $isExpectedDisconnect =
        ($exType -match 'PSRemotingTransportException|PipelineStoppedException') -or
        ($exMsg  -match 'The pipeline has been stopped|connection.*closed|virtual machine.*turned off')
    if (-not $isExpectedDisconnect) {
        Write-Error "DC promotion failed unexpectedly: $_"
        Exit-Script 1
    }
    Write-Host "  -> DC is rebooting as part of domain promotion (expected)." -ForegroundColor Yellow
}
```

#### **Hyper-V Role Installation**
```powershell
Invoke-Command -VMName $vh -Credential $domainAdminCred -ErrorAction Stop -ScriptBlock {
    $feature = Get-WindowsFeature -Name Hyper-V
    if ($feature.InstallState -ne 'Installed') {
        $result = Install-WindowsFeature -Name Hyper-V -IncludeManagementTools -ErrorAction Stop
        if (-not $result.Success) { throw "Hyper-V feature install failed." }
        Restart-Computer -Force
    }
}

# Wait for expected disconnect and reconnect
Start-Sleep -Seconds 90
```

### **6. Validation & Pre-flight Checks**

#### **File Existence Checks**
```powershell
# ─── Read credentials ────────────────────────────────────────────────────────
$currentDir = $PSScriptRoot
$seedPath   = Join-Path $currentDir "sys_bootstrap.ini"

if (-not $InitCode) {
    if (-not (Test-Path $seedPath)) {
        Write-Error "sys_bootstrap.ini not found at: $seedPath"
        Exit-Script 1
    }
    $baseVal = (Get-Content -Path $seedPath | Select-Object -First 1).Trim()
    if ([string]::IsNullOrWhiteSpace($baseVal)) {
        Write-Error "sys_bootstrap.ini is empty."
        Exit-Script 1
    }
    $InitCode = ConvertTo-SecureString $baseVal -AsPlainText -Force
}
```

#### **VM State Validation**
```powershell
# ─── Pre-validate: no VM name collisions ──────────────────────────────────────
foreach ($vmName in $vmNames) {
    if (Get-VM -Name $vmName -ErrorAction SilentlyContinue) {
        Write-Error "VM '$vmName' already exists in Hyper-V. Remove it first or use a different name."
        Exit-Script 1
    }
}
```

#### **Network Connectivity Tests**
```powershell
# ─── Validate DC connectivity ────────────────────────────────────────────────
Write-Host "Validating Domain Controller connectivity..." -ForegroundColor Cyan
try {
    $testSession = New-PSSession -VMName $DcVmName -Credential $domainAdminCred -ErrorAction Stop
    Remove-PSSession -Session $testSession -ErrorAction SilentlyContinue
    Write-Host "  [OK]  DC '$DcVmName' is reachable." -ForegroundColor Green
} catch {
    Write-Error "Cannot connect to DC '$DcVmName': $_"
    Exit-Script 1
}
```

### **7. Timeout & Retry Logic**

#### **VM Boot Waiting**
```powershell
Write-Host "`nWaiting for guest IP address (up to 2 minutes)..." -ForegroundColor Cyan
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
```

#### **Domain Join Verification**
```powershell
$timeout     = (Get-Date).AddMinutes(15)
$domainLabel = $DomainToJoin.Split('.')[0]

while ($joinedState.Values -contains $false) {
    if ((Get-Date) -gt $timeout) {
        $pending = $joinedState.GetEnumerator() | Where-Object { -not $_.Value } | ForEach-Object { $_.Key }
        Write-Warning "15-minute timeout reached. VMs still not confirmed: $($pending -join ', ')"
        break
    }

    foreach ($vm in $vmNamesArray) {
        if ($joinedState[$vm]) { continue }

        # Try both local and domain credentials (credential fallback)
        $currentCred = $vmAdminCred
        $domainChecked = $false

        try {
            $domainStatus = Invoke-Command -VMName $vm -Credential $currentCred -ErrorAction Stop -ScriptBlock {
                (Get-CimInstance Win32_ComputerSystem).Domain
            }
            if ($domainStatus -match [regex]::Escape($domainLabel)) {
                Write-Host "  [OK]  '$vm' is now a member of '$domainStatus'." -ForegroundColor Green
                $joinedState[$vm] = $true
            }
        } catch {
            # Try domain credentials if local fails
            if (-not $domainChecked) {
                try {
                    $currentCred = $domainVmCred
                    $domainChecked = $true
                    # Retry with domain credentials...
                } catch {
                    Write-Host "  -> '$vm' unreachable (still rebooting). Waiting..." -ForegroundColor Yellow
                }
            }
        }
    }

    if ($joinedState.Values -contains $false) { Start-Sleep -Seconds 15 }
}
```

### **8. Logging & Diagnostics**

#### **Comprehensive Logging**
```powershell
# All major operations are logged via Start-Transcript
# Logs are stored in logs/ directory with timestamped names
# Format: ScriptName_YYYY-MM-DD_HH-MM-SS.txt
```

#### **Progress Indicators**
```powershell
Write-Host "`nStarting parallel VHD copy for $($vmNames.Count) VM(s)..." -ForegroundColor Cyan

$copyProcesses = @{}
$vmProgress    = @{}

# Real-time progress updates during long operations
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
```

## 🚨 Error Classification

### **Critical Errors** (Immediate Exit)
- Missing required files (sys_bootstrap.ini)
- Network configuration issues
- VM creation failures
- Domain controller promotion failures

### **Recoverable Errors** (Retry/Continue)
- Temporary network connectivity issues
- VM boot delays
- Service startup timing issues
- Credential context changes

### **Expected Errors** (Handled Gracefully)
- PS Direct disconnections during reboots
- Domain credential transitions
- Hyper-V role installation reboots

## 🛠️ Debugging Tools

### **Transcript Analysis**
- All scripts generate detailed transcripts
- Include timestamps, commands executed, and outputs
- Essential for post-mortem analysis

### **Verbose Logging**
- Progress indicators for long-running operations
- Status updates every 15-30 seconds
- Clear success/failure indicators

### **Error Context**
- Include relevant parameters in error messages
- Show current operation state
- Provide specific recovery instructions

---

*Generated: March 27, 2026 | Hyper-V Lab Suite v3.0*</content>
<parameter name="filePath">C:\Users\ronald\Desktop\workplace\Rule\Error-Handling.md