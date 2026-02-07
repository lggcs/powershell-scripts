# PowerShell Pong - Final "Perfected" Version
# Run in regular PowerShell Console.
# Controls: Up/Down Arrows. P to Pause. Q or ESC to Quit.

# 1. Console Setup
$Host.UI.RawUI.WindowSize = New-Object System.Management.Automation.Host.Size(80, 26)
$Host.UI.RawUI.BufferSize = New-Object System.Management.Automation.Host.Size(80, 26)
[Console]::CursorVisible = $false
[Console]::Clear()

# 2. Constants & Configuration
$Width = 80
$Height = 25
$PaddleHeight = 5
$WinScore = 10
$GameAreaTop = 2    # Header takes rows 0 and 1
$GameAreaBottom = $Height - 1

# 3. Game State
$PlayerY = 10
$AIY = 10
$BallX = 40.0
$BallY = 12.0
$BallDX = 1.2
$BallDY = 0.6
$PlayerScore = 0
$AIScore = 0
$HighScore = 0
$Level = 1
$Paused = $false
$Running = $true
$GameStarted = $false

# History Tracking (for flicker-free updates)
$PrevPlayerY = $PlayerY
$PrevAIY = $AIY
$PrevBallX = [int]$BallX
$PrevBallY = [int]$BallY
$PrevPlayerScore = $PlayerScore
$PrevAIScore = $AIScore
$PrevPaused = $Paused

# 4. Helper Functions
function Reset-Ball {
    $script:BallX = 40.0
    $script:BallY = 12.0
    # Randomize start direction slightly
    $script:BallDX = if ($script:BallDX -gt 0) { -1.1 } else { 1.1 }
    $script:BallDY = (Get-Random -Minimum -10 -Maximum 10) / 10
}

function Draw-StaticElements {
    # Draw Header Background
    [Console]::SetCursorPosition(0, 0)
    Write-Host (" " * $Width) -NoNewline -BackgroundColor Blue
    
    # Draw Center Line
    for ($y = $GameAreaTop; $y -le $GameAreaBottom; $y++) {
        [Console]::SetCursorPosition(40, $y)
        Write-Host "|" -NoNewline
    }
}

function Draw-ScoreBoard {
    $Header = " Score: $PlayerScore | AI: $AIScore | Level: $Level | High Score: $HighScore "
    $Header = $Header.PadLeft(40 + [int]($Header.Length / 2)).PadRight($Width)
    [Console]::SetCursorPosition(0, 0)
    Write-Host $Header -ForegroundColor Yellow -BackgroundColor Blue -NoNewline
}

function Draw-Paddle ($x, $y) {
    for ($i = 0; $i -lt $PaddleHeight; $i++) {
        $drawY = $y + $i
        if ($drawY -ge $GameAreaTop -and $drawY -le $GameAreaBottom) {
            [Console]::SetCursorPosition($x, $drawY)
            Write-Host "█" -NoNewline
        }
    }
}

function Draw-StartScreen {
    $msg = "PRESS ANY KEY TO START"
    $xPos = 40 - [int]($msg.Length / 2)
    [Console]::SetCursorPosition($xPos, 12)
    Write-Host $msg -ForegroundColor White -BackgroundColor Black -NoNewline
}

# 5. Initial Render
Draw-StaticElements
Draw-ScoreBoard
Draw-Paddle 1 $PlayerY           # Player Paddle
Draw-Paddle ($Width - 2) $AIY    # AI Paddle
# Draw Ball (Start Pos)
[Console]::SetCursorPosition([int]$BallX, [int]$BallY)
Write-Host "O" -NoNewline
Draw-StartScreen

# 6. Wait for Start
while (-not $GameStarted) {
    if ([Console]::KeyAvailable) {
        $k = [Console]::ReadKey($true)
        if ($k.Key -eq "Escape" -or $k.Key -eq "Q") {
            [Console]::CursorVisible = $true
            exit
        }
        $GameStarted = $true
        # Clear Start Message
        $msgLen = "PRESS ANY KEY TO START".Length
        $xPos = 40 - [int]($msgLen / 2)
        [Console]::SetCursorPosition($xPos, 12)
        Write-Host (" " * $msgLen) -NoNewline
        # Restore the center line part that the message might have erased
        [Console]::SetCursorPosition(40, 12)
        Write-Host "|" -NoNewline
        # Restore ball if message overwrote it
        [Console]::SetCursorPosition(40, 12)
        Write-Host "O" -NoNewline
    }
    Start-Sleep -Milliseconds 50
}

# 7. Main Game Loop
while ($Running) {
    # --- INPUT ---
    if ([Console]::KeyAvailable) {
        $Key = [Console]::ReadKey($true).Key
        if ($Key -eq "UpArrow" -and $PlayerY -gt $GameAreaTop) { 
            $PlayerY--
        }
        if ($Key -eq "DownArrow" -and $PlayerY -lt ($GameAreaBottom - $PaddleHeight + 1)) { 
            $PlayerY++
        }
        if ($Key -eq "P") { 
            $Paused = !$Paused 
        }
        if ($Key -eq "Escape" -or $Key -eq "Q") {
            $Running = $false
        }
    }

    if (-not $Paused) {
        # --- PHYSICS ---
        $BallX += $BallDX
        $BallY += $BallDY

        # Top/Bottom Wall Bounce
        if ($BallY -le $GameAreaTop -or $BallY -ge $GameAreaBottom) {
            $BallDY = -$BallDY
            # Clamp to bounds
            if ($BallY -le $GameAreaTop) { $BallY = $GameAreaTop + 0.1 }
            if ($BallY -ge $GameAreaBottom) { $BallY = $GameAreaBottom - 0.1 }
        }

        # Player Paddle Collision (Left)
        if ($BallX -le 2 -and $BallX -ge 1) {
            if ($BallY -ge $PlayerY -and $BallY -lt ($PlayerY + $PaddleHeight)) {
                $BallDX = [math]::Abs($BallDX) + 0.1
                $BallDY += ($BallY - ($PlayerY + $PaddleHeight / 2)) / 2
                $BallX = 3 # Push out
            }
        }

        # AI Paddle Collision (Right)
        if ($BallX -ge ($Width - 3) -and $BallX -le ($Width - 2)) {
            if ($BallY -ge $AIY -and $BallY -lt ($AIY + $PaddleHeight)) {
                $BallDX = -([math]::Abs($BallDX) + 0.1)
                $BallDY += ($BallY - ($AIY + $PaddleHeight / 2)) / 2
                $BallX = $Width - 4 # Push out
            }
        }

        # AI Movement
        $targetY = $BallY - ($PaddleHeight / 2)
        # Constrain Target
        $targetY = [Math]::Max($GameAreaTop, [Math]::Min($GameAreaBottom - $PaddleHeight, $targetY))
        
        if ([Math]::Abs($AIY - $targetY) -gt 0.3) {
            if ($AIY -lt $targetY -and $AIY -lt ($GameAreaBottom - $PaddleHeight + 1)) { $AIY += 0.35 }
            if ($AIY -gt $targetY -and $AIY -gt $GameAreaTop) { $AIY -= 0.35 }
        }

        # Scoring
        if ($BallX -lt 0) {
            $AIScore++
            Reset-Ball
        } elseif ($BallX -gt $Width) {
            $PlayerScore++
            if ($PlayerScore -gt $HighScore) { $HighScore = $PlayerScore }
            $Level = [math]::Floor($PlayerScore / 3) + 1
            Reset-Ball
        }

        if ($PlayerScore -eq $WinScore -or $AIScore -eq $WinScore) { $Running = $false }
    }

    # --- RENDERING (Smart Update) ---
    
    # 1. Header (Always redraw to be safe)
    Draw-ScoreBoard

    # 2. Ball Integer Positions
    $ballXInt = [int][math]::Round($BallX)
    $ballYInt = [int][math]::Round($BallY)
    
    # Clamp integers for drawing safety
    $ballXInt = [Math]::Max(0, [Math]::Min($Width - 1, $ballXInt))
    $ballYInt = [Math]::Max($GameAreaTop, [Math]::Min($GameAreaBottom, $ballYInt))

    # 3. Detect Changes
    $needRedraw = ($PlayerY -ne $PrevPlayerY) -or ($AIY -ne $PrevAIY) -or 
                  ($ballXInt -ne $PrevBallX) -or ($ballYInt -ne $PrevBallY) -or 
                  ($Paused -ne $PrevPaused)

    if ($needRedraw) {
        # --- Update Ball ---
        # Erase Old Ball
        if ($PrevBallX -ge 0 -and $PrevBallX -lt $Width -and $PrevBallY -ge $GameAreaTop -and $PrevBallY -le $GameAreaBottom) {
            [Console]::SetCursorPosition($PrevBallX, $PrevBallY)
            if ($PrevBallX -eq 40) {
                # Restore Center Line
                Write-Host "|" -NoNewline
            } else {
                # Erase
                Write-Host " " -NoNewline
            }
        }

        # Draw New Ball
        if ($ballXInt -ge 0 -and $ballXInt -lt $Width -and $ballYInt -ge $GameAreaTop -and $ballYInt -le $GameAreaBottom) {
            [Console]::SetCursorPosition($ballXInt, $ballYInt)
            Write-Host "O" -NoNewline
        }

        # --- Update Paddles ---
        # Player (Left)
        if ($PlayerY -ne $PrevPlayerY) {
            # Erase Old
            for ($i=0; $i -lt $PaddleHeight; $i++) {
                $y = $PrevPlayerY + $i
                if ($y -ge $GameAreaTop -and $y -le $GameAreaBottom) {
                    [Console]::SetCursorPosition(1, $y); Write-Host " " -NoNewline
                }
            }
            # Draw New
            for ($i=0; $i -lt $PaddleHeight; $i++) {
                $y = $PlayerY + $i
                if ($y -ge $GameAreaTop -and $y -le $GameAreaBottom) {
                    [Console]::SetCursorPosition(1, $y); Write-Host "█" -NoNewline
                }
            }
        }

        # AI (Right)
        if ($AIY -ne $PrevAIY) {
            # Erase Old
            for ($i=0; $i -lt $PaddleHeight; $i++) {
                $y = $PrevAIY + $i
                if ($y -ge $GameAreaTop -and $y -le $GameAreaBottom) {
                    [Console]::SetCursorPosition($Width - 2, $y); Write-Host " " -NoNewline
                }
            }
            # Draw New
            for ($i=0; $i -lt $PaddleHeight; $i++) {
                $y = $AIY + $i
                if ($y -ge $GameAreaTop -and $y -le $GameAreaBottom) {
                    [Console]::SetCursorPosition($Width - 2, $y); Write-Host "█" -NoNewline
                }
            }
        }

        # --- Update Pause Status ---
        if ($Paused -and !$PrevPaused) {
            [Console]::SetCursorPosition(32, 12)
            Write-Host " PAUSED (Press P) " -BackgroundColor Red -NoNewline
        } elseif (!$Paused -and $PrevPaused) {
            [Console]::SetCursorPosition(32, 12)
            if (12 -eq 12) { # logic to restore center line pixel if pause covered it
                 Write-Host "        |         " -BackgroundColor Black -NoNewline
            } else {
                 Write-Host "                  " -BackgroundColor Black -NoNewline
            }
        }

        # Save History
        $PrevPlayerY = $PlayerY
        $PrevAIY = $AIY
        $PrevBallX = $ballXInt
        $PrevBallY = $ballYInt
        $PrevPaused = $Paused
    }

    Start-Sleep -Milliseconds 20
}

# 8. Game Over
[Console]::Clear()
Write-Host @"
**************************************
             GAME OVER
      Final Score: $PlayerScore - $AIScore
      High Score: $HighScore
**************************************
"@ -ForegroundColor Green
[Console]::CursorVisible = $true