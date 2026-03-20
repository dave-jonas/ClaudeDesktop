# Claude Desktop — Intune Deployment

This repo covers deploying Claude Desktop system-wide via Microsoft Intune, including the Hyper-V prerequisites required for Claude Cowork to function.It allows claude features to run without requiring admin access. Honestly, you can tell Anthropic dont live in a world with enterprise and security best practices. 

> **Work in progress — tested on Windows 11 Pro managed devices. Always check Anthropic's official documentation as the authoritative reference.**
>
> - [Deploy Claude Desktop for Windows](https://support.claude.com/en/articles/12622703-deploy-claude-desktop-for-windows)
> - [Enterprise configuration](https://support.claude.com/en/articles/12622667-enterprise-configuration)

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

Assign to a **device group**, not a user group. The MSIX is provisioned system-wide so device-based targeting is required.

Start with your pilot group. Check install status under **Devices > Monitor > App install status** before rolling out wider.

---

## Part 3 — Policy via ADMX (recommended)

The `claude_admx/` folder contains ADMX and ADML policy templates for managing Claude Desktop settings via Intune's Administrative Templates profile or traditional Group Policy.

**Use ADMX over JSON/OMA-URI.** Anthropic ships updated ADMX templates with each Claude release and the settings map directly to the [Enterprise configuration](https://support.claude.com/en/articles/12622667-enterprise-configuration) documentation. Intune's Imported Administrative Templates approach picks up new settings automatically as Claude updates — you don't need to maintain OMA-URI paths or re-import JSON blobs when Anthropic adds settings. The ADMX approach has also been observed to apply more reliably than direct registry JSON configuration in testing.

**To use with Intune (recommended):**

1. Go to **Devices > Configuration profiles > Create > New policy**
2. Platform: **Windows 10 and later**, Profile type: **Templates > Imported Administrative templates**
3. Import `claude_admx.admx` and `claude_adml.adml`
4. Configure the desired policy settings and assign to a device group

> When Anthropic releases a new Claude version with new policy settings, re-import the updated ADMX/ADML files into the same profile. Existing configured settings are preserved.

**To use with traditional Group Policy**, copy to your Central Store:

```
\\<domain>\SYSVOL\<domain>\Policies\PolicyDefinitions\
    claude_admx.admx
    en-US\claude_adml.adml
```

> GPO/ADML templates contributed with assistance from **Zane @ the Kestral team**.

---

## End user communication

When rolling out to users, set expectations upfront. A suggested message:

---

> **Claude Desktop is being deployed to your device.**
>
> To complete the setup, your device needs to be restarted **at least twice** over the coming hours. Claude will not appear or work correctly until both restarts have completed and the background configuration has finished.
>
> You don't need to do anything other than restart when prompted or at a convenient time. If you see a notification saying **"Claude Desktop is almost ready"**, that means the first phase is done — please restart when you can.
>
> Once Claude appears in your Start Menu, Cowork should work without needing administrator access.

---

### How users can verify the prereqs are ready

The deployment writes a flag file once the system is prepared. Users can check it themselves — no admin rights needed.

The file is in `C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\Claude\` — note that `C:\ProgramData` is a **hidden folder** in Windows Explorer. To navigate there directly:

1. Open **File Explorer**
2. Click in the address bar and type: `C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\Claude\`
3. Press Enter

If `ClaudePrereqsReady.flag` exists in that folder, the prereqs are done and Claude should install on the next Intune sync. If it isn't there yet, the device needs another reboot or more time for the hourly remediation to run.

Alternatively, users can run this in PowerShell (no elevation needed):

```powershell
Test-Path "C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\Claude\ClaudePrereqsReady.flag"
```

`True` = ready. `False` = not yet — restart and wait for the next Intune cycle.

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
