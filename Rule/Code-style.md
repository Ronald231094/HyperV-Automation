# Hyper-V Automation Lab Suite - Code Style Guidelines

## 📝 PowerShell Coding Standards

This document outlines the coding conventions and style guidelines used throughout the Hyper-V Automation Lab Suite.

## 🎯 Core Principles

### **Consistency**
- All scripts follow the same patterns and conventions
- Code style is uniform across the entire codebase
- Naming conventions are strictly followed

### **Readability**
- Clear, descriptive variable and function names
- Comprehensive comments explaining complex logic
- Logical code organization with clear sections

### **Maintainability**
- Modular functions with single responsibilities
- Consistent error handling patterns
- Well-documented parameter usage

## 📏 Code Formatting

### **Script Structure**
```powershell
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Brief description of script purpose.
.DESCRIPTION
    Detailed description of functionality, parameters, and usage.
.PARAMETER ParamName
    Parameter description and usage.
.EXAMPLE
    .\Script.ps1 -Param1 "value"
#>

param (
    [Parameter(Mandatory = $true)]
    [string]$Param1,

    [Parameter(Mandatory = $false)]
    [string]$Param2 = "default"
)

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

# ─── Main script logic ────────────────────────────────────────────────────────
# Implementation here
```

### **Comment Style**
```powershell
# ─── Section Header ───────────────────────────────────────────────────────────
# Brief description of section purpose

# BUG FIX: Description of bug and fix applied
# FEATURE: Description of feature implementation

# Inline comments for complex logic
$result = Complex-Calculation  # Why this calculation is needed
```

### **Variable Naming**
```powershell
# Use PascalCase for global variables and parameters
$CurrentDir = $PSScriptRoot
$DomainName = "corp.local"

# Use camelCase for local variables
$vmList = @()
$retryCount = 0

# Use descriptive names
$domainControllerName = "DC01"  # Not $dc or $d
$virtualMachineList = @()       # Not $vms or $list
```

## 🔧 PowerShell Best Practices

### **Strict Mode & Error Handling**
```powershell
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Always use try/catch for external operations
try {
    $result = Invoke-Command -VMName $vmName -ScriptBlock { Get-Service }
} catch {
    Write-Error "Failed to query services on $vmName`: $_"
    Exit-Script 1
}
```

### **Parameter Validation**
```powershell
param (
    [Parameter(Mandatory = $true)]
    [ValidateSet("2016","2019","2022","2025")]
    [string]$OS,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-zA-Z0-9\-_]+$')]
    [string]$VMName
)
```

### **Function Design**
```powershell
function Get-VmStatus {
    param (
        [Parameter(Mandatory = $true)]
        [string]$VMName
    )

    # Function logic here
    return $status
}

# Usage
$status = Get-VmStatus -VMName "TestVM"
```

## 📊 Code Organization Patterns

### **Section Headers**
Use consistent header formatting:
```powershell
# ─── Section Name ────────────────────────────────────────────────────────────
# Brief description of what this section does
```

### **Parameter Processing**
```powershell
# ─── Prompt for missing parameters ───────────────────────────────────────────
if (-not $DCName)    { $DCName     = Read-Host "Enter Domain Controller VM Name" }
if (-not $DomainName){ $DomainName = Read-Host "Enter Domain Name (e.g., corp.local)" }

# ─── Parameter validation ────────────────────────────────────────────────────
if ($null -eq $VMNames) {
    # Convert comma-separated string to array
    $VMNames = @((Read-Host "Enter VM names (comma-separated)") -split ',' |
                 ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
}
```

### **Error Recovery**
```powershell
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

## 🎨 Output Formatting

### **Progress Messages**
```powershell
Write-Host "`nStarting Domain Controller creation..." -ForegroundColor Cyan
Write-Host "  [OK]  DC '$DCName' created successfully." -ForegroundColor Green
Write-Host "  [FAIL] Could not create DC '$DCName'." -ForegroundColor Red
Write-Host "  -> Waiting for VM to respond... (attempt $attempt/$maxAttempts)" -ForegroundColor Yellow
```

### **Status Indicators**
- `[OK]` - Success confirmation
- `[FAIL]` - Error condition
- `[INFO]` - Informational message
- `->` - Progress or waiting status

### **Color Coding**
- `Cyan` - Section headers and major operations
- `Green` - Success confirmations
- `Red` - Errors and failures
- `Yellow` - Warnings and progress updates
- `Gray` - Debug/diagnostic information

## 🔍 Code Quality Checks

### **Required Elements**
- [ ] `#Requires -RunAsAdministrator` at script top
- [ ] Comprehensive comment-based help
- [ ] Transcript logging setup
- [ ] Proper error handling with try/catch
- [ ] Parameter validation
- [ ] Exit-Script function for clean shutdown

### **Prohibited Patterns**
- [ ] Direct `exit` calls (use `Exit-Script` instead)
- [ ] Hardcoded paths (use `$PSScriptRoot`)
- [ ] Magic numbers without explanation
- [ ] Inconsistent variable naming
- [ ] Missing error handling for external operations

## 📋 Naming Conventions

### **Script Files**
- Use PascalCase: `CreateDC.ps1`, `JoinDomain.ps1`
- Use descriptive names: `RDVH.ps1` (RDS Virtual Desktop Hyper-V)
- Use consistent prefixes: `setup.ps1`, `deploy.ps1`

### **Functions**
```powershell
# Verb-Noun pattern
Get-VmStatus
Start-VmDeployment
Test-NetworkConnectivity
Convert-ParameterArray
```

### **Constants**
```powershell
# Use ALL_CAPS with underscores
$DEFAULT_TIMEOUT = 300
$MAX_RETRY_COUNT = 3
$LOG_DATE_FORMAT = "yyyy-MM-dd_HH-mm-ss"
```

## 🧪 Testing Considerations

### **Manual Testing Checklist**
- [ ] Script runs without errors in clean environment
- [ ] All parameter combinations work
- [ ] Error conditions handled gracefully
- [ ] Cleanup works properly on failure
- [ ] Replay commands are generated correctly

### **Code Review Checklist**
- [ ] Follows established patterns
- [ ] Proper error handling
- [ ] Clear comments and documentation
- [ ] No hardcoded values
- [ ] Consistent formatting

## 🚀 Advanced Patterns

### **Retry Logic**
```powershell
$maxRetries = 3
$retryCount = 0

do {
    $retryCount++
    try {
        $result = Risky-Operation
        break
    } catch {
        Write-Warning "Attempt $retryCount/$maxRetries failed: $_"
        if ($retryCount -lt $maxRetries) {
            Start-Sleep -Seconds 5
        }
    }
} while ($retryCount -lt $maxRetries)
```

### **Progress Reporting**
```powershell
$activity = "Deploying VMs"
$totalItems = $vmList.Count
$currentItem = 0

foreach ($vm in $vmList) {
    $currentItem++
    $status = "Processing $vm ($currentItem/$totalItems)"
    Write-Progress -Activity $activity -Status $status -PercentComplete (($currentItem / $totalItems) * 100)

    # VM processing logic here
}

Write-Progress -Activity $activity -Completed
```

---

*Generated: March 27, 2026 | Hyper-V Lab Suite v3.0*</content>
<parameter name="filePath">C:\Users\ronald\Desktop\workplace\Rule\Code-style.md