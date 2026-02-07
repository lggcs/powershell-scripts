# PowerShell Space Invaders Clone
# Controls: Left/Right Arrows to move, Space to fire, ESC to quit

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
$BulletX = -1
$BulletY = -1
$Score = 0
$Lives = 3
$HighScore = 0
$AlienDir = 1  # 1 = right, -1 = left
$AlienMoveCounter = 0
$AlienSpeed = 24  # Higher is slower
$FireCooldown = 0
$AnimationFrame = 0  # For alien animation
$EdgeHits = 0  # Count edge hits for vertical descent delay
$CurrentDirectionWasLeft = $true  # Track if we were moving left before current direction
$GameOver = $false
$Win = $false

# UFO bonus ship
$UFO = $null
$UFOTimer = 0
$UFOInterval = 300  #.frames

# 3. Alien Grid (5 rows x 11 columns) - Full width coverage
# 0 = empty, 1 = type 1 (worth 10), 2 = type 2 (worth 20), 3 = type 3 (worth 30)
$AlienGrid = @(
    @(1,1,1,1,1,1,1,1,1,1,1),
    @(1,1,1,1,1,1,1,1,1,1,1),
    @(2,2,2,2,2,2,2,2,2,2,2),
    @(2,2,2,2,2,2,2,2,2,2,2),
    @(3,3,3,3,3,3,3,3,3,3,3)
)

$AlienStartY = 3
$AlienStartX = 3
$Aliens = @()  # Will hold positions of living aliens
$AlienBullets = @()

# Initialize aliens with prev positions for smooth rendering
for ($row = 0; $row -lt 5; $row++) {
    for ($col = 0; $col -lt 11; $col++) {
        if ($AlienGrid[$row][$col] -ne 0) {
            $x = $AlienStartX + $col * 7
            $y = $AlienStartY + $row * 2
            $Aliens += @{
                X = $x; PrevX = $x
                Y = $y; PrevY = $y
                Type = $AlienGrid[$row][$col]
                Alive = $true
            }
        }
    }
}

# 4. Destructible Bunkers (4 bunkers)
# Each bunker is 8 wide x 3 tall, represented as a grid of hit points
$Bunkers = @(
    # Bunker 1
    @{
        X = 10; Y = 19
        Cells = @(
            @(3,3,3,3,3,3,3,3),
            @(3,2,2,2,2,2,2,3),
            @(3,2,1,1,1,1,2,3)
        )
    },
    # Bunker 2
    @{
        X = 28; Y = 19
        Cells = @(
            @(3,3,3,3,3,3,3,3),
            @(3,2,2,2,2,2,2,3),
            @(3,2,1,1,1,1,2,3)
        )
    },
    # Bunker 3
    @{
        X = 46; Y = 19
        Cells = @(
            @(3,3,3,3,3,3,3,3),
            @(3,2,2,2,2,2,2,3),
            @(3,2,1,1,1,1,2,3)
        )
    },
    # Bunker 4
    @{
        X = 64; Y = 19
        Cells = @(
            @(3,3,3,3,3,3,3,3),
            @(3,2,2,2,2,2,2,3),
            @(3,2,1,1,1,1,2,3)
        )
    }
)

# 5. Helper Functions
$Global:EdgeDebug = ""  # Global debug variable

function Draw-Header {
    [Console]::SetCursorPosition(0, 0)
    $Header = " SCORE: $Score | LIVES: $('O ' * $Lives) | HIGH SCORE: $HighScore |$Global:EdgeDebug"
    $Header = $Header.PadLeft(40 + [int]($Header.Length / 2)).PadRight($W)
    Write-Host $Header -ForegroundColor Green -BackgroundColor DarkRed -NoNewline
    [Console]::SetCursorPosition(0, 1)
    Write-Host ("-" * $W) -ForegroundColor DarkRed -NoNewline
}

function Draw-Alien($alien) {
    if (-not $alien.Alive) { return }

    # Erase previous position if it changed
    $posChanged = ($alien.PrevX -ne $alien.X -or $alien.PrevY -ne $alien.Y)
    if ($posChanged -and $alien.PrevX -ge 0 -and $alien.PrevY -ge 2 -and $alien.PrevX -lt $W) {
        [Console]::SetCursorPosition($alien.PrevX, $alien.PrevY)
        Write-Host "   " -NoNewline
    }

    # Update prev position
    $alien.PrevX = $alien.X
    $alien.PrevY = $alien.Y

    # Draw new position with animation (only if visible)
    if ($alien.X -ge 0 -and $alien.X -lt $W -and $alien.Y -ge 2) {
        [Console]::SetCursorPosition($alien.X, $alien.Y)
        switch ($alien.Type) {
            1 {
                if ($script:AnimationFrame -eq 0) {
                    Write-Host "<o>" -ForegroundColor Cyan -NoNewline
                } else {
                    Write-Host "<w>" -ForegroundColor Cyan -NoNewline
                }
            }
            2 {
                if ($script:AnimationFrame -eq 0) {
                    Write-Host "/v\" -ForegroundColor Magenta -NoNewline
                } else {
                    Write-Host "|/|" -ForegroundColor Magenta -NoNewline
                }
            }
            3 {
                if ($script:AnimationFrame -eq 0) {
                    Write-Host "><>" -ForegroundColor Yellow -NoNewline
                } else {
                    Write-Host "/#\" -ForegroundColor Yellow -NoNewline
                }
            }
        }
    }
}

function Draw-AlienKilled($alien) {
    [Console]::SetCursorPosition($alien.PrevX, $alien.PrevY)
    Write-Host "   " -NoNewline
}

function Draw-Bunkers($bunkers) {
    foreach ($bunker in $bunkers) {
        for ($row = 0; $row -lt $bunker.Cells.Length; $row++) {
            for ($col = 0; $col -lt $bunker.Cells[$row].Length; $col++) {
                $x = $bunker.X + $col
                $y = $bunker.Y + $row
                $hp = $bunker.Cells[$row][$col]
                [Console]::SetCursorPosition($x, $y)
                if ($hp -eq 0) {
                    Write-Host " " -NoNewline
                } else {
                    $shade = switch ($hp) {
                        1 { "-" }
                        2 { "=" }
                        3 { "#" }
                        default { "#" }
                    }
                    Write-Host $shade -ForegroundColor Green -NoNewline
                }
            }
        }
    }
}

function Check-BunkerCollision($bunkers, $bx, $by, $isPlayerBullet) {
    foreach ($bunker in $bunkers) {
        $relX = $bx - $bunker.X
        $relY = $by - $bunker.Y
        if ($relY -ge 0 -and $relY -lt $bunker.Cells.Length -and $relX -ge 0 -and $relX -lt $bunker.Cells[$relY].Length) {
            if ($bunker.Cells[$relY][$relX] -gt 0) {
                $bunker.Cells[$relY][$relX]--
                if ($isPlayerBullet) {
                    # Player bullet destroys more
                    if ($relY -ge 0 -and $relY+1 -lt $bunker.Cells.Length -and $bunker.Cells[$relY+1][$relX] -gt 0) {
                        $bunker.Cells[$relY+1][$relX]--
                    }
                    if ($relX -gt 0 -and $bunker.Cells[$relY][$relX-1] -gt 0) {
                        $bunker.Cells[$relY][$relX-1]--
                    }
                    if ($relX+1 -lt $bunker.Cells[$relY].Length -and $bunker.Cells[$relY][$relX+1] -gt 0) {
                        $bunker.Cells[$relY][$relX+1]--
                    }
                }
                return $true
            }
        }
    }
    return $false
}

function Draw-Player($prevX) {
    # Erase old player position
    [Console]::SetCursorPosition($prevX, $PlayerY)
    Write-Host "     " -NoNewline
    # Draw new player position
    [Console]::SetCursorPosition($PlayerX, $PlayerY)
    Write-Host "/^\" -ForegroundColor Green -NoNewline
}

function Draw-Bullet($prevX, $prevY, $currentX, $currentY) {
    # Erase old bullet
    if ($prevX -ge 0 -and $prevY -ge 0) {
        [Console]::SetCursorPosition($prevX, $prevY)
        Write-Host " " -NoNewline
    }
    # Draw new bullet
    if ($currentX -ge 0 -and $currentY -ge 0) {
        [Console]::SetCursorPosition($currentX, $currentY)
        Write-Host "|" -ForegroundColor Red -NoNewline
    }
}

function Draw-UFO($ufo) {
    if ($ufo -eq $null) { return }

    # Always erase previous position
    [Console]::SetCursorPosition($ufo.PrevX, $ufo.Y)
    Write-Host "     " -NoNewline

    # Draw new position if on screen
    if ($ufo.X -ge 0 -and $ufo.X -lt $W - 4) {
        [Console]::SetCursorPosition($ufo.X, $ufo.Y)
        Write-Host "--(>--" -ForegroundColor Red -NoNewline
    }

    $ufo.PrevX = $ufo.X
}

function Draw-AlienBullet($bullets, $prevBullets) {
    # Get positions of new bullets to avoid erasing them
    $newPositions = @{}
    foreach ($b in $bullets) {
        $newPositions["$($b.X),$($b.Y)"] = $true
    }

    # Clear old bullets (but not where new bullets are)
    foreach ($b in $prevBullets) {
        $posKey = "$($b.X),$($b.Y)"
        if (-not $newPositions.ContainsKey($posKey) -and $b.X -ge 0 -and $b.Y -ge 2) {
            [Console]::SetCursorPosition($b.X, $b.Y)
            Write-Host " " -NoNewline
        }
    }

    # Draw new bullets
    foreach ($b in $bullets) {
        if ($b.X -ge 0 -and $b.Y -ge 2 -and $b.X -lt $W -and $b.Y -lt $H) {
            [Console]::SetCursorPosition($b.X, $b.Y)
            Write-Host "!" -ForegroundColor Yellow -NoNewline
        }
    }
}

function Draw-GameArea {
    # Draw floor
    [Console]::SetCursorPosition(0, $H - 1)
    Write-Host ("=" * $W) -ForegroundColor Blue -NoNewline
}

function Draw-GameOver($isWin) {
    [Console]::SetCursorPosition(30, 12)
    if ($isWin) {
        Write-Host " YOU WIN! " -ForegroundColor Green -BackgroundColor Blue -NoNewline
    } else {
        Write-Host " GAME OVER " -ForegroundColor Red -BackgroundColor Blue -NoNewline
    }
    [Console]::SetCursorPosition(28, 14)
    Write-Host " Score: $Score | Press ESC " -ForegroundColor White -NoNewline
}

# 6. Initial Render
Draw-Header
Draw-GameArea
Draw-Bunkers $Bunkers
$PrevPlayerX = $PlayerX
$PrevBulletX = -1; $PrevBulletY = -1
$PrevAlienBullets = @()

foreach ($alien in $Aliens) {
    Draw-Alien $alien
}

Draw-Player $PrevPlayerX

# 6. Main Game Loop
while (-not $GameOver -and -not $Win) {
    # --- INPUT ---
    if ([Console]::KeyAvailable) {
        $key = [Console]::ReadKey($true).Key
        switch ($key) {
            "LeftArrow" { if ($PlayerX -gt 1) { $PlayerX -= 2 } }
            "RightArrow" { if ($PlayerX -lt $W - 5) { $PlayerX += 2 } }
            "Spacebar" {
                if ($BulletX -lt 0 -and $FireCooldown -eq 0) {
                    $BulletX = $PlayerX + 1
                    $BulletY = $PlayerY - 1
                    $FireCooldown = 10
                }
            }
            "Q" { $GameOver = $true }
            "Escape" { $GameOver = $true }
        }
    }

    # Decrease cooldown
    if ($FireCooldown -gt 0) { $FireCooldown-- }

    # --- BULLET PHYSICS ---
    $OldBX = $BulletX; $OldBY = $BulletY
    if ($BulletX -ge 0) {
        $BulletY--
        # Check collision with bunkers first
        if (Check-BunkerCollision $Bunkers $BulletX $BulletY $true) {
            Draw-Bunkers $Bunkers
            $BulletX = -1; $BulletY = -1
        }
        else {
            # Check collision with aliens
            $hitAlien = $null
            foreach ($alien in $Aliens) {
                if ($alien.Alive -and
                    $BulletX -ge $alien.X -and $BulletX -le $alien.X + 2 -and
                    $BulletY -eq $alien.Y) {
                    $alien.Alive = $false
                    Draw-AlienKilled $alien
                    $Score += $alien.Type * 10
                    if ($Score -gt $HighScore) { $HighScore = $Score }
                    $BulletX = -1; $BulletY = -1
                    break
                }
            }
        }
        # Bullet went off screen
        if ($BulletY -lt 2) {
            $BulletX = -1; $BulletY = -1
        }
    }
    Draw-Bullet $OldBX $OldBY $BulletX $BulletY

    # --- ALIEN MOVEMENT ---
    $AlienMoveCounter++
    if ($AlienMoveCounter -ge $AlienSpeed) {
        $AlienMoveCounter = 0

        # Toggle animation frame
        $AnimationFrame = if ($AnimationFrame -eq 0) { 1 } else { 0 }

        # Update prev positions and prepare to move
        foreach ($alien in $Aliens) {
            if ($alien.Alive) {
                $alien.PrevX = $alien.X
                $alien.PrevY = $alien.Y
            }
        }

        # Find boundaries - simplified approach
        $livingAliens = $Aliens | Where-Object { $_.Alive -eq $true }
        $minX = 99
        $maxX = -1
        foreach ($alien in $livingAliens) {
            if ($alien.X -lt $minX) { $minX = $alien.X }
            if ($alien.X -gt $maxX) { $maxX = $alien.X }
        }

        # Debug: Show edge detection in header
        $Global:EdgeDebug = " Count:$($livingAliens.Count) minX:$minX maxX:$maxX Dir:$($script:AlienDir) Hits:$($script:EdgeHits) "

        # Check if hit edge
        $hitEdge = $false

        # Hit right edge
        if ($maxX -ge 72) {
            $script:AlienDir = -1
            $script:EdgeHits++
        }
        # Hit left edge
        elseif ($minX -le 1) {
            $script:AlienDir = 1
            $script:EdgeHits++
        }

        # Descend after hitting both edges twice (4 hits total = 2 full cycles)
        if ($script:EdgeHits -ge 4) {
            $hitEdge = $true
            $script:EdgeHits = 0
        }

        # Clamp positions after direction change
        foreach ($alien in $Aliens) {
            if ($alien.Alive) {
                if ($alien.X -ge 72) { $alien.X = 71 }
                if ($alien.X -le 0) { $alien.X = 1 }
            }
        }

        # Move aliens
        foreach ($alien in $Aliens) {
            if ($alien.Alive) {
                if ($hitEdge) {
                    $alien.Y++
                    # Check if aliens reached player
                    if ($alien.Y -ge $PlayerY - 1) {
                        $GameOver = $true
                    }
                } else {
                    $alien.X += $script:AlienDir
                }
                Draw-Alien $alien
            }
        }

        # Speed up as aliens are destroyed (starts at 24, gets faster as fewer remain)
        $remainingAliens = ($Aliens | Where-Object { $_.Alive }).Count
        if ($remainingAliens -gt 0) {
            $AlienSpeed = [Math]::Max(6, 24 - [Math]::Floor((55 - $remainingAliens) / 8))
        }
    }

    # --- ALIEN BULLETS ---
    # Save old positions BEFORE modifying
    $PrevAlienBullets = @()
    foreach ($b in $AlienBullets) {
        $PrevAlienBullets += @{ X = $b.X; Y = $b.Y }
    }

    $NewAlienBullets = @()

    # Random alien fire
    $livingAliens = $Aliens | Where-Object { $_.Alive }
    if ($livingAliens.Count -gt 0 -and (Get-Random -Maximum 100) -lt 5) {
        $shooter = $livingAliens | Get-Random
        $NewAlienBullets += @{ X = $shooter.X + 1; Y = $shooter.Y + 1 }
    }

    # Move alien bullets and check collisions
    foreach ($b in $AlienBullets) {
        $newY = $b.Y + 1

        # Check if bullet hit bunkers
        if (Check-BunkerCollision $Bunkers $b.X $newY $false) {
            Draw-Bunkers $Bunkers
            continue  # Bullet destroyed, don't add to new list
        }

        # Check if bullet went off screen
        if ($newY -ge $H - 1) {
            continue
        }

        # Check collision with player
        if ($b.X -ge $PlayerX -and $b.X -le $PlayerX + 2 -and $newY -eq $PlayerY) {
            $Lives--
            if ($Lives -le 0) {
                $GameOver = $true
            }
            continue
        }

        # Add bullet with new position
        $NewAlienBullets += @{ X = $b.X; Y = $newY }
    }

    $AlienBullets = $NewAlienBullets

    # Draw alien bullets (erases old ones internally)
    Draw-AlienBullet $AlienBullets $PrevAlienBullets

    # --- UFO LOGIC ---
    $UFOTimer++
    if ($UFO -eq $null -and $UFOTimer -ge $UFOInterval) {
        $UFOTimer = 0
        $UFOInterval = 200 + (Get-Random -Maximum 200)
        $UFO = @{
            X = if ((Get-Random -Maximum 2) -eq 0) { -6 } else { $W }
            Y = 2
            Dir = if ($UFO.X -lt 0) { 1 } else { -1 }
            PrevX = $UFO.X
        }
    }

    if ($UFO -ne $null) {
        $UFO.X += $UFO.Dir
        if ($UFO.X -lt -6 -or $UFO.X -gt $W) {
            $UFO = $null
        } else {
            Draw-UFO $UFO
            # Check if player bullet hits UFO
            if ($BulletX -ge 0 -and $BulletY -ge 0) {
                if ($BulletX -ge $UFO.X -and $BulletX -le $UFO.X + 5 -and $BulletY -eq $UFO.Y) {
                    $ufoScore = (50, 100, 150, 200, 300) | Get-Random
                    $Score += $ufoScore
                    if ($Score -gt $HighScore) { $HighScore = $Score }
                    $UFO = $null
                    $BulletX = -1; $BulletY = -1
                }
            }
        }
    }

    # --- PLAYER UPDATE ---
    Draw-Player $PrevPlayerX
    $PrevPlayerX = $PlayerX

    # --- UPDATE HEADER ---
    $Global:EdgeDebug = ""
    Draw-Header

    # --- CHECK WIN CONDITION ---
    $aliensAlive = ($Aliens | Where-Object { $_.Alive }).Count
    if ($aliensAlive -eq 0) {
        $Win = $true
    }

    Start-Sleep -Milliseconds 20
}

# 7. Clear console and show final score
[Console]::CursorVisible = $true
[Console]::Clear()
$winMsg = if ($Win) { "VICTORY" } else { "GAME OVER" }
Write-Host "$winMsg | Final Score: $Score" -ForegroundColor Yellow