# pfUI - Turtle WoW Enhanced Edition (Experiment Branch)

[![Version](https://img.shields.io/badge/version-7.4.1--experimental-red.svg)](https://github.com/me0wg4ming/pfUI)
[![Turtle WoW](https://img.shields.io/badge/Turtle%20WoW-1.18.0-brightgreen.svg)](https://turtlecraft.gg/)
[![SuperWoW](https://img.shields.io/badge/SuperWoW-REQUIRED-purple.svg)](https://github.com/balakethelock/SuperWoW)
[![Nampower](https://img.shields.io/badge/Nampower-REQUIRED-yellow.svg)](https://gitea.com/avitasia/nampower)
[![UnitXP](https://img.shields.io/badge/UnitXP__SP3-Optional-yellow.svg)](https://codeberg.org/konaka/UnitXP_SP3)

**⚠️ EXPERIMENTAL BUILD - Use at your own risk! ⚠️**

This is an experimental pfUI fork with a **complete rewrite of the debuff tracking system**. It offers significant performance improvements for debuff timers but has higher complexity.

**Requires:** SuperWoW + Nampower DLL for full functionality!

> **Looking for stable version?** Use Master branch: [https://github.com/me0wg4ming/pfUI](https://github.com/me0wg4ming/pfUI)

---

## 🚨 Important Warnings

### This Build Is EXPERIMENTAL

**Known Issues:**
- ❌ Not fully tested in 40-man raids
- ❌ Higher code complexity = more potential bugs

**Use This Build If:**
- ✅ You have SuperWoW + Nampower installed
- ✅ You want improved debuff tracking performance
- ✅ You're willing to test and report bugs
- ✅ You play Druid/Rogue (combo point finishers benefit most)

**Use Master If:**
- ✅ You want a stable, battle-tested build
- ✅ You don't have Nampower
- ✅ You prefer reliability over bleeding-edge features

---

## 🎯 What's New in Version 7.4.1 (January 27, 2026)

### 🎯 Nameplate Debuff Timer Improvements

- ✅ **New Option: Enable Debuff Timers** - Toggle for debuff timer display on nameplates
  - Moved from hidden location (Appearance → Cooldown → "Display Debuff Durations") to Nameplates → Debuffs
  - All timer-related options are now grouped together for better discoverability
- ✅ **New Option: Show Timer Text** - Toggle the countdown text (e.g., "12s") on debuff icons
  - Previously always shown, now configurable
- ✅ **Show Timer Animation** - Existing pie-chart animation option, now properly grouped with other timer options

### 🖼️ Unitframe Timer Config Fix (unitframes.lua)

- ✅ **Live Config Updates** - "Show Timer Animation" and "Show Timer Text" now update immediately
  - Previously: Changes only applied after buffs/debuffs were refreshed
  - Now: Toggling the option instantly shows/hides the animation and text on existing buffs/debuffs

### 🔧 Slot Shifting Fix Attempt (libdebuff.lua)

- ✅ **DEBUFF_REMOVED now uses slotData.spellName** - Previously used spellName from scan, which could be wrong after slot shifting
  - When debuffs shift slots (e.g., slot 3 removed, slots 4+ shift down), the scan might read a different spell
  - Now uses `removedSpellName = slotData.spellName` from stored slot data for consistency
- ✅ **Cleanup empty spell tables** - After removing a caster from allAuraCasts, checks if no other casters remain and removes the empty spell table
- ✅ **Defensive casterGuid validation** - Checks for empty string and "0x0000000000000000" before looking up timer data
- ✅ **Invalid timer detection** - Warns when remaining > duration (impossible state)
- ✅ **ValidateSlotConsistency function** - Debug function to verify allSlots and allAuraCasts consistency after shifting
- ✅ **Enhanced debug logging** - All debug messages now include target= for easier filtering

---

## 🎯 What's New in Version 7.4.0 (January 26, 2026)

### 🗡️ Rogue Combo Point Fix

**PLAYER_COMBO_POINTS event now works for Rogues:**

The combo point tracking was previously only enabled for Druids. Rogues were completely ignored, causing abilities like Kidney Shot to always show base duration (1 sec) instead of the correct CP-scaled duration.

**Technical Details:**
- Nampower sends `durationMs=1000` (base duration) for Kidney Shot
- Code checked `if duration == 0` before calling `GetDuration()` 
- Since duration was 1 (not 0), the CP calculation was skipped
- Fix: Always call `GetDuration()` for CP-based abilities, regardless of event duration

### ⚙️ New Settings: Number & Timer Formatting

**Abbreviate Numbers (Settings → General):**

| Option | Example |
|--------|---------|
| Full Numbers | 4250 |
| 2 Decimals | 4.25k |
| 1 Decimal | 4.2k (always rounds DOWN) |

**Castbar Timer Decimals (Settings → General):**

| Option | Example |
|--------|---------|
| 1 Decimal | 2.1 |
| 2 Decimals | 2.14 |

### 🎬 Nameplate Castbar Improvements

**Smooth Castbar Animation:**
- Fixed stuttering castbar caused by incorrect throttle placement
- Scanner throttle (0.05s) now only affects nameplate detection
- Castbar updates run at full 50 FPS for smooth animation

**Countdown Timer:**
- Castbar timer now counts DOWN (3.0 → 0.0) instead of up
- Shows remaining cast time, not elapsed time

**Intelligent Throttling (unchanged):**
- Target OR casting nameplates: 0.02s (50 FPS)
- All other nameplates: 0.1s (10 FPS)
- Event updates bypass throttle entirely

### 🧹 Memory Management

**Cache cleanup for hidden nameplates:**
- `guidRegistry` cleared when plate hides
- `CastEvents` cleared when plate hides
- `debuffCache` cleared when plate hides
- `threatMemory` cleared when plate hides

Prevents memory leaks when mobs die or go out of range.

---

## 🎯 What's New in Version 7.3.0 (January 25, 2026)

### ⚡ O(1) Performance Optimizations for Unitframes

**Complete rewrite of health/mana lookups using Nampower's `GetUnitField` API:**

The unitframes now use direct memory access via `GetUnitField(guid, "health")` instead of the slower `UnitHealth()` API calls. This provides significant performance improvements especially in raids.

**Key Changes:**

| Component | Before (7.2.0) | After (7.3.0) |
|-----------|----------------|---------------|
| HealPredict Health | `UnitHealth()` API calls | `GetUnitField(guid, "health")` O(1) |
| Health Bar Colors | 4x redundant API calls per update | Uses cached `hp_orig`/`hpmax_orig` values |
| GetColor Function | `UnitHealth()` API calls | `GetUnitField(guid, "health")` O(1) |

**Fallback Support:**
- Automatic fallback to `UnitHealth()` when Nampower not available
- Automatic fallback for units >180 yards (out of Nampower range)
- Automatic fallback when GUID unavailable

### 🚀 Smart Roster Updates (No More Freeze!)

**GUID-based tracking eliminates screen freezes when swapping raid groups:**

Previously, any raid roster change would trigger a full update of ALL 40 raid frames, causing noticeable freezes. Now, only frames where the actual player changed get updated.

**How it works:**
```lua
-- OLD: RAID_ROSTER_UPDATE → ALL 40 frames update_full = true → FREEZE
-- NEW: RAID_ROSTER_UPDATE → Check GUID per frame → Only changed frames update
```

| Scenario | Before (7.2.0) | After (7.3.0) |
|----------|----------------|---------------|
| Swap 2 players | 40 frame updates | 2 frame updates |
| Player joins | 40 frame updates | 1 frame update |
| Player leaves | 40 frame updates | 1 frame update |
| No changes | 40 frame updates | 0 frame updates |

**Technical Implementation:**
- `pfUI.uf.guidTracker` tracks GUID per frame
- On roster change, compares old GUID vs new GUID
- Only sets `update_full = true` if GUID actually changed
- Also forces `update_aura = true` to refresh buffs/debuffs

### 🔧 libpredict.lua Optimizations

**Eliminated redundant `UnitName()` calls:**
- `UnitGetIncomingHeals()`: Removed double `UnitName()` call
- `UnitHasIncomingResurrection()`: Removed double `UnitName()` call  
- `UNIT_HEALTH` event handler: Reuses cached name variable

---

## 🎯 What's New in Version 7.2.0 (January 24, 2026)

### 🐱 Druid Secondary Mana Bar Overhaul

**Complete rewrite using Nampower's `GetUnitField` API:**

The Druid Mana Bar feature (showing base mana while in shapeshift form) has been completely rewritten to use Nampower's native `GetUnitField` instead of the deprecated `UnitMana()` extended return values.

**Key Changes:**

| Component | Before (7.1.0) | After (7.2.0) |
|-----------|----------------|---------------|
| Data Source | `UnitMana()` second return value | `GetUnitField(guid, "power1")` |
| Player Support | ✅ Druids only | ✅ Druids only |
| Target Support | ❌ Limited/broken | ✅ All classes can see Druid mana in all forms |
| Text Settings | Hardcoded format | Respects Power Bar text config |

<img width="704" height="210" alt="grafik" src="https://i.ibb.co/bgfC04Gk/grafik.png" />

**New Features:**
- ✅ **Target Secondary Mana:** See enemy/friendly Druid's base mana while they're in Cat/Bear form
- ✅ **Respects Power Text Settings:** Uses same format as your Power Bar configuration (`powerdyn`, `power`, `powerperc`, `none`, etc.)
- ✅ **Available for ALL Classes:** Any class can now see Druid mana bars (controlled by "Show Druid Mana Bar" setting)

**Technical Implementation:**
```lua
-- OLD: Extended UnitMana (unreliable for other units)
local _, baseMana = UnitMana("target")  -- Often returns nil for non-player

-- NEW: Direct field access via Nampower
local _, guid = UnitExists("target")
local baseMana = GetUnitField(guid, "power1")      -- Base mana
local baseMaxMana = GetUnitField(guid, "maxPower1") -- Max base mana
```

### 🧹 Major Code Cleanup

**superwow.lua:**
- ❌ Removed legacy `pfDruidMana` bar (old SuperWoW-style implementation)
- ❌ Removed `UnitMana()` fallback code
- ✅ Unified all secondary mana bars to use `GetUnitField`
- ✅ Fixed text centering issue (was using `SetJustifyH("RIGHT")`)

**nampower.lua - Massive Cleanup:**

Removed significant amounts of dead/unused code:

| Removed Feature | Reason |
|-----------------|--------|
| Buff tracking system | Data collected but never displayed |
| HoT Detection (AURA_CAST events) | `OnHotApplied` callback never implemented |
| Swing Timer (`GetSwingTimers()`) | Never called anywhere in codebase |
| UNIT_DIED buff/debuff cleanup | Now handled by libdebuff |

**Result:** Cleaner, more maintainable code with reduced memory footprint.

---

## 🎯 What's New in Version 7.1.0 (January 24, 2026)

### ⚡ Cooldown Timer Animation Support

**Nameplate Debuff Animations:**
- ✅ Added "Show Timer Animation" option for nameplate debuffs
- ✅ Uses proper `Model` frame with `CooldownFrameTemplate` for Vanilla client
- ✅ Pie/swipe animation now works on nameplate debuff icons
- ✅ Configurable via GUI: Nameplates → Show Timer Animation

**Target Frame Debuff Animations:**
- ✅ Timer animations now properly visible on target/player frame debuffs
- ✅ Fixed CD frame scaling and positioning for correct display
- ✅ `SetScale(size/32)`, `SetAllPoints()`, `SetFrameLevel(14)` for proper rendering

**cooldown.lua Fix:**
- ✅ Added `elseif pfCooldownStyleAnimation == 1 then SetAlpha(1)` to make animations visible
- ✅ Previously animations were created but never shown (alpha stayed 0)

### 🧹 Memory Leak Fixes

**libdebuff.lua:**
- ✅ `lastCastRanks` table now cleaned up (entries older than 3 seconds removed)
- ✅ `lastFailedSpells` table now cleaned up (entries older than 2 seconds removed)
- ✅ Previously these tables grew indefinitely over long play sessions

**unitframes.lua:**
- ✅ Cache cleanup now uses in-place `= nil` instead of creating new table every 30 seconds
- ✅ Reduces garbage collector pressure

**nameplates.lua:**
- ✅ Reusable `debuffSeen` table instead of creating `local seen = {}` on every DEBUFF_UPDATE event
- ✅ Significant reduction in table allocations during combat

---

## 🎯 What's New in Version 7.0.0 (January 21, 2026)

### 🔥 Complete libdebuff.lua Rewrite (464 → 1594 lines)

**Event-Driven Architecture:**

Replaced tooltip scanning with a pure event-based system using Nampower/SuperWoW:

**OLD (Master):**
```lua
-- Every UI update:
for slot = 1, 16 do
  scanner:SetUnitDebuff("target", slot)  -- Tooltip scan
  local name = scanner:Line(1)
end
```

**NEW (Experiment):**
```lua
-- Events fire when changes happen:
RegisterEvent("AURA_CAST_ON_SELF")     -- You cast a debuff
RegisterEvent("DEBUFF_ADDED_OTHER")    -- Debuff lands in slot
RegisterEvent("DEBUFF_REMOVED_OTHER")  -- Debuff removed

-- UI reads from pre-computed tables:
local data = ownDebuffs[guid][spell]  -- Direct lookup
```

---

### 🐱 Combo Point Finisher Support

**Dynamic Duration Calculation:**

| Ability | Formula | Durations (1-5 CP) |
|---------|---------|-------------------|
| Rip | 8s + CP × 2s | 10s / 12s / 14s / 16s / 18s |
| Rupture | 10s + CP × 2s | 12s / 14s / 16s / 18s / 20s |
| Kidney Shot | 2s + CP × 1s | 3s / 4s / 5s / 6s / 7s |

**Before:** All Rips showed 18s (wrong for 1-4 CP)
**After:** Shows actual duration based on combo points used

---

### 🎭 Carnage Talent Detection

**Ferocious Bite Refresh Mechanics:**
- Tracks Carnage talent (Rank 2) which makes Ferocious Bite refresh Rip & Rake
- Only refreshes when Ferocious Bite HITS (not on miss/dodge/parry)
- Preserves original duration (doesn't reset to new CP count)
- Uses `DidSpellFail()` API for miss detection

---

### 🔄 Additional Features

- **Debuff Overwrite Pairs:** Faerie Fire ↔ Faerie Fire (Feral), Demoralizing Shout ↔ Demoralizing Roar
- **Slot Shifting Algorithm:** Accurate icon placement when debuffs expire
- **Multi-Caster Tracking:** Multiple players' debuffs tracked separately
- **Rank Protection:** Lower rank can't overwrite higher rank timer
- **Unique Debuff System:** Hunter's Mark, Scorpid Sting, etc. handled correctly

---

## 📊 Performance Comparison

### The Core Difference: Data Access Architecture

**Master uses Blizzard API + Tooltip Scanning:**
```lua
-- Every UnitDebuff call requires tooltip scan
function libdebuff:UnitDebuff(unit, id)
  local texture, stacks, dtype = UnitDebuff(unit, id)
  if texture then
    scanner:SetUnitDebuff(unit, id)  -- Tooltip scan to get spell name
    effect = scanner:Line(1)
  end
  -- Duration comes from hardcoded lookup tables
end

-- UnitOwnDebuff iterates all 16 slots
function libdebuff:UnitOwnDebuff(unit, id)
  for i = 1, 16 do
    local effect = libdebuff:UnitDebuff(unit, i)  -- 16 tooltip scans!
    if caster == "player" then ...
  end
end
```

**Experiment uses Nampower Events + GetUnitField:**
```lua
-- Single call returns ALL 48 aura slots (32 buffs + 16 debuffs)
local auras = GetUnitField(guid, "aura")  -- Returns array[48] of spell IDs
local stacks = GetUnitField(guid, "auraApplications")  -- Returns array[48] of stack counts

-- Events fire with full data including duration
-- AURA_CAST_ON_OTHER: spellId, casterGuid, targetGuid, effect, effectAuraName, 
--                     effectAmplitude, effectMiscValue, durationMs, auraCapStatus
-- BUFF_REMOVED_OTHER: guid, slot, spellId, stackCount, auraLevel

-- UnitOwnDebuff is just a table lookup
function libdebuff:UnitOwnDebuff(unit, id)
  local _, guid = UnitExists(unit)
  local data = ownDebuffs[guid][spellName]  -- Pre-computed by events
  return data.duration, data.timeleft, ...
end
```

### Nampower Features Used (Experiment Only)

| Feature | Purpose | Data Provided |
|---------|---------|---------------|
| `GetUnitField(guid, "aura")` | Single call returns all 48 aura spell IDs | `array[48]` of spell IDs |
| `GetUnitField(guid, "auraApplications")` | Stack counts for all auras | `array[48]` of stack counts |
| `GetUnitField(guid, "power1")` | Base mana for shapeshifted Druids | Mana value (7.2.0) |
| `GetUnitField(guid, "maxPower1")` | Max base mana | Max mana value (7.2.0) |
| `AURA_CAST_ON_OTHER` | Instant debuff cast detection | spellId, casterGuid, targetGuid, **durationMs** |
| `AURA_CAST_ON_SELF` | Instant self-buff detection | Same as above |
| `BUFF_REMOVED_OTHER` | Instant aura removal detection | guid, **slot**, spellId, stackCount |
| `DEBUFF_ADDED_OTHER` | Debuff slot assignment | guid, slot, spellId, stacks |
| `DEBUFF_REMOVED_OTHER` | Debuff removal with slot info | guid, slot, spellId |

Master uses **none** of these - it relies on:
- `UnitDebuff()` API (no caster info, no duration)
- Tooltip scanning via `GameTooltip:SetUnitDebuff()` to get spell names
- Chat message parsing (`CHAT_MSG_SPELL_PERIODIC_*`) for duration detection
- Hardcoded duration lookup tables

### Performance Comparison

| Operation | Master | Experiment | Improvement |
|-----------|--------|------------|-------------|
| Initial target scan | 16 tooltip scans | 1 GetUnitField call (48 slots) | **16x fewer calls** |
| Get YOUR debuffs | Loop 16 slots + tooltip each | Direct table lookup | **~50-100x faster** |
| Debuff duration | Hardcoded tables / chat parsing | Event provides `durationMs` | **Accurate to ms** |
| Detect debuff removal | Polling / timeout | `BUFF_REMOVED_OTHER` event | **Instant** |
| Detect new debuff | Chat message delay | `AURA_CAST_ON_OTHER` event | **Instant** |
| Caster identification | Not available | Event provides `casterGuid` | **New capability** |
| Druid mana (other units) | Not available | `GetUnitField(guid, "power1")` | **New in 7.2.0** |
| Memory usage | ~50KB | ~200KB | 4x more (negligible) |

### Memory Management (7.1.0+ Fixes)

| Table | Before 7.1.0 | After 7.1.0 |
|-------|--------------|-------------|
| `lastCastRanks` | Grew indefinitely | Cleaned every 30s (>3s old) |
| `lastFailedSpells` | Grew indefinitely | Cleaned every 30s (>2s old) |
| `debuffSeen` (nameplates) | New table per DEBUFF_UPDATE | Reused single table |
| `cleanedCache` (unitframes) | New table every 30s | In-place cleanup |

---

## 📋 File Changes Summary

### Version 7.4.0

| File | Location | Changes |
|------|----------|---------|
| `libdebuff.lua` | `libs/` | Rogue PLAYER_COMBO_POINTS fix, always use GetDuration() for CP-abilities |
| `api.lua` | `api/` | Abbreviate() now supports 3 modes (off/2dec/1dec), 1dec always floors |
| `config.lua` | `api/` | Added `castbardecimals` option |
| `gui.lua` | `modules/` | Abbreviate Numbers dropdown, Castbar Timer Decimals dropdown |
| `nameplates.lua` | `modules/` | Smooth castbar (throttle fix), countdown timer, cache cleanup |
| `castbar.lua` | `modules/` | FormatCastbarTime() helper, respects castbardecimals config |

### Version 7.2.0

| File | Location | Changes |
|------|----------|---------|
| `superwow.lua` | `modules/` | Removed legacy pfDruidMana, added Target/ToT secondary mana bars, GetUnitField for all mana queries, respect Power Bar text settings |
| `nampower.lua` | `modules/` | Major cleanup: removed dead buff tracking, HoT detection, swing timer code |

### Version 7.1.0

| File | Location | Changes |
|------|----------|---------|
| `libdebuff.lua` | `libs/` | Memory leak fixes for lastCastRanks, lastFailedSpells |
| `unitframes.lua` | `api/` | In-place cache cleanup, CD frame scaling/positioning |
| `nameplates.lua` | `modules/` | Reusable debuffSeen table, Model+CooldownFrameTemplate |
| `cooldown.lua` | `modules/` | SetAlpha(1) for pfCooldownStyleAnimation == 1 |
| `config.lua` | `api/` | Added nameplates.debuffanim option |
| `gui.lua` | `modules/` | Added "Show Timer Animation" checkbox for nameplates |

---

## 📋 Installation

### Requirements

**REQUIRED:**
- SuperWoW DLL
- Nampower DLL

**Optional but Recommended:**
- UnitXP_SP3 DLL (for accurate XP tracking)

### Steps

1. Install SuperWoW + Nampower
2. Download pfUI Experiment build
3. Extract to `Interface/AddOns/pfUI`
4. `/reload`
5. Check for errors in console

### Verification

Type `/run print(GetNampowerVersion())` - should show version number.

If `nil`, Nampower is not installed correctly!

---

## 🐛 Known Issues

### Untested Scenarios

- ❌ 40-man raids with 5+ druids (slot shifting stress test)
- ❌ Rapid target swapping with Ferocious Bite spam
- ⚠️ Multi-caster tracking in AQ40/Naxx

### Edge Cases

1. **DEBUFF_ADDED race condition:** Sometimes fires before AURA_CAST_ON_SELF processes
2. **Slot shifting bugs:** Complex logic for removing/adding debuffs
3. **Combo point detection:** Relies on PLAYER_COMBO_POINTS event timing

---

## 📜 Changelog

### 7.4.0 (January 26, 2026)

**Added:**
- ✅ Castbar Timer Decimals setting (1 or 2 decimals)
- ✅ Abbreviate Numbers dropdown (Full / 2 Decimals / 1 Decimal)
- ✅ Nameplate castbar countdown (shows remaining time)
- ✅ Cache cleanup for hidden nameplates (prevents memory leaks)

**Fixed:**
- 🔧 Rogue combo point tracking (PLAYER_COMBO_POINTS was Druid-only)
- 🔧 Kidney Shot/Rupture duration (now always uses GetDuration() for CP-abilities)
- 🔧 Nameplate castbar stuttering (throttle only affects scanner, not updates)

**Changed:**
- 🔧 Abbreviate Numbers: 1 Decimal mode always rounds DOWN (4180 → 4.1k)
- 🔧 Nameplate castbar: counts down instead of up

### 7.2.0 (January 24, 2026)

**Added:**
- ✅ Target Secondary Mana Bar (see Druid mana while in shapeshift form)
- ✅ Target-of-Target Secondary Mana Bar
- ✅ Secondary Mana Bars now respect Power Bar text settings

**Changed:**
- 🔧 Secondary Mana Bars now use `GetUnitField(guid, "power1")` instead of `UnitMana()`
- 🔧 "Show Druid Mana Bar" setting now available for ALL classes (not just Druids)

**Removed:**
- ❌ Legacy `pfDruidMana` bar (replaced by `pfPlayerSecondaryMana`)
- ❌ `UnitMana()` extended return value fallback
- ❌ Dead code in nampower.lua: buff tracking, HoT detection, swing timer

### 7.1.0 (January 24, 2026)

**Added:**
- ✅ Nameplate debuff timer animation support (pie/swipe effect)
- ✅ Target frame debuff animation improvements
- ✅ GUI option: Nameplates → Show Timer Animation

**Fixed:**
- 🔧 Memory leak: `lastCastRanks` now cleaned up (>3s old entries)
- 🔧 Memory leak: `lastFailedSpells` now cleaned up (>2s old entries)
- 🔧 Memory churn: Reusable `debuffSeen` table in nameplates
- 🔧 Memory churn: In-place cache cleanup in unitframes
- 🔧 cooldown.lua: Animation now visible when pfCooldownStyleAnimation == 1

### 7.0.0 (January 21, 2026)

**Added:**
- ✅ Event-driven debuff tracking (AURA_CAST, DEBUFF_ADDED, etc.)
- ✅ Combo point finisher support (Rip, Rupture, Kidney Shot)
- ✅ Carnage talent detection (Ferocious Bite refresh)
- ✅ Debuff overwrite pairs (Faerie Fire ↔ Faerie Fire Feral)
- ✅ Slot shifting algorithm (accurate icon placement)
- ✅ Multi-caster tracking (multiple Moonfires)
- ✅ Rank protection (Rank 1 can't overwrite Rank 10)
- ✅ Unique debuff system (Hunter's Mark, Scorpid Sting)
- ✅ Nampower GetUnitField() initial scan
- ✅ Combat indicator fix (works on player frame now)

**Changed:**
- 🔧 libdebuff.lua completely rewritten (464 → 1594 lines)
- 🔧 UnitOwnDebuff() uses table lookup instead of tooltip scan

---

## 🤝 Contributing

**Bug Reports:**
- Discord: me0wg4ming
- GitHub Issues: https://github.com/me0wg4ming/pfUI/issues

**Include:**
- SuperWoW version
- Nampower version
- Exact steps to reproduce
- Screenshots if possible
- `/console scriptErrors 1` error messages

---

## ⚖️ License

Same as original pfUI: GNU General Public License v3.0

---

## 🙏 Credits

**Original pfUI:** Shagu (https://github.com/shagu/pfUI)
**Master Fork:** me0wg4ming
**Experiment Development:** me0wg4ming + AI collaboration
**Nampower:** Avitasia
**SuperWoW:** Balake
**Testing:** Turtle WoW community

---

*Last Updated: January 27, 2026*
*Version: 7.4.1-experimental*
