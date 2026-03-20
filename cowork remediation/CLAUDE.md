# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Two PowerShell scripts implementing a **Microsoft Intune Remediations** package that detects and remediates prerequisites for the Claude Desktop Cowork virtualization feature on Windows 11 Pro managed endpoints.

- `Detect-ClaudeCowork.ps1` — Detection script (v1.6); exits 0 (compliant) or 1 (non-compliant)
- `Remediate-ClaudeCowork.ps1` — Remediation script (v1.6); only runs when detection exits 1

Both scripts require `#Requires -RunAsAdministrator` and run as SYSTEM via Intune.

## Execution Model

Scripts are not built, compiled, or tested locally — they are deployed directly to Intune Remediations and execute on managed endpoints. The recommended schedule is **hourly** so devices get the flag written promptly after their first post-feature-enablement reboot.

To test manually on a local machine (requires elevation):
```powershell
# Run detection
powershell.exe -ExecutionPolicy Bypass -File .\Detect-ClaudeCowork.ps1

# Run remediation
powershell.exe -ExecutionPolicy Bypass -File .\Remediate-ClaudeCowork.ps1
```

## Log and Flag Paths

All scripts write logs and the prereqs flag to:

```
C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\Claude\
```

This directory is inside the IME Logs path, so Intune's **Collect diagnostics** action captures it automatically — no custom diagnostics profile configuration required.

| File | Written by |
|------|-----------|
| `ClaudeCowork-Detection.log` | Detect-ClaudeCowork.ps1 |
| `ClaudeCowork-Remediation.log` | Remediate-ClaudeCowork.ps1 |
| `ClaudePrereqsReady.flag` | Detection script on exit 0; also Remediate script on first clean run |

The flag signals to `install_claude.ps1` that VM infrastructure is healthy and Claude can be provisioned.

## Architecture

### Detection Flow

The detection script runs checks in sequence. **Gate checks** (CHECK 0 and CHECK 0b) cause immediate `Exit 1` when the issue cannot be remediated by script. All other checks accumulate issues and report at the end.

| Check | What | Gate? |
|-------|------|-------|
| 0 | Hypervisor present (VT-x/AMD-V in firmware) | Yes — script cannot fix BIOS |
| 0b | Guest VM without nested virtualization | Yes — script cannot fix parent host |
| 1 | VirtualMachinePlatform Windows feature | No |
| 1b | Full Hyper-V stack (Microsoft-Hyper-V, -Services, -Hypervisor) | No |
| 2 | vmcompute + vmms services running | No |
| 2b | HNS service running | No |
| 8 | 172.16.0.0/24 subnet conflict | No (flag only; cannot remediate) |

If all checks pass (exit 0), the detection script writes `ClaudePrereqsReady.flag`.

### Remediation Flow

Mirrors the detection checks. Gates (0, 0b) exit with an error message. Fixes:

- **FIX 1**: `Enable-WindowsOptionalFeature VirtualMachinePlatform` — sets `$rebootRequired = $true`
- **FIX 1b**: `Enable-WindowsOptionalFeature` for the three Hyper-V features — sets `$rebootRequired = $true`; service starts are skipped pending reboot
- **FIX 2**: Starts `vmms` and `vmcompute` if stopped (skipped if features were just enabled)
- **FIX 2b**: Starts `HNS` if stopped

After all fixes, if there are no failures and no reboot is required, the remediation script writes `ClaudePrereqsReady.flag`.

### Logging (Three Layers)

| Layer | Location | Purpose |
|-------|----------|---------|
| File | `C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\Claude\ClaudeCowork-*.log` | Full audit trail; rotates at 5 MB; auto-collected by Intune diagnostics |
| Event Log | Windows Application Log, Source `ClaudeCoworkMSIX` | EventID 1000/1002 = compliant/success, 1001/1003 = non-compliant/partial |
| Stdout | Key=value pairs (e.g. `STATUS=COMPLIANT\|ISSUE_COUNT=0\|...`) | Visible in Intune portal device status |

## Known Limitations

- **Feature enablement requires reboot**: Services (vmcompute, vmms) won't start until after the reboot that follows feature enablement; the script detects this state and skips service-start attempts.
- **Subnet conflicts**: If another adapter already uses 172.16.0.0/24, the issue is flagged but cannot be automatically resolved.
