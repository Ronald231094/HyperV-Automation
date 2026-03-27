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
