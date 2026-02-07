# PowerShell Games

A collection of classic arcade games implemented in PowerShell.

## Games

| Game | Description |
|------|-------------|
| **Breakout** | Classic brick-breaking game. Use the paddle to bounce the ball and destroy all bricks. Different colored rows have different point values. |
| **Centipede** | Arcade shooter where you battle a centipede that splits when hit. Features destructible mushrooms and a spider enemy that zig-zags through the player area. |
| **Pac-Man** | Classic maze game. Collect all dots while avoiding ghosts. Eat power pellets to temporarily turn ghosts vulnerable and eat them for bonus points. |
| **Pong** | Classic table tennis game. Control the left paddle against an AI opponent. First to 10 points wins. Includes pause functionality. |
| **Space Invaders** | Classic arcade shooter. Defend Earth from waves of descending aliens. Features destructible bunkers, UFO bonus targets, and increasing difficulty. |

## Requirements

- Windows PowerShell 5.1+ or PowerShell 7+
- PowerShell console (not ISE)

## Usage

Run any game directly from PowerShell:

```powershell
.\breakout.ps1
.\centipede.ps1
.\pacman.ps1
.\pong.ps1
.\spaceinvaders.ps1
```

### Common Controls

| Key | Most Games |
|-----|------------|
| Arrow Keys | Movement |
| Space / Click | Fire / Action |
| P | Pause (Pong) |
| Q / ESC | Quit |

### Game-Specific Controls

- **Breakout**: Left/Right arrows to move paddle
- **Centipede**: Arrow keys to move, Space to fire
- **Pac-Man**: Arrow keys for movement
- **Pong**: Up/Down arrows to move paddle, P to pause
- **Space Invaders**: Left/Right arrows to move, Space to fire

## Notes

- These games use the PowerShell console for rendering and input
- Console window size is automatically set for optimal gameplay
- High scores are maintained during the session
- Press `Ctrl+C` at any time to exit