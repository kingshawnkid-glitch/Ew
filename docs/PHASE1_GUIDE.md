# Phase 1 — Installation, Integration, Testing

## 1. What Phase 1 delivers

* **Central RF engine** (`RFSimulationService`). A full link budget with antenna patterns,
  polarization, ITU-R P.372 noise, weather, fading, in-band interference, SINR and quality states.
* **Terrain/structure propagation** (`TerrainPropagationService`). It reads real Roblox Terrain and
  parts through raycasts and voxel reads: ridges and valleys (Deygout diffraction), terrain mass,
  tunnels and caves, buildings with cumulative walls, foliage and water. Results are cached and
  invalidated by region, and each one comes with a plain-language explanation.
* **Universal `EWDetectable` registry.** Registration is event-driven, root resolution handles Model,
  Tool and BasePart, Backpack carry is supported, state persists across moves and respawns, and the
  connection accounting has no leaks.
* **Power and battery** state machine (boot, depletion, swap, fault).
* **Security layer** (schemas, rate limits, ownership and range checks, developer gate).
* **Scheduler** with frame, raycast and voxel budgets and three performance profiles.
* **Diagnostics.** A developer panel, a delta stream, and local-only debug path lines.
* **A reproducible Studio test range** with 13 automated tests, including a test that adds and
  removes real Terrain and shows the link responding.
* **Interaction Menu module** (`EWDevice`) for the menu you provided: Power and Status on any EW device.

Not in Phase 1, by design: the PRC-163 UI and state machine, voice and text traffic presentation,
the ES spectrum display, direction finding, jammer gameplay, drones and relays. Phase 1 provides the
shared services those phases use.

---

## 2. Installation

### Option A — Rojo (recommended once you have Studio)

```
rojo serve default.project.json      # then connect from the Rojo Studio plugin
```

### Option B — No Rojo: insert the prebuilt models

Prebuilt files are in `build/`. Regenerate them with `python3 tools/build_rbxmx.py`.

| File | Insert into (right-click the service → *Insert from File…*) |
|---|---|
| `build/EWShared.rbxmx` | `ReplicatedStorage` (creates `ReplicatedStorage.EWShared`) |
| `build/EWServer.rbxmx` | `ServerScriptService` (creates `ServerScriptService.EWServer`) |
| `build/EWClient.rbxmx` | `StarterPlayer > StarterPlayerScripts` (creates `EWClient`) |
| `build/EWDevice_InteractionModule.rbxmx` | your `Interaction Menu > Controller > Interacts` folder |

### Resulting hierarchy

```
ReplicatedStorage
  EWShared (Folder)
    DeviceDefinitions, EWConfig, EWRemotes, EWTypes, MaterialProfiles,
    RFMath, SharedUtilities, SignalCompatibility, SignalProfiles   (ModuleScripts)
    Remotes (Folder, created by the server at runtime)
      DeviceCommand (RemoteEvent), DeviceStatus (RemoteEvent),
      DiagnosticsRequest (RemoteFunction), DiagnosticsStream (RemoteEvent)
ServerScriptService
  EWServer (Folder)                  attributes: EW_PerformanceProfile, EW_MetersPerStud, EW_RangeScale, EW_RunTests
    EWBootstrap (Script)
    EW (ModuleScript)
    Services (Folder): DeviceCommandService, ElectronicDeviceRegistry, EnvironmentalConditionsAdapter,
      EquipmentPowerService, EWDiagnostics, EWScheduler, EWSecurityService, RFSimulationService,
      SignalQualityService, SpatialIndex, TerrainPropagationService
    Tests (Folder): EWTestEnvironment, EWTestRunner
StarterPlayer
  StarterPlayerScripts
    EWClient (Folder)
      EWClientController (LocalScript)
      Modules (Folder): EWClientAPI, EWDebugPathRenderer, EWDiagnosticsUI
```

No other setup is required. The system boots by itself. The `Tests` folder may be deleted in
production builds; diagnostics then report `TEST_RUNNER_MISSING`.

---

## 3. Making things electronic (map developers)

**Minimum.** Insert a `BoolValue` named `EWDetectable` (Value = true) into any Model, Tool or BasePart.
The object becomes a powered passive electronic device with a weak unintentional emission.

**Typical radio prop:**

```
RadioCrate (Model, PrimaryPart = Body)
  Body (Part)
    EWDetectable (BoolValue = true)
    EWAntenna (Attachment at the antenna tip, UpVector = element axis)   optional
  attributes on RadioCrate:
    ElectronicType = "Communications"
    SignalProfile = "VHF_FM_VOICE"
    TransmissionChannel = 45.0        (MHz, or a name from EWConfig.ChannelPlan)
    CustomDisplayName = "OP North radio"
```

**Map geometry hints (all optional):**

| Purpose | How |
|---|---|
| Wall material override | `EWMaterial = "Concrete"` (part, or its parent model) |
| Fixed attenuation | `EWAttenuationDb = 12` on a part |
| Not an RF obstacle | `EWIgnore = true` attribute or `EWIgnore` tag |
| Foliage | tag tree models `EWVegetation` |
| Noisy area (city, generator yard) | invisible part tagged `EWNoiseZone` with `NoiseEnvironment = "City"` or `ExtraNoiseDb = 15` |
| Scripted terrain edits (craters, digging) | `EW.WaitForReady().Terrain:NotifyTerrainChanged(minCorner, maxCorner)` |
| Weather system | set Workspace attributes `EW_RainRate`, `EW_SnowRate`, `EW_Fog`, `EW_StormIntensity`, `EW_NoiseEnvironment`, `EW_ExtraNoiseDb` |

Decorative non-collidable parts are ignored by default (`RespectCanCollide = true`). Give a
non-collidable wall an `EWMaterial` attribute if it should block signals. Parts with `CanQuery = false`
are invisible to all EW rays.

---

## 4. Integrating the existing models

| Model | Phase 1 integration |
|---|---|
| **AN/PRC-163** (Tool) | `EWDetectable` BoolValue inside `Handle`. Tool attributes: `ElectronicType = "Communications"`, `SignalProfile = "VHF_FM_VOICE"`, `EWSerial = "<unique>"` (the battery survives respawns). Add an `EWAntenna` Attachment at the antenna tip. Phase 2 will register it through `Registry:RegisterDevice` with dual R/T 1 and R/T 2 emitters and receivers. |
| **Jammer backpack** (worn Accessory or Model) | `EWDetectable` inside the main part. If it is an Accessory, set `EWDeviceRoot = true` on the Accessory so the whole pack is one device. For the Interaction Menu, add an `INTERACT_MENU`-tagged Attachment with `Text = "EW JAMMER"`, `Module = "EWDevice"`. Phase 4 adds the jammer profile and controls. |
| **MQ-1C Gray Eagle** (Model) | `EWDetectable` in the model, `ElectronicType = "DroneControl"`, `EWAntenna` attachment(s) on the airframe. The airborne propagation advantage already works (Test H). Payloads come in Phase 5. |
| **Interaction Menu** (your model) | Put `EWDevice` in `Controller > Interacts`. **Important:** the Controller `require`s every module in `Interacts` at startup, and the included `Breach` module waits forever for `ReplicatedStorage["Combat Breaching"]`. If your place does not have that folder, the whole menu (including EWDevice) never loads, so remove `Breach` or add the folder. |

Server code reaches the services like this:

```lua
local EW = require(game.ServerScriptService.EWServer.EW)
local ctx = EW.WaitForReady()
local record = ctx.Registry:RegisterDevice(tool, { ElectronicType = "Communications", SignalProfile = "UHF_FM_VOICE" })
local result = ctx.RF:EvaluateLink(txRecord, rxRecord)        -- LinkResult
print(result.Quality.State, result.SinrDb, table.concat(result.Propagation.Explanation, "\n"))
```

---

## 5. Client/server contracts

See `src/ReplicatedStorage/EWShared/EWRemotes.luau` for the authoritative list.

| Remote | Direction | Payload | Server checks |
|---|---|---|---|
| `DeviceCommand` | C→S | `{Action: "TogglePower"/"SetPower"/"QueryStatus", Device: Instance, On: boolean?}` | rate limit 8, then 2/s; exact schema; device resolved from the Instance; carried devices are controllable only by the carrier; world devices only within 14 studs of the player's **server-side** character |
| `DeviceStatus` | S→C (one player) | `{Ok, DisplayName, PowerState, BatteryPercent?, Message?}` | sent only to the requester or carrier |
| `DiagnosticsRequest` | C→S (RemoteFunction) | `{Action, Enabled?, Profile?, TxId?, RxId?, WatchId?}` | developer only, rate limit, schema |
| `DiagnosticsStream` | S→C (subscribed developers) | `{Kind: "Snapshot"/"TestLog"/"DebugPaths", Data}` | developer re-checked on every publish |

Clients never send positions, ranges, signal values or contacts. The server computes everything
from its own state.

---

## 6. Configuration (EWConfig)

| Section | Key settings |
|---|---|
| `Units` | `MetersPerStud` (0.28), `RangeScale` (3.0, a map-compression factor for the distance term only), `MaxRaySegmentStuds` |
| `Registry` | flag name, tag name, root-override attribute, antenna attachment name, state persistence time |
| `Propagation` | height cell size, profile spacing and samples, Deygout depth, obstacle significance thresholds, spindle count and offset, voxel limits, water, cavity and vegetation coefficients, cache TTL and size, classification thresholds |
| `Fading` | shadow σ and Rician K per class, Doppler floor, jitter |
| `Noise` | ITU-R P.372 categories, default category, storm noise |
| `Interference` | candidate range, detailed-interferer count, ACR, adjacent span |
| `Quality` | state thresholds (Clear 15 / Good 8 / Degraded 3 / Broken −1 dB margin), hysteresis, smoothing |
| `Power` | tick, drain multiplier, low and critical thresholds |
| `Security` | interaction distance, developer allowlist, group, rate limits |
| `PerformanceProfiles` | frame, ray and voxel budgets per profile |
| `MaterialProfiles` | per-material entry loss, dB/m and frequency exponent (structures and terrain); runtime `SetStructure` / `SetTerrain` |
| `SignalProfiles` | waveform-family defaults (power levels, sensitivity, NF, required SINR, antenna) |

Per-place overrides without editing code: attributes on `ServerScriptService.EWServer`:
`EW_PerformanceProfile`, `EW_MetersPerStud`, `EW_RangeScale`.

---

## 7. Running the tests in Studio

1. Install as above, then press **Play** (a player character also enables the equip/unequip checks).
2. Either:
   * set the attribute `EW_RunTests = true` on `ServerScriptService.EWServer` (before Play, or during
     Play from the server-side Explorer or command bar):
     `game.ServerScriptService.EWServer:SetAttribute("EW_RunTests", true)`; or
   * press **F6** → **Run Tests** in the diagnostics panel.
3. Output appears in the Output window (`[EW] Test: ...`) and in the panel's **Log** tab.
4. The test range is built at `EWConfig.TestEnvironment.Origin` = (12000, 0, 12000). It overwrites
   terrain in an area of about 2,400 × 2,400 studs there, so change the origin if your map uses that
   space. It stays in place after the run for inspection: fly there, open F6 → Live → Paths, and watch
   links between stations with *Watch link* (ids are on the Devices tab).

### Expected results

The numbers below come from the reference implementation of the same equations
(`MetersPerStud 0.28`, `RangeScale 3`, deterministic). Studio values will differ by a few dB because
of profile sampling, voxel quantization, spindle rays and antenna pattern terms, which is why the
assertions are relative.

| Scenario (UHF 300 MHz unless noted) | Excess loss | Link margin | State |
|---|---|---|---|
| Open lane, 1,400 studs | ≈ 0 dB | ≈ +40 dB | Clear |
| Ridge lane, same distance | ≈ 38 dB | ≈ +2 dB | Broken |
| VHF 45 MHz, open / ridge | 0 / ≈ 22 dB | ≈ +20 / ≈ −2 dB | Clear / Unusable |
| L-band 1350 MHz, open / ridge | 0 / ≈ 57 dB | ≈ +16 / ≈ −41 dB | Clear / NoSignal |
| Crest of ridge → far station | small | ≈ +76 dB | Clear |
| Airborne (300 studs up) → far station | ≈ 5 dB | ≈ +66 dB | Clear |
| Terrain change: flat → 80-stud berm → removed | 0 → ≈ 27 → 0 dB | drops ≈ 27 dB, then restored | |
| Walls at 300 MHz: wood 1 stud / concrete 2 studs / metal container | ≈ 3 / ≈ 15 / ≈ 25 dB | | |
| Forest, ~100 studs of canopy (300 MHz) | ≈ 7 dB vegetation | | |
| Straight tunnel, 112 studs deep (45 MHz / 300 MHz) | ≈ 43 dB / ≈ 3 dB cavity | | |
| Submerged antenna 12.5 studs deep (300 MHz) | ≥ 15 dB more than a buoy antenna | | |

Every test prints PASS or FAIL with its numbers and explanation lines, and the run ends with a summary.

### Test J — client-side abuse script

Run this in the Studio **client** command bar during Play, after setting
`EWConfig.Security.StudioUsersAreDevelopers = false` to also test the non-developer path:

```lua
local remotes = game.ReplicatedStorage.EWShared.Remotes
local cmd = remotes.DeviceCommand
cmd:FireServer("garbage")                                         -- PAYLOAD_NOT_TABLE
cmd:FireServer({ Action = "TogglePower" })                        -- MISSING_DEVICE
cmd:FireServer({ Action = "Explode", Device = workspace })        -- BAD_ENUM_ACTION
cmd:FireServer({ Action = "TogglePower", Device = workspace, Range = 99999 }) -- UNEXPECTED_FIELD
cmd:FireServer({ Action = "TogglePower", Device = workspace.Terrain })       -- UNKNOWN_DEVICE
for i = 1, 40 do cmd:FireServer({ Action = "QueryStatus", Device = workspace }) end -- RATE_LIMIT
print(remotes.DiagnosticsRequest:InvokeServer({ Action = "RunTests" }))     -- NOT_AUTHORIZED for non-developers
```

Expected: nothing changes on the server, and the Perf tab's **Security** section lists each rejection
reason with its count.

---

## 8. Known limitations (honest list)

* **Not executed in Studio yet.** This environment has no Roblox Studio or Luau runtime. The code
  has been checked by a structural Luau linter (block and bracket balance, aware of if-expressions)
  and an undeclared-identifier scan, and the RF math was cross-checked against an independent Python
  reference. The first Studio run of the test suite is the real validation; please send me its
  output.
* **Simplified propagation.** There are no specular reflections or multipath ray tracing (multipath
  is statistical fading). Diffraction is knife-edge, which underestimates rounded hills slightly.
  Tunnels are treated as straight-line cavity attenuation, not a waveguide simulation.
* **Surface height.** The height field is the top static surface. Overhangs are handled only where
  the line of sight is actually checked: by voxel reads for terrain, and by rays for parts.
* **Doors and moving walls** are picked up by the 8 s path-cache TTL, or immediately with
  `NotifyTerrainChanged`. Scripted terrain edits without a notification heal within 300 s.
* **Interference.** Only the strongest N interferers get full terrain analysis per receiver; the
  rest use the basic loss, which is conservative.
* **RangeScale 3** is a game assumption, not physics. Use 1.0 for literal avatar scale.
* **CanQuery = false** geometry is invisible to the RF system (a Roblox raycast limitation).

---

## 9. Follow-up — Phase 2 (AN/PRC-163)

* Use `RadioDefinitions` with the public datasheet bands: R/T 1 covers 30–88, 118–174 and 225–512 MHz
  plus SATCOM; R/T 2 covers 225–450 and 1300–2600 MHz. Add 99 net presets and 15 knob presets
  (FP + 15).
* Build a radio state machine with two independent receiver/emitter paths, crossband (`XB`),
  scanning, squelch (noise or tone), TX power LOW/MED/HIGH, key slots, zeroize, and GPS/MGRS display.
* Build a `RadioNetworkService` and `TransmissionService`. PTT is validated by the server, and
  delivery goes to eligible receivers with the `LinkResult.Quality` already computed here. Text
  traffic is the reliable fallback. Voice uses `AudioDeviceInput`/`VoiceChat` only where Roblox
  permissions allow.
* Build the screen UI from your reference images (spec in `docs/RESEARCH_NOTES.md`), physical keypad
  bindings, mobile controls, and audio degradation driven by `NoiseLevel`, `DropoutRate` and
  `PacketLoss`.
