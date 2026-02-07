# PowerShell Breakout Clone
# Controls: Left/Right Arrows to move paddle. Q or ESC to Quit.

$ErrorActionPreference = "SilentlyContinue"

# 1. Console Setup
$W = 80; $H = 30
$host.UI.RawUI.WindowSize = New-Object System.Management.Automation.Host.Size($W, $H)
$host.UI.RawUI.BufferSize = New-Object System.Management.Automation.Host.Size($W, $H)
[Console]::CursorVisible = $false
[Console]::Clear()

# 2. Game Constants
$PaddleWidth = 12
$PaddleY = 27
$BallX = 40.0
$BallY = 26.0
$BallDX = 0.6
$BallDY = -0.6
$BallSpeed = 0.05
$Score = 0
$Lives = 3
$HighScore = 0
$GameRunning = $true
$GameStarted = $false

# Brick colors by row
$BrickColors = @("Red", "Magenta", "Yellow", "Green", "Cyan", "Blue")
$BrickValues = @(60, 50, 40, 30, 20, 10)

# 3. Initialize Bricks (6 rows x 10 columns) - fit within play area
$BrickWidth = 6
$BrickHeight = 1
$BrickStartX = 5
$BrickStartY = 4
$Bricks = @()

for ($row = 0; $row -lt 6; $row++) {
    for ($col = 0; $col -lt 10; $col++) {
        $Bricks += @{
            X = $BrickStartX + $col * ($BrickWidth + 1)
            Y = $BrickStartY + $row * 2
            Width = $BrickWidth
            Height = 1
            Color = $BrickColors[$row]
            Points = $BrickValues[$row]
            Alive = $true
            PrevX = -1
            PrevY = -1
        }
    }
}

$PaddleX = 40 - ($PaddleWidth / 2)
$PrevPaddleX = $PaddleX
$PrevBallX = [int]$BallX
$PrevBallY = [int]$BallY

# 4. Helper Functions
function Reset-Ball {
    $script:BallX = 40.0
    $script:BallY = 26.0
    $script:BallDX = if ((Get-Random -Minimum 0 -Maximum 2) -eq 0) { -1.0 } else { 1.0 }
    $script:BallDY = -1.0
}

function Draw-Header {
    [Console]::SetCursorPosition(0, 0)
    $header = " SCORE: $Score | LIVES: $('O ' * $Lives) | HIGH: $HighScore "
    $header = $header.PadRight($W)
    Write-Host $header -F Yellow -B DarkBlue -NoNewline
    [Console]::SetCursorPosition(0, 1)
    Write-Host ("-" * $W) -F Blue -NoNewline
}

function Draw-Walls {
    # Side walls
    for ($y = 2; $y -lt $H; $y++) {
        [Console]::SetCursorPosition(0, $y)
        Write-Host "|" -F Cyan -NoNewline
        [Console]::SetCursorPosition($W - 1, $y)
        Write-Host "|" -F Cyan -NoNewline
    }
    # Bottom wall
    [Console]::SetCursorPosition(0, $H - 1)
    Write-Host ("=" * $W) -F Cyan -NoNewline
}

function Draw-Paddle($x, $prevX) {
    # Draw new paddle first (reduces flicker)
    if ($x -ge 1 -and $x -lt $W - $PaddleWidth - 1) {
        [Console]::SetCursorPosition([int]$x, $PaddleY)
        Write-Host ("#" * $PaddleWidth) -F Green -NoNewline
    }
    # Erase old paddle (only if different position)
    if ($prevX -ge 1 -and $prevX -lt $W - $PaddleWidth - 1 -and [math]::Abs($x - $prevX) -ge 1) {
        [Console]::SetCursorPosition([int]$prevX, $PaddleY)
        Write-Host (" " * $PaddleWidth) -NoNewline
    }
}

function Draw-Ball($x, $y, $prevX, $prevY) {
    # Erase old ball
    if ($prevX -ge 1 -and $prevX -lt $W - 1 -and $prevY -ge 2 -and $prevY -lt $H - 1) {
        [Console]::SetCursorPosition([int]$prevX, [int]$prevY)
        Write-Host " " -NoNewline
        # Restore wall if needed
        if ($prevX -eq 1 -or $prevX -eq $W - 2) {
            Write-Host "|" -F Cyan -NoNewline
        }
    }
    # Draw new ball
    if ($x -ge 1 -and $x -lt $W - 1 -and $y -ge 2 -and $y -lt $H - 1) {
        [Console]::SetCursorPosition([int]$x, [int]$y)
        Write-Host "O" -F White -NoNewline
    }
}

function Draw-Bricks($bricks) {
    foreach ($brick in $bricks) {
        if ($brick.Alive) {
            # Draw brick
            [Console]::SetCursorPosition($brick.X, $brick.Y)
            $str = "=" * $brick.Width
            Write-Host $str -F $brick.Color -NoNewline
        }
    }
}

function Draw-StartScreen {
    [Console]::SetCursorPosition(30, 15)
    Write-Host "PRESS ANY KEY TO START" -F White -B Black -NoNewline
    [Console]::SetCursorPosition(34, 17)
    Write-Host "Q/ESC to Quit" -F Gray -B Black -NoNewline
}

# 5. Initial Render
Draw-Header
Draw-Walls
Draw-Bricks $Bricks
Draw-Paddle $PaddleX $PrevPaddleX
Draw-Ball $BallX $BallY $PrevBallX $PrevBallY
Draw-StartScreen

# 6. Wait for Start
while (-not $GameStarted) {
    if ([Console]::KeyAvailable) {
        $k = [Console]::ReadKey($true).Key
        if ($k -eq "Q" -or $k -eq "Escape") {
            $GameRunning = $false
            break
        }
        $GameStarted = $true
        # Clear start screen
        [Console]::SetCursorPosition(30, 15)
        Write-Host (" " * 24) -NoNewline
        [Console]::SetCursorPosition(34, 17)
        Write-Host (" " * 14) -NoNewline
    }
    Start-Sleep -m 50
}

if (-not $GameRunning) { exit }

# 7. Main Game Loop
while ($GameRunning -and $Lives -gt 0) {
    # Input
    if ([Console]::KeyAvailable) {
        $k = [Console]::ReadKey($true).Key
        if ($k -eq "LeftArrow" -and $PaddleX -gt 2) {
            $PaddleX -= 2
        }
        if ($k -eq "RightArrow" -and $PaddleX -lt $W - $PaddleWidth - 2) {
            $PaddleX += 2
        }
        if ($k -eq "Q" -or $k -eq "Escape") {
            break
        }
    }

    # Ball movement
    $BallX += $BallDX
    $BallY += $BallDY

    # Wall collisions
    if ($BallX -le 2 -or $BallX -ge $W - 3) {
        $BallDX = -$BallDX
        if ($BallX -le 2) { $BallX = 2.5 }
        if ($BallX -ge $W - 3) { $BallX = $W - 3.5 }
    }
    if ($BallY -le 2) {
        $BallDY = -$BallDY
        $BallY = 2.5
    }

    # Bottom (lose life)
    if ($BallY -ge $H - 2) {
        $Lives--
        if ($Lives -gt 0) {
            Reset-Ball
            $PaddleX = 40 - ($PaddleWidth / 2)
        }
    }

    # Paddle collision
    if ($BallY -ge $PaddleY - 1 -and $BallY -le $PaddleY + 1 -and
        $BallX -ge $PaddleX -and $BallX -le $PaddleX + $PaddleWidth) {
        $BallDY = -[Math]::Abs($BallDY)
        $BallY = $PaddleY - 1.5
        # Add angle based on hit position
        $hitPos = ($BallX - ($PaddleX + $PaddleWidth / 2)) / ($PaddleWidth / 2)
        $BallDX = $hitPos * 1.5
        if ([Math]::Abs($BallDX) -lt 0.3) { $BallDX = if ($BallDX -ge 0) { 0.3 } else { -0.3 } }
    }

    # Brick collision
    foreach ($brick in $Bricks) {
        if ($brick.Alive) {
            $brickEndX = $brick.X + $brick.Width
            if ($BallX -ge $brick.X -and $BallX -lt $brickEndX -and
                $BallY -ge $brick.Y -1 -and $BallY -le $brick.Y + 1) {
                $brick.Alive = $false
                # Erase brick
                [Console]::SetCursorPosition($brick.X, $brick.Y)
                Write-Host (" " * $brick.Width) -NoNewline
                $Score += $brick.Points
                if ($Score -gt $HighScore) { $HighScore = $Score }
                $BallDY = -$BallDY
                break
            }
        }
    }

    # Check win condition
    $aliveBricks = ($Bricks | Where-Object { $_.Alive }).Count
    if ($aliveBricks -eq 0) {
        break
    }

    # Rendering
    $ballXInt = [int]$BallX
    $ballYInt = [int]$BallY

    # Only redraw if something changed
    if ($PaddleX -ne $PrevPaddleX -or $ballXInt -ne $PrevBallX -or $ballYInt -ne $PrevBallY) {
        Draw-Paddle $PaddleX $PrevPaddleX
        Draw-Ball $BallX $BallY $PrevBallX $PrevBallY
        $PrevPaddleX = $PaddleX
        $PrevBallX = $ballXInt
        $PrevBallY = $ballYInt
    }

    Draw-Header

    Start-Sleep -m 30
}

# 8. Cleanup
[Console]::CursorVisible = $true
[Console]::Clear()

if ($aliveBricks -eq 0) {
    Write-Host "VICTORY! | Final Score: $Score" -F Green
} elseif ($Lives -le 0) {
    Write-Host "GAME OVER | Final Score: $Score" -F Red
} else {
    Write-Host "QUIT | Final Score: $Score" -F Yellow
}