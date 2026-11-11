# CardboardOS

Turns an iOS 12 device into a Google Cardboard computer.

A SpringBoard tweak mirrors the composited display into two lens-corrected eye
views and lets you drive the entire OS with the viewer's conductive button. The
pointer is a virtual mouse: a small dot drawn over the picture, steered by the
gyroscope and accelerometer in every direction. Press the button and the click
lands where the dot sits — that is how you open apps from the home screen, or
anything else in whatever is on screen. Holds open the system Home, app
switcher and settings menu. No touch screen access is needed once the phone is
in the headset.

The view is always laid out for landscape use: the two eyes sit along the
panel's long axis and both the mirrored picture and the menu are rotated to
match, whatever orientation the UI thinks the phone is in.

```
┌───────────────────────┬───────────────────────┐
│                       │                       │
│   left eye view       │   right eye view      │
│   (barrel-corrected)  │   (barrel-corrected)  │
│        · dot          │        · dot          │
│                       │                       │
└───────────────────────┴───────────────────────┘
```

## What it actually does

* `CARenderServerRenderDisplay("LCD", …)` captures the whole composited display
  (SpringBoard and whatever app is in front) into a triple-buffered pool of
  `IOSurface`s. This is the same private entry point jailbreak screen recorders
  use.
* The surfaces are wrapped as Metal textures and drawn by an `MTKView` that
  covers the screen. A runtime-compiled Metal fragment shader does inverse
  barrel distortion (`k1`, `k2`), chromatic-aberration correction, optional
  virtual-screen curvature, vignette and brightness, and draws the mouse dot in
  source space so it stays glued to the pixel it points at.
* The overlay window is marked with `CALayer.disableUpdateMask = 0x12`, the
  private flag that keeps a layer visible on the panel but out of screenshots
  and captures. That is what stops the mirror from capturing its own output.
* While stereo is on the overlay claims **every** touch, because the viewer's
  pad is hand-built and presses wherever it presses: a press that is not claimed
  does not become a click, it reaches SpringBoard as an ordinary tap and opens
  whatever icon sits under the pad. SpringBoard's own windows are also made
  non-interactive while stereo is on, so a press that escapes the overlay is
  dropped instead of opening an app; they accept touches again for the fraction
  of a second a synthetic click is being delivered. With stereo off the overlay
  claims only a 72 pt disc around the button (so four taps can bring stereo
  back), every SpringBoard window is interactive again and fingers reach iOS
  everywhere. Synthetic taps/swipes are injected with
  `IOHIDEventSystemClientDispatchEvent` (falling back to
  `BKHIDSystemInterface`) and the overlay goes fully transparent to hit testing
  while they are delivered.

## Build

Requires [Theos](https://theos.dev) plus a jailbroken iOS 12 device.

```sh
# one-time, if you do not already have Theos:
bash -c "$(curl -fsSL https://raw.githubusercontent.com/theos/theos/master/bin/install-theos)"
export THEOS=$HOME/theos          # the installer adds this to ~/.zshrc

make package
make install          # needs THEOS_DEVICE_IP, or install the .deb manually
killall -9 SpringBoard
```

Over SSH to a device that still has the default `alpine` password, use the deploy
target. It builds, copies **only the newest** package and resprings only if dpkg
succeeded:

```sh
make deploy                                   # 100.88.174.24, password alpine
make deploy THEOS_DEVICE_IP=192.168.4.52 CBB_SSH_PASSWORD=secret
```

Do not install `packages/*.deb`: that installs every old build kept in the
folder, and dpkg configures whichever filename sorts last — `-10` sorts before
`-2`, so the phone can end up running a build several rounds behind the source.
If the folder has piled up, `rm -rf packages` first.

Without `sshpass` you can use `make install THEOS_DEVICE_IP=192.168.4.52`, which
prompts for the password. Any SSH client works as long as the device is running
OpenSSH from Cydia/Sileo and is reachable over the LAN.

The Makefile falls back to `~/theos`, `/opt/theos`, `~/.theos` and
`/usr/local/theos` when `THEOS` is missing from the environment, so a fresh
terminal or a GUI-launched build should still work. If none of those exist it
stops with a message instead of failing on an empty include path. Xcode command
line tools (`xcode-select --install`) are required by Theos.

iOS 12 on A12+ devices needs an arm64e slice, and current clang cannot produce a
compatible arm64e ABI for iOS 12–13.7. Either build with the Xcode 11.7
toolchain, or build arm64 only for an A11-or-earlier device:

```sh
make ARCHS=arm64 package
```

The tweak only targets `com.apple.springboard`.

## First run

1. Put the phone into the viewer. Any press anywhere on the panel counts as a
   click while stereo is on, so the pad's exact contact point does not matter.
   The stored hotspot, used for the on-screen marker, ships at the middle of the
   left edge (5 % across, 50 % down); use **Learn button** to pin it to the pad.
2. On first launch the screen turns into the stereo view. If the image is
   sideways, or the dot travels opposite to your head, open the menu
   (press-and-hold three times) and change **Rotation** by 180° — that row both
   turns the picture and the aim axes that go with it.
3. The tap mapping is measured automatically a few seconds after the stereo view
   comes up: three taps are sent to known panel points, the overlay reads back
   where they actually arrived, and the transform between the two is stored. If
   clicks drift, **Calibrate taps** in the menu runs it again. **Lens k1/k2** is
   already set from the Google Cardboard v2 / I/O 2015 viewer profile
   (`k1 0.34`, `k2 0.55`) — adjust only if you use a different viewer.

## Button map (stereo view)

| Gesture | Action |
| --- | --- |
| move your head | the dot follows your aim, in every direction |
| 1 tap | confirm the click at the dot |
| 2 taps | scroll toward the end of the page (synthetic swipe) |
| 3 taps | scroll back |
| 4 taps (or more) | recentre: the current head pose becomes "straight ahead" |
| press and hold, 1 tap | Home |
| press and hold, 2 taps | app switcher |
| press and hold, 3 taps | open the viewer menu |
| press and hold, 4 taps | turn stereo off (normal iOS returns) |

A press has to stay down for 1.2 s before it becomes a hold, so an ordinary
click is never mistaken for Home. When stereo is off, four quick taps on the
button bring it back. The button disc is the only part of the screen the tweak
consumes while off.

The dot is absolute: the angle between your current head pose and the recentred
pose maps linearly onto the panel, about 17° of yaw or pitch for the full side
at the default **Aim sensitivity**. Both axes use the same angular range, so
up, down, left, right and every diagonal move the dot by the same amount of
head turn and it can reach any point on the screen; yaw is unwrapped past the
half turn so a big head rotation never snaps it back. Looking past the edge
simply pins the dot there. Recentre whenever you pick the phone up, change your
grip, or notice the pointer drifting — the gyro is corrected against the
magnetometer, but no phone gyro is perfectly drift free.

The click lands where the dot was **when the button went down**, not where it has
drifted to by the time the tap is injected a fraction of a second later, so
pressing on a small target does not slide off it.

The aim reference is captured from whatever pose the phone was in when stereo
came on, which is usually flat on a desk. Two things stop that from pinning the
dot: picking the phone up re-captures the reference, and if the aim ever sits
more than twice outside its range for half a second the tweak re-captures on its
own. Normal aiming at a corner stays at the edge and never triggers it.

## Menu map (press-and-hold three times)

| Gesture | Action |
| --- | --- |
| 1 tap | next row |
| 2 taps | increase / next value |
| 3 taps | decrease / previous value |
| 4 taps | activate row |
| press and hold, 1 tap | close menu |
| press and hold, 2 taps | +10 (fast adjust) |
| press and hold, 3 taps | −10 |

Rows: stereo on/off, fill vs 1:1 view, zoom, panel rotation, lens `k1`/`k2`,
chroma, curvature, parallax, brightness, vignette, hide-overlay-from-capture,
aim sensitivity, calibrate taps, mirror, SB landscape, capture FPS, learn
button, recentre aim, reset settings, close.

**Mirror** flips the captured picture, per axis: `NONE` normally, `U`/`V` if the
device hands the surface over flipped (text reads backwards, or the picture is
upside down in a way the rotation row cannot fix). The flip is applied to the
cursor as well as to the picture, so the dot stays on the pixel the tap will hit
whichever setting you use, and the aim direction follows the flip so looking
right still moves the dot right. Use `U+V` for a 180° flip.

**Calibrate taps** re-measures the map from a dot position to where this build
actually delivers a tap. Digitizer coordinates are normalised against *some*
space — the panel's, the forced landscape interface's, or one of those with the
axes' aspects swapped — and which one differs between iOS builds. Instead of a
manual quarter-turn knob, three probes are injected to known panel points, the
overlay reads the arrival point of each, and the affine map that takes one to
the other is solved and stored (`tapA…tapTY`, `tapCalibrated`). The probes are
claimed by the overlay, so they cannot touch anything; if the overlay is not
owning touches at all, calibration says so in the stages file and keeps the
previous map. It runs by itself whenever the interface orientation changes,
because that is what changes the mapping.

**SB landscape** decides whether SpringBoard itself rotates, and it ships `AUTO`.
On iPhone the home screen normally claims portrait only, which is why it looks
sideways in the viewer — iOS lays portrait content out along the panel's long
axis. Setting this row relaxes that claim while stereo is on, so the home screen
lays out for the landscape eyes: `AUTO` follows the phone like an app,
`LEFT`/`RIGHT` pin a direction if auto picks the wrong 180. It is restored to
portrait when stereo goes off.

Three things are overridden while it is on: `-[UIApplication
supportedInterfaceOrientationsForWindow:]` (every window answers landscape),
SpringBoard's delegate method of the same name — hooked lazily, because the
delegate object does not exist yet when the tweak starts — and
`SBHomeScreenViewController`'s `supportedInterfaceOrientations`/`shouldAutorotate`.
SpringBoard's rotation lock is released once, since the lock gates the home
screen even when an orientation is forced. The orientation is then requested and
re-requested once a second for up to ten attempts, because UIKit resets it for
its own reasons (alerts, the status bar, an app launch). The log shows which hooks
were found (`landscape hooks: app 1 home screen 1`) and every attempt
(`asked the home screen for interface orientation 3 (attempt 1/10)`); `home screen 0`
means this build has no `SBHomeScreenViewController` and the masks are all it can
try.

The override edits SpringBoard's own orientation policy, so it is opt-in per
device: while it is on, a `landscapeArmed` flag is written and cleared after 20
seconds of survival. If the phone resprings or crashes inside those 20 seconds,
the flag is still set at the next launch and the override is switched back to
`OFF` automatically instead of looping.

**Hide overlay** controls the private capture-exclusion flag. Leave it on; it is
what keeps the mirror from filming itself. Turn it off only if the flag is
causing the stereo image to freeze on a particular device.

At launch the tweak also sanity-checks the capture once, five seconds in: if the
frames are entirely black it says so in the log and shows `CAPTURE IS BLACK` in
the headset menu, but it does not switch stereo off — silently turning itself off
looks exactly like the tweak not being installed.

**Learn button** arms the whole screen for one touch: press the viewer button
and its real panel position is stored as the new hotspot, which is where the
menu draws its button marker. The position changes nothing about clicks — a
press is a click wherever it lands while stereo is on — so this is only for
keeping the marker honest.

```sh
defaults write com.buffy.cardboardos buttonX -float 0.05
defaults write com.buffy.cardboardos buttonY -float 0.50
killall -9 SpringBoard
```

Settings live in
`/var/mobile/Library/Preferences/com.buffy.cardboardos.plist`.

## Design notes and honest limits

* **This is a stereoscopic presentation of a flat screen, not true depth.**
  iOS renders one image; the tweak cannot invent a second eye's parallax. Both
  eyes receive the same captured frame, pre-distorted for the lenses, with the
  dot shared. **Parallax** shifts each eye's sampling window outward from the
  centre; it ships at `0.11`, which is where the lens axes of a Cardboard v2
  viewer (64 mm apart) fall on an 88.5 mm panel, so the picture sits under the
  lenses instead of toward the nose. Setting it to `0` centres the view in
  each half again.
* **Fill mode halves horizontal resolution per eye.** A 2436 px wide panel split
  into two 1218 px eye views must squash the 2436 px UI by 2×. That is physics.
  Use **View: 1:1** plus zoom and the dot-following pan for sharp, readable
  text; 1:1 shows a 1:1 window of the UI instead of the whole width, and the
  window follows the dot automatically.
* **Portrait-only apps** (Settings, for example) still draw portrait; in a
  landscape-held viewer they appear sideways. Rotation only corrects the panel
  capture, not the app's supported orientations. Only SpringBoard is rotated on
  request, by **SB landscape**.
* **The home screen rotation is a policy override, not a public API.** It
  swizzles the orientation questions SpringBoard asks, and skips anything its
  build does not have. If a particular iOS 12 build still refuses to lay the home
  screen out sideways, set **SB landscape** to LEFT or RIGHT, and fall back to
  the panel **Rotation** row, which always works.
* **Fill** fits the whole panel into each eye without distorting it, so there
  are black bars on two sides — the panel is portrait and the eye is not, and the
  alternative is a picture stretched by more than 2:1. **Native 1:1** has no bars
  and no distortion, at the cost of showing a window rather than the whole screen.
* **Secure content** (passwords, DRM video, some banking apps) is excluded from
  the capture by the system, so it shows black in the headset. That is the
  capture API behaving correctly.
* **No typing.** The on-screen keyboard is reachable and tappable with the
  dot, but there is no button-driven text entry. Pair a Bluetooth keyboard
  or use the app's own dictation.
* **The pointer is head aim, not real head tracking.** The gyro moves a 2D dot
  across a flat mirror of the screen; there is no parallax, no depth and no
  world that shifts as you turn. Rotating your head scrolls the aim instead of
  changing your viewpoint, and the dot stops at the edge of the screen rather
  than wrapping round it.
* Home and app switcher are injected as the consumer-control "Menu" usage,
  which is the hardware Home button. If a future iOS build ignores it, use the
  menu's **Stereo off** and the physical button.
* Injection field constants (`0xb0009`, `0xb0019`) follow the working
  Veency/SimulateTouch recipe. They are the fragile part of any HID tweak; if
  taps do nothing but the dot moves, that is where to look.

## If something goes wrong

* **"The tweak did not load"** — with nothing on screen there is no overlay
  either, so it is one of three things. The installed package may be older than
  the build you just made (`dpkg -l | grep cardboard` must match, see **Build**).
  The dylib may not have loaded at all: an arm64e slice built for the wrong iOS
  12 ABI does not load, which is why the Makefile builds arm64 only by default.
  Or SpringBoard started before capture was ready. The log line
  `[CardboardOS] started at {w, h}` means it loaded; its absence means it did
  not.
* A tweak that is switched off is invisible on purpose: no overlay, no label, no
  window. Watch the log to tell a working capture from a black one —
  `capture is live: {1125, 2436}` versus `captured frames are black: …`.
* **Landing in safe mode** means SpringBoard died with the tweak loaded. Leave
  safe mode without losing the tweak by switching it off and respringing:

  ```sh
  ssh root@100.88.174.24                     # password: alpine
  defaults write com.buffy.cardboardos enabled -bool NO
  defaults write com.buffy.cardboardos homeLandscape -int 0
  killall -9 SpringBoard                    # leave safe mode, tweak dormant
  ```

  Four button taps turn stereo back on when you want to try again, or remove it
  entirely with `dpkg -r com.buffy.cardboardos`.
* The tweak protects itself against that loop: `bootArmed` is written *before*
  any window, capture or shader work, and cleared once everything has run for 25
  seconds. One bad launch drops **SB landscape** and retries stereo; a second
  comes up dormant and retries once after 30 seconds; a third leaves stereo off
  until four button taps bring it back. Startup exceptions are caught as well.
* Watch what it does over SSH before blaming a feature:

  ```sh
  tail -f /var/log/syslog | grep CardboardOS
  ```
* Hold the volume-up button while respringing to enter safe mode.
* `killall -9 SpringBoard` from SSH always removes the overlay.
* Delete `/var/mobile/Library/Preferences/com.buffy.cardboardos.plist` to reset
  every setting, including `enabled`.
* Set `enabled` to `false` in that plist if you want the tweak installed but
  dormant; four button taps still re-enable it.

## Injection frameworks

The package does not care which loader injects it: it uses a single `%ctor`,
no Logos `%hook` and no `MSHook*` call, so it does not link against
libsubstrate and needs nothing from the framework beyond being `dlopen`ed.
Sonar, Substitute, libhooker and Substrate all work.

Two things had to be aligned for that to be true, and both used to be wrong:

* `Depends: mobilesubstrate` is gone. Sonar does not provide that virtual
  package, and dpkg refuses to *configure* a package whose dependencies are
  unsatisfied — the files get unpacked, the `postinst` that resprings never runs,
  and the phone looks exactly as it did before. The only dependency left is the
  firmware version.
* `-Wl,-dead_strip_dylibs` keeps `libsubstrate.dylib` out of the load commands,
  so dyld does not look for a library Sonar may not ship. Without it a loaded
  dylib can fail on a missing dependency and vanish silently.
* Both filter directories get the tweak, as real copies. Substrate and
  Substitute read `/Library/MobileSubstrate/DynamicLibraries`; Substitute-style
  and Sonar-style loaders read `/usr/lib/TweakInject`, and which one dpkg
  populates depends on the Theos that built the package — on the iPhone 5S test
  device one build installed into `/usr/lib/TweakInject` while
  `/Library/MobileSubstrate/DynamicLibraries` stayed empty, and a later one
  installed into neither.
  So `make deploy` no longer guesses: it ships `deploy-ondevice.sh` to the device
  and runs it. That script asks `dpkg -L` where the package put its files, falls
  back to searching `/Library`, `/usr/lib`, `/usr/local/lib`, `/var/jb` and
  `/usr/share` for `CardboardOS.dylib`, and copies the binary and its filter
  plist into both directories (copy, not symlink: a loader is not obliged to
  follow one). It prints every path it tried, so a package that installs to a new
  place is visible instead of silent.
* The filter plist is XML, not Theos's shorter OpenStep syntax. CoreFoundation
  reads both, but a loader that parses filters with its own code may only handle
  XML, and a filter that does not parse means the dylib is never injected.

`make deploy` now says `INSTALL OK` or `INSTALL FAILED` with dpkg's own reason,
lists both injection directories, and lists the installed Sonar/Substitute/
libhooker packages.

It also clears and then reads back
`/var/mobile/Library/Preferences/com.buffy.cardboardos.stages`, the breadcrumb
file the tweak appends to at each step of startup. This exists because iOS 12
here has no `syslogd`: `NSLog` output goes nowhere, so without it "the tweak
loaded and did nothing" and "the tweak was never loaded" are indistinguishable.
`make doctor` prints it, and a run that never got loaded leaves no file at all.

`make deploy` also deletes `/var/mobile/Library/Preferences/com.buffy.cardboardos.plist`
before respringing, so the next launch starts from the built-in defaults (stereo
on). This matters because the tweak stores its own state there: an earlier build
persisted `enabled = NO` whenever a launch failed, and the boot guard writes the
same flag after two early deaths. A reinstalled, repaired build then came up
switched off and looked exactly like a tweak that never loaded. `make doctor`
leaves preferences alone, so it cannot mask the current state. If it says `INSTALL OK` and the injection lines show the
files, the package is in place and the remaining question is whether the loader
injects into SpringBoard — `make doctor` prints the same information without
installing anything.

## Files

| File | Role |
| --- | --- |
| `Tweak.x` | SpringBoard entry point |
| `CBBController.m` | overlay window, gesture mapping, cursor, menu model |
| `CBBStereoRenderer.m` | Metal eye compositor |
| `CBBShaders.h` | runtime-compiled lens shader |
| `CBBDisplayCapture.m` | `CARenderServerRenderDisplay` → IOSurface → Metal |
| `CBBTouchInjector.m` | synthetic digitizer / Home events |
| `CBBClickRecognizer.m` | click-count and hold state machine |
| `CBBStereoHUD.m` | two-eye menu and button marker |
| `CBBMotionPointer.m` | gyro head aim (`CMMotionManager`) |
| `CBBHomeLandscape.m` | SpringBoard home screen orientation override |
| `CBBPrefs.m` | persisted settings |
