# Claude Desktop — Intune Deployment

This repo provides a more formal and detailed deployment guide than the official Anthropic documentation, covering Win32 app packaging, enterprise registry policy, and detection/uninstall scripts for deploying Claude Desktop system-wide via Microsoft Intune.

> **Work in progress — this deployment approach is still being tested. Always check Anthropic's official documentation as the authoritative reference, as guidance is likely to improve over time.**
>
> - [Deploy Claude Desktop for Windows](https://support.claude.com/en/articles/12622703-deploy-claude-desktop-for-windows)
> - [Enterprise configuration](https://support.claude.com/en/articles/12622667-enterprise-configuration)

---

## What's included

| File | Purpose |
|---|---|
| `install_claude.ps1` | Enables Virtual Machine Platform, provisions the MSIX system-wide |
| `detect_claude.ps1` | Detection script for Intune |
| `uninstall_claude.ps1` | Removes and deprovisions Claude for all users |
| `claude-desktop-intune-policy.json` | Intune custom configuration profile (OMA-URI) |

---

## Step 1 — Download the MSIX

Download the latest Claude Desktop MSIX from the Anthropic website:

**https://claude.ai/download**

Select **Windows** and download the `.msix` file. Save it as `Claude.msix`.

---

## Step 2 — Prepare the staging folder

Create a staging folder and place the following files in it:

```
C:\Staging\Claude\
    Claude.msix
    install_claude.ps1
    detect_claude.ps1
    uninstall_claude.ps1
```

All four files must be in the same folder before packaging.

---

## Step 3 — Create the .intunewin package

Download the Microsoft Win32 Content Prep Tool:

**https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool**

Run the following command:

```
IntuneWinAppUtil.exe -c "C:\Staging\Claude" -s install_claude.ps1 -o "C:\Output"
```

This produces `install_claude.intunewin` in your output folder. That's what you upload to Intune.

---

## Step 4 — Create the Win32 app in Intune

1. Go to **Intune admin centre > Apps > All apps > Add**
2. Select **Windows app (Win32)**
3. Upload `install_claude.intunewin`

### App information

Fill in name, description, and publisher as needed. No specific requirements here.

### Program tab

| Field | Value |
|---|---|
| Install command | `powershell.exe -ExecutionPolicy Bypass -File install_claude.ps1 -PackagePath ".\Claude.msix"` |
| Uninstall command | `powershell.exe -ExecutionPolicy Bypass -File uninstall_claude.ps1` |
| Install behaviour | **System** |
| Device restart behaviour | No specific action |

Install behaviour must be set to **System**. The install script uses `Add-AppxProvisionedPackage` which requires SYSTEM context. It will not work if set to User.

### Requirements tab

| Field | Value |
|---|---|
| Operating system architecture | 64-bit |
| Minimum OS | Windows 10 2004 |

### Detection tab

Select **Use a custom detection script** and upload `detect_claude.ps1`.

| Field | Value |
|---|---|
| Run script as 32-bit process | No |
| Enforce script signature check | No |

### Assignments

Assign to a **device group**, not a user group. The MSIX is provisioned system-wide so device-based targeting is required.

Start with a pilot group. Check install status under **Devices > Monitor > App install status** before rolling out wider.

---

## Step 5 — Deploy the registry policy

This step applies the Claude enterprise settings (auto-updates, Cowork, extensions) via a separate Intune configuration profile. It does not require any PowerShell.

1. Go to **Devices > Configuration profiles > Create profile**
2. Platform: **Windows 10 and later**
3. Profile type: **Templates > Custom**
4. Click **Import** and upload `claude-desktop-intune-policy.json`
5. Review the settings, then assign to the same device group

The policy writes the following registry keys to `HKLM\SOFTWARE\Policies\Claude`:

| Setting | Value | Notes |
|---|---|---|
| `disableAutoUpdates` | 0 | Auto-updates on |
| `autoUpdaterEnforcementHours` | 72 | Force-restart within 72 hours to apply updates |
| `secureVmFeaturesEnabled` | 1 | Enables Cowork |
| `isDesktopExtensionEnabled` | 1 | Extensions on |
| `isDesktopExtensionDirectoryEnabled` | 1 | Extension directory access on |
| `isLocalDevMcpEnabled` | 1 | Local MCP servers on |
| `isClaudeCodeForDesktopEnabled` | 1 | Claude Code access on |

Review `isLocalDevMcpEnabled` and `isClaudeCodeForDesktopEnabled` before deploying to general staff. Both are on by default but explicitly setting them in policy locks the value so users and apps cannot override it.

> Check the [enterprise configuration reference](https://support.claude.com/en/articles/12622667-enterprise-configuration) for the current full list of supported policy keys, as Anthropic may add or change settings over time.

---

## Notes on Virtual Machine Platform

The install script enables the Windows **Virtual Machine Platform** optional feature. This is required for Cowork to function. The script uses `-NoRestart` so it will not force a reboot mid-deployment. Cowork will not be active until the device has rebooted after installation.

The registry policy and the Win32 app are deployed independently. The policy keys will land on devices before Claude is necessarily installed. That is fine. Claude reads the registry on launch.

---

## Testing manually

If you need to test the install script outside of Intune, open PowerShell **as Administrator** and run:

```powershell
.\install_claude.ps1 -PackagePath ".\Claude.msix"
```

SYSTEM context is provided by Intune at deployment time. Running manually requires an elevated session as the closest equivalent.

To verify the registry keys were applied:

```powershell
Get-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Claude"
```

To verify Claude is provisioned:

```powershell
Get-AppxProvisionedPackage -Online | Where-Object { $_.DisplayName -like "*Claude*" }
```
