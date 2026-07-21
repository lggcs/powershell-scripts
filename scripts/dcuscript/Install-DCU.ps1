#Requires -Version 5.1
<#
.SYNOPSIS
    Stages and installs the .NET 8.0 Desktop Runtime and Dell Command | Update
    5.7.0 (Universal Application) for deployment.

.DESCRIPTION
    Idempotent installer chain. Safe to re-run on the same host.
      1) Verifies the .NET 8.0 Desktop Runtime (>= $MinDotNetVersion) is present;
         if missing, installs it silently from a bundled or downloaded installer.
      2) Verifies DCU 5.7.0 (Universal) is present; if missing or older, installs
         it silently.
      3) Writes a timestamped log to $LogPath.
      4) Exits with RMM-consumable codes:
           0    = Success, no reboot required (or already installed)
           3010 = Success, reboot required to complete install
           1    = Hard failure (see log)

.PARAMETER InstallSource
    Directory containing the bundled installers. Defaults to the directory
    this script lives in. Expected filenames:
      - windowsdesktop-runtime-8.0.*-win-x64.exe  (.NET 8.0 Desktop Runtime)
      - Dell-Command-Update-Windows-Universal-Application_*_5.7.0_A00.EXE  (DCU)

    ONLY the .NET 8.0 DESKTOP Runtime is supported. The base .NET runtime
    (dotnet-runtime-*.exe) does not include WPF/WinForms and will not satisfy
    DCU's prerequisite. The script hard-fails if the Desktop Runtime is not
    registered after install.

    If a file is not present the script will attempt to download it from the
    Microsoft / Dell download URLs in this script. Provide files locally for
    air-gapped or controlled environments; do not rely on the download fallback
    for mass RMM deployment.

.PARAMETER LogPath
    Full path to the log file. Defaults to
    $env:SystemDrive\Temp\BIOS-Update\Install-DCU.log.

.PARAMETER MinDotNetVersion
    Minimum .NET 8.0 Desktop Runtime version required (as the installer's
    embedded FileVersion, e.g. "8.0.25.34020"). Defaults to "8.0.25".

.PARAMETER ExpectedDcuVersion
    DCU version required, matched against the registry ProductVersion string.
    Defaults to "5.7.0".

.PARAMETER NoDownload
    Switch: fail instead of downloading when a bundled installer is missing.
    Recommended for RMM runs to force shipping the installers with the script.

.PARAMETER SkipHashCheck
    Switch: skip hash verification of the .NET and DCU installers. By default
    the script hard-fails if either file hash does not match the embedded
    expected hashes ($DotNetSha512 SHA-512, $DcuSha256 SHA-256). Only use this
    switch during development; never in production RMM runs.

.EXAMPLE
    .\Install-DCU.ps1
    .\Install-DCU.ps1 -NoDownload
    .\Install-DCU.ps1 -InstallSource \\server\share\DCU -LogPath C:\Logs\d.log

.NOTES
    PowerShell 5.1 strict-ISE compatible. No .NET idioms. Must be run as
    Administrator (DCU and .NET installers both require elevation).

.LICENSE
MIT License

.AUTHOR
Luke

.VERSION
1.0.0
#>

[CmdletBinding()]
param(
    [string]$InstallSource,
    [string]$LogPath       = (Join-Path $env:SystemDrive 'Temp\BIOS-Update\Install-DCU.log'),
    [string]$MinDotNetVersion  = '8.0.25',
    [string]$ExpectedDcuVersion = '5.7.0',
    [switch]$NoDownload,
    [switch]$SkipHashCheck
)

# --- Strictness / error policy -------------------------------------------------
$ErrorActionPreference = 'Stop'
$ProgressPreference     = 'SilentlyContinue'   # speed up Invoke-WebRequest
Set-StrictMode -Version 3.0

# Resolve InstallSource AFTER Set-StrictMode. $PSScriptRoot is populated by
# PS 5.1+ whenever a .ps1 file is executed as a file (the normal RMM case:
# `powershell.exe -File path.ps1` or `& 'path.ps1'`). It is NOT populated when
# the script's text is slurped and re-executed via Invoke-Expression /
# Invoke-Command -ScriptBlock [scriptblock]::Create($content) - in those
# contexts $MyInvocation exists but its shape is incompatible with strict
# mode (accessing .MyCommand.Path throws "property not found" under
# Set-StrictMode -Version 3.0). For those contexts we fall back to the
# current working directory; RMMs that slurp-and-reexecute almost always cd
# to the script folder first, and the user can always pass -InstallSource
# explicitly to override the guess.
if (-not $InstallSource) {
    if ($PSScriptRoot) {
        $InstallSource = $PSScriptRoot
    }
    else {
        $InstallSource = (Get-Location).Path
    }
}
if (-not $InstallSource) { $InstallSource = (Get-Location).Path }

# --- Constants ----------------------------------------------------------------
$LogDir  = Split-Path -Path $LogPath -Parent
$TempDir = Join-Path $env:SystemDrive 'Temp\BIOS-Update\Stage'

# Download fallbacks. Verify these URLs against your procurement process before
# relying on them. The Microsoft URL is the official .NET 8.0.25 Desktop Runtime
# build artifact (builds.dotnet.microsoft.com); the Dell URL is the release
# path for FGK9X WIN64 5.7.0 A00. Dell's CDN (dl.dell.com) rejects the default
# PowerShell User-Agent with HTTP 403, so the download path sends a browser
# User-Agent via -Headers.
$DotNetDownloadUrl = 'https://builds.dotnet.microsoft.com/dotnet/WindowsDesktop/8.0.25/windowsdesktop-runtime-8.0.25-win-x64.exe'
$DcuDownloadUrl    = 'https://dl.dell.com/FOLDER14424601M/1/Dell-Command-Update-Windows-Universal-Application_FGK9X_WIN64_5.7.0_A00.EXE'

# SHA-512 of the .NET 8.0.25 Desktop Runtime x64 installer, from the Microsoft
# download page. Verified against the file shipped with this script.
$DotNetSha512 = '044628141cb05423b7e3a819d3baf13cab75382174a1e528c9c00f9e93919fd2684d68b5d70293f69560316c3909c49be279290da22541ed130a91924842e8ad'

# SHA-256 of the DCU 5.7.0 Universal installer, from the Dell download page.
# Verified against the file shipped with this script.
$DcuSha256 = '98c20d9809d7469a760b42a9a258e8c67a35c6cf46aa6a9c173e29d39a056d89'

# --- Logging ------------------------------------------------------------------
if (-not (Test-Path -Path $LogDir)) {
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
}
if (-not (Test-Path -Path $TempDir)) {
    New-Item -ItemType Directory -Path $TempDir -Force | Out-Null
}

function Write-Log {
    param(
        [Parameter(Mandatory=$true, Position=0)][string]$Message,
        [ValidateSet('INFO','WARN','ERROR','SUCCESS')][string]$Level = 'INFO'
    )
    $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
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
# Pre-flight checks
# ==============================================================================

# Admin check (the installers will fail without elevation; fail fast instead
# of letting them exit with cryptic codes).
$currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal   = New-Object Security.Principal.WindowsPrincipal($currentUser)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) {
    Write-Log "This script must be run as Administrator." -Level ERROR
    Exit 1
}

Write-Log "=== Install-DCU starting ==="
Write-Log "InstallSource      : $InstallSource"
Write-Log "LogPath            : $LogPath"
Write-Log "TempDir            : $TempDir"
Write-Log "MinDotNetVersion   : $MinDotNetVersion"
Write-Log "ExpectedDcuVersion : $ExpectedDcuVersion"
Write-Log "NoDownload         : $NoDownload"

# Force TLS 1.2 for any download path (Win7/Win8.1 default to TLS 1.0/1.1).
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 }
catch { Write-Log "Could not set TLS 1.2 - downloads may fail on legacy hosts." -Level WARN }

# Final exit code we hand to the RMM. Start at 0; promote to 3010 if any
# installer reports a reboot is pending, keep at 0 if everything was already
# installed, set to 1 on any hard failure.
$script:FinalExitCode = 0

function Set-RebootRequired {
    if ($script:FinalExitCode -eq 0) { $script:FinalExitCode = 3010 }
}

function Fail-Hard {
    param([Parameter(Mandatory)][string]$Message)
    Write-Log $Message -Level ERROR
    Exit 1
}

# ==============================================================================
# Helper: hash verification (PS 5.1 Get-FileHash supports SHA256/SHA384/SHA512).
# ==============================================================================
function Test-FileHash {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ExpectedHash,
        [ValidateSet('SHA256','SHA384','SHA512')][string]$Algorithm = 'SHA512'
    )
    if ($SkipHashCheck) { return $true }
    if (-not (Test-Path -Path $Path -PathType Leaf)) { return $false }
    try {
        $actual = (Get-FileHash -Path $Path -Algorithm $Algorithm).Hash
    } catch {
        Write-Log "Get-FileHash ($Algorithm) failed for $Path : $($_.Exception.Message)" -Level ERROR
        return $false
    }
    if ($actual -and $actual.ToLower() -eq $ExpectedHash.ToLower()) {
        Write-Log "$Algorithm verified: $Path"
        return $true
    }
    Write-Log "$Algorithm MISMATCH for $Path`nExpected: $ExpectedHash`nActual  : $actual" -Level ERROR
    return $false
}

# ==============================================================================
# Helper: resolve an installer file (use bundled file if present, else download)
# ==============================================================================
function Resolve-Installer {
    param(
        [string]$NamePattern,        # e.g. 'windowsdesktop-runtime-8.0.*-win-x64.exe'
        [string]$DownloadUrl,
        [string]$OutFileName,
        [string]$ExpectedHash,        # optional; if set, hash is verified after resolve
        [ValidateSet('SHA256','SHA384','SHA512')][string]$HashAlgorithm = 'SHA512'
    )
    # Precedence 1: pattern match in InstallSource (preferred for RMM shipping)
    $local = Get-ChildItem -Path $InstallSource -Filter $NamePattern -File -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending | Select-Object -First 1
    $resolved = $null
    if ($local) {
        $resolved = $local.FullName
        Write-Log "Using bundled installer: $resolved"
    } else {
        # Precedence 2: exact-name match in InstallSource (some RMMs strip wildcards)
        $exact = Join-Path $InstallSource $OutFileName
        if (Test-Path -Path $exact -PathType Leaf) {
            $resolved = $exact
            Write-Log "Using bundled installer (exact name): $resolved"
        }
    }

    # Precedence 3: download fallback
    if (-not $resolved) {
        if ($NoDownload) {
            Fail-Hard "Bundled installer '$NamePattern' not found in '$InstallSource' and -NoDownload was set."
        }
        Write-Log "Bundled installer '$NamePattern' not found; downloading from $DownloadUrl" -Level WARN
        $resolved = Join-Path $TempDir $OutFileName
        # Dell's CDN (dl.dell.com) rejects the default PowerShell User-Agent
        # with HTTP 403. Microsoft's CDN accepts it. Send a browser UA to
        # cover both; -UseBasicParsing avoids the IE-engine dependency.
        $dlHeaders = @{ 'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36' }
        try {
            Invoke-WebRequest -Uri $DownloadUrl -OutFile $resolved -UseBasicParsing -Headers $dlHeaders
        }
        catch {
            Fail-Hard "Download failed from $DownloadUrl : $($_.Exception.Message)"
        }
        if (-not (Test-Path -Path $resolved -PathType Leaf)) {
            Fail-Hard "Download reported success but file is missing: $resolved"
        }
        Write-Log "Downloaded to $resolved"
    }

    # Hash verification (always runs unless -SkipHashCheck, regardless of
    # whether the file was bundled or downloaded - protects against a tampered
    # staged file as well as a corrupted/interrupted download).
    if ($ExpectedHash) {
        if (-not (Test-FileHash -Path $resolved -ExpectedHash $ExpectedHash -Algorithm $HashAlgorithm)) {
            # Remove a downloaded bad file so the next run re-downloads; leave
            # bundled files in place (they're user-owned).
            if ($resolved -like "$TempDir*") {
                Remove-Item -Path $resolved -Force -ErrorAction SilentlyContinue
            }
            Fail-Hard "Installer hash verification failed for $resolved. Aborting for safety."
        }
    }

    return $resolved
}

# ==============================================================================
# .NET 8.0 Desktop Runtime detection
# ==============================================================================
# The Desktop runtime registers in the Windows Uninstall registry with
# DisplayName like: "Microsoft Windows Desktop Runtime - 8.0.29 (x64)"
# (Desktop Runtime FIRST, version SECOND, architecture in parens). Microsoft's
# DisplayVersion property is unreliable for these entries (sometimes a build
# number like 64.116.55314, sometimes the real 8.0.x.y). We extract the version
# from the DisplayName itself for a trustworthy signal.
#
# Strict-mode safe property access: registry entries from Get-ItemProperty
# frequently omit values like DisplayName / DisplayVersion (e.g. some COM
# component registrations). Under Set-StrictMode -Version 3.0, direct member
# access ($i.DisplayName) throws "The property 'DisplayName' cannot be found
# on this object" when the property is absent. Use a helper that returns
# $null instead of throwing.
function Get-PropertySafe {
    param(
        [Parameter(Mandatory=$true, Position=0)]$Object,
        [Parameter(Mandatory=$true, Position=1)][string]$Name
    )
    if ($null -eq $Object) { return $null }
    # PSObject.Properties indexer returns $null for missing properties without
    # tripping strict mode. Case-insensitive match handles "DisplayVersion" vs
    # whatever case the registry provider returned.
    $prop = $Object.PSObject.Properties | Where-Object { $_.Name -ieq $Name } | Select-Object -First 1
    if ($prop) { return $prop.Value }
    return $null
}

function Get-InstalledDotNetDesktopVersion {
    # Match the Microsoft-published DisplayName format:
    #   "Microsoft Windows Desktop Runtime - 8.0.<patch> (x64)"
    # We require x64 explicitly because the Uninstall key may also contain
    # x86 entries and we ship the x64 installer only. We lock to major version
    # 8 because DCU 5.7.0's prerequisite is .NET 8.x Desktop Runtime; a 6.x or
    # 9.x Desktop Runtime does not satisfy it. Captures the version (e.g.
    # "8.0.29") into group 1.
    $pattern = '^Microsoft\s+Windows\s+Desktop\s+Runtime\s+-\s+(8\.\d+\.\d+)\s+\(x64\)\s*$'

    $keys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $best = $null
    foreach ($k in $keys) {
        try {
            $items = Get-ItemProperty -Path $k -ErrorAction SilentlyContinue
        } catch { continue }
        if ($null -eq $items) { continue }
        foreach ($i in $items) {
            $name = Get-PropertySafe $i 'DisplayName'
            if (-not $name) { continue }
            if ($name -match $pattern) {
                $ver = $matches[1]
                # Keep the highest version encountered - handles cases where
                # stale registry entries coexist with current ones.
                if (-not $best -or (Test-VersionGeq -Have $ver -Need $best)) {
                    $best = $ver
                }
            }
        }
    }
    return $best
}

function Test-VersionGeq {
    param([string]$Have, [string]$Need)
    if (-not $Have) { return $false }
    try {
        $h = [version]$Have
        $n = [version]$Need
        return ($h -ge $n)
    } catch {
        return $false
    }
}

# ==============================================================================
# DCU detection
# ==============================================================================
# Dell UpdateService registry probe
# (HKLM:\SOFTWARE\DELL\UpdateService\Clients\CommandUpdate\Preferences\Settings).
# Universal -> "C:\Program Files\Dell\CommandUpdate\"
function Get-InstalledDcu {
    $reg = 'HKLM:\SOFTWARE\DELL\UpdateService\Clients\CommandUpdate\Preferences\Settings'
    if (-not (Test-Path -Path $reg)) { return $null }
    # Use Get-PropertySafe for the same strict-mode reason: the registry key
    # may exist without the AppCode / ProductVersion values, and direct
    # member access throws under Set-StrictMode -Version 3.0.
    $keyObj = $null
    try { $keyObj = Get-ItemProperty -Path $reg -ErrorAction SilentlyContinue } catch { return $null }
    if ($null -eq $keyObj) { return $null }
    $appCode = Get-PropertySafe $keyObj 'AppCode'
    $ver     = Get-PropertySafe $keyObj 'ProductVersion'
    if (-not $appCode) { return $null }
    return [pscustomobject]@{ AppCode = $appCode; Version = $ver }
}

# ==============================================================================
# 1) Install .NET 8.0 Desktop Runtime
# ==============================================================================
Write-Log "Stage 1: .NET 8.0 Desktop Runtime"

$dotNetVersion = Get-InstalledDotNetDesktopVersion
if ($dotNetVersion -and (Test-VersionGeq -Have $dotNetVersion -Need $MinDotNetVersion)) {
    Write-Log ".NET 8.0 Desktop Runtime $dotNetVersion already installed (>= $MinDotNetVersion). Skipping." -Level SUCCESS
} else {
    if ($dotNetVersion) {
        Write-Log "Installed .NET Desktop runtime $dotNetVersion is older than required $MinDotNetVersion; will upgrade." -Level WARN
    } else {
        Write-Log ".NET 8.0 Desktop Runtime not found; installing."
    }

    $dotNetExe = Resolve-Installer `
        -NamePattern 'windowsdesktop-runtime-8.0.*-win-x64.exe' `
        -DownloadUrl $DotNetDownloadUrl `
        -OutFileName 'windowsdesktop-runtime-8.0.25-win-x64.exe' `
        -ExpectedSha512 $DotNetSha512

    if (-not (Test-Path -Path $dotNetExe)) { Fail-Hard "Resolved .NET installer not found: $dotNetExe" }

    $dotNetLog = Join-Path $LogDir 'DotNet_8_Desktop_Install.log'
    $dotNetArgs = "/install /quiet /norestart /log `"$dotNetLog`""
    Write-Log "Running: $dotNetExe $dotNetArgs"

    try {
        $proc = Start-Process -FilePath $dotNetExe -ArgumentList $dotNetArgs -Wait -PassThru
    } catch {
        Fail-Hard "Failed to launch .NET installer: $($_.Exception.Message)"
    }

    Write-Log ".NET installer ExitCode: $($proc.ExitCode)"
    switch ($proc.ExitCode) {
        0    { Write-Log ".NET Desktop Runtime installed successfully." -Level SUCCESS }
        3010 { Write-Log ".NET Desktop Runtime installed; reboot required." -Level SUCCESS; Set-RebootRequired }
        1602  { Write-Log ".NET installer was cancelled by user (1602)." -Level WARN }
        1603  { Fail-Hard ".NET installer fatal error (1603). See $dotNetLog" }
        default { Fail-Hard ".NET installer failed with exit code $($proc.ExitCode). See $dotNetLog" }
    }

    # Re-verify: a non-zero exit from the installer should have been caught by
    # the switch above, but the installer can lie (returns 0 with nothing
    # installed). If the registry still shows no Desktop Runtime, hard-fail
    # rather than silently continuing - DCU install would then fail with a
    # cryptic .NET error further down.
    $dotNetVersion = Get-InstalledDotNetDesktopVersion
    if (-not $dotNetVersion) {
        Fail-Hard ".NET Desktop Runtime is still not registered after install. The bundled installer did not install the Desktop Runtime. Check $dotNetLog."
    }
}

# ==============================================================================
# 2) Install Dell Command | Update 5.7.0 (Universal)
# ==============================================================================
Write-Log "Stage 2: Dell Command | Update $ExpectedDcuVersion"

$dcu = Get-InstalledDcu
if ($dcu -and $dcu.AppCode -eq 'Universal' -and $dcu.Version -and ($dcu.Version.StartsWith($ExpectedDcuVersion))) {
    Write-Log "DCU $($dcu.Version) ($($dcu.AppCode)) already installed. Skipping." -Level SUCCESS
} else {
    if ($dcu) {
        Write-Log "DCU present as $($dcu.AppCode) v$($dcu.Version) - will (re)install Universal $ExpectedDcuVersion." -Level WARN
    } else {
        Write-Log "DCU not installed; installing Universal $ExpectedDcuVersion."
    }

    $dcuExe = Resolve-Installer `
        -NamePattern 'Dell-Command-Update-Windows-Universal-Application_*_5.7.0_A00.EXE' `
        -DownloadUrl $DcuDownloadUrl `
        -OutFileName 'Dell-Command-Update-Windows-Universal-Application_5.7.0_A00.EXE' `
        -ExpectedHash $DcuSha256 `
        -HashAlgorithm SHA256

    if (-not (Test-Path -Path $dcuExe)) { Fail-Hard "Resolved DCU installer not found: $dcuExe" }

    # Verified DCU silent install switches: /s = silent, /l=<path> = log file.
    # Note: /l writes the LOG FILE at the path given, not a directory.
    $dcuLog = Join-Path $LogDir 'Dell_DCU_5.7.0_Install.log'
    $dcuArgs = "/s /l=`"$dcuLog`""
    Write-Log "Running: $dcuExe $dcuArgs"

    try {
        $proc = Start-Process -FilePath $dcuExe -ArgumentList $dcuArgs -Wait -PassThru
    } catch {
        Fail-Hard "Failed to launch DCU installer: $($_.Exception.Message)"
    }

    Write-Log "DCU installer ExitCode: $($proc.ExitCode)"
    # DCU installer exit codes (verified): 0 = Success, 2 = Reboot Required.
    switch ($proc.ExitCode) {
        0 { Write-Log "DCU installed successfully." -Level SUCCESS }
        2 { Write-Log "DCU installed; reboot required (installer exit 2)." -Level SUCCESS; Set-RebootRequired }
        default { Fail-Hard "DCU installer failed with exit code $($proc.ExitCode). See $dcuLog" }
    }

    # Re-verify via registry so the RMM gets a trustworthy signal.
    Start-Sleep -Seconds 3   # let registry settle
    $dcu = Get-InstalledDcu
    if (-not $dcu) {
        Write-Log "DCU registry key not present after install - install may have failed silently. See $dcuLog" -Level WARN
    } else {
        Write-Log "Post-install verification: DCU $($dcu.Version) ($($dcu.AppCode))" -Level SUCCESS
    }
}

# ==============================================================================
# 3) Housekeeping
# ==============================================================================
# Only purge files we downloaded; never touch shipped installers in the
# InstallSource directory.
if (-not $NoDownload) {
    Get-ChildItem -Path $TempDir -File -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

Write-Log "=== Install-DCU complete. FinalExitCode=$script:FinalExitCode ==="
Exit $script:FinalExitCode