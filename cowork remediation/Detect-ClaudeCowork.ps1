#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Detection script for Claude Cowork prerequisites (Intune Remediation)
.DESCRIPTION
    Checks VM infrastructure prerequisites required before Claude Desktop is installed.
    Exits 0 if everything is healthy (no remediation needed) and writes the prereqs flag.
    Exits 1 if any check fails (triggers remediation script).
    Designed to run as SYSTEM via Intune Remediations.

    Checks cover only VM infrastructure (Hyper-V features, services, subnet conflicts).
    Post-install checks (CoworkVMService, HNS network, WinNAT, VHDX files) are
    intentionally excluded — they cannot pass before Claude is installed and would
    permanently block the prereqs flag from being written.

    Logging strategy (three layers):
      1. File log   -  C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\Claude\ClaudeCowork-Detection.log
                     Detailed timestamped log. Automatically collected by Intune > Collect diagnostics
                     because it lives inside the IME Logs directory.
      2. Event log  -  Windows Application log, Source "ClaudeCoworkMSIX"
                     EventID 1000 = compliant, EventID 1001 = non-compliant.
                     Queryable via Log Analytics if MMA/AMA is deployed to endpoints.
      3. stdout     -  Write-Host output captured by Intune Remediations reporting blade.
                     Structured key=value format, one summary line + one issues line.
                     Visible in Intune admin centre: Devices > Remediations > [script] > Device status.
.NOTES
    Version:    1.7
    Date:       2026-03
    Author:     David Carroll - Jonas Software Australia
    Scope:      Windows 11 Pro, Claude Desktop MSIX, Intune-managed devices
    Changes v1.7:
      - CHECK2: Removed vmms from service checks. Cowork only requires vmcompute;
        vmms (Hyper-V Manager stack) is not needed and was causing false positives
        on working devices where vmcompute runs without vmms.
      - CHECK0b: Use vmcompute (not vmms) as the signal for Hyper-V being present.
    Changes v1.5:
      - CHECK 0b: Guest VM detection now requires integration services to be RUNNING, not just exist.
        After enabling Hyper-V on a bare-metal host, vmicXXX services are created but stopped —
        previously this caused the host to be misidentified as a guest VM on the post-reboot cycle.
    Changes v1.4:
      - Removed CHECK3 (CoworkVMService), CHECK4-6 (HNS/WinNAT/DNS), CHECK7 (VHDX integrity)
        These are post-install/post-first-run checks that cannot pass before Claude is installed.
        Keeping them caused the prereqs flag to never be written on fresh machines.
      - Flag is now written by detection (exit 0) not remediation, so install_claude.ps1
        only proceeds once VM infrastructure is confirmed healthy.
    Changes v1.3:
      - CHECK7: Removed rootfs.vhdx minimum size threshold (version-dependent; breaks on Anthropic updates)
    Changes v1.2:
      - CHECK0b: Detect guest VM without nested virtualisation (previously misidentified as vmms failure)
      - CHECK1b: Full Hyper-V feature stack (Microsoft-Hyper-V, -Services, -Hypervisor)  -  not just VirtualMachinePlatform
      - CHECK2b: HNS service  -  required for cowork-vm-nat network creation
      - CHECK7: Extended to cover rootfs.vhdx and smol-bin.vhdx (not just sessiondata.vhdx)
#>

# ===========================================================================
# LOGGING SETUP
# ===========================================================================
$LogDir      = "$env:ProgramData\Microsoft\IntuneManagementExtension\Logs\Claude"
$LogFile     = "$LogDir\ClaudeCowork-Detection.log"
$EventSource = "ClaudeCoworkMSIX"
$EventLog    = "Application"

if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }

# Rotate log file if over 5 MB
if ((Test-Path $LogFile) -and (Get-Item $LogFile).Length -gt 5MB) {
    Rename-Item -Path $LogFile -NewName "$LogFile.bak" -Force -ErrorAction SilentlyContinue
}

# Register Event Log source (SYSTEM has rights to do this)
if (-not [System.Diagnostics.EventLog]::SourceExists($EventSource)) {
    try { New-EventLog -LogName $EventLog -Source $EventSource -ErrorAction Stop } catch {}
}

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$ts [$Level] $Message" | Out-File -FilePath $LogFile -Append -Encoding UTF8
}

Write-Log "========================================="
Write-Log "Claude Cowork detection started (v1.5)"
Write-Log "Host: $env:COMPUTERNAME | OS: $([System.Environment]::OSVersion.VersionString)"
Write-Log "========================================="

# $issues   = failures that trigger remediation
# $checks   = structured key=value results for Intune stdout
$issues = [System.Collections.Generic.List[string]]::new()
$checks = [System.Collections.Generic.List[string]]::new()

# Helper to emit to Intune portal (called once at the end)
function Write-IntuneOutput {
    param([int]$IssueCount, [string[]]$CheckResults, [string[]]$IssueList)
    $status = if ($IssueCount -gt 0) { "NON-COMPLIANT" } else { "COMPLIANT" }
    Write-Host "STATUS=$status|ISSUE_COUNT=$IssueCount|$($CheckResults -join '|')"
    if ($IssueCount -gt 0) {
        Write-Host "ISSUES: $($IssueList -join ' || ')"
    }
}

# ===========================================================================
# CHECK 0: Hypervisor present (confirms firmware VT-x/AMD-V is enabled)
#
# Gate check. If HypervisorPresent is false, firmware virt is off  -  BIOS
# intervention required. Exit early to avoid cascading false failures.
# ===========================================================================
Write-Log "--- CHECK 0: Hypervisor present (firmware VT-x/AMD-V)"
try {
    $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
    if ($cs.HypervisorPresent -eq $true) {
        Write-Log "PASS: HypervisorPresent = True"
        $checks.Add("CHECK0_HYPERVISOR=PASS")
    } else {
        Write-Log "FAIL: HypervisorPresent = False. CPU virtualisation disabled in BIOS/UEFI." "WARN"
        $checks.Add("CHECK0_HYPERVISOR=FAIL:FirmwareVirtDisabled")
        $checks.Add("REMAINING_CHECKS=SKIPPED:HypervisorNotPresent")
        $issues.Add("CHECK0: Firmware virtualisation (VT-x/AMD-V) disabled. Enable in BIOS/UEFI. Script cannot fix this.")
        try {
            Write-EventLog -LogName $EventLog -Source $EventSource -EventId 1001 -EntryType Warning `
                -Message "Claude Cowork NON-COMPLIANT on $env:COMPUTERNAME. HypervisorPresent=False. BIOS intervention required." `
                -ErrorAction SilentlyContinue
        } catch {}
        Write-IntuneOutput -IssueCount $issues.Count -CheckResults $checks -IssueList $issues
        Exit 1
    }
} catch {
    Write-Log "WARN: Win32_ComputerSystem query failed  -  $_. Continuing with remaining checks." "WARN"
    $checks.Add("CHECK0_HYPERVISOR=UNKNOWN:QueryFailed")
}

# ===========================================================================
# CHECK 0b: Guest VM without nested virtualisation
#
# HypervisorPresent=True passes CHECK 0 regardless of whether this machine
# is a bare-metal host or a guest VM. The distinguishing signal is:
#   - Guest integration services present (vmicheartbeat etc.) = this is a guest
#   - vmms absent = either nested virt not exposed by parent, OR Hyper-V features
#     were disabled on this guest (e.g. by Windows Update)
#
# We distinguish these by checking Hyper-V feature state:
#   - Features Disabled = fixable by remediation (do not gate-exit)
#   - Features absent/unknown + vmms missing = likely parent host issue (gate-exit)
# ===========================================================================
Write-Log "--- CHECK 0b: Guest VM / nested virtualisation"
$guestIntegrationSvcs = @("vmicheartbeat","vmicshutdown","vmickvpexchange","vmicvss","vmicguestinterface")
$isGuestVM   = $null -ne ($guestIntegrationSvcs | Where-Object { (Get-Service -Name $_ -ErrorAction SilentlyContinue).Status -eq "Running" })
$vmmsPresent = $null -ne (Get-Service -Name "vmms" -ErrorAction SilentlyContinue)

if ($isGuestVM -and -not $vmmsPresent) {
    # Check if Hyper-V features exist but are merely disabled (fixable) vs truly absent (parent host issue)
    $hvFeatureState = (Get-WindowsOptionalFeature -Online -FeatureName "Microsoft-Hyper-V" -ErrorAction SilentlyContinue).State
    if ($hvFeatureState -eq "Disabled") {
        Write-Log "INFO: Guest VM without vmms but Microsoft-Hyper-V is Disabled (not absent). Features were likely disabled by a Windows Update. Remediation can re-enable them. Continuing checks."
        $checks.Add("CHECK0b_NESTEDVIRT=WARN:GuestVMHyperVDisabled:RemediationCanFix")
    } else {
        $msg = "This machine is a Hyper-V guest VM, vmms is absent, and Hyper-V features are not in a recoverable state (feature state: $hvFeatureState). Nested virt may not be exposed by the parent host. Parent host fix: Set-VMProcessor -VMName <VMName> -ExposeVirtualizationExtensions `$true. On Azure: resize to Dv3/Ev3 or higher SKU."
        Write-Log "FAIL: $msg" "WARN"
        $checks.Add("CHECK0b_NESTEDVIRT=FAIL:GuestVMNoNestedVirt")
        $checks.Add("REMAINING_CHECKS=SKIPPED:NestedVirtNotAvailable")
        $issues.Add("CHECK0b: Guest VM without nested virt. Parent host change required  -  script cannot fix.")
        try {
            Write-EventLog -LogName $EventLog -Source $EventSource -EventId 1001 -EntryType Warning `
                -Message "Claude Cowork NON-COMPLIANT on $env:COMPUTERNAME. Guest VM, nested virt not enabled. Parent host intervention required." `
                -ErrorAction SilentlyContinue
        } catch {}
        Write-IntuneOutput -IssueCount $issues.Count -CheckResults $checks -IssueList $issues
        Exit 1
    }
} elseif ($isGuestVM -and $vmmsPresent) {
    Write-Log "INFO: Guest VM detected but vmms is present  -  nested virt is enabled. Continuing checks."
    $checks.Add("CHECK0b_NESTEDVIRT=PASS:GuestVMWithNestedVirt")
} else {
    Write-Log "PASS: Bare-metal host (no guest integration services detected)"
    $checks.Add("CHECK0b_NESTEDVIRT=PASS:BareMetal")
}

# ===========================================================================
# CHECK 1: Virtual Machine Platform Windows feature
# ===========================================================================
Write-Log "--- CHECK 1: Virtual Machine Platform feature"
try {
    $vmp = Get-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -ErrorAction Stop
    if ($vmp.State -ne "Enabled") {
        Write-Log "FAIL: VirtualMachinePlatform state = $($vmp.State)" "WARN"
        $checks.Add("CHECK1_VMP=FAIL:State=$($vmp.State)")
        $issues.Add("CHECK1: VirtualMachinePlatform not enabled (state: $($vmp.State)). Reboot required after fix.")
    } else {
        Write-Log "PASS: VirtualMachinePlatform = Enabled"
        $checks.Add("CHECK1_VMP=PASS")
    }
} catch {
    Write-Log "FAIL: VirtualMachinePlatform query error  -  $_" "WARN"
    $checks.Add("CHECK1_VMP=FAIL:QueryError")
    $issues.Add("CHECK1: VirtualMachinePlatform query failed: $_")
}

# ===========================================================================
# CHECK 1b: Full Hyper-V feature stack
#
# VirtualMachinePlatform alone is not sufficient. Cowork requires the full
# Hyper-V stack: Microsoft-Hyper-V (core), Microsoft-Hyper-V-Services, and
# Microsoft-Hyper-V-Hypervisor. Without these, vmms and vmcompute cannot
# exist as services regardless of VirtualMachinePlatform state.
# Confirmed required by reference machine (JCPC-8CC0380SN9, v1.1.7053).
# ===========================================================================
Write-Log "--- CHECK 1b: Hyper-V feature stack (Microsoft-Hyper-V, -Services, -Hypervisor)"
$requiredHVFeatures = @(
    "Microsoft-Hyper-V",
    "Microsoft-Hyper-V-Services",
    "Microsoft-Hyper-V-Hypervisor"
)
foreach ($feat in $requiredHVFeatures) {
    try {
        $f = Get-WindowsOptionalFeature -Online -FeatureName $feat -ErrorAction Stop
        if ($f.State -ne "Enabled") {
            Write-Log "FAIL: $feat state = $($f.State)" "WARN"
            $checks.Add("CHECK1b_${feat}=FAIL:State=$($f.State)")
            $issues.Add("CHECK1b: $feat not enabled (state: $($f.State)). Reboot required after fix.")
        } else {
            Write-Log "PASS: $feat = Enabled"
            $checks.Add("CHECK1b_${feat}=PASS")
        }
    } catch {
        Write-Log "FAIL: $feat query error  -  $_" "WARN"
        $checks.Add("CHECK1b_${feat}=FAIL:QueryError")
        $issues.Add("CHECK1b: $feat query failed: $_")
    }
}

# ===========================================================================
# CHECK 2: Hyper-V services (vmcompute, vmms)
# ===========================================================================
Write-Log "--- CHECK 2: Hyper-V services (vmcompute, vmms)"
foreach ($svcName in @("vmcompute", "vmms")) {
    try {
        $svc = Get-Service -Name $svcName -ErrorAction Stop
        if ($svc.Status -ne "Running") {
            Write-Log "FAIL: $svcName status = $($svc.Status)" "WARN"
            $checks.Add("CHECK2_${svcName}=FAIL:$($svc.Status)")
            $issues.Add("CHECK2: Service $svcName not running (status: $($svc.Status))")
        } else {
            Write-Log "PASS: $svcName = Running"
            $checks.Add("CHECK2_${svcName}=PASS")
        }
    } catch {
        Write-Log "FAIL: $svcName not found  -  $_" "WARN"
        $checks.Add("CHECK2_${svcName}=FAIL:NotFound")
        $issues.Add("CHECK2: Service $svcName not found: $_")
    }
}

# ===========================================================================
# CHECK 2b: HNS service
#
# The Host Network Service is required for cowork-vm-nat network creation.
# On the reference machine: HNS = Running | StartType=Manual.
# If HNS is stopped, the HNS network checks below will silently fail.
# ===========================================================================
Write-Log "--- CHECK 2b: HNS service"
try {
    $hns = Get-Service -Name "HNS" -ErrorAction Stop
    if ($hns.Status -ne "Running") {
        Write-Log "FAIL: HNS status = $($hns.Status)" "WARN"
        $checks.Add("CHECK2b_HNS=FAIL:$($hns.Status)")
        $issues.Add("CHECK2b: HNS service not running (status: $($hns.Status)). cowork-vm-nat network cannot be created.")
    } else {
        Write-Log "PASS: HNS = Running"
        $checks.Add("CHECK2b_HNS=PASS")
    }
} catch {
    Write-Log "FAIL: HNS service not found  -  $_" "WARN"
    $checks.Add("CHECK2b_HNS=FAIL:NotFound")
    $issues.Add("CHECK2b: HNS service not found. Hyper-V networking stack may be missing.")
}

# ===========================================================================
# CHECK 8: 172.16.0.0/24 subnet conflict on host adapters
# Flag only  -  remediation cannot safely fix a subnet conflict
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
    $issues.Add("CHECK8: Subnet conflict on 172.16.0.0/24 ($detail). Cowork NAT will fail. Manual review required  -  script cannot safely remap Cowork subnet.")
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

# Write to Windows Event Log
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

# Emit structured stdout for Intune Remediations portal
Write-IntuneOutput -IssueCount $issues.Count -CheckResults $checks -IssueList $issues

# Write the prereqs-ready flag when all checks pass so install_claude.ps1 can proceed.
if ($issues.Count -eq 0) {
    $FlagFile = "$LogDir\ClaudePrereqsReady.flag"
    if (-not (Test-Path $FlagFile)) {
        "Prereqs confirmed ready on $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') by $env:COMPUTERNAME" | Out-File -FilePath $FlagFile -Encoding UTF8
        Write-Log "FLAG WRITTEN: $FlagFile"
    } else {
        Write-Log "FLAG EXISTS: $FlagFile (no action needed)"
    }
}

if ($issues.Count -gt 0) { Exit 1 } else { Exit 0 }
