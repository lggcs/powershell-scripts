# PowerShell Centipede Clone
# Controls: Left/Right/Up/Down Arrows to move. Space to fire. Q or ESC to Quit.

$ErrorActionPreference = "SilentlyContinue"

# 1. Console Setup
$W = 80; $H = 25
$host.UI.RawUI.WindowSize = New-Object System.Management.Automation.Host.Size($W, $H)
$host.UI.RawUI.BufferSize = New-Object System.Management.Automation.Host.Size($W, $H)
[Console]::CursorVisible = $false
[Console]::Clear()

# 2. Game Constants
$PlayerX = 40
$PlayerY = 23
# Support multiple bullets for rapid fire - use ArrayList for RemoveAt support
$Bullets = New-Object System.Collections.ArrayList
$MaxBullets = 2  # Maximum bullets on screen
$Score = 0
$Lives = 3
$HighScore = 0
$GameRunning = $true
$GameStarted = $false

# Player area (bottom rows where centipedes roam)
$PlayerAreaStartY = 20

# Spider - enters from sides, zig-zags through player area
$Spider = @{
    X = -1
    Y = 0
    Dir = 0  # 0 = right, 1 = left
    VerticalDir = 1  # -1 = up, 1 = down
    Active = $false
    Timer = 0
    MaxTime = 0
}
$SpiderEntryCooldown = 0
$MinSpiderCooldown = 300  # Frames until spider can appear

# 3. Mushrooms (destructible obstacles)
$Mushrooms = @()
$mushroomCount = 40
for ($i = 0; $i -lt $mushroomCount; $i++) {
    $mx = Get-Random -Minimum 2 -Maximum ($W - 2)
    $my = Get-Random -Minimum 7 -Maximum ($PlayerAreaStartY - 1)
    $Mushrooms += @{
        X = $mx
        Y = $my
        Health = 4
        Alive = $true
    }
}

# 4. Centipede Chains - each chain is an array of segments in order
# Head is always index 0
$script:CentipedeChains = @()
$InitialCentipedeLength = 10
$CurrentCentipedeLength = $InitialCentipedeLength

function Create-Centipede-Chain($length, $startX, $startY, $dir) {
    $chain = @()
    for ($i = 0; $i -lt $length; $i++) {
        $seg = @{
            X = $startX - ($i)
            Y = $startY
            Dir = if ($i -eq 0) { $dir } else { 0 }
            Alive = $true
        }
        $chain += $seg
    }
    return $chain
}

function Spawn-Initial-Centipede {
    # Create a NEW array containing the chain as a single element (comma operator prevents flattening)
    $chain = Create-Centipede-Chain $script:CurrentCentipedeLength 30 6 1
    $script:CentipedeChains = ,$chain
    # Force redraw now
    for ($i = 0; $i -lt $chain.Count; $i++) {
        Draw-Centipede-Seg $chain[$i] ($i -eq 0)
    }
}

# Helper Functions
function Reset-Game {
    $script:PlayerX = 40
    $script:PlayerY = 23

    # Clear entire game area to remove all artifacts (player, bullets, centipedes, spider)
    for ($y = 2; $y -lt $H - 1; $y++) {
        [Console]::SetCursorPosition(1, $y)
        Write-Host (" " * ($W - 2)) -NoNewline
    }

    $script:Bullets.Clear()

    $script:CurrentCentipedeLength = $script:InitialCentipedeLength
    Spawn-Initial-Centipede
    # Reset mushrooms
    foreach ($m in $script:Mushrooms) {
        $m.Health = 4
        $m.Alive = $true
    }
    $script:Spider.Active = $false
    $script:SpiderEntryCooldown = $script:MinSpiderCooldown
}

function Draw-Header {
    [Console]::SetCursorPosition(0, 0)
    $chainCount = if ($CentipedeChains -ne $null) { $CentipedeChains.Count } else { 0 }
    $header = " SCORE: $Score | LIVES: $('O ' * $Lives) | HIGH: $HighScore | CHAINS: $chainCount "
    $header = $header.PadRight($W)
    Write-Host $header -F Yellow -B DarkBlue -NoNewline
}

function Draw-Player($prevX, $prevY) {
    if ($prevX -ge 1 -and $prevX -lt $W - 1 -and $prevY -ge 4 -and $prevY -lt $H - 1) {
        [Console]::SetCursorPosition($prevX, $prevY)
        Write-Host " " -NoNewline
    }
    if ($PlayerX -ge 1 -and $PlayerX -lt $W - 1 -and $PlayerY -ge 4 -and $PlayerY -lt $H - 1) {
        [Console]::SetCursorPosition($PlayerX, $PlayerY)
        Write-Host "^" -F Green -NoNewline
    }
}

function Draw-Bullet($bullets) {
    foreach ($b in $bullets) {
        if ($b.X -ge 1 -and $b.X -lt $W - 1 -and $b.Y -ge 2 -and $b.Y -lt $H) {
            [Console]::SetCursorPosition($b.X, $b.Y)
            Write-Host "|" -F Cyan -NoNewline
        }
    }
}

function Erase-Bullet($x, $y) {
    if ($x -ge 1 -and $x -lt $W - 1 -and $y -ge 2 -and $y -lt $H) {
        [Console]::SetCursorPosition($x, $y)
        Write-Host " " -NoNewline
    }
}

function Draw-Mushrooms($mushrooms) {
    foreach ($m in $mushrooms) {
        if ($m.Alive) {
            [Console]::SetCursorPosition($m.X, $m.Y)
            $char = switch ($m.Health) {
                1 { ":" }
                2 { ";" }
                3 { "&" }
                4 { "%" }
                default { "%" }
            }
            Write-Host $char -F Cyan -NoNewline
        }
    }
}

function Spawn-Spider {
    $side = Get-Random -Minimum 0 -Maximum 2
    $Spider.Y = Get-Random -Minimum $PlayerAreaStartY -Maximum ($H - 4)
    if ($side -eq 0) {
        # Enter from left
        $Spider.X = 1
        $Spider.Dir = 1  # Moving right
    } else {
        # Enter from right
        $Spider.X = $W - 2
        $Spider.Dir = -1  # Moving left
    }
    $Spider.VerticalDir = if ((Get-Random -Minimum 0 -Maximum 2) -eq 0) { -1 } else { 1 }
    $Spider.Active = $true
    $Spider.Timer = 0
    $Spider.MaxTime = Get-Random -Minimum 200 -Maximum 500
}

function Move-Spider {
    if (-not $Spider.Active) { return }

    # Save old position for erasing
    $oldX = $Spider.X
    $oldY = $Spider.Y

    # Move forward (left/right) - always forward, never back
    $Spider.X += $Spider.Dir

    # Check if spider left the screen or time expired
    if ($Spider.X -lt 0 -or $Spider.X -ge $W - 1) {
        $Spider.Active = $false
        $SpiderEntryCooldown = $MinSpiderCooldown + (Get-Random -Minimum 100 -Maximum 300)
        [Console]::SetCursorPosition($oldX, $oldY)
        Write-Host " " -NoNewline
        return
    }

    $Spider.Timer++
    if ($Spider.Timer -ge $Spider.MaxTime) {
        # Time up - spider leaves
        $Spider.Active = $false
        $SpiderEntryCooldown = $MinSpiderCooldown + (Get-Random -Minimum 100 -Maximum 300)
        [Console]::SetCursorPosition($oldX, $oldY)
        Write-Host " " -NoNewline
        return
    }

    # Check player collision (spider kills player)
    if ($Spider.X -eq $PlayerX -and $Spider.Y -eq $PlayerY) {
        $script:Lives--
        if ($Lives -gt 0) {
            Reset-Game
        }
        return
    }

    # Zig-zag vertical movement (30% chance each frame)
    if ((Get-Random -Minimum 0 -Maximum 10) -lt 3) {
        $Spider.Y += $Spider.VerticalDir

        # Change vertical direction at boundaries
        if ($Spider.Y -le $PlayerAreaStartY) {
            $Spider.Y = $PlayerAreaStartY
            $Spider.VerticalDir = 1  # Go down
        }
        elseif ($Spider.Y -ge $H - 3) {
            $Spider.Y = $H - 3
            $Spider.VerticalDir = -1  # Go up
        }
    }

    # Erase old position (will be redrawn in render phase)
    if ($oldX -ge 1 -and $oldX -lt $W - 1 -and $oldY -ge $PlayerAreaStartY -and $oldY -lt $H - 1) {
        [Console]::SetCursorPosition($oldX, $oldY)
        Write-Host " " -NoNewline
    }

    # Occasionally eat a mushroom
    if ((Get-Random -Minimum 0 -Maximum 100) -lt 5) {
        for ($i = $Mushrooms.Count - 1; $i -ge 0; $i--) {
            if ($Mushrooms[$i].Alive -and $Mushrooms[$i].X -eq $Spider.X -and $Mushrooms[$i].Y -eq $Spider.Y) {
                $Mushrooms[$i].Alive = $false
                break
            }
        }
    }
}

function Draw-Spider {
    if ($Spider.Active) {
        [Console]::SetCursorPosition($Spider.X, $Spider.Y)
        Write-Host "@" -F Magenta -NoNewline
    }
}

function Check-Spider-Hit($bulletX, $bulletY) {
    if (-not $Spider.Active) { return @($false, 0) }

    if ($bulletX -eq $Spider.X -and $bulletY -eq $Spider.Y) {
        # Calculate points based on distance from player
        $distance = [Math]::Abs($PlayerY - $Spider.Y)
        $points = switch ($distance) {
            { $_ -le 2 } { 900 }
            { $_ -le 5 } { 600 }
            default { 300 }
        }

        # Kill spider
        $Spider.Active = $false
        [Console]::SetCursorPosition($Spider.X, $Spider.Y)
        Write-Host " " -NoNewline
        return @($true, $points)
    }

    return @($false, 0)
}

function Draw-Centipede-Seg($seg, $isHead) {
    # Clamp to screen boundaries
    $drawX = [Math]::Max(1, [Math]::Min($W - 2, $seg.X))
    $drawY = [Math]::Max(2, [Math]::Min($H - 2, $seg.Y))
    
    [Console]::SetCursorPosition($drawX, $drawY)
    if ($isHead) {
        Write-Host "W" -F Red -NoNewline
    } else {
        Write-Host "#" -F Yellow -NoNewline
    }
}

function Draw-StartScreen {
    [Console]::SetCursorPosition(28, 12)
    Write-Host "CENTIPEDE" -F Cyan -B Black -NoNewline
    [Console]::SetCursorPosition(24, 14)
    Write-Host "PRESS ANY KEY TO START" -F White -B Black -NoNewline
    [Console]::SetCursorPosition(28, 16)
    Write-Host "Q/ESC to Quit" -F Gray -B Black -NoNewline
}

# 6. Initial Render
Draw-Header
Draw-Mushrooms $Mushrooms
Spawn-Initial-Centipede
foreach ($chain in $CentipedeChains) {
    if ($chain.Count -gt 0) {
        for ($i = 0; $i -lt $chain.Count; $i++) {
            if ($chain[$i].Alive) {
                Draw-Centipede-Seg $chain[$i] ($i -eq 0)
            }
        }
    }
}
$PrevPlayerX = $PlayerX
$PrevPlayerY = $PlayerY
Draw-Player $PrevPlayerX $PrevPlayerY
Draw-Bullet $Bullets
Draw-StartScreen

# 7. Wait for Start
while (-not $GameStarted) {
    if ([Console]::KeyAvailable) {
        $k = [Console]::ReadKey($true).Key
        if ($k -eq "Q" -or $k -eq "Escape") {
            [Console]::CursorVisible = $true
            [Console]::Clear()
            exit
        }
        $GameStarted = $true
        [Console]::SetCursorPosition(28, 12)
        Write-Host (" " * 10) -NoNewline
        [Console]::SetCursorPosition(24, 14)
        Write-Host (" " * 24) -NoNewline
        [Console]::SetCursorPosition(28, 16)
        Write-Host (" " * 14) -NoNewline
    }
    Start-Sleep -m 50
}

# 8. Main Game Loop
$FrameCount = 0
$WaveTimer = 0  # Timer for spawning new heads from sides

while ($GameRunning -and $Lives -gt 0) {
    # Input - Process all available keys for responsiveness
    $keysProcessed = 0
    $maxKeysPerFrame = 5
    while ([Console]::KeyAvailable -and $keysProcessed -lt $maxKeysPerFrame) {
        $k = [Console]::ReadKey($true).Key
        switch ($k) {
            "LeftArrow"  { if ($PlayerX -gt 1) { $PlayerX-- } }
            "RightArrow" { if ($PlayerX -lt $W - 2) { $PlayerX++ } }
            "UpArrow"    { if ($PlayerY -gt $PlayerAreaStartY) { $PlayerY-- } }
            "DownArrow"  { if ($PlayerY -lt $H - 2) { $PlayerY++ } }
            "Spacebar"   {
                if ($Bullets.Count -lt $MaxBullets) {
                    $null = $Bullets.Add(@{
                        X = $PlayerX
                        Y = $PlayerY - 1
                    })
                }
            }
            "Q"          { $GameRunning = $false }
            "Escape"     { $GameRunning = $false }
        }
        $keysProcessed++
    }

    # Bullet physics - handle multiple bullets for rapid fire
    # Iterate backwards so we can safely remove bullets
    for ($bul = $Bullets.Count - 1; $bul -ge 0; $bul--) {
        $bullet = $Bullets[$bul]

        # Erase current bullet position
        Erase-Bullet $bullet.X $bullet.Y

        # Move bullet up
        $bullet.Y = $bullet.Y - 1

        # Check if bullet went off screen
        if ($bullet.Y -lt 2) {
            $Bullets.RemoveAt($bul)
            continue
        }

        # Check mushroom hit
        $hitMushroom = $false
        foreach ($m in $Mushrooms) {
            if ($m.Alive -and $bullet.X -eq $m.X -and $bullet.Y -eq $m.Y) {
                $m.Health--
                if ($m.Health -le 0) { $m.Alive = $false }
                $Score += 10
                if ($Score -gt $HighScore) { $HighScore = $Score }
                $hitMushroom = $true
                break
            }
        }

        if ($hitMushroom) {
            $Bullets.RemoveAt($bul)
            continue
        }

        # Check spider hit
        ($hitSpider, $spiderPoints) = Check-Spider-Hit $bullet.X $bullet.Y
        if ($hitSpider) {
            $Score += $spiderPoints
            if ($Score -gt $HighScore) { $HighScore = $Score }
            $Bullets.RemoveAt($bul)
            continue
        }

        # Check centipede hit
        $hitChain = -1
        $hitIndex = -1
        $hitDetails = ""
        for ($c = 0; $c -lt $CentipedeChains.Count; $c++) {
            $chain = $CentipedeChains[$c]
            for ($i = 0; $i -lt $chain.Count; $i++) {
                $seg = $chain[$i]
                if ($seg.Alive -and $bullet.X -eq $seg.X -and $bullet.Y -eq $seg.Y) {
                    $hitChain = $c
                    $hitIndex = $i
                    break
                }
            }
            if ($hitChain -ge 0) { break }
        }

        if ($hitChain -ge 0 -and $hitIndex -ge 0) {
            $chain = $CentipedeChains[$hitChain]
            $seg = $chain[$hitIndex]
            $deathX = $seg.X
            $deathY = $seg.Y

            # Kill the segment - update the chain directly then verify
            $chain[$hitIndex].Alive = $false
            $seg = $chain[$hitIndex]  # Refresh seg to get updated value

            $Score += 100
            if ($Score -gt $HighScore) { $HighScore = $Score }

            # Erase the killed segment immediately from all positions it might be drawn
            [Console]::SetCursorPosition($deathX, $deathY)
            Write-Host " " -NoNewline
            [Console]::SetCursorPosition($seg.X, $seg.Y)
            Write-Host " " -NoNewline

            # Spawn mushroom at death location
            $Mushrooms += @{
                X = $deathX
                Y = $deathY
                Health = 4
                Alive = $true
            }

            # Handle the hit

            # Check if this is the HEAD (first alive segment - might not be index 0!)
            $isHead = $true
            for ($i = 0; $i -lt $hitIndex; $i++) {
                if ($chain[$i].Alive) {
                    $isHead = $false
                    break
                }
            }

            # Check if this is the TAIL (last alive segment)
            $isTail = $true
            for ($i = $hitIndex + 1; $i -lt $chain.Count; $i++) {
                if ($chain[$i].Alive) {
                    $isTail = $false
                    break
                }
            }

            if ($isHead) {
                # Head was hit - next alive segment becomes new head (no split)
                $foundNext = $false
                for ($i = $hitIndex + 1; $i -lt $chain.Count; $i++) {
                    if ($chain[$i].Alive) {
                        $chain[$i].Dir = $seg.Dir
                        $foundNext = $true
                        break
                    }
                }
            }
            elseif ($isTail) {
                # Tail was hit - no split, just remove
            }
            else {
                # Middle segment was hit - SPLIT into two chains
                $newChain = @()
                for ($i = $hitIndex + 1; $i -lt $chain.Count; $i++) {
                    $newSeg = @{
                        X = $chain[$i].X
                        Y = $chain[$i].Y
                        Dir = if ($i -eq $hitIndex + 1) { if ($seg.Dir -eq 0) { 1 } else { $seg.Dir } } else { 0 }
                        Alive = $true
                    }
                    $newChain += $newSeg
                    $chain[$i].Alive = $false
                    [Console]::SetCursorPosition($chain[$i].X, $chain[$i].Y)
                    Write-Host " " -NoNewline
                }
                if ($newChain.Count -gt 0) {
                    $script:CentipedeChains = $script:CentipedeChains + ,$newChain
                }
            }

            # Remove dead chains - rebuild array with only alive chains
            $newChains = @()
            foreach ($c in $CentipedeChains) {
                $hasAlive = $false
                foreach ($s in $c) {
                    if ($s.Alive) { $hasAlive = $true; break }
                }
                if ($hasAlive) {
                    $newChains = $newChains + ,$c
                }
            }
            $script:CentipedeChains = $newChains

            # Check if all dead - spawn new wave
            $totalSegments = 0
            foreach ($c in $CentipedeChains) {
                foreach ($s in $c) {
                    if ($s.Alive) { $totalSegments++ }
                }
            }
            if ($totalSegments -eq 0) {
                $script:CurrentCentipedeLength = [Math]::Min(20, $script:CurrentCentipedeLength + 1)
                Spawn-Initial-Centipede
                [Console]::SetCursorPosition(35, 12)
                Write-Host "WAVE COMPLETE!" -F Green -B Black -NoNewline
                Start-Sleep -m 1000
                [Console]::SetCursorPosition(35, 12)
                Write-Host (" " * 15) -NoNewline
            }

            $Bullets.RemoveAt($bul)
        }
    }

    # Draw bullets at their new positions (only those that didn't hit anything)
    Draw-Bullet $Bullets

    # Centipede movement (every 4 frames)
    $FrameCount++
    if ($FrameCount % 4 -eq 0) {
        # DEBUG DISABLED - was overwriting other debug output
        # [Console]::SetCursorPosition(0, 1)
        # $chainInfo = ""
        # for ($ci = 0; $ci -lt [Math]::Min(2, $CentipedeChains.Count); $ci++) {
        #     $c = $CentipedeChains[$ci]
        #     $aliveInC = 0
        #     foreach ($s in $c) { if ($s.Alive) { $aliveInC++ } }
        #     $chainInfo = $chainInfo + "C$ci" + ":" + "$aliveInC "
        # }
        # Write-Host "Frame: $FrameCount, Chains: $($CentipedeChains.Count), $chainInfo" -NoNewline

        # Spawn new heads from sides if in player area (DISABLED FOR DEBUGGING)
        # NOTE: When re-enabling, use comma operator: $script:CentipedeChains += ,$newChain
        # $WaveTimer++
        # if ($WaveTimer -ge 300) {
        #     $WaveTimer = 0
        #     $newChain = Create-Centipede-Chain 1 (if ((Get-Random -Minimum 0 -Maximum 2) -eq 0) { 1 } else { $W - 2 }) $PlayerAreaStartY (if ((Get-Random -Minimum 0 -Maximum 2) -eq 0) { 1 } else { -1 })
        #     $script:CentipedeChains += ,$newChain
        # }

        $chainNum = 0
        foreach ($chain in $CentipedeChains) {
            # Find head (first alive segment)
            $headIndex = -1
            for ($i = 0; $i -lt $chain.Count; $i++) {
                if ($chain[$i].Alive) {
                    $headIndex = $i
                    break
                }
            }
            if ($headIndex -lt 0) { continue }
            if ($headIndex -ge $chain.Count) { continue }

            $chainNum++

            # Move head
            $head = $chain[$headIndex]
            $nextX = $head.X + $head.Dir
            $nextY = $head.Y

            # Check for obstacles (walls, mushrooms)
            $hitObstacle = $false
            if ($head.Dir -eq 1 -and $nextX -ge $W - 2) { $hitObstacle = $true }
            elseif ($head.Dir -eq -1 -and $nextX -le 0) { $hitObstacle = $true }

            if (-not $hitObstacle) {
                foreach ($m in $Mushrooms) {
                    if ($m.Alive -and $nextX -eq $m.X -and $nextY -eq $m.Y) {
                        $hitObstacle = $true
                        break
                    }
                }
            }

            # Erase old positions BEFORE moving (for head and all body segments)
            # Do this before any position changes to avoid artifacts
            for ($i = 0; $i -lt $chain.Count; $i++) {
                if ($chain[$i].Alive) {
                    [Console]::SetCursorPosition($chain[$i].X, $chain[$i].Y)
                    Write-Host " " -NoNewline
                }
            }

            # Save old positions BEFORE moving so body segments can follow correctly
            $oldPositions = @()
            for ($i = 0; $i -lt $chain.Count; $i++) {
                $oldPositions += @{ X = $chain[$i].X; Y = $chain[$i].Y }
            }

            if ($hitObstacle) {
                $nextY++
                $head.Dir = -$head.Dir
                if ($nextY -ge $H - 1) { $nextY = $H - 2 }
            }
            $head.X = $nextX
            $head.Y = $nextY

            # Move body segments - each follows the segment ahead's OLD position
            # In original game, body segments just follow blindly - only head checks for obstacles
            for ($i = $chain.Count - 1; $i -gt $headIndex; $i--) {
                if (-not $chain[$i].Alive) { continue }
                $seg = $chain[$i]

                # Move to where the previous segment WAS (old position)
                $seg.X = $oldPositions[$i - 1].X
                $seg.Y = $oldPositions[$i - 1].Y
            }

            # Draw chain AFTER all positions have been updated
            for ($i = 0; $i -lt $chain.Count; $i++) {
                if ($chain[$i].Alive) {
                    Draw-Centipede-Seg $chain[$i] ($i -eq $headIndex)
                }
            }

            # Check player collision
            foreach ($seg in $chain) {
                if ($seg.Alive -and $seg.X -eq $PlayerX -and $seg.Y -eq $PlayerY) {
                    $script:Lives--
                    if ($Lives -gt 0) {
                        Reset-Game
                    }
                    break
                }
            }
        }
    }

    # Mushroom regeneration
    if ($FrameCount % 600 -eq 0) {
        foreach ($m in $Mushrooms) {
            if ($m.Alive -and $m.Health -lt 4) {
                $m.Health++
            }
        }
    }

    # Spider management - spawn, move, and handle cooldown
    if ($Spider.Active) {
        Move-Spider
    } else {
        if ($SpiderEntryCooldown -gt 0) {
            $SpiderEntryCooldown--
        } elseif ((Get-Random -Minimum 0 -Maximum 500) -lt 5) {
            # Small chance to spawn spider when cooldown is over
            Spawn-Spider
        }
    }

    # Rendering - Order matters! Draw bottom layer first
    # 1. Draw mushrooms (bottom layer - centipedes will appear on top)
    Draw-Mushrooms $Mushrooms

    # 2. Draw player (centipedes are already drawn in movement phase, bullets handled above)
    Draw-Player $PrevPlayerX $PrevPlayerY

    # 3. Draw spider (on top of mushrooms and player)
    Draw-Spider

    # Update previous player position for next frame
    $PrevPlayerX = $PlayerX
    $PrevPlayerY = $PlayerY

    Draw-Header

    Start-Sleep -m 40
}

# 9. Cleanup
[Console]::CursorVisible = $true
[Console]::Clear()

if ($Lives -le 0) {
    Write-Host "GAME OVER | Final Score: $Score" -F Red
} else {
    Write-Host "QUIT | Final Score: $Score" -F Yellow
}