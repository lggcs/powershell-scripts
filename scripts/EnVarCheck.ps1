<#
.SYNOPSIS
    Gathers and displays all user and system environment variables.
    Attempts to load and unload user hives for users not logged in presently.

.LICENSE
MIT License

.AUTHOR
Luke

.VERSION
1.0.0
#>

# =========================================================================
# 1. FIXED: DUMP GLOBAL SYSTEM VARIABLES (ComSpec, DriverData, PATH, etc.)
# =========================================================================
Write-Host "`n=========================================" -ForegroundColor Magenta
Write-Host " SYSTEM-WIDE ENVIRONMENT VARIABLES (GLOBAL)" -ForegroundColor Magenta
Write-Host "=========================================" -ForegroundColor Magenta

# Get-ItemProperty targeting the actual properties inside the key
$SysPath = "Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\Session Manager\Environment"
(Get-ItemProperty -Path $SysPath).psobject.properties | 
    Where-Object { $_.Name -notmatch "PSPath|PSParentPath|PSChildName|PSDrive|PSProvider" } |
    Select-Object @{N="Name";E={$_.Name}}, @{N="Value";E={$_.Value}} | Format-Table -AutoSize


# =========================================================================
# 2. ENUMERATE ALL USER PROFILES & CAPTURE USER VARIABLES
# =========================================================================
$Profiles = Get-CimInstance -ClassName Win32_UserProfile | Where-Object { $_.Special -eq $false -and $_.LocalPath -like "*\Users\*" }

foreach ($Profile in $Profiles) {
    $Username = Split-Path $Profile.LocalPath -Leaf
    $UserSID = $Profile.SID
    
    Write-Host "`n=========================================" -ForegroundColor Cyan
    Write-Host " USER ENVIRONMENT PROFILE: $Username" -ForegroundColor Cyan
    Write-Host "=========================================" -ForegroundColor Cyan

    $IsActive = Test-Path "Registry::HKEY_USERS\$UserSID"
    $RegPrefix = "Registry::HKEY_USERS\$UserSID"

    if (-not $IsActive) {
        $NtUserPath = Join-Path $Profile.LocalPath "NTUSER.DAT"
        if (Test-Path $NtUserPath) {
            reg load "HKU\Temp_$Username" $NtUserPath | Out-Null
            $RegPrefix = "Registry::HKEY_USERS\Temp_$Username"
        } else {
            Write-Host " [!] Could not load registry file for $Username" -ForegroundColor Red
            continue
        }
    }

    # Gather Standard User Variables (using Get-ItemProperty properties collection)
    $UserVars = @{}
    $UserEnvKey = "$RegPrefix\Environment"
    if (Test-Path $UserEnvKey) {
        (Get-ItemProperty -Path $UserEnvKey).psobject.properties | 
            Where-Object { $_.Name -notmatch "PSPath|PSParentPath|PSChildName|PSDrive|PSProvider" } |
            ForEach-Object { $UserVars[$_.Name] = $_.Value }
    }

    # Explicitly resolve the USER PATH strings
    $RawPath = $UserVars["Path"]
    $ExpandedPath = if ($RawPath) { $RawPath -replace "%USERPROFILE%", $Profile.LocalPath } else { "[Not Set]" }

    # Explicitly resolve USER TEMP / TMP
    $RawTemp = $UserVars["TEMP"]
    $ExpandedTemp = if ($RawTemp) { $RawTemp -replace "%USERPROFILE%", $Profile.LocalPath } else { "$($Profile.LocalPath)\AppData\Local\Temp" }

    # Probing OneDrive configurations hidden inside the Software branch
    $OneDrivePath = "[Not Running / Not Configured]"
    $ODSettingsPath = "$RegPrefix\Software\Microsoft\OneDrive\Accounts\Business1"
    $ODPersonalPath = "$RegPrefix\Software\Microsoft\OneDrive\Accounts\Personal"
    
    if (Test-Path $ODSettingsPath) {
        $OneDrivePath = (Get-ItemProperty -Path $ODSettingsPath -ErrorAction SilentlyContinue).UserFolder
    } elseif (Test-Path $ODPersonalPath) {
        $OneDrivePath = (Get-ItemProperty -Path $ODPersonalPath -ErrorAction SilentlyContinue).UserFolder
    } elseif (Test-Path (Join-Path $Profile.LocalPath "OneDrive")) {
        $OneDrivePath = Join-Path $Profile.LocalPath "OneDrive"
    }

    # Output the core summary table
    [PSCustomObject]@{
        "User Profile"   = $Username
        "OneDrive Path"  = $OneDrivePath
        "TEMP Directory" = $ExpandedTemp
        "User Path"      = $ExpandedPath
    } | Format-List

    # Dump remaining custom user variables
    Write-Host " Additional Custom User Variables:" -ForegroundColor Gray
    if ($UserVars.Count -gt 0) {
        $UserVars.GetEnumerator() | Where-Object { $_.Key -notin @("Path", "TEMP", "TMP") } | 
            Select-Object @{N="Name";E={$_.Key}}, @{N="Value";E={$_.Value}} | Format-Table -AutoSize
    } else {
        Write-Host " None found." -ForegroundColor DarkGray
    }

    # Unload the hive safely if manually mounted
    if (-not $IsActive) {
        [GC]::Collect()
        reg unload "HKU\Temp_$Username" | Out-Null
    }
}
