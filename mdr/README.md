# SentinelOne deployment by Group Policy

This folder installs the SentinelOne agent on domain computers with a daily
scheduled task, pushed out by a GPO. The task runs `Install-SentinelOne.ps1`
as SYSTEM. If the agent is already installed, the script exits straight away,
so it is safe to leave the task running every day.

| File | What it is |
| --- | --- |
| `Install-SentinelOne.ps1` | Installs the agent if it is missing, and logs the result |
| `SentinelInstaller_windows_64bit_v26_2_3_158.msi` | The SentinelOne installer |
| `SentinelOne-ScheduledTask.zip` | A GPO backup containing the scheduled task, ready to import |

There are two ways to set it up. **Importing the zip (option A) is quicker.**
Building the task by hand (option B) gives the same result.

You will need:

- Your domain name (shown below as `DOMAIN.TLD`)
- The site token from the SentinelOne console (shown below as `S1_TOKEN`)

## 1. Copy the files to NETLOGON

Copy `Install-SentinelOne.ps1` and the installer MSI to:

```
\\DOMAIN.TLD\NETLOGON\S1\
```

## 2A. Import the GPO from the zip

Run this on a domain controller, or on an admin machine with the Group Policy
PowerShell module (RSAT) installed.

1. Extract `SentinelOne-ScheduledTask.zip` to `C:\backup`. That folder should
   now contain `manifest.xml` and a `{C452D176-...}` folder.

2. Import it into a **new** GPO:

   ```powershell
   Import-GPO -BackupId "C452D176-8E49-410C-9AB7-3764442F6B2D" -Path "C:\backup" -TargetName "SentinelOne - Scheduled Task" -CreateIfNeeded
   ```

   > **Do not import into an existing GPO.** `Import-GPO` replaces every
   > setting in the target GPO, including any old SentinelOne software
   > installation package.

3. In Group Policy Management, edit the new GPO and go to
   **Computer Configuration > Preferences > Control Panel Settings > Scheduled Tasks**.
   Open **Tenax S1 Deploy**, go to the **Actions** tab, edit the action, and
   in the arguments replace:
   - `DOMAIN.TLD` with your domain (for example `contoso.local`)
   - `S1_TOKEN` with your site token

   The arguments point to installer v26.2.3.158. Change the file name if you
   copied a different version.

4. Link the GPO to the OUs that should get SentinelOne.

## 2B. Build the scheduled task by hand

1. Create or edit a GPO and go to
   **Computer Configuration > Preferences > Control Panel Settings > Scheduled Tasks**.

2. Right-click the empty right-hand pane and select
   **New > Scheduled Task (At least Windows 7)**.

3. **General** tab:
   - Action: **Update**
   - Name: `Tenax S1 Deploy`
   - User account: `NT AUTHORITY\System` (click **Change User or Group** and type `SYSTEM`)
   - Select **Run whether user is logged on or not**
   - Tick **Run with highest privileges**
   - Configure for: **Windows 7, Windows Server 2008 R2**

4. **Triggers** tab, click **New**:
   - Begin the task: **On a schedule**
   - **Daily**, starting today, recur every **1** day
   - Under Advanced settings, tick **Delay task for up to (random delay)** and choose **1 minute**
   - Make sure **Enabled** is ticked

5. **Actions** tab, click **New**:
   - Action: **Start a program**
   - Program/script: `powershell.exe`
   - Add arguments (replace `DOMAIN.TLD`, `<VERSION>` and `S1_TOKEN`):

     ```
     -NoProfile -ExecutionPolicy Bypass -File "\\DOMAIN.TLD\NETLOGON\S1\Install-SentinelOne.ps1" -InstallerPath "\\DOMAIN.TLD\NETLOGON\S1\SentinelInstaller_windows_64bit_v<VERSION>.msi" -SiteToken "S1_TOKEN"
     ```

6. **Conditions** tab:
   - Untick **Start the task only if the computer is on AC power**
   - Untick **Stop if the computer switches to battery power**

7. **Settings** tab:
   - Tick **Run task as soon as possible after a scheduled start is missed**,
     so computers that are off at the scheduled time still get the install
   - Set **Stop the task if it runs longer than** to **1 hour**

8. Link the GPO to the OUs that should get SentinelOne.

## 3. Remove the old software installation deployment

If SentinelOne was previously deployed with **Software Installation**, remove
that package **after** the new task is working:

1. In the old GPO, go to
   **Computer Configuration > Policies > Software Settings > Software Installation**.
2. Right-click the package and select **All Tasks > Remove...**.
3. Choose **Allow users to continue to use the software, but prevent new installations**.
   Do not choose the immediate uninstall option.

## 4. Check that it worked

On a target computer, run `gpupdate /force`, then either wait for the task or
run **Tenax S1 Deploy** manually in Task Scheduler. The logs are in
`C:\ProgramData\Tenax\S1Install\`:

- `Install-SentinelOne.log` has one line per run, ending in `RESULT=<code>`
- `msiexec-S1.log` has the full installer log, for when an install fails

| Result code | Meaning |
| --- | --- |
| 0 | Already installed, or installed successfully |
| 3010 | Installed; reboot needed to finish |
| 1618 | Another install was running; the task will try again tomorrow |
| 10 | OS too old for this agent (Windows 7 / Server 2008 R2); install the legacy agent manually |
| 11 | 32-bit Windows and no 32-bit installer was given (`-InstallerPath32`) |
| 20 | Site token or installer path is missing from the arguments |
| 21 | Installer could not be copied or downloaded; check the NETLOGON path |
| 30 | Installer ran but the SentinelAgent service did not appear; check `msiexec-S1.log` |
