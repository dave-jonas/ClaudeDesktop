#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Remediation script for Claude Cowork prerequisites (Intune Remediation)
.DESCRIPTION
    Fixes VM infrastructure prerequisites required for the Claude Desktop Cowork
    virtualisation feature. Designed to run as SYSTEM via Intune Remediations,
    paired with Detect-ClaudeCowork.ps1.

    State-machine driven (v2.0). Each run figures out where the device is and does the
    ONE correct next step, instead of blindly re-running Enable every cycle:

        not enabled  --(enable, no reboot pending)-->  enabled+reboot-pending
        enabled+reboot-pending  --(reboot happens externally)-->  services present
        services present  --(start + set Automatic)-->  READY (flag written)

    Fixes applied:
      - Enables VirtualMachinePlatform + full Hyper-V stack (Microsoft-Hyper-V,
        -Services, -Hypervisor) via DISM.exe (language-independent exit codes).
      - Starts vmcompute (StartupType Automatic) + HNS once they exist post-reboot.
    Does NOT fix (reports and exits cleanly):
      - Firmware virtualisation disabled in BIOS/UEFI.
      - Guest VM without nested virtualisation (parent-host change required).
      - Component store corruption (DISM 14098 / 0x800f0831 / 0x80073712) -- escalated
        for manual repair (in-place upgrade / Reset), NOT retried forever.
      - Subnet conflict on 172.16.0.0/24 (post-install concern).

.NOTES
    Version:    2.3
    Date:       2026-07
    Author:     David Carroll - Jonas Software Australia (v2.0+ hardening: Claude)
    Scope:      Windows 11 Pro/Enterprise, Claude Desktop, Intune-managed devices

    Changes v2.3 (reboot-prompt safety -- stop stale/endless restarts):
      - SELF-VERIFY before prompting: if vmcompute is already running (or the
        prereqs-ready flag exists), the pending flag is stale -> clean up and NEVER
        reboot a device whose prereqs are already met. Fixes devices that converged
        via detection-only (remediation never re-ran CASE A to clear the pending flag).
      - REBOOT CAP: trigger at most 3 restarts (RebootCount in HKCU). After that, stop
        rebooting, write CoworkReboot-Capped.flag, leave the device for manual attention.
      - Paired Detect-ClaudeCowork.ps1 raised to v2.1: when COMPLIANT it removes the
        stale RebootPending flag and unregisters the reboot-prompt task (SYSTEM cleanup).

    Changes v2.2:
      - REBOOT PROMPT FOLDED IN (single Intune package): instead of a second
        user-context remediation, this SYSTEM script drops a user-context prompt
        script (CoworkRebootPrompt.ps1) and registers a scheduled task that runs it
        in the logged-on user's session (at logon + every 4h) whenever a servicing
        reboot is pending; the task + script are removed once prereqs reach READY.
        Supersedes the separate reboot-orchestration/ pair.

    Changes v2.1:
      - STORE-CORRUPTION LATCH: on DISM 14098 the script now writes a persistent
        ClaudeCowork-Blocked.flag and short-circuits on subsequent runs, so it stops
        re-hammering "dism /enable" against a corrupt component store every cycle.
        Manual repair path: fix the store (DISM /RestoreHealth, in-place upgrade, or
        Reset This PC) THEN delete ClaudeCowork-Blocked.flag to re-arm remediation.
        The flag is also cleared automatically once prereqs reach READY.
      - Detect-ClaudeCowork.ps1 raised to v2.0 to mirror this state model.

    Changes v2.0 (fleet hardening -- prevents the failure mode that corrupted a device):
      - REBOOT-PENDING GUARD: if a servicing reboot is already pending (CBS RebootPending
        key, WU RebootRequired key, or our own marker), the script does NOT attempt to
        enable features again. Stacking Enable operations on an un-committed pending
        servicing state is what corrupted the component store previously.
      - STATE MACHINE: distinguishes "features enabled, waiting for reboot" (expected,
        reported as SUCCESS/exit 0, no failures) from real errors. No more spurious
        PARTIAL/Exit 1 on the pre-reboot cycle.
      - DISM.exe for enablement with numeric exit-code classification (0/3010 = ok,
        14098 = store corrupt, else error) -- no dependency on localized message text.
      - STORE-CORRUPTION ESCALATION: on DISM 14098 the script stops, writes a clear
        STATUS=BLOCKED|REASON=StoreCorrupt (EventID 1004) and exits 1 so Intune surfaces
        the device for manual repair instead of looping and worsening corruption.
      - GATE 0 relaxed/corrected: only hard-fails on firmware virt disabled when it is
        actually confirmed (HypervisorPresent False AND VirtualizationFirmwareEnabled
        explicitly False). "Hyper-V not enabled yet" no longer false-fails the gate.
      - RebootPending marker cleared once services are confirmed running.
    (Earlier changelog v1.2-v1.8 retained in git history.)
#>

# ===========================================================================
# LOGGING SETUP
# ===========================================================================
$LogDir      = "$env:ProgramData\Microsoft\IntuneManagementExtension\Logs\Claude"
$LogFile     = "$LogDir\ClaudeCowork-Remediation.log"
$EventSource = "ClaudeCoworkMSIX"
$EventLog    = "Application"
$FlagFile          = "$LogDir\ClaudePrereqsReady.flag"
$RebootPendingFlag = "$LogDir\ClaudeCowork-RebootPending.flag"
$BlockedFlag       = "$LogDir\ClaudeCowork-Blocked.flag"

# Reboot prompt (delivered WITHOUT a second Intune remediation): this SYSTEM script
# drops a user-context prompt script and registers a scheduled task to run it in the
# logged-on user's session (same trick install2.ps1 uses), removing both once READY.
$PromptDir    = "$env:ProgramData\AnthropicClaude"
$PromptScript = "$PromptDir\CoworkRebootPrompt.ps1"
$PromptTask   = "ClaudeCoworkRebootPrompt"

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

function Write-Evt {
    param([int]$Id, [string]$Type, [string]$Message)
    try { Write-EventLog -LogName $EventLog -Source $EventSource -EventId $Id -EntryType $Type -Message $Message -ErrorAction SilentlyContinue } catch {}
}

Write-Log "========================================="
Write-Log "Claude Cowork remediation started (v2.3)"
Write-Log "Host: $env:COMPUTERNAME | OS: $([System.Environment]::OSVersion.VersionString)"
Write-Log "========================================="

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Test-PendingReboot {
    # Authoritative signals that a servicing reboot is outstanding. Deliberately
    # does NOT use PendingFileRenameOperations (almost always present, too noisy).
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { return $true }
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { return $true }
    if (Test-Path $RebootPendingFlag) { return $true }
    return $false
}

function Get-FeatureState {
    param([string]$Name)
    try { return (Get-WindowsOptionalFeature -Online -FeatureName $Name -ErrorAction Stop).State } catch { return 'Unknown' }
}

# Returns: 'Enabled' | 'RebootRequired' | 'StoreCorrupt' | 'Error:<code>'
function Enable-FeatureDism {
    param([string]$Name)
    $null = & dism.exe /online /enable-feature /featurename:$Name /all /norestart 2>&1
    $code = $LASTEXITCODE
    switch ($code) {
        0     { return 'RebootRequired' }   # enabled; treat as reboot-required for these features
        3010  { return 'RebootRequired' }   # ERROR_SUCCESS_REBOOT_REQUIRED
        14098 { return 'StoreCorrupt'   }   # CBS_E_STORE_CORRUPT (0x800f0831)
        -2146498511 { return 'StoreCorrupt' }
        -2146963694 { return 'StoreCorrupt' } # 0x80073712 ERROR_SXS_COMPONENT_STORE_CORRUPT
        default { return "Error:$code" }
    }
}

$applied  = [System.Collections.Generic.List[string]]::new()
$skipped  = [System.Collections.Generic.List[string]]::new()
$failures = [System.Collections.Generic.List[string]]::new()

function Complete-Run {
    param([string]$Status, [string]$Detail, [int]$ExitCode, [int]$EvtId, [string]$EvtType)
    Write-Log "========================================="
    Write-Log "Result: STATUS=$Status | $Detail"
    Write-Log "Applied : $($applied  -join ' | ')"
    Write-Log "Skipped : $($skipped  -join ' | ')"
    Write-Log "Failures: $($failures -join ' | ')"
    Write-Log "========================================="
    $msg = "Claude Cowork remediation on $env:COMPUTERNAME.`nSTATUS=$Status`n$Detail`nApplied: $($applied -join ', ')`nFailures: $($failures -join ', ')"
    Write-Evt -Id $EvtId -Type $EvtType -Message $msg
    Write-Host "STATUS=$Status|$Detail|APPLIED=$($applied.Count)|FAILURES=$($failures.Count)"
    if ($applied.Count)  { Write-Host "APPLIED: $($applied -join ' | ')" }
    if ($failures.Count) { Write-Host "FAILURES: $($failures -join ' | ')" }
    exit $ExitCode
}

function Write-ReadyFlag {
    if (-not (Test-Path $FlagFile)) {
        "PrereqsReady=$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')|Host=$env:COMPUTERNAME" |
            Out-File -FilePath $FlagFile -Encoding UTF8 -Force
        Write-Log "Prereqs flag written: $FlagFile"
    } else {
        Write-Log "Prereqs flag already exists -- not overwritten."
    }
}

# The user-context reboot prompt. Single-quoted here-string = written verbatim to disk;
# its $variables are evaluated when the child script runs in the user session, not here.
$RebootPromptBody = @'
# CoworkRebootPrompt.ps1 -- generated by Remediate-ClaudeCowork.ps1.
# Runs in the USER session via a scheduled task (no second Intune remediation).
# Self-gates on ClaudeCowork-RebootPending.flag; prompts to restart, forced backstop.
$ErrorActionPreference = "SilentlyContinue"

$DeferHours         = 4
$MaxDefers          = 3
$ForceAfterHours    = 48
$ForcedCountdownSec = 900
$EnableForcedReboot = $true
$MinGraceHours      = 2
$MaxReboots         = 3

$Flag     = "$env:ProgramData\Microsoft\IntuneManagementExtension\Logs\Claude\ClaudeCowork-RebootPending.flag"
$StateKey = "HKCU:\Software\Claude\CoworkReboot"
$LogDir   = "$env:LOCALAPPDATA\Claude"
$LogFile  = "$LogDir\CoworkReboot.log"

if (-not (Test-Path $LogDir))   { New-Item -ItemType Directory -Path $LogDir   -Force | Out-Null }
if (-not (Test-Path $StateKey)) { New-Item -Path $StateKey -Force | Out-Null }

function Write-PLog { param([string]$m) "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $m" | Out-File -FilePath $LogFile -Append -Encoding UTF8 }
function Set-Snooze { param([int]$h) Set-ItemProperty -Path $StateKey -Name "SnoozeUntil" -Value ([string]((Get-Date).ToUniversalTime().AddHours($h).ToFileTimeUtc())) -Force }
function Get-Defers { try { [int](Get-ItemProperty -Path $StateKey -Name "Defers" -ErrorAction Stop).Defers } catch { 0 } }
function Get-Reboots { try { [int](Get-ItemProperty -Path $StateKey -Name "RebootCount" -ErrorAction Stop).RebootCount } catch { 0 } }

# Nothing pending -> clear per-user state and exit.
if (-not (Test-Path $Flag)) {
    Remove-ItemProperty -Path $StateKey -Name "SnoozeUntil","Defers","RebootCount" -ErrorAction SilentlyContinue
    exit 0
}

# Initial grace based on flag age.
try { $ageH = ((Get-Date) - (Get-Item $Flag).LastWriteTime).TotalHours } catch { $ageH = 999999 }
if ($ageH -lt $MinGraceHours) { exit 0 }

# Snooze window.
try {
    $s = (Get-ItemProperty -Path $StateKey -Name "SnoozeUntil" -ErrorAction Stop).SnoozeUntil
    if ($s -and ((Get-Date).ToUniversalTime() -lt [DateTime]::FromFileTimeUtc([Int64]$s))) { exit 0 }
} catch {}

# Self-verify: is a reboot even still needed? If vmcompute is already running (or the
# prereqs-ready flag exists), the pending flag is stale -> never reboot a healthy device.
$vmc = Get-Service -Name vmcompute -ErrorAction SilentlyContinue
if (($vmc -and $vmc.Status -eq 'Running') -or (Test-Path "$env:ProgramData\Microsoft\IntuneManagementExtension\Logs\Claude\ClaudePrereqsReady.flag")) {
    Write-PLog "Prereqs already satisfied (vmcompute running / ready flag present) -- reboot not needed; cleaning up, no restart."
    Remove-Item $Flag -Force -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path $StateKey -Name "SnoozeUntil","Defers","RebootCount" -ErrorAction SilentlyContinue
    exit 0
}

# Reboot cap: never trigger more than $MaxReboots restarts. If that many reboots did not
# bring the prereqs up, stop rebooting and leave the device for manual attention.
if ((Get-Reboots) -ge $MaxReboots) {
    Write-PLog "Reboot cap reached ($MaxReboots) without prereqs becoming ready -- NOT rebooting again; needs manual attention."
    "RebootCapReached=$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')|Count=$(Get-Reboots)" | Out-File -FilePath (Join-Path $LogDir 'CoworkReboot-Capped.flag') -Encoding UTF8 -Force
    exit 0
}

$defers = Get-Defers
$forced = $EnableForcedReboot -and (($ageH -ge $ForceAfterHours) -or ($defers -ge $MaxDefers))
Write-PLog "Prompt due. ageH=$([math]::Round($ageH,1)) defers=$defers forced=$forced"

Add-Type -AssemblyName System.Windows.Forms | Out-Null
Add-Type -AssemblyName System.Drawing | Out-Null

function Invoke-Restart { param([int]$Delay,[string]$Comment)
    $n = (Get-Reboots) + 1
    Set-ItemProperty -Path $StateKey -Name "RebootCount" -Value $n -Force
    Write-PLog "Scheduling restart in ${Delay}s (reboot $n/$MaxReboots)."
    & shutdown.exe /r /t $Delay /c $Comment /d p:2:4 | Out-Null
    Set-Snooze ([math]::Ceiling(($Delay/3600.0)+0.5))
}

$title = "Claude Cowork - restart required"

if ($forced) {
    $form = New-Object System.Windows.Forms.Form
    $form.Text = $title; $form.Size = New-Object System.Drawing.Size(520,240)
    $form.StartPosition = "CenterScreen"; $form.TopMost = $true
    $form.FormBorderStyle = "FixedDialog"; $form.ControlBox = $false
    $form.MaximizeBox = $false; $form.MinimizeBox = $false
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Size = New-Object System.Drawing.Size(480,120); $lbl.Location = New-Object System.Drawing.Point(20,20)
    $mins = [math]::Round($ForcedCountdownSec/60)
    $lbl.Text = "Setup for Claude Cowork needs to finish and requires a restart.`r`n`r`nYour PC will restart automatically in about $mins minutes. Please save your work now.`r`n`r`nYou can restart immediately with the button below."
    $form.Controls.Add($lbl)
    $btn = New-Object System.Windows.Forms.Button
    $btn.Text = "Restart now"; $btn.Size = New-Object System.Drawing.Size(120,32); $btn.Location = New-Object System.Drawing.Point(370,150)
    $btn.Add_Click({ $form.Tag = "now"; $form.Close() }); $form.Controls.Add($btn); $form.AcceptButton = $btn
    $timer = New-Object System.Windows.Forms.Timer; $timer.Interval = 60000
    $timer.Add_Tick({ $timer.Stop(); $form.Close() }); $timer.Start()
    [void]$form.ShowDialog(); $timer.Stop()
    if ($form.Tag -eq "now") { Invoke-Restart 60 "Claude Cowork setup: restarting now at your request." }
    else { Invoke-Restart $ForcedCountdownSec "Claude Cowork setup requires a restart to finish." }
    Write-PLog "Forced-mode restart scheduled."
    exit 0
} else {
    $form = New-Object System.Windows.Forms.Form
    $form.Text = $title; $form.Size = New-Object System.Drawing.Size(520,220)
    $form.StartPosition = "CenterScreen"; $form.TopMost = $true
    $form.FormBorderStyle = "FixedDialog"; $form.MaximizeBox = $false; $form.MinimizeBox = $false
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Size = New-Object System.Drawing.Size(480,100); $lbl.Location = New-Object System.Drawing.Point(20,20)
    $lbl.Text = "Claude Cowork setup is almost done -- it just needs a restart to finish enabling the required Windows features.`r`n`r`nRestart now, or you will be reminded again later."
    $form.Controls.Add($lbl)
    $btnNow = New-Object System.Windows.Forms.Button
    $btnNow.Text = "Restart now"; $btnNow.Size = New-Object System.Drawing.Size(120,32); $btnNow.Location = New-Object System.Drawing.Point(250,130)
    $btnNow.Add_Click({ $form.Tag = "now"; $form.Close() }); $form.Controls.Add($btnNow)
    $btnLater = New-Object System.Windows.Forms.Button
    $btnLater.Text = "Remind me later"; $btnLater.Size = New-Object System.Drawing.Size(120,32); $btnLater.Location = New-Object System.Drawing.Point(380,130)
    $btnLater.Add_Click({ $form.Tag = "later"; $form.Close() }); $form.Controls.Add($btnLater); $form.AcceptButton = $btnNow
    [void]$form.ShowDialog()
    if ($form.Tag -eq "now") { Invoke-Restart 60 "Claude Cowork setup: restarting now at your request."; Write-PLog "User chose Restart now." }
    else { Set-ItemProperty -Path $StateKey -Name "Defers" -Value ($defers + 1) -Force; Set-Snooze $DeferHours; Write-PLog "User deferred (now $($defers+1)). Snoozed ${DeferHours}h." }
    exit 0
}
'@

function Register-RebootPromptTask {
    # Drop the prompt script and (re)register a user-context scheduled task that runs it
    # at logon and every few hours, so the reboot nudge is delivered without a second
    # Intune remediation. Idempotent; no-ops gracefully when no user is logged on.
    try {
        if (-not (Test-Path $PromptDir)) { New-Item -ItemType Directory -Path $PromptDir -Force | Out-Null }
        Set-Content -Path $PromptScript -Value $RebootPromptBody -Encoding UTF8 -Force
        $who = (Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue).UserName
        if (-not $who) { Write-Log "Reboot prompt: no interactive user yet; task will be created on a later run."; return }
        $act  = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PromptScript`""
        $prin = New-ScheduledTaskPrincipal -UserId $who -LogonType Interactive -RunLevel Limited
        $tLogon = New-ScheduledTaskTrigger -AtLogOn -User $who
        $tRep   = New-ScheduledTaskTrigger -Once -At ((Get-Date).AddMinutes(5)) -RepetitionInterval (New-TimeSpan -Hours 4) -RepetitionDuration (New-TimeSpan -Days 365)
        $set  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
        $task = New-ScheduledTask -Action $act -Principal $prin -Trigger @($tLogon,$tRep) -Settings $set
        Register-ScheduledTask -TaskName $PromptTask -InputObject $task -Force -ErrorAction Stop | Out-Null
        Write-Log "Reboot prompt task registered for $who."
    } catch {
        Write-Log "WARN: could not register reboot prompt task - $_" "WARN"
    }
}

function Remove-RebootPromptTask {
    Unregister-ScheduledTask -TaskName $PromptTask -Confirm:$false -ErrorAction SilentlyContinue
    Remove-Item $PromptScript -Force -ErrorAction SilentlyContinue
    Write-Log "Reboot prompt task removed (prereqs ready)."
}

# ===========================================================================
# GATE -1: Windows 365 Cloud PC skip
# ===========================================================================
Write-Log "--- GATE -1: Cloud PC detection"
try {
    $model = (Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop).Model
    if ($model -like "Cloud PC*") {
        Write-Log "Cloud PC detected (model: $model). Writing flag so Claude installs without Cowork."
        Write-ReadyFlag
        Complete-Run -Status "SKIPPED" -Detail "GATE=CloudPC|MODEL=$model" -ExitCode 0 -EvtId 1002 -EvtType "Information"
    }
} catch {
    Write-Log "WARN: Cloud PC model query failed  -  $_. Continuing." "WARN"
}

# ===========================================================================
# GATE 0: Firmware virtualisation (VT-x/AMD-V)
#
# v2.0: only hard-fail when firmware virt is CONFIRMED disabled. When Hyper-V
# is not yet enabled, HypervisorPresent is legitimately False -- that must NOT
# be mistaken for "BIOS off", or the script would refuse to ever enable it.
# ===========================================================================
Write-Log "--- GATE 0: Firmware virtualisation"
try {
    $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
    if ($cs.HypervisorPresent -eq $true) {
        Write-Log "PASS: HypervisorPresent = True (hypervisor already running)."
    } else {
        # Hypervisor not running. Distinguish 'BIOS virt off' from 'Hyper-V not enabled yet'.
        $fw = (Get-CimInstance -ClassName Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1).VirtualizationFirmwareEnabled
        if ($fw -eq $false) {
            $msg = "GATE FAIL: Firmware virtualisation (VT-x/AMD-V) is disabled in BIOS/UEFI (VirtualizationFirmwareEnabled=False, HypervisorPresent=False). Manual BIOS change required."
            Write-Log $msg "WARN"
            Complete-Run -Status "FAILED" -Detail "GATE=HypervisorNotPresent|ACTION_REQUIRED=EnableVirtualisationInBIOS" -ExitCode 1 -EvtId 1003 -EvtType "Warning"
        } else {
            Write-Log "INFO: HypervisorPresent=False but firmware virt not confirmed disabled (VirtualizationFirmwareEnabled=$fw). Hyper-V likely just not enabled yet. Continuing."
        }
    }
} catch {
    Write-Log "WARN: Win32_ComputerSystem query failed  -  $_. Continuing." "WARN"
}

# ===========================================================================
# GATE 0b: Guest VM without nested virtualisation
# ===========================================================================
Write-Log "--- GATE 0b: Guest VM / nested virtualisation"
$guestIntegrationSvcs = @("vmicheartbeat","vmicshutdown","vmickvpexchange","vmicvss","vmicguestinterface")
$isGuestVM        = $null -ne ($guestIntegrationSvcs | Where-Object { (Get-Service -Name $_ -ErrorAction SilentlyContinue).Status -eq "Running" })
$vmcomputePresent = $null -ne (Get-Service -Name "vmcompute" -ErrorAction SilentlyContinue)

if ($isGuestVM -and -not $vmcomputePresent) {
    $hvFeatureState = Get-FeatureState -Name "Microsoft-Hyper-V"
    if ($hvFeatureState -eq "Disabled") {
        Write-Log "INFO: Guest VM without vmcompute but Microsoft-Hyper-V is Disabled (not absent). Will attempt to enable."
    } else {
        $msg = "GATE FAIL: Guest VM without nested virtualisation. vmcompute absent, Hyper-V state '$hvFeatureState'. Fix on parent host: Set-VMProcessor -ExposeVirtualizationExtensions `$true (Azure: Dv3/Ev3+)."
        Write-Log $msg "WARN"
        Complete-Run -Status "FAILED" -Detail "GATE=GuestVMNoNestedVirt|ACTION_REQUIRED=EnableNestedVirtOnParentHost" -ExitCode 1 -EvtId 1003 -EvtType "Warning"
    }
} elseif ($isGuestVM) {
    Write-Log "INFO: Guest VM detected, vmcompute present  -  nested virt enabled. Continuing."
} else {
    Write-Log "PASS: Bare-metal host."
}

# ===========================================================================
# ASSESS CURRENT STATE
# ===========================================================================
$requiredFeatures = @("VirtualMachinePlatform","Microsoft-Hyper-V","Microsoft-Hyper-V-Services","Microsoft-Hyper-V-Hypervisor")
$featureState = @{}
foreach ($f in $requiredFeatures) { $featureState[$f] = Get-FeatureState -Name $f }
$notEnabled = $requiredFeatures | Where-Object { $featureState[$_] -ne "Enabled" }
$allEnabled = ($notEnabled.Count -eq 0)

$vmcomputeSvc = Get-Service -Name "vmcompute" -ErrorAction SilentlyContinue
$hnsSvc       = Get-Service -Name "HNS"       -ErrorAction SilentlyContinue
$vmcomputeRunning = ($vmcomputeSvc -and $vmcomputeSvc.Status -eq "Running")
$servicesPresent  = ($null -ne $vmcomputeSvc -and $null -ne $hnsSvc)
$pendingReboot    = Test-PendingReboot

Write-Log "State: featuresEnabled=$allEnabled (notEnabled: $($notEnabled -join ',')) | vmcomputePresent=$($null -ne $vmcomputeSvc) running=$vmcomputeRunning | HNSpresent=$($null -ne $hnsSvc) | pendingReboot=$pendingReboot"

# ===========================================================================
# CASE A: Everything enabled and services present -> ensure running + Automatic
# ===========================================================================
if ($allEnabled -and $servicesPresent) {
    foreach ($svcName in @("vmcompute","HNS")) {
        $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
        if (-not $svc) { $failures.Add("$svcName=NotFound"); continue }
        try {
            if ($svcName -eq "vmcompute" -and $svc.StartType -ne "Automatic") {
                Set-Service -Name $svcName -StartupType Automatic -ErrorAction Stop
                $applied.Add("$svcName=StartupTypeAutomatic")
                Write-Log "$svcName StartupType set to Automatic."
            }
            if ($svc.Status -ne "Running") {
                Start-Service -Name $svcName -ErrorAction Stop
                $applied.Add("$svcName=Started")
                Write-Log "$svcName started."
            } else {
                $skipped.Add("$svcName=AlreadyRunning")
            }
        } catch {
            $failures.Add("$svcName=Error:$($_.Exception.Message)")
            Write-Log "ERROR: could not start $svcName  -  $_" "ERROR"
        }
    }

    if ($failures.Count -eq 0) {
        Remove-Item $RebootPendingFlag -Force -ErrorAction SilentlyContinue
        Remove-RebootPromptTask
        # Prereqs reached READY -- clear any stale store-corruption latch.
        if (Test-Path $BlockedFlag) {
            Remove-Item $BlockedFlag -Force -ErrorAction SilentlyContinue
            Write-Log "Cleared stale ClaudeCowork-Blocked.flag (prereqs now READY)."
        }
        Write-ReadyFlag
        Complete-Run -Status "SUCCESS" -Detail "READY=True|REBOOT=False" -ExitCode 0 -EvtId 1002 -EvtType "Information"
    } else {
        Complete-Run -Status "PARTIAL" -Detail "READY=False|ServiceStartFailed" -ExitCode 1 -EvtId 1003 -EvtType "Warning"
    }
}

# ===========================================================================
# CASE B: Features enabled, but services not yet present -> waiting for reboot
# ===========================================================================
if ($allEnabled -and -not $servicesPresent) {
    if (-not (Test-Path $RebootPendingFlag)) {
        "RebootPending=$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')|Reason=FeaturesEnabled" | Out-File -FilePath $RebootPendingFlag -Encoding UTF8 -Force
    }
    Write-Log "Features enabled but vmcompute/HNS not yet registered -> reboot required to complete servicing."
    Register-RebootPromptTask
    Complete-Run -Status "SUCCESS" -Detail "READY=False|REBOOT=REQUIRED|STAGE=FeaturesEnabledAwaitingReboot" -ExitCode 0 -EvtId 1002 -EvtType "Information"
}

# ===========================================================================
# CASE C: Some features not enabled
# ===========================================================================
if (-not $allEnabled) {

    # LATCH: a previous run hit component-store corruption. Do NOT re-run dism
    # /enable against a corrupt store every cycle. Surface for manual repair and
    # stop. Re-arm by deleting ClaudeCowork-Blocked.flag after repairing the store.
    if (Test-Path $BlockedFlag) {
        $blockedSince = (Get-Content $BlockedFlag -ErrorAction SilentlyContinue | Select-Object -First 1)
        Write-Log "BLOCKED latch present ($blockedSince). Component store previously reported corrupt. NOT retrying enable. Manual repair + delete of $BlockedFlag required." "ERROR"
        $failures.Add("Blocked=StoreCorruptLatch")
        Complete-Run -Status "BLOCKED" -Detail "REASON=StoreCorrupt|STAGE=Latched|ACTION_REQUIRED=ManualStoreRepairThenDeleteBlockedFlag" -ExitCode 1 -EvtId 1004 -EvtType "Error"
    }

    # GUARD: never enable on top of an un-committed pending reboot (root cause of
    # the store corruption we hardened against). Defer until the reboot happens.
    if ($pendingReboot) {
        Write-Log "Features not fully enabled AND a servicing reboot is pending. Deferring enable until reboot -- NOT stacking another enable operation." "WARN"
        Register-RebootPromptTask
        Complete-Run -Status "SUCCESS" -Detail "READY=False|REBOOT=REQUIRED|STAGE=EnableDeferredPendingReboot" -ExitCode 0 -EvtId 1002 -EvtType "Information"
    }

    $enabledSomething = $false
    foreach ($f in $requiredFeatures) {
        if ($featureState[$f] -eq "Enabled") { $skipped.Add("$f=AlreadyEnabled"); continue }
        Write-Log "Enabling $f (state was: $($featureState[$f])) ..."
        $result = Enable-FeatureDism -Name $f
        switch ($result) {
            'RebootRequired' {
                $applied.Add("$f=Enabled:RebootRequired")
                $enabledSomething = $true
                Write-Log "$f enabled. Reboot required."
            }
            'StoreCorrupt' {
                $msg = "BLOCKED: Enabling $f failed with component-store corruption (DISM 14098 / 0x800f0831). This cannot be fixed by feature enablement. Manual repair required: DISM /RestoreHealth with matching media, in-place repair upgrade, or Reset This PC. Halting to avoid worsening corruption."
                Write-Log $msg "ERROR"
                "Blocked=$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')|Reason=StoreCorrupt|Feature=$f|Host=$env:COMPUTERNAME" |
                    Out-File -FilePath $BlockedFlag -Encoding UTF8 -Force
                Write-Log "BLOCKED latch written: $BlockedFlag (delete after manual store repair to re-arm)."
                $failures.Add("$f=StoreCorrupt")
                Complete-Run -Status "BLOCKED" -Detail "REASON=StoreCorrupt|FEATURE=$f|ACTION_REQUIRED=ManualStoreRepair" -ExitCode 1 -EvtId 1004 -EvtType "Error"
            }
            default {
                Write-Log "ERROR: enabling $f failed  -  $result" "ERROR"
                $failures.Add("$f=$result")
            }
        }
    }

    if ($enabledSomething) {
        "RebootPending=$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')|Reason=FeaturesJustEnabled" | Out-File -FilePath $RebootPendingFlag -Encoding UTF8 -Force
        Register-RebootPromptTask
        if ($failures.Count -eq 0) {
            Complete-Run -Status "SUCCESS" -Detail "READY=False|REBOOT=REQUIRED|STAGE=FeaturesEnabled" -ExitCode 0 -EvtId 1002 -EvtType "Information"
        } else {
            Complete-Run -Status "PARTIAL" -Detail "READY=False|REBOOT=REQUIRED|SomeFeaturesFailed" -ExitCode 1 -EvtId 1003 -EvtType "Warning"
        }
    } else {
        Complete-Run -Status "PARTIAL" -Detail "READY=False|NoFeaturesEnabled" -ExitCode 1 -EvtId 1003 -EvtType "Warning"
    }
}

# Fallback (should not be reached)
Complete-Run -Status "UNKNOWN" -Detail "READY=False|UnhandledState" -ExitCode 1 -EvtId 1003 -EvtType "Warning"
