# EW — Electronic Warfare & Tactical Communications Simulation (Roblox / Luau)

A server-authoritative electromagnetic environment for a military Roblox experience. Radios,
jammers, sensors, drones and relays all share one RF engine. In that engine, **real Terrain and map
geometry** (ridges, valleys, buildings, foliage, tunnels, water) decide whether signals get through.

**Status: Phase 1 (core simulation) implemented.** Phases 2 (AN/PRC-163), 3 (electronic support and
direction finding), 4 (jammer), 5 (MQ-1C and relays) and 6 (advanced) build on it.

| Read | For |
|---|---|
| [docs/PHASE1_ARCHITECTURE.md](docs/PHASE1_ARCHITECTURE.md) | architecture, data schema, BoolValue rules, RF and terrain models, compatibility, scheduler, test plan |
| [docs/PHASE1_GUIDE.md](docs/PHASE1_GUIDE.md) | installation (Rojo or prebuilt `.rbxmx`), map integration, remote contracts, config, Studio tests, expected results, limitations |
| [docs/RESEARCH_NOTES.md](docs/RESEARCH_NOTES.md) | PRC-163 public datasheet facts, screen/keypad spec from the reference images, Interaction Menu notes, EW gaps in the brief, sources |

## Quick start

1. Insert `build/EWShared.rbxmx` into **ReplicatedStorage**, `build/EWServer.rbxmx` into
   **ServerScriptService**, and `build/EWClient.rbxmx` plus `build/EWInteractionMenu.rbxmx` into
   **StarterPlayer › StarterPlayerScripts**. Alternatively, `rojo serve default.project.json`.
   Remove the old Interaction Menu model; `EWInteractionMenu` replaces it for EW gear.
2. Make anything electronic by adding a `BoolValue` named **`EWDetectable`** (true). For the EW
   backpack, also set `ElectronicType = "Jammer"` on the pack.
3. Press Play, then run the test suite:
   `game.ServerScriptService.EWServer:SetAttribute("EW_RunTests", true)`. You can also press **F6**
   and choose **Run Tests**.

## Layout

```
src/ReplicatedStorage/EWShared/        shared types, config, RF math, profiles, materials, remotes
src/ServerScriptService/EWServer/      bootstrap, services, Studio test range + runner
src/StarterPlayerScripts/EWClient/     client controller, developer diagnostics UI, debug path renderer
src/StarterPlayerScripts/EWInteractionMenu/  EW interaction menu (hold Left Alt near EW gear)
build/                                 generated .rbxmx models (python3 tools/build_rbxmx.py)
tools/                                 rbxmx builder
```
