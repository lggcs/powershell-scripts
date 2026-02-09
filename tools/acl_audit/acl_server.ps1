# PowerShell ACL Dashboard Server - Fast Startup Version
param(
    [int]$Port = 5000,
    [string]$DataFile = "acl_data_light.json",
    [switch]$Help
)

if ($Help) {
    Write-Host @"
========================================
ACL Dashboard Server - Usage
========================================

Serves the ACL Audit Dashboard web interface and API.

PARAMETERS:
  -Port       <int>       (Optional) HTTP port to listen on (default: 5000)
  -DataFile   <string>    (Optional) JSON data file path (default: acl_data_light.json)
                                Can be relative (from script dir) or absolute path
  -Help                   (Optional) Show this help message

EXAMPLES:
  # Default usage (port 5000, acl_data_light.json)
  .\acl_server.ps1

  # Custom port
  .\acl_server.ps1 -Port 8080

  # Custom data file
  .\acl_server.ps1 -DataFile "acl_data.json"

  # Absolute path to data file
  .\acl_server.ps1 -DataFile "C:\Data\my_acl.json"

  # Both custom port and data file
  .\acl_server.ps1 -Port 3000 -DataFile "custom.json"

DASHBOARD:
  Open http://127.0.0.1:5000 in your browser after starting

========================================
"@ -ForegroundColor Cyan
    exit 0
}

$ErrorActionPreference = "Stop"

Write-Host "Loading ACL data..." -ForegroundColor Cyan

# Load ACL data
# If DataFile is a relative path, resolve from script directory
if ([System.IO.Path]::IsPathRooted($DataFile)) {
    $dataFilePath = $DataFile
} else {
    $dataFilePath = Join-Path $PSScriptRoot $DataFile
}

if (-not (Test-Path $dataFilePath)) {
    Write-Error "Data file not found: $dataFilePath"
    exit 1
}

Write-Host "  File: $dataFilePath" -ForegroundColor Gray

Write-Host "Loading 213MB file... (15-30 seconds)" -ForegroundColor Yellow
$jsonContent = [System.IO.File]::ReadAllText($dataFilePath, [System.Text.Encoding]::UTF8)
$aclData = $jsonContent | ConvertFrom-Json

Write-Host "ACL data loaded." -ForegroundColor Green

# Extract server names
$servers = $aclData.PSObject.Properties.Name
foreach ($server in $servers) {
    Write-Host "  - $server" -ForegroundColor Gray
}

# Build ONLY path cache (fast!) - User index will be built dynamically on first search
Write-Host "Building path cache..." -ForegroundColor Cyan

$pathCache = @{} # "path|server" -> node

function BuildPathCache-Iterative {
    param($Data, $ServerName)

    $stack = [System.Collections.Generic.Stack[Object]]::new()

    foreach ($folder in $Data) {
        $stack.Push($folder)
    }

    $processed = 0
    $startTime = Get-Date

    while ($stack.Count -gt 0) {
        $item = $stack.Pop()

        if ($item -and $item.path) {
            $processed++
            # Normalize path to single backslashes when building cache
            $normalizedPath = ($item.path) -replace '\\+', '\'
            $key = $normalizedPath + "|" + $ServerName
            $pathCache[$key] = $item

            if ($item.children) {
                foreach ($child in $item.children) {
                    $stack.Push($child)
                }
            }
        }

        if ($processed % 5000 -eq 0) {
            $elapsed = [Math]::Round(((Get-Date) - $startTime).TotalSeconds, 0)
            Write-Host "`r      Cached $processed folders ($elapsed sec)" -NoNewline
        }
    }

    return $processed
}

$nodeCount = 0
$startTime = Get-Date

foreach ($server in $servers) {
    Write-Host "`n  Caching $server..." -ForegroundColor DarkGray
    $folders = $aclData.$server
    if ($folders) {
        $serverNodes = BuildPathCache-Iterative $folders $server
        $nodeCount += $serverNodes
    }
}

$elapsed = [Math]::Round(((Get-Date) - $startTime).TotalSeconds, 0)
Write-Host "`r  Path cache complete: $nodeCount folders in $elapsed seconds" -ForegroundColor Green
Write-Host ""

# Lazy user index - only built when first search is performed
$script:userIndex = $null
$script:userIndexBuilt = $false

function EnsureUserIndex {
    if (-not $script:userIndexBuilt) {
        Write-Host "Building user index (first search only)..." -ForegroundColor Cyan
        $script:userIndex = @{}
        $startTime = Get-Date
        $processed = 0

        # Pre-split all keys once (much faster than splitting each time)
        $keyParts = @{}
        foreach ($key in $pathCache.Keys) {
            $parts = $key.Split('|')
            $keyParts[$key] = @{server=$parts[1]; path=$parts[0]}
        }

        foreach ($entry in $pathCache.GetEnumerator()) {
            $node = $entry.Value
            $key = $entry.Key

            if ($node.users) {
                $server = $keyParts[$key].server
                $path = $keyParts[$key].path

                foreach ($perm in $node.users.PSObject.Properties) {
                    $usersArray = $perm.Value
                    if ($usersArray -is [System.Collections.IEnumerable] -and $usersArray -isnot [string]) {
                        foreach ($user in $usersArray) {
                            $username = $user.identity.ToLower()
                            if (-not $script:userIndex.ContainsKey($username)) {
                                $script:userIndex[$username] = [System.Collections.ArrayList]@()
                            }
                            $null = $script:userIndex[$username].Add(@{
                                path = $path
                                server = $server
                                permission_type = $perm.Name
                                user_data = $user
                            })
                        }
                    }
                }
            }

            $processed++
            if ($processed % 5000 -eq 0) {
                $elapsed = [Math]::Round(((Get-Date) - $startTime).TotalSeconds, 0)
                Write-Host "`r      Indexed $processed entries ($elapsed sec)" -NoNewline
            }
        }

        $elapsed = [Math]::Round(((Get-Date) - $startTime).TotalSeconds, 0)
        Write-Host "`r  User index built: $($script:userIndex.Count) users, $processed entries in $elapsed seconds" -ForegroundColor Green
        $script:userIndexBuilt = $true
    }
}

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "ACL Audit Dashboard is now running!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Local access:  http://127.0.0.1:$Port" -ForegroundColor White
Write-Host ""
Write-Host "Press Ctrl+C to stop the server" -ForegroundColor Gray
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# Find node from cache
function FindNode($path, $server) {
    # Normalize path - replace double backslashes with single
    $normalizedPath = $path -replace '\\+', '\'
    $key = $normalizedPath + "|" + $server

    if ($pathCache.ContainsKey($key)) {
        return $pathCache[$key]
    }
    return $null
}

function Get-Stats($statsObj) {
    # Return stats as a hashtable (not PSCustomObject)
    $result = @{}
    if ($statsObj -and $statsObj.PSObject.Properties) {
        foreach ($prop in $statsObj.PSObject.Properties) {
            $result[$prop.Name] = $prop.Value
        }
    }
    # Ensure required fields exist
    if (-not $result.ContainsKey('FullControl')) { $result['FullControl'] = 0 }
    if (-not $result.ContainsKey('Modify')) { $result['Modify'] = 0 }
    if (-not $result.ContainsKey('Read')) { $result['Read'] = 0 }
    return $result
}

function Convert-ToJsonString($obj) {
    try {
        # For PSCustomObject, ensure it converts properly
        if ($obj -is [PSCustomObject]) {
            # Convert to hashtable first for proper serialization
            $ht = @{}
            foreach ($prop in $obj.PSObject.Properties) {
                $ht[$prop.Name] = $prop.Value
            }
            $json = $ht | ConvertTo-Json -Depth 10 -Compress
        }
        else {
            $json = $obj | ConvertTo-Json -Depth 10 -Compress
        }

        # Fix: PowerShell 5.x returns single object instead of array for single-item arrays
        if ($obj -is [Array] -and -not $json.TrimStart().StartsWith('[')) {
            $json = '[' + $json + ']'
        }

        return $json
    }
    catch {
        Write-Host "JSON error: $_" -ForegroundColor Red
        return '{}'
    }
}

# Create listener
$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add("http://127.0.0.1:$Port/")
$listener.Start()

$requestCount = 0

try {
    while ($listener.IsListening) {
        $context = $listener.GetContext()
        $request = $context.Request
        $response = $context.Response
        
        $requestCount++
        $url = $request.Url.LocalPath
        $queryString = $request.Url.Query
        
        if ($requestCount -le 10 -or $requestCount % 100 -eq 0) {
            Write-Host "[$requestCount] $request.HttpMethod $url" -ForegroundColor Gray
        }

        try {
            $responseData = ""
            $contentType = "application/json"
            $statusCode = 200

            $queryParams = @{}
            if ($queryString.Length -gt 0) {
                $qs = $queryString.Substring(1).Split('&')
                foreach ($param in $qs) {
                    $parts = $param.Split('=')
                    if ($parts.Length -eq 2) {
                        $key = [System.Web.HttpUtility]::UrlDecode($parts[0])
                        $val = [System.Web.HttpUtility]::UrlDecode($parts[1])
                        $queryParams[$key] = $val
                    }
                }
            }

            if ($url -eq "/" -or $url -eq "/index.html") {
                $htmlPath = Join-Path $PSScriptRoot "acl_dashboard.html"
                if (Test-Path $htmlPath) {
                    $responseData = [System.IO.File]::ReadAllText($htmlPath)
                    $contentType = "text/html"
                } else {
                    $statusCode = 404
                    $responseData = '{"error": "HTML file not found"}'
                }
            }
            elseif ($url -eq "/api/roots") {
                $roots = @()
                foreach ($server in $servers) {
                    $folders = $aclData.$server
                    if ($folders) {
                        foreach ($folder in $folders) {
                            # Normalize the path
                            $normalizedPath = ($folder.path) -replace '\\+', '\'
                            $roots += [PSCustomObject]@{
                                name = $server + "\" + ($folder.name)
                                server = $server
                                path = $normalizedPath
                                stats = Get-Stats $folder.stats
                                has_children = $folder.children -and $folder.children.Count -gt 0
                            }
                        }
                    }
                }
                $responseData = Convert-ToJsonString @($roots)
            }
            elseif ($url -eq "/api/children" -and $queryParams.ContainsKey('path')) {
                $reqPath = $queryParams['path']
                $server = $queryParams['server']
                $node = FindNode $reqPath $server
                if ($node) {
                    $children = @()
                    if ($node.children) {
                        foreach ($child in $node.children) {
                            # Normalize child path
                            $normalizedPath = ($child.path) -replace '\\+', '\'
                            $children += [PSCustomObject]@{
                                name = $child.name
                                path = $normalizedPath
                                stats = Get-Stats $child.stats
                                has_children = $child.children -and $child.children.Count -gt 0
                            }
                        }
                    }
                    $responseData = Convert-ToJsonString @($children)
                } else {
                    $statusCode = 404
                    $responseData = '{"error": "Node not found"}'
                }
            }
            elseif ($url -eq "/api/node" -and $queryParams.ContainsKey('path')) {
                $reqPath = $queryParams['path']
                $server = $queryParams['server']
                $node = FindNode $reqPath $server
                if ($node) {
                    $normalizedPath = ($node.path) -replace '\\+', '\'
                    $stats = Get-Stats $node.stats
                    $hasChildren = $node.children -and $node.children.Count -gt 0

                    # Build response as hashtable to avoid PSCustomObject issues
                    $responseHash = @{
                        name = $node.name
                        path = $normalizedPath
                        stats = $stats
                        users = $node.users
                        has_children = $hasChildren
                    }

                    $responseData = Convert-ToJsonString $responseHash
                } else {
                    $statusCode = 404
                    $responseData = '{"error": "Node not found"}'
                }
            }
            elseif ($url -eq "/api/search") {
                $query = if ($queryParams.ContainsKey('q')) { $queryParams['q'].Trim().ToLower() } else { "" }

                if ($query.Length -ge 1) {
                    # Build user index on first search
                    EnsureUserIndex

                    # Collect results faster using ArrayList
                    $resultsList = [System.Collections.ArrayList]@()
                    foreach ($kv in $script:userIndex.GetEnumerator()) {
                        if ($kv.Key -like "*$query*") {
                            # Convert ArrayList to array and add to results
                            $resultsList.AddRange($kv.Value.ToArray())
                        }
                    }

                    # Group by path+server
                    $grouped = @{}
                    foreach ($item in $resultsList) {
                        $key = $item.path + "|" + $item.server
                        if (-not $grouped.ContainsKey($key)) {
                            $grouped[$key] = @{path=$item.path; server=$item.server; permissions=[System.Collections.ArrayList]@()}
                        }
                        $null = $grouped[$key].permissions.Add(@{type=$item.permission_type; user=$item.user_data})
                    }

                    # Convert permissions ArrayList to array for JSON
                    $finalResults = $grouped.Values | ForEach-Object {
                        $_.permissions = @($_.permissions.ToArray())
                        [PSCustomObject]$_
                    }

                    $responseData = Convert-ToJsonString @{
                        results = @($finalResults)
                        count = $finalResults.Count
                    }
                } else {
                    $statusCode = 400
                    $responseData = '{"error": "Query required"}'
                }
            }
            else {
                $statusCode = 404
                $responseData = '{"error": "Not found"}'
            }

            $response.Headers.Add("Access-Control-Allow-Origin", "*")
            
            if ($request.HttpMethod -eq "OPTIONS") {
                $response.StatusCode = 200
            } else {
                $buffer = [System.Text.Encoding]::UTF8.GetBytes($responseData)
                $response.ContentLength64 = $buffer.Length
                $response.ContentType = $contentType
                $response.StatusCode = $statusCode
                $response.OutputStream.Write($buffer, 0, $buffer.Length)
            }
            $response.OutputStream.Close()

        }
        catch {
            $errorJson = '{"error":"' + $_.Exception.Message.Replace('"', '\"') + '"}'
            $buffer = [System.Text.Encoding]::UTF8.GetBytes($errorJson)
            $response.ContentLength64 = $buffer.Length
            $response.StatusCode = 500
            $response.OutputStream.Write($buffer, 0, $buffer.Length)
            $response.OutputStream.Close()
        }
    }
}
finally {
    $listener.Stop()
    $listener.Close()
    Write-Host "`nServer stopped. Total requests: $requestCount" -ForegroundColor Yellow
}