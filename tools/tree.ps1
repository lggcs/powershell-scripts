#!/usr/bin/env pwsh
# PowerShell implementation of the Linux 'tree' command
# Displays directory structures visually

param(
    [string]$Path = ".",
    [Alias('a')]
    [switch]$All,
    [Alias('d')]
    [switch]$DirsOnly,
    [Alias('L')]
    [int]$Level = -1,
    [Alias('f')]
    [switch]$FullPath,
    [Alias('i')]
    [switch]$NoIndent,
    [Alias('p')]
    [switch]$Permissions,
    [Alias('s')]
    [switch]$Size,
    [Alias('h')]
    [switch]$HumanReadable,
    [Alias('match')]
    [string]$Pattern,
    [Alias('ignore')]
    [string]$IgnorePattern,
    [Alias('o')]
    [string]$OutputFile,
    [switch]$Help,
    [switch]$Version,
    [switch]$NoReport,
    [switch]$DirsFirst,
    [Alias('?')]
    [switch]$HelpAlt
)

$ScriptVersion = "1.0.0"

# Box drawing characters (set to ASCII if console doesn't support Unicode)
$script:CharConnect = "|-- "
$script:CharLast = "+-- "
$script:CharVert = "|   "
$script:CharEmpty = "    "

# Try to detect if console supports Unicode
try {
    $consoleCP = [Console]::OutputEncoding
    if ($consoleCP.CodePage -eq 65001 -or $consoleCP.CodePage -eq 1200) {
        # UTF-8 or Unicode - use box drawing characters
        $script:CharConnect = [char]0x251C + [char]0x2500 + [char]0x2500 + " "  # |--
        $script:CharLast = [char]0x2514 + [char]0x2500 + [char]0x2500 + " "     # +--
        $script:CharVert = [char]0x2502 + "   "                                  # |
        $script:CharEmpty = "    "
    }
} catch {
    # Use ASCII fallback
}

function Show-Help {
    $helpText = @"

Usage: tree.ps1 [options] [directory]

-------
Options:
-------
  -a, -All             All files are listed (including hidden files)
  -d, -DirsOnly        List directories only
  -Level <level>       Max display depth of the directory tree
  -L <level>           Same as -Level (alias)
  -f, -FullPath        Print the full path prefix for each file
  -i, -NoIndent        Don't print indentation lines
  -p, -Permissions     Print file permissions
  -s, -Size            Print file size in bytes
  -h, -HumanReadable   Print file size in human readable format (e.g., 1K, 2M)
  -match <pattern>      List only those files matching the pattern (wildcards supported)
  -ignore <pattern>     Do not list files matching the pattern (wildcards supported)
  -o <filename>        Output to file instead of stdout
  -NoReport            Don't print file/directory count at end
  -DirsFirst           List directories before files
  -Help, -?            Show this help message
  -Version             Show version information

-------
Patterns:
-------
  Patterns support PowerShell wildcards:
    *       Matches any characters
    ?       Matches a single character
    [a-z]   Matches characters in range
    |       Separate multiple patterns (e.g., "*.txt|*.doc")

-------
Examples:
-------
  tree.ps1                          Show tree of current directory
  tree.ps1 -L 2                     Show tree with max depth of 2
  tree.ps1 -a C:\Users              Show all files including hidden
  tree.ps1 -d                       Show directories only
  tree.ps1 -match *.txt             Show only .txt files
  tree.ps1 -ignore node_modules     Exclude node_modules directory
  tree.ps1 -h -s                    Show file sizes in human readable format
  tree.ps1 -f -i                    Show full paths without indent lines
  tree.ps1 C:\Projects -ignore ".git|node_modules" -L 3

"@
    Write-Host $helpText
}

# Show help if requested
if ($Help -or $HelpAlt) {
    Show-Help
    exit 0
}

if ($Version) {
    Write-Host "tree.ps1 version $ScriptVersion (PowerShell implementation)"
    exit 0
}

function Format-FileSize {
    param([long]$Bytes)
    
    if ($Bytes -ge 1GB) { return "{0:N1}G" -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return "{0:N1}M" -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return "{0:N1}K" -f ($Bytes / 1KB) }
    return "$($Bytes)"
}

function Get-FilePermissionString {
    param([System.IO.FileSystemInfo]$Item)
    
    $perms = ""
    
    if ($Item -is [System.IO.DirectoryInfo]) {
        $perms = "d"
    } elseif ($Item.LinkType) {
        $perms = "l"
    } else {
        $perms = "-"
    }
    
    # Check if read-only
    $isReadOnly = $Item.Attributes -band [System.IO.FileAttributes]::ReadOnly
    
    # Simulate Unix-style permissions (simplified for Windows)
    $perms += if ($isReadOnly) { "r--" } else { "rw-" }
    $perms += if ($isReadOnly) { "r--" } else { "rw-" }
    $perms += if ($isReadOnly) { "r--" } else { "rw-" }
    
    return "[$perms]"
}

function Test-MatchesPattern {
    param(
        [string]$Name,
        [string]$PatternString
    )
    
    if ([string]::IsNullOrEmpty($PatternString)) { return $true }
    
    # Handle multiple patterns separated by |
    $patterns = $PatternString -split '\|'
    foreach ($p in $patterns) {
        $p = $p.Trim()
        if ($Name -like $p) { return $true }
    }
    return $false
}

function Get-TreeOutput {
    param(
        [string]$Directory,
        [int]$Depth = 0,
        [string]$Prefix = "",
        [ref]$Stats
    )
    
    # Check depth limit
    if ($Level -ge 0 -and $Depth -ge $Level) { return }
    
    # Resolve to absolute path
    $dirPath = (Resolve-Path -Path $Directory -ErrorAction SilentlyContinue).Path
    
    if (-not $dirPath) {
        $script:OutputLines += "$Prefix[access denied]"
        return
    }
    
    try {
        $items = Get-ChildItem -Path $dirPath -Force:$All -ErrorAction Stop
    } catch {
        $script:OutputLines += "$Prefix[access denied]"
        return
    }
    
    # Filter by patterns
    if (-not [string]::IsNullOrEmpty($IgnorePattern)) {
        $items = $items | Where-Object { -not (Test-MatchesPattern -Name $_.Name -PatternString $IgnorePattern) }
    }
    
    if (-not [string]::IsNullOrEmpty($Pattern)) {
        $items = $items | Where-Object { (Test-MatchesPattern -Name $_.Name -PatternString $Pattern) }
    }
    
    # Filter directories only if requested
    if ($DirsOnly) {
        $items = $items | Where-Object { $_ -is [System.IO.DirectoryInfo] }
    }
    
    # Sort: directories first if requested
    if ($DirsFirst) {
        $dirs = @($items | Where-Object { $_ -is [System.IO.DirectoryInfo] } | Sort-Object Name)
        $files = @($items | Where-Object { $_ -is [System.IO.FileInfo] } | Sort-Object Name)
        $items = @($dirs) + @($files)
    } else {
        $items = @($items | Sort-Object Name)
    }
    
    $count = $items.Count
    
    for ($i = 0; $i -lt $count; $i++) {
        $item = $items[$i]
        $isLast = ($i -eq $count - 1)
        
        # Build the prefix characters
        if ($NoIndent) {
            $itemPrefix = ""
            $newPrefix = ""
        } else {
            $connector = if ($isLast) { $script:CharLast } else { $script:CharConnect }
            $itemPrefix = $Prefix + $connector
            $newPrefix = $Prefix + $(if ($isLast) { $script:CharEmpty } else { $script:CharVert })
        }
        
        # Build the display name
        if ($FullPath) {
            $displayName = $item.FullName
        } else {
            $displayName = $item.Name
        }
        
        # Build info string
        $info = ""
        
        if ($Permissions) {
            $info += "$(Get-FilePermissionString -Item $item) "
        }
        
        if ($Size -and ($item -is [System.IO.FileInfo])) {
            if ($HumanReadable) {
                $info += "$(Format-FileSize -Bytes $item.Length) "
            } else {
                $info += "$($item.Length) "
            }
        } elseif ($Size -and ($item -is [System.IO.DirectoryInfo])) {
            $info += "<DIR> "
        }
        
        $line = "$itemPrefix$info$displayName"
        $script:OutputLines += $line
        
        # Update stats
        if ($item -is [System.IO.DirectoryInfo]) {
            $Stats.Value.Directories++
        } else {
            $Stats.Value.Files++
        }
        
        # Recurse into directories
        if ($item -is [System.IO.DirectoryInfo]) {
            Get-TreeOutput -Directory $item.FullName -Depth ($Depth + 1) -Prefix $newPrefix -Stats $Stats
        }
    }
}

# Initialize output
$script:OutputLines = @()

# Validate directory
$resolvedPath = (Resolve-Path -Path $Path -ErrorAction SilentlyContinue)
if (-not $resolvedPath) {
    Write-Error "tree.ps1: Invalid path '$Path'"
    exit 1
}

$rootPath = $resolvedPath.Path

# Add root directory to output
$rootInfo = ""
if ($Permissions) {
    $dirInfo = Get-Item $rootPath
    $rootInfo = "$(Get-FilePermissionString -Item $dirInfo) "
}

if ($FullPath) {
    $script:OutputLines += "$rootInfo$rootPath"
} else {
    $script:OutputLines += "$rootInfo$($resolvedPath.Path.Split('\')[-1])"
}

# Initialize stats
$stats = [ref]@{
    Directories = 0
    Files = 0
}

# Generate tree
Get-TreeOutput -Directory $rootPath -Depth 0 -Prefix "" -Stats $stats

# Add report if not suppressed
if (-not $NoReport) {
    $script:OutputLines += ""
    if ($DirsOnly) {
        $script:OutputLines += "$($stats.Value.Directories) directories"
    } else {
        $script:OutputLines += "$($stats.Value.Directories) directories, $($stats.Value.Files) files"
    }
}

# Output results
if (-not [string]::IsNullOrEmpty($OutputFile)) {
    $script:OutputLines | Out-File -FilePath $OutputFile -Encoding utf8
    Write-Host "Output written to $OutputFile"
} else {
    $script:OutputLines | ForEach-Object { Write-Host $_ }
}