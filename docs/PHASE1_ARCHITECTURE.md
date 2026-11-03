# Phase 1 — Architecture and Simulation Design

This document covers the items the brief asked to have defined before implementation (section 22):
architecture, device data schema, BoolValue registration rules, RF propagation model, terrain
interference model, signal compatibility interface, server update scheduler, and the diagnostics
and testing plan. Every equation here is implemented in the source files it names.

> **Simulated, not measured.** All RF numbers are produced by documented, simplified, configurable
> models. A few defaults come from public, unclassified, non-export-controlled sources (the L3Harris
> AN/PRC-163 datasheet and ITU-R recommendations), and each one is labelled where it appears.
> The project does not reproduce classified waveforms, real cryptography, or real jamming performance.

---

## 1. Architecture

```
ReplicatedStorage
└── EWShared                          (Folder)  shared, side-effect-free
    ├── EWTypes                       types + unit conventions
    ├── EWConfig                      every tunable parameter, performance profiles
    ├── RFMath                        pure RF equations (FSPL, two-ray, P.526, P.372, P.838, ...)
    ├── SignalProfiles                emission/reception profiles (radio, drone, radar, passive, noise)
    ├── DeviceDefinitions             ElectronicType -> defaults (battery, boot, profile, class)
    ├── MaterialProfiles              structure + terrain material attenuation
    ├── SignalCompatibility           energy / demodulation / authorization interface
    ├── SharedUtilities               Signal, ConnectionBag (live-connection count), TokenBucket
    ├── EWRemotes                     remote contracts; server creates, clients wait
    └── Remotes                       (Folder, created at runtime by the server)

ServerScriptService
└── EWServer                          (Folder)
    ├── EWBootstrap      (Script)     wires services via a context table, starts scheduler
    ├── EW               (Module)     facade: EW.WaitForReady() -> context for other scripts
    ├── Services
    │   ├── EWScheduler               heartbeat scheduler, frame/raycast/voxel budgets, profiles
    │   ├── SpatialIndex              XZ spatial hash (candidate filtering)
    │   ├── ElectronicDeviceRegistry  EWDetectable / tag / API registration, poses, lifecycle
    │   ├── EquipmentPowerService     power state machine, battery, boot, faults
    │   ├── EnvironmentalConditionsAdapter  weather + noise environment (attribute driven)
    │   ├── TerrainPropagationService geometry analysis (raycasts + voxels) and loss math
    │   ├── SignalQualityService      SINR margin -> quality state / presentation values
    │   ├── RFSimulationService       link budget, interference, watched links, emissions
    │   ├── EWSecurityService         rate limits, schemas, ownership/range, developer gate
    │   ├── DeviceCommandService      DeviceCommand remote (power / status)
    │   └── EWDiagnostics             snapshots, delta stream, debug paths, test trigger
    └── Tests
        ├── EWTestEnvironment         builds the terrain/structure test range
        └── EWTestRunner              tests A, B, C, E, F, G, H, I, J, K, L, M, TC, U

StarterPlayer.StarterPlayerScripts
└── EWClient                          (Folder)
    ├── EWClientController (LocalScript)  notifications, loads dev UI for developers only
    └── Modules
        ├── EWClientAPI               request wrapper (TogglePower/SetPower/QueryStatus)
        ├── EWDiagnosticsUI           developer panel (Devices / Links / Perf / Log)
        └── EWDebugPathRenderer       LOCAL path lines under workspace.CurrentCamera
└── EWInteractionMenu                 (Folder)  EW-only rebuild of the provided Interaction Menu
    ├── Controller (LocalScript)      EWDetectable discovery, hold-to-show, 3-level lists
    ├── Templates                     GUI built in code from the original layout values
    └── Interacts/EW                  Power / Emission / Mode / Battery / Status requests
```

### Dependency rules

* Shared modules depend only on other shared modules.
* No service `require`s another service. `EWBootstrap` builds one `context` table and calls
  `Init(context)` on every service, then `Start()`. Services reach each other only through
  `context` at runtime, so there are no circular requires and each service can be replaced.
* Device behaviour, such as a radio, a drone controller or a relay, lives in device and equipment
  code. Signal physics lives in `RFSimulationService` and `TerrainPropagationService`.
  A new device type adds a `SignalProfile` and a `DeviceDefinition`; it never adds its own
  propagation code.

### Initialization order

| Init (wiring) | Start (events, jobs) |
|---|---|
| Diagnostics → Scheduler → Environment → Terrain → Registry → Power → Quality → RF → Security → DeviceCommands | Environment → Terrain → Registry → Power → RF → Security → DeviceCommands → Diagnostics → **Scheduler heartbeat last** |

---

## 2. Electronic device data schema

The server owns one `DeviceRecord` per registered root (`EWTypes.DeviceRecord`):

| Field | Meaning |
|---|---|
| `Id` | `EW-00001` style id (diagnostics only; never needed by players) |
| `Root` | owning Instance (Model, Tool or BasePart) |
| `DefinitionId`, `ElectronicType`, `DetectionClass` | resolved from `ElectronicType` attribute |
| `DisplayName`, `Faction`, `Serial`, `OwnerUserId` | `CustomDisplayName`, `ElectronicFaction`, `EWSerial`, carrier |
| `Detectable` | result of the EWDetectable rules (eligible for detection results) |
| `RegistrationSources` | `{Flag, Tag, API}` |
| `PowerState` | `Off · Booting · On · Fault · Depleted` |
| `Battery` | `CapacityWh, ChargeWh, Idle/Receive/TransmitDrawW, Low/Critical fractions, Removable` |
| `Emitters[]` | per emission: frequency, bandwidth, TX power, duty cycle, `Transmitting`, network, security profile, priority, stability, antenna, signature reduction |
| `Receivers[]` | per receiver: frequency, bandwidth, sensitivity, noise figure, required SINR, interference rejection, network, security profile, antenna |
| `Position`, `AntennaCFrame`, `Velocity`, `InWorld` | pose cache refreshed by the adaptive pose job |
| `AnchorPart`, `AntennaAttachment` | Instance bindings (`EWAntenna` attachment optional) |
| `Revision` | bumps on every configuration/state change (cache keys, deltas) |

`AntennaSpec`: `Pattern (Isotropic|Omni|Directional)`, `GainDbi`, `BeamwidthDeg`, `FrontToBackDb`,
`ElevationFloorDb`, `Polarization (Vertical|Horizontal|Circular)`, `HeightOffsetStuds`.

### Optional attributes (root, or on the BoolValue itself as fallback)

| Attribute | Type | Effect |
|---|---|---|
| `ElectronicType` | string | `Generic`, `Communications`, `ActiveTransmitter`, `Radar`, `DroneControl`, `BackgroundSource` (+ aliases) |
| `SignalProfile` | string | profile id from `SignalProfiles` |
| `EmissionEnabled` | bool | emitter `Transmitting` |
| `TransmissionChannel` | number (MHz) or string (channel plan name / numeric string) | frequency |
| `PowerState` | `"On"`/`"Off"` or bool | initial state; changes drive the power service |
| `DetectionDifficulty` | 0..1 | signature reduction (0–25 dB) applied to ES detection only |
| `SignalStrength` | number (dBm) or `"LOW"/"MED"/"HIGH"` | transmit power |
| `ElectronicFaction` | string | faction tag (optional enforcement for world devices) |
| `CustomDisplayName` | string | display name |
| `EWAntennaHeight`, `EWAntennaGain`, `EWAntennaPattern` | number / number / string | antenna overrides |
| `EWBandwidthKHz`, `EWNetworkId`, `EWSecurityProfile` | number / string / string | channel overrides |
| `EWSerial` | string | persistent identity across destroy/recreate (battery, power) |
| `EWOwnerUserId` | number | owner for world devices |
| `EWPriority` | 1..3 | update priority |
| `EWDeviceRoot` | bool (on an ancestor) | forces that ancestor as the device root |

Map-geometry attributes and tags: `EWMaterial` (string), `EWAttenuationDb` (number) and `EWIgnore`
(bool attribute or tag) go on BaseParts. `EWVegetation` is a tag for foliage models. `EWNoiseZone`
is a tag for volumes that use `NoiseEnvironment` / `ExtraNoiseDb` attributes.

---

## 3. BoolValue registration rules

1. Only a `BoolValue` named exactly **`EWDetectable`** triggers automatic registration.
   * `true`: the device is registered and **eligible** for detection results.
   * `false`: the device stays registered, so its state is preserved and it can still physically
     emit and interfere, but it is **excluded from detection results**
     (`Registry:IsEligibleForDetection`, `RF:GetDetectableEmissions`).
   * BoolValue removed, or no BoolValue at all: the device is not registered, unless the
     `EWDevice` tag or `Registry:RegisterDevice` (API) registers it explicitly.
2. **Root resolution.** The first matching rule, starting at the BoolValue's parent, picks the root:
   1. the nearest ancestor with attribute `EWDeviceRoot = true`
   2. the parent `Tool`, or the nearest `Tool` ancestor, then the nearest worn `Accessory`
   3. the parent `Model` (never Workspace)
   4. a `BasePart`: its parent Model if that Model is not character-like (has no Humanoid), else the part itself
   5. any other container (Folder, Configuration, Attachment): rules 3 and 4 applied to the nearest Model/BasePart ancestor
3. **Several BoolValues under one root.** The root registers once and is detectable if **any** of them is true.
   If a flag exists it overrides the tag and API `Detectable` values, because the map developer's intent wins.
4. **World containers.** A device exists only inside `Workspace` or a player's `Backpack`. A Tool in a
   Backpack is positioned on its carrier. When a device leaves the world (for example to ServerStorage)
   it is unregistered, but its power, battery and emission state are kept. The state is weak-keyed by
   instance, and also kept by `EWSerial` for `PersistSecondsAfterRemoval` (300 s), so a respawned
   radio carrying the same serial resumes its battery.
5. **Event-driven.** Discovery runs one initial `GetDescendants` pass. After that it uses only
   `DescendantAdded` (on Workspace and on each Backpack), `BoolValue.Changed`, `AncestryChanged`,
   `AttributeChanged`, `Destroying` and the CollectionService tag signals. All changes are coalesced
   with `task.defer`, so a reparent (Removing followed by Added) is processed as one update and the
   record and its state survive equip and unequip. Nothing scans the Workspace per frame. A BoolValue
   parented under its default name `Value` and renamed afterwards is re-checked once.
6. **Lifecycle accounting.** Every connection goes through a `ConnectionBag`, and the bags keep a
   global live count. Test L asserts that the count returns to its baseline after
   spawn, equip, unequip, move, destroy and recreate.

### Detection classes (electronic versus transmitting)

| Class | Example profile | Behaviour |
|---|---|---|
| `Communications` | `VHF_FM_VOICE`, `UHF_FM_VOICE`, `MANET_*` | emits only while keyed (PTT) |
| `ActiveTransmitter` | `BEACON_UHF` | continuous low-duty emission |
| `RadarEmitter` | `SEARCH_RADAR_X` | pulsed; average power = peak × duty cycle |
| `DroneLink` | `DRONE_C2_24`, `DRONE_VIDEO_58` | continuous telemetry/video |
| `PassiveElectronic` | `UNINTENTIONAL_EMISSION` | −45 dBm broadband signature; plausible only at short range |
| `ActiveTransmitter` (Jammer) | `JAMMER_BARRAGE_VHF`, `JAMMER_BARRAGE_UHF`, `JAMMER_SPOT` | radiates only when the operator enables emission; game-value power, diluted by band overlap |
| `BackgroundSource` | `BROADBAND_NOISE` | wideband noise (generators, power lines) |

An object with only `EWDetectable = true` becomes `Generic` / `PassiveElectronic` with the weak
unintentional profile. It is eligible for detection, but whether it is actually detected
(Phase 3) still depends on range, terrain, receiver sensitivity and noise.

---

## 4. RF propagation model (link budget)

Implemented in `RFSimulationService.propagate` and `RFMath`.

```
EIRP        = P_tx + G_tx(direction)                                         [dBm]
L_basic     = FSPL(d)                              if d <= d_cross          [dB]
            = max(FSPL(d), PlaneEarth(d, ht, hr))  if d >  d_cross
  FSPL      = 20 log10(d_km) + 20 log10(f_MHz) + 32.45
  PlaneEarth= 40 log10(d_m) - 20 log10(ht_m) - 20 log10(hr_m)
  d_cross   = 4π ht hr / λ
  d         = |rx - tx| · MetersPerStud · RangeScale
L_total     = L_basic + L_excess(terrain/structures/vegetation/water/cavity)
            + L_weather + L_polarization
P_rx        = EIRP + G_rx(-direction) - L_total + F_shadow + F_fast + F_jitter
S_inband    = P_rx - CouplingLoss(frequency/bandwidth overlap)
N           = -174 + 10 log10(B_Hz) + 10 log10(f_a + f_r - 1)               (ITU-R P.372 + receiver NF)
I           = Σ in-band interferer powers (- interference rejection)
SINR        = S_inband - (N ⊕ I)            ⊕ = incoherent power sum
margin      = SINR - RequiredSinr(receiver)
```

* **Effective antenna heights.** The height is the larger of the antenna's height above local ground
  and its height above the mean terrain along the path, with a minimum of 0.5 m. Standing on a
  hilltop therefore reduces the two-ray loss, and standing in a valley does not. Under a roof or water
  surface, the floor below is found with one extra ray.
* **Antenna patterns.** `Omni` is a dipole-like doughnut (`sin²` of the angle from the element axis)
  with a configurable null floor, so a drone straight overhead sits in the null. `Directional` uses a
  parabolic main lobe `12(θ/θ3dB)²` capped at the front-to-back ratio.
* **Polarization.** Each element axis is projected onto the plane perpendicular to the propagation
  direction. Loss is `-20 log10|cos ψ|`, capped at 20 dB. Circular↔linear loses 3 dB. Without an
  `EWAntenna` attachment the antenna is assumed upright, so random tool rotations do not create
  polarization loss.
* **Noise.** ITU-R P.372 man-made noise categories (`City`, `Residential`, `Rural`, `QuietRural`)
  are combined with galactic noise. A storm raises atmospheric noise mostly at low VHF.
  `EWNoiseZone` volumes give local overrides.
* **Fading** (disabled by `Deterministic` for tests):
  * *Shadowing.* Spatially correlated, deterministic, unit-variance Gaussian value noise
    (decorrelation 60 studs). Its σ depends on the obstruction class (1.5 to 7 dB).
    The same place always gives the same value.
  * *Small-scale.* Rician power gain built from two Ornstein–Uhlenbeck Gaussian components.
    The K-factor depends on the class (12 for line of sight, down to 0, which is Rayleigh). The time
    constant is the Doppler coherence time `0.423/f_d` with `f_d = v_rel/λ`, so moving fast at
    high frequency gives fast fades and stationary links barely change.
  * *Equipment jitter.* `(1 - Stability) × 3 dB` Gaussian.
* **Weather.** ITU-R P.838-3 rain coefficients, interpolated. Rain is negligible below about 2 GHz,
  so ordinary rain does not affect VHF/UHF voice but does affect 5.8 GHz video. Wet snow is counted
  as half the equivalent rain. Fog follows a rough f² liquid-water fit above 3 GHz.

### Scale

* `MetersPerStud = 0.28` (Roblox avatar scale) is used for all geometry: heights, wall thickness,
  Fresnel zones and diffraction.
* `RangeScale = 3.0` (default) multiplies **only the distance term** of the basic loss. It is a
  declared map-compression assumption: with 1.0, a 4,000-stud map is only about 1.1 km, and 5 W
  VHF/UHF radios would work almost everywhere that is not deeply obstructed, as they do in real life
  at that distance. With 3.0, ridges, distance and power level matter on typical map sizes. Terrain
  shape always uses true geometry. Both values can be set per place through attributes.

---

## 5. Terrain interference model (TerrainPropagationService)

### Stage 1 — `AnalyzePath(a, b)` → `PathGeometry` (frequency-independent, cached)

1. **Height field.** A downward `Workspace:Raycast` probe, cached per 8-stud cell, returns the top
   *static* surface: Terrain, or anchored and significant BaseParts. Probes skip water (it is recorded
   separately), dynamic parts, foliage and ignored parts. Up to 72 samples are taken along the path.
2. **Terrain mass under the line of sight.** At every sample where the LOS is below the surface,
   `Terrain:ReadVoxels` reads the voxel at the LOS point:
   * solid voxel: terrain penetration length per material
   * water voxel: water path length
   * air voxel: **cavity**. This covers tunnels, caves and arches under terrain, and rooms under a
     roof. Such samples are excluded from diffraction edges because the LOS is open there.
     Terrain-covered air also accumulates cavity length.
3. **Structures.** A center ray runs from A to B, excluding Terrain, characters, foliage, the endpoint
   devices and `EWIgnore` parts. For each significant hit:
   * The exit point comes from a **reverse include-filtered ray** fired from beyond the part, which
     gives the true thickness.
   * MeshParts and Unions get an extra **forward include ray** to find inner cavities, so a hollow
     union building is not treated as solid.
   * The trace continues past the exit, so **multiple walls accumulate**.
   * Insignificant parts are skipped: invisible ones, parts with no side ≥ 2.5 studs or volume
     < 0.6 stud³, character parts and accessories, and `CanCollide = false` parts unless they are
     given `EWMaterial`.
   * Obstacles on the center ray also become explicit diffraction-profile points, using the top of
     their bounding box, so a thin tall wall between samples is never missed.
4. **Fresnel spindle sub-paths.** This is bounded multi-ray sampling. Two to four extra paths run
   A→M→B, where M is the midpoint offset by 0.6 × the first-Fresnel radius (capped at 14 studs).
   Each path is traced with the same obstacle tracer, which detects partial obstruction by building
   edges near the path.
5. **Vegetation.** An include-filtered ray through `EWVegetation`-tagged foliage, plus
   `LeafyGrass`/`Grass` parts found by the structure tracer, gives the foliage depth.
6. **Endpoints.** Ground (or water surface) under each endpoint, the floor under covered endpoints,
   and depth below the water surface for submerged endpoints (verified with a voxel read).

### Stage 2 — `ComputeLosses(geometry, f)` → `PropagationLosses` (cheap, per frequency)

| Component | Model |
|---|---|
| Diffraction | Deygout (principal edge plus one secondary edge on each side, weighted by `T = 1 - e^(-J(vp)/6)`) using the ITU-R P.526 `J(v) = 6.9 + 20 log10(√((v-0.1)²+1) + v - 0.1)`. Earth bulge uses k = 4/3. Reported as **excess over a smooth baseline profile** (the straight line between the terminal ground points), because the plane-earth basic loss already accounts for smooth ground. Flat ground adds 0 dB. |
| Terrain penetration | Σ length × material dB/m × (f/100 MHz)^0.35. Moist soil is about 4 dB/m, rock 2, sand 1.5, snow 0.3, ice 0.15. Capped at 160 dB. |
| Structures | Per obstacle `(Entry + dB/m · t) · (f/1 GHz)^exp`, capped. Center ray and spindles are combined by a **power average** (center weight 2). |
| Vegetation | Weissberger, capped at 30 dB because a lower-loss path around foliage always exists (ITU-R P.833 guidance). |
| Water | Interface loss plus fresh-water dB/m. Applies on the path and at submerged endpoints. |
| Cavity | `0.08 dB/m × (f/300 MHz)^-1.5`. Low VHF is below the waveguide cutoff of a typical tunnel and dies quickly; UHF and above travel along straight tunnels. |

**Combining the paths.** This decides what happens when the direct ray is blocked:

* Direct ray clear: `excess = diffraction + structures + vegetation + cavity + submerged-endpoint`.
  J(v) already describes Fresnel intrusion, so no separate "through" path is needed.
* Direct ray blocked, with a real diffraction edge: the over-the-top path
  (`diffraction + obstacles within 40 studs of an endpoint + ...`) and the through path
  (`terrain + structures + vegetation + water + ...`) are combined as **incoherent alternative
  paths**, `-10 log10(10^(-L1/10) + 10^(-L2/10))`. The lower-loss path dominates: a signal goes
  *over* a mountain rather than through it, but *through* a thin wall rather than over a tall building.
* Direct ray blocked with no real edge: the smaller of the two, so the same physical path is never
  counted twice.

**Classification** (`Unobstructed · PartiallyObstructed · Obstructed · HeavilyObstructed`) uses
line-of-sight status and the excess-loss thresholds 1.5, 8 and 25 dB.

**Explanations.** Each result carries plain-language lines, for example
*"Terrain edge 712 studs from A rises 38.2 studs above the line of sight (v=3.10): 24.1 dB
diffraction over 3 edge(s)"*, *"Direct ray penetrates 2 obstacle(s): Concrete 2.0 studs (15.0 dB), …"*,
*"Over-the-top path 24.1 dB vs through path 160.0 dB → excess 24.1 dB (OverTheTop, Obstructed)"*.

### Caching and invalidation

* **Path cache.** The key is the pair of endpoints quantized to 2 studs, stored symmetric (A↔B
  share an entry). Entries have an 8 s TTL and a region-revision stamp: the sum of revisions of the
  256-stud cells the path crosses. Editing one area invalidates only the paths through it.
* **Height cache.** Cleared by region on `NotifyTerrainChanged` / `InvalidateRegion`, automatically
  when large anchored parts (side ≥ 8 studs) are added or removed, and fully every 300 s
  (`HeightCacheMaxAgeSeconds`) so un-notified edits heal themselves.
* **Budgets.** A non-forced analysis that cannot afford its rays reuses stale geometry, or
  interpolates cached profile cells (marked `Approximate`), or defers. Watched links retry within
  50 ms, and the last authoritative result is kept rather than replaced by an invented one.

---

## 6. Signal compatibility interface

`SignalCompatibility.Evaluate(emitter, receiver)` → `CompatibilityResult` keeps three questions separate:

1. **Energy.** `OverlapFraction` is the share of emitter power inside the receiver passband.
   `CouplingLossDb = -10 log10(overlap)`. Outside the passband, adjacent-channel leakage is
   `ACR (60 dB) - 10 log10(Brx/Btx)` within three receiver bandwidths; beyond that, nothing couples.
   A barrage emitter spread over 10 MHz therefore delivers about 26 dB less power into a 25 kHz
   receiver than a spot emitter. This dilution follows from the overlap math rather than a special case.
2. **Demodulation.** The modulation family must match (FM↔FM, AM↔AM or CW, ...).
3. **Authorization** (simulated). The network ids must match, or one side is nil. Security profiles:
   `PT` reaches PT and CT receivers; `CT:<key>` reaches only the same key. No cryptography is
   performed; the server compares strings it owns.

`Intelligible = in-band ∧ overlap ≥ 0.5 ∧ modulation ∧ network ∧ security ∧ receiver enabled`.
Energy always counts toward **interference**, even when traffic is unintelligible.

---

## 7. Server update scheduler (EWScheduler)

* A single `RunService.Heartbeat` loop. Jobs declare an interval and a priority, and run in priority
  order while the per-frame time budget lasts. Essential jobs (battery) always run. Each job is
  wrapped in `pcall` and a MicroProfiler label `EW:<job>`.
* Per-frame **raycast and voxel budgets** are reset every frame. Forced, on-demand work (tests,
  future PTT events) is still counted.
* **Jobs.**
  * `PowerTick` (1 s, essential).
  * `DevicePoses`, adaptive: moving or emitting devices are refreshed every 0.2 s, idle devices back
    off to 2 s.
  * `LinkEvaluation`, every frame within budget: priority intervals of 0.2, 0.5 and 2 s, and
    immediately when an endpoint moves more than 3 studs.
  * `EmissionAudit` (2 s), `PropagationCacheMaintenance` (5 s), `RegistryMaintenance` (10 s),
    `DiagnosticsPublish` (1 s), and `ProfileCheck` (10 s).
* **Performance profiles.**

| Profile | Frame budget | Rays/frame | Voxels/frame | Spindles | Max samples | Detailed interferers | Link interval × |
|---|---|---|---|---|---|---|---|
| Development | 4.0 ms | 400 | 200 | 4 | 72 | 6 | 1.0 |
| Normal | 2.5 ms | 160 | 96 | 2 | 56 | 4 | 1.0 |
| HighPopulation | 1.6 ms | 90 | 48 | 0 | 40 | 2 | 1.6 |

`Auto` picks Development in Studio, Normal on live servers, and HighPopulation at 40 or more players
(re-checked every 10 s).

---

## 8. Diagnostics and testing plan

### Diagnostics (developers only)

* **Who counts as a developer:** Studio users, the place creator or group owner, an explicit
  allowlist, or a group rank. The server sets the `EWDeveloper` player attribute for the UI, but
  re-checks every request.
* **Panel tabs (F6, or the "EW" button).**
  * Devices: power, battery, detectability, sources.
  * Links: SINR, noise, interference, every loss term, class, dominant path, reasons and
    plain-language explanation.
  * Perf: job costs, raycasts and voxel reads per second, cache hit rate, budget denials, security
    rejections, registry counters including live connections.
  * Log: server log and streamed test output.
* **Streaming.** A 1 Hz delta stream: only changed device rows are sent, with a full refresh every 10 s.
* **Debug paths.** Signal paths, obstacle entry points and the principal diffraction edge are drawn
  **locally** under `workspace.CurrentCamera` on the developer's client only. Nothing is placed in the
  shared Workspace. They are Studio-only by default.

### Test plan (EWTestRunner, on the real test range)

| Test | What is proven |
|---|---|
| A | A BoolValue-only Model registers with the Generic/passive defaults. Toggling false removes it from detection; removing the BoolValue unregisters it. Part-root, Tool-root and rename cases are covered. |
| L | Spawn, container moves, equip/unequip (when a player is present), destroy/recreate by serial, BoolValue root migration. Device count and **live connection count** return to baseline. |
| B | Same 1,400-stud distance, open lane versus ridge lane, at VHF, UHF and L-band: at least 15 dB more excess loss and 15 dB worse SINR behind the ridge, correct classification, and the crest restores the link. |
| TC | The **reproducible terrain test**. `Terrain:FillBlock` adds an 80-stud berm and the link degrades by at least 8 dB; filling it with Air restores the link to within 1 dB. |
| C | Open < wood hut < concrete bunker, and a metal container far above wood, at three bands. |
| E | A mobile station moves open → behind ridge → crest → open, using **scheduler-driven** watched-link updates (no forced evaluation, no regions). The link degrades by at least 15 dB, recovers on the crest, and returns to the start value within 2 dB. |
| H | An airborne station clears the ridge (at least 15 dB better), but altitude cannot reach a receiver deep in a tunnel. |
| U | An off-axis tunnel receiver is heavily degraded; low VHF cannot escape a straight tunnel; a submerged antenna loses at least 8 dB; foliage attenuates. |
| G | A co-channel emitter cuts SINR by at least 10 dB, an emitter 10 MHz away has no effect, and the receiver stays powered (degradation, not destruction). |
| F | Detectable versus deactivated versus `EWDetectable = false` (still emitting, not detectable). |
| I | Transmit draw exceeds idle draw; an empty battery means Depleted and Offline; power-on is refused; battery swap → boot → link restored. |
| J | Payload schema rejections, rate-limit burst, ownership and range refusals. The client-side remote abuse script is in the guide. |
| M | EW backpack: a UHF barrage degrades a UHF link by at least 10 dB while a VHF barrage leaves it unchanged, the jammed radio stays powered, and radiating draws heavy power. Menu commands (Power, Emission, Mode, battery swap) succeed for a nearby player, and unauthorized or malformed requests are refused. |
| K | 60 moving devices, 40 watched links and 6 active emitters for 10 s. Reports frame cost, rays per frame against budget, evaluations and job costs. |
