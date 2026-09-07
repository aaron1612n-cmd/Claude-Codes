# IpadMouseLock

A client-side camera controller that gives Roblox on iPadOS the pointer lock it
never gets from the OS, so shift lock and first person actually turn the camera
when you move a mouse.

## The problem

On iPadOS the system cursor belongs to the OS, not to Roblox. Setting
`UserInputService.MouseBehavior = LockCenter` does nothing there, and because
Roblox derives camera rotation from `InputObject.Delta` — which only gets filled
in when the pointer really is locked — the stock camera receives `(0, 0)`
forever. The cursor slides around the screen while the camera sits still.

## The fix

`IpadMouseLock.client.lua` takes the camera over (`CameraType = Scriptable`)
whenever you are in first person or shift lock, and drives yaw/pitch itself:

- **Position deltas instead of movement deltas.** It tracks where the cursor
  *was* and where it *is*, and turns that difference into rotation. It still
  prefers the native `Delta` when a platform provides one, so the same file
  behaves normally on desktop.
- **Edge steering.** The OS cursor stops dead at the screen border, which would
  otherwise cap you at one screen-width of turning. When the pointer is not
  genuinely locked, pushing it into the outer ~110 px keeps rotating in that
  direction for as long as you hold it there — so you can spin freely.
- **Real shift lock.** Camera offset to the right, character turns to face
  wherever you look, camera pulled in so walls don't clip through it.
- **First-person self-hiding.** Since the script owns the camera, it hides the
  local character itself rather than relying on Roblox's transparency
  controller. Other players still see you normally.
- **Touch still works.** A finger drag rotates the camera too, and edge steering
  stands down while you're using touch so a cursor parked in the margin can't
  spin the view under your thumb.

## Install

Put `IpadMouseLock.client.lua` in **StarterPlayer → StarterPlayerScripts** as a
`LocalScript`. It needs no server code and no other setup.

This is a `LocalScript` for a place you can edit — your own game, or one you're
testing in Studio. It is not an injector: there's no supported way to add a
script to somebody else's running game, and the tools that claim to do it will
get your account banned.

## Controls

| Action | Input |
| --- | --- |
| Toggle shift lock | `Shift`, or the on-screen **LOCK** button |
| First person | Zoom all the way in — engages automatically |
| Zoom | Scroll wheel |
| Look | Move the mouse; hold it against a screen edge to keep turning |

The **LOCK** button exists because plenty of iPads have a mouse but no keyboard.
Set `CONFIG.ShowToggleButton = false` if you don't want it.

## Tuning

Everything adjustable is in the `CONFIG` table at the top of the file.

| Setting | Default | What it does |
| --- | --- | --- |
| `Sensitivity` | `0.32` | Degrees turned per pixel of mouse movement |
| `TouchSensitivity` | `0.45` | Same, for finger drags |
| `InvertY` | `false` | Flip vertical look |
| `EdgeMargin` | `110` | Width in pixels of the edge steering zone |
| `EdgeTurnSpeed` | `1100` | How fast a full edge push turns you |
| `ShiftLockOffset` | `(1.75, 0, 0)` | Shift lock camera offset, in studs |
| `MinPitch` / `MaxPitch` | `-78` / `78` | Vertical look limits, in degrees |
| `MinZoom` / `MaxZoom` | `0.5` / `20` | Zoom range, in studs |
| `CameraCollision` | `true` | Pull the camera in so walls don't clip |
| `CameraCollisionRadius` | `0.5` | Radius of the swept sphere used for collision |
| `CameraCollisionPadding` | `0.25` | Gap left between the camera and a wall |
| `CameraReturnSpeed` | `6` | How fast the camera eases back out after an obstruction |
| `HideCharacterDistance` | `1.5` | Hide your character once the camera is this close |
| `ShowCrosshair` | `true` | Fixed centre dot to aim with |
| `WarpThreshold` | `0.35` | Cursor jumps bigger than this fraction of the screen are ignored |

If turning feels sluggish on your iPad, raise `Sensitivity` first. If you keep
running out of room before the edge zone catches you, widen `EdgeMargin`.

## Behaving like part of the game

The script gets out of the way where a place has its own rules:

- `Player.CameraMinZoomDistance` and `CameraMaxZoomDistance` are honoured, so a
  game that forbids first person or caps how far you can pull out still gets
  what it asked for.
- `CameraMode = LockFirstPerson` stays locked in first person; the wheel can't
  pull you out of it.
- Scroll input that the game's own UI consumed doesn't also zoom the camera.
- Death hands the camera straight back to Roblox's death camera.
- Your character isn't force-turned while seated, ragdolling or dead — writing
  to the root part in those states fights the seat weld or the physics and
  makes the character judder.
- Cursor jumps larger than `WarpThreshold` are discarded. iPadOS magnetises its
  pointer onto UI elements and jumps it when it re-enters the window, and
  without this the camera flings across the map.

## Beyond this script

Nothing client-side can pin the iPad cursor, but two things help a lot:

- **A Bluetooth controller** sidesteps the problem entirely. Roblox's iPad
  controller support drives the camera from the right stick as relative input,
  with no cursor involved.
- **Lower the iPad's tracking speed** (Settings → General → Trackpad & Mouse)
  and raise `Sensitivity` here to compensate. Slower tracking means less screen
  travel per inch of real movement, so you reach the border far less often.

The underlying gap is Roblox's: iPadOS has exposed a pointer lock API
(`prefersPointerLocked`) since iPadOS 14, and the Roblox client doesn't use it.

## About the cursor

The cursor still slides around the screen in shift lock, and no in-game script
can stop that. iPadOS owns the pointer; `MouseBehavior = LockCenter` is ignored
and `MouseIconEnabled = false` only hides Roblox's own drawn cursor, not the
system one. Pinning it to the middle is exactly the thing the OS won't allow —
which is why this script converts the cursor's wandering into camera rotation
instead of trying to stop it.

What that means in practice:

- A centre crosshair is drawn while locked, so you have a stable aim point even
  though the cursor is somewhere else.
- Raising `Sensitivity` is the best mitigation. Higher sensitivity means the
  cursor travels less across the screen for the same amount of turning, so you
  hit the edge less often. Try `0.5` or `0.6` if the default has you constantly
  running into the border.
- Clicks land wherever the system cursor actually is, not at the crosshair.
  Nothing client-side can change that.

## Tests

`tests/` runs the script against a stubbed Roblox runtime (Vector2/Vector3,
enough `CFrame` math to check the camera really points where it should, signals,
and instances). 42 checks covering the iPad path with deltas forced to zero,
edge steering, desktop lock detection, pitch clamping, first-person
transparency, camera handback, and camera collision — including the easing
behaviour and the cases where a wall pushes the camera inside your own
character — plus the game-compatibility rules above: zoom limits, forced first
person, UI-consumed scroll, seated characters, death, and pointer warps.

```sh
curl -sSL -o luau.zip \
  https://github.com/luau-lang/luau/releases/latest/download/luau-ubuntu.zip
unzip -q luau.zip -d luau-bin
LUAU=./luau-bin/luau roblox/tests/run.sh
```
