# Phase 2 — AN/PRC-163 radio

Phase 2 adds a dual-channel AN/PRC-163 radio on top of the Phase 1 RF engine. Players carry it as a
Tool, program it from a front panel, and send **text traffic**. Every message goes through the same
link evaluation as Phase 1, so terrain, buildings, power level, squelch, COMSEC keys and jamming all
decide what arrives. Voice is planned for later and will reuse the same delivery decisions.

## 1. Pieces

| File | Role |
|---|---|
| `ReplicatedStorage/EWShared/RadioDefinitions.luau` | Bands per R/T, power levels, squelch modes, key slots, default preset plan |
| `ReplicatedStorage/EWShared/DeviceDefinitions.luau` | `PRC163` device definition (Communications, 88 Wh battery, 3 s boot) |
| `ReplicatedStorage/EWShared/EWRemotes.luau` | `RadioCommand`, `RadioState`, `RadioTraffic` |
| `ServerScriptService/EWServer/Services/RadioService.luau` | Radio state, programming, PTT, text delivery |
| `ServerScriptService/EWServer/Services/ElectronicDeviceRegistry.luau` | New `AddConfigurationExtender` hook (the radio uses it for its two channels) |
| `ServerScriptService/EWServer/EWGearIssue.server.luau` | Pickup station that issues the radio Tool |
| `StarterPlayerScripts/EWRadio/` | `RadioScreen` (panel UI) and `RadioController` (input, remotes) |
| `ServerScriptService/EWServer/Tests/EWRadioTests.luau` | Tests R1–R7, run after the Phase 1 suite |

## 2. Setup in a place

1. **Tool template.** Build a Tool named `AN/PRC-163` in `ServerStorage.EWGear`:
   * An upright `Handle` part holding an `EWDetectable` BoolValue (true) and an `EWAntenna`
     Attachment at the antenna tip.
   * The radio meshes welded to the Handle with `WeldConstraint`s, set unanchored, massless and
     non-collidable.
   * Tool attributes `ElectronicType = "PRC163"` and `CustomDisplayName = "AN/PRC-163"`.
2. **Pickup station.** Give any display model in Workspace the attribute
   `EWIssueTool = "AN/PRC-163"`. Its prompt gives each player one copy, with
   `EWSerial = "AN/PRC-163:<UserId>"`, so the radio's battery, programming and keys follow that player
   across respawns.
3. **Any other radio.** A Model or Tool with `EWDetectable` and `ElectronicType = "PRC163"` is a radio.
   An uncarried radio works as a loudspeaker for players within 8 studs.

## 3. The radio

| Channel | Bands (MHz) | Waveform label → profile |
|---|---|---|
| R/T 1 | 30–88 (FM), 118–174 (AM), 225–512 (FM) | VULOS → `VHF_FM_VOICE` / `VHF_AM_VOICE` / `UHF_FM_VOICE` |
| R/T 2 | 225–450 (FM), 1300–2600 (data) | UHF LOS → `UHF_FM_VOICE`, ANW2C → `MANET_DATA_LBAND` |

* **Function knob:** `OFF` · `Z` (zeroize) · `LOAD` (refill keys from the carrier's team fill) · `FP`
  (front-panel tuning) · `01`–`15` (presets).
* **Power:** LOW 0.25 W / MED 1 W / HIGH 5 W (3.2 W maximum on L/S-band). LOW costs 13 dB of link
  margin.
* **Squelch:**
  * `NOI` hides traffic with no usable signal.
  * `TON` also requires the same net (preset).
  * `OFF` shows noise and fragments.
* **COMSEC:** `PT` (plain), or `CT` with key slot 01–06. Keys are simulated IDs (`FILL:<team>:<slot>`).
  * A zeroized radio hears CT traffic only as `[ENCRYPTED TRAFFIC]` and cannot transmit on CT.
  * A captured radio that was not zeroized keeps its keys.
* **Default presets:**
  * 01 AMVOICE 142.5, 02 PLT-NET 45.0, 03 CO-NET 52.25, 04 BN-CMD 300.0, 05 FIRES 38.5
  * 06 MEDEVAC 52.9, 07 AIR-GND 251.0, 08 GUARD 243.0, 09 MANET-1 1350 (R/T 2), 10 UHF-LOS 310 (R/T 2)
  * 11 SQD-1, 12 SQD-2, 13 EOD-NET, 14 HARBOR 156.8, 15 MANET-2 1820 (R/T 2)

### Front panel (equip the Tool)

| Control | Action |
|---|---|
| Knob ◀ ▶ | Turn the function knob (turning to Z asks for confirmation) |
| Digits, then ENT | Knob on FP: type a frequency. ▶ = decimal point, ◀ = backspace, CLR = cancel |
| ◀ ▶ (no entry) | Select R/T 1 or R/T 2 |
| PRE + / − | Next or previous preset on the selected R/T |
| 1 CALL | Send "RADIO CHECK, OVER" |
| 2 LT | Toggle the backlight |
| 3 MODE | Cycle power LOW / MED / HIGH |
| 4 SQL | Cycle squelch NOI / TON / OFF |
| 5 ZERO | Zeroize (press twice) |
| 6 ▲ / 9 ▼ | Volume up / down |
| 7 OPT | Switch COMSEC between PT and CT |
| 8 PGM | List the presets on the selected R/T |
| PTT button or hold Caps Lock | Key the selected R/T (carrier only for now) |
| Message box + Enter | Send a text burst on the selected R/T |

Received traffic appears in a feed next to the panel, including while the radio is in the Backpack.
Each line shows the R/T, preset, frequency, sender and readability/strength (`5/5`).

## 4. Delivery rules

For each other powered PRC-163 tuned within the channel bandwidth, the server runs
`RF:EvaluateLink(tx, rx, {EmitterIndex, ReceiverIndex, IncludeInterference})`:

| Link quality | Shown |
|---|---|
| Clear / Good | The message as sent |
| Degraded | Characters lost at the link's PacketLoss |
| Broken | Heavy loss |
| Unusable | `[UNREADABLE]`, only with squelch OFF |
| NoSignal / off frequency | Nothing |
| Key mismatch | `[ENCRYPTED TRAFFIC]` |

## 5. Security

* `RadioCommand` is rate limited (12 burst, 4/s) and schema checked.
* Programming requires `CanControlDevice`.
* PTT and Text also require that the player carries the radio.
* Text is limited to 120 characters, 3 messages back to back and then one every 2 s.
* Text is filtered with `TextService` before anyone receives it.
* A held PTT unkeys after 30 s.

## 6. Tests (Studio, Play)

`game.ServerScriptService.EWServer:SetAttribute("EW_RunTests", true)` runs Phase 1 followed by:

| Test | Checks |
|---|---|
| R1 | Registration: two emitters and two receivers, default presets |
| R2 | Programming: band limits, 10 Hz quantization, knob/preset rules, schema rejections |
| R3 | Text traffic: open lane delivers intact (5/4), ridge blocks, other frequency hears nothing |
| R4 | COMSEC: zeroize gives encrypted-only reception, PT still readable, LOAD restores |
| R5 | Power: LOW vs HIGH = 13.0 dB |
| R6 | Jamming: a VHF barrage next to the receiver stops delivery |
| R7 | PTT: keyed R/T is an active emission, R/T 2 stays silent, stuck-key timeout |

First Studio run: R1–R7 all passed.

## 7. Not in this phase yet

* Voice (AudioDeviceInput / VoiceChat routing).
* SATCOM (needs a satellite model).
* Crossband bridging (the XB flag is stored and shown only).
* A full PGM menu.
* MANET routing and relays (Phase 5).
* GPS jamming of the MGRS display.

`build/*.rbxmx` has not been regenerated for Phase 2. Use Rojo (`default.project.json` now includes
`EWRadio`), or run `python3 tools/build_rbxmx.py`.
