#Requires -Version 5.1
<#
.SYNOPSIS
  Interactive serial console terminal for Windows.

.DESCRIPTION
  Opens a serial port and turns the console window into a simple character
  terminal: every keystroke is forwarded immediately and bytes arriving from
  the device are printed as they arrive (raw/char mode, like PuTTY).

  Defaults match the Aruba 2530 series (J9773A) console:
  9600 baud, 8 data bits, no parity, 1 stop bit, no flow control.

  Hotkeys:
    Ctrl+] or F12   disconnect and exit
    Ctrl+B          interrupt the switch during POST (HP/Aruba boot monitor)
    Ctrl+C          forwarded to the switch - does NOT exit this window
    Arrows/Home/End/Delete/PgUp/PgDn forwarded as VT escape sequences
    Typing quit, logout or exit + Enter at the switch CLI ends the session
    automatically once the switch shows its idle banner; the screen is then
    cleared so you land back on a clean PowerShell prompt.

  Logging (-Log):
    Captures data received from the device only. The switch suppresses echo
    at password prompts, so credentials never reach the log file.

  Exit codes (for scripting and monitoring):
    0  success: clean exit, -List, passing -Loopback / -Listen / -Detect -TestOnly
    1  error: usage error, no ports, open failure, failed test
    2  -Listen received data but it looked like garbage (wrong baud rate)

.PARAMETER PortName
  COM port to open, e.g. COM3. When omitted, ports are listed and one is picked.

.PARAMETER BaudRate
  Baud rate. Default 9600.

.PARAMETER DataBits
  Data bits. Default 8.

.PARAMETER Parity
  None (default), Even, Odd, Mark or Space.

.PARAMETER StopBits
  One (default), OnePointFive or Two.

.PARAMETER Handshake
  None (default), XOnXOff, RequestToSend or RequestToSendXOnXOff.

.PARAMETER Log
  Optional file path. Everything received from the device is appended to it.

.PARAMETER Detect
  Probe common baud rates (sending Enter and listening on each) and report
  which rate returns readable text instead of garbage.

.PARAMETER TestOnly
  With -Detect: run the probe, report the result, then exit without opening
  an interactive session. For scripted connectivity checks.

.PARAMETER Loopback
  Loopback test: send a test string and verify it is echoed back unchanged.
  Requires a paperclip shorting TX and RX together at the cable's open end
  (DB9 pins 2+3, or RJ45 contacts 3+6 plus 4+5 for ground). Proves the
  USB adapter, driver and this script work before blaming the cable or switch.

.PARAMETER Listen
  One-way listen mode: opens the port at the configured baud and prints
  everything received for -ListenSeconds. Run this while power-cycling the
  switch to catch boot/POST text without a console session.

.PARAMETER ListenSeconds
  Duration in seconds for -Listen. Default 60.

.PARAMETER LogoutMarker
  Text the switch prints on its idle banner after the CLI session ends.
  Default matches HP/Aruba 2530 ("Press any key to continue"): typing quit,
  logout or exit at the switch then ends the console session automatically
  and clears the screen. Pass -LogoutMarker '' to disable auto-exit.

.PARAMETER List
  List serial ports with friendly device names, then exit.

.EXAMPLE
  .\serial-console.ps1

.EXAMPLE
  .\serial-console.ps1 -PortName COM3

.EXAMPLE
  .\serial-console.ps1 -PortName COM3 -Detect

.EXAMPLE
  .\serial-console.ps1 -PortName COM3 -Log session.log

.EXAMPLE
  .\serial-console.ps1 -PortName COM3 -Loopback
  Short the adapter's open-end pins first (see -Loopback description).

.EXAMPLE
  .\serial-console.ps1 -PortName COM3 -Listen
  Start this, then power-cycle the switch to watch boot text.
#>
param(
    [string]$PortName,
    [ValidateRange(50, 2000000)][int]$BaudRate = 9600,
    [ValidateRange(5, 8)][int]$DataBits = 8,
    [ValidateSet('None', 'Even', 'Odd', 'Mark', 'Space')][string]$Parity = 'None',
    [ValidateSet('One', 'OnePointFive', 'Two')][string]$StopBits = 'One',
    [ValidateSet('None', 'XOnXOff', 'RequestToSend', 'RequestToSendXOnXOff')][string]$Handshake = 'None',
    [string]$Log,
    [switch]$Detect,
    [switch]$TestOnly,
    [switch]$List,
    [switch]$Loopback,
    [switch]$Listen,
    [ValidateRange(1, 86400)][int]$ListenSeconds = 60,
    [string]$LogoutMarker = 'Press any key to continue'
)

$ErrorActionPreference = 'Stop'

if (-not ('System.IO.Ports.SerialPort' -as [type])) {
    try { Add-Type -AssemblyName System.IO.Ports } catch { }
}

# --- usage validation (fail fast, before any probing) ------------------------

if ($TestOnly -and -not $Detect) {
    Write-Host '-TestOnly only qualifies a -Detect run: use them together.' -ForegroundColor Red
    exit 1
}
$selectedModes = @($List, $Loopback, $Listen, $Detect) | Where-Object { $_ }
if (@($selectedModes).Count -gt 1) {
    Write-Host 'Modes are mutually exclusive: pick one of -List, -Loopback, -Listen, -Detect.' -ForegroundColor Red
    exit 1
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function New-SerialPortObject {
    param(
        [Parameter(Mandatory = $true)][string]$Port,
        [int]$Baud = 9600,
        [int]$Data = 8,
        [System.IO.Ports.Parity]$ParitySetting = [System.IO.Ports.Parity]::None,
        [System.IO.Ports.StopBits]$StopSetting = [System.IO.Ports.StopBits]::One,
        [System.IO.Ports.Handshake]$Flow = [System.IO.Ports.Handshake]::None
    )
    $sp = New-Object System.IO.Ports.SerialPort
    $sp.PortName     = $Port
    $sp.BaudRate     = $Baud
    $sp.DataBits     = $Data
    $sp.Parity       = $ParitySetting
    $sp.StopBits     = $StopSetting
    $sp.Handshake    = $Flow
    $sp.Encoding     = [System.Text.Encoding]::GetEncoding(28591)
    $sp.ReadTimeout  = 100
    $sp.WriteTimeout = 300
    $sp.DtrEnable    = $true
    $sp.RtsEnable    = $true
    return $sp
}

function Get-SerialPortInfo {
    $info = @()
    try {
        $pnp = @(Get-CimInstance Win32_PnPEntity -Filter "Name LIKE '%(COM%)'" -ErrorAction Stop)
    } catch {
        $pnp = @()
    }
    foreach ($dev in $pnp) {
        $m = [regex]::Match($dev.Name, '\(COM(\d+)\)')
        if ($m.Success) {
            $info += [PSCustomObject]@{
                Port   = 'COM' + $m.Groups[1].Value
                Device = ($dev.Name -replace '\s*\(COM\d+\)\s*$', '')
                Status = $dev.Status
            }
        }
    }
    if (-not $info) {
        try { $fallback = [System.IO.Ports.SerialPort]::GetPortNames() } catch { $fallback = @() }
        foreach ($n in $fallback) {
            $info += [PSCustomObject]@{ Port = $n; Device = $n; Status = 'unknown' }
        }
    }

    $seen = @{}
    $unique = @()
    foreach ($p in ($info | Sort-Object { [int]($_.Port -replace '\D', '') })) {
        if (-not $seen.ContainsKey($p.Port)) {
            $seen[$p.Port] = $true
            $unique += $p
        }
    }
    return $unique
}

function Show-PortList {
    param($Info)
    Write-Host "`nSerial ports found:" -ForegroundColor Cyan
    if (-not $Info -or @($Info).Count -eq 0) {
        Write-Host '  (none)'
        Write-Host ''
        Write-Host 'If a USB console cable is plugged in:'
        Write-Host '  - Check Device Manager > "Ports (COM & LPT)" for an adapter entry or a'
        Write-Host '    device with a yellow warning under "Other devices" (missing driver).'
        Write-Host '  - Common chipsets: FTDI, Prolific PL2303, CH340 - each needs its own'
        Write-Host '    driver from the adapter vendor.'
        return
    }
    foreach ($p in @($Info)) {
        Write-Host ('  {0,-6} {1}   [{2}]' -f $p.Port, $p.Device, $p.Status)
    }
}

function Select-PortInteractive {
    param($Info)
    $items = @($Info)
    if ($items.Count -eq 1) {
        Write-Host ('Only one serial port found - using {0}' -f $items[0].Port)
        return $items[0].Port
    }
    Write-Host "`nSerial ports found:" -ForegroundColor Cyan
    $i = 1
    foreach ($p in $items) {
        Write-Host ('  {0}) {1,-6} {2}' -f $i, $p.Port, $p.Device)
        $i++
    }
    while ($true) {
        $reply = Read-Host ('Select a port (1-{0})' -f $items.Count)
        if ([string]::IsNullOrWhiteSpace($reply)) { return $items[0].Port }
        $num = 0
        if ([int]::TryParse($reply, [ref]$num) -and $num -ge 1 -and $num -le $items.Count) {
            return $items[$num - 1].Port
        }
        Write-Host '  invalid choice, try again' -ForegroundColor DarkYellow
    }
}

function ConvertTo-SerialBytes {
    param([System.ConsoleKeyInfo]$Key)

    $ctrl = [bool]($Key.Modifiers -band [ConsoleModifiers]::Control)
    $charCode = [int]$Key.KeyChar

    if ($Key.Key -eq [ConsoleKey]::F12) { return 'EXIT' }
    if ($ctrl -and ($charCode -eq 29 -or $Key.Key -eq [ConsoleKey]::Oem6)) { return 'EXIT' }

    switch ($Key.Key.ToString()) {
        'Enter'      { return [byte[]](13) }
        'Backspace'  { return [byte[]](8) }
        'Tab'        { return [byte[]](9) }
        'Escape'     { return [byte[]](27) }
        'UpArrow'    { return [byte[]](27, 91, 65) }
        'DownArrow'  { return [byte[]](27, 91, 66) }
        'RightArrow' { return [byte[]](27, 91, 67) }
        'LeftArrow'  { return [byte[]](27, 91, 68) }
        'Home'       { return [byte[]](27, 91, 49, 126) }
        'End'        { return [byte[]](27, 91, 52, 126) }
        'Delete'     { return [byte[]](27, 91, 51, 126) }
        'PageUp'     { return [byte[]](27, 91, 53, 126) }
        'PageDown'   { return [byte[]](27, 91, 54, 126) }
        'Insert'     { return [byte[]](27, 91, 50, 126) }
    }

    if ($ctrl) {
        if ($charCode -ge 1 -and $charCode -le 31) { return [byte[]]($charCode) }
        $keyVal = [int]$Key.Key
        if ($keyVal -ge 65 -and $keyVal -le 90) { return [byte[]]($keyVal -band 31) }
        return $null
    }

    if ($charCode -ge 32 -and $charCode -le 255) { return [byte[]]($charCode) }
    return $null
}

function Invoke-BaudDetect {
    param([string]$PortName)

    Write-Host ('Probing {0} (sending Enter, listening 2s per rate)...' -f $PortName) -ForegroundColor Cyan
    $bauds = 9600, 115200, 19200, 38400, 57600, 4800
    $best = $null

    foreach ($b in $bauds) {
        if ($best) { break }

        $probe = New-SerialPortObject -Port $PortName -Baud $b

        $label = ('{0,7} baud' -f $b)
        try {
            $probe.Open()
        } catch {
            Write-Host ('  {0}  could not open: {1}' -f $label, $_.Exception.Message) -ForegroundColor DarkYellow
            continue
        }

        $acc = New-Object System.Text.StringBuilder
        $ioError = $false
        try {
            # The switch's USB serial bridge can swallow writes made within a
            # few hundred ms of Open() - PuTTY never trips this because its
            # first keystroke arrives seconds later on human timescales.
            Start-Sleep -Milliseconds 800
            $probe.Write("`r`n")
            Start-Sleep -Milliseconds 600
            $probe.Write("`r`n")
            Start-Sleep -Milliseconds 600
            $probe.Write("`r`n")
            $until = (Get-Date).AddSeconds(4)
            while ((Get-Date) -lt $until) {
                if ($probe.BytesToRead -gt 0) { [void]$acc.Append($probe.ReadExisting()) }
                Start-Sleep -Milliseconds 20
            }
        } catch {
            $ioError = $true
        } finally {
            try { if ($probe.IsOpen) { $probe.Close() } } catch { }
        }

        if ($ioError) {
            Write-Host ('  {0}  I/O error (adapter unplugged?)' -f $label) -ForegroundColor DarkYellow
            continue
        }

        $text = $acc.ToString()
        if (-not $text) {
            Write-Host ('  {0}  no response' -f $label) -ForegroundColor DarkGray
            continue
        }

        $printable = 0
        foreach ($ch in $text.ToCharArray()) {
            $code = [int]$ch
            if (($code -ge 32 -and $code -le 126) -or $code -eq 9 -or $code -eq 10 -or $code -eq 13) { $printable++ }
        }
        if ($printable -ge 8 -and ($printable / $text.Length) -ge 0.5) {
            $snippet = ($text -replace "`r", '') -replace "`n", ' | '
            if ($snippet.Length -gt 64) { $snippet = $snippet.Substring(0, 64) + '...' }
            Write-Host ('  {0}  readable text  [{1}]' -f $label, $snippet) -ForegroundColor Green
            $best = $b
        } else {
            Write-Host ('  {0}  garbage (wrong baud)' -f $label) -ForegroundColor Yellow
        }
    }

    return $best
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

$listInfo = Get-SerialPortInfo

if ($List) {
    Show-PortList -Info $listInfo
    exit 0
}

if ($PortName) {
    $present = @()
    try { $present = [System.IO.Ports.SerialPort]::GetPortNames() } catch { }
    if ($present -notcontains $PortName) {
        Write-Host ('Port {0} is not present right now.' -f $PortName) -ForegroundColor Red
        Show-PortList -Info $listInfo
        exit 1
    }
} else {
    if (-not $listInfo -or @($listInfo).Count -eq 0) {
        Write-Host 'No serial ports found.' -ForegroundColor Red
        Show-PortList -Info $listInfo
        exit 1
    }
    $PortName = Select-PortInteractive -Info $listInfo
}

if ($Loopback) {
    Write-Host "`nLoopback test - verifies USB adapter, driver and this script." -ForegroundColor Cyan
    Write-Host 'Short the open end of the cable with a paperclip:'
    Write-Host '  DB9 end : pins 2 + 3  (shell = pin 5)'
    Write-Host '  RJ45 end: contacts 3 + 6 together, plus 4 + 5 together'
    Write-Host ''

    $lo = New-SerialPortObject -Port $PortName -Baud $BaudRate

    $ok = $false
    $sent = 'LOOPBACK-TEST-976543'
    try {
        $lo.Open()
        if ($lo.BytesToRead -gt 0) { [void]$lo.ReadExisting(); Start-Sleep -Milliseconds 200; if ($lo.BytesToRead -gt 0) { [void]$lo.ReadExisting() } }
        Start-Sleep -Milliseconds 400
        $lo.Write($sent)
        $until = (Get-Date).AddSeconds(2)
        while ((Get-Date) -lt $until -and -not $ok) {
            if ($lo.BytesToRead -gt 0) {
                $rx = $lo.ReadExisting()
                if ($rx.Contains($sent)) { $ok = $true; break }
            }
            Start-Sleep -Milliseconds 20
        }
    } catch {
        Write-Host ('I/O error during loopback: {0}' -f $_.Exception.Message) -ForegroundColor Red
        exit 1
    } finally {
        try { if ($lo.IsOpen) { $lo.Close() } } catch { }
    }

    if ($ok) {
        Write-Host 'PASS  - sent data was echoed back byte-for-byte.' -ForegroundColor Green
        Write-Host 'The USB adapter, driver and script are working. The silence at the switch'
        Write-Host 'is caused by the cable pinout or the switch-side connection, not your PC.'
    } else {
        Write-Host 'FAIL  - no echo received.' -ForegroundColor Red
        Write-Host 'Either the paperclip short is not in place, or the adapter/cable is bad.'
        exit 1
    }
    exit 0
}

if ($Listen) {
    Write-Host ("Listening on {0} at {1} baud for {2}s - data from the switch will be printed." -f $PortName, $BaudRate, $ListenSeconds) -ForegroundColor Cyan
    Write-Host 'Power-cycle the switch now if you want to catch its boot text.' -ForegroundColor Cyan
    Write-Host ''

    $ls = New-SerialPortObject -Port $PortName -Baud $BaudRate -Data $DataBits `
        -ParitySetting $Parity -StopSetting $StopBits -Flow $Handshake

    $buf = New-Object System.Text.StringBuilder
    $lerr = $false
    try {
        $ls.Open()
        $until = (Get-Date).AddSeconds($ListenSeconds)
        while ((Get-Date) -lt $until) {
            if ($ls.BytesToRead -gt 0) {
                $chunk = $ls.ReadExisting()
                [void]$buf.Append($chunk)
                [Console]::Write($chunk)
            }
            Start-Sleep -Milliseconds 20
        }
    } catch {
        $lerr = $true
        Write-Host ("`n[!] I/O error while listening: {0}" -f $_.Exception.Message) -ForegroundColor Red
    } finally {
        try { if ($ls.IsOpen) { $ls.Close() } } catch { }
    }

    if (-not $lerr) {
        $text = $buf.ToString()
        if ([string]::IsNullOrWhiteSpace($text)) {
            Write-Host ("`nResult: received nothing at {0} baud." -f $BaudRate) -ForegroundColor Red
            Write-Host 'If the switch was power-cycled, this strongly suggests a pinout mismatch or a fault'
            Write-Host 'between the cable and the switch console port.'
            exit 1
        }
        $printable = 0
        foreach ($ch in $text.ToCharArray()) {
            $code = [int]$ch
            if (($code -ge 32 -and $code -le 126) -or $code -eq 9 -or $code -eq 10 -or $code -eq 13) { $printable++ }
        }
        if ($printable -ge 8 -and ($printable / $text.Length) -ge 0.5) {
            Write-Host ("`nResult: readable text received at {0} baud - link works." -f $BaudRate) -ForegroundColor Green
            exit 0
        }
        Write-Host ("`nResult: data received at {0} baud but it looks like garbage - wrong baud rate." -f $BaudRate) -ForegroundColor Yellow
        Write-Host 'Re-run with -Detect to find the correct rate.'
        exit 2
    }
    exit 1
}

if ($Detect) {
    $best = Invoke-BaudDetect -PortName $PortName
    if (-not $best) {
        Write-Host "`nNo baud rate produced readable text. Things to check:" -ForegroundColor Red
        Write-Host '  - Make sure the cable is plugged into the switch CONSOLE port, not a network port.'
        Write-Host '  - The J9773A console is RJ45: it needs an HP/Aruba console cable (RJ45 to DB9/USB).'
        Write-Host '    A Cisco rollover cable uses a different pinout and typically does not work.'
        Write-Host '  - Serial consoles stay silent until a key is pressed; the probe already sends Enter.'
        exit 1
    }
    if ($TestOnly) {
        Write-Host ("`nDevice responded with readable text at {0} baud." -f $best) -ForegroundColor Green
        exit 0
    }

    $chosen = $best
    $reply = Read-Host ('Use {0} baud for the session? [Enter = yes, n = quit, or type another rate]' -f $chosen)
    if ($reply -match '^[nN]') { exit 0 }
    $numMatch = [regex]::Match($reply, '\d+')
    if ($numMatch.Success) { $chosen = [int]$numMatch.Value }
    $BaudRate = $chosen
}

# Interactive mode drives [Console] directly - it cannot work with redirected
# stdin/stdout (services, scheduled tasks, CI). Fail loudly instead of throwing.
if (-not [Environment]::UserInteractive -or [Console]::IsInputRedirected -or [Console]::IsOutputRedirected) {
    Write-Host 'Interactive console mode needs a real console (stdin/stdout must not be redirected).' -ForegroundColor Red
    Write-Host 'For unattended or scripted use: -Detect -TestOnly, -Loopback or -Listen.'
    exit 1
}

# Enable ANSI escape passthrough on legacy conhost (no effect under Windows Terminal)
try {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class ConsoleVT
{
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr GetStdHandle(int handle);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetConsoleMode(IntPtr hConsoleHandle, out uint mode);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetConsoleMode(IntPtr hConsoleHandle, uint mode);
    public static void Enable()
    {
        uint mode;
        IntPtr h = GetStdHandle(-11);
        if (h != IntPtr.Zero && GetConsoleMode(h, out mode))
        {
            SetConsoleMode(h, mode | 0x0004);
        }
    }
}
'@ -ErrorAction SilentlyContinue | Out-Null
    [ConsoleVT]::Enable()
} catch { }

# --- open the port ----------------------------------------------------------

$parityLetter = @{ None = 'N'; Even = 'E'; Odd = 'O'; Mark = 'M'; Space = 'S' }[$Parity]
$stopLetter   = @{ One = '1'; OnePointFive = '1.5'; Two = '2' }[$StopBits]
$flowShort    = @{ None = 'none'; XOnXOff = 'XON/XOFF'; RequestToSend = 'RTS/CTS'; RequestToSendXOnXOff = 'RTS/CTS+XON/XOFF' }[$Handshake]

$serial = New-SerialPortObject -Port $PortName -Baud $BaudRate -Data $DataBits `
    -ParitySetting $Parity -StopSetting $StopBits -Flow $Handshake

try {
    $serial.Open()
} catch {
    Write-Host ('Could not open {0}: {1}' -f $PortName, $_.Exception.Message) -ForegroundColor Red
    Write-Host '  - "Access is denied": another program has the port open (PuTTY, another console, Arduino IDE...).'
    Write-Host '  - Port disappeared: unplug and replug the USB-serial adapter and re-run.'
    Write-Host '  - Otherwise check Device Manager > "Ports (COM & LPT)" for driver problems.'
    exit 1
}

# Let the USB console bridge settle before the first keystroke can be sent.
Start-Sleep -Milliseconds 400

$script:logWriter = $null
if ($Log) {
    try {
        $script:logWriter = New-Object System.IO.StreamWriter($Log, $true, [System.Text.Encoding]::GetEncoding(28591))
        Write-Host ('Logging to {0}' -f $Log) -ForegroundColor DarkGray
    } catch {
        Write-Host ('Cannot open log file {0}: {1} (continuing without logging)' -f $Log, $_.Exception.Message) -ForegroundColor Yellow
    }
}

try { $host.UI.RawUI.WindowTitle = ('Serial console: {0} @ {1}' -f $PortName, $BaudRate) } catch { }

Write-Host ''
Write-Host ('Connected: {0} @ {1} baud ({2}{3}{4}, flow: {5})' -f $PortName, $BaudRate, $DataBits, $parityLetter, $stopLetter, $flowShort) -ForegroundColor Green
Write-Host 'Press ENTER twice if no prompt appears.' -ForegroundColor DarkGray
Write-Host 'Exit: quit/logout on the switch (auto-detected), or Ctrl+] / F12' -ForegroundColor DarkGray
Write-Host 'Ctrl+C, Ctrl+B and arrows are forwarded to the switch' -ForegroundColor DarkGray
Write-Host ''

function Write-IncomingText {
    param([string]$Text)
    if ($Text) {
        [Console]::Write($Text)
        if ($script:logWriter) { $script:logWriter.Write($Text) }
    }
}

# Logout auto-detection: after the user types quit/logout/exit + Enter, watch
# (20s window) for the switch's idle banner; when it appears, end the session.
# The watch tail is reset on arming so a banner printed earlier cannot match.
$script:logoutArmed    = $false
$script:logoutWatchEnd = $null
$script:tail           = ''
$script:pendingLine    = ''
$script:exitReason     = ''

$script:flushInterval = [TimeSpan]::FromSeconds(2)
$script:lastFlush = Get-Date

[Console]::TreatControlCAsInput = $true

try {
    while ($true) {
        $activity = $false
        try {
            # Drain everything pending before yielding so a config dump or
            # POST flood cannot overflow the driver's receive buffer.
            while ($serial.BytesToRead -gt 0) {
                $chunk = $serial.ReadExisting()
                Write-IncomingText -Text $chunk
                if ($LogoutMarker -and $script:logoutArmed) {
                    $script:tail = $script:tail + $chunk
                    if ($script:tail.Length -gt 400) {
                        $script:tail = $script:tail.Substring($script:tail.Length - 400)
                    }
                }
                $activity = $true
            }

            if ($script:logoutArmed) {
                if ($script:tail -like ('*' + $LogoutMarker + '*')) {
                    $script:exitReason = 'Switch session ended.'
                    break
                }
                if (($null -ne $script:logoutWatchEnd) -and ((Get-Date) -gt $script:logoutWatchEnd)) {
                    Write-Host "`n[!] No idle banner within 20s - still attached. Auto-exit disarmed." -ForegroundColor Yellow
                    Write-Host '    Ctrl+] or F12 exits manually.' -ForegroundColor Yellow
                    $script:logoutArmed = $false
                    $script:logoutWatchEnd = $null
                    $script:tail = ''
                }
            }

            if ([Console]::KeyAvailable) {
                $keyInfo = [Console]::ReadKey($true)
                $data = ConvertTo-SerialBytes -Key $keyInfo
                if ($data -is [string]) {
                    $script:exitReason = 'manual (Ctrl+] / F12)'
                    break
                }
                if ($data) {
                    $serial.Write($data, 0, $data.Length)
                    if ($LogoutMarker -and $data.Length -eq 1) {
                        if ($data[0] -eq 13) {
                            if ($script:pendingLine -match '^(quit|logout|exit)$') {
                                $script:logoutArmed = $true
                                $script:logoutWatchEnd = (Get-Date).AddSeconds(20)
                                $script:tail = ''
                            }
                            $script:pendingLine = ''
                        } elseif ($data[0] -eq 8) {
                            if ($script:pendingLine.Length -gt 0) {
                                $script:pendingLine = $script:pendingLine.Substring(0, $script:pendingLine.Length - 1)
                            }
                        } elseif ($data[0] -ge 32 -and $data[0] -le 255) {
                            $script:pendingLine = $script:pendingLine + [char]$data[0]
                            if ($script:pendingLine.Length -gt 32) {
                                $script:pendingLine = $script:pendingLine.Substring($script:pendingLine.Length - 32)
                            }
                        }
                    }
                }
                $activity = $true
            }
        } catch {
            if ($_.Exception -is [System.TimeoutException]) { continue }
            Write-Host ("`n[!] Serial I/O error: {0}  (adapter unplugged or port closed)" -f $_.Exception.Message) -ForegroundColor Red
            break
        }
        if ($script:logWriter -and ((Get-Date) - $script:lastFlush) -gt $script:flushInterval) {
            try { $script:logWriter.Flush() } catch { }
            $script:lastFlush = Get-Date
        }
        if (-not $activity) { Start-Sleep -Milliseconds 8 }
    }
} finally {
    [Console]::TreatControlCAsInput = $false
    if ($script:logWriter) {
        try { $script:logWriter.Flush() } catch { }
        try { $script:logWriter.Dispose() } catch { }
        $script:logWriter = $null
    }
    try { if ($serial.IsOpen) { $serial.Close() } } catch { }
    if ($script:exitReason -eq 'Switch session ended.') {
        try { [Console]::Clear() } catch { }
    }
    if ($script:exitReason) {
        Write-Host ('Disconnected from {0} - {1}' -f $PortName, $script:exitReason) -ForegroundColor Cyan
    } else {
        Write-Host "`nDisconnected from $PortName." -ForegroundColor Cyan
    }
}
