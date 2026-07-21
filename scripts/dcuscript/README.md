# Dell Command | Update — Enterprise Deployment Guide

Two PowerShell 5.1 scripts for automated deployment of Dell BIOS updates.
Both scripts are strict-mode, admin-required, idempotent, log to
`$env:SystemDrive\Temp\BIOS-Update\` (NOT a folder containing "DCU" — DCU's
CLI rejects any `-outputlog` path containing that substring, returning exit
107 "reserved folder"), and exit with RMM-consumable codes. No .NET idioms.

```
Install-DCU.ps1     # stages .NET 8.0 Desktop Runtime + DCU 5.7.0 (Universal)
dell-update.ps1     # suspends BitLocker, runs dcu-cli.exe for BIOS/firmware/drivers, reboots
```

## Files to ship alongside the scripts

Put these in the same folder as `Install-DCU.ps1`. The scripts find them by
wildcard and will not download anything if `-NoDownload` is set.

| File                                                              | Source                                                                 |
|-------------------------------------------------------------------|------------------------------------------------------------------------|
| `windowsdesktop-runtime-8.0.25-win-x64.exe`                        | https://builds.dotnet.microsoft.com/dotnet/WindowsDesktop/8.0.25/windowsdesktop-runtime-8.0.25-win-x64.exe (SHA-512 see below) |
| `Dell-Command-Update-Windows-Universal-Application_*_5.7.0_A00.EXE`| https://dl.dell.com/FOLDER14424601M/1/Dell-Command-Update-Windows-Universal-Application_FGK9X_WIN64_5.7.0_A00.EXE (SHA-256 see below)  |

### DCU 5.7.0 — verified file

```
Dell-Command-Update-Windows-Universal-Application_FGK9X_WIN64_5.7.0_A00.EXE
SHA-256: 98c20d9809d7469a760b42a9a258e8c67a35c6cf46aa6a9c173e29d39a056d89
URL:     https://dl.dell.com/FOLDER14424601M/1/Dell-Command-Update-Windows-Universal-Application_FGK9X_WIN64_5.7.0_A00.EXE
```

`Install-DCU.ps1` enforces this hash by default and hard-fails on mismatch.

### .NET Desktop Runtime — verified file

The .NET 8.0.25 Desktop Runtime installer now in this folder is:

```
windowsdesktop-runtime-8.0.25-win-x64.exe
SHA-512: 044628141cb05423b7e3a819d3baf13cab75382174a1e528c9c00f9e93919fd2684d68b5d70293f69560316c3909c49be279290da22541ed130a91924842e8ad
URL:     https://builds.dotnet.microsoft.com/dotnet/WindowsDesktop/8.0.25/windowsdesktop-runtime-8.0.25-win-x64.exe
```

`Install-DCU.ps1` enforces this hash by default and hard-fails on mismatch.
Bypass with `-SkipHashCheck` **only** during development.

**Only the Desktop Runtime is supported.** DCU 5.7.0 depends on WPF/WinForms
assemblies that ship only with `windowsdesktop-runtime-*.exe`. The script
hard-fails if the Desktop Runtime is not registered after install — it will
never silently fall back to the base runtime (`dotnet-runtime-*.exe`).

## RMM workflow

1. Push the script folder (the two `.ps1` files + the two installers) to the
   target machines via your RMM's file distribution.
2. Run as **SYSTEM / Administrator** (elevated). Both scripts check and exit
   with code 1 if not elevated.
3. Typical two-step schedule:

   ```
   Step 1 (anytime):   powershell.exe -ExecutionPolicy Bypass -File .\Install-DCU.ps1 -NoDownload
   Step 2 (after Step 1 returned 0 or 3010, and after any required reboot):
                       powershell.exe -ExecutionPolicy Bypass -File .\dell-update.ps1
   ```

   Between Step 1 and Step 2, if Step 1 returned **3010**, schedule a reboot
   first. If it returned **0**, no reboot is needed and you can run Step 2
   immediately.

4. For Step 2, prefer `-NoRestart` if your RMM has its own reboot-with-
   notification workflow; otherwise let the script reboot directly. With
   `-NoRestart`, Step 2 exits **3010** when the BIOS was staged and a reboot
   is required, and your RMM owns the actual restart.

## Exit codes

### `Install-DCU.ps1`

| Code | Meaning                                              | RMM action                          |
|------|------------------------------------------------------|-------------------------------------|
| 0    | Success; nothing else required (or already-installed) | proceed to dell-update              |
| 1    | Hard failure — see log                               | do not proceed; ticket the host     |
| 3010 | Success; reboot required to complete install        | reboot, then proceed to dell-update |

### `dell-update.ps1`

| Code | Meaning                                                            | RMM action                                       |
|------|--------------------------------------------------------------------|--------------------------------------------------|
| 0    | Updates already up to date, or applied with no reboot needed      | done                                             |
| 1    | Hard failure — BitLocker was resumed, no reboot attempted         | ticket the host; do **not** reboot on this code  |
| 2    | `dcu-cli.exe` not found — run `Install-DCU.ps1` first              | run Install-DCU, then retry                      |
| 3010 | Updates staged, reboot required, and `-NoRestart` was set        | reboot the host via your RMM's reboot workflow   |

Note: when `dcu-cli.exe` itself returns code 7 (BIOS password validation
error), `dell-update.ps1` maps it to script exit code 1 with a clear log
message indicating whether no password was supplied (use `-BiosPassword` etc.)
or the supplied password was wrong.

If you did **not** pass `-NoRestart` and the update run succeeded with a
reboot required (dcu-cli exited 1), the script reboots the machine itself and
does not return 3010.

## Verified facts used to write these scripts

1. **DCU CLI argument is `/applyUpdates`, not `/apply`.** The `-silent` flag
   the plan used does not exist for `dcu-cli.exe`; CLI invocations are silent
   by design. The correct logging flag is `-outputlog=<path>`.

2. **DCU 5.7.0 Universal installs to `C:\Program Files\Dell\CommandUpdate\`**,
   not `C:\Program Files\WindowsApps\DellInc.DellCommandUpdate_*\` as the plan
   guessed. The classic (non-Universal) variant goes to
   `C:\Program Files (x86)\Dell\CommandUpdate\`. We detect which via the
   registry `AppCode` value under
   `HKLM:\SOFTWARE\DELL\UpdateService\Clients\CommandUpdate\Preferences\Settings`.

3. **DCU CLI exit codes** (Dell-documented). The plan treated `2` as
   "reboot required" — that is wrong. `2` means "unknown application error".
   Correct mapping:
   - `0` = Success, no reboot required
   - `1` = Success, **reboot required**  ← this is the reboot signal
   - `2` = Unknown application error (failure)
   - `4` = Not launched with admin privilege
   - `5` = Reboot already pending from a prior operation
   - `6` = Another DCU instance (UI or CLI) is already running
   - `500` = No updates found (treat as success, no reboot)
   - `1002` = Network error during apply

4. **DCU installer silent switches** — verified as `/s /l=<path-to-log-file>`.
   The plan had this right but used `$LogDir\Dell_DCU_5.7_Install.log` for the
   log path; `/l=` writes a file at the path you give it, so it must be a full
   file path, not a directory.

5. **DUP installer switches** (Dell BIOS update package, for applying BIOS
   updates directly rather than through dcu-cli): `/s /l=<log>
   [/p=<password>]`. Not used in our scripts (we go through `dcu-cli.exe`),
   but kept here for reference if you ever choose to bypass DCU.

Source of corrections: Dell's `dcu-cli.exe /help` output and Dell's
documented dcu-cli exit-code reference, cross-checked with the behavior
observed during production testing.

## BitLocker handling

`dell-update.ps1` enumerates **all** BitLocker-protected volumes (not only
`C:`) and suspends each with `-RebootCount 1`, so protection auto-resumes on
the next boot. If anything fails before the reboot, the script resumes
BitLocker before exiting so the machine is not left suspended. If DCU staged
the update successfully (exit 1) and the script is about to reboot, BitLocker
is intentionally **left** suspended because the reboot is what triggers the
auto-resume.

## Idempotency

`Install-DCU.ps1` is safe to re-run on hosts where the components are already
installed: it checks registry versions and skips the install step if the
required version is present. `dell-update.ps1` invokes
`dcu-cli.exe /applyUpdates -updateType=bios,firmware,driver
-updateSeverity=critical,security` by default — DCU itself is idempotent and
will exit 500 ("no updates found") when everything is already at the latest
available version, which the script maps to exit 0.

To narrow scope, pass `-UpdateType` and/or `-UpdateSeverity` explicitly (both
are array-typed; the script joins them with commas for dcu-cli). Examples:

```
dell-update.ps1 -UpdateType bios                          # BIOS only
dell-update.ps1 -UpdateType bios,firmware -UpdateSeverity critical
dell-update.ps1 -UpdateType bios,firmware,driver,application
```

## Logging

Every line the scripts write goes both to stdout (color-coded for an
operator) and to the log file:

- `Install-DCU.ps1` → `$env:SystemDrive\Temp\BIOS-Update\Install-DCU.log`
- `dell-update.ps1` → `$env:SystemDrive\Temp\BIOS-Update\dell-update.log`
- Component installers write their own logs alongside:
  - `$env:SystemDrive\Temp\BIOS-Update\DotNet_8_Desktop_Install.log`
  - `$env:SystemDrive\Temp\BIOS-Update\Dell_DCU_5.7.0_Install.log`
  - `$env:SystemDrive\Temp\BIOS-Update\DCU-CLI-<timestamp>-ApplyUpdates.log`
  - `$env:SystemDrive\Temp\BIOS-Update\DCU-CLI-<timestamp>-Configure.log` (only when a BIOS password is supplied)

## Known limitations / things to watch in production

- **DCU 5.7.0 catalog may offer an older DCU version than what is installed.**
  This is observed in the field. Our script matches on `5.7.0` (StartsWith) so a
  host with `5.7.0.123` installed will be treated as up to date.

- **Dell Client Management Service (DCMS)** must be running for dcu-cli.exe to
  work. If it is stopped or disabled, dcu-cli exits 3000–3005. The script
  surfaces these as exit 1 with a log message; check
  `DCU-CLI-*-ApplyUpdates.log` for the specific code. You may want a pre-flight
  `Get-Service -Name 'DellClientManagementService' | Start-Service` step in your
  RMM workflow if you hit this on a fleet.

- **BIOS password** (now handled). If the host has a BIOS admin password
  set, `dell-update.ps1` will fail with DCU CLI exit code 7 unless you
  supply the password via one of three parameters:

  | Parameter set | Security | Notes |
  |---|---|---|
  | `-BiosPassword "<pwd>"` | Lowest — visible in process command line | Easiest; use only if your RMM injects at the last moment |
  | `-EncryptionKey "<key>" -EncryptedPassword "<enc>"` | High — neither value reveals the BIOS password if leaked | Generate once with `dcu-cli.exe /generateencryptedpassword` (see below) |
  | `-EncryptionKey "<key>" -EncryptedPasswordFile "<path>"` | High — secret dropped as a file by the RMM | Useful if your RMM can drop secret files but can't inject strings |

  **Two-step invocation.** DCU's CLI does NOT accept `-biosPassword` (or
  `-encryptedpassword`) on `/applyUpdates` — it returns exit code 106
  ("invalid options detected"). The script therefore uses Dell's
  documented two-step pattern when any password material is supplied:

  ```
  Step 1:  dcu-cli.exe /configure -biosPassword="<pw>" -outputlog="<log>"
           (DCU stores the password internally; exit 0 = success)
  Step 2:  dcu-cli.exe /applyUpdates -updateType=bios,firmware,driver -updateSeverity=critical,security -outputlog="<log>"
           (DCU reads the password from internal state)
  ```

  The encrypted forms work the same way — `-encryptionkey` + `-encryptedpassword`
  are passed to `/configure`, not `/applyUpdates`.

  Generate the encrypted pair once on any Dell host with DCU installed:

  ```
  dcu-cli.exe /generateencryptedpassword -encryptionkey="<your-key>" -password="<bios-password>" -outputpath="C:\Temp"
  ```

  DCU writes two files to `C:\Temp`: `<random>.json` (encrypted password)
  and `<random>.bin` (the encryption key). Store both in your RMM's
  credential vault and inject them at runtime. **Never hardcode the
  password or key in the `.ps1` file or in any committed config.**

  All password material is masked in the script log; only the *mode*
  (plaintext / encrypted-string / encrypted-file) is recorded. The
  `/configure` call writes its own log alongside the `/applyUpdates` log:
  `DCU-CLI-<timestamp>-Configure.log` and `DCU-CLI-<timestamp>-ApplyUpdates.log`.

- **Download URLs change frequently.** The fallback URLs in `Install-DCU.ps1`
  point to the verified .NET 8.0.25 Desktop Runtime and DCU 5.7.0 A00 artifacts.
  Ship the installers with the script and use `-NoDownload` in production so
  you never depend on those URLs. Dell's CDN (`dl.dell.com`) rejects the
  default PowerShell User-Agent with HTTP 403; the script's download path sets
  a browser User-Agent to work around this. The `FOLDER<id>` segment in the
  Dell URL is release-specific and will need to be replaced when you upgrade
  to a future DCU version.

- **Update scope defaults to BIOS + firmware + driver, severity critical + security.**
  Override at the command line with the array-typed `-UpdateType` and
  `-UpdateSeverity` parameters. Validate sets:
  - `-UpdateType`: `bios`, `firmware`, `driver`, `application`, `others`
  - `-UpdateSeverity`: `security`, `critical`, `recommended`, `optional`
  Passing a single value works (`-UpdateType bios`); the script accepts
  PowerShell's natural comma-separated syntax for arrays.

## Sanity check before mass deployment

1. Run on one Dell test host with verbose logging:
   ```
   powershell.exe -ExecutionPolicy Bypass -File .\Install-DCU.ps1 -NoDownload -Verbose
   ```
   Verify `.NET Desktop Runtime 8.0.x` appears in
   `HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\` and DCU 5.7.0
   shows `AppCode = Universal` in the Dell registry key above.
2. Reboot if exit was 3010.
3. Run:
   ```
   powershell.exe -ExecutionPolicy Bypass -File .\dell-update.ps1 -NoRestart -Verbose
   ```
   Inspect `DCU-CLI-*-ApplyUpdates.log` (and `DCU-CLI-*-Configure.log` if a
   BIOS password was supplied). Verify the exit code matches the
   documented meaning in the table above before letting the script reboot
   hosts unattended.
4. Once verified, push via the RMM at fleet scale.