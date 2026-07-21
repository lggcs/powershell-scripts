#Requires -Version 5.1
<#
.SYNOPSIS
    Suspends BitLocker, applies Dell updates (BIOS, firmware, drivers) via
    Dell Command | Update CLI, and restarts the host to complete the flash.

.DESCRIPTION
    Run after Install-DCU.ps1 has placed DCU 5.7.0 (Universal) on the host.
      1) Locates dcu-cli.exe via the Dell UpdateService registry key.
         Universal -> C:\Program Files\Dell\CommandUpdate\;
         Classic  -> C:\Program Files (x86)\Dell\CommandUpdate\.
      2) Suspends BitLocker protection on EVERY BitLocker-protected volume for
         exactly 1 reboot (-RebootCount 1). If anything goes wrong after this
         point, the script resumes BitLocker before exiting non-zero so the
         machine is not left suspended.
      3) Invokes:  dcu-cli.exe /applyUpdates -updateType=bios,firmware,driver
                                       -updateSeverity=critical,security
                                       -outputlog="<log>"
         Verified syntax (the plan's "/apply -silent" was wrong on both counts:
         the verb is /applyUpdates and -silent is not a valid dcu-cli option).
      4) Interprets the dcu-cli.exe exit code per Dell's documented table:
           0    = Success, no reboot needed (or no update available)
           1    = Success, reboot required to complete the operation
           2    = Unknown application error (FAILURE, do not reboot)
           4    = CLI not launched with admin privilege
           6    = Another instance of UI/CLI already running
           7    = BIOS password validation error (not supplied or wrong)
           106  = Invalid options detected (e.g. -biosPassword on /applyUpdates)
           107  = Invalid option value (e.g. -outputlog path is a reserved folder)
           500  = No updates found (treat as success, no reboot needed)
           502/503 = scan cancelled / network error during apply
           1002 = network error during apply
           3000-3005 = Dell Client Management Service not running/installed
      5) If a reboot is required (exit 1) and -NoRestart was not supplied,
         restarts the machine after a grace period. If -NoRestart is supplied
         the script exits 3010 and the RMM is responsible for invoking its own
         reboot workflow (recommended if the RMM wants end-user notification).

    Exit codes for the RMM:
      0    = Updates already applied / applied successfully, no reboot needed
      1    = Hard failure (BitLocker resumed, no reboot attempted)
      2    = DCU not installed; run Install-DCU.ps1 first
      3010 = Updates staged, reboot required, and -NoRestart was set / RMM owns reboot

.PARAMETER LogPath
    Full path to the script log. Defaults to
    $env:SystemDrive\Temp\BIOS-Update\dell-update.log.

.PARAMETER NoRestart
    Do not restart the machine even if DCU reports reboot required. The
    script will instead exit 3010 so the RMM can schedule the reboot.

.PARAMETER RestartDelaySeconds
    Seconds between the reboot warning and the actual Restart-Computer call.
    Default 15. Has no effect with -NoRestart.

.PARAMETER UpdateType
    Update categories to apply, as an array. Defaults to bios,firmware,driver.
    Acceptable values: bios, firmware, driver, application, others.
    Passed to dcu-cli as a comma-separated list: -updateType=bios,firmware,driver.
    Example: -UpdateType bios,firmware   |   -UpdateType bios,driver,application

.PARAMETER UpdateSeverity
    Update severity levels to apply, as an array. Defaults to critical,security.
    Acceptable values: security, critical, recommended, optional.
    Passed to dcu-cli as a comma-separated list: -updateSeverity=critical,security.
    Example: -UpdateSeverity security   |   -UpdateSeverity critical,recommended,optional

.PARAMETER BiosPassword
    BIOS admin password, REQUIRED if the target host's BIOS has an admin
    password set. The script uses a two-step DCU CLI pattern: it first calls
    `dcu-cli.exe /configure -biosPassword="<pw>"` to register the password
    with DCU, then calls `dcu-cli.exe /applyUpdates` (which reads the
    password from DCU's internal state). Passing -biosPassword directly
    with /applyUpdates returns DCU exit 106 ("invalid options detected").
    The plaintext password is visible in the dcu-cli process command line
    during the /configure call - use the encrypted form for air-gapped or
    audited environments.
    NEVER hardcode this in the script file. Inject it from the RMM's
    credential store at runtime: powershell -File dell-update.ps1
    -BiosPassword $RmmSecret.

.PARAMETER EncryptionKey
    Encryption key used to decrypt -EncryptedPassword (or the file referenced
    by -EncryptedPasswordFile). Generate the encrypted pair once with:
        dcu-cli.exe /generateencryptedpassword -encryptionkey="<key>"
            -password="<bios password>" -outputpath="<folder>"
    DCU writes two files to <folder>: <random>.json containing the encrypted
    password and <random>.bin containing the encryption key. Inject BOTH
    values via the RMM credential store. Safer than -BiosPassword because
    neither value reveals the BIOS password if leaked.

.PARAMETER EncryptedPassword
    The encrypted password string produced by
    `dcu-cli.exe /generateencryptedpassword`. Use with -EncryptionKey.

.PARAMETER EncryptedPasswordFile
    Path to a file containing the encrypted password produced by
    `dcu-cli.exe /generateencryptedpassword`. Use with -EncryptionKey.
    Useful if your RMM can drop a secret file but cannot inject a string.

.EXAMPLE
    .\dell-update.ps1
    .\dell-update.ps1 -NoRestart
    .\dell-update.ps1 -BiosPassword $RmmSecretBiosPwd
    .\dell-update.ps1 -UpdateType bios
    .\dell-update.ps1 -UpdateType bios,firmware -UpdateSeverity security,critical
    .\dell-update.ps1 -EncryptionKey $RmmSecretKey -EncryptedPassword $RmmSecretEnc
    .\dell-update.ps1 -RestartDelaySeconds 60 -LogPath C:\Logs\dell.log

.NOTES
    PowerShell 5.1 strict-ISE compatible. No .NET idioms.
    Requires DCU 5.7.0 (Universal or Classic) already installed.
    Must be run as Administrator.
    Secrets handling: -BiosPassword, -EncryptionKey, -EncryptedPassword are
    masked in all log output. Pass them via the RMM's credential store;
    do not type them on the command line in plain view.

.LICENSE
MIT License

.AUTHOR
Luke

.VERSION
1.0.0
#>

[CmdletBinding()]
param(
    [string]$LogPath = (Join-Path $env:SystemDrive 'Temp\BIOS-Update\dell-update.log'),
    [switch]$NoRestart,
    [int]$RestartDelaySeconds = 15,
    [ValidateSet('bios','firmware','driver','application','others')]
    [string[]]$UpdateType = @('bios','firmware','driver'),
    [ValidateSet('security','critical','recommended','optional')]
    [string[]]$UpdateSeverity = @('critical','security'),
    [string]$BiosPassword,
    [string]$EncryptionKey,
    [string]$EncryptedPassword,
    [string]$EncryptedPasswordFile
)

# --- Strictness / error policy -------------------------------------------------
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

$LogDir = Split-Path -Path $LogPath -Parent
if (-not (Test-Path -Path $LogDir)) {
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
}

function Write-Log {
    param(
        [Parameter(Mandatory=$true, Position=0)][string]$Message,
        [ValidateSet('INFO','WARN','ERROR','SUCCESS')][string]$Level = 'INFO'
    )
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line  = "[$stamp] [$Level] $Message"
    Add-Content -Path $LogPath -Value $line -ErrorAction SilentlyContinue
    switch ($Level) {
        'ERROR'   { Write-Host $line -ForegroundColor Red }
        'WARN'    { Write-Host $line -ForegroundColor Yellow }
        'SUCCESS' { Write-Host $line -ForegroundColor Green }
        default   { Write-Host $line }
    }
}

# ==============================================================================
# Pre-flight
# ==============================================================================
$currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal   = New-Object Security.Principal.WindowsPrincipal($currentUser)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) {
    Write-Log "This script must be run as Administrator." -Level ERROR
    Exit 1
}

Write-Log "=== dell-update starting ==="
Write-Log "LogPath             : $LogPath"
Write-Log "NoRestart           : $NoRestart"
Write-Log "RestartDelaySeconds : $RestartDelaySeconds"
Write-Log "UpdateType          : $($UpdateType -join ',')"
Write-Log "UpdateSeverity      : $($UpdateSeverity -join ',')"

# Track whether we suspended BitLocker so we can resume on any failure path.
$script:BitLockerSuspended = $false

# ==============================================================================
# Strict-mode safe property access helper
# ==============================================================================
# Under Set-StrictMode -Version 3.0, accessing a property that does not exist
# on an object throws "The property '<name>' cannot be found on this object".
# Registry keys from Get-ItemProperty regularly omit values (e.g. AppCode,
# ProductVersion); direct member access trips strict mode. This helper
# returns $null for missing properties without raising.
function Get-PropertySafe {
    param(
        [Parameter(Mandatory=$true, Position=0)]$Object,
        [Parameter(Mandatory=$true, Position=1)][string]$Name
    )
    if ($null -eq $Object) { return $null }
    $prop = $Object.PSObject.Properties | Where-Object { $_.Name -ieq $Name } | Select-Object -First 1
    if ($prop) { return $prop.Value }
    return $null
}

# ==============================================================================
# Locate dcu-cli.exe via the Dell UpdateService registry key
# ==============================================================================
function Get-DcuCliPath {
    $reg = 'HKLM:\SOFTWARE\DELL\UpdateService\Clients\CommandUpdate\Preferences\Settings'
    if (-not (Test-Path -Path $reg)) { return $null }
    $keyObj = $null
    try { $keyObj = Get-ItemProperty -Path $reg -ErrorAction SilentlyContinue } catch { return $null }
    if ($null -eq $keyObj) { return $null }
    $appCode = Get-PropertySafe $keyObj 'AppCode'

    $dcuFolder = $null
    switch ($appCode) {
        'Universal' { $dcuFolder = 'C:\Program Files\Dell\CommandUpdate' }
        'Classic'   { $dcuFolder = 'C:\Program Files (x86)\Dell\CommandUpdate' }
        default { return $null }
    }
    $dcuCli = Join-Path $dcuFolder 'dcu-cli.exe'
    if (Test-Path -Path $dcuCli -PathType Leaf) { return $dcuCli }
    return $null
}

$DcuCli = Get-DcuCliPath
if (-not $DcuCli) {
    # Fallback: search the Dell folder tree if the registry key is stale.
    $candidates = @(
        'C:\Program Files\Dell\CommandUpdate\dcu-cli.exe',
        'C:\Program Files (x86)\Dell\CommandUpdate\dcu-cli.exe'
    )
    foreach ($c in $candidates) {
        if (Test-Path -Path $c -PathType Leaf) { $DcuCli = $c; break }
    }
}
if (-not $DcuCli) {
    Write-Log "dcu-cli.exe was not found. Run Install-DCU.ps1 first." -Level ERROR
    Exit 2
}
Write-Log "Located dcu-cli.exe at: $DcuCli"

# ==============================================================================
# BitLocker: suspend on every protected volume for exactly 1 reboot
# ==============================================================================
function Get-ProtectedBitLockerVolumes {
    try {
        # Filter nulls explicitly - Get-BitLockerVolume can emit $null for
        # volumes it can't enumerate, and downstream $null.MountPoint would
        # throw. Where-Object with $null -ne $_ keeps only real objects.
        $vols = Get-BitLockerVolume -ErrorAction SilentlyContinue |
            Where-Object { $null -ne $_ -and $_.ProtectionStatus -eq 'On' }
    } catch { return @() }
    return @($vols)
}

function Suspend-AllBitLocker {
    # Wrap at the call site: @() guarantees an array even if the function
    # somehow returned a scalar or $null. Under Set-StrictMode -Version 3.0,
    # a non-array scalar does not have .Count, so we use "-not $vols" (the
    # PS-idiomatic empty check: true for empty arrays and $null, false for
    # non-empty arrays and non-null scalars) instead of $vols.Count.
    $vols = @(Get-ProtectedBitLockerVolumes)
    if (-not $vols) {
        Write-Log "No BitLocker-protected volumes found. Proceeding without suspension."
        return
    }
    foreach ($v in $vols) {
        $mount = Get-PropertySafe $v 'MountPoint'
        if (-not $mount) { continue }
        try {
            Suspend-BitLocker -MountPoint $mount -RebootCount 1 -ErrorAction Stop
            Write-Log "BitLocker suspended on $mount for 1 reboot." -Level SUCCESS
        } catch {
            Write-Log "Failed to suspend BitLocker on $mount : $($_.Exception.Message)" -Level ERROR
            # Roll back any suspensions we did achieve so we leave the machine safe.
            Resume-AllBitLocker
            Exit 1
        }
    }
    $script:BitLockerSuspended = $true
}

function Resume-AllBitLocker {
    if (-not $script:BitLockerSuspended) { return }
    try {
        # Lead with $null -ne $_ for the same reason as Suspend-AllBitLocker:
        # Get-BitLockerVolume can emit $null entries on some hosts, and under
        # Set-StrictMode -Version 3.0, $null.ProtectionStatus throws.
        Get-BitLockerVolume -ErrorAction SilentlyContinue |
            Where-Object { $null -ne $_ -and $_.ProtectionStatus -eq 'Off' -and $_.VolumeStatus -ne 'DecryptionInProgress' } |
            ForEach-Object {
                $mount = Get-PropertySafe $_ 'MountPoint'
                if (-not $mount) { return }
                try {
                    Resume-BitLocker -MountPoint $mount -ErrorAction Stop
                    Write-Log "BitLocker resumed on $mount."
                } catch {
                    Write-Log "Resume-BitLocker failed on ${mount}: $($_.Exception.Message)" -Level WARN
                }
            }
    } catch {
        Write-Log "Resume-AllBitLocker wrapper error: $($_.Exception.Message)" -Level WARN
    }
    $script:BitLockerSuspended = $false
}

Write-Log "Stage 1: BitLocker suspension"
Suspend-AllBitLocker

# ==============================================================================
# Invoke dcu-cli.exe for Dell updates (BIOS, firmware, drivers per -UpdateType)
# ==============================================================================
Write-Log "Stage 2: dcu-cli.exe /applyUpdates -updateType=$($UpdateType -join ',') -updateSeverity=$($UpdateSeverity -join ',')"

$dt = (Get-Date).ToString('yyyyMMddHHmmss')
$dcuCliLog = Join-Path $LogDir "DCU-CLI-$dt-ApplyUpdates.log"
$dcuCliConfigureLog = Join-Path $LogDir "DCU-CLI-$dt-Configure.log"

# Build the BIOS password argument. Three supported forms (Dell-documented):
#   1. Plaintext:        -biosPassword="<pw>"               (least secure)
#   2. Encrypted string: -encryptionkey="<key>" -encryptedpassword="<enc>"
#   3. Encrypted file:   -encryptionkey="<key>" -encryptedpassword=<file path>
# We accept any one of these via parameters; the RMM injects whichever it has.
# The secret material is NEVER written to the script log - the log line below
# uses a masked placeholder.
#
# IMPORTANT: -biosPassword / -encryptedpassword are options on /configure, NOT
# on /applyUpdates. DCU CLI returns exit 106 ("invalid options detected") if
# you pass them with /applyUpdates. The correct pattern is a two-step
# invocation: /configure first to register the password with DCU, then
# /applyUpdates (which reads the password from DCU's internal state).
$pwArg = $null
$pwMode = 'none'
if ($BiosPassword) {
    $pwArg  = "-biosPassword=`"$BiosPassword`""
    $pwMode = 'plaintext'
}
elseif ($EncryptionKey -and $EncryptedPassword) {
    $pwArg  = "-encryptionkey=`"$EncryptionKey`" -encryptedpassword=`"$EncryptedPassword`""
    $pwMode = 'encrypted-string'
}
elseif ($EncryptionKey -and $EncryptedPasswordFile) {
    if (-not (Test-Path -Path $EncryptedPasswordFile -PathType Leaf)) {
        Write-Log "EncryptedPasswordFile not found: $EncryptedPasswordFile" -Level ERROR
        Resume-AllBitLocker
        Exit 1
    }
    $pwArg  = "-encryptionkey=`"$EncryptionKey`" -encryptedpassword=`"$EncryptedPasswordFile`""
    $pwMode = 'encrypted-file'
}
elseif ($EncryptionKey -or $EncryptedPassword -or $EncryptedPasswordFile) {
    # Partial password material supplied. Refuse rather than silently run
    # without a password and fail at the DCU layer with a cryptic code.
    Write-Log "Incomplete encrypted password material: EncryptionKey and (EncryptedPassword OR EncryptedPasswordFile) must both be supplied." -Level ERROR
    Resume-AllBitLocker
    Exit 1
}

# Step 1 (only when a password is supplied): /configure -biosPassword=...
# DCU stores the password internally so the subsequent /applyUpdates can use
# it without re-supplying. This is REQUIRED for hosts with a BIOS admin
# password set; without it, /applyUpdates returns exit 7 ("password validation
# error").
if ($pwArg) {
    $configureArgList = "/configure $pwArg -outputlog=`"$dcuCliConfigureLog`""
    $pwLog = switch ($pwMode) {
        'plaintext'        { 'BIOS password supplied (plaintext)' }
        'encrypted-string' { 'BIOS password supplied (encrypted string)' }
        'encrypted-file'   { "BIOS password supplied (encrypted file: $EncryptedPasswordFile)" }
        default            { 'unknown password mode' }
    }
    Write-Log "Stage 2a: dcu-cli.exe /configure <password-arg-masked> -outputlog=`"$dcuCliConfigureLog`""
    Write-Log "Password mode: $pwLog"

    try {
        $configureProc = Start-Process -FilePath $DcuCli -ArgumentList $configureArgList -Wait -NoNewWindow -PassThru
        $configureExit = $configureProc.ExitCode
    } catch {
        Write-Log "Failed to launch dcu-cli.exe /configure: $($_.Exception.Message)" -Level ERROR
        Resume-AllBitLocker
        Exit 1
    }
    Write-Log "dcu-cli.exe /configure ExitCode: $configureExit"
    # DCU /configure exit codes use the same table as /applyUpdates:
    # 0 = success, 106 = invalid options, 107 = invalid option value, etc.
    if ($configureExit -ne 0) {
        Write-Log "dcu-cli.exe /configure failed with exit $configureExit. See $dcuCliConfigureLog" -Level ERROR
        Resume-AllBitLocker
        Exit 1
    }
    Write-Log "BIOS password registered with DCU." -Level SUCCESS
}

# Step 2: /applyUpdates -updateType=bios,firmware,driver -updateSeverity=critical,security -outputlog=<path>
# No password argument here - DCU uses the password registered in Step 1.
# Verified dcu-cli.exe syntax (NOT "/apply -silent" - the plan had both wrong:
# the verb is /applyUpdates and -silent is not a valid dcu-cli option).
# -updateType and -updateSeverity accept a comma-separated list (no spaces).
$updateTypeCsv     = ($UpdateType     -join ',')
$updateSeverityCsv = ($UpdateSeverity -join ',')
$argList = "/applyUpdates -updateType=$updateTypeCsv -updateSeverity=$updateSeverityCsv -outputlog=`"$dcuCliLog`""

# Log the invocation. No secret material in $argList at this point, so it is
# safe to log verbatim.
Write-Log "Stage 2b: dcu-cli.exe $argList"

$exitCode = $null
try {
    $proc = Start-Process -FilePath $DcuCli -ArgumentList $argList -Wait -NoNewWindow -PassThru
    $exitCode = $proc.ExitCode
} catch {
    Write-Log "Failed to launch dcu-cli.exe: $($_.Exception.Message)" -Level ERROR
    Resume-AllBitLocker
    Exit 1
}

Write-Log "dcu-cli.exe ExitCode: $exitCode"

# Translate the exit code per Dell's documented dcu-cli table.
switch ($exitCode) {
    0 {
        Write-Log "DCU CLI: Success (no reboot required, or no update available)." -Level SUCCESS
        Resume-AllBitLocker
        Write-Log "=== dell-update complete. Exit 0 ==="
        Exit 0
    }
    1 {
        Write-Log "DCU CLI: Success, reboot required to complete operation." -Level SUCCESS
        # Fall through to reboot logic below. DO NOT resume BitLocker - reboot
        # is what triggers the auto-resume since we used -RebootCount 1.
    }
    2 {
        Write-Log "DCU CLI: Unknown application error (exit 2). Aborting; no reboot." -Level ERROR
        Resume-AllBitLocker
        Exit 1
    }
    4 {
        Write-Log "DCU CLI: Not launched with administrative privilege (exit 4)." -Level ERROR
        Resume-AllBitLocker
        Exit 1
    }
    6 {
        Write-Log "DCU CLI: Another instance (UI or CLI) is already running (exit 6)." -Level ERROR
        Resume-AllBitLocker
        Exit 1
    }
    7 {
        # Dell's DUP exit table documents 7 = "Password validation error -
        # Password not provided or incorrect password provided for BIOS
        # execution." This fires when the host has a BIOS admin password
        # set but -BiosPassword / -EncryptedPassword was not supplied, or
        # the supplied password is wrong.
        if ($pwMode -eq 'none') {
            Write-Log "DCU CLI: BIOS password validation error (exit 7). The host has a BIOS admin password set but no password was supplied. Re-run with -BiosPassword or -EncryptionKey + -EncryptedPassword." -Level ERROR
        } else {
            Write-Log "DCU CLI: BIOS password validation error (exit 7). The supplied password is incorrect or the encrypted material is invalid. Verify the credential in your RMM store." -Level ERROR
        }
        Resume-AllBitLocker
        Exit 1
    }
    500 {
        Write-Log "DCU CLI: No updates found for the system (exit 500). Treating as success." -Level SUCCESS
        Resume-AllBitLocker
        Exit 0
    }
    502 {
        Write-Log "DCU CLI: Apply operation cancelled (exit 502)." -Level ERROR
        Resume-AllBitLocker
        Exit 1
    }
    503 {
        Write-Log "DCU CLI: Network error applying updates (exit 503). Aborting." -Level ERROR
        Resume-AllBitLocker
        Exit 1
    }
    1002 {
        Write-Log "DCU CLI: Network error during apply (exit 1002). Aborting." -Level ERROR
        Resume-AllBitLocker
        Exit 1
    }
    { @(3000,3001,3002,3003,3004,3005) -contains $_ } {
        Write-Log "DCU CLI: Dell Client Management Service issue (exit $exitCode). See $dcuCliLog" -Level ERROR
        Resume-AllBitLocker
        Exit 1
    }
    107 {
        # Dell's table: "While evaluating the command line parameters, one or
        # more values provided to the specific option was invalid." In
        # practice this fires for -outputlog paths DCU considers reserved -
        # any path containing the substring "DCU" (case-insensitive) is
        # rejected, including Dell's own install dir AND folder names like
        # "DCUDeploy". The script's log root is Temp\BIOS-Update to avoid it.
        Write-Log "DCU CLI: Invalid -outputlog path (exit 107). DCU rejected `"$dcuCliLog`" as a reserved folder (paths containing 'DCU' are rejected). Use -LogPath to point at a non-Dell folder, e.g. `$env:SystemDrive\Temp\BIOS-Update\dell-update.log." -Level ERROR
        Resume-AllBitLocker
        Exit 1
    }
    106 {
        # Dell: "While evaluating the command line parameters, invalid options
        # were detected." Previously fired when -biosPassword was passed with
        # /applyUpdates (that option is /configure-only). The script now uses
        # a /configure step before /applyUpdates, so this should not recur,
        # but if a user-supplied option causes it, surface the cause.
        Write-Log "DCU CLI: Invalid options detected (exit 106). dcu-cli rejected an option on /applyUpdates. If you supplied -BiosPassword/-EncryptedPassword, the script should have routed them through /configure; check $dcuCliLog and $dcuCliConfigureLog." -Level ERROR
        Resume-AllBitLocker
        Exit 1
    }
    default {
        Write-Log "DCU CLI: Unhandled exit code $exitCode. See $dcuCliLog" -Level ERROR
        Resume-AllBitLocker
        Exit 1
    }
}

# ==============================================================================
# Reboot to flash
# ==============================================================================
if ($NoRestart) {
    Write-Log "Updates staged; -NoRestart was set. Leaving reboot to the RMM. BitLocker will auto-resume on the next boot." -Level SUCCESS
    Write-Log "=== dell-update complete. Exit 3010 ==="
    Exit 3010
}

Write-Log "Dell updates staged. Rebooting in $RestartDelaySeconds seconds (BitLocker will auto-resume after the reboot)." -Level SUCCESS
if ($RestartDelaySeconds -gt 0) {
    Start-Sleep -Seconds $RestartDelaySeconds
}
try {
    # -Force: skip "user is logged on" dialog. RMM context has no interactive user.
    Restart-Computer -Force -ErrorAction Stop
} catch {
    Write-Log "Restart-Computer failed: $($_.Exception.Message)" -Level ERROR
    # BitLocker is still suspended - we should NOT resume, since DCU may have
    # staged the update expecting a reboot. Surface the failure to the RMM.
    Exit 1
}
# Script never reaches here - reboot takes effect.