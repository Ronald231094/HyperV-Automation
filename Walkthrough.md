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
