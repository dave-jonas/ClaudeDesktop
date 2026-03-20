#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Installs Claude Desktop as a machine-wide provisioned MSIX.
.DESCRIPTION
    Checks for ClaudePrereqsReady.flag before installing.
    This flag is written by Detect-ClaudeCowork.ps1 (or Remediate-ClaudeCowork.ps1) once
    Hyper-V features are enabled and all required services (vmms, vmcompute, HNS) are running.

    If the flag is absent the script exits 1 — Intune will retry on next check-in.
    Once the flag is present:
      1. Kills any running Claude processes
      2. Removes any existing provisioned Claude Appx package
      3. Removes Claude Appx packages for all users
      4. Deletes AppData\Local\AnthropicClaude from every user profile
      5. Provisions Claude system-wide via Add-AppxProvisionedPackage -Regions "All"

    Logging: C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\Claude\ClaudeInstall.log
             Automatically collected by Intune > Collect diagnostics.
             Windows Application event log, Source "ClaudeCoworkMSIX"
             EventID 2000 = success, 2001 = failed, 2002 = prereqs not ready
.NOTES
    Version:    1.5
    Date:       2026-03
    Author:    David Carroll - Jonas Software Australia. 
#>
param(
  [string]$PackagePath = "$PSScriptRoot\Claude.msix"
)

# ===========================================================================
# LOGGING SETUP
# ===========================================================================
$LogDir      = "$env:ProgramData\Microsoft\IntuneManagementExtension\Logs\Claude"
$LogFile     = "$LogDir\ClaudeInstall.log"
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
    Write-Host "$ts [$Level] $Message"
}

function Write-EventLog-Safe {
    param([int]$EventId, [string]$EntryType, [string]$Message)
    try {
        Write-EventLog -LogName $EventLog -Source $EventSource -EventId $EventId `
            -EntryType $EntryType -Message $Message -ErrorAction SilentlyContinue
    } catch {
        Write-Log "WARN: Event log write failed - $_" "WARN"
    }
}

Write-Log "========================================="
Write-Log "Claude install started (v1.4)"
Write-Log "Host: $env:COMPUTERNAME | OS: $([System.Environment]::OSVersion.VersionString)"
Write-Log "PackagePath: $PackagePath"
Write-Log "========================================="

# ===========================================================================
# PREREQS FLAG CHECK
# ===========================================================================
$FlagFile = "$env:ProgramData\Microsoft\IntuneManagementExtension\Logs\Claude\ClaudePrereqsReady.flag"
Write-Log "Checking prereqs flag: $FlagFile"

if (-not (Test-Path $FlagFile)) {
    $msg = "PREREQS NOT READY: $FlagFile not found. Hyper-V services not yet confirmed running. Intune will retry on next check-in."
    Write-Log $msg "WARN"
    Write-EventLog-Safe -EventId 2002 -EntryType "Warning" -Message $msg
    exit 1
}

Write-Log "Prereqs flag found. Contents: $(Get-Content $FlagFile)"

# ===========================================================================
# STEP 1: Kill any running Claude processes
# ===========================================================================
Write-Log "--- STEP 1: Killing Claude processes"
$claudeProcs = Get-Process -Name "Claude*" -ErrorAction SilentlyContinue
if ($claudeProcs) {
    $claudeProcs | Stop-Process -Force -ErrorAction SilentlyContinue
    Write-Log "Killed $($claudeProcs.Count) Claude process(es): $($claudeProcs.Name -join ', ')"
} else {
    Write-Log "No Claude processes running."
}

# ===========================================================================
# STEP 2: Remove existing provisioned Claude Appx package
# ===========================================================================
Write-Log "--- STEP 2: Removing provisioned Claude package"
$provisioned = Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName -like "*Claude*" }
if ($provisioned) {
    foreach ($pkg in $provisioned) {
        Write-Log "  Removing provisioned package: $($pkg.PackageName)"
        try {
            Remove-AppxProvisionedPackage -Online -PackageName $pkg.PackageName -ErrorAction Stop | Out-Null
            Write-Log "  Removed: $($pkg.PackageName)"
        } catch {
            Write-Log "  WARN: Failed to remove $($pkg.PackageName): $_" "WARN"
        }
    }
} else {
    Write-Log "  No provisioned Claude package found."
}

# ===========================================================================
# STEP 3: Remove existing Claude Appx packages for all users
# ===========================================================================
Write-Log "--- STEP 3: Removing Claude Appx packages for all users"
$allUserPkgs = Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -like "*Claude*" }
if ($allUserPkgs) {
    foreach ($pkg in $allUserPkgs) {
        Write-Log "  Removing: $($pkg.PackageFullName)"
        try {
            Remove-AppxPackage -Package $pkg.PackageFullName -AllUsers -ErrorAction Stop
            Write-Log "  Removed."
        } catch {
            Write-Log "  WARN: Failed to remove $($pkg.PackageFullName): $_" "WARN"
        }
    }
} else {
    Write-Log "  No per-user Claude packages found."
}

# ===========================================================================
# STEP 4: Delete AppData\Local\AnthropicClaude from every user profile
# ===========================================================================
Write-Log "--- STEP 4: Removing AnthropicClaude AppData from user profiles"
$profileList = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\*" `
    -ErrorAction SilentlyContinue |
    Where-Object { $_.PSChildName -match "^S-1-5-21-" -and (Test-Path $_.ProfileImagePath) }
Write-Log "Found $($profileList.Count) user profile(s)."
foreach ($profile in $profileList) {
    $claudeAppData = Join-Path $profile.ProfileImagePath "AppData\Local\AnthropicClaude"
    if (Test-Path $claudeAppData) {
        Write-Log "  Removing: $claudeAppData"
        try {
            Remove-Item -Path $claudeAppData -Recurse -Force -ErrorAction Stop
            Write-Log "  Removed."
        } catch {
            Write-Log "  WARN: Failed to remove ${claudeAppData}: $_" "WARN"
        }
    } else {
        Write-Log "  Not found (skipped): $claudeAppData"
    }
}

# ===========================================================================
# STEP 5: Provision Claude MSIX system-wide
# ===========================================================================
Write-Log "--- STEP 5: Provisioning Claude MSIX"
Write-Log "PackagePath: $PackagePath"

if (-not (Test-Path $PackagePath)) {
    $msg = "ERROR: Package not found at $PackagePath"
    Write-Log $msg "ERROR"
    Write-EventLog-Safe -EventId 2001 -EntryType "Error" -Message $msg
    exit 1
}

try {
    $result = Add-AppxProvisionedPackage -Online -PackagePath $PackagePath -SkipLicense -Regions "All" -Verbose 4>&1
    $result | ForEach-Object { Write-Log "  DISM: $_" }
    Write-Log "Claude provisioned successfully."
} catch {
    $msg = "ERROR: Failed to provision Claude MSIX: $_"
    Write-Log $msg "ERROR"
    Write-EventLog-Safe -EventId 2001 -EntryType "Error" -Message $msg
    exit 1
}

Write-Log "========================================="
Write-Log "Install complete."
Write-Log "========================================="

Write-EventLog-Safe -EventId 2000 -EntryType "Information" `
    -Message "Claude Desktop provisioned successfully on $env:COMPUTERNAME."

exit 0
