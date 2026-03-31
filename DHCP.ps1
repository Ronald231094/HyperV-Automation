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
