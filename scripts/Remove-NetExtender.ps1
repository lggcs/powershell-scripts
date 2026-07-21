<#
.SYNOPSIS
    SonicWall NetExtender removal script (PowerShell 5.0+ / ISE compatible).

.DESCRIPTION
    Performs a complete, idempotent cleanup of SonicWall NetExtender:
      1. Stops NetExtender processes.
      2. Stops and deletes the SONICWALL_NetExtender service (and legacy driver
         services sonicwallnxdrv / sslvpnnetextenderssldrv / NxRasd).
      3. Runs the NSIS uninstaller silently (uninst.exe /S) when present.
      4. Removes NetExtender PnP devices and driver packages via pnputil.exe
         (defensive; skipped automatically if not applicable / not supported).
      5. Cleans NetExtender entries from per-user RAS phonebooks (rasphone.pbk)
         and removes any NxRasd.dll / NetExtender reference from
         SYSTEM\CurrentControlSet\Services\RasMan\Parameters\CustomDLL.
      6. Deletes leftover install folders (honoring a custom InstallDir value if
         present), per-user AppData, and shortcuts.
      7. Removes NetExtender-specific registry keys (Run/RunOnce auto-starts,
         uninstall entries, App Paths, HKLM/HKCU SonicWall\SSL-VPN NetExtender,
         loaded user hives, MSI Installer\Products entries, and the optional
         broad HKLM/SOFTWARE\SonicWall purge).
      8. Loads each offline user profile's NTUSER.DAT (reg load/unload) to clean
         per-user SonicWall keys from profiles that aren't currently logged on.

    No external modules or .NET assemblies are required. Only built-in cmdlets,
    sc.exe, pnputil.exe and reg.exe are used. Designed to run from an elevated
    PowerShell 5.0/5.1 ISE session.

.NOTES
    Run as Administrator. Reboot required after completion.

    Known limitation: the script walks profiles under C:\Users and loads each
    offline user's NTUSER.DAT to clean their per-user SonicWall registry entries.
    Profiles whose NTUSER.DAT cannot be accessed (ACL-denied, in-use by another
    session, or owned by system accounts) are skipped with a log line; they will
    be handled only while that user is logged on. UsrClass.dat (HKCU\Software
    \Classes) is not parsed because NetExtender does not register per-user COM
    classes; if a future variant does, that path should be added.

.LICENSE
MIT License

.AUTHOR
Luke

.VERSION
1.0.0
#>

[CmdletBinding()]
param(
    # Remove broad HKLM:\SOFTWARE\SonicWall and HKCU:\Software\SonicWall keys.
    # Use only when no other SonicWall products are installed.
    [switch]$RemoveAllSonicWallKeys,

    # Skip pnputil-based device and driver-package removal.
    [switch]$SkipDriverCleanup,

    # Skip confirmation prompt and proceed immediately (for automation).
    [switch]$Force
)

$ErrorActionPreference = 'Continue'

$logStamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$logPath  = Join-Path $env:TEMP ("NetExtender_Removal_{0}.log" -f $logStamp)

# Static target lists (built from the on-host install and reverse-engineered
# NxCleaner.exe strings; see NxCleaner_static_analysis.md).

$ProcessNames = @(
    'NEGui', 'NEIdle', 'NEService', 'NECLI', 'NEDiag',
    'NEUpdsvc', 'NEUpdUI', 'NxCleaner', 'NetExtender'
)

$ServiceNames = @(
    'SONICWALL_NetExtender',   # main user-mode service  (Type 272)
    'sonicwallnxdrv',          # legacy NDIS driver service
    'sslvpnnetextenderssldrv', # legacy SSL-VPN driver service
    'NxRasd'                   # legacy RAS helper service
)

$InstallPaths = @(
    "${env:ProgramFiles(x86)}\SonicWall\SSL-VPN\NetExtender",
    "${env:ProgramFiles}\SonicWall\SSL-VPN\NetExtender",
    "${env:ProgramFiles(x86)}\SonicWall\NetExtender",
    "${env:ProgramFiles}\SonicWall\NetExtender",
    "${env:ProgramData}\SonicWall\NetExtender",
    "${env:ProgramData}\SonicWall\SSL-VPN NetExtender",
    "${env:ProgramData}\SonicWall\SSL-VPN"
)

$PublicShortcuts = @(
    "${env:PUBLIC}\Desktop\SonicWall NetExtender.lnk",
    "${env:PUBLIC}\Desktop\Dell SonicWALL NetExtender.lnk",
    "${env:ProgramData}\Microsoft\Windows\Start Menu\Programs\SonicWall NetExtender.lnk",
    "${env:ProgramData}\Microsoft\Windows\Start Menu\Programs\Dell SonicWALL NetExtender.lnk"
)

$SpecificRegistryKeys = @(
    'HKLM:\SOFTWARE\SonicWall\SSL-VPN NetExtender',
    'HKLM:\SOFTWARE\SonicWall\NetExtender',
    'HKLM:\SOFTWARE\WOW6432Node\SonicWall\SSL-VPN NetExtender',
    'HKLM:\SOFTWARE\WOW6432Node\SonicWall\NetExtender',
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\SonicWALL NetExtender',
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\Dell SonicWALL NetExtender',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths\Dell SonicWALL NetExtender',
    'HKCU:\Software\SonicWall\SSL-VPN NetExtender',
    'HKCU:\Software\SonicWall\NetExtender'
)

# --- helpers ---------------------------------------------------------------

function Write-Log {
    param([string]$Message)
    $line = '[{0:yyyy-MM-dd HH:mm:ss}] {1}' -f (Get-Date), $Message
    Write-Host $line
    try { Add-Content -Path $logPath -Value $line -ErrorAction SilentlyContinue } catch { }
}

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Run an external program hidden, wait, and report success.
function Invoke-External {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string]$Arguments = '',
        [int[]]$SuccessCodes = @(0, 3010, 1605, 1614)
    )
    if (-not (Test-Path -LiteralPath $FilePath) -and -not (Get-Command $FilePath -ErrorAction SilentlyContinue)) {
        Write-Log ("Not found: {0}" -f $FilePath)
        return $false
    }
    Write-Log ("Running: {0} {1}" -f $FilePath, $Arguments)
    try {
        $p = Start-Process -FilePath $FilePath -ArgumentList $Arguments -Wait -PassThru -WindowStyle Hidden
        $code = if ($p) { $p.ExitCode } else { -1 }
        Write-Log ("Exit code from {0}: {1}" -f $FilePath, $code)
        if ($SuccessCodes -contains $code) { return $true }
        return $false
    }
    catch {
        Write-Log ("Failed running {0}: {1}" -f $FilePath, $_.Exception.Message)
        return $false
    }
}

# --- 1. processes ----------------------------------------------------------

function Stop-NetExtenderProcesses {
    Write-Log 'Stopping NetExtender processes.'
    $procs = Get-Process -ErrorAction SilentlyContinue | Where-Object {
        $ProcessNames -contains $_.ProcessName -or
        ($_.Path -and $_.Path -like '*SonicWall*NetExtender*')
    }
    foreach ($pr in $procs) {
        try {
            Write-Log ("Killing {0} (PID {1})" -f $pr.ProcessName, $pr.Id)
            Stop-Process -Id $pr.Id -Force -ErrorAction Stop
        }
        catch {
            Write-Log ("Could not kill {0}: {1}" -f $pr.ProcessName, $_.Exception.Message)
        }
    }
}

# --- 2. services -----------------------------------------------------------

function Remove-NetExtenderServices {
    Write-Log 'Removing NetExtender services.'
    foreach ($svc in $ServiceNames) {
        $regKey = "HKLM:\SYSTEM\CurrentControlSet\Services\$svc"
        $exists = Test-Path $regKey
        $serviceObj = Get-Service -Name $svc -ErrorAction SilentlyContinue
        if ($serviceObj) {
            if ($serviceObj.Status -ne 'Stopped') {
                Write-Log ("Stopping service: {0}" -f $svc)
                try { Stop-Service -Name $svc -Force -ErrorAction Stop } catch { }
                & sc.exe stop $svc 2>$null | Out-Null
                Start-Sleep -Milliseconds 1500
            }
        }
        elseif (-not $exists) {
            Write-Log ("Service not present: {0}" -f $svc)
            continue
        }

        Write-Log ("Deleting service: {0}" -f $svc)
        & sc.exe delete $svc 2>&1 | ForEach-Object { Write-Log ("  sc: {0}" -f $_) }

        # Belt-and-suspenders: also drop the service registry key directly when sc
        # reports it absent but the key still lingers.
        if (Test-Path $regKey) {
            try {
                Remove-Item -Path $regKey -Recurse -Force -ErrorAction Stop
                Write-Log ("Removed service registry key: {0}" -f $regKey)
            }
            catch {
                Write-Log ("Could not remove service key {0}: {1}" -f $regKey, $_.Exception.Message)
            }
        }
    }
}

# --- 3. uninstaller ---------------------------------------------------------

function Invoke-NetExtenderUninstaller {
    Write-Log 'Running NetExtender uninstallers.'

    # Primary: the known NSIS uninst.exe. NSIS accepts /S for silent uninstall.
    foreach ($p in $InstallPaths) {
        $uninst = Join-Path $p 'uninst.exe'
        if (Test-Path -LiteralPath $uninst) {
            Write-Log ("Found uninst.exe: {0}" -f $uninst)
            Invoke-External -FilePath $uninst -Arguments '/S' | Out-Null
        }
    }

    # Registry-discovered uninstall entries (NSIS or MSI).
    $uninstallRoots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    foreach ($root in $uninstallRoots) {
        if (-not (Test-Path $root)) { continue }
        Get-ChildItem $root -ErrorAction SilentlyContinue | ForEach-Object {
            $p = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
            if (-not $p) { return }
            $name = $p.DisplayName
            if (-not ($name -like '*NetExtender*' -or $name -like '*SonicWall*SSL*VPN*')) { return }

            Write-Log ("Uninstall entry: {0} ({1})" -f $name, $_.PSChildName)

            # MSI package -> msiexec /x.
            if ($_.PSChildName -match '^\{[0-9A-Fa-f-]{36}\}$') {
                Invoke-External -FilePath 'msiexec.exe' `
                    -Arguments ("/x {0} /qn REBOOT=ReallySuppress" -f $_.PSChildName) | Out-Null
                return
            }

            # NSIS-style: append /S to UninstallString via cmd.exe to preserve quoting.
            if ($p.UninstallString) {
                Write-Log ("Running UninstallString (+/S): {0}" -f $p.UninstallString)
                Start-Process -FilePath 'cmd.exe' `
                    -ArgumentList ('/c "{0} /S"' -f $p.UninstallString) `
                    -Wait -WindowStyle Hidden
            }
        }
    }
}

# --- 4. PnP devices and driver packages ------------------------------------

# Parse pnputil /enum-drivers output into one record per block.
function Get-PnpUtilDriverBlocks {
    $raw = & pnputil.exe /enum-drivers 2>&1
    $blocks = New-Object System.Collections.ArrayList
    $current = New-Object System.Collections.ArrayList
    foreach ($line in $raw) {
        $s = "$line"
        if ($s -match '^\s*Published Name\s*:') {
            if ($current.Count -gt 0) {
                [void]$blocks.Add(($current.ToArray()))
                $current.Clear()
            }
        }
        [void]$current.Add($s)
    }
    if ($current.Count -gt 0) { [void]$blocks.Add(($current.ToArray())) }
    # Return as a flat array so callers can `foreach ($block in ...)` directly.
    return @($blocks)
}

function Remove-NetExtenderPnpAndDrivers {
    if ($SkipDriverCleanup) {
        Write-Log 'Driver/PnP cleanup skipped (-SkipDriverCleanup).'
        return
    }

    # Devices. pnputil /enum-devices and /remove-device exist on modern builds;
    # on older Windows they may not. We degrade gracefully.
    Write-Log 'Enumerating PnP devices for SonicWall/NetExtender matches.'
    try {
        $devOut = & pnputil.exe /enum-devices 2>&1
        $devLines = $devOut | ForEach-Object { "$_" }
        $currentId = $null
        $currentName = $null
        # NOTE: do not name this variable $matches — it shadows PowerShell's
        # automatic $Matches variable and silently breaks regex captures above.
        $pnpMatches = New-Object System.Collections.ArrayList
        for ($i = 0; $i -lt $devLines.Count; $i++) {
            $l = $devLines[$i]
            if ($l -match 'Instance ID:\s*(\S+)')  { $currentId   = $Matches[1] }
            if ($l -match 'Device Description:\s*(.+)$') { $currentName = $Matches[1].Trim() }
            if ($l -match '^\s*$') {
                if ($currentId -and ($currentId -match 'SonicWall|NetExtender|SWVNIC|SSLVPN' -or
                                     $currentName -match 'SonicWall|NetExtender')) {
                    [void]$pnpMatches.Add([PSCustomObject]@{ InstanceId = $currentId; Name = $currentName })
                }
                $currentId = $null; $currentName = $null
            }
        }
        if ($currentId -and ($currentId -match 'SonicWall|NetExtender|SWVNIC|SSLVPN' -or
                             $currentName -match 'SonicWall|NetExtender')) {
            [void]$pnpMatches.Add([PSCustomObject]@{ InstanceId = $currentId; Name = $currentName })
        }
        foreach ($dev in $pnpMatches) {
            Write-Log ("Removing PnP device: {0} ({1})" -f $dev.Name, $dev.InstanceId)
            & pnputil.exe /remove-device $dev.InstanceId 2>&1 |
                ForEach-Object { Write-Log ("  pnputil: {0}" -f $_) }
        }
    }
    catch {
        Write-Log ("PnP enumeration/removal unsupported or failed: {0}" -f $_.Exception.Message)
    }

    # Driver packages.
    Write-Log 'Enumerating Windows driver store for SonicWall/NetExtender packages.'
    try {
        $blocks = Get-PnpUtilDriverBlocks
        foreach ($block in $blocks) {
            $joined = ($block -join "`n")
            if ($joined -notmatch 'SonicWall|NetExtender|SWVNIC|SMA Connect Tunnel|SSL-VPN') { continue }

            $inf = $null
            foreach ($l in $block) {
                if ($l -match 'Published Name\s*:\s*(oem\d+\.inf)') { $inf = $Matches[1]; break }
            }
            if ($inf) {
                Write-Log ("Deleting driver package: {0}" -f $inf)
                & pnputil.exe /delete-driver $inf /uninstall /force 2>&1 |
                    ForEach-Object { Write-Log ("  pnputil: {0}" -f $_) }
            }
            else {
                Write-Log ("Could not parse Published Name from driver block.")
            }
        }
    }
    catch {
        Write-Log ("Driver package enumeration failed: {0}" -f $_.Exception.Message)
    }
}

# --- 5. RAS phonebook -------------------------------------------------------

# Remove [Section] blocks from rasphone.pbk whose section name (or body) refers
# to NetExtender / SonicWall. Mirrors what NxCleaner does via RasDeleteEntryA.
function Remove-RasPhonebookEntries {
    Write-Log 'Cleaning NetExtender RAS phonebook entries.'
    $userRoot = 'C:\Users'
    if (-not (Test-Path $userRoot)) { return }

    $phonebooksScanned = 0
    $phonebooksModified = 0

    Get-ChildItem $userRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notin @('Public', 'Default', 'Default User', 'All Users') } |
        ForEach-Object {
            $pbk = Join-Path $_.FullName 'AppData\Roaming\Microsoft\Network\Connections\Pbk\rasphone.pbk'
            if (-not (Test-Path -LiteralPath $pbk)) { return }

            $phonebooksScanned++
            $content = Get-Content -LiteralPath $pbk -ErrorAction SilentlyContinue
            if (-not $content) { return }
            $text = ($content -join "`r`n")
            if ($text -notmatch '(?i)NetExtender|SonicWall|SSL-VPN') { return }

            Write-Log ("Found NetExtender reference in: {0}" -f $pbk)
            # Backup before editing.
            Copy-Item -LiteralPath $pbk -Destination ($pbk + '.bak') -Force -ErrorAction SilentlyContinue

            # Split into sections starting at lines like [SectionName].
            $sections = New-Object System.Collections.ArrayList
            $cur = New-Object System.Collections.ArrayList
            $curName = $null
            foreach ($l in $content) {
                if ($l -match '^\[(.+)\]\s*$') {
                    if ($cur.Count -gt 0) {
                        [void]$sections.Add([PSCustomObject]@{ Name = $curName; Lines = $cur.ToArray() })
                    }
                    $cur.Clear()
                    $curName = $Matches[1]
                }
                [void]$cur.Add($l)
            }
            if ($cur.Count -gt 0) {
                [void]$sections.Add([PSCustomObject]@{ Name = $curName; Lines = $cur.ToArray() })
            }

            $kept = New-Object System.Collections.ArrayList
            foreach ($s in $sections) {
                $drop = $false
                if ($s.Name -and $s.Name -match '(?i)NetExtender|SonicWall|SSL-VPN') { $drop = $true }
                if (-not $drop) {
                    $body = ($s.Lines -join "`n")
                    if ($body -match '(?i)NetExtender|SonicWall') { $drop = $true }
                }
                if ($drop) {
                    Write-Log ("Removing RAS entry: {0}" -f $s.Name)
                } else {
                    foreach ($x in $s.Lines) { [void]$kept.Add($x) }
                }
            }

            try {
                Set-Content -LiteralPath $pbk -Value $kept.ToArray() -Encoding ASCII -ErrorAction Stop
                Write-Log ("Rewrote phonebook: {0}" -f $pbk)
                $phonebooksModified++
            }
            catch {
                Write-Log ("Could not rewrite {0}: {1}" -f $pbk, $_.Exception.Message)
            }
        }

    Write-Log ("Phonebook scan complete: {0} file(s) scanned, {1} modified." -f $phonebooksScanned, $phonebooksModified)
}

# NxCleaner registers NxRasd.dll as a RAS custom-dll under
# SYSTEM\CurrentControlSet\Services\RasMan\Parameters\CustomDLL during install and
# removes it during cleanup. Drop any CustomDLL value that references NetExtender
# or NxRasd without disturbing Microsoft's own RASMAN values.
function Remove-RasManCustomDll {
    $key = 'HKLM:\SYSTEM\CurrentControlSet\Services\RasMan\Parameters'
    if (-not (Test-Path $key)) { return }

    try {
        $p = Get-ItemProperty -Path $key -ErrorAction SilentlyContinue
        if (-not $p) { return }

        $customDll = $p.CustomDLL
        if (-not $customDll) { return }

        # CustomDLL can be a single string or an array of strings.
        $values = @($customDll)
        $toRemove = $values | Where-Object {
            $_ -match '(?i)NxRasd|NetExtender|SonicWall|SSL-VPN|SecureRemoteAccess'
        }
        if (-not $toRemove) { return }

        foreach ($v in $toRemove) {
            Write-Log ("Removing RasMan\\Parameters\\CustomDLL value: {0}" -f $v)
        }

        $keep = $values | Where-Object {
            $_ -notmatch '(?i)NxRasd|NetExtender|SonicWall|SSL-VPN|SecureRemoteAccess'
        }
        try {
            if ($keep) {
                Set-ItemProperty -Path $key -Name 'CustomDLL' -Value $keep -Type MultiString -ErrorAction Stop
            } else {
                Remove-ItemProperty -Path $key -Name 'CustomDLL' -ErrorAction Stop
            }
        }
        catch {
            Write-Log ("Could not update CustomDLL: {0}" -f $_.Exception.Message)
        }
    }
    catch {
        Write-Log ("RasMan\\Parameters inspection failed: {0}" -f $_.Exception.Message)
    }
}

# --- 6. files --------------------------------------------------------------

# Build the effective install-path list. Combine the static candidates with the
# InstallDir value under HKLM\SOFTWARE\SonicWall\SSL-VPN NetExtender\Standalone
# (NxCleaner reads this to honor custom install locations). If the InstallDir
# value points somewhere other than the hardcoded paths, we delete that too.
function Get-EffectiveInstallPaths {
    $paths = New-Object System.Collections.Generic.List[string]
    foreach ($p in $InstallPaths) { [void]$paths.Add($p) }

    $standaloneKey = 'HKLM:\SOFTWARE\SonicWall\SSL-VPN NetExtender\Standalone'
    if (Test-Path $standaloneKey) {
        try {
            $val = (Get-ItemProperty -Path $standaloneKey -Name 'InstallDir' -ErrorAction SilentlyContinue).InstallDir
            if ($val) {
                $trimmed = $val.TrimEnd('\')
                if ($trimmed -and ($paths -notcontains $trimmed) -and ($paths -notcontains ($trimmed + '\'))) {
                    Write-Log ("Custom InstallDir detected: {0}" -f $trimmed)
                    [void]$paths.Add($trimmed)
                }
            }
        }
        catch {
            Write-Log ("Could not read InstallDir: {0}" -f $_.Exception.Message)
        }
    }
    return $paths
}

function Remove-NetExtenderFiles {
    Write-Log 'Removing leftover files and folders.'

    $effectivePaths = Get-EffectiveInstallPaths
    foreach ($p in $effectivePaths) {
        if (Test-Path -LiteralPath $p) {
            try {
                Write-Log ("Deleting: {0}" -f $p)
                Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction Stop
            }
            catch {
                Write-Log ("Failed to delete {0}: {1}" -f $p, $_.Exception.Message)
            }
        }
    }

    foreach ($s in $PublicShortcuts) {
        if (Test-Path -LiteralPath $s) {
            try {
                Remove-Item -LiteralPath $s -Force -ErrorAction Stop
                Write-Log ("Deleted shortcut: {0}" -f $s)
            }
            catch {
                Write-Log ("Failed to delete shortcut {0}: {1}" -f $s, $_.Exception.Message)
            }
        }
    }

    # Per-user AppData.
    $userRoot = 'C:\Users'
    if (Test-Path $userRoot) {
        Get-ChildItem $userRoot -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notin @('Public', 'Default', 'Default User', 'All Users') } |
            ForEach-Object {
                $u = $_.FullName
                $userPaths = @(
                    (Join-Path $u 'AppData\Roaming\SonicWall'),
                    (Join-Path $u 'AppData\Local\SonicWall'),
                    (Join-Path $u 'Desktop\SonicWall NetExtender.lnk'),
                    (Join-Path $u 'Desktop\Dell SonicWALL NetExtender.lnk'),
                    (Join-Path $u 'Start Menu\Programs\SonicWall NetExtender.lnk')
                )
                foreach ($up in $userPaths) {
                    if (Test-Path -LiteralPath $up) {
                        try {
                            Write-Log ("Deleting user artifact: {0}" -f $up)
                            Remove-Item -LiteralPath $up -Recurse -Force -ErrorAction Stop
                        }
                        catch {
                            Write-Log ("Could not delete {0}: {1}" -f $up, $_.Exception.Message)
                        }
                    }
                }
            }
    }

    # Temp leftovers.
    foreach ($tempRoot in @($env:TEMP, 'C:\Windows\Temp')) {
        if (-not (Test-Path $tempRoot)) { continue }
        Get-ChildItem $tempRoot -Recurse -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -like '*NetExtender*' -or $_.FullName -like '*SonicWall*' } |
            ForEach-Object {
                try {
                    Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction Stop
                    Write-Log ("Deleted temp item: {0}" -f $_.FullName)
                }
                catch {
                    Write-Log ("Could not delete temp item {0}" -f $_.FullName)
                }
            }
    }
}

# --- 7. registry -----------------------------------------------------------

function Remove-NetExtenderRegistry {
    Write-Log 'Removing NetExtender-specific registry entries.'

    # Static SonicWall/NetExtender keys (App Paths, install, HKCU mirror).
    foreach ($key in $SpecificRegistryKeys) {
        if (Test-Path $key) {
            try {
                Write-Log ("Deleting registry key: {0}" -f $key)
                Remove-Item -LiteralPath $key -Recurse -Force -ErrorAction Stop
            }
            catch {
                Write-Log ("Could not delete key {0}: {1}" -f $key, $_.Exception.Message)
            }
        }
    }

    # Run / RunOnce auto-start values that re-launch NetExtender at logon.
    $runRoots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\RunOnce',
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run',
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce'
    )
    # A bare 'NEUpd' substring would otherwise false-match 'OneDriveSetup'.
    # NE* process names must be a full filename token ending in .exe; the
    # longer NetExtender/SonicWall/SSL-VPN/SecureRemoteAccess strings are
    # safe as path-anchored substrings.
    $runValuePattern = '(?i)(?:^|["\\\/])(?:NetExtender|SonicWall|SecureRemoteAccess|SSL-VPN|NEGui|NEIdle|NEService|NECLI|NEDiag|NEUpdsvc|NEUpdUI|NxCleaner)\.exe'
    $runValuePathPattern = '(?i)SonicWall\\SSL-VPN|SonicWall\\NetExtender|\\NetExtender\\|SSL-VPN NetExtender|SecureRemoteAccess'
    foreach ($root in $runRoots) {
        if (-not (Test-Path $root)) { continue }
        $p = Get-ItemProperty -Path $root -ErrorAction SilentlyContinue
        if (-not $p) { continue }
        foreach ($prop in $p.PSObject.Properties) {
            if ($prop.Name -like 'PS*') { continue }
            $val = "$($prop.Value)"
            if ($val -and ($val -match $runValuePattern -or $val -match $runValuePathPattern)) {
                try {
                    Write-Log ("Removing auto-start value: {0} :: {1}" -f $root, $prop.Name)
                    Remove-ItemProperty -LiteralPath $root -Name $prop.Name -Force -ErrorAction Stop
                }
                catch {
                    Write-Log ("Could not remove {0} :: {1}: {2}" -f $root, $prop.Name, $_.Exception.Message)
                }
            }
        }
    }

    # Loaded user hives (HKEY_USERS\<SID>\Software\SonicWall\...).
    try {
        Get-ChildItem Registry::HKEY_USERS -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match 'S-1-5-21-' -and $_.Name -notlike '*_Classes' } |
            ForEach-Object {
                $sid = Split-Path $_.Name -Leaf
                $userKeys = @(
                    "Registry::HKEY_USERS\$sid\Software\SonicWall\SSL-VPN NetExtender",
                    "Registry::HKEY_USERS\$sid\Software\SonicWall\NetExtender",
                    "Registry::HKEY_USERS\$sid\Software\SonicWall"
                )
                foreach ($uk in $userKeys) {
                    if (Test-Path $uk) {
                        try {
                            Remove-Item -LiteralPath $uk -Recurse -Force -ErrorAction Stop
                            Write-Log ("Deleted loaded user key: {0}" -f $uk)
                        }
                        catch {
                            Write-Log ("Could not delete {0}: {1}" -f $uk, $_.Exception.Message)
                        }
                    }
                }
            }
    }
    catch {
        Write-Log ("HKEY_USERS traversal failed: {0}" -f $_.Exception.Message)
    }

    # Offline user profiles not currently logged on.
    Remove-OfflineUserHives

    # Stale uninstall entries still referencing NetExtender.
    $uninstallRoots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    foreach ($root in $uninstallRoots) {
        if (-not (Test-Path $root)) { continue }
        Get-ChildItem $root -ErrorAction SilentlyContinue | ForEach-Object {
            $p = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
            if (-not $p) { return }
            if ($p.DisplayName -like '*NetExtender*' -or
                $p.DisplayName -like '*SonicWall*SSL*VPN*' -or
                $p.UninstallString -like '*NetExtender*' -or
                $p.InstallLocation -like '*NetExtender*') {
                try {
                    Write-Log ("Deleting stale uninstall entry: {0}" -f $_.PSPath)
                    Remove-Item -LiteralPath $_.PSPath -Recurse -Force -ErrorAction Stop
                }
                catch {
                    Write-Log ("Could not delete entry {0}: {1}" -f $_.PSPath, $_.Exception.Message)
                }
            }
        }
    }

    # MSI-cached product registration. NxCleaner walks
    # HKLM\SOFTWARE\Classes\Installer\Products and removes entries whose
    # ProductName matches NetExtender / SonicWall SSL-VPN NetExtender. Harmless
    # on NSIS installs (no entries); valuable on legacy MSI deployments.
    $installerProducts = 'HKLM:\SOFTWARE\Classes\Installer\Products'
    if (Test-Path $installerProducts) {
        Get-ChildItem $installerProducts -ErrorAction SilentlyContinue | ForEach-Object {
            $p = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
            if (-not $p) { return }
            if ($p.ProductName -like '*NetExtender*' -or
                $p.ProductName -like '*SonicWall*SSL*VPN*' -or
                $p.ProductName -like '*SecureRemoteAccess*') {
                try {
                    Write-Log ("Deleting MSI Installer\\Products entry: {0} ({1})" -f $_.PSChildName, $p.ProductName)
                    Remove-Item -LiteralPath $_.PSPath -Recurse -Force -ErrorAction Stop
                }
                catch {
                    Write-Log ("Could not delete Installer\\Products entry {0}: {1}" -f $_.PSPath, $_.Exception.Message)
                }
            }
        }
    }

    # Optional broad purge (only when explicitly enabled).
    if ($RemoveAllSonicWallKeys) {
        Write-Log 'RemoveAllSonicWallKeys set: purging broad SonicWall keys.'
        foreach ($key in @('HKLM:\SOFTWARE\SonicWall',
                          'HKLM:\SOFTWARE\WOW6432Node\SonicWall',
                          'HKCU:\Software\SonicWall')) {
            if (Test-Path $key) {
                try {
                    Remove-Item -LiteralPath $key -Recurse -Force -ErrorAction Stop
                    Write-Log ("Deleted broad key: {0}" -f $key)
                }
                catch {
                    Write-Log ("Could not delete broad key {0}: {1}" -f $key, $_.Exception.Message)
                }
            }
        }
    }
}

# Load each offline user profile's NTUSER.DAT under a temporary subkey of
# HKEY_USERS, delete per-user SonicWall keys, then unload. Profiles that are
# already loaded (current user + anyone with an active session) are skipped to
# avoid touching live hives; those are handled by the loaded-hive pass above.
function Remove-OfflineUserHives {
    Write-Log 'Processing offline user profile hives.'

    # SIDs currently visible under HKEY_USERS (load targets must avoid these).
    $loadedSids = @()
    try {
        $loadedSids = Get-ChildItem Registry::HKEY_USERS -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match 'S-1-5-21-' -and $_.Name -notlike '*_Classes' } |
            ForEach-Object { Split-Path $_.Name -Leaf }
    }
    catch {
        Write-Log ("Could not enumerate HKEY_USERS; skipping offline-hive pass: {0}" -f $_.Exception.Message)
        return
    }

    # Map NTUSER.DAT paths to owning SIDs via the ProfileImagePath registry.
    $profileList = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'
    if (-not (Test-Path $profileList)) {
        Write-Log 'ProfileList key missing; skipping offline-hive pass.'
        return
    }

    # System / special accounts we never touch.
    $skipNames = @('Public', 'Default', 'Default User', 'All Users',
                   'system32', 'ServiceProfiles', 'NetworkService', 'LocalService')
    $tag = 0
    Get-ChildItem $profileList -ErrorAction SilentlyContinue | ForEach-Object {
        $sid = $_.PSChildName
        if ($loadedSids -contains $sid) { return }   # hive is live; already handled.

        try { $pi = Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction SilentlyContinue } catch { return }
        if (-not $pi -or -not $pi.ProfileImagePath) { return }

        $profilePath = $pi.ProfileImagePath
        $leaf = Split-Path $profilePath -Leaf
        if ($skipNames -contains $leaf) { return }

        $ntuser = Join-Path $profilePath 'NTUSER.DAT'
        if (-not (Test-Path -LiteralPath $ntuser)) { return }

        # Use a unique temp subkey name under HKEY_USERS.
        $tag++
        $mountName = "NX_CLEAN_{0}_{1}" -f $tag, $(Get-Date -Format 'HHmmssfff')

        Write-Log ("Loading offline hive: {0} ({1}) as {2}" -f $ntuser, $sid, $mountName)
        $loadOut = & reg.exe load "HKEY_USERS\$mountName" $ntuser 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Log ("  reg load failed (exit {0}): {1}" -f $LASTEXITCODE, ($loadOut -join ' '))
            return
        }

        try {
            $mountPoint = "Registry::HKEY_USERS\$mountName"
            $userKeys = @(
                (Join-Path $mountPoint 'Software\SonicWall\SSL-VPN NetExtender'),
                (Join-Path $mountPoint 'Software\SonicWall\NetExtender'),
                (Join-Path $mountPoint 'Software\SonicWall')
            )
            foreach ($uk in $userKeys) {
                if (Test-Path $uk) {
                    try {
                        Remove-Item -LiteralPath $uk -Recurse -Force -ErrorAction Stop
                        Write-Log ("  Deleted offline user key: {0}" -f $uk)
                    }
                    catch {
                        Write-Log ("  Could not delete {0}: {1}" -f $uk, $_.Exception.Message)
                    }
                }
            }
        }
        finally {
            # Critical: always unload, even on partial failure, to avoid leaving
            # the user's hive mounted (which would block their next logon).
            [void](& reg.exe unload "HKEY_USERS\$mountName" 2>&1)
            Write-Log ("  Unloaded: HKEY_USERS\\{0}" -f $mountName)
        }
    }
}

# --- 8. final report --------------------------------------------------------

function Show-RemainingArtifacts {
    Write-Log '--- Remaining-artifact check ---'

    $leftSvc = Get-Service -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like '*NetExtender*' -or $_.Name -like '*sonicwall*' }
    if ($leftSvc) {
        foreach ($s in $leftSvc) { Write-Log ("  Service remains: {0} ({1})" -f $s.Name, $s.Status) }
    } else { Write-Log '  No NetExtender services remain.' }

    $leftPaths = Get-EffectiveInstallPaths | Where-Object { Test-Path -LiteralPath $_ }
    if ($leftPaths) {
        foreach ($p in $leftPaths) { Write-Log ("  Folder remains: {0}" -f $p) }
    } else { Write-Log '  No NetExtender install folders remain.' }

    # Driver packages (best-effort).
    try {
        $blocks = Get-PnpUtilDriverBlocks
        $left = $blocks | Where-Object { ($_ -join "`n") -match 'SonicWall|NetExtender|SWVNIC' }
        if ($left) { Write-Log ("  Driver packages remain: {0}" -f $left.Count) }
        else       { Write-Log '  No matching driver packages remain.' }
    } catch { Write-Log '  Could not query driver store for leftovers.' }

    Write-Log '--- End remaining-artifact check ---'
}

# --- main ------------------------------------------------------------------

Write-Log 'Starting SonicWall NetExtender removal.'
Write-Log ("Log: {0}" -f $logPath)

if (-not (Test-IsAdmin)) {
    throw 'This script must be run from an elevated (Administrator) PowerShell session.'
}

# Optional confirmation.
if (-not $Force) {
    Write-Host ''
    Write-Host 'This will stop services, run uninstallers, and delete files, registry'
    Write-Host 'keys (including Run/RunOnce auto-starts and offline user profiles), RAS'
    Write-Host 'entries and driver packages related to SonicWall NetExtender. A reboot'
    Write-Host 'will be required.'
    if ($RemoveAllSonicWallKeys) {
        Write-Host 'WARNING: -RemoveAllSonicWallKeys will delete ALL SonicWall registry keys.'
    }
    Write-Host ''
    $resp = Read-Host 'Continue? (Y/N)'
    if ($resp -notmatch '^[Yy]') {
        Write-Log 'Aborted by user.'
        Write-Output 'Aborted. No changes were made.'
        return
    }
}

Stop-NetExtenderProcesses
Remove-NetExtenderServices
Invoke-NetExtenderUninstaller

# Second pass: anything surfaced by the uninstaller (re-stopped in case the
# uninstaller respawned the service or left child processes behind).
Stop-NetExtenderProcesses
Remove-NetExtenderServices
Remove-NetExtenderPnpAndDrivers
Remove-RasPhonebookEntries
Remove-RasManCustomDll
Remove-NetExtenderFiles
Remove-NetExtenderRegistry

Show-RemainingArtifacts

Write-Log 'NetExtender removal routine complete.'
Write-Log 'A reboot is strongly recommended before reinstalling NetExtender.'
Write-Output ("Complete. Log: {0}. Reboot the system." -f $logPath)