# Claude Desktop — Intune Deployment

This repo covers deploying Claude Desktop system-wide via Microsoft Intune, including the Hyper-V prerequisites required for Claude Cowork to function. It allows Claude features including Cowork to run without requiring users to have local administrator rights — something Anthropic's own installer does not support out of the box.

> **Work in progress — tested on Windows 11 Pro managed devices. Always check Anthropic's official documentation as the authoritative reference.**
>
> - [Deploy Claude Desktop for Windows](https://support.claude.com/en/articles/12622703-deploy-claude-desktop-for-windows)
> - [Enterprise configuration](https://support.claude.com/en/articles/12622667-enterprise-configuration)

> **All scripts in this repository were written by Claude (the AI).** The code has been reviewed and tested in a production Intune environment, but it may contain bugs. Review everything before deploying to your fleet, test on a pilot group first, and adapt to your organisation's requirements. Use at your own risk.

---

## Background — why this approach is needed

### The user-context install problem

When a user downloads and runs the Claude installer directly, it installs via **Squirrel** — a per-user installer that drops into `AppData\Local\AnthropicClaude`. This causes several problems in a managed environment:

- It requires the user to have write access to their own AppData (fine) but the install is **invisible to Intune** — it won't appear as a managed app
- It **does not provision the app for other users** on the same device
- Squirrel self-updates silently, bypassing your MSIX version control
- It **conflicts directly with the MSIX provisioned install** — if both exist, you get duplicate entries, broken shortcuts, and update loops
- Crucially: the Squirrel install does **not** satisfy Intune's detection rule, so Intune will keep trying to install the MSIX on top of an existing Squirrel install

The `install_claude.ps1` script handles this by removing any existing Squirrel install from all user profiles before provisioning the MSIX. If users have previously installed Claude themselves, this cleanup is essential before the managed install will work cleanly.

### The virtualisation services requirement

Claude Cowork relies on Windows virtualisation services (`vmms`, `vmcompute`, `HNS`) that are part of the Hyper-V stack. These services must be **running** before Cowork is used — having the Windows features installed is not enough if the services haven't started after a reboot.

Historically this required admin rights to configure. **This deployment handles the entire Hyper-V stack setup from SYSTEM context via the Intune Remediation**, so users do not need local administrator rights. Once deployed, Claude Cowork runs fully without admin privileges.

---

## How it works

Claude Cowork requires Hyper-V and supporting services to be active **before** Claude is installed, and a reboot is needed after enabling those features. This deployment uses two independent Intune components to handle that sequence without any dependency logic:

1. **Intune Remediation** — detects whether Hyper-V features and services are healthy. If not, the remediation script enables them and flags a reboot. Once detection confirms everything is running cleanly, it writes a flag file.
2. **Win32 App** — checks for the flag file before installing. If the flag is absent, Intune retries on the next check-in. Once the flag is present, installs Claude system-wide.

The device reboots naturally between the two steps. No dependency chains, no combined scripts.

> **Not all machines need this.** The Hyper-V remediation is only relevant for devices that will use **Claude Cowork** (the virtualisation feature). Machines without Cowork can skip the remediation entirely — Claude Desktop will install and run fine without Hyper-V. Only target the remediation at devices where Cowork is required.

---

## What's included

| File | Purpose |
|---|---|
| `install_claude.ps1` | Win32 app install script — checks prereqs flag, cleans up existing installs, provisions MSIX system-wide |
| `detect_claude.ps1` | Win32 app detection script for Intune |
| `uninstall_claude.ps1` | Removes and deprovisions Claude for all users |
| `cowork remediation/Detect-ClaudeCowork.ps1` | Remediation detection script — checks Hyper-V features and services, writes prereqs flag on pass |
| `cowork remediation/Remediate-ClaudeCowork.ps1` | Remediation fix script — enables features, starts services, writes prereqs flag |
| `Test-ClaudeDeployment.ps1` | Manual validation script — checks all deployment layers and reports pass/fail per check |
| `claude_admx/claude_admx.admx` | ADMX Group Policy template for Claude Desktop |
| `claude_admx/claude_adml.adml` | ADML language file for the ADMX template |

---

## Part 1 — Intune Remediation (Hyper-V prerequisites)

This must be deployed **before** the Win32 app. The remediation enables the required Windows features and writes the flag that unblocks the install.

### Features enabled by the remediation

- `VirtualMachinePlatform`
- `Microsoft-Hyper-V`
- `Microsoft-Hyper-V-Services`
- `Microsoft-Hyper-V-Hypervisor`

Without the full Hyper-V stack, `vmms` and `vmcompute` services do not exist and Cowork cannot run.

### Deploy the remediation in Intune

1. Go to **Intune admin centre > Devices > Remediations > Create**
2. **Basics tab** — name it `Claude Cowork Prerequisites`
3. **Settings tab**

| Field | Value |
|---|---|
| Detection script | Upload `Detect-ClaudeCowork.ps1` |
| Remediation script | Upload `Remediate-ClaudeCowork.ps1` |
| Run this script using the logged-on credentials | **No** |
| Enforce script signature check | **No** |
| Run script in 64-bit PowerShell | **Yes** |

4. **Assignments tab** — assign to your device group (pilot first)
5. **Schedule** — set to run **every 1 hour**

> **Schedule guidance:** Run hourly during initial rollout so devices get the flag written promptly after their first reboot. Once all devices are deployed (check flag presence via Intune logs or the Application event log source `ClaudeCoworkMSIX`), scale back to once daily.

### What happens on each Intune cycle

Each cycle runs the **detection script first**. If detection exits 1 (non-compliant), the **remediation script** runs immediately after.

| Cycle | State | Detection outcome | Remediation outcome |
|---|---|---|---|
| 1st run (fresh machine) | Hyper-V features not enabled | Exits 1 | Enables Hyper-V stack — **flag NOT written**, reboot required |
| After 1st reboot | Features enabled, services starting | Exits 1 (services may still be initialising) | Starts `vmms`, `vmcompute`, `HNS` if needed |
| Once all services confirmed running | Everything healthy | **Exits 0 → writes flag:** `C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\Claude\ClaudePrereqsReady.flag` | Not triggered (or writes flag if remediation ran first) |
| Subsequent cycles | Everything healthy | Exits 0, flag already present — no action | Not triggered |

> **Expect at least 2 reboots before Claude is fully ready.** The first reboot activates the Hyper-V features. The second reboot (or a session after Intune has re-run the remediation) allows the services to start cleanly and the flag to be written. Only after the flag is written will the Claude install proceed. This is expected behaviour — do not attempt to skip or force steps. See the [End user communication](#end-user-communication) section for guidance on what to tell users.
>
> **Intune is not fast.** Device check-in for Win32 apps and Remediations can take 30–60 minutes even with an hourly schedule, particularly on freshly enrolled or recently rebooted devices. The device must be online, connected, and have synced with Intune. You can trigger an immediate sync from **Settings > Accounts > Access work or school > [account] > Info > Sync** on the device, or from **Intune admin centre > Devices > [device] > Sync**.

### Checking remediation logs

All logs are written under `C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\Claude\` — the IME Logs directory. Intune's **Collect diagnostics** action captures this path automatically, so no custom diagnostics profile is required.

| Log file | Script |
|---|---|
| `ClaudeCowork-Detection.log` | Detect-ClaudeCowork.ps1 |
| `ClaudeCowork-Remediation.log` | Remediate-ClaudeCowork.ps1 |
| `ClaudeInstall.log` | install_claude.ps1 |
| `ClaudePrereqsReady.flag` | Written by detection (or remediation) once all prereqs confirmed |

You can also query the Windows Application event log for source `ClaudeCoworkMSIX` (EventID 1002 = success, 1003 = partial/failure) or `ClaudeCoworkMSIX` (EventID 2000 = success, 2001 = failed).

### Running the remediation on demand (without waiting for the next cycle)

If you need to trigger the remediation immediately on a specific device rather than waiting for the next hourly cycle, Intune supports running a remediation as a remote device action.

> This feature is currently in **preview**. See the official Microsoft documentation: [Run remediation remote device action](https://learn.microsoft.com/en-us/intune/intune-service/remote-actions/device-run-remediation)

**Steps:**

1. Sign in to the **Intune admin centre**
2. Go to **Devices > By platform > Windows** and select the target device
3. On the device Overview page, select **… (ellipsis) > Run remediation (preview)**
4. In the pane that appears, select the **Claude Cowork Prerequisites** script package
5. Optionally select **View details** to review the script before running
6. Select **Run remediation**

The device must be online and reachable via Windows Push Notification Service (WNS) for the action to be delivered immediately. If the device is offline, the action will be queued and delivered on next connection.

> **Required permission:** The Intune admin account must have the *Run remediation* permission under Remote tasks, or the built-in Intune Administrator role.

---

## Part 2 — Claude Win32 App

### Step 1 — Download the MSIX

Download the latest Claude Desktop MSIX directly from Anthropic:

**https://claude.ai/api/desktop/win32/x64/msix/latest/redirect**

Save as `Claude.msix`.

### Step 2 — Prepare the staging folder

Create a staging folder with all four files in the same directory:

```
C:\Staging\Claude\
    Claude.msix
    install_claude.ps1
    detect_claude.ps1
    uninstall_claude.ps1
```

### Step 3 — Create the .intunewin package

Download the Microsoft Win32 Content Prep Tool from:

**https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool**

Run:

```
IntuneWinAppUtil.exe -c "C:\Staging\Claude" -s install_claude.ps1 -o "C:\Output"
```

This produces `install_claude.intunewin` in your output folder. That is the file you upload to Intune.

### Step 4 — Create the Win32 app in Intune

1. Go to **Intune admin centre > Apps > All apps > Add**
2. Select **Windows app (Win32)**
3. Upload `install_claude.intunewin`

#### App information tab

Fill in name, description, and publisher as needed.

#### Program tab

| Field | Value |
|---|---|
| Install command | `powershell.exe -ExecutionPolicy Bypass -File install_claude.ps1 -PackagePath ".\Claude.msix"` |
| Uninstall command | `powershell.exe -ExecutionPolicy Bypass -File uninstall_claude.ps1` |
| Install behaviour | **System** |
| Device restart behaviour | **No specific action** |

> Install behaviour **must** be System. `Add-AppxProvisionedPackage` requires SYSTEM context and will fail if set to User.

#### Requirements tab

| Field | Value |
|---|---|
| Operating system architecture | 64-bit |
| Minimum OS | Windows 10 2004 |

#### Detection tab

Select **Use a custom detection script** and upload `detect_claude.ps1`.

| Field | Value |
|---|---|
| Run script as 32-bit process | No |
| Enforce script signature check | No |

#### Return codes tab

Add the following custom return code so Intune retries gracefully when the prereqs flag is not yet present, rather than marking the device as failed:

| Return code | Code type |
|---|---|
| `0` | Success |
| `3010` | Success with soft reboot |
| `1` | **Retry** |

> Without this, a device that attempts the install before the remediation has written the flag will be marked as **Failed** in Intune. Setting `1 = Retry` keeps it in a pending state until the next check-in.

#### Assignments tab

You can assign to either a **user group** or a **device group** — the install still runs as SYSTEM regardless of how it is targeted. User group targeting is fine and is how this was deployed in testing.

Start with a pilot group. Check install status under **Devices > Monitor > App install status** before rolling out wider.

---

## Part 3 — Policy via ADMX (recommended)

The `claude_admx/` folder contains ADMX and ADML policy templates for managing Claude Desktop settings via Intune's Administrative Templates profile or traditional Group Policy.

**Use ADMX over JSON/OMA-URI.** The ADMX templates in this repo were created by a colleague and map to the settings documented in [Enterprise configuration](https://support.claude.com/en/articles/12622667-enterprise-configuration). The ADMX approach has been observed to apply more reliably than direct registry JSON configuration in testing, and you avoid having to maintain OMA-URI paths or re-import JSON blobs as settings change. Note that Anthropic does not currently ship official ADMX templates with Claude releases — the templates here are community-produced and will need to be updated manually if Anthropic adds new policy settings.

**To use with Intune (recommended):**

The process requires importing the ADMX files into Intune first, then creating a policy that references them — it is a two-step process. Follow Microsoft's official documentation for the current steps:

> [Use Windows 10/11 templates to configure group policy settings in Microsoft Intune](https://learn.microsoft.com/en-us/mem/intune/configuration/administrative-templates-windows)

Import `claude_admx.admx` and `claude_adml.adml` from the `claude_admx/` folder. Once imported, create a configuration profile using the imported template and configure the desired policy settings.

> If the ADMX templates in this repo are updated to add new policy settings, re-import both files and update your profile accordingly. Existing configured settings are preserved.

**To use with traditional Group Policy**, copy to your Central Store:

```
\\<domain>\SYSVOL\<domain>\Policies\PolicyDefinitions\
    claude_admx.admx
    en-US\claude_adml.adml
```

> GPO/ADML templates contributed with assistance from **Zane @ the Kestral team**.

---

## End user communication

> **This approach worked well for our environment — your mileage may vary.** The message and process below reflect what we actually sent to staff during our rollout. Adapt the tone, support contact, and specific steps to suit your organisation. The key facts (two reboots, flag file location, Company Portal sync) are accurate regardless of environment.

The deployment is largely silent, but setting expectations upfront avoids a lot of "where's Claude?" tickets. Below is the message we used, genericised.

---

**Subject: Claude Desktop — rolling out to your PC over the coming days**

Claude Desktop will install automatically on your work PC. You don't need to kick anything off.

Getting Claude's virtual machine feature (Cowork) running properly requires some specific Windows components to be enabled and a couple of services running before the app can even install. The whole process needs **at least two reboots**, so it may take a day or so depending on when Intune checks in.

**What happens in the background:**
Some scripts will run to check and configure the Windows settings needed to support Cowork. Once everything checks out, your PC gets a green light and Claude installs automatically via Intune.

**How to check if your PC is ready:**
Once the scripts have run successfully, a small flag file will appear at:

`C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\Claude\ClaudePrereqsReady.flag`

> Note: `C:\ProgramData` is a hidden folder. Paste the full path directly into the File Explorer address bar to navigate there, or enable hidden items in View settings.

If that file exists, your PC is prepped and Claude is cleared to install. You can speed things along by opening **Company Portal → Settings → Sync**, which prompts Intune to check in immediately rather than waiting for the next scheduled cycle.

**Once it's installed:**
1. Open **Company Portal** and look for Claude Desktop under **Downloads & Updates** — it will auto-install, so check there rather than searching manually.
2. Once you see it listed, **restart your PC**.
3. After the reboot, open the **Start menu** — Claude will appear under "recently added". Open that entry.
4. Remove any old Claude shortcuts (desktop, taskbar, pinned Start items) — use only the newly installed version.
5. Pin the new Claude to your taskbar for easy access.

**If something doesn't look right:**
If the flag file isn't there after a day or so, or Claude isn't showing in Company Portal after a reboot, contact your IT support team — logs are available at `C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\Claude\` for troubleshooting.

---

### How users can check the flag themselves

Users can verify readiness without admin rights in two ways:

**File Explorer:** Paste this path directly into the address bar and press Enter:
```
C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\Claude\
```
If `ClaudePrereqsReady.flag` is there, the prereqs are done.

**PowerShell** (no elevation needed):
```powershell
Test-Path "C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\Claude\ClaudePrereqsReady.flag"
```
`True` = ready. `False` = not yet — another reboot and Intune cycle needed.

---

## Testing manually on the pilot machine

To run the full deployment validation in one pass (run as Administrator):

```powershell
.\Test-ClaudeDeployment.ps1
```

This checks every layer — prereqs flag, Hyper-V features, services, provisioned package, per-user registration, and Start Menu shortcuts — and prints colour-coded PASS/FAIL with remediation hints.

To test the remediation script directly (run as Administrator):

```powershell
.\cowork remediation\Remediate-ClaudeCowork.ps1
```

Check the logs (all in one place):

```powershell
Get-ChildItem "C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\Claude\"
Get-Content "C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\Claude\ClaudeCowork-Remediation.log"
```

Check whether the flag was written:

```powershell
Test-Path "C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\Claude\ClaudePrereqsReady.flag"
Get-Content "C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\Claude\ClaudePrereqsReady.flag"
```

To test the install script directly (run as Administrator, MSIX in same folder):

```powershell
.\install_claude.ps1 -PackagePath ".\Claude.msix"
```

To verify Claude is provisioned:

```powershell
# Match on either DisplayName or PackageName — the MSIX publisher prefix can cause DisplayName-only checks to miss it
Get-AppxProvisionedPackage -Online | Where-Object {
    $_.DisplayName -like "*Claude*" -or $_.DisplayName -like "*Anthropic*" -or
    $_.PackageName -like "*Claude*" -or $_.PackageName -like "*Anthropic*"
}
```

To verify policy was applied (via ADMX or registry):

```powershell
Get-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Anthropic\Claude" -ErrorAction SilentlyContinue
```
