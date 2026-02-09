# ACL Data Gatherer - Directly exports to JSON format for ACL Dashboard

param(
    [string]$Path = "",
    [string]$ServerName = "",
    [string]$OutputPath = (Join-Path $PSScriptRoot "acl_data_light.json"),
    [switch]$VerboseMode,
    [switch]$Help
)

if ($Help) {
    Write-Host @"
========================================
ACL Data Gatherer - Usage
========================================

Gathers ACL permissions from a directory tree and exports to JSON for the ACL Dashboard.

PARAMETERS:
  -Path        <string>    (Required) Root directory path to scan
  -ServerName  <string>    (Required) Name to identify this server in the dashboard
  -OutputPath  <string>    (Optional) Output JSON file path (default: acl_data_light.json)
  -VerboseMode             (Optional) Show detailed progress messages
  -Help                   (Optional) Show this help message

EXAMPLES:
  # Basic usage
  .\Gather-ACLsDirect.ps1 -Path "C:\Data" -ServerName "FileServer01"

  # Specify custom output file
  .\Gather-ACLsDirect.ps1 -Path "C:\Data" -ServerName "FileServer01" -OutputPath "customacl.json"

  # Verbose mode
  .\Gather-ACLsDirect.ps1 -Path "C:\Data" -ServerName "FileServer01" -VerboseMode

========================================
"@ -ForegroundColor Cyan
    exit 0
}

# Check if required parameters are missing (when run without arguments)
if (-not $Path -or -not $ServerName) {
    Write-Host @"
========================================
ACL Data Gatherer - Usage
========================================

Gathers ACL permissions from a directory tree and exports to JSON for the ACL Dashboard.

PARAMETERS:
  -Path        <string>    (Required) Root directory path to scan
  -ServerName  <string>    (Required) Name to identify this server in the dashboard
  -OutputPath  <string>    (Optional) Output JSON file path (default: acl_data_light.json)
  -VerboseMode             (Optional) Show detailed progress messages
  -Help                   (Optional) Show this help message

EXAMPLES:
  # Basic usage
  .\Gather-ACLsDirect.ps1 -Path "C:\Data" -ServerName "FileServer01"

  # Specify custom output file
  .\Gather-ACLsDirect.ps1 -Path "C:\Data" -ServerName "FileServer01" -OutputPath "customacl.json"

  # Verbose mode
  .\Gather-ACLsDirect.ps1 -Path "C:\Data" -ServerName "FileServer01" -VerboseMode

========================================
"@ -ForegroundColor Cyan
    exit 0
}

if (-not (Test-Path $Path)) {
    Write-Error "Path not found: $Path"
    exit 1
}

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "ACL Data Gatherer" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Target: $Path" -ForegroundColor White
Write-Host "Server: $ServerName" -ForegroundColor White
Write-Host "Output: $OutputPath" -ForegroundColor White
Write-Host ""

# Permission categorization function
function Get-PermissionType($rights) {
    if ($null -eq $rights) { return "Read" }
    $rightsStr = $rights.ToString()
    $rightsUpper = $rightsStr.ToUpper()
    
    if ($rightsUpper -match "FULLCONTROL" -or $rightsUpper -match "FULL CONTROL") {
        return "FullControl"
    }
    elseif ($rightsUpper -match "MODIFY") {
        return "Modify"
    }
    else {
        return "Read"
    }
}

# User key generator (matches ACL data format)
function New-UserKey($identity, $permissionType, $inherited) {
    $sanitizedIdentity = $identity -replace '\\', '_' -replace '.', '_' -replace ' ', '_'
    return "${sanitizedIdentity}_${permissionType}_$inherited"
}

# Progress tracking
$totalFolders = 0
$processedFolders = 0

# Count folders first for progress bar
Write-Host "Counting folders..." -ForegroundColor Yellow
$totalFolders = @(Get-ChildItem -Path $Path -Directory -Recurse -ErrorAction SilentlyContinue).Count
Write-Host "Found $totalFolders folders" -ForegroundColor Green
Write-Host ""

# Build folder structure using queue-based iteration (avoids stack overflow)
Write-Host "Building ACL data structure..." -ForegroundColor Yellow

$rootNode = @{
    name = (Split-Path $Path -Leaf)
    path = $Path -replace '\\', '\\'
    stats = @{FullControl = 0; Modify = 0; Read = 0}
    users = @{FullControl = @(); Modify = @(); Read = @()}
    children = [System.Collections.ArrayList]@()
}

$queue = [System.Collections.Queue]::new()
$processedFolders = 0
$startTime = Get-Date

# Initialize with root item
$rootItem = Get-Item -Path $Path -Force
$queue.Enqueue(@($rootItem, $rootNode))

# Dictionary to store nodes by path for building structure
$nodeMap = @{}
$nodeMap[$Path] = $rootNode

function Process-Folder($folder, $parentNode) {
    try {
        $acl = Get-Acl $folder.FullName -ErrorAction Stop

        $users = @{
            FullControl = [System.Collections.ArrayList]@()
            Modify = [System.Collections.ArrayList]@()
            Read = [System.Collections.ArrayList]@()
        }

        $stats = @{
            FullControl = 0
            Modify = 0
            Read = 0
        }

        $skippedCount = 0
        $allowedCount = 0

        foreach ($access in $acl.Access) {
            # Skip inherited Deny entries for cleaner data
            if ($access.AccessControlType -eq "Deny" -and $access.IsInherited) {
                continue
            }

            # Skip built-in accounts unless desired
            $identity = $access.IdentityReference.Value
            $identityUpper = $identity.ToUpper()

            # Only allow "Allow" permissions by default
            if ($access.AccessControlType -ne "Allow") {
                if ($VerboseMode) {
                    Write-Host "    FILTERED: $identity - Not Allow type" -ForegroundColor DarkGray
                }
                continue
            }

            # Skip common system accounts (optional - comment out if needed)
            if ($identityUpper -in @(
                "NT AUTHORITY\SYSTEM", "NT AUTHORITY\AUTHENTICATED USERS",
                "BUILTIN\Administrators", "BUILTIN\Users", "BUILTIN\CREATOR OWNER",
                "EVERYONE"
            )) {
                $skippedCount++
                if ($VerboseMode) {
                    Write-Host "    FILTERED: $identity - System account" -ForegroundColor DarkGray
                }
                continue
            }
            
            $permType = Get-PermissionType $access.FileSystemRights
            $isInherited = $access.IsInherited
            $key = New-UserKey $identity $permType $isInherited

            $userObj = @{
                key = $key
                identity = $identity
                rights = $permType
                access_type = if ($access.AccessControlType -eq "Allow") { "Allow" } else { "Deny" }
                inherited = $isInherited
            }

            [void]$users[$permType].Add($userObj)
            $stats[$permType]++
            $allowedCount++
        }

        if ($VerboseMode -and ($allowedCount -gt 0 -or $skippedCount -gt 0)) {
            Write-Host "  ACL: $($folder.FullName)" -ForegroundColor DarkGray
            Write-Host "    Allowed: $allowedCount, Filtered: $skippedCount" -ForegroundColor DarkGray
            Write-Host "    Users: FullControl=$($stats.FullControl), Modify=$($stats.Modify), Read=$($stats.Read)" -ForegroundColor DarkGray
        }
        
        # Debug: Show data BEFORE conversion
        if ($VerboseMode) {
            Write-Host "    BEFORE conversion: FC count = $($users.FullControl.Count), type = $($users.FullControl.GetType().Name)" -ForegroundColor Yellow
        }

        # Clean up empty arrays - set to empty arrays for consistent JSON
        $userKeys = @($users.Keys)  # Get keys first to avoid collection modification issues
        foreach ($key in $userKeys) {
            if ($users[$key].Count -eq 0) {
                $users[$key] = @()
            } else {
                $temp = $users[$key]
                $users[$key] = @($temp)
            }
        }

        # Create a snapshot of the users data (not a reference)
        $result = @{
            stats = @{
                FullControl = $stats.FullControl
                Modify = $stats.Modify
                Read = $stats.Read
            }
            users = @{
                FullControl = [System.Collections.ArrayList]@($users.FullControl)
                Modify = [System.Collections.ArrayList]@($users.Modify)
                Read = [System.Collections.ArrayList]@($users.Read)
            }
        }

        return $result
    }
    catch {
        if ($VerboseMode) {
            Write-Warning "Could not get ACL for $($folder.FullName): $_"
        }
        return @{
            stats = @{FullControl = 0; Modify = 0; Read = 0}
            users = @{FullControl = @(); Modify = @(); Read = @()}
        }
    }
}

# Process root first
$rootResult = Process-Folder $rootItem $null
$rootNode.stats = $rootResult.stats
$rootNode.users = $rootResult.users

$processedFolders++
$lastProgress = 0

Write-Host "Processing folders (with progress)..." -ForegroundColor Yellow

while ($queue.Count -gt 0) {
    $folderItem, $parentData = $queue.Dequeue()
    
    if ($folderItem.FullName -ne $Path) {
        # Process this folder
        $result = Process-Folder $folderItem $null
        
        $folderNode = @{
            name = $folderItem.Name
            path = ($folderItem.FullName -replace '\\', '\\')
            stats = $result.stats
            users = $result.users
            children = [System.Collections.ArrayList]@()
        }

        # Debug: Verify data after folderNode creation
        if ($VerboseMode -and $folderNode.users.FullControl.Count -gt 0) {
            Write-Host "    folderNode users: FC count = $($folderNode.users.FullControl.Count)" -ForegroundColor Magenta
            Write-Host "      folderNode sample: $($folderNode.users.FullControl[0].identity)" -ForegroundColor Magenta
        }

        # Add to parent's children
        [void]$parentData.children.Add($folderNode)

        # Debug: Verify data after adding to children array
        if ($VerboseMode -and $folderItem.Name -eq "4. Intake Policies and Procedures") {
            Write-Host "    After Add to children: FC count = $($parentData.children[-1].users.FullControl.Count)" -ForegroundColor Magenta
        }

        # Store in map
        $nodeMap[$folderItem.FullName] = $folderNode

        # Debug: Verify data in map
        if ($VerboseMode -and $folderItem.Name -eq "4. Intake Policies and Procedures") {
            Write-Host "    In nodeMap: FC count = $($nodeMap[$folderItem.FullName].users.FullControl.Count)" -ForegroundColor Magenta
        }
    }
    
    # Get children and enqueue
    try {
        $children = Get-ChildItem -Path $folderItem.FullName -Directory -ErrorAction SilentlyContinue
        
        $childrenByPath = @{}
        foreach ($child in $children) {
            $childrenByPath[$child.FullName] = $child
        }
        
        # Sort by full path to ensure consistent structure
        $sortedChildren = $childrenByPath.Keys | Sort-Object
        
        foreach ($childPath in $sortedChildren) {
            $child = $childrenByPath[$childPath]
            $processedFolders++
            
            # Find the parent node for this child
            $childParentPath = Split-Path $childPath -Parent
            if ($nodeMap.ContainsKey($childParentPath)) {
                $childParentNode = $nodeMap[$childParentPath]
                $queue.Enqueue(@($child, $childParentNode))
            }
        }
    }
    catch {
        if ($VerboseMode) {
            Write-Warning "Could not enumerate children for $($folderItem.FullName): $_"
        }
    }
    
    # Show progress
    if ($totalFolders -gt 0) {
        $progress = [Math]::Round(($processedFolders / $totalFolders) * 100)
        $now = Get-Date
        $elapsed = ($now - $startTime).TotalSeconds
        
        if ($progress -ge $lastProgress + 5 -or $progress -eq 100) {
            Write-Host "`r  Progress: $progress% ($processedFolders/$totalFolders folders, $($elapsed.ToString('0')) sec)" -NoNewline
            $lastProgress = $progress
        }
    }
}

Write-Host ""
$elapsed = [Math]::Round(((Get-Date) - $startTime).TotalSeconds, 0)
Write-Host "Processed $processedFolders folders in $elapsed seconds" -ForegroundColor Green
Write-Host ""

# Convert hashtables to PSCustomObjects for proper JSON serialization
function Convert-NodeToPSCustomObject($node) {
    # Convert children
    $childObjects = @()
    if ($node.children) {
        foreach ($child in $node.children) {
            $childObjects += Convert-NodeToPSCustomObject $child
        }
    }

    # Convert users arrays to PSCustomObjects
    $fcUsers = @()
    $modUsers = @()
    $readUsers = @()

    if ($node.users.FullControl) { foreach ($u in $node.users.FullControl) { $fcUsers += [PSCustomObject]$u } }
    if ($node.users.Modify) { foreach ($u in $node.users.Modify) { $modUsers += [PSCustomObject]$u } }
    if ($node.users.Read) { foreach ($u in $node.users.Read) { $readUsers += [PSCustomObject]$u } }

    # Return as PSCustomObject
    [PSCustomObject]@{
        name = $node.name
        path = $node.path
        stats = [PSCustomObject]$node.stats
        users = [PSCustomObject]@{
            FullControl = $fcUsers
            Modify = $modUsers
            Read = $readUsers
        }
        children = $childObjects
    }
}

$rootObject = Convert-NodeToPSCustomObject $rootNode

# Build final JSON structure
$output = @{}
$output[$ServerName] = @($rootObject)

# Convert to JSON
Write-Host "Converting to JSON..." -ForegroundColor Yellow

$jsonOutput = $output | ConvertTo-Json -Depth 100 -Compress

# Get file size
$fileSizeMB = [Math]::Round($jsonOutput.Length / 1MB, 2)

# Write to file
$jsonOutput | Out-File -FilePath $OutputPath -Encoding UTF8 -Force

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Complete!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Output: $OutputPath" -ForegroundColor White
Write-Host "Size: $fileSizeMB MB" -ForegroundColor White
Write-Host "Servers: 1 ($ServerName)" -ForegroundColor White
Write-Host "Folders: $processedFolders" -ForegroundColor White
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "To use with dashboard:" -ForegroundColor Yellow
Write-Host "  powershell -ExecutionPolicy Bypass -File .\acl_server.ps1" -ForegroundColor Gray
Write-Host ""