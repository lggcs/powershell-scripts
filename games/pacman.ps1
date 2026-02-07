# PowerShell Pac-Man: Master Grid Rebuild
$ErrorActionPreference = "SilentlyContinue"

# 1. Setup
$W = 64; $H = 35
$host.UI.RawUI.WindowSize = New-Object System.Management.Automation.Host.Size($W, $H)
$host.UI.RawUI.BufferSize = New-Object System.Management.Automation.Host.Size($W, $H)
[Console]::CursorVisible = $false
[Console]::Clear()

# 2. Rebuilt Map (28x21) - Audited Connectivity
# Legend: # = Wall, . = Dot, * = Power, - = Ghost Gate, G = Ghost Spawn, P = Pacman Spawn
# 2. Rebuilt Map (30x21) - No dead ends, proper Ghost House, and Teleport
$RawMap = @(
    "############################",
    "#............##............#",
    "#.####.#####.##.#####.####.#",
    "#*#  #.#   #.##.#   #.#  #*#",
    "#.####.#####.##.#####.####.#",
    "#..........................#",
    "#.####.#.##########.#.####.#",
    "#......#.....##.....#......#",
    "######.#####.##.#####.######",
    "............................",
    "##.###.#####----#####.###.##",
    "##.###.#   GGGG     #.###.##",
    "##.###.##############.###.##",
    "#............##............#",
    "#.####.#####.##.#####.####.#",
    "#.####.#####.##.#####.####.#",
    "#*...#.......P........#...*#",
    "#.##.#.#.##########.#.#.####",
    "#......#.....##.....#......#",
    "############....############",
    "############################"
)

# 3. Dynamic Initialization
$Score = 0; $Lives = 3; $Frame = 0; $PowerTimer = 0
$Pac = @{ X = 0; Y = 0; Dir = "Left"; NextDir = "Left" }
$Ghosts = @()
$GhostColors = @("Red", "Magenta", "Cyan", "Yellow")

$GridHeight = $RawMap.Count
$GridWidth = $RawMap[0].Length
$Grid = New-Object "string[][]" $GridHeight
$TotalDots = 0

for($y=0; $y -lt $GridHeight; $y++) {
    $line = $RawMap[$y].ToCharArray()
    $Grid[$y] = New-Object string[] $GridWidth
    for($x=0; $x -lt $GridWidth; $x++) {
        $char = $line[$x].ToString()
        if ($char -eq "G") {
            if ($Ghosts.Count -lt 4) {
                $Ghosts += @{ X=$x; Y=$y; Color=$GhostColors[$Ghosts.Count]; Dir="Up" }
            }
            $Grid[$y][$x] = " "
        }
        elseif ($char -eq "P") {
            $Pac.X = $x; $Pac.Y = $y
            $Grid[$y][$x] = " "
        }
        elseif ($char -eq ".") { $TotalDots++; $Grid[$y][$x] = "." }
        else { $Grid[$y][$x] = $char }
    }
}

function Draw-Tile($x, $y) {
    if ($x -lt 0 -or $x -ge $GridWidth -or $y -lt 0 -or $y -ge $GridHeight) { return }
    [Console]::SetCursorPosition($x * 2, $y + 4)
    $tile = $Grid[$y][$x]
    switch($tile) {
        "#" { Write-Host "[]" -F Blue -NoNewline }
        "." { Write-Host " ." -F Gray -NoNewline }
        "*" { Write-Host "**" -F White -NoNewline }
        "-" { Write-Host "--" -F White -NoNewline }
        default { Write-Host "  " -NoNewline }
    }
}

function Check-Collision {
    foreach($g in $Ghosts) {
        if ($g.X -eq $Pac.X -and $g.Y -eq $Pac.Y) {
            if ($script:PowerTimer -gt 0) {
                $script:Score += 200; Draw-Tile $g.X $g.Y 
                # Respawn ghost at house entrance
                $g.X=14; $g.Y=11; return $false
            } else {
                $script:Lives--; $script:Pac.X=14; $script:Pac.Y=16
                Start-Sleep -s 1; return $true
            }
        }
    }
    return $false
}

# 4. Initial Render
[Console]::Clear()
for($y=0;$y-lt $GridHeight;$y++){ for($x=0;$x-lt $GridWidth;$x++){ Draw-Tile $x $y } }

# 5. Main Loop
while ($Lives -gt 0) {
    [Console]::SetCursorPosition(0,0)
    $pwr = if($PowerTimer -gt 0){"POWER!!"}else{"        "}
    Write-Host " SCORE: $($Score.ToString().PadRight(8)) | LIVES: $('O ' * $Lives) | $pwr" -B DarkBlue -F Yellow
    Write-Host ("-" * ($GridWidth * 2)) -F Blue

    if ($TotalDots -eq 0) {
        break
    }

    if ([Console]::KeyAvailable) {
        $k = [Console]::ReadKey($true).Key
        switch($k){ "UpArrow"{$Pac.NextDir="Up"}; "DownArrow"{$Pac.NextDir="Down"}; "LeftArrow"{$Pac.NextDir="Left"}; "RightArrow"{$Pac.NextDir="Right"}; "Q"{$Lives=0}; "Escape"{$Lives=0} }
    }

    $oldPX=$Pac.X; $oldPY=$Pac.Y
    $vN = switch($Pac.NextDir){"Up"{@{X=0;Y=-1}};"Down"{@{X=0;Y=1}};"Left"{@{X=-1;Y=0}};"Right"{@{X=1;Y=0}}}
    
    # PACMAN COLLISION: Cannot pass # or -
    $targetX = $Pac.X + $vN.X; $targetY = $Pac.Y + $vN.Y
    if ($targetX -ge 0 -and $targetX -lt $GridWidth -and $Grid[$targetY][$targetX] -notin @("#","-")) { $Pac.Dir=$Pac.NextDir }
    
    $v = switch($Pac.Dir){"Up"{@{X=0;Y=-1}};"Down"{@{X=0;Y=1}};"Left"{@{X=-1;Y=0}};"Right"{@{X=1;Y=0}}}
    $nx=$Pac.X+$v.X; $ny=$Pac.Y+$v.Y
    
    if ($nx -lt 0 -or $nx -ge $GridWidth -or $Grid[$ny][$nx] -notin @("#","-")) {
        $Pac.X=$nx; $Pac.Y=$ny
        if($Pac.X -lt 0){$Pac.X=$GridWidth-1} elseif($Pac.X -ge $GridWidth){$Pac.X=0}
    }
    
    if(Check-Collision){ [Console]::Clear(); for($y=0;$y-lt $GridHeight;$y++){ for($x=0;$x-lt $GridWidth;$x++){ Draw-Tile $x $y } } }

    if ($Pac.X -ge 0 -and $Pac.X -lt $GridWidth) {
        if ($Grid[$Pac.Y][$Pac.X] -eq ".") { $Grid[$Pac.Y][$Pac.X]=" "; $Score+=10; $TotalDots-- }
        elseif ($Grid[$Pac.Y][$Pac.X] -eq "*") { $Grid[$Pac.Y][$Pac.X]=" "; $Score+=50; $PowerTimer=80 }
    }

    # GHOST MOVEMENT
    foreach($g in $Ghosts) {
        $gOldX=$g.X; $gOldY=$g.Y
        if ($PowerTimer -gt 0 -and ($Frame % 2 -ne 0)) { continue }
        
        $dirs = @(@{X=0;Y=-1;D="Up"},@{X=0;Y=1;D="Down"},@{X=-1;Y=0;D="Left"},@{X=1;Y=0;D="Right"})
        # GHOST COLLISION: Can pass through - but not #
        $valid = $dirs | ? { 
            $tx=$g.X+$_.X; $ty=$g.Y+$_.Y; 
            $ty -ge 0 -and $ty -lt $GridHeight -and ($tx -lt 0 -or $tx -ge $GridWidth -or $Grid[$ty][$tx] -ne "#") 
        }
        
        $m = $valid | Get-Random; if($m){$g.Dir=$m.D; $g.X+=$m.X; $g.Y+=$m.Y}
        if($g.X -lt 0){$g.X=$GridWidth-1} elseif($g.X -ge $GridWidth){$g.X=0}
        Draw-Tile $gOldX $gOldY
    }

    if(Check-Collision){ [Console]::Clear(); for($y=0;$y-lt $GridHeight;$y++){ for($x=0;$x-lt $GridWidth;$x++){ Draw-Tile $x $y } } }

    Draw-Tile $oldPX $oldPY
    $mSym = if($Frame%2 -eq 0){"()"}else{ switch($Pac.Dir){"Left"{"< "};"Right"{" >"};"Up"{"v "};"Down"{"^ "}} }
    [Console]::SetCursorPosition($Pac.X*2, $Pac.Y+4); Write-Host $mSym -F Yellow -NoNewline

    foreach($g in $Ghosts) {
        $gCol = if($PowerTimer -gt 0){ if($PowerTimer -lt 20 -and ($Frame % 2 -eq 0)){"White"}else{"Blue"} } else {$g.Color}
        [Console]::SetCursorPosition($g.X*2, $g.Y+4); Write-Host "MM" -F $gCol -NoNewline
    }

    if($PowerTimer -gt 0){ $PowerTimer-- }
    $Frame++; Start-Sleep -m 70
}

# Cleanup: Restore console state
[Console]::CursorVisible = $true
[Console]::Clear()
Write-Host "GAME OVER | Final Score: $Score" -F Yellow