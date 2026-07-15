<#
.SYNOPSIS
Safely synchronizes Windows system time with reliable NTP sources.

.DESCRIPTION
Queries multiple NTP servers, measures clock drift, and only corrects
system time when the offset exceeds a configurable threshold.
Includes concurrency protection to prevent multiple instances from
running simultaneously.

.LICENSE
MIT License

.AUTHOR
Luke

.VERSION
1.0.0
#>

# Requires Administrator privileges
if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "This script must be run as an Administrator!"
    exit 1
}

# ------------------------------------------------------------
# Concurrency protection
# Prevents multiple instances from modifying time at once
# ------------------------------------------------------------
$MutexName = "Global\TimeSyncScriptMutex"
$Mutex = $null
$HasMutex = $false

try {
    $Mutex = New-Object System.Threading.Mutex($false, $MutexName)

    try {
        $HasMutex = $Mutex.WaitOne(0, $false)
    }
    catch [System.Threading.AbandonedMutexException] {
        # Previous process exited unexpectedly while holding the mutex.
        # Current process now owns it.
        $HasMutex = $true
    }

    if (-not $HasMutex) {
        Write-Host "Another instance is already running. Exiting safely." -ForegroundColor Yellow
        exit 0
    }

    # ------------------------------------------------------------
    # Reliable NTP servers
    # ------------------------------------------------------------
    $TimeServers = @(
        "0.us.pool.ntp.org",
        "1.us.pool.ntp.org",
        "time.windows.com",
        "time.google.com"
    )

    $TargetServer = $null
    $NetworkTime = $null

    Write-Host "Querying time servers for raw network time..." -ForegroundColor Cyan

    foreach ($Server in $TimeServers) {
        $Socket = $null

        try {
            # Query NTP server over UDP port 123 using a 48-byte NTP packet
            $NtpData = New-Object byte[] 48
            $NtpData[0] = 0x1B

            $AddressList = [System.Net.Dns]::GetHostAddresses($Server)

            $Address = $AddressList |
                Where-Object { $_.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork } |
                Select-Object -First 1

            if ($null -eq $Address) {
                throw "No IPv4 address found for $Server"
            }

            $EndPoint = New-Object System.Net.IPEndPoint($Address, 123)

            $Socket = New-Object System.Net.Sockets.Socket(
                [System.Net.Sockets.AddressFamily]::InterNetwork,
                [System.Net.Sockets.SocketType]::Dgram,
                [System.Net.Sockets.ProtocolType]::Udp
            )

            $Socket.SendTimeout = 2000
            $Socket.ReceiveTimeout = 2000

            $Socket.Connect($EndPoint)
            [void] $Socket.Send($NtpData)
            [void] $Socket.Receive($NtpData)

            # NTP transmit timestamp starts at byte 40.
            # NTP is big-endian. Windows BitConverter expects little-endian.
            $IntBytes = [byte[]] ($NtpData[43], $NtpData[42], $NtpData[41], $NtpData[40])
            $FracBytes = [byte[]] ($NtpData[47], $NtpData[46], $NtpData[45], $NtpData[44])

            $IntPart = [System.BitConverter]::ToUInt32($IntBytes, 0)
            $FracPart = [System.BitConverter]::ToUInt32($FracBytes, 0)

            # Convert NTP timestamp to milliseconds from Jan 1, 1900 UTC
            $Milliseconds = ($IntPart * 1000) + (($FracPart * 1000) / 4294967296)

            $NtpEpochLocal = Get-Date -Year 1900 -Month 1 -Day 1 -Hour 0 -Minute 0 -Second 0
            $NtpEpochUtc = [System.DateTime]::SpecifyKind($NtpEpochLocal, [System.DateTimeKind]::Utc)

            $NetworkTime = $NtpEpochUtc.AddMilliseconds($Milliseconds).ToLocalTime()
            $TargetServer = $Server

            Write-Host "Successfully retrieved time from $TargetServer" -ForegroundColor Green
            break
        }
        catch {
            Write-Host "Failed to reach $Server, trying next... $($_.Exception.Message)" -ForegroundColor Yellow
        }
        finally {
            if ($null -ne $Socket) {
                try {
                    $Socket.Close()
                }
                catch {
                }

                try {
                    $Socket.Dispose()
                }
                catch {
                }
            }
        }
    }

    if ($null -eq $NetworkTime) {
        Write-Error "All time servers failed or were unreachable."
        exit 1
    }

    # ------------------------------------------------------------
    # Calculate offset
    # ------------------------------------------------------------
    $LocalTime = Get-Date
    $Offset = $NetworkTime - $LocalTime
    $OffsetSeconds = [System.Math]::Abs($Offset.TotalSeconds)

    Write-Host "Local Time:    $LocalTime"
    Write-Host "Network Time:  $NetworkTime"
    Write-Host "Current Offset: $OffsetSeconds seconds" -ForegroundColor Yellow

    # ------------------------------------------------------------
    # If already within normal sync range, do not override time
    # ------------------------------------------------------------
    if ($OffsetSeconds -le 2) {
        Write-Host "System time is already within 2 seconds of network time." -ForegroundColor Green
        Write-Host "Skipping Set-Date, Windows Time Service restart, and forced resync." -ForegroundColor Green

        Write-Host ""
        Write-Host "Verification check against ${TargetServer}:" -ForegroundColor Cyan
        w32tm /stripchart /computer:$TargetServer /samples:1

        exit 0
    }

    # ------------------------------------------------------------
    # Large offset detected, manually correct system clock
    # ------------------------------------------------------------
    Write-Host "Offset exceeds 2 seconds. Setting system time manually..." -ForegroundColor Cyan
    Set-Date -Date $NetworkTime

    # ------------------------------------------------------------
    # Configure Windows Time Service
    # ------------------------------------------------------------
    Write-Host "Configuring Windows Time Service..." -ForegroundColor Cyan

    $ManualPeerList = @()

    foreach ($TimeServer in $TimeServers) {
        $ManualPeerList += "$TimeServer,0x8"
    }

    $ServerListString = $ManualPeerList -join " "

    w32tm /config /manualpeerlist:"$ServerListString" /syncfromflags:manual /reliable:YES /update

    Restart-Service w32time -Force

    # ------------------------------------------------------------
    # Final official Windows Time Service sync
    # ------------------------------------------------------------
    Write-Host "Executing final w32tm resync..." -ForegroundColor Cyan
    Start-Sleep -Seconds 2

    w32tm /resync /force

    # ------------------------------------------------------------
    # Verify accuracy
    # ------------------------------------------------------------
    Write-Host ""
    Write-Host "Verification check against ${TargetServer}:" -ForegroundColor Cyan
    w32tm /stripchart /computer:$TargetServer /samples:3
}
finally {
    if (($null -ne $Mutex) -and $HasMutex) {
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
}
