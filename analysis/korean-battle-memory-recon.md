# Korean Battle Memory Recon

## Goal

Map Korean Pokemon HeartGold battle memory using the Korean ROM as the primary target, while using the US decomp source as a semantic reference.

Target ROM:

- `/Users/baekcg/Documents/Projects/Poke-Speech/포켓몬스터 하트골드(K).nds`

Relevant source references:

- [src/launch_application.c](/Users/baekcg/Documents/Projects/pokeheartgold/src/launch_application.c#L180)
- [src/battle/battle_system.c](/Users/baekcg/Documents/Projects/pokeheartgold/src/battle/battle_system.c#L60)
- [include/battle/battle.h](/Users/baekcg/Documents/Projects/pokeheartgold/include/battle/battle.h#L207)
- [include/battle/battle.h](/Users/baekcg/Documents/Projects/pokeheartgold/include/battle/battle.h#L279)
- [src/battle/battle_command.c](/Users/baekcg/Documents/Projects/pokeheartgold/src/battle/battle_command.c#L48)
- [src/battle/battle_command.c](/Users/baekcg/Documents/Projects/pokeheartgold/src/battle/battle_command.c#L744)
- [src/battle/battle_command.c](/Users/baekcg/Documents/Projects/pokeheartgold/src/battle/battle_command.c#L1519)
- [src/battle/battle_command.c](/Users/baekcg/Documents/Projects/pokeheartgold/src/battle/battle_command.c#L1695)

## Tool Status

- `radare2` and `rabin2` are available and usable in this environment.
- `ghidraRun` is available at `/opt/homebrew/bin/ghidraRun`.
- `DeSmuME.app` exists at `/Applications/DeSmuME.app`.
- Ghidra headless import works with escalated permissions.
- A reusable Ghidra reporting script was added at [analysis/ghidra_scripts/ProgramReportScript.java](/Users/baekcg/Documents/Projects/pokeheartgold/analysis/ghidra_scripts/ProgramReportScript.java).
- A reusable savestate scanner was added at [analysis/scripts/find_battlemon_in_savestate.py](/Users/baekcg/Documents/Projects/pokeheartgold/analysis/scripts/find_battlemon_in_savestate.py).

## ROM Identification

ROM header confirmation:

- Internal title starts with `POKEMON HG`
- Game code is `IPKK`
- This is the Korean HeartGold ROM, not the US build

Basic binary info from `rabin2`:

- Architecture: ARM
- OS: Nintendo DS
- ARM9: `paddr=0x00004000`, `vaddr=0x02000000`, `size=0x000BAD14`
- ARM7: `paddr=0x002F7A00`, `vaddr=0x02380000`, `size=0x000276D8`

## Battle Overlay Mapping

The source indicates battle runs as `OVY_12`:

- `gOverlayTemplate_Battle = { ..., FS_OVERLAY_ID(OVY_12) }`
- Reference: [src/launch_application.c](/Users/baekcg/Documents/Projects/pokeheartgold/src/launch_application.c#L180)

From the Korean ROM header and overlay table:

- ARM9 overlay table offset: `0x000BEE00`
- Overlay entry size: `0x20`
- `OVY_12` table entry confirms:
  - Overlay ID: `12`
  - RAM address: `0x022382C0`
  - Uncompressed RAM size: `0x00037380`
  - BSS size: `0x00000000`
  - Static init start: `0x0226F60C`
  - Static init end: `0x0226F614`
  - File ID: `12`
  - Compressed size: `0x00027AEC`

FAT lookup for file ID `12`:

- ROM file start: `0x00130C00`
- ROM file end: `0x001586EC`
- File size: `0x00027AEC`

This matches the compressed overlay size from the overlay table.

## Extracted Overlay

The Korean `OVY_12` was extracted and decompressed during analysis:

- Temporary extracted file: `/tmp/ov12_kr.bin`
- Compressed size before decompression: `162540` bytes (`0x27AEC`)
- Size after decompression: `226176` bytes (`0x37380`)

The decompressed size matches the overlay table RAM size, so the extraction/decompression path is consistent.

## Ghidra Findings

### Launcher

- `ghidraRun` launches successfully in this environment when run with escalated permissions.

### Direct ROM import limits

Two direct ROM import issues were observed in Ghidra headless:

- The original Korean ROM filename was rejected because the path contained non-ASCII characters.
- After copying the ROM to `/tmp/hgk.nds`, Ghidra still reported `No load spec found`, so this local installation does not appear to support direct `.nds` import for this file.

### Successful Ghidra workflow

Ghidra successfully analyzed the decompressed battle overlay as a raw binary:

- Input: `/tmp/ov12_kr.bin`
- Loader: `Raw Binary`
- Processor: `ARM:LE:32:v5t`
- Base address option: `022382c0`
- Import mode: `-loader BinaryLoader -processor ARM:LE:32:v5t -loader-baseAddr 022382c0`

### Ghidra program report

From `ProgramReportScript.java` after analysis:

- Program name: `ov12_kr.bin`
- Executable format: `Raw Binary`
- Language ID: `ARM:LE:32:v5t`
- Compiler spec: `default`
- Reported image base: `00000000`
- Minimum address: `022382c0`
- Maximum address: `0226f63f`
- Function count after analysis: `945`
- Memory block:
  - `ram` from `022382c0` to `0226f63f`
  - Size `0x37380`
  - `r=true w=true x=true init=true overlay=false`

### Ghidra analysis timing

The headless analysis completed successfully in about `25` seconds.

Major analyzers reported by Ghidra:

- `ARM Constant Reference Analyzer`
- `Create Function`
- `Disassemble`
- `Reference`
- `Stack`
- `Decompiler Switch Analysis`

Interpretation:

- Ghidra confirms the decompressed Korean `OVY_12` is analyzable as a self-contained ARMv5T raw binary at `0x022382C0`.
- The loaded memory range matches the overlay table and `r2` results.
- Ghidra reports `IMAGE_BASE=00000000`, but the effective loaded address range is the `ram` block from `0x022382C0` to `0x0226F63F`.

## Source-Derived Runtime Model

The US source gives the semantic model even though Korean addresses differ:

- `BattleSystem_GetBattleContext()` returns `battleSystem->ctx`
  - [src/battle/battle_system.c](/Users/baekcg/Documents/Projects/pokeheartgold/src/battle/battle_system.c#L60)
- `BattleContext` is the main battle state
  - [include/battle/battle.h](/Users/baekcg/Documents/Projects/pokeheartgold/include/battle/battle.h#L279)
- `BattleMon` is each battler's live combat state
  - [include/battle/battle.h](/Users/baekcg/Documents/Projects/pokeheartgold/include/battle/battle.h#L207)
- `RunBattleScript()` dispatches battle script opcodes
  - [src/battle/battle_command.c](/Users/baekcg/Documents/Projects/pokeheartgold/src/battle/battle_command.c#L48)
- `BtlCmd_CalcDamage()` writes to `ctx->damage`
  - [src/battle/battle_command.c](/Users/baekcg/Documents/Projects/pokeheartgold/src/battle/battle_command.c#L744)
- `BtlCmd_ChangeStatStage()` writes into `ctx->battleMons[..].statChanges`
  - [src/battle/battle_command.c](/Users/baekcg/Documents/Projects/pokeheartgold/src/battle/battle_command.c#L1519)
- `BtlCmd_UpdateMonData()` updates battler fields then copies back to party state
  - [src/battle/battle_command.c](/Users/baekcg/Documents/Projects/pokeheartgold/src/battle/battle_command.c#L1695)

## Korean Battle Memory Anchors

The following offsets are relative to `BattleContext *ctx`.

High-confidence `BattleContext` offsets:

- `ctx + 0x213C` = `battleStatus`
- `ctx + 0x2140` = `battleStatus2`
- `ctx + 0x2144` = `damage`
- `ctx + 0x2148` = `hitDamage`
- `ctx + 0x2700` = `battleScriptBuffer`
- `ctx + 0x2D40` = `battleMons[0]`

High-confidence `BattleMon` layout:

- Stride: `0xC0`
- `+0x00` = `species`
- `+0x0C` = `moves[4]`
- `+0x18` = `statChanges[8]`
- `+0x27` = `ability`
- `+0x4C` = `hp`
- `+0x50` = `maxHp`
- `+0x64` = `exp`
- `+0x6C` = `status`
- `+0x70` = `status2`
- `+0x78` = `item`
- `+0x80` = `moveEffectFlags`

Derived battler base examples:

- `battleMons[0].hp` = `ctx + 0x2D8C`
- `battleMons[1].hp` = `ctx + 0x2E4C`
- `battleMons[2].hp` = `ctx + 0x2F0C`
- `battleMons[3].hp` = `ctx + 0x2FCC`

## Binary Evidence From Korean OVY_12

Literal-pool searches against `/tmp/ov12_kr.bin` produced repeated hits for the same offsets expected from the source layout.

Observed repeated constants:

- `0x213C` at examples such as `0x022410B8`, `0x0224BF24`
- `0x2144` at examples such as `0x022410D4`, `0x0224D3C8`
- `0x2D8C` at examples such as `0x022410D0`, `0x0224D3E0`
- `0x2D90` at examples such as `0x02241F60`, `0x0224D3C4`
- `0x2DAC` at examples such as `0x02241C88`, `0x0224AA54`
- `0x2DB0` at examples such as `0x02241290`, `0x0224D3D0`
- `0x2700` at `0x0226ECA8`

Interpretation:

- Korean `OVY_12` appears to preserve the same broad `BattleContext` and `BattleMon` layout used by the US decomp.
- Absolute addresses differ because this is a different ROM build, but the structure-relative field layout is stable enough to use for reverse tracing and live memory work.

## Practical DeSmuME Search Procedure

To locate battle memory during a live fight:

1. Search current HP as a 32-bit value.
2. For a candidate address `X`, test:
   - `X + 0x04` should look like `maxHp`
   - `X + 0x20` should behave like `status`
   - `X + 0x24` should behave like `status2`
   - `X + 0x2C` should behave like held item
3. If those line up, `X - 0x4C` is likely the start of `BattleMon`.
4. From a confirmed `BattleMon` base:
   - `ctx = battleMonBase - 0x2D40` for battler 0
   - `ctx = battleMonBase - 0x2E00` for battler 1
   - More generally, `battleMonBase = ctx + 0x2D40 + 0xC0 * battlerId`
5. Once `ctx` is known:
   - `ctx + 0x2144` tracks current script damage
   - `ctx + 0x2700` contains battle script words
   - `ctx + 0x213C` and `ctx + 0x2140` track battle state flags

## Savestate Verification

Live verification was performed using:

- `/Users/baekcg/Documents/save_state.dst`

### Savestate format notes

- File header begins with `DeSmuME SState`
- Payload after offset `0x20` is zlib-compressed
- Decompressed size: `11,670,828` bytes

### ARM9 memory block anchor inside the savestate

The first 64 bytes of the ROM's ARM9 payload were searched inside the decompressed savestate.

Result:

- ARM9 memory block file offset inside savestate: `0x0000C6A0`
- This corresponds to live NDS address `0x02000000`

Therefore:

- `live_addr = 0x02000000 + (savestate_file_offset - 0x0000C6A0)`

### Confirmed battle structures from the savestate

Using the previously derived `BattleMon` layout:

- Player `BattleMon` file offset: `0x002D30D4`
- Enemy `BattleMon` file offset: `0x002D3194`
- These are exactly `0xC0` bytes apart, matching the expected `BattleMon` stride.

Converted live ARM9 addresses:

- `BattleContext` = `0x022C3CF4`
- `battleMons[0]` = `0x022C6A34`
- `battleMons[1]` = `0x022C6AF4`
- `ctx->battleStatus` = `0x022C5E30`
- `ctx->damage` = `0x022C5E38`
- `ctx->battleScriptBuffer` = `0x022C63F4`

### Verified player battler data

At `0x022C6A34`:

- `species = 158` = `TOTODILE`
- `moves = (10, 43, 0, 0)` = `SCRATCH`, `LEER`
- `level = 5`
- `hp = 19`
- `maxHp = 20`
- `status = 0`
- `status2 = 0`

This matches the reported live battle state:

- Level 5 Totodile
- Current HP 19
- Max HP 20
- Moves Scratch and Leer

### Verified enemy battler data

At `0x022C6AF4`:

- `species = 16` = `PIDGEY`
- `moves = (33, 0, 0, 0)` = `TACKLE`
- `level = 2`
- `hp = 4`
- `maxHp = 13`
- `status = 0`
- `status2 = 0`

This matches the reported live battle state:

- Enemy is a level 2 Pidgey

### Verified battle context state

At `BattleContext = 0x022C3CF4`:

- `battleStatus = 0`
- `battleStatus2 = 0`
- `damage = 0`
- `hitDamage = -1`
- first 8 `battleScriptBuffer` words:
  - `0x20`
  - `0x0`
  - `0x10`
  - `0xff`
  - `0x5d`
  - `0x21`
  - `0x1`
  - `0x2`

Interpretation:

- The player and enemy `BattleMon` structures are confirmed in a real Korean battle savestate.
- The `BattleContext` offsets derived from source plus static reverse engineering are valid for this Korean build in live memory.
- The absolute runtime addresses above are directly usable as anchors for DeSmuME memory inspection and runtime patching.

## Reproducible Savestate Workflow

The verification above was reproduced with the helper script:

- [analysis/scripts/find_battlemon_in_savestate.py](/Users/baekcg/Documents/Projects/pokeheartgold/analysis/scripts/find_battlemon_in_savestate.py)

Player battler search command:

```bash
python3 analysis/scripts/find_battlemon_in_savestate.py \
  '/Users/baekcg/Documents/save_state.dst' \
  '/Users/baekcg/Documents/Projects/Poke-Speech/포켓몬스터 하트골드(K).nds' \
  --species 158 --level 5 --hp 19 --max-hp 20 --move 10 --move 43
```

Observed match:

- `candidate_1 file_off=0x2d30d4`
- `candidate_1 live_addr=0x022C6A34`
- `moves=(10, 43, 0, 0)`
- `hp=19 max_hp=20`

Enemy battler search command:

```bash
python3 analysis/scripts/find_battlemon_in_savestate.py \
  '/Users/baekcg/Documents/save_state.dst' \
  '/Users/baekcg/Documents/Projects/Poke-Speech/포켓몬스터 하트골드(K).nds' \
  --species 16 --level 2 --move 33
```

Observed match:

- `candidate_1 file_off=0x2d3194`
- `candidate_1 live_addr=0x022C6AF4`
- `moves=(33, 0, 0, 0)`
- `hp=4 max_hp=13`

This gives a repeatable workflow for future Korean savestate verification without manually searching raw decompressed memory.

## Verified Direct Modification Points

All addresses below come from the validated `save_state.dst` battle instance.

Shared formulas:

- `BattleContext = 0x022C3CF4`
- `battleMons[n] = 0x022C3CF4 + 0x2D40 + 0xC0 * n`
- `BattleMon.hp = battleMons[n] + 0x4C`
- `BattleMon.maxHp = battleMons[n] + 0x50`
- `BattleMon.status = battleMons[n] + 0x6C`
- `BattleMon.status2 = battleMons[n] + 0x70`

Player battler 0, Totodile:

- `BattleMon base = 0x022C6A34`
- `species = 0x022C6A34`
- `moves = 0x022C6A40`
- `statChanges = 0x022C6A4C`
- `ability = 0x022C6A5B`
- `movePPCur = 0x022C6A60`
- `level = 0x022C6A68`
- `hp = 0x022C6A80`
- `maxHp = 0x022C6A84`
- `exp = 0x022C6A98`
- `status = 0x022C6AA0`
- `status2 = 0x022C6AA4`
- `item = 0x022C6AAC`
- `moveEffectFlags = 0x022C6AB4`

Enemy battler 1, Pidgey:

- `BattleMon base = 0x022C6AF4`
- `species = 0x022C6AF4`
- `moves = 0x022C6B00`
- `statChanges = 0x022C6B0C`
- `ability = 0x022C6B1B`
- `movePPCur = 0x022C6B20`
- `level = 0x022C6B28`
- `hp = 0x022C6B40`
- `maxHp = 0x022C6B44`
- `exp = 0x022C6B58`
- `status = 0x022C6B60`
- `status2 = 0x022C6B64`
- `item = 0x022C6B6C`
- `moveEffectFlags = 0x022C6B74`

BattleContext control fields:

- `battleStatus = 0x022C5E30`
- `battleStatus2 = 0x022C5E34`
- `damage = 0x022C5E38`
- `hitDamage = 0x022C5E3C`
- `battleScriptBuffer = 0x022C63F4`
- `battleMons[0] = 0x022C6A34`
- `battleMons[1] = 0x022C6AF4`

Practical live-edit notes:

- Changing `hp` alone updates the current battler HP but can desync expected behavior if `maxHp` or script-side damage state is inconsistent.
- For safe battle testing, pair `hp` edits with checks on `status`, `status2`, and `ctx->damage`.
- Editing `moves`, `movePPCur`, or `statChanges` is usually lower risk than directly changing controller state or script buffer words.
- `battleScriptBuffer` is useful for tracing script flow, but arbitrary writes there are higher risk than writing battler fields.

## Stable Validation Strategy

Fixed-value checks such as current HP, exact species, or specific move IDs are useful for first discovery, but they are not stable enough for an always-on automation script.

For a reusable detector, validate the structure instead of the current values:

- Cache a previously found `BattleContext` and revalidate it every frame.
- Only rescan RAM when the cached `BattleContext` stops matching the expected layout.
- Treat `BattleMon` as valid when it satisfies structural constraints:
  - `species` is nonzero and in a plausible range
  - `level` is `1..100`
  - `hp` is `0..maxHp`
  - `maxHp` is nonzero and plausible
  - `moves[4]` are all in a plausible move-ID range
  - `statChanges[8]` stay within `0..12`
  - `type1/type2` stay within the expected Gen 4 type range
- Treat `BattleContext` as valid when:
  - `command` and `commandNext` are below `CONTROLLER_COMMAND_MAX`
  - `battlersOnField` is `2` or `4`
  - `battleMons[0]` and `battleMons[1]` are plausible active battlers
  - `battleMons[2]` and `battleMons[3]` are either plausible battlers or zeroed slots

This is the correct basis for a Lua automation that must decide whether it is currently inside a battle before touching battle memory.

## Lua Detector

A DeSmuME-oriented detector script was added at:

- [analysis/scripts/desmume_battle_state_detector.lua](/Users/baekcg/Documents/Projects/pokeheartgold/analysis/scripts/desmume_battle_state_detector.lua)
- [analysis/scripts/desmume_battle_bridge.py](/Users/baekcg/Documents/Projects/pokeheartgold/analysis/scripts/desmume_battle_bridge.py)
- [analysis/scripts/desmume_lua_savestate_harness.lua](/Users/baekcg/Documents/Projects/pokeheartgold/analysis/scripts/desmume_lua_savestate_harness.lua)
- [analysis/scripts/run_desmume_battle_harness.py](/Users/baekcg/Documents/Projects/pokeheartgold/analysis/scripts/run_desmume_battle_harness.py)

Design points:

- Scans ARM9 RAM for a plausible `BattleMon[0]` and derives `BattleContext` from `ctx + 0x2D40`.
- Revalidates cached `ctx` every frame instead of doing a full rescan constantly.
- Rescans only when the cached candidate fails structural validation.
- Reads `command`, `commandNext`, `damage`, player battler, and enemy battler every frame after lock-on.
- Accepts multiple common Lua memory API names at runtime so the script can survive small emulator API differences.
- Writes a normalized battle snapshot to `runtime/desmume/state.json`.
- Consumes high-level commands from `runtime/desmume/command.json`.
- Keeps memory patching, joypad input, and savestate handling inside Lua while Python only emits intent-level actions.
- Includes a savestate-backed harness so the Lua bridge can be replayed offline without a live DeSmuME session.

The intended long-term usage is:

1. Lua script confirms `in_battle` and resolves/caches `BattleContext`.
2. Lua script writes the normalized snapshot JSON for the current frame.
3. Python reads `state.json` and decides `select_move`, `press_buttons`, or `save_state`.
4. Lua consumes `command.json` and performs the emulator-facing action.

## Updated Next Steps

- Trace the Korean `OVY_12` functions that read or write `0x2144`, `0x2D8C`, and `0x2700` to map damage, battler update, and script dispatch handlers more precisely.
- Add a second helper that converts a confirmed `BattleMon` address into `BattleContext`, battler index, and nearby control fields automatically.
- Capture one more savestate during a nonzero-damage frame and verify how `ctx->damage` and `ctx->hitDamage` transition across script execution.
- Build a Korean-specific watch list for `battlerIdAttacker`, `battlerIdTarget`, controller command state, and animation dispatch state.

## Notes

- A full US build output is not required for this workflow.
- The US decomp is still useful as a semantic reference map even when all final address work is done against the Korean ROM.
