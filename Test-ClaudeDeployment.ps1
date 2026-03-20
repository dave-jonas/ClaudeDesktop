#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Validates the full Claude Desktop deployment state on a machine.
.DESCRIPTION
    Checks and reports on every layer of the Claude Desktop deployment:
      - Prereqs flag file
      - Hyper-V Windows features
      - Hyper-V / HNS services
      - Provisioned Claude Appx package
      - Squirrel (non-MSIX) installs in user profiles
      - Per-user Claude Appx package registration
      - Per-user Start Menu shortcut

    Outputs PASS/FAIL for each check with remediation hints for failures.
.NOTES
    Version: 1.0
    Date:    2026-03
    Author:  David Carroll - Jonas Software Australia
#>

# ===========================================================================
# HELPERS
# ===========================================================================
$passCount = 0
$failCount = 0

function Write-Pass {
    param([string]$Label, [string]$Detail = "")
    $script:passCount++
    $line = "  [PASS] $Label"
    if ($Detail) { $line += " — $Detail" }
    Write-Host $line -ForegroundColor Green
}

function Write-Fail {
    param([string]$Label, [string]$Detail = "", [string]$Hint = "")
    $script:failCount++
    $line = "  [FAIL] $Label"
    if ($Detail) { $line += " — $Detail" }
    Write-Host $line -ForegroundColor Red
    if ($Hint) {
        Write-Host "         HINT: $Hint" -ForegroundColor Yellow
    }
}

function Write-Section {
    param([string]$Title)
    Write-Host ""
    Write-Host "--- $Title" -ForegroundColor Cyan
}

# ===========================================================================
# ENUMERATE USER PROFILES (used by multiple checks below)
# ===========================================================================
$profileList = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\*" `
    -ErrorAction SilentlyContinue |
    Where-Object { $_.PSChildName -match "^S-1-5-21-" -and (Test-Path $_.ProfileImagePath) }

# ===========================================================================
Write-Host ""
Write-Host "=======================================================" -ForegroundColor White
Write-Host "  Claude Desktop Deployment Validation" -ForegroundColor White
Write-Host "  Host: $env:COMPUTERNAME  |  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor White
Write-Host "=======================================================" -ForegroundColor White

# ===========================================================================
# CHECK 1: Prereqs flag file
# Checks both the current IME Logs path and the legacy Jonas path so machines
# that had the flag written before the path change still pass.
# ===========================================================================
Write-Section "CHECK 1: Prereqs flag file"
$FlagPathNew    = "$env:ProgramData\Microsoft\IntuneManagementExtension\Logs\Claude\ClaudePrereqsReady.flag"
$FlagPathLegacy = "$env:ProgramData\Jonas\Flags\ClaudePrereqsReady.flag"
$provisionedPkg = $null   # populated in CHECK 4, used in CHECK 6

if (Test-Path $FlagPathNew) {
    $flagContent = (Get-Content $FlagPathNew -Raw).Trim()
    Write-Pass "Flag exists (current path)" $flagContent
} elseif (Test-Path $FlagPathLegacy) {
    $flagContent = (Get-Content $FlagPathLegacy -Raw).Trim()
    Write-Pass "Flag exists (legacy path — will move on next remediation cycle)" $flagContent
} else {
    Write-Fail "Flag missing" $FlagPathNew `
        "Run Remediate-ClaudeCowork.ps1 and ensure Hyper-V services are running, then re-check."
}

# ===========================================================================
# CHECK 2: Hyper-V Windows features
# ===========================================================================
Write-Section "CHECK 2: Hyper-V Windows features"
$hvFeatures = @(
    "Microsoft-Hyper-V",
    "Microsoft-Hyper-V-Services",
    "Microsoft-Hyper-V-Hypervisor"
)
foreach ($feat in $hvFeatures) {
    try {
        $f = Get-WindowsOptionalFeature -Online -FeatureName $feat -ErrorAction Stop
        if ($f.State -eq "Enabled") {
            Write-Pass $feat "State=Enabled"
        } else {
            Write-Fail $feat "State=$($f.State)" `
                "Run: Enable-WindowsOptionalFeature -Online -FeatureName $feat -All -NoRestart  (reboot required)"
        }
    } catch {
        Write-Fail $feat "Query failed: $_" `
            "Ensure DISM is available and run as administrator."
    }
}

# ===========================================================================
# CHECK 3: Hyper-V and HNS services
# ===========================================================================
Write-Section "CHECK 3: Services (vmms, vmcompute, HNS)"
foreach ($svcName in @("vmms", "vmcompute", "HNS")) {
    $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
    if (-not $svc) {
        Write-Fail $svcName "Service does not exist" `
            "Hyper-V features may not be installed. Run Remediate-ClaudeCowork.ps1."
    } elseif ($svc.Status -eq "Running") {
        Write-Pass $svcName "Status=Running | StartType=$($svc.StartType)"
    } else {
        Write-Fail $svcName "Status=$($svc.Status)" `
            "Run: Start-Service -Name $svcName"
    }
}

# ===========================================================================
# CHECK 4: Provisioned Claude Appx package
# Matches on DisplayName OR PackageName containing "Claude" or "Anthropic"
# because the MSIX publisher prefix means DisplayName alone can miss it.
# Also checks per-user installs so we can distinguish "not provisioned
# system-wide" (fixable) from "not installed at all".
# ===========================================================================
Write-Section "CHECK 4: Claude Appx package"
$provisionedPkg = Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
    Where-Object {
        $_.DisplayName -like "*Claude*"  -or $_.DisplayName -like "*Anthropic*" -or
        $_.PackageName -like "*Claude*"  -or $_.PackageName -like "*Anthropic*"
    } |
    Select-Object -First 1

if ($provisionedPkg) {
    Write-Pass "Provisioned system-wide" $provisionedPkg.PackageName
} else {
    # Check if installed per-user (explains why the app works but isn't system-wide)
    $perUserPkg = Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like "*Claude*" -or $_.Name -like "*Anthropic*" } |
        Select-Object -First 1
    if ($perUserPkg) {
        Write-Fail "Not provisioned system-wide" "Found as per-user install: $($perUserPkg.PackageFullName)" `
            "App works for existing users but won't be available to new profiles. Run install_claude.ps1 to provision system-wide."
    } else {
        Write-Fail "Not installed" "" `
            "Run install_claude.ps1 to provision Claude system-wide."
    }
}

# ===========================================================================
# CHECK 5: Squirrel installs in user profiles
# ===========================================================================
Write-Section "CHECK 5: Squirrel (non-MSIX) installs in user profiles"
$squirrelFound = $false
foreach ($profile in $profileList) {
    $squirrelExe = Join-Path $profile.ProfileImagePath "AppData\Local\AnthropicClaude\Update.exe"
    $squirrelDir = Join-Path $profile.ProfileImagePath "AppData\Local\AnthropicClaude"
    if (Test-Path $squirrelExe) {
        Write-Fail "Squirrel install found: $($profile.ProfileImagePath)" $squirrelDir `
            "Remove AppData\Local\AnthropicClaude from this profile, then re-run install_claude.ps1."
        $squirrelFound = $true
    }
}
if (-not $squirrelFound) {
    Write-Pass "No Squirrel installs found across $($profileList.Count) profile(s)"
}

# ===========================================================================
# CHECK 6: Per-user Claude Appx package registration
# ===========================================================================
Write-Section "CHECK 6: Claude Appx registration per user profile"
if (-not $provisionedPkg) {
    Write-Host "  [SKIP] No provisioned package found — skipping per-user registration check." -ForegroundColor DarkGray
} else {
    $allUserPkgs = Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like "*Claude*" }

    # Build a lookup: SID -> registered
    $registeredSids = @{}
    foreach ($pkg in $allUserPkgs) {
        foreach ($userInfo in $pkg.PackageUserInformation) {
            if ($userInfo.InstallState -eq "Installed") {
                $registeredSids[$userInfo.UserSecurityId] = $pkg.PackageFullName
            }
        }
    }

    foreach ($profile in $profileList) {
        $sid = $profile.PSChildName
        $upPath = $profile.ProfileImagePath
        if ($registeredSids.ContainsKey($sid)) {
            Write-Pass "Registered: $upPath" $registeredSids[$sid]
        } else {
            Write-Fail "Not registered: $upPath" "SID: $sid" `
                "User must log in to trigger MSIX registration, or re-run install_claude.ps1."
        }
    }
}

# ===========================================================================
# CHECK 7: Start Menu shortcut
# Checks the system-wide Start Menu (covers all users for provisioned MSIX)
# and the currently logged-on interactive user's profile.
# Does NOT iterate every profile — service accounts and defaultuser0 don't need Claude.
# ===========================================================================
Write-Section "CHECK 7: Start Menu shortcut"
$systemStartMenu = "$env:ProgramData\Microsoft\Windows\Start Menu\Programs"

# System-wide shortcut (any .lnk with Claude or Anthropic in the name)
$systemLnk = Get-ChildItem $systemStartMenu -Filter "*.lnk" -Recurse -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -like "*Claude*" -or $_.Name -like "*Anthropic*" } |
    Select-Object -First 1

if ($systemLnk) {
    Write-Pass "System Start Menu shortcut" $systemLnk.FullName
} else {
    Write-Fail "System Start Menu shortcut missing" $systemStartMenu `
        "Claude may not be provisioned system-wide. Check CHECK 4 and run install_claude.ps1."
}

# Currently logged-on interactive user
$loggedOnUser = (Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue).UserName
if ($loggedOnUser) {
    $userName = $loggedOnUser.Split('\')[-1]
    $userProfile = $profileList | Where-Object { $_.ProfileImagePath -like "*\$userName" } | Select-Object -First 1
    if ($userProfile) {
        $userStartMenu = Join-Path $userProfile.ProfileImagePath "AppData\Roaming\Microsoft\Windows\Start Menu\Programs"
        $userLnk = Get-ChildItem $userStartMenu -Filter "*.lnk" -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like "*Claude*" -or $_.Name -like "*Anthropic*" } |
            Select-Object -First 1
        if ($userLnk) {
            Write-Pass "Current user ($loggedOnUser) Start Menu" $userLnk.FullName
        } else {
            Write-Fail "Current user ($loggedOnUser) Start Menu shortcut missing" "" `
                "User may need to sign out and back in for MSIX registration to complete."
        }
    }
} else {
    Write-Host "  [INFO] No interactive user logged on — skipping per-user shortcut check." -ForegroundColor DarkGray
}

# ===========================================================================
# SUMMARY
# ===========================================================================
Write-Host ""
Write-Host "=======================================================" -ForegroundColor White
$totalChecks = $passCount + $failCount
Write-Host "  RESULT: $passCount/$totalChecks checks passed" -ForegroundColor $(if ($failCount -eq 0) { "Green" } else { "Red" })
if ($failCount -gt 0) {
    Write-Host "  $failCount check(s) failed — see HINT lines above." -ForegroundColor Yellow
}
Write-Host "=======================================================" -ForegroundColor White
Write-Host ""

exit $(if ($failCount -gt 0) { 1 } else { 0 })
