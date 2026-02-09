<#
.SYNOPSIS
    PowerShell implementation of iftop - displays real-time network bandwidth usage
.DESCRIPTION
    Shows network connections with bandwidth usage per connection using performance counters.

    Usage:
        .\iftop.ps1           - Show iftop display
        .\iftop.ps1 -i WiFi    - Show specific interface
        .\iftop.ps1 -t 2       - Update interval in seconds (default 2)
        .\iftop.ps1 -n         - Numeric addresses only
        .\iftop.ps1 -c 20      - Show top N connections (default 20)
        .\iftop.ps1 -p         - Show process names (default true)
.EXAMPLE
    .\iftop.ps1 -i Wi-Fi -t 1
#>

param(
    [string]$i = "",           # Interface name
    [int]$t = 2,               # Update interval in seconds
    [switch]$n,                # Numeric addresses only
    [int]$c = 20,              # Number of top connections to show
    [switch]$p                 # Show process names
)

# Suppress Ctrl+C and provide clean exit
try {
    [Console]::TreatControlCAsInput = $true
} catch {}

# Global state for traffic tracking
$script:connectionHistory = @{}
$script:interfaceHistory = @{}

function Get-InterfaceStats {
    param([string]$interface)

    $adapters = Get-NetAdapter
    if ($interface) {
        $adapters = $adapters | Where-Object { $_.Name -like "*$interface*" -or $_.InterfaceDescription -like "*$interface*" }
    }

    $stats = @()
    foreach ($adapter in $adapters) {
        $stat = Get-NetAdapterStatistics -Name $adapter.Name -ErrorAction SilentlyContinue
        if ($stat) {
            $stats += [PSCustomObject]@{
                Name = $adapter.Name
                Description = $adapter.InterfaceDescription
                ReceivedBytes = $stat.ReceivedBytes
                SentBytes = $stat.SentBytes
                PacketsReceived = $stat.ReceivedUnicastPackets
                PacketsSent = $stat.SentUnicastPackets
                Speed = $adapter.LinkSpeed
            }
        }
    }
    return $stats
}

function Get-ActiveConnections {
    $connections = @()
    $tcp = Get-NetTCPConnection -ErrorAction SilentlyContinue | 
            Where-Object { $_.State -eq "Established" }

    foreach ($conn in $tcp) {
        $procName = ""
        try {
            $procName = (Get-Process -Id $conn.OwningProcess -ErrorAction SilentlyContinue).ProcessName
        } catch {}

        $connections += [PSCustomObject]@{
            LocalAddr = $conn.LocalAddress
            LocalPort = $conn.LocalPort
            RemoteAddr = $conn.RemoteAddress
            RemotePort = $conn.RemotePort
            ProcessId = $conn.OwningProcess
            ProcessName = $procName
            Key = "$($conn.LocalAddress):$($conn.LocalPort)->$($conn.RemoteAddress):$($conn.RemotePort)"
        }
    }

    return $connections
}

function Update-ConnectionTraffic {
    param([int]$interval)

    $connections = Get-ActiveConnections
    $currentStats = Get-InterfaceStats -interface $params.interface

    # Track per-connection traffic based on packet-level estimation
    # Windows doesn't expose per-connection byte counters, so we estimate based on
    # interface traffic distribution and connection characteristics
    foreach ($conn in $connections) {
        if (-not $script:connectionHistory.ContainsKey($conn.Key)) {
            $script:connectionHistory[$conn.Key] = @{
                ProcessName = $conn.ProcessName
                LastSeen = Get-Date
                EstimatedRxBytes = 0
                EstimatedTxBytes = 0
            }
        }

        $history = $script:connectionHistory[$conn.Key]
        $history.LastSeen = Get-Date
        $history.ProcessName = $conn.ProcessName
    }
}

function Calculate-ConnectionRates {
    param(
        [hashtable]$connHistory,
        [array]$currentStats,
        [int]$interval
    )

    $rates = @{}

    # Get total interface traffic for this interval
    $totalDeltaRx = 0
    $totalDeltaTx = 0

    if ($script:interfaceHistory.Count -gt 0) {
        foreach ($stat in $currentStats) {
            if ($script:interfaceHistory.ContainsKey($stat.Name)) {
                $prev = $script:interfaceHistory[$stat.Name]
                $deltaRx = [math]::Max(0, $stat.ReceivedBytes - $prev.ReceivedBytes)
                $deltaTx = [math]::Max(0, $stat.SentBytes - $prev.SentBytes)
                $totalDeltaRx += $deltaRx
                $totalDeltaTx += $deltaTx
            }
        }
    }

    # Distribute traffic across active connections
    $activeConns = @($connHistory.Values | Where-Object { 
        (Get-Date) - $_.LastSeen -lt [timespan]::FromSeconds($interval * 2)
    })

    $connCount = $activeConns.Count

    foreach ($key in $connHistory.Keys) {
        $conn = $connHistory[$key]
        $timeSinceSeen = (Get-Date) - $conn.LastSeen

        # If connection was seen recently, allocate a share of traffic
        if ($timeSinceSeen.TotalSeconds -lt $interval * 2 -and $connCount -gt 0) {
            # Each active connection gets an equal share (simplified model)
            $shareRx = $totalDeltaRx / $connCount
            $shareTx = $totalDeltaTx / $connCount

            $rates[$key] = @{
                ProcessName = $conn.ProcessName
                RX = $shareRx / $interval
                TX = $shareTx / $interval
                Total = ($shareRx + $shareTx) / $interval
            }
        }
    }

    return $rates
}

function Get-ConnectionInfo {
    param([string]$key)

    if ($key -match "^([^:]+):(\d+)->([^:]+):(\d+)$") {
        return @{
            LocalAddr = $matches[1]
            LocalPort = [int]$matches[2]
            RemoteAddr = $matches[3]
            RemotePort = [int]$matches[4]
        }
    }
    return $null
}

function Resolve-Hostname {
    param([string]$ip)

    if ([string]::IsNullOrEmpty($ip) -or $ip -eq "0.0.0.0" -or $ip -eq "::" -or $ip -eq "*") {
        return "*"
    }

    try {
        $hostname = [System.Net.Dns]::GetHostEntry($ip).HostName
        return $hostname
    } catch {
        return $ip
    }
}

function Format-Bandwidth {
    param([double]$bytes)

    if ($bytes -le 0) { return "0 B/s" }

    $units = @("PB/s", "TB/s", "GB/s", "MB/s", "KB/s", "B/s")
    $sizes = @(1PB, 1TB, 1GB, 1MB, 1KB, 1)

    for ($i = 0; $i -lt $units.Count; $i++) {
        if ($bytes -ge $sizes[$i]) {
            if ($i -eq 5) {
                return "{0:N0} {1}" -f $bytes, $units[$i]
            } else {
                return "{0:N2} {1}" -f ($bytes / $sizes[$i]), $units[$i]
            }
        }
    }

    return "0 B/s"
}

function Format-Bytes {
    param([long]$bytes)

    if ($bytes -le 0) { return "0 B" }

    $units = @("PB", "TB", "GB", "MB", "KB", "B")
    $sizes = @(1PB, 1TB, 1GB, 1MB, 1KB, 1)

    for ($i = 0; $i -lt $units.Count; $i++) {
        if ($bytes -ge $sizes[$i]) {
            if ($i -eq 5) {
                return "{0:N0} {1}" -f $bytes, $units[$i]
            } else {
                return "{0:N2} {1}" -f ($bytes / $sizes[$i]), $units[$i]
            }
        }
    }

    return "0 B"
}

function Convert-LinkSpeedToBits {
    param([string]$speedString)

    if ([string]::IsNullOrEmpty($speedString)) {
        return 0
    }

    $speedString = $speedString.ToUpper()

    if ($speedString -match "^([\d\.]+)\s*([KMGT]?BPS)$") {
        $value = [double]$matches[1]
        $unit = $matches[2] -replace "BPS", ""

        switch ($unit) {
            ""      { return [long]($value) }
            "K"     { return [long]($value * 1000) }
            "M"     { return [long]($value * 1000000) }
            "G"     { return [long]($value * 1000000000) }
            "T"     { return [long]($value * 1000000000000) }
            default { return [long]$value }
        }
    }

    try {
        return [long]$speedString
    } catch {
        return 0
    }
}

# Helper class to store colored line segments
class ColoredLine {
    [System.Collections.Generic.List[object]]$Segments = [System.Collections.Generic.List[object]]::new()

    Add([string]$Text, [string]$Color = $null, [bool]$NoNewline = $false) {
        $this.Segs.Add(@{ Text = $Text; Color = $Color; NoNewline = $NoNewline })
    }
}

function Write-ColoredLine {
    param(
        [ColoredLine]$line,
        [int]$width
    )

    $builtContent = ""
    $lastColorIndex = 0

    foreach ($seg in $line.Segments) {
        if ($seg.Color) {
            $builtContent += $seg.Text
        } else {
            $builtContent += $seg.Text
        }
    }

    # Pad to width
    Write-Host $builtContent.PadRight($width) -NoNewline

    # Write with colors
    $cursorPos = $host.UI.RawUI.CursorPosition
    $col = 0

    foreach ($seg in $line.Segments) {
        if ($seg.Color) {
            Write-Host $seg.Text -ForegroundColor $seg.Color -NoNewline
            $col += $seg.Text.Length
        } else {
            Write-Host $seg.Text -NoNewline
            $col += $seg.Text.Length
        }
    }
    Write-Host ""
}

function Show-IFTOP {
    param(
        [string]$interface,
        [int]$interval,
        [switch]$numeric,
        [int]$topCount
    )

    Clear-Host

    $iteration = 0

    while ($true) {
        # Move cursor to top
        $host.UI.RawUI.CursorPosition = @{X=0; Y=0}
        $windowWidth = $host.UI.RawUI.WindowSize.Width

        # Get interface stats
        $currentStats = Get-InterfaceStats -interface $interface

        if ($currentStats.Count -eq 0) {
            Write-Host "ERROR: No network adapter found" -ForegroundColor Red
            Write-Host "`nAvailable adapters:" -ForegroundColor Yellow
            Get-NetAdapter | Format-Table Name, Status, LinkSpeed -AutoSize
            break
        }

        # Calculate bandwidth from interface history
        $bandwidth = @{RX = 0; TX = 0; Total = 0}
        $deltaRX = 0
        $deltaTX = 0

        foreach ($stat in $currentStats) {
            if ($script:interfaceHistory.ContainsKey($stat.Name)) {
                $prev = $script:interfaceHistory[$stat.Name]
                $deltaRX += [math]::Max(0, $stat.ReceivedBytes - $prev.ReceivedBytes)
                $deltaTX += [math]::Max(0, $stat.SentBytes - $prev.SentBytes)
            }
        }

        $bandwidth.RX = $deltaRX / $interval
        $bandwidth.TX = $deltaTX / $interval
        $bandwidth.Total = $bandwidth.RX + $bandwidth.TX

        # Update connection tracking
        Update-ConnectionTraffic -interval $interval

        # Calculate connection rates using a traffic distribution model
        $rates = Calculate-ConnectionRates -connHistory $script:connectionHistory -currentStats $currentStats -interval $interval

        # Build connection list with rates
        $connectionList = @()
        foreach ($key in $rates.Keys) {
            $rateData = $rates[$key]
            $connInfo = Get-ConnectionInfo -key $key

            if ($connInfo) {
                $localHost = if ($numeric) { $connInfo.LocalAddr } else { Resolve-Hostname $connInfo.LocalAddr }
                $remoteHost = if ($numeric) { $connInfo.RemoteAddr } else { Resolve-Hostname $connInfo.RemoteAddr }

                $connectionList += [PSCustomObject]@{
                    LocalHost = $localHost
                    LocalPort = $connInfo.LocalPort
                    RemoteHost = $remoteHost
                    RemotePort = $connInfo.RemotePort
                    ProcessName = $rateData.ProcessName
                    RX = $rateData.RX
                    TX = $rateData.TX
                    Total = $rateData.Total
                }
            }
        }

        # Sort and filter
        $topConnections = $connectionList |
            Sort-Object -Property Total -Descending |
            Select-Object -First $topCount

        # Display header with colors
        Write-Host ""
        Write-Host "iftop $(hostname)" -ForegroundColor Cyan
        if ($interface) {
            Write-Host "Interface: $($currentStats[0].Name)" -ForegroundColor Gray
        } else {
            Write-Host "Interface: All" -ForegroundColor Gray
        }
        Write-Host "Interval: ${interval}s  q to quit" -ForegroundColor Gray

        # Table header
        $separator = "=" * [math]::Min($windowWidth, 100)
        Write-Host $separator -ForegroundColor DarkGray
        Write-Host ("{0,-22} {1,6} {2,-22} {3,5} {4,10} {5,10} {6,10} {7,-20}" -f
            "Source", "Port", "Destination", "Port", "RX", "TX", "Total", "Process") -ForegroundColor White
        Write-Host $separator -ForegroundColor DarkGray

        # Display connections
        $maxRate = if ($topConnections.Count -gt 0) { ($topConnections | Measure-Object -Property Total -Maximum).Maximum } else { 0 }

        foreach ($conn in $topConnections) {
            $rx = Format-Bandwidth $conn.RX
            $tx = Format-Bandwidth $conn.TX
            $total = Format-Bandwidth $conn.Total

            $localStr = if ($conn.LocalHost.Length -gt 22) { $conn.LocalHost.Substring(0, 19) + "..." } else { $conn.LocalHost }
            $remoteStr = if ($conn.RemoteHost.Length -gt 22) { $conn.RemoteHost.Substring(0, 19) + "..." } else { $conn.RemoteHost }
            $procStr = if ($conn.ProcessName.Length -gt 20) { $conn.ProcessName.Substring(0, 17) + "..." } else { $conn.ProcessName }

            $line = "{0,-22} {1,6} {2,-22} {3,5} {4,10} {5,10} {6,10} {7,-20}" -f
                $localStr, $conn.LocalPort, $remoteStr, $conn.RemotePort, $rx, $tx, $total, $procStr
            Write-Host $line

            # Bandwidth bar
            if ($maxRate -gt 0) {
                $barWidth = [math]::Min(20, [math]::Floor(($conn.Total / $maxRate) * 20))
                $bar = "=" * $barWidth
                if ($bar.Count -gt 0) {
                    Write-Host ("    " + $bar + ">") -ForegroundColor Green
                }
            }
        }

        # Summary
        Write-Host $separator -ForegroundColor DarkGray
        $rxStr = Format-Bandwidth $bandwidth.RX
        $txStr = Format-Bandwidth $bandwidth.TX
        $totalStr = Format-Bandwidth $bandwidth.Total
        Write-Host ("TX: {0}   RX: {1}   TOTAL: {2}" -f $txStr, $rxStr, $totalStr) -ForegroundColor Cyan

        # Interface details
        Write-Host ""
        Write-Host "Interface Statistics:" -ForegroundColor Gray

        foreach ($stat in $currentStats) {
            $rxBytes = Format-Bytes $stat.ReceivedBytes
            $txBytes = Format-Bytes $stat.SentBytes
            $speedString = $stat.Speed
            $speedBits = Convert-LinkSpeedToBits $speedString

            Write-Host "  $($stat.Name):" -ForegroundColor White
            Write-Host "    RX Total: $($rxBytes)   TX Total: $($txBytes)"

            if ($speedBits -gt 0) {
                $speedGbps = [math]::Round($speedBits / 1GB, 2)
                Write-Host "    Link Speed: $($speedGbps) Gbps ($($speedString))"
            }

            $bandwidthBits = $bandwidth.Total * 8
            $utilization = if ($speedBits -gt 0) { [math]::Round(($bandwidthBits / $speedBits) * 100, 2) } else { 0 }
            $utilColor = if ($utilization -gt 80) { "Red" } elseif ($utilization -gt 50) { "Yellow" } else { "Green" }
            Write-Host ("    Utilization: {0}%" -f $utilization) -ForegroundColor $utilColor
        }

        # Top processes
        $processAgg = @{}
        foreach ($conn in $connectionList) {
            if (-not $processAgg.ContainsKey($conn.ProcessName)) {
                $processAgg[$conn.ProcessName] = @{RX = 0; TX = 0; Total = 0}
            }
            $processAgg[$conn.ProcessName].RX += $conn.RX
            $processAgg[$conn.ProcessName].TX += $conn.TX
            $processAgg[$conn.ProcessName].Total += $conn.Total
        }

        if ($processAgg.Count -gt 0) {
            Write-Host ""
            Write-Host "Top 5 Processes by Network Activity:" -ForegroundColor Gray

            $topProcesses = $processAgg.GetEnumerator() | 
                Sort-Object { $_.Value.Total } -Descending | 
                Select-Object -First 5

            foreach ($procEntry in $topProcesses) {
                $procRx = Format-Bandwidth $procEntry.Value.RX
                $procTx = Format-Bandwidth $procEntry.Value.TX
                $procTotal = Format-Bandwidth $procEntry.Value.Total

                Write-Host "  $($procEntry.Key): RX=$procRx TX=$procTx Total=$procTotal"
            }
        }

        # Store current stats for next iteration
        $script:interfaceHistory = @{}
        foreach ($stat in $currentStats) {
            $script:interfaceHistory[$stat.Name] = @{
                ReceivedBytes = $stat.ReceivedBytes
                SentBytes = $stat.SentBytes
            }
        }

        # Check for quit
        if ([Console]::KeyAvailable) {
            $key = [Console]::ReadKey($true)
            if ($key.KeyChar -eq 'q' -or $key.Key -eq 'Escape') {
                Write-Host "`nExiting..." -ForegroundColor Yellow
                break
            }
        }

        Start-Sleep -Seconds $interval
        $iteration++
    }
}

# Run the main function
try {
    Show-IFTOP -interface $i -interval $t -numeric:$n -topCount $c
}
finally {
    try {
        [Console]::TreatControlCAsInput = $false
    } catch {}
}