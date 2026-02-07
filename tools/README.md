# PowerShell Tools

A collection of network monitoring tools implemented in PowerShell, providing Linux-like functionality on Windows.

## Tools

| Tool | Description |
|------|-------------|
| **iftop.ps1** | Real-time network bandwidth usage monitor. Displays active network connections with per-connection bandwidth statistics using performance counters. Similar to the Linux `iftop` command. |
| **netstat.ps1** | Network connection and port statistics tool. Displays TCP/UDP connections, listening ports, and associated process information. Supports Linux-style combined flags. |

## Requirements

- Windows PowerShell 5.1+ or PowerShell 7+
- Administrator privileges recommended for full process visibility

## Usage

### iftop.ps1

```powershell
# Show default display (all interfaces, 2 second update)
.\iftop.ps1

# Show specific interface
.\iftop.ps1 -i Wi-Fi

# Set update interval (seconds)
.\iftop.ps1 -t 1

# Numeric addresses only (no DNS resolution)
.\iftop.ps1 -n

# Show top N connections
.\iftop.ps1 -c 30

# Combined options
.\iftop.ps1 -i Ethernet -t 1 -n -c 15
```

**Parameters:**
- `-i <interface>` - Filter by interface name
- `-t <seconds>` - Update interval (default: 2)
- `-n` - Numeric addresses only, skip DNS resolution
- `-c <number>` - Number of top connections to show (default: 20)
- `-p` - Show process names (default: true)

### netstat.ps1

```powershell
# Show all connections with process info (default behavior)
.\netstat.ps1

# Show TCP connections, numeric addresses
.\netstat.ps1 -ant

# Show TCP/UDP with numeric addresses and process info
.\netstat.ps1 -antp

# Using combined Linux-style flags
.\netstat.ps1 -peanut
.\netstat.ps1 -tunlp
```

**Flags:**
- `-a` - Show all connections (including listening)
- `-n` - Numeric addresses only (no DNS - much faster)
- `-t` - Show TCP connections
- `-u` - Show UDP connections
- `-p` - Show process name and PID
- `-e` - Show ethernet statistics

## Notes

- DNS resolution can significantly slow down output; use `-n` for numeric addresses
- Some processes may require administrator privileges to fully identify
- To exit continuous monitoring, press `Ctrl+C`