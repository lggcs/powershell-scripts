<#
.SYNOPSIS
    PowerShell implementation of netstat -peanut functionality
.DESCRIPTION
    Displays network connections, listening ports, and process information
    Accepts the same command-line options as netstat

    Supports combined flags like Linux netstat: -ant, -peanut, -tunlp, etc.
    
.PARAMETER args
    Accepts flags as array of strings
.EXAMPLE
    .\netstat.ps1 -peanut
.EXAMPLE
    .\netstat.ps1 -ant
.EXAMPLE
    .\netstat.ps1 -tunlp
#>

<#
    No param block - we parse $args directly to support combined flags
    like -ant, -peanut, etc.
#>

# Initialize flags
$a = $false
$e = $false
$n = $false
$p = $false
$t = $false
$u = $false

function Parse-CombinedFlags {
    param($flagString)
    
    # Remove leading dash if present
    $flags = $flagString.TrimStart('-')
    
    # Check each character
    foreach ($char in $flags.ToCharArray()) {
        switch ($char) {
            'a' { $script:a = $true }
            'e' { $script:e = $true }
            'n' { $script:n = $true }
            'p' { $script:p = $true }
            't' { $script:t = $true }
            'u' { $script:u = $true }
        }
    }
}

# Parse all arguments
foreach ($arg in $args) {
    # Handle arguments with dashes
    if ($arg -match '^-') {
        Parse-CombinedFlags -flagString $arg
    }
}

# Parse options - match Linux netstat behavior
$all = $a
$ethernet = $e
# -n flag: numeric addresses (no DNS). Without -n, DNS is enabled.
$numeric = $n
$programs = $p

# Protocol selection: -t for TCP, -u for UDP
$tcp = $t
$udp = $u

# If no protocol specified (-t, -u), default to showing both
if (-not $tcp -and -not $udp) {
    $tcp = $true
    $udp = $true
}

# If no options specified at all, default to -peanut behavior
$anyFlagSpecified = $a -or $e -or $n -or $p -or $t -or $u

if (-not $anyFlagSpecified) {
    $all = $true
    $ethernet = $true
    $numeric = $true
    $programs = $true
    $tcp = $true
    $udp = $true
}

# IMPORTANT: If -n is NOT specified, DNS resolution would be enabled
if (-not $numeric -and $anyFlagSpecified) {
    Write-Host "Warning: DNS resolution enabled. Use -n for numeric addresses (much faster)." -ForegroundColor Yellow
}

function Format-LocalAddress {
    param($endpoint, $numeric)
    if ($numeric) {
        return "$($endpoint.LocalAddress):$($endpoint.LocalPort)"
    } else {
        try {
            $ip = $endpoint.LocalAddress
            if ($ip -eq '0.0.0.0' -or $ip -eq '::' -or $ip -eq '*') {
                $hostname = '*'
            } else {
                $hostname = [System.Net.Dns]::GetHostEntry($ip).HostName
            }
            return "$($hostname):$($endpoint.LocalPort)"
        } catch {
            return "$($endpoint.LocalAddress):$($endpoint.LocalPort)"
        }
    }
}

function Format-RemoteAddress {
    param($endpoint, $numeric)
    if ($numeric) {
        return "$($endpoint.RemoteAddress):$($endpoint.RemotePort)"
    } else {
        try {
            $ip = $endpoint.RemoteAddress
            if ($ip -eq '0.0.0.0' -or $ip -eq '::' -or $ip -eq '*') {
                $hostname = '*'
            } else {
                $hostname = [System.Net.Dns]::GetHostEntry($ip).HostName
            }
            return "$($hostname):$($endpoint.RemotePort)"
        } catch {
            return "$($endpoint.RemoteAddress):$($endpoint.RemotePort)"
        }
    }
}

function Get-ProcessName {
    param($processId)
    try {
        if ($processId -eq 0) {
            return ''
        }
        $processObj = Get-Process -Id $processId -ErrorAction SilentlyContinue
        if ($processObj) {
            return $processObj.ProcessName
        }
        return ''
    } catch {
        return ''
    }
}

# Display Ethernet statistics if requested
if ($ethernet) {
    $interfaces = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' } | Sort-Object Name
    $stats = Get-NetAdapterStatistics -ErrorAction SilentlyContinue

    Write-Host ""
    Write-Host "Interface Statistics"
    Write-Host ""

    $maxNameLen = 0
    foreach ($iface in $interfaces) {
        if ($iface.Name.Length -gt $maxNameLen) { $maxNameLen = $iface.Name.Length }
    }

    Write-Host ("{0,-$maxNameLen}  {1,15}  {2,15}  {3,15}  {4,15}" -f "Bytes", "Received", "Sent", "Bytes", "Sent")
    Write-Host ("{0,-$maxNameLen}  {1,15}  {2,15}  {3,15}  {4,15}" -f "", "Received", "Sent", "Unicast", "Unicast")
    Write-Host ("{0,-$maxNameLen}  {1,15}  {2,15}  {3,15}  {4,15}" -f "Interface", "Bytes", "Bytes", "Packets", "Packets")
    Write-Host ("{0,-$maxNameLen}  {1,15}  {2,15}  {3,15}  {4,15}" -f ("-" * $maxNameLen), "---------------", "---------------", "---------------", "---------------")

    foreach ($iface in $interfaces) {
        $ifaceStats = $stats | Where-Object { $_.Name -eq $iface.Name }
        
        $receivedBytes = if ($ifaceStats) { $ifaceStats.ReceivedBytes } else { 0 }
        $sentBytes = if ($ifaceStats) { $ifaceStats.SentBytes } else { 0 }
        $receivedUnicastPackets = if ($ifaceStats) { $ifaceStats.ReceivedUnicastPackets } else { 0 }
        $sentUnicastPackets = if ($ifaceStats) { $ifaceStats.SentUnicastPackets } else { 0 }

        Write-Host ("{0,-$maxNameLen}  {1,15:N0}  {2,15:N0}  {3,15:N0}  {4,15:N0}" -f $iface.Name, $receivedBytes, $sentBytes, $receivedUnicastPackets, $sentUnicastPackets)
    }
}

# Display header if outputting connections
if ($tcp -or $udp) {
    if ($programs) {
        Write-Host ""
        Write-Host "Active Connections"
        Write-Host ""
        Write-Host "  Proto  Local Address          Foreign Address        State           PID/Program name"
        Write-Host "------  ----------------------  -----------------------  --------------  ----------------"
    } else {
        Write-Host ""
        Write-Host "Active Connections"
        Write-Host ""
        Write-Host "  Proto  Local Address          Foreign Address        State"
        Write-Host "------  ----------------------  -----------------------  --------------"
    }
}

# Process TCP connections
if ($tcp) {
    $tcpConnections = Get-NetTCPConnection -ErrorAction SilentlyContinue

    if (-not $all) {
        $tcpConnections = $tcpConnections | Where-Object { $_.State -eq 'Established' }
    }

    foreach ($conn in $tcpConnections | Sort-Object -Property LocalAddress) {
        $localAddr = Format-LocalAddress -endpoint $conn -numeric $numeric
        $remoteAddr = Format-RemoteAddress -endpoint $conn -numeric $numeric
        $state = $conn.State

        if ($programs) {
            $processName = Get-ProcessName -processId $conn.OwningProcess
            $line = "  TCP    {0,-23}  {1,-23}  {2,-14}  {3}/{4}" -f $localAddr, $remoteAddr, $state, $conn.OwningProcess, $processName
            Write-Host $line
        } else {
            $line = "  TCP    {0,-23}  {1,-23}  {2,-14}" -f $localAddr, $remoteAddr, $state
            Write-Host $line
        }
    }
}

# Process UDP endpoints
if ($udp) {
    $udpEndpoints = Get-NetUDPEndpoint -ErrorAction SilentlyContinue

    foreach ($endpoint in $udpEndpoints | Sort-Object -Property LocalAddress) {
        $localAddr = Format-LocalAddress -endpoint $endpoint -numeric $numeric
        $remoteAddr = '*:*'
        $state = ''

        if ($programs) {
            $processName = Get-ProcessName -processId $endpoint.OwningProcess
            $line = "  UDP    {0,-23}  {1,-23}  {2,-14}  {3}/{4}" -f $localAddr, $remoteAddr, $state, $endpoint.OwningProcess, $processName
            Write-Host $line
        } else {
            $line = "  UDP    {0,-23}  {1,-23}  {2,-14}" -f $localAddr, $remoteAddr, $state
            Write-Host $line
        }
    }
}