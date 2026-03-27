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
