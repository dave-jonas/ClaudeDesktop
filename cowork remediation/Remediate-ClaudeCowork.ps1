#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Remediation script for Claude Cowork prerequisites (Intune Remediation)
.DESCRIPTION
    Fixes VM infrastructure prerequisites required before Claude Desktop is installed.
    Designed to run as SYSTEM via Intune Remediations, paired with Detect-ClaudeCowork.ps1.

    Fixes applied:
      - Enables Virtual Machine Platform if missing (reports reboot required  -  does NOT force restart)
      - Enables full Hyper-V feature stack if missing (Microsoft-Hyper-V, -Services, -Hypervisor)
      - Starts Hyper-V services (vmcompute, vmms) if stopped
      - Starts HNS service if stopped
    Does NOT fix:
      - Firmware virtualisation disabled (BIOS/UEFI)  -  exits with clear message
      - Guest VM without nested virtualisation  -  exits with clear message
      - Subnet conflicts on 172.16.0.0/24  -  logged, flagged for manual review
      - Post-install issues (CoworkVMService, WinNAT, DNS, VHDX files)  -  not prereqs

    Logging strategy (three layers):
      1. File log   -  C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\Claude\ClaudeCowork-Remediation.log
                     Automatically collected by Intune > Collect diagnostics (lives inside IME Logs dir).
      2. Event log  -  Windows Application log, Source "ClaudeCoworkMSIX"
                     EventID 1002 = remediation applied, EventID 1003 = remediation failed/partial.
      3. stdout     -  Structured key=value summary captured by Intune Remediations portal.
.NOTES
    Version:    1.6
    Date:       2026-03
    Author:     David Carroll - Jonas Software Australia
    Scope:      Windows 11 Pro, Claude Desktop MSIX, Intune-managed devices
    Changes v1.6:
      - All logs and flag file moved to C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\Claude\
        so they are automatically collected by Intune > Collect diagnostics without any custom path setup.
      - Writes ClaudePrereqsReady.flag on first successful run (no reboot required, no failures).
    Changes v1.5:
      - CHECK 0b: Guest VM detection now requires integration services to be RUNNING, not just exist.
        After enabling Hyper-V on a bare-metal host, vmicXXX services are created but stopped —
        previously this caused the host to be misidentified as a guest VM on the post-reboot cycle.
    Changes v1.4:
      - Removed FIX 3 (CoworkVMService), FIX 4 (WinNAT), FIX 5 (DNS)
        These are post-install/post-first-run concerns, not VM infrastructure prereqs.
        Keeping them caused spurious failures before Claude was installed.
    Changes v1.3:
      - Removed FIX 6 (VHDX renaming)  -  renaming files is destructive
    Changes v1.2:
      - GATE CHECK 0b: Exit early if guest VM without nested virt
      - FIX 1b: Enable full Hyper-V feature stack, not just VirtualMachinePlatform
      - FIX 2b: Start HNS service if stopped
#>

# ===========================================================================
# LOGGING SETUP
# ===========================================================================
$LogDir      = "$env:ProgramData\Microsoft\IntuneManagementExtension\Logs\Claude"
$LogFile     = "$LogDir\ClaudeCowork-Remediation.log"
$EventSource = "ClaudeCoworkMSIX"
$EventLog    = "Application"

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

Write-Log "========================================="
Write-Log "Claude Cowork remediation started (v1.6)"
Write-Log "Host: $env:COMPUTERNAME | OS: $([System.Environment]::OSVersion.VersionString)"
Write-Log "========================================="

$rebootRequired  = $false
$applied  = [System.Collections.Generic.List[string]]::new()
$skipped  = [System.Collections.Generic.List[string]]::new()
$failures = [System.Collections.Generic.List[string]]::new()
$FlagFile = "$LogDir\ClaudePrereqsReady.flag"

# ===========================================================================
# GATE CHECK 0: Hypervisor present (firmware VT-x/AMD-V)
# ===========================================================================
Write-Log "--- GATE 0: Hypervisor present"
try {
    $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
    if ($cs.HypervisorPresent -ne $true) {
        $msg = "GATE FAIL: HypervisorPresent=False on $env:COMPUTERNAME. Firmware virtualisation (VT-x/AMD-V) is disabled in BIOS/UEFI. No script remediation is possible. Manual intervention required: enter BIOS/UEFI and enable Intel VT-x or AMD-V."
        Write-Log $msg "WARN"
        try {
            Write-EventLog -LogName $EventLog -Source $EventSource -EventId 1003 -EntryType Warning `
                -Message $msg -ErrorAction SilentlyContinue
        } catch {}
        Write-Host "STATUS=FAILED|GATE=HypervisorNotPresent|ACTION_REQUIRED=EnableVirtualisationInBIOS"
        Write-Host "DETAIL: $msg"
        Exit 1
    }
    Write-Log "PASS: HypervisorPresent = True"
} catch {
    Write-Log "WARN: Win32_ComputerSystem query failed  -  $_. Continuing." "WARN"
}

# ===========================================================================
# GATE CHECK 0b: Guest VM without nested virtualisation
#
# If this machine is a Hyper-V guest and vmms is absent, we first check whether
# the Hyper-V features are merely Disabled (fixable by this script) vs truly
# absent (parent host nested virt not exposed  -  unfixable by script).
# ===========================================================================
Write-Log "--- GATE 0b: Guest VM / nested virtualisation"
$guestIntegrationSvcs = @("vmicheartbeat","vmicshutdown","vmickvpexchange","vmicvss","vmicguestinterface")
$isGuestVM   = $null -ne ($guestIntegrationSvcs | Where-Object { (Get-Service -Name $_ -ErrorAction SilentlyContinue).Status -eq "Running" })
$vmmsPresent = $null -ne (Get-Service -Name "vmms" -ErrorAction SilentlyContinue)

if ($isGuestVM -and -not $vmmsPresent) {
    $hvFeatureState = (Get-WindowsOptionalFeature -Online -FeatureName "Microsoft-Hyper-V" -ErrorAction SilentlyContinue).State
    if ($hvFeatureState -eq "Disabled") {
        Write-Log "INFO: Guest VM without vmms but Microsoft-Hyper-V is Disabled (not absent). Will attempt to re-enable features."
    } else {
        $msg = "GATE FAIL: Guest VM without nested virtualisation on $env:COMPUTERNAME. vmms absent and Hyper-V feature state is '$hvFeatureState'. Infrastructure fix required on parent host: Set-VMProcessor -VMName <VMName> -ExposeVirtualizationExtensions `$true. On Azure: resize to Dv3/Ev3 or higher SKU."
        Write-Log $msg "WARN"
        try {
            Write-EventLog -LogName $EventLog -Source $EventSource -EventId 1003 -EntryType Warning `
                -Message $msg -ErrorAction SilentlyContinue
        } catch {}
        Write-Host "STATUS=FAILED|GATE=GuestVMNoNestedVirt|ACTION_REQUIRED=EnableNestedVirtOnParentHost"
        Write-Host "DETAIL: $msg"
        Exit 1
    }
} elseif ($isGuestVM) {
    Write-Log "INFO: Guest VM detected, vmms present  -  nested virt enabled. Continuing."
} else {
    Write-Log "PASS: Bare-metal host."
}

# ===========================================================================
# FIX 1: Virtual Machine Platform
# ===========================================================================
Write-Log "--- FIX 1: Virtual Machine Platform"
try {
    $vmp = Get-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -ErrorAction Stop
    if ($vmp.State -ne "Enabled") {
        Write-Log "Enabling VirtualMachinePlatform..."
        Enable-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -All -NoRestart -ErrorAction Stop | Out-Null
        $applied.Add("FIX1_VMP=Enabled:RebootRequired")
        $rebootRequired = $true
        Write-Log "VirtualMachinePlatform enabled. Reboot required before services will start."
    } else {
        Write-Log "VirtualMachinePlatform already enabled  -  skipped"
        $skipped.Add("FIX1_VMP=AlreadyEnabled")
    }
} catch {
    Write-Log "ERROR: VirtualMachinePlatform enable failed  -  $_" "ERROR"
    $failures.Add("FIX1_VMP=Error:$_")
}

# ===========================================================================
# FIX 1b: Full Hyper-V feature stack
#
# VirtualMachinePlatform alone is not sufficient. The working reference machine
# has Microsoft-Hyper-V, -Services, and -Hypervisor all enabled. Without these,
# vmms and vmcompute do not exist as services. Enabling Microsoft-Hyper-V-All
# installs all sub-features in one pass. Reboot required.
# ===========================================================================
Write-Log "--- FIX 1b: Hyper-V feature stack"
$requiredHVFeatures = @(
    "Microsoft-Hyper-V",
    "Microsoft-Hyper-V-Services",
    "Microsoft-Hyper-V-Hypervisor"
)
$hvFeaturesEnabled = $false
foreach ($feat in $requiredHVFeatures) {
    try {
        $f = Get-WindowsOptionalFeature -Online -FeatureName $feat -ErrorAction Stop
        if ($f.State -ne "Enabled") {
            Write-Log "Enabling $feat..."
            Enable-WindowsOptionalFeature -Online -FeatureName $feat -All -NoRestart -ErrorAction Stop | Out-Null
            $applied.Add("FIX1b_${feat}=Enabled:RebootRequired")
            $rebootRequired = $true
            $hvFeaturesEnabled = $true
            Write-Log "$feat enabled. Reboot required before services will start."
        } else {
            Write-Log "$feat already enabled  -  skipped"
            $skipped.Add("FIX1b_${feat}=AlreadyEnabled")
        }
    } catch {
        Write-Log "ERROR: $feat enable failed  -  $_" "ERROR"
        $failures.Add("FIX1b_${feat}=Error:$_")
    }
}

# ===========================================================================
# FIX 2: Hyper-V services (vmcompute, vmms)
# Skip if features were just enabled above  -  services won't exist until reboot.
# ===========================================================================
Write-Log "--- FIX 2: Hyper-V services (vmcompute, vmms)"
foreach ($svcName in @("vmcompute", "vmms")) {
    try {
        $svc = Get-Service -Name $svcName -ErrorAction Stop
        if ($svc.Status -ne "Running") {
            if ($hvFeaturesEnabled) {
                Write-Log "INFO: $svcName not running but Hyper-V features were just enabled  -  will start after reboot."
                $skipped.Add("FIX2_${svcName}=SkippedPendingReboot")
            } else {
                Write-Log "Starting $svcName..."
                Start-Service -Name $svcName -ErrorAction Stop
                $applied.Add("FIX2_${svcName}=Started")
                Write-Log "$svcName started"
            }
        } else {
            Write-Log "$svcName already running  -  skipped"
            $skipped.Add("FIX2_${svcName}=AlreadyRunning")
        }
    } catch {
        if ($hvFeaturesEnabled) {
            Write-Log "INFO: $svcName not found  -  expected before reboot after feature enablement."
            $skipped.Add("FIX2_${svcName}=NotFoundPendingReboot")
        } else {
            Write-Log "ERROR: Could not start $svcName  -  $_" "ERROR"
            $failures.Add("FIX2_${svcName}=Error:$_")
        }
    }
}

# ===========================================================================
# FIX 2b: HNS service
#
# The Host Network Service must be running for cowork-vm-nat to be created.
# Reference machine: HNS = Running | StartType=Manual.
# ===========================================================================
Write-Log "--- FIX 2b: HNS service"
try {
    $hns = Get-Service -Name "HNS" -ErrorAction Stop
    if ($hns.Status -ne "Running") {
        Write-Log "Starting HNS..."
        Start-Service -Name "HNS" -ErrorAction Stop
        $applied.Add("FIX2b_HNS=Started")
        Write-Log "HNS started"
    } else {
        Write-Log "HNS already running  -  skipped"
        $skipped.Add("FIX2b_HNS=AlreadyRunning")
    }
} catch {
    Write-Log "ERROR: Could not start HNS  -  $_" "ERROR"
    $failures.Add("FIX2b_HNS=Error:$_")
}

# ===========================================================================
# RESULT SUMMARY
# ===========================================================================
Write-Log "========================================="
Write-Log "Remediation complete."
Write-Log "Applied  : $($applied.Count)   -  $($applied -join ' | ')"
Write-Log "Skipped  : $($skipped.Count)   -  $($skipped -join ' | ')"
Write-Log "Failures : $($failures.Count)  -  $($failures -join ' | ')"
Write-Log "Reboot   : $rebootRequired"
Write-Log "========================================="

# Windows Event Log
$evtId   = if ($failures.Count -gt 0) { 1003 } else { 1002 }
$evtType = if ($failures.Count -gt 0) { "Warning" } else { "Information" }
$evtMsg  = "Claude Cowork remediation on $env:COMPUTERNAME.`n"
$evtMsg += "Applied: $($applied.Count) | Skipped: $($skipped.Count) | Failures: $($failures.Count)`n"
$evtMsg += "Applied:`n$($applied -join "`n")`n"
$evtMsg += "Failures:`n$($failures -join "`n")`n"
$evtMsg += "Reboot required: $rebootRequired"
try {
    Write-EventLog -LogName $EventLog -Source $EventSource -EventId $evtId `
        -EntryType $evtType -Message $evtMsg -ErrorAction SilentlyContinue
} catch {
    Write-Log "WARN: Event log write failed  -  $_" "WARN"
}

# Intune stdout
$status = if ($failures.Count -gt 0) { "PARTIAL" } else { "SUCCESS" }
Write-Host "STATUS=$status|APPLIED=$($applied.Count)|SKIPPED=$($skipped.Count)|FAILURES=$($failures.Count)|REBOOT=$rebootRequired"
Write-Host "APPLIED: $($applied -join ' | ')"
if ($failures.Count -gt 0) {
    Write-Host "FAILURES: $($failures -join ' | ')"
}

if ($rebootRequired) {
    Write-Log "REBOOT REQUIRED: Hyper-V features were enabled. A restart is needed before services will start. Schedule a restart via Intune or allow the next maintenance window." "WARN"
    Write-Host "REBOOT=REQUIRED:HyperVFeaturesEnabled:RestartNotForced"
}

# ===========================================================================
# FLAG FILE: Write when all prereqs are confirmed ready this run
# ===========================================================================
if ($failures.Count -eq 0 -and -not $rebootRequired) {
    if (-not (Test-Path $FlagFile)) {
        "PrereqsReady=$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')|Host=$env:COMPUTERNAME" |
            Out-File -FilePath $FlagFile -Encoding UTF8 -Force
        Write-Log "Prereqs flag written: $FlagFile"
    } else {
        Write-Log "Prereqs flag already exists — not overwritten."
    }
}

if ($failures.Count -gt 0) { Exit 1 } else { Exit 0 }
