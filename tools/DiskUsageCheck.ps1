<#
.SYNOPSIS
    Disk usage analyzer for Windows endpoints - finds space-hogging folders,
    largest individual files, and per-extension size breakdown.

.DESCRIPTION
    A read-only PowerShell disk-usage scanner designed for fleet-wide deployment
    via RMM platforms (e.g. N-able N-central). Scans a drive root, builds a
    folder-size tree to a configurable depth, and reports:

      * Top-N root folders by size with ASCII bar charts
      * Recursive drill-down of the biggest folders (with junction/symlink
        detection - reparse points are tagged [J] and never followed)
      * Actionable cleanup candidates (Downloads, Temp, OneDrive, Cache,
        SoftwareDistribution, Packages)
      * Top-N largest individual files above a size threshold
      * Per-extension size breakdown with file counts
      * Optional CSV export for centralized reporting

    Writes nothing to disk except the optional CSV output file. No files are
    modified, moved, or deleted.

.PARAMETER Path
    Root folder to scan. Defaults to C:\.

.PARAMETER Depth
    Maximum recursion depth for the folder tree. Default 4.

.PARAMETER TopRoots
    Number of root folders to drill into. Default 5.

.PARAMETER TopChildren
    Number of child folders to show per level. Default 5.

.PARAMETER TopFiles
    Number of largest individual files to display. Default 20.

.PARAMETER TopExtensions
    Number of extensions to show in the breakdown. Default 15.

.PARAMETER MinimumPercent
    Minimum percentage of parent size for a child folder to be shown. Default 5.

.PARAMETER MinimumSize
    Minimum absolute size in bytes for a child folder to be shown. A folder
    is skipped only if it is below BOTH MinimumPercent and MinimumSize.
    Default 0 (disabled).

.PARAMETER LargeFileThreshold
    Size threshold for the largest-files section. Accepts human-readable
    strings like "500MB", "1.5GB", "2TB", or a bare byte count. Default "100MB".

.PARAMETER ExportCsv
    Optional path to write a CSV report (RootFolder, CleanupCandidate,
    LargeFile, and Extension rows). Defaults to none.

.EXAMPLE
    .\diskcheck.ps1
    Scans C:\ with defaults, console output only.

.EXAMPLE
    .\diskcheck.ps1 -Path D:\ -Depth 2 -TopFiles 20 -LargeFileThreshold 500MB -ExportCsv "C:\ProgramData\diskcheck_report.csv"
    Scans D:\ with fleet-friendly settings and exports CSV for collection.

.NOTES
    File Name      : DiskUsageCheck.ps1
    Author         : Luke
    Prerequisite   : PowerShell 5.1 (Windows PowerShell ISE compatible)
    License        : MIT
#>

#Requires -Version 5.1

param(
    [string]$Path = "C:\",
    [int]$Depth = 4,
    [int]$TopRoots = 5,
    [int]$TopChildren = 5,
    [int]$TopFiles = 20,
    [int]$TopExtensions = 15,
    [double]$MinimumPercent = 5,
    [Int64]$MinimumSize = 0,
    [string]$LargeFileThreshold = "100MB",
    [string]$ExportCsv = ""
)

function ConvertTo-ByteSize {
    param([string]$Value)

    if ($Value -match '^\s*(\d+(?:\.\d+)?)\s*(KB|MB|GB|TB|PB)?\s*$') {
        $Number = [double]$Matches[1]
        $Unit   = $Matches[2]

        if ([string]::IsNullOrEmpty($Unit)) { return [Int64]$Number }

        switch ($Unit) {
            'KB' { return [Int64]($Number * 1KB) }
            'MB' { return [Int64]($Number * 1MB) }
            'GB' { return [Int64]($Number * 1GB) }
            'TB' { return [Int64]($Number * 1TB) }
            'PB' { return [Int64]($Number * 1PB) }
        }
    }

    throw "Cannot parse '$Value' as a size. Use formats like 500, 500MB, 1.5GB, 2TB."
}

Set-StrictMode -Version Latest

$script:LargeFileThresholdBytes = ConvertTo-ByteSize $LargeFileThreshold

# Strip stray quotes from parameters (common when invoked via cmd.exe / RMM)
if (-not [string]::IsNullOrEmpty($ExportCsv)) {
    $ExportCsv = $ExportCsv.Trim("'", '"')
}
if (-not [string]::IsNullOrEmpty($Path)) {
    $Path = $Path.Trim("'", '"')
}

# ---------------------------------------------------------------------------
# Script-scope state
# ---------------------------------------------------------------------------

$script:FolderSizeCache = @{}
$script:CleanupCandidates = New-Object System.Collections.ArrayList
$script:LargeFiles = New-Object System.Collections.ArrayList
$script:ExtensionSizes = @{}
$script:ExtensionCounts = @{}

$ExcludeRecursion = @(
    "winsxs",
    "system32",
    "assembly",
    "servicing",
    "driverstore",
    "installer"
)

# Pre-built regex to skip excluded directories during file scans
$script:ExcludeRegex = '\\(' + (($ExcludeRecursion | ForEach-Object { [regex]::Escape($_) }) -join '|') + ')\\'

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Write-Header {
    param([string]$Title)

    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host $Title -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan
}

function Get-UsageColor {
    param([double]$Percent)

    if ($Percent -ge 50) { return "Red" }
    elseif ($Percent -ge 20) { return "Yellow" }
    else { return "Green" }
}

function Format-Size {
    param([Int64]$Bytes)

    if ($Bytes -ge 1TB) {
        return ("{0:N2} TB" -f ($Bytes / 1TB))
    }
    elseif ($Bytes -ge 1GB) {
        return ("{0:N2} GB" -f ($Bytes / 1GB))
    }
    elseif ($Bytes -ge 1MB) {
        return ("{0:N2} MB" -f ($Bytes / 1MB))
    }
    elseif ($Bytes -ge 1KB) {
        return ("{0:N2} KB" -f ($Bytes / 1KB))
    }

    return ("{0} B" -f $Bytes)
}

function New-Bar {
    param(
        [double]$Percent,
        [int]$Width = 30
    )

    if ($Percent -lt 0) { $Percent = 0 }
    if ($Percent -gt 100) { $Percent = 100 }

    $Filled = [int]($Percent * $Width / 100)

    if ($Filled -gt $Width) {
        $Filled = $Width
    }

    ("#" * $Filled).PadRight($Width, '.')
}

function Test-ReparsePoint {
    param([string]$FolderPath)

    try {
        $Item = Get-Item -LiteralPath $FolderPath -Force -ErrorAction SilentlyContinue
        if ($null -ne $Item -and ($Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
            return $true
        }
    }
    catch { }

    return $false
}

# ---------------------------------------------------------------------------
# Folder-size with cache
# ---------------------------------------------------------------------------

function Get-FolderSize {
    param([string]$FolderPath)

    $cacheKey = $FolderPath.TrimEnd('\')

    if ($script:FolderSizeCache.ContainsKey($cacheKey)) {
        return $script:FolderSizeCache[$cacheKey]
    }

    if (Test-ReparsePoint $FolderPath) {
        $script:FolderSizeCache[$cacheKey] = [Int64]0
        return [Int64]0
    }

    try {
        $Measure =
            Get-ChildItem `
                -LiteralPath $FolderPath `
                -Recurse `
                -File `
                -Force `
                -ErrorAction SilentlyContinue |
            Measure-Object Length -Sum

        $result = if ($null -eq $Measure.Sum) { [Int64]0 } else { [Int64]$Measure.Sum }
    }
    catch {
        $result = [Int64]0
    }

    $script:FolderSizeCache[$cacheKey] = $result
    return $result
}

function Add-CleanupCandidate {
    param(
        [string]$Path,
        [Int64]$Size
    )

    if ($Size -le 0) {
        return
    }

    $null = $script:CleanupCandidates.Add([PSCustomObject]@{
        Path = $Path
        Size = $Size
    })
}

# ---------------------------------------------------------------------------
# Tree traversal
# ---------------------------------------------------------------------------

function Get-LargestChildren {

    param(
        [string]$ParentPath,
        [switch]$ShowProgress
    )

    try {
        $Children = @(Get-ChildItem `
            -LiteralPath $ParentPath `
            -Directory `
            -Force `
            -ErrorAction SilentlyContinue)
    }
    catch {
        return @()
    }

    if ($null -eq $Children -or $Children.Count -eq 0) {
        return @()
    }

    $Total = $Children.Count
    $Index = 0

    # Force the result into an array so single-element or empty returns
    # don't get unwrapped to $null by the pipeline (StrictMode + .Count)
    $Results = @(
        $Children | ForEach-Object {

            $Index++

            if ($ShowProgress) {
                Write-Host (
                    "[{0}/{1}] {2}" -f
                    $Index,
                    $Total,
                    $_.FullName
                ) -ForegroundColor Gray
            }

            $Size = Get-FolderSize $_.FullName

            [PSCustomObject]@{
                Name       = $_.Name
                Path       = $_.FullName
                Size       = $Size
                IsJunction = (Test-ReparsePoint $_.FullName)
            }
        }
    )

    return ($Results | Sort-Object Size -Descending)
}

function Show-Hogs {

    param(
        [string]$Folder,
        [Int64]$ParentSize,
        [int]$Level,
        [int]$MaxDepth
    )

    if ($Level -gt $MaxDepth) {
        return
    }

    $FolderName = Split-Path $Folder -Leaf

    if ($ExcludeRecursion -contains $FolderName.ToLower()) {

        $Children = Get-LargestChildren -ParentPath $Folder

        foreach ($Child in ($Children | Select-Object -First 10)) {

            if ($Child.Size -le 0) {
                continue
            }

            $Indent = ("|  " * ($Level - 1))

            $Tag = if ($Child.IsJunction) { " [J]" } else { "" }

            Write-Host (
                "{0}+-- {1,-30} {2}{3}" -f `
                $Indent,
                $Child.Name,
                (Format-Size $Child.Size),
                $Tag
            ) -ForegroundColor DarkYellow
        }

        return
    }

    $Children = Get-LargestChildren -ParentPath $Folder

    foreach ($Child in ($Children | Select-Object -First $TopChildren)) {

        if ($Child.Size -le 0) {
            continue
        }

        $Percent = 0

        if ($ParentSize -gt 0) {
            $Percent = ($Child.Size / $ParentSize) * 100
        }

        # Skip only if below both percentage AND absolute thresholds
        if ($Percent -lt $MinimumPercent -and $Child.Size -lt $MinimumSize) {
            continue
        }

        if (-not $Child.IsJunction) {
            $PathLower = $Child.Path.ToLower()

            if (
                $PathLower -match '\\downloads$' -or
                $PathLower -match '\\temp$' -or
                $PathLower -match '\\onedrive$' -or
                $PathLower -match '\\packages$' -or
                $PathLower -match '\\cache$' -or
                $PathLower -match '\\softwaredistribution$'
            ) {
                Add-CleanupCandidate -Path $Child.Path -Size $Child.Size
            }
        }

        $Color = Get-UsageColor $Percent
        $Indent = ("|  " * ($Level - 1))

        $Tag = if ($Child.IsJunction) { " [J]" } else { "" }

        Write-Host (
            "{0}+-- {1,-30} {2,12} [{3}] {4,5:N1}%{5}" -f `
            $Indent,
            $Child.Name,
            (Format-Size $Child.Size),
            (New-Bar $Percent),
            $Percent,
            $Tag
        ) -ForegroundColor $Color

        if (-not $Child.IsJunction) {
            Show-Hogs `
                -Folder $Child.Path `
                -ParentSize $Child.Size `
                -Level ($Level + 1) `
                -MaxDepth $MaxDepth
        }
    }
}

# ---------------------------------------------------------------------------
# Important / known folders
# ---------------------------------------------------------------------------

function Show-ImportantFolders {

    Write-Header "ACTIONABLE FINDINGS"

    $Candidates = New-Object System.Collections.ArrayList

    $UsersRoot = Join-Path $env:SystemDrive "Users"

    if (Test-Path $UsersRoot -ErrorAction SilentlyContinue) {

        Get-ChildItem $UsersRoot -Directory -ErrorAction SilentlyContinue |
        ForEach-Object {

            $UserRoot = $_.FullName

            foreach ($Target in @(
                "$UserRoot\Downloads",
                "$UserRoot\Desktop",
                "$UserRoot\Documents",
                "$UserRoot\OneDrive",
                "$UserRoot\AppData\Local",
                "$UserRoot\AppData\Local\Temp",
                "$UserRoot\AppData\Local\Packages",
                "$UserRoot\AppData\Roaming"
            )) {

                if (Test-Path $Target -ErrorAction SilentlyContinue) {

                    $Size = Get-FolderSize $Target

                    if ($Size -gt 0) {

                        $null = $Candidates.Add([PSCustomObject]@{
                            Path = $Target
                            Size = $Size
                        })
                    }
                }
            }
        }
    }

    foreach ($Target in @(
        "$env:SystemDrive\Windows\SoftwareDistribution",
        "$env:SystemDrive\Windows\Temp",
        "$env:SystemDrive\`$Recycle.Bin"
    )) {

        if (Test-Path $Target -ErrorAction SilentlyContinue) {

            $Size = Get-FolderSize $Target

            if ($Size -gt 0) {

                $null = $Candidates.Add([PSCustomObject]@{
                    Path = $Target
                    Size = $Size
                })
            }
        }
    }

    $Candidates |
        Sort-Object Size -Descending |
        Select-Object -First 20 |
        ForEach-Object {

            Write-Host (
                "{0,-12} {1}" -f
                (Format-Size $_.Size),
                $_.Path
            ) -ForegroundColor Magenta
        }
}

# ---------------------------------------------------------------------------
# Largest files + extension breakdown (single pass)
# ---------------------------------------------------------------------------

function Collect-FileStats {

    param(
        [PSCustomObject[]]$RootFolders
    )

    if ($null -eq $RootFolders -or $RootFolders.Count -eq 0) {
        return
    }

    $Total = $RootFolders.Count
    $Index = 0

    foreach ($Root in $RootFolders) {

        $Index++
        Write-Host ("[{0}/{1}] Scanning files in {2}" -f $Index, $Total, $Root.Path) -ForegroundColor Gray

        Get-ChildItem `
            -LiteralPath $Root.Path `
            -Recurse `
            -File `
            -Force `
            -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch $script:ExcludeRegex } |
        ForEach-Object {

            $FileSize = $_.Length

            if ($FileSize -ge $script:LargeFileThresholdBytes) {
                $null = $script:LargeFiles.Add([PSCustomObject]@{
                    Path      = $_.FullName
                    Size      = $FileSize
                    Extension = if ([string]::IsNullOrEmpty($_.Extension)) { "(none)" } else { $_.Extension }
                })
            }

            $Ext = if ([string]::IsNullOrEmpty($_.Extension)) { "(none)" } else { $_.Extension }

            if ($script:ExtensionSizes.ContainsKey($Ext)) {
                $script:ExtensionSizes[$Ext] += $FileSize
                $script:ExtensionCounts[$Ext]++
            }
            else {
                $script:ExtensionSizes[$Ext] = $FileSize
                $script:ExtensionCounts[$Ext] = [Int64]1
            }
        }
    }
}

function Show-LargestFiles {

    Write-Header "LARGEST FILES (>= $(Format-Size $script:LargeFileThresholdBytes))"

    if ($script:LargeFiles.Count -eq 0) {
        Write-Host "No individual files met the threshold." -ForegroundColor Gray
        return
    }

    $script:LargeFiles |
        Sort-Object Size -Descending |
        Select-Object -First $TopFiles |
        ForEach-Object {

            Write-Host (
                "{0,-12} {1}" -f
                (Format-Size $_.Size),
                $_.Path
            ) -ForegroundColor Yellow
        }
}

function Show-ExtensionBreakdown {

    Write-Header "EXTENSION BREAKDOWN (Top $TopExtensions)"

    $ExtData = New-Object System.Collections.ArrayList

    foreach ($Ext in $script:ExtensionSizes.Keys) {

        # Skip 0-byte extensions â€” empty files contribute nothing to disk analysis
        if ($script:ExtensionSizes[$Ext] -le 0) {
            continue
        }

        $null = $ExtData.Add([PSCustomObject]@{
            Extension = $Ext
            TotalSize = $script:ExtensionSizes[$Ext]
            FileCount = $script:ExtensionCounts[$Ext]
        })
    }

    if ($ExtData.Count -eq 0) {
        Write-Host "No file data collected." -ForegroundColor Gray
        return
    }

    $GrandTotal = ($ExtData | Measure-Object TotalSize -Sum).Sum

    $ExtData |
        Sort-Object TotalSize -Descending |
        Select-Object -First $TopExtensions |
        ForEach-Object {

            $Percent = 0
            if ($GrandTotal -gt 0) {
                $Percent = ($_.TotalSize / $GrandTotal) * 100
            }

            Write-Host (
                "{0,-10} {1,12} {2,8:N0} files [{3}] {4,5:N1}%" -f
                $_.Extension,
                (Format-Size $_.TotalSize),
                $_.FileCount,
                (New-Bar $Percent),
                $Percent
            ) -ForegroundColor (Get-UsageColor $Percent)
        }
}

# ---------------------------------------------------------------------------
# Disk info
# ---------------------------------------------------------------------------

function Show-DiskInfo {

    param([string]$DriveLetter)

    $Drive = $DriveLetter.TrimEnd('\')

    $Disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$Drive'" -ErrorAction SilentlyContinue

    if ($null -eq $Disk) {
        return
    }

    $Total = [Int64]$Disk.Size
    $Free = [Int64]$Disk.FreeSpace
    $Used = $Total - $Free

    Write-Host ("Drive : {0}" -f $Drive) -ForegroundColor White
    Write-Host ("Total : {0}" -f (Format-Size $Total)) -ForegroundColor White
    Write-Host ("Used  : {0}" -f (Format-Size $Used)) -ForegroundColor Yellow
    Write-Host ("Free  : {0}" -f (Format-Size $Free)) -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# CSV export
# ---------------------------------------------------------------------------

function Export-ResultsCsv {

    param([string]$BasePath)

    $Dir = Split-Path $BasePath -Parent
    if (-not (Test-Path $Dir)) {
        try {
            New-Item -ItemType Directory -Path $Dir -Force -ErrorAction SilentlyContinue | Out-Null
        }
        catch {
            Write-Host "Cannot create export directory: $Dir" -ForegroundColor Red
            return
        }
    }

    $Rows = New-Object System.Collections.ArrayList

    # Root folders
    if ($null -ne $script:RootFolderData) {
        foreach ($R in $script:RootFolderData) {
            $null = $Rows.Add([PSCustomObject]@{
                Category    = "RootFolder"
                Path        = $R.Path
                SizeBytes   = $R.Size
                FormattedSize = (Format-Size $R.Size)
            })
        }
    }

    # Cleanup candidates
    $script:CleanupCandidates |
        Sort-Object Size -Descending |
        Group-Object Path |
        ForEach-Object { $_.Group[0] } |
        Select-Object -First 20 |
        ForEach-Object {
            $null = $Rows.Add([PSCustomObject]@{
                Category    = "CleanupCandidate"
                Path        = $_.Path
                SizeBytes   = $_.Size
                FormattedSize = (Format-Size $_.Size)
            })
        }

    # Largest files
    $script:LargeFiles |
        Sort-Object Size -Descending |
        Select-Object -First $TopFiles |
        ForEach-Object {
            $null = $Rows.Add([PSCustomObject]@{
                Category    = "LargeFile"
                Path        = $_.Path
                SizeBytes   = $_.Size
                FormattedSize = (Format-Size $_.Size)
            })
        }

    # Extension breakdown (skip 0-byte entries)
    foreach ($Ext in $script:ExtensionSizes.Keys) {
        if ($script:ExtensionSizes[$Ext] -le 0) {
            continue
        }
        $null = $Rows.Add([PSCustomObject]@{
            Category    = "Extension"
            Path        = $Ext
            SizeBytes   = $script:ExtensionSizes[$Ext]
            FormattedSize = (Format-Size $script:ExtensionSizes[$Ext])
        })
    }

    try {
        $Rows | Export-Csv -Path $BasePath -NoTypeInformation -Encoding UTF8
        Write-Host "Exported $($Rows.Count) rows to $BasePath" -ForegroundColor Green
    }
    catch {
        Write-Host "Export failed: $_" -ForegroundColor Red
    }
}

# ===========================================================================
# MAIN
# ===========================================================================

Write-Header "DISK USAGE REPORT"

Show-DiskInfo -DriveLetter ([System.IO.Path]::GetPathRoot($Path)) | Out-Null

Write-Host ""
Write-Host "Scanning root folders..." -ForegroundColor Cyan

$RootFolders = Get-LargestChildren -ParentPath $Path -ShowProgress

if ($null -eq $RootFolders) {
    $RootFolders = @()
}

$script:RootFolderData = $RootFolders

$MeasuredTotal = [Int64]0

if ($RootFolders.Count -gt 0) {
    $MeasureResult = ($RootFolders | Measure-Object Size -Sum)
    if ($null -ne $MeasureResult -and $null -ne $MeasureResult.Sum) {
        $MeasuredTotal = [Int64]$MeasureResult.Sum
    }
}

Write-Header "TOP ROOT FOLDERS"

foreach ($Root in ($RootFolders | Select-Object -First 20)) {

    $Percent = 0
    if ($MeasuredTotal -gt 0) {
        $Percent = ($Root.Size / $MeasuredTotal) * 100
    }

    $Tag = if ($Root.IsJunction) { " [J]" } else { "" }

    Write-Host (
        "{0,-12} [{1}] {2,5:N1}% {3}{4}" -f `
        (Format-Size $Root.Size),
        (New-Bar $Percent),
        $Percent,
        $Root.Path,
        $Tag
    ) -ForegroundColor (Get-UsageColor $Percent)
}

Show-ImportantFolders

Write-Header "ACTIONABLE SPACE HOGS"

foreach ($Root in ($RootFolders | Select-Object -First $TopRoots)) {

    Write-Host ""
    Write-Host (
        "{0} ({1})" -f `
        $Root.Path,
        (Format-Size $Root.Size)
    ) -ForegroundColor Cyan

    Show-Hogs `
        -Folder $Root.Path `
        -ParentSize $Root.Size `
        -Level 1 `
        -MaxDepth $Depth
}

# Collect file stats from the top roots (single pass for both sections)
Write-Host ""
Write-Host "Scanning for large files and extension breakdown..." -ForegroundColor Cyan

$TopRootFolders = $RootFolders | Select-Object -First $TopRoots
Collect-FileStats -RootFolders $TopRootFolders

Show-LargestFiles
Show-ExtensionBreakdown

Write-Header "CLEANUP OPPORTUNITIES"

$PotentialRecovery = [Int64]0

$script:CleanupCandidates |
    Sort-Object Size -Descending |
    Group-Object Path |
    ForEach-Object { $_.Group[0] } |
    Select-Object -First 20 |
    ForEach-Object {

        $PotentialRecovery += $_.Size

        Write-Host (
            "{0,-12} {1}" -f `
            (Format-Size $_.Size),
            $_.Path
        ) -ForegroundColor Magenta
    }

$RecoveryGB = $PotentialRecovery / 1GB

$RecoveryColor = "Green"

if ($RecoveryGB -ge 100) {
    $RecoveryColor = "Red"
}
elseif ($RecoveryGB -ge 25) {
    $RecoveryColor = "Yellow"
}

Write-Host ""
Write-Host (
    "Potential Recovery: {0}" -f
    (Format-Size $PotentialRecovery)
) -ForegroundColor $RecoveryColor

if (-not [string]::IsNullOrEmpty($ExportCsv)) {
    Write-Header "CSV EXPORT"
    Export-ResultsCsv -BasePath $ExportCsv
}

Write-Header "COMPLETE"

Write-Host ""
Write-Host "Cache stats: $($script:FolderSizeCache.Count) folders cached, $($script:LargeFiles.Count) large files found." -ForegroundColor DarkGray
