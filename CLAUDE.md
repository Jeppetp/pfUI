# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

pfUI is a complete World of Warcraft UI replacement addon for Vanilla/TBC clients, specifically this fork is optimized for Turtle WoW. It features ~80 modules, 10+ internal libraries, and optional DLL integrations (SuperWoW, Nampower, UnitXP_SP3).

## Development Commands

There is no build system - this is a pure Lua addon loaded directly by WoW. Test changes by reloading the UI in-game with `/rl`.

**In-game slash commands:**
- `/pfui` - Open settings GUI
- `/pfdll` - Check DLL status (SuperWoW, Nampower, UnitXP)
- `/pftest` - Toggle unitframe test mode
- `/rl` - Reload UI

## Architecture

### Entry Point and Initialization

**pfUI.lua** is the main entry point. Initialization order:
1. Slash commands registered
2. Main frame created, `ADDON_LOADED` event registered
3. SavedVariables loaded (`pfUI_config`, `pfUI_playerDB`, `pfUI_profiles`, `pfUI_cache`)
4. Client/expansion detected (`pfUI.expansion`, `pfUI.client`)
5. Modules and skins loaded via XML includes

### Module System

Modules are registered with:
```lua
pfUI:RegisterModule("moduleName", "vanilla:tbc:wotlk", function()
  -- C = pfUI_config, L = locale strings, T = translations
end)
```

The second parameter specifies expansion compatibility (colon-separated). Each module receives an injected environment via `setfenv` providing access to `C`, `L`, `T`, `pfUI`, and `_G`.

### Directory Structure

- `pfUI.lua` - Entry point
- `init/` - XML loaders that define load order (env.xml → compat.xml → api.xml → libs.xml → skins.xml → modules.xml)
- `api/` - Core APIs: config system, UI widgets, unitframe API
- `libs/` - Internal libraries (libcast, libdebuff, libpredict, librange, etc.)
- `modules/` - All feature modules (~80 files)
- `skins/blizzard/` - Blizzard UI reskins
- `env/` - Localization files and game data tables
- `compat/` - Expansion-specific compatibility patches

### Key Libraries

- **libdebuff.lua** - Debuff/buff tracking with duration prediction (vanilla only)
- **libcast.lua** - Provides `UnitCastingInfo()`/`UnitChannelInfo()` for vanilla
- **libpredict.lua** - HoT duration prediction with HealComm compatibility
- **librange.lua** - Range checking using best available method

### Configuration System

Config is stored in `pfUI_config` as nested tables:
```lua
pfUI_config = {
  global = { language = "enUS", ... },
  unitframes = { player = {...}, target = {...} },
  disabled = { moduleName = "1" },  -- "1" = disabled
  ...
}
```

Use `pfUI:UpdateConfig(group, subgroup, entry, value)` to set defaults.

### DLL Integration

Three optional DLLs provide enhanced features:
- **SuperWoW** - `UNIT_CASTEVENT`, `UnitPosition()`, `SpellInfo()`
- **Nampower** - Spell queue indicator, GCD indicator
- **UnitXP_SP3** - `UnitInLineOfSight()`, `UnitIsBehind()`

Detection helpers: `pfUI.api.HasSuperWoW()`, `pfUI.api.HasNampower()`, `pfUI.api.HasUnitXP()`

### Performance Patterns

OnUpdate throttling pattern used throughout:
```lua
if (this.tick or 0) > GetTime() then return end
this.tick = GetTime() + 0.1
-- expensive operation
```

Raid frames use centralized event handling with O(1) unitmap lookups instead of per-frame event registration.

### Skin System

Skins reskin Blizzard UI frames:
```lua
pfUI:RegisterSkin("SkinName", "vanilla:tbc", function()
  -- modify Blizzard frames
end)
```

Disable with `pfUI_config.disabled.skin_SkinName = "1"`.

## Code Conventions

- Version checks: `if pfUI.client > 11200 then return end` or `if pfUI.expansion == "vanilla" then`
- Localized strings via `L["key"]`, translations via `T["key"]`
- Media paths use `img:` and `font:` prefixes resolved by metatable
