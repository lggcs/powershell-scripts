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

# Global state for tracking network I/O rates
$script:processIoHistory = @{}
$script:maxHistoryEntries = 3  # Keep last 3 samples for smooth averaging

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
                ReceivedUnicastPackets = $stat.ReceivedUnicastPackets
                SentUnicastPackets = $stat.SentUnicastPackets
                Speed = $adapter.LinkSpeed
            }
        }
    }
    return $stats
}

function Get-ProcessNetworkIO {
    # Get per-process network I/O using .NET Process class
    $processIo = @{}

    try {
        $processes = Get-Process -ErrorAction SilentlyContinue

        foreach ($proc in $processes) {
            try {
                # Try to get network statistics from performance counters
                $procObj = [System.Diagnostics.Process]::GetProcessById($proc.Id)

                # Get network bytes sent/received (Process.TotalProcessorTime is network related in some contexts)
                # But we need different approach for Windows - use ETW or estimate
                # Alternative: count TCP segments per process
                $processIo[$proc.Id] = @{
                    Id = $proc.Id
                    Name = $proc.ProcessName
                    BytesSent = 0
                    BytesReceived = 0
                    LastUpdate = Get-Date
                }
            } catch {
                continue
            }
        }
    } catch {}

    return $processIo
}

function Get-TCPConnectionEstimates {
    # Get TCP connections and estimate traffic based on state and activity
    $connections = @()

    $tcp = Get-NetTCPConnection -ErrorAction SilentlyContinue
    foreach ($conn in $tcp) {
        if ($conn.State -notin @("Established", "Listen", "TimeWait")) {
            continue
        }

        $localHost = if ($n) { $conn.LocalAddress } else { Resolve-Hostname $conn.LocalAddress }
        $remoteHost = if ($n) { $conn.RemoteAddress } else { Resolve-Hostname $conn.RemoteAddress }

        $procName = Get-ProcessName $conn.OwningProcess

        $connections += [PSCustomObject]@{
            Protocol = "TCP"
            LocalHost = $localHost
            LocalPort = $conn.LocalPort
            RemoteHost = $remoteHost
            RemotePort = $conn.RemotePort
            State = $conn.State
            OwningProcess = $conn.OwningProcess
            ProcessName = $procName
            Key = "TCP|$($conn.OwningProcess)|$($localHost)|$($conn.LocalPort)|$($remoteHost)|$($conn.RemotePort)"
        }
    }

    return $connections
}

function Get-ProcessTrafficCounters {
    # Use performance counters to get process-specific network metrics
    $processTraffic = @{}

    try {
        # Get .NET CLR Networking counters for each process
        $categories = Get-Counter -ListSet ".NET CLR Networking" -ErrorAction SilentlyContinue

        if ($categories) {
            $instanceNames = $categories.CounterSet | Select-Object -ExpandProperty Counter

            foreach ($instance in $categories.CounterSet) {
                try {
                    $counters = Get-Counter "\.NET CLR Networking(*)\Bytes Received", `
                                     "\.NET CLR Networking(*)\Bytes Sent" `
                                     -ErrorAction SilentlyContinue

                    if ($counters) {
                        foreach ($sample in $counters.CounterSamples) {
                            if ($sample.InstanceName -notMatch "^total$" -and $sample.InstanceName -match "_(\d+)$") {
                                $processId = [int]$matches[1]

                                if (-not $processTraffic.ContainsKey($processId)) {
                                    $processTraffic[$processId] = @{
                                        BytesReceived = 0
                                        BytesSent = 0
                                        ProcessName = ""
                                    }
                                }

                                if ($sample.Path -match "Bytes Received") {
                                    $processTraffic[$processId].BytesReceived = [long]$sample.CookedValue
                                } elseif ($sample.Path -match "Bytes Sent") {
                                    $processTraffic[$processId].BytesSent = [long]$sample.CookedValue
                                }

                                try {
                                    $procName = (Get-Process -Id $processId -ErrorAction SilentlyContinue).ProcessName
                                    $processTraffic[$processId].ProcessName = $procName
                                } catch {}
                            }
                        }
                    }
                } catch {}
            }
        }
    } catch {}

    # Alternative: Use TCP segment counts as proxy for traffic
    # This works for all processes, not just .NET ones
    $procStats = Get-NetTCPConnection -ErrorAction SilentlyContinue |
                 Group-Object OwningProcess

    foreach ($group in $procStats) {
        $processId = [int]$group.Name
        if (-not $processTraffic.ContainsKey($processId)) {
            $processTraffic[$processId] = @{
                BytesReceived = 0
                BytesSent = 0
                ProcessName = ""
            }
        }

        # Estimate traffic based on connection count and state
        $establishedCount = @($group.Group | Where-Object { $_.State -eq "Established" }).Count
        $timeWaitCount = @($group.Group | Where-Object { $_.State -eq "TimeWait" }).Count

        # Use segment sizes as rough estimate (1440 bytes typical)
        $processTraffic[$processId].EstimatedBytesReceived = $establishedCount * 1440 * 10
        $processTraffic[$processId].EstimatedBytesSent = $establishedCount * 1440 * 10

        try {
            $procName = (Get-Process -Id $processId -ErrorAction SilentlyContinue).ProcessName
            $processTraffic[$processId].ProcessName = $procName
        } catch {}
    }

    return $processTraffic
}

function Update-ProcessIORates {
    # Collect current process traffic data
    $currentTraffic = Get-ProcessTrafficCounters
    $timestamp = Get-Date

    # Update history
    foreach ($processId in $currentTraffic.Keys) {
        if (-not $script:processIoHistory.ContainsKey($processId)) {
            $script:processIoHistory[$processId] = @{
                Samples = @()
                ProcessName = $currentTraffic[$processId].ProcessName
            }
        }

        $sample = @{
            Timestamp = $timestamp
            BytesReceived = $currentTraffic[$processId].BytesReceived
            BytesSent = $currentTraffic[$processId].BytesSent
            EstimatedBytesReceived = $currentTraffic[$processId].EstimatedBytesReceived
            EstimatedBytesSent = $currentTraffic[$processId].EstimatedBytesSent
        }

        $script:processIoHistory[$processId].Samples += $sample

        # Keep only recent samples
        if ($script:processIoHistory[$processId].Samples.Count -gt $script:maxHistoryEntries) {
            $script:processIoHistory[$processId].Samples = $script:processIoHistory[$processId].Samples[-$script:maxHistoryEntries..-1]
        }
    }
}

function Get-ProcessRates {
    param(
        [int]$interval
    )

    $rates = @{}

    foreach ($processId in $script:processIoHistory.Keys) {
        $history = $script:processIoHistory[$processId]

        if ($history.Samples.Count -ge 2) {
            $latest = $history.Samples[-1]
            $earliest = $history.Samples[0]
            $timeDelta = ($latest.Timestamp - $earliest.Timestamp).TotalSeconds

            if ($timeDelta -gt 0) {
                # Use actual bytes if available, fall back to estimated
                $rxBytes = if ($latest.BytesReceived -gt 0 -and $earliest.BytesReceived -gt 0) {
                    [math]::Max(0, $latest.BytesReceived - $earliest.BytesReceived)
                } else {
                    [math]::Max(0, $latest.EstimatedBytesReceived - ($earliest.EstimatedBytesReceived))
                }

                $txBytes = if ($latest.BytesSent -gt 0 -and $earliest.BytesSent -gt 0) {
                    [math]::Max(0, $latest.BytesSent - $earliest.BytesSent)
                } else {
                    [math]::Max(0, $latest.EstimatedBytesSent - ($earliest.EstimatedBytesSent))
                }

                $rates[$processId] = @{
                    ProcessName = $history.ProcessName
                    RX = $rxBytes / $interval
                    TX = $txBytes / $interval
                    Total = ($rxBytes + $txBytes) / $interval
                }
            }
        }
    }

    return $rates
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

function Get-ProcessName {
    param([int]$processId)

    if ($processId -eq 0 -or $processId -eq 4) { return "" }

    try {
        $proc = Get-Process -Id $processId -ErrorAction SilentlyContinue
        if ($proc) { return $proc.ProcessName }
    } catch {}

    return ""
}

function Get-ConnectionBandwidth {
    param(
        [System.Collections.ArrayList]$previousStats,
        [System.Collections.ArrayList]$currentStats,
        [int]$interval
    )

    if ($previousStats.Count -eq 0 -or $currentStats.Count -eq 0) {
        return @{RX = 0; TX = 0; Total = 0}
    }

    $totalRX = 0
    $totalTX = 0

    for ($i = 0; $i -lt $previousStats.Count; $i++) {
        $prev = $previousStats[$i]
        $curr = $currentStats[$i] | Where-Object { $_.Name -eq $prev.Name }

        if ($curr) {
            $rxDelta = [math]::Max(0, $curr.ReceivedBytes - $prev.ReceivedBytes)
            $txDelta = [math]::Max(0, $curr.SentBytes - $prev.SentBytes)
            $totalRX += $rxDelta
            $totalTX += $txDelta
        }
    }

    $rxRate = $totalRX / $interval
    $txRate = $totalTX / $interval
    $totalRate = $rxRate + $txRate

    return @{
        RX = $rxRate
        TX = $txRate
        Total = $totalRate
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

    # Normalize to uppercase for matching
    $speedString = $speedString.ToUpper()

    # Parse strings like "866.7 Mbps", "1 GBPS", "100 Kbps"
    if ($speedString -match "^([\d\.]+)\s*([KMGT]?BPS)$") {
        $value = [double]$matches[1]
        $unit = $matches[2] -replace "BPS", ""

        # Use 1000-based for network speeds (1 Mbps = 1,000,000 bps)
        switch ($unit) {
            ""      { return [long]($value) }                           # bps
            "K"     { return [long]($value * 1000) }                    # Kbps = 1000 bps
            "M"     { return [long]($value * 1000000) }                 # Mbps = 1,000,000 bps
            "G"     { return [long]($value * 1000000000) }              # Gbps = 1,000,000,000 bps
            "T"     { return [long]($value * 1000000000000) }           # Tbps
            default { return [long]$value }
        }
    }

    # Try to convert directly if it's just a number
    try {
        return [long]$speedString
    } catch {
        return 0
    }
}

function Show-IFTOP {
    param(
        [string]$interface,
        [int]$interval,
        [switch]$numeric,
        [int]$topCount
    )

    # Initial interface stats
    $prevStats = New-Object System.Collections.ArrayList
    $initialStats = Get-InterfaceStats -interface $interface

    foreach ($s in $initialStats) {
        $prevStats.Add($s) | Out-Null
    }

    # Initialize process I/O tracking
    Update-ProcessIORates
    $iteration = 0

    while ($true) {
        Clear-Host

        # Current interface stats
        $currentStats = Get-InterfaceStats -interface $interface

        if ($currentStats.Count -eq 0) {
            Write-Host "ERROR: No network adapter found" -ForegroundColor Red
            Write-Host "Available adapters:" -ForegroundColor Yellow
            Get-NetAdapter | Select-Object Name, Status, LinkSpeed | Format-Table -AutoSize
            break
        }

        # Calculate interface bandwidth
        $bandwidth = Get-ConnectionBandwidth -previousStats $prevStats -currentStats $currentStats -interval $interval

        # Update process I/O rates
        Update-ProcessIORates
        $processRates = Get-ProcessRates -interval $interval

        # Get connections
        $tcpConnections = Get-TCPConnectionEstimates

        # Merge connection data with process rate data
        $connectionList = @()
        $processConnectionCounts = @{}

        foreach ($conn in $tcpConnections) {
            $processId = $conn.OwningProcess

            # Track count of connections per process
            if (-not $processConnectionCounts.ContainsKey($processId)) {
                $processConnectionCounts[$processId] = 0
            }
            $processConnectionCounts[$processId]++

            # Get process rate
            if ($processRates.ContainsKey($processId)) {
                $rateData = $processRates[$processId]
                $connRate = $rateData.Total / [math]::Max(1, $processConnectionCounts[$processId])
            } else {
                $rateData = @{RX = 0; TX = 0; Total = 0}
                $connRate = 0
            }

            $connectionList += [PSCustomObject]@{
                Protocol = $conn.Protocol
                LocalHost = $conn.LocalHost
                LocalPort = $conn.LocalPort
                RemoteHost = $conn.RemoteHost
                RemotePort = $conn.RemotePort
                State = $conn.State
                ProcessName = $conn.ProcessName
                ProcessId = $processId
                RX = $rateData.RX / [math]::Max(1, $processConnectionCounts[$processId])
                TX = $rateData.TX / [math]::Max(1, $processConnectionCounts[$processId])
                Total = $connRate
            }
        }

        # Sort by total rate and take top N
        $topConnections = $connectionList |
            Sort-Object -Property Total -Descending |
            Select-Object -First $topCount |
            Where-Object { $_.Total -gt 0 -or $iteration -lt 2 }

        # Display header
        Write-Host "`n"
        $hostName = hostname
        Write-Host "iftop $hostName" -ForegroundColor Cyan
        if ($interface) {
            Write-Host "Interface: $($currentStats[0].Name)" -ForegroundColor Gray
        } else {
            Write-Host "Interface: All" -ForegroundColor Gray
        }
        Write-Host "Interval: ${interval}s  q to quit`n" -ForegroundColor Gray

        # Connection table header
        $lineLength = 100
        $separator = "=" * $lineLength
        Write-Host $separator -ForegroundColor DarkGray
        Write-Host ("{0,-22} {1,-6} {2,-22} {3,-4} {4,-10} {5,-10} {6,-10} {7,-20}" -f
            "Source", "Port", "Destination", "Port", "RX", "TX", "Total", "Process") -ForegroundColor White
        Write-Host $separator -ForegroundColor DarkGray

        # Display connections
        $maxRate = if ($topConnections.Count -gt 0) { ($topConnections | Measure-Object -Property Total -Maximum).Maximum } else { 1 }
        if ($maxRate -eq 0) { $maxRate = 1 }

        foreach ($conn in $topConnections) {
            $rx = Format-Bandwidth $conn.RX
            $tx = Format-Bandwidth $conn.TX
            $total = Format-Bandwidth $conn.Total
            $barWidth = [math]::Min(15, [math]::Floor(($conn.Total / $maxRate) * 15))
            $bar = "=" * $barWidth + ">" * 1

            $localStr = if ($conn.LocalHost.Length -gt 22) { $conn.LocalHost.Substring(0, 19) + "..." } else { $conn.LocalHost }
            $remoteStr = if ($conn.RemoteHost.Length -gt 22) { $conn.RemoteHost.Substring(0, 19) + "..." } else { $conn.RemoteHost }
            $procStr = if ($conn.ProcessName.Length -gt 20) { $conn.ProcessName.Substring(0, 17) + "..." } else { $conn.ProcessName }

            Write-Host ("{0,-22} {1,-6} {2,-22} {3,-4} {4,-10} {5,-10} {6,-10} {7,-20}" -f
                $localStr, $conn.LocalPort, $remoteStr, $conn.RemotePort, $rx, $tx, $total, $procStr)

            # Show bandwidth bar
            if ($conn.Total -gt 0) {
                Write-Host ("{0,64} {1}" -f "", $bar) -ForegroundColor Green
            }
        }

        # Summary footer
        Write-Host $separator -ForegroundColor DarkGray
        $rxStr = Format-Bandwidth $bandwidth.RX
        $txStr = Format-Bandwidth $bandwidth.TX
        $totalStr = Format-Bandwidth $bandwidth.Total

        Write-Host ("TX: {0}   RX: {1}   TOTAL: {2}" -f $txStr, $rxStr, $totalStr) -ForegroundColor Cyan

        # Interface details
        Write-Host "`nInterface Statistics:" -ForegroundColor Gray
        foreach ($stat in $currentStats) {
            $rxBytes = Format-Bytes $stat.ReceivedBytes
            $txBytes = Format-Bytes $stat.SentBytes
            $speedString = $stat.Speed
            $speedBits = Convert-LinkSpeedToBits $speedString

            Write-Host "  $($stat.Name):" -ForegroundColor White
            Write-Host "    RX Total: $($rxBytes)   TX Total: $($txBytes)"

            if ($speedBits -gt 0) {
                $speedGbps = [math]::Round($speedBits / 1GB, 2)  # Convert to Gbps
                Write-Host "    Link Speed: $($speedGbps) Gbps ($($speedString))"
            }

            # Convert bandwidth from bytes/sec to bits/sec for utilization
            $bandwidthBits = $bandwidth.Total * 8
            $utilization = if ($speedBits -gt 0) { [math]::Round(($bandwidthBits / $speedBits) * 100, 2) } else { 0 }
            $utilColor = if ($utilization -gt 80) { "Red" } elseif ($utilization -gt 50) { "Yellow" } else { "Green" }
            Write-Host ("    Utilization: {0}%" -f $utilization) -ForegroundColor $utilColor
        }

        # Active processes summary
        if ($processRates.Count -gt 0) {
            Write-Host "`nTop 5 Processes by Network Activity:" -ForegroundColor Gray
            $topProcesses = $processRates.GetEnumerator() |
                Sort-Object { $_.Value.Total } -Descending |
                Select-Object -First 5

            foreach ($procEntry in $topProcesses) {
                $procRx = Format-Bandwidth $procEntry.Value.RX
                $procTx = Format-Bandwidth $procEntry.Value.TX
                $procTotal = Format-Bandwidth $procEntry.Value.Total

                Write-Host "  [$($procEntry.Key)] $($procEntry.Value.ProcessName): RX=$procRx TX=$procTx Total=$procTotal"
            }
        }

        # Update previous stats
        $prevStats = New-Object System.Collections.ArrayList
        foreach ($s in $currentStats) {
            $prevStats.Add($s) | Out-Null
        }

        # Check for key press
        if ([Console]::KeyAvailable) {
            $key = [Console]::ReadKey($true)
            if ($key.KeyChar -eq 'q' -or $key.Key -eq 'Escape') {
                Write-Host "`nExiting..." -ForegroundColor Yellow
                break
            }
        }

        # Wait for next interval
        Start-Sleep -Seconds $interval
        $iteration++
    }
}

# Clear any existing Ctrl+C handler
try {
    [Console]::TreatControlCAsInput = $false
} catch {}

# Run iftop
try {
    Show-IFTOP -interface $i -interval $t -numeric:$n -topCount $c
}
finally {
    try {
        [Console]::TreatControlCAsInput = $false
    } catch {}
}