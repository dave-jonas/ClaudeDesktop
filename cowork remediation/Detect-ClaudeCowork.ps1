#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Detection script for Claude Cowork prerequisites (Intune Remediation)
.DESCRIPTION
    Checks VM infrastructure prerequisites for the Claude Desktop Cowork feature.
    Exits 0 (COMPLIANT) only when prereqs are truly READY (features enabled +
    vmcompute + HNS running, no blocking condition) and writes ClaudePrereqsReady.flag.
    Exits 1 (NON-COMPLIANT) otherwise, which triggers Remediate-ClaudeCowork.ps1.
    Runs as SYSTEM via Intune Remediations. Paired with Remediate-ClaudeCowork.ps1 (v2.1).

    v2.0 alignment with the state-machine remediation:
      - GATE 0 no longer false-fails "BIOS off" just because HypervisorPresent=False.
        It only reports firmware-disabled when VirtualizationFirmwareEnabled is
        explicitly False. A device that simply has not enabled Hyper-V yet is reported
        as an ordinary (remediable) non-compliance, not a dead-end BIOS gate.
      - REBOOT-PENDING AWARENESS: when features are enabled but services are not yet
        present and a servicing reboot is pending, the issue is phrased as the expected
        "awaiting reboot" stage (still non-compliant, so remediation completes it after
        the reboot) rather than a raw service failure.
      - BLOCKED PASSTHROUGH: if remediation latched a store-corruption block
        (ClaudeCowork-Blocked.flag), detection surfaces STATUS=BLOCKED and stays
        non-compliant so the device is visible for manual repair. Remediation itself
        stops re-running dism; detection does not clear the latch.

    Post-install checks (CoworkVMService, WinNAT, DNS, VHDX files) are intentionally
    excluded -- they cannot pass before Claude is installed and would permanently block
    the prereqs flag.

    Logging strategy (three layers):
      1. File log   -  C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\Claude\ClaudeCowork-Detection.log
      2. Event log  -  Windows Application log, Source "ClaudeCoworkMSIX"
                     EventID 1000 = compliant, 1001 = non-compliant, 1004 = blocked.
      3. stdout     -  Structured key=value captured by the Intune Remediations blade.
.NOTES
    Version:    2.1
    Date:       2026-07
    Author:     David Carroll - Jonas Software Australia (v2.0 alignment: Claude)
    Scope:      Windows 11 Pro/Enterprise, Claude Desktop, Intune-managed devices

    Changes v2.1:
      - When COMPLIANT, remove the stale ClaudeCowork-RebootPending.flag and unregister
        the user-context reboot-prompt task + script. Runs as SYSTEM, so it reliably
        cleans up devices that converged via detection alone (remediation never re-ran
        CASE A), preventing the reboot-prompt from force-restarting off a leftover flag.

    Changes v2.0:
      - GATE 0 corrected (see above): distinguishes firmware-off from not-yet-enabled.
      - Reboot-pending awareness for feature/service checks.
      - Blocked (store-corruption) passthrough, mirroring remediation v2.1.
      - Shared Test-PendingReboot helper so detection and remediation agree on state.
    (Earlier changelog v1.2-v1.7 retained in git history.)
#>

# ===========================================================================
# LOGGING SETUP
# ===========================================================================
$LogDir      = "$env:ProgramData\Microsoft\IntuneManagementExtension\Logs\Claude"
$LogFile     = "$LogDir\ClaudeCowork-Detection.log"
$EventSource = "ClaudeCoworkMSIX"
$EventLog    = "Application"
$FlagFile          = "$LogDir\ClaudePrereqsReady.flag"
$RebootPendingFlag = "$LogDir\ClaudeCowork-RebootPending.flag"
$BlockedFlag       = "$LogDir\ClaudeCowork-Blocked.flag"

if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }

if ((Test-Path $LogFile) -and (Get-Item $LogFile).Length -gt 5MB) {
    Rename-Item -Path $LogFile -NewName "$LogFile.bak" -Force -ErrorAction SilentlyContinue
}

if (-not [System.Diagnostics.EventLog]::SourceExists($EventSource)) {
    try { New-EventLog -LogName $EventLog -Source $EventSource -ErrorAction Stop } catch {}
}

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$ts [$Level] $Message" | Out-File -FilePath $LogFile -Append -Encoding UTF8
}

function Test-PendingReboot {
    # Same signals as the remediation, so both scripts agree on "reboot pending".
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { return $true }
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { return $true }
    if (Test-Path $RebootPendingFlag) { return $true }
    return $false
}

function Get-FeatureState {
    param([string]$Name)
    try { return (Get-WindowsOptionalFeature -Online -FeatureName $Name -ErrorAction Stop).State } catch { return 'Unknown' }
}

Write-Log "========================================="
Write-Log "Claude Cowork detection started (v2.1)"
Write-Log "Host: $env:COMPUTERNAME | OS: $([System.Environment]::OSVersion.VersionString)"
Write-Log "========================================="

# $issues = failures that trigger remediation ; $checks = key=value results for stdout
$issues = [System.Collections.Generic.List[string]]::new()
$checks = [System.Collections.Generic.List[string]]::new()

function Write-IntuneOutput {
    param([int]$IssueCount, [string[]]$CheckResults, [string[]]$IssueList, [string]$StatusOverride)
    $status = if ($StatusOverride) { $StatusOverride } elseif ($IssueCount -gt 0) { "NON-COMPLIANT" } else { "COMPLIANT" }
    Write-Host "STATUS=$status|ISSUE_COUNT=$IssueCount|$($CheckResults -join '|')"
    if ($IssueCount -gt 0) {
        Write-Host "ISSUES: $($IssueList -join ' || ')"
    }
}

$pendingReboot = Test-PendingReboot
Write-Log "pendingReboot = $pendingReboot"

# ===========================================================================
# CHECK -1: Windows 365 Cloud PC skip
#
# Cloud PC SKUs below 8vCPU/32GB cannot do nested virtualisation. Report
# COMPLIANT and write the flag so Claude installs (without Cowork).
# ===========================================================================
Write-Log "--- CHECK -1: Cloud PC detection"
try {
    $model = (Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop).Model
    if ($model -like "Cloud PC*") {
        Write-Log "Cloud PC detected (model: $model). Skipping Cowork prereqs. Writing flag so Claude installs without Cowork."
        $checks.Add("CHECK-1_CLOUDPC=SKIP:$model")
        if (-not (Test-Path $FlagFile)) {
            "Cloud PC ($model)  -  Cowork prereqs skipped on $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') by $env:COMPUTERNAME" |
                Out-File -FilePath $FlagFile -Encoding UTF8
            Write-Log "FLAG WRITTEN: $FlagFile"
        }
        try {
            Write-EventLog -LogName $EventLog -Source $EventSource -EventId 1000 -EntryType Information `
                -Message "Claude Cowork prereqs SKIPPED on Cloud PC $env:COMPUTERNAME (model: $model)." -ErrorAction SilentlyContinue
        } catch {}
        Write-IntuneOutput -IssueCount 0 -CheckResults $checks -IssueList $issues
        Exit 0
    }
    Write-Log "Not a Cloud PC (model: $model). Continuing checks."
} catch {
    Write-Log "WARN: Cloud PC model query failed  -  $_. Continuing." "WARN"
}

# ===========================================================================
# CHECK -0: BLOCKED latch (store corruption) passthrough
#
# Remediation writes ClaudeCowork-Blocked.flag when DISM reports the component
# store is corrupt. That is not fixable by feature enablement -- surface it and
# stay NON-COMPLIANT so the device is visible for manual repair. Detection does
# NOT clear the latch (only manual repair + remediation reaching READY does).
# ===========================================================================
Write-Log "--- CHECK -0: Blocked latch"
if (Test-Path $BlockedFlag) {
    $blockedSince = (Get-Content $BlockedFlag -ErrorAction SilentlyContinue | Select-Object -First 1)
    Write-Log "BLOCKED latch present ($blockedSince). Component store corruption reported by remediation." "ERROR"
    $checks.Add("CHECK-0_BLOCKED=StoreCorrupt")
    $issues.Add("BLOCKED: Component store corruption latched. Manual repair required (DISM /RestoreHealth, in-place upgrade, or Reset), then delete $BlockedFlag.")
    try {
        Write-EventLog -LogName $EventLog -Source $EventSource -EventId 1004 -EntryType Error `
            -Message "Claude Cowork BLOCKED on $env:COMPUTERNAME. Store corruption latched. Manual repair required." -ErrorAction SilentlyContinue
    } catch {}
    Write-IntuneOutput -IssueCount $issues.Count -CheckResults $checks -IssueList $issues -StatusOverride "BLOCKED"
    Exit 1
}

# ===========================================================================
# CHECK 0: Firmware virtualisation (VT-x/AMD-V)
#
# v2.0: only report firmware-disabled when it is CONFIRMED (HypervisorPresent
# False AND VirtualizationFirmwareEnabled explicitly False). "Hyper-V not enabled
# yet" (HypervisorPresent False but firmware virt available) is a normal remediable
# state and must NOT be reported as a BIOS dead-end.
# ===========================================================================
Write-Log "--- CHECK 0: Firmware virtualisation (VT-x/AMD-V)"
try {
    $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
    if ($cs.HypervisorPresent -eq $true) {
        Write-Log "PASS: HypervisorPresent = True"
        $checks.Add("CHECK0_HYPERVISOR=PASS")
    } else {
        $fw = (Get-CimInstance -ClassName Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1).VirtualizationFirmwareEnabled
        if ($fw -eq $false) {
            Write-Log "FAIL: Firmware virtualisation disabled (VirtualizationFirmwareEnabled=False, HypervisorPresent=False). BIOS/UEFI change required." "WARN"
            $checks.Add("CHECK0_HYPERVISOR=FAIL:FirmwareVirtDisabled")
            $checks.Add("REMAINING_CHECKS=SKIPPED:FirmwareVirtDisabled")
            $issues.Add("CHECK0: Firmware virtualisation (VT-x/AMD-V) disabled in BIOS/UEFI. Manual BIOS change required - script cannot fix this.")
            try {
                Write-EventLog -LogName $EventLog -Source $EventSource -EventId 1001 -EntryType Warning `
                    -Message "Claude Cowork NON-COMPLIANT on $env:COMPUTERNAME. Firmware virt disabled. BIOS intervention required." -ErrorAction SilentlyContinue
            } catch {}
            Write-IntuneOutput -IssueCount $issues.Count -CheckResults $checks -IssueList $issues
            Exit 1
        } else {
            Write-Log "INFO: HypervisorPresent=False but firmware virt not confirmed disabled (VirtualizationFirmwareEnabled=$fw). Hyper-V likely just not enabled yet. Continuing."
            $checks.Add("CHECK0_HYPERVISOR=INFO:NotEnabledYet")
        }
    }
} catch {
    Write-Log "WARN: Win32_ComputerSystem query failed  -  $_. Continuing." "WARN"
    $checks.Add("CHECK0_HYPERVISOR=UNKNOWN:QueryFailed")
}

# ===========================================================================
# CHECK 0b: Guest VM without nested virtualisation
# ===========================================================================
Write-Log "--- CHECK 0b: Guest VM / nested virtualisation"
$guestIntegrationSvcs = @("vmicheartbeat","vmicshutdown","vmickvpexchange","vmicvss","vmicguestinterface")
$isGuestVM        = $null -ne ($guestIntegrationSvcs | Where-Object { (Get-Service -Name $_ -ErrorAction SilentlyContinue).Status -eq "Running" })
$vmcomputePresent = $null -ne (Get-Service -Name "vmcompute" -ErrorAction SilentlyContinue)

if ($isGuestVM -and -not $vmcomputePresent) {
    $hvFeatureState = Get-FeatureState -Name "Microsoft-Hyper-V"
    if ($hvFeatureState -eq "Disabled") {
        Write-Log "INFO: Guest VM without vmcompute but Microsoft-Hyper-V is Disabled (not absent). Remediation can re-enable. Continuing."
        $checks.Add("CHECK0b_NESTEDVIRT=WARN:GuestVMHyperVDisabled:RemediationCanFix")
    } else {
        $msg = "Guest VM without nested virt. vmcompute absent, Hyper-V state '$hvFeatureState'. Parent host fix: Set-VMProcessor -ExposeVirtualizationExtensions `$true (Azure: Dv3/Ev3+)."
        Write-Log "FAIL: $msg" "WARN"
        $checks.Add("CHECK0b_NESTEDVIRT=FAIL:GuestVMNoNestedVirt")
        $checks.Add("REMAINING_CHECKS=SKIPPED:NestedVirtNotAvailable")
        $issues.Add("CHECK0b: Guest VM without nested virt. Parent host change required - script cannot fix.")
        try {
            Write-EventLog -LogName $EventLog -Source $EventSource -EventId 1001 -EntryType Warning `
                -Message "Claude Cowork NON-COMPLIANT on $env:COMPUTERNAME. Guest VM, nested virt not enabled." -ErrorAction SilentlyContinue
        } catch {}
        Write-IntuneOutput -IssueCount $issues.Count -CheckResults $checks -IssueList $issues
        Exit 1
    }
} elseif ($isGuestVM -and $vmcomputePresent) {
    Write-Log "INFO: Guest VM detected but vmcompute present - nested virt enabled. Continuing."
    $checks.Add("CHECK0b_NESTEDVIRT=PASS:GuestVMWithNestedVirt")
} else {
    Write-Log "PASS: Bare-metal host."
    $checks.Add("CHECK0b_NESTEDVIRT=PASS:BareMetal")
}

# ===========================================================================
# CHECK 1 + 1b: Required Windows features
# ===========================================================================
Write-Log "--- CHECK 1/1b: Required features"
$requiredFeatures = @("VirtualMachinePlatform","Microsoft-Hyper-V","Microsoft-Hyper-V-Services","Microsoft-Hyper-V-Hypervisor")
foreach ($feat in $requiredFeatures) {
    $state = Get-FeatureState -Name $feat
    if ($state -eq "Enabled") {
        Write-Log "PASS: $feat = Enabled"
        $checks.Add("FEATURE_${feat}=PASS")
    } elseif ($pendingReboot) {
        Write-Log "PENDING: $feat = $state (servicing reboot pending)" "WARN"
        $checks.Add("FEATURE_${feat}=PENDING:$state")
        $issues.Add("FEATURE: $feat not yet Enabled (state: $state). Servicing reboot pending - completes after restart.")
    } else {
        Write-Log "FAIL: $feat = $state" "WARN"
        $checks.Add("FEATURE_${feat}=FAIL:$state")
        $issues.Add("FEATURE: $feat not enabled (state: $state). Remediation will enable; reboot required.")
    }
}

# ===========================================================================
# CHECK 2 + 2b: Required services (vmcompute, HNS)
#
# Only vmcompute is required for Cowork; vmms is intentionally NOT checked.
# If a reboot is pending, absent services are the expected "awaiting reboot"
# stage rather than a hard failure.
# ===========================================================================
Write-Log "--- CHECK 2/2b: Services (vmcompute, HNS)"
foreach ($svcName in @("vmcompute","HNS")) {
    $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
    if ($null -eq $svc) {
        if ($pendingReboot) {
            Write-Log "PENDING: $svcName not present yet (servicing reboot pending)." "WARN"
            $checks.Add("SVC_${svcName}=PENDING:NotPresentAwaitingReboot")
            $issues.Add("SERVICE: $svcName not present yet. Servicing reboot pending - registers after restart.")
        } else {
            Write-Log "FAIL: $svcName not found." "WARN"
            $checks.Add("SVC_${svcName}=FAIL:NotFound")
            $issues.Add("SERVICE: $svcName not found. Hyper-V stack incomplete.")
        }
    } elseif ($svc.Status -ne "Running") {
        Write-Log "FAIL: $svcName status = $($svc.Status)" "WARN"
        $checks.Add("SVC_${svcName}=FAIL:$($svc.Status)")
        $issues.Add("SERVICE: $svcName not running (status: $($svc.Status)). Remediation will start it.")
    } else {
        Write-Log "PASS: $svcName = Running"
        $checks.Add("SVC_${svcName}=PASS")
    }
}

# ===========================================================================
# CHECK 8: 172.16.0.0/24 subnet conflict (flag only - cannot auto-remap)
# ===========================================================================
Write-Log "--- CHECK 8: 172.16.0.0/24 subnet conflict"
$conflictAdapters = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object {
        $_.InterfaceAlias -notlike "*cowork*" -and
        $_.InterfaceAlias -notlike "*Loopback*" -and
        $_.IPAddress      -like "172.16.0.*"
    }
if ($conflictAdapters) {
    $detail = ($conflictAdapters | ForEach-Object { "$($_.InterfaceAlias)=$($_.IPAddress)" }) -join ','
    Write-Log "WARN: Subnet conflict on 172.16.0.0/24  -  $detail" "WARN"
    $checks.Add("CHECK8_SUBNET=WARN:Conflict:$detail")
    $issues.Add("CHECK8: Subnet conflict on 172.16.0.0/24 ($detail). Cowork NAT will fail. Manual review - script cannot safely remap.")
} else {
    Write-Log "PASS: No 172.16.0.0/24 conflict"
    $checks.Add("CHECK8_SUBNET=PASS")
}

# ===========================================================================
# RESULT
# ===========================================================================
Write-Log "========================================="
Write-Log "Detection complete. Issues: $($issues.Count)"
foreach ($i in $issues) { Write-Log "  ISSUE: $i" "WARN" }
Write-Log "========================================="

$eventMsg  = "Claude Cowork detection on $env:COMPUTERNAME.`nIssues: $($issues.Count)`n"
$eventMsg += if ($issues.Count -gt 0) { $issues -join "`n" } else { "All checks passed." }
$eventMsg += "`n`nChecks:`n$($checks -join "`n")"
try {
    $evtId   = if ($issues.Count -gt 0) { 1001 } else { 1000 }
    $evtType = if ($issues.Count -gt 0) { "Warning" } else { "Information" }
    Write-EventLog -LogName $EventLog -Source $EventSource -EventId $evtId `
        -EntryType $evtType -Message $eventMsg -ErrorAction SilentlyContinue
} catch {
    Write-Log "WARN: Event log write failed  -  $_" "WARN"
}

Write-IntuneOutput -IssueCount $issues.Count -CheckResults $checks -IssueList $issues

# Write the prereqs-ready flag only when everything passed (truly READY).
if ($issues.Count -eq 0) {
    if (-not (Test-Path $FlagFile)) {
        "Prereqs confirmed ready on $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') by $env:COMPUTERNAME" | Out-File -FilePath $FlagFile -Encoding UTF8
        Write-Log "FLAG WRITTEN: $FlagFile"
    } else {
        Write-Log "FLAG EXISTS: $FlagFile (no action needed)"
    }

    # Prereqs are READY -> clean up any stale reboot-prompt artefacts so the user-context
    # prompt task cannot fire (and force restarts) off a leftover pending flag. Runs as
    # SYSTEM, so it reliably removes the flag and unregisters the task even when the
    # remediation itself never re-ran (device converged via detection alone).
    Remove-Item $RebootPendingFlag -Force -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName "ClaudeCoworkRebootPrompt" -Confirm:$false -ErrorAction SilentlyContinue
    Remove-Item "$env:ProgramData\AnthropicClaude\CoworkRebootPrompt.ps1" -Force -ErrorAction SilentlyContinue
}

if ($issues.Count -gt 0) { Exit 1 } else { Exit 0 }
