# Research Notes — EW concepts, PRC-163 reference, and gaps in the brief

All sources below are public. Nothing classified, export-controlled, or operational (real jamming
settings, waveforms, cryptography) is used or needed.

## 1. AN/PRC-163 — public datasheet facts (L3Harris L26821, 08/2024, marked non-export-controlled)

| Item | Public value | Used for |
|---|---|---|
| R/T 1 bands | VHF-low 30–88 MHz, VHF-high 118–174 MHz, UHF 225–512 MHz; SATCOM 300–320 UL / 360–380 DL; UHF SATCOM 291–318.3 UL / 243–270 DL | profile ranges (Phase 2 RadioDefinitions) |
| R/T 2 bands | UHF 225–450 MHz, L/S-band 1300–2600 MHz | MANET L-band profile |
| Channel bandwidth | R/T 1: 5 kHz–10 MHz; R/T 2: 5 kHz–40 MHz | bandwidth limits |
| Net presets | 99 standard; function knob "FP and 15 presets" (Off / Load / Z / Volume / Mechanical interlock) | preset system, zeroize position |
| TX power | 250 mW – 5 W LOS, 10 W SATCOM, 3.2 W L/S-band | `PowerLevelsDbm` LOW 24 / MED 30 / HIGH 37 dBm |
| Sensitivity | −116 dBm (36.5–52 MHz), −114 dBm (146–426 MHz), 12 dB SINAD | `SensitivityDbm`; NF + RequiredSinr chosen to reproduce it |
| Tuning / stability | 10 Hz steps, 0.5 ppm | Phase 2 frequency entry |
| GPS | built-in, SAASM L1/L2 or commercial L1 | MGRS display; GNSS jamming hook |
| Key fill | DS-101 | simulated key slots / KEY field |
| Battery | 7.0 Ah Li-ion; 9.6–34.3 VDC input | battery model (game-scaled) |
| Waveform families | Ch1: VHF/UHF LOS, ANW2C, SINCGARS, P25 (+ options incl. HAVEQUICK, IW SATCOM); Ch2: ANW2C, UHF LOS, UHF SATCOM (+ TSM-X, L-TAC, ...) | named only as game "families"; no waveform is reproduced |
| Crossbanding | simultaneous voice/data across SATCOM, LOS and MANET | `XB` field, Phase 2 bridging |

### Screen and keypad specification taken from your reference images

```
┌──────────────────────────────────────────────────────────────┐
│ XB:OFF               17:25:03                     [■■■■■▯]  │ status bar: crossband · time · battery
│ ┌VULOS      CT┐ ╱╱VULOS╱╱CT╱╱ ╱╱╱╱╱MM╱╱╱╱╱                    │ tabs: R/T1 · R/T2 (hatched = not selected) · MM
│ │ R  VOL ▇▇▇▇▇▇   VULOS     TON     VINSON                   │ R = active R/T, volume bar, waveform, squelch, COMSEC
│ │ R:  142.50000                         TX [         ]       │ frequency view: RX / TX MHz, TX activity bar
│ │ T:  142.50000                             ---              │
│ │          FREQUENCY                        CHAN             │
│ └──────────────────────────────────────────────────────────┘ │
│ [      ] [  18S        MGRS-NEW   ] [      ]                │ soft keys · GPS (zone, datum) · soft key / RSSI
│          [  UJ 43773E 39055N      ]                         │ grid square, easting, northing
└──────────────────────── AN/PRC-163 ─────────────────────────┘
```

* **Preset view.** A large `01-AMVOICE` (preset number and name), then a value row
  `LOS · VOC · AM · --- · 01` with labels `TYPE · TRF · MOD · CHAN · KEY`.
* **SATCOM view.** `02-SATCOM-A` with a sync/refresh glyph and a TX box. Values
  `SAT · VOC · MED · PT · --:--` with labels `TYPE · TRF · PWR · SEC · KEY`. The right soft key shows
  signal bars with a count (`02`). Squelch shows `NOI` and COMSEC shows `NONE`.
* **Program menu.** Header `XB:--`, tab `PROGRAM 1:-- 2:--`, tab `MM:--`. List: `PGM-CONFIG`,
  `SYSTEM PRESETS` (inverse-video highlight), `SA BLACK CONFIG`, `SA RED CONFIG`, with a scrollbar.
  Both side soft keys read `PGM`.
* **Keypad (4 × 5).**
  * Row 1: `1 ABC/CALL`, `2 DEF/LT`, `3 GHI/MODE`, `CLR` (red)
  * Row 2: `4 JKL/SQL`, `5 MNO/ZERO`, `6 PQR/▲`, `ENT` (green)
  * Row 3: `7 STU/OPT`, `8 VWX/PGM`, `9 YZ?/▼`, `+ PRE −` rocker
  * Row 4: `0/○`, `◀`, `▶`
  * The 3D model shows hover tooltips such as "Go back" on the keys.
* **Look.**
  * Lime LCD (about `#8FD400` in the flat screenshots, about `#A8C83A` on the 3D model).
  * Black monospace / pixel font; hatching on inactive tabs; black-filled volume bar.
  * The screen sits in a dark bezel with the white bold-italic `AN/PRC-163` label (flat UI) or the
    `FALCON IV` molded label (3D model).
* **Field meanings.**
  * `CT`/`PT` = cipher or plain text.
  * `VINSON` = a simulated COMSEC mode label; `TON`/`NOI` = tone or noise squelch.
  * `TRF` = traffic (VOC/DAT); `MM` = mission module tab.
  * `SA BLACK/RED` = situational-awareness (PLI) configuration.

## 2. Your Interaction Menu (decoded from `mi_1.0.rbxm`, now rebuilt as `EWInteractionMenu`)

The rebuilt menu drops the Breach module and the tag requirement, and copies the original layout
values: BillboardGui 20×20 studs, AlwaysOnTop, MaxDistance 100; Main 0.1×0.02 with dot 0.09
(RelativeXX); red selector ring 2× rotating at 110°/s; title at X 5.464, stroke 0.7, max text size
15; Section list at X 0.65 and third column at X 0.77; click sound 6324790483 at volume 0.1.
The original analysis follows.


* Hold **LeftAlt** (or **R3**) to show menus for Attachments tagged `INTERACT_MENU` within the
  module's `Settings.Distance`. Attachment attributes: `Text`, `Module`, `Folder`.
* Module contract: `Settings`, `Add(layer, attachment)`, `Check`, `Folder`, `Grab`, `First`,
  `Second`, `Third`, and optionally `Special`.
* **Pitfall 1.** Tables returned from `Add()` must provide `Order` and `Image`, or a `GetAttribute`
  method, because the Controller falls back to `info:GetAttribute(...)` on tables. `EWDevice`
  includes the method.
* **Pitfall 2.** The included `Breach` module waits forever for `ReplicatedStorage["Combat Breaching"]`
  at require time. If that folder is missing, the Controller never finishes loading.

## 3. EW concepts the brief does not cover (recommended additions)

| Concept | Why it matters for gameplay | Phase |
|---|---|---|
| **Emission control (EMCON) and emitter signature** | Every transmission is a detection opportunity. Short transmissions, low power and directional antennas reduce exposure. Low power is a real PRC-163 setting (0.25 W vs 5 W) and changes the link budget by 13 dB. | 2–3 |
| **Friendly-jamming fratricide and spectrum deconfliction (JRFL: taboo / protected / guarded frequencies)** | A friendly jammer degrades friendly radios on the same band. Jammer profiles should carry a protected-frequency list and a "look-through" duty cycle. | 4 |
| **Electronic protection (EP)** | Frequency hopping, spread spectrum and processing gain (`InterferenceRejectionDb` already exists), burst transmission, terrain masking, directional antennas. | 2, 4 |
| **J/S, parity distance and burn-through** | For one-way communications jamming, a link "burns through" when the wanted signal exceeds the jammer at the receiver. This falls out of the shared SINR model; no special code is needed. | 4 |
| **Barrage vs spot vs follower/reactive jamming** | Barrage spreads power over bandwidth: 10 MHz into 25 kHz is −26 dB, which the overlap model already captures. Reactive jammers key only when they detect a signal. | 4 |
| **PNT warfare (GNSS jamming and spoofing)** | The PRC-163 shows GPS/MGRS. Jammed GPS should degrade the displayed position and PLI and the drones' navigation. Hopping radios also depend on time-of-day sync. | 2, 4, 5 |
| **COMSEC fill and zeroize** | Key slots (the KEY field), a fill device, the `ZERO` key and the knob `Z` position. A captured radio that was not zeroized compromises its net. Simulated only. | 2 |
| **Direction finding: line of bearing → cut → fix, error ellipse** | Two bearings give a cut; three or more give a fix with confidence. Bearings near buildings and terrain suffer multipath error. TDOA needs synchronized sensors. | 3 |
| **Counter-targeting** | A located emitter can be targeted, so moving after transmitting matters. Provide fix reports to fire support. | 3+ |
| **Retransmission / relays** | Hilltop and airborne relays fix terrain-blocked links (Test H already shows the propagation side). | 5 |
| **Readability/strength scale ("loud and clear")** | Radio checks are reported 1–5. `QualityResult.Readability` and `Strength` are already provided. | 2 |
| **Electronic deception / decoys** | Decoy emitters with plausible signatures, to mislead ES operators. | 3–6 |
| **Fiber-optic and RF-silent drones** | Recent conflicts show wire-guided FPVs are immune to RF jamming and detection, which is a useful counterpoint to jammers. | 5–6 |
| **Cold-weather battery capacity** | Li-ion capacity drops in the cold. Use a weather-adapter hook into the battery model. | 6 |

## 4. Propagation and noise references used

* **ITU-R P.526** (diffraction): J(v) knife-edge approximation; Deygout multiple-edge construction.
  The NTIA comparison (TR-26-580) notes that Bullington is too optimistic and that Deygout is the
  common practical choice.
* **ITU-R P.372** (radio noise): man-made noise curves `Fam = c − d·log10(f)` for City, Residential,
  Rural and Quiet Rural, plus galactic noise.
* **ITU-R P.833** (vegetation): specific attenuation with a maximum cap, because a lower-loss path
  around vegetation exists.
* **Weissberger** modified exponential decay model (foliage).
* **ITU-R P.838-3** (rain specific attenuation coefficients).
* **ITU-R P.2109** (building entry loss) informed the qualitative ordering. Modern
  thermally-efficient buildings attenuate far more than traditional ones, which can be expressed
  with `EWMaterial`.
* **Two-ray / plane-earth model** for communications jamming geometry:
  `L = 120 + 40 log10(d_km) − 20 log10(ht) − 20 log10(hr)`, including the J/S and parity-distance
  formulation.

## 5. Sources

* [AN/PRC-163 datasheet (L3Harris, via ZSIS)](https://www.zsis.hr/UserDocsImages/Sigurnost/pdfs/AN_PRC-163.pdf)
* [AN/PRC-163 application handbook (L3Harris)](https://www.l3harris.com/sites/default/files/2024-05/l3harris-prc-163-multichannel-handheld-radio-application-handbook-cs-tcom.pdf)
* [AN/PRC-163 — Wikipedia](https://en.wikipedia.org/wiki/AN/PRC-163)
* [Falcon IV family radios (L3Harris)](https://www.l3harris.com/all-capabilities/falcon-iv-family-radios)
* [Soldier communications: rugged, capable and interoperable (ESD, 2023)](https://euro-sd.com/2023/06/articles/31815/soldier-communications-rugged-capable-and-interoperable/)
* [Electronic warfare specialists train on VROD systems (army.mil)](https://www.army.mil/article/193810/electronic_warfare_specialists_train_on_vrod_systems)
* [Army modernizing electronic warfare capabilities (GlobalSecurity / ARNEWS)](https://www.globalsecurity.org/military/library/news/2019/02/mil-190213-arnews01.htm)
* [Outmatched Army begins long road to EW rollout (Defense News)](https://www.defensenews.com/electronic-warfare/2017/10/02/outmatched-army-begins-long-road-to-electronic-warfare-rollout/)
* [Jamming efficacy of communications links (JED)](https://www.jedonline.com/2022/08/17/jamming-efficacy-of-communications-links/)
* [Radar basics — electronic warfare (radartutorial.eu)](https://www.radartutorial.eu/16.eccm/ja11.en.html)
* [Jamming-to-signal ratio (RF Cafe EW handbook)](https://rfcafe.com/references/electrical/ew-radar-handbook/jamming-to-signal-ratio-constant-power.htm)
* [ITU-R P.526 overview (EDX wireless KB)](https://edxwireless.atlassian.net/wiki/spaces/EWKB/pages/1933549/ITU-R+P.526)
* [NTIA TR-26-580 multiple knife-edge diffraction comparison](https://www.its.ntia.gov/publications/download/TR-26-580.pdf)
* [ITU-R P.833-2 (vegetation)](https://itu.int/dms_pubrec/itu-r/rec/p/R-REC-P.833-2-199910-S!!PDF-E.pdf)
* [ITU-R Report P.2346 (building entry loss measurements)](https://www.itu.int/dms_pub/itu-r/opb/rep/R-REP-P.2346-6-2026-PDF-E.pdf)
