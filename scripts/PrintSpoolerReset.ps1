<#
.SYNOPSIS
Safely clears and resets the Windows Print Spooler.

.DESCRIPTION
Stops the Print Spooler service, clears queued spool files, and starts the
service again.

.COMPATIBILITY
Windows PowerShell 5.1
Windows Server 2012-2022

.LICENSE
MIT License

.AUTHOR
Luke

.VERSION
1.0.0
#>

# ------------------------------------------------------------
# Script settings
# ------------------------------------------------------------
$ServiceName = "Spooler"
$SpoolPath = Join-Path $env:SystemRoot "System32\spool\PRINTERS"
$TimeoutSeconds = 30
$HadErrors = $false

$MutexName = "Global\PrintSpoolerResetMutex"
$Mutex = $null
$HasMutex = $false

# ------------------------------------------------------------
# Cleanup and exit helper
# ------------------------------------------------------------
function Exit-Script {
    param (
        [int] $ExitCode
    )

    if (($null -ne $Mutex) -and ($HasMutex -eq $true)) {
        try {
            $Mutex.ReleaseMutex()
        }
        catch {
        }
    }

    if ($null -ne $Mutex) {
        try {
            $Mutex.Dispose()
        }
        catch {
        }
    }

    exit $ExitCode
}

# ------------------------------------------------------------
# Administrator check
# ------------------------------------------------------------
$CurrentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
$Principal = New-Object Security.Principal.WindowsPrincipal($CurrentIdentity)

if (-not $Principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "This script must be run as Administrator." -ForegroundColor Red
    exit 1
}

# ------------------------------------------------------------
# Concurrency protection
# ------------------------------------------------------------
try {
    $Mutex = New-Object System.Threading.Mutex($false, $MutexName)
}
catch {
    Write-Host "Failed to create mutex: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

try {
    $HasMutex = $Mutex.WaitOne(0, $false)
}
catch [System.Threading.AbandonedMutexException] {
    $HasMutex = $true
}
catch {
    Write-Host "Failed to acquire mutex: $($_.Exception.Message)" -ForegroundColor Red
    Exit-Script 1
}

if ($HasMutex -ne $true) {
    Write-Host "Another Print Spooler reset is already running. Exiting safely." -ForegroundColor Yellow
    Exit-Script 0
}

Write-Host "Print Spooler reset starting..." -ForegroundColor Cyan

# ------------------------------------------------------------
# Validate service exists
# ------------------------------------------------------------
try {
    $Service = Get-Service -Name $ServiceName -ErrorAction Stop
}
catch {
    Write-Host "Print Spooler service was not found: $($_.Exception.Message)" -ForegroundColor Red
    Exit-Script 1
}

# ------------------------------------------------------------
# Stop Print Spooler
# ------------------------------------------------------------
try {
    $Service.Refresh()

    if ($Service.Status.ToString() -ne "Stopped") {
        Write-Host "Stopping Print Spooler service..." -ForegroundColor Yellow
        Stop-Service -Name $ServiceName -Force -ErrorAction Stop

        $StopWait = 0

        while ($StopWait -lt $TimeoutSeconds) {
            Start-Sleep -Seconds 1
            $StopWait = $StopWait + 1

            $Service.Refresh()

            if ($Service.Status.ToString() -eq "Stopped") {
                break
            }
        }

        $Service.Refresh()

        if ($Service.Status.ToString() -ne "Stopped") {
            Write-Host "Print Spooler did not stop within $TimeoutSeconds seconds." -ForegroundColor Red
            Exit-Script 1
        }

        Write-Host "Print Spooler stopped successfully." -ForegroundColor Green
    }
    else {
        Write-Host "Print Spooler is already stopped." -ForegroundColor Yellow
    }
}
catch {
    Write-Host "Failed to stop Print Spooler: $($_.Exception.Message)" -ForegroundColor Red
    Exit-Script 1
}

# ------------------------------------------------------------
# Clear spool folder
# ------------------------------------------------------------
Write-Host "Clearing spool folder: $SpoolPath" -ForegroundColor Yellow

if (Test-Path -Path $SpoolPath) {
    try {
        $Items = Get-ChildItem -Path $SpoolPath -Force -ErrorAction Stop
    }
    catch {
        Write-Host "Failed to enumerate spool folder: $($_.Exception.Message)" -ForegroundColor Red
        $HadErrors = $true
        $Items = $null
    }

    if ($null -eq $Items) {
        Write-Host "Spool folder is already empty or no items were returned." -ForegroundColor Green
    }
    else {
        foreach ($Item in $Items) {
            try {
                Remove-Item -Path $Item.FullName -Force -Recurse -ErrorAction Stop
                Write-Host "Removed: $($Item.Name)" -ForegroundColor Gray
            }
            catch {
                $HadErrors = $true
                Write-Host "Failed to remove item: $($Item.FullName)" -ForegroundColor Yellow
                Write-Host "Reason: $($_.Exception.Message)" -ForegroundColor Yellow
            }
        }
    }
}
else {
    Write-Host "Spool folder not found at expected path: $SpoolPath" -ForegroundColor Red
    $HadErrors = $true
}

# ------------------------------------------------------------
# Start Print Spooler
# ------------------------------------------------------------
try {
    Write-Host "Starting Print Spooler service..." -ForegroundColor Yellow
    Start-Service -Name $ServiceName -ErrorAction Stop

    $StartWait = 0

    while ($StartWait -lt $TimeoutSeconds) {
        Start-Sleep -Seconds 1
        $StartWait = $StartWait + 1

        $Service.Refresh()

        if ($Service.Status.ToString() -eq "Running") {
            break
        }
    }

    $Service.Refresh()

    if ($Service.Status.ToString() -ne "Running") {
        Write-Host "Print Spooler did not start within $TimeoutSeconds seconds." -ForegroundColor Red
        Exit-Script 1
    }

    Write-Host "Print Spooler started successfully." -ForegroundColor Green
}
catch {
    Write-Host "Failed to start Print Spooler: $($_.Exception.Message)" -ForegroundColor Red
    Exit-Script 1
}

# ------------------------------------------------------------
# Final result
# ------------------------------------------------------------
if ($HadErrors -eq $true) {
    Write-Host "Print Spooler reset completed with warnings." -ForegroundColor Yellow
    Exit-Script 2
}
else {
    Write-Host "Print Spooler reset complete." -ForegroundColor Cyan
    Exit-Script 0
}
