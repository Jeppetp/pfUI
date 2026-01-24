pfUI:RegisterModule("nameplates", "vanilla", function ()
  -- disable original castbars
  pcall(SetCVar, "ShowVKeyCastbar", 0)

  -- check for SuperWoW support (use SUPERWOW_VERSION global)
  local superwow_active = SUPERWOW_VERSION ~= nil

  -- Local function references for performance
  local GetTime = GetTime
  local UnitExists = UnitExists
  local UnitName = UnitName
  local UnitClass = UnitClass
  local UnitLevel = UnitLevel
  local UnitIsPlayer = UnitIsPlayer
  local UnitIsDead = UnitIsDead
  local UnitAffectingCombat = UnitAffectingCombat
  local UnitIsUnit = UnitIsUnit
  local UnitCanAssist = UnitCanAssist
  local UnitCastingInfo = UnitCastingInfo
  local UnitChannelInfo = UnitChannelInfo
  local UnitHealth = UnitHealth
  local UnitHealthMax = UnitHealthMax
  local UnitMana = UnitMana
  local UnitManaMax = UnitManaMax
  local pairs = pairs
  local tonumber = tonumber
  local strlower = strlower
  local strfind = strfind
  local strlen = strlen
  local floor = floor
  local ceil = ceil
  local abs = abs
  local mathmod = math.mod

  local unitcolors = {
    ["ENEMY_NPC"] = { .9, .2, .3, .8 },
    ["NEUTRAL_NPC"] = { 1, 1, .3, .8 },
    ["FRIENDLY_NPC"] = { .6, 1, 0, .8 },
    ["ENEMY_PLAYER"] = { .9, .2, .3, .8 },
    ["FRIENDLY_PLAYER"] = { .2, .6, 1, .8 }
  }

  local offtanks = {}

  local combatstate = {
    -- gets overwritten by user config
    ["OFFTANK"]  = { r = .7, g = .4, b = .2, a = 1 },
    ["NOTHREAT"] = { r = .7, g = .7, b = .2, a = 1 },
    ["THREAT"]   = { r = .7, g = .2, b = .2, a = 1 },
    ["CASTING"]  = { r = .7, g = .2, b = .7, a = 1 },
    ["STUN"]     = { r = .2, g = .7, b = .7, a = 1 },
    ["NONE"]     = { r = .2, g = .2, b = .2, a = 1 },
  }

  local elitestrings = {
    ["elite"] = "+",
    ["rareelite"] = "R+",
    ["rare"] = "R",
    ["boss"] = "B"
  }

  -- catch all nameplates
  local childs, regions, plate
  local initialized = 0
  
  -- Friendly zone nameplate disable state
  local savedHostileState = nil
  local savedFriendlyState = nil
  local inFriendlyZone = false
  local parentcount = 0
  local platecount = 0
  local registry = {}
  local debuffdurations = C.appearance.cd.debuffs == "1" and true or nil

  -- ============================================================================
  -- OPTIMIZATION: GUID-based registries for O(1) lookups (from ShaguPlatesX)
  -- ============================================================================
  local guidRegistry = {}   -- guid -> plate (for direct event routing)
  local CastEvents = {}     -- guid -> cast info
  local debuffCache = {}    -- guid -> { [spellID] = { start, duration } }
  local threatMemory = {}   -- guid -> true if mob had player targeted

  -- wipe polyfill
  local wipe = wipe or function(t) for k in pairs(t) do t[k] = nil end end

  -- Player GUID for filtering
  local _, PlayerGUID = UnitExists("player")

  -- ============================================================================
  -- OPTIMIZATION: Config caching (updated on config change)
  -- ============================================================================
  local cfg = {}
  local function CacheConfig()
    cfg.showcastbar = C.nameplates["showcastbar"] == "1"
    cfg.targetcastbar = C.nameplates["targetcastbar"] == "1"
    cfg.notargalpha = tonumber(C.nameplates.notargalpha) or 0.5
    if cfg.notargalpha > 1 then cfg.notargalpha = cfg.notargalpha / 100 end
    cfg.namefightcolor = C.nameplates.namefightcolor == "1"
    cfg.spellname = C.nameplates.spellname == "1"
    cfg.showhp = C.nameplates.showhp == "1"
    cfg.showdebuffs = C.nameplates["showdebuffs"] == "1"
    cfg.targetzoom = C.nameplates.targetzoom == "1"
    cfg.zoomval = (tonumber(C.nameplates.targetzoomval) or 0.4) + 1
    cfg.width = tonumber(C.nameplates.width) or 120
    cfg.heighthealth = tonumber(C.nameplates.heighthealth) or 8
    cfg.targetglow = C.nameplates.targetglow == "1"
    cfg.targethighlight = C.nameplates.targethighlight == "1"
    cfg.outcombatstate = C.nameplates.outcombatstate == "1"
    cfg.barcombatstate = C.nameplates.barcombatstate == "1"
    cfg.ccombatcasting = C.nameplates.ccombatcasting == "1"
    cfg.ccombatthreat = C.nameplates.ccombatthreat == "1"
    cfg.ccombatnothreat = C.nameplates.ccombatnothreat == "1"
    cfg.ccombatstun = C.nameplates.ccombatstun == "1"
    cfg.ccombatofftank = C.nameplates.ccombatofftank == "1"
    cfg.use_unitfonts = C.nameplates.use_unitfonts == "1"
    cfg.font_size = cfg.use_unitfonts and C.global.font_unit_size or C.global.font_size
    cfg.hptextformat = C.nameplates.hptextformat
  end

  -- ============================================================================
  -- OPTIMIZATION: Frame state cache (updated once per frame, used by all plates)
  -- ============================================================================
  local frameState = {
    now = 0,
    hasTarget = false,
    targetGuid = nil,
    hasMouseover = false,
  }

  -- cache default border color
  local er, eg, eb, ea = GetStringColor(pfUI_config.appearance.border.color)

  local function GetCombatStateColor(guid)
    local target = guid.."target"
    local color = false

    if UnitAffectingCombat("player") and UnitAffectingCombat(guid) and not UnitCanAssist("player", guid) then
      local isCasting = CastEvents[guid] and CastEvents[guid].endTime and frameState.now < CastEvents[guid].endTime
      local targetingPlayer = UnitIsUnit(target, "player")

      -- Remember if mob targets player, clear only when targeting someone else while NOT casting
      if targetingPlayer then
        threatMemory[guid] = true
      elseif UnitExists(target) and not isCasting then
        threatMemory[guid] = nil
      end

      if cfg.ccombatcasting and isCasting then
        color = combatstate.CASTING
      elseif cfg.ccombatthreat and (targetingPlayer or threatMemory[guid]) then
        color = combatstate.THREAT
      elseif cfg.ccombatofftank and UnitName(target) and offtanks[strlower(UnitName(target))] then
        color = combatstate.OFFTANK
      elseif cfg.ccombatofftank and pfUI.uf and pfUI.uf.raid and pfUI.uf.raid.tankrole[UnitName(target)] then
        color = combatstate.OFFTANK
      elseif cfg.ccombatnothreat and UnitExists(target) then
        color = combatstate.NOTHREAT
      elseif cfg.ccombatstun and not UnitExists(target) and not UnitIsPlayer(guid) then
        color = combatstate.STUN
      end
    end

    return color
  end

  local function DoNothing()
    return
  end

  local function wipe(table)
    if type(table) ~= "table" then
      return
    end
    for k in pairs(table) do
      table[k] = nil
    end
  end

  local function IsNamePlate(frame)
    if frame:GetObjectType() ~= NAMEPLATE_FRAMETYPE then return nil end
    regions = plate:GetRegions()

    if not regions then return nil end
    if not regions.GetObjectType then return nil end
    if not regions.GetTexture then return nil end

    if regions:GetObjectType() ~= "Texture" then return nil end
    return regions:GetTexture() == "Interface\\Tooltips\\Nameplate-Border" or nil
  end

  local function DisableObject(object)
    if not object then return end
    if not object.GetObjectType then return end

    local otype = object:GetObjectType()

    if otype == "Texture" then
      object:SetTexture("")
      object:SetTexCoord(0, 0, 0, 0)
    elseif otype == "FontString" then
      object:SetWidth(0.001)
    elseif otype == "StatusBar" then
      object:SetStatusBarTexture("")
    end
  end

  local function TotemPlate(name)
    if C.nameplates.totemicons == "1" then
      for totem, icon in pairs(L["totems"]) do
        if string.find(name, totem) then return icon end
      end
    end
  end

  local function HidePlate(unittype, name, fullhp, target)
    -- keep some plates always visible according to config
    if C.nameplates.fullhealth == "1" and not fullhp then return nil end
    if C.nameplates.target == "1" and target then return nil end

    -- return true when something needs to be hidden
    if C.nameplates.enemynpc == "1" and unittype == "ENEMY_NPC" then
      return true
    elseif C.nameplates.enemyplayer == "1" and unittype == "ENEMY_PLAYER" then
      return true
    elseif C.nameplates.neutralnpc == "1" and unittype == "NEUTRAL_NPC" then
      return true
    elseif C.nameplates.friendlynpc == "1" and unittype == "FRIENDLY_NPC" then
      return true
    elseif C.nameplates.friendlyplayer == "1" and unittype == "FRIENDLY_PLAYER" then
      return true
    elseif C.nameplates.critters == "1" and unittype == "NEUTRAL_NPC" then
      for i, critter in pairs(L["critters"]) do
        if string.lower(name) == string.lower(critter) then return true end
      end
    elseif C.nameplates.totems == "1" then
      for totem in pairs(L["totems"]) do
        if string.find(name, totem) then return true end
      end
    end

    -- nothing to hide
    return nil
  end

  local function abbrevname(t)
    return string.sub(t,1,1)..". "
  end

  local function GetNameString(name)
    local abbrev = pfUI_config.unitframes.abbrevname == "1" or nil
    local size = 20

    -- first try to only abbreviate the first word
    if abbrev and name and strlen(name) > size then
      name = string.gsub(name, "^(%S+) ", abbrevname)
    end

    -- abbreviate all if it still doesn't fit
    if abbrev and name and strlen(name) > size then
      name = string.gsub(name, "(%S+) ", abbrevname)
    end

    return name
  end


  local function GetUnitType(red, green, blue)
    if red > .9 and green < .2 and blue < .2 then
      return "ENEMY_NPC"
    elseif red > .9 and green > .9 and blue < .2 then
      return "NEUTRAL_NPC"
    elseif red < .2 and green < .2 and blue > 0.9 then
      return "FRIENDLY_PLAYER"
    elseif red < .2 and green > .9 and blue < .2 then
      return "FRIENDLY_NPC"
    end
  end

  local filter, list, cache
  local function DebuffFilterPopulate()
    -- initialize variables
    filter = C.nameplates["debuffs"]["filter"]
    if filter == "none" then return end
    list = C.nameplates["debuffs"][filter]
    cache = {}

    -- populate list
    for _, val in pairs({strsplit("#", list)}) do
      cache[strlower(val)] = true
    end
  end

  local function DebuffFilter(effect)
    if filter == "none" then return true end
    if not cache then DebuffFilterPopulate() end

    if filter == "blacklist" and cache[strlower(effect)] then
      return nil
    elseif filter == "blacklist" then
      return true
    elseif filter == "whitelist" and cache[strlower(effect)] then
      return true
    elseif filter == "whitelist" then
      return nil
    end
  end

  local function PlateCacheDebuffs(self, unitstr, verify)
    if not self.debuffcache then self.debuffcache = {} end
    if not libdebuff then return end  -- Safety check

    for id = 1, 16 do
      local effect, _, texture, stacks, _, duration, timeleft

      if unitstr and C.nameplates.selfdebuff == "1" then
        effect, _, texture, stacks, _, duration, timeleft = libdebuff:UnitOwnDebuff(unitstr, id)
      else
        effect, _, texture, stacks, _, duration, timeleft = libdebuff:UnitDebuff(unitstr, id)
      end

      if effect and timeleft and timeleft > 0 then
        local start = GetTime() - ( (duration or 0) - ( timeleft or 0) )
        local stop = GetTime() + ( timeleft or 0 )
        self.debuffcache[id] = self.debuffcache[id] or {}
        self.debuffcache[id].effect = effect
        self.debuffcache[id].texture = texture
        self.debuffcache[id].stacks = stacks
        self.debuffcache[id].duration = duration or 0
        self.debuffcache[id].start = start
        self.debuffcache[id].stop = stop
        self.debuffcache[id].empty = nil
      end
    end

    self.verify = verify
  end

  local function PlateUnitDebuff(self, id)
    -- break on unknown data
    if not self.debuffcache then return end
    if not self.debuffcache[id] then return end
    if not self.debuffcache[id].stop then return end

    -- break on timeout debuffs
    if self.debuffcache[id].empty then return end
    if self.debuffcache[id].stop < GetTime() then return end

    -- return cached debuff
    local c = self.debuffcache[id]
    return c.effect, c.rank, c.texture, c.stacks, c.dtype, c.duration, (c.stop - GetTime())
  end

  local function CreateDebuffIcon(plate, index)
    plate.debuffs[index] = CreateFrame("Frame", plate.platename.."Debuff"..index, plate)
    plate.debuffs[index]:Hide()
    plate.debuffs[index]:SetFrameLevel(1)

    plate.debuffs[index].icon = plate.debuffs[index]:CreateTexture(nil, "BACKGROUND")
    plate.debuffs[index].icon:SetTexture(.3,1,.8,1)
    plate.debuffs[index].icon:SetAllPoints(plate.debuffs[index])

    plate.debuffs[index].stacks = plate.debuffs[index]:CreateFontString(nil, "OVERLAY")
    plate.debuffs[index].stacks:SetAllPoints(plate.debuffs[index])
    plate.debuffs[index].stacks:SetJustifyH("RIGHT")
    plate.debuffs[index].stacks:SetJustifyV("BOTTOM")
    plate.debuffs[index].stacks:SetTextColor(1,1,0)

    -- Read config values for cooldown display (like unitframes does)
    local cooldown_text = debuffdurations and 1 or 0
    local cooldown_anim = tonumber(C.nameplates.debuffanim) or 0

    if pfUI.client <= 11200 then
      -- Use Model frame with CooldownFrameTemplate for proper pie animation in Vanilla
      plate.debuffs[index].cd = CreateFrame("Model", plate.platename.."Debuff"..index.."Cooldown", plate.debuffs[index], "CooldownFrameTemplate")
      plate.debuffs[index].cd:SetAllPoints(plate.debuffs[index])
      plate.debuffs[index].cd.pfCooldownStyleAnimation = cooldown_anim
      plate.debuffs[index].cd.pfCooldownStyleText = cooldown_text
    else
      -- use regular cooldown animation frames on burning crusade and later
      plate.debuffs[index].cd = CreateFrame(COOLDOWN_FRAME_TYPE, plate.platename.."Debuff"..index.."Cooldown", plate.debuffs[index], "CooldownFrameTemplate")
      -- Setup for animation support
      local debuffsize = tonumber(C.nameplates.debuffsize) or 20
      local cdScale = debuffsize / 32
      plate.debuffs[index].cd:ClearAllPoints()
      plate.debuffs[index].cd:SetScale(cdScale)
      plate.debuffs[index].cd:SetAllPoints(plate.debuffs[index])
      plate.debuffs[index].cd:SetFrameLevel(plate.debuffs[index]:GetFrameLevel() + 1)
      plate.debuffs[index].cd.pfCooldownStyleAnimation = cooldown_anim
      plate.debuffs[index].cd.pfCooldownStyleText = cooldown_text
    end

    plate.debuffs[index].cd.pfCooldownType = "ALL"
  end

  local function UpdateDebuffConfig(nameplate, i)
    if not nameplate.debuffs[i] then return end

    -- update debuff positions
    local width = tonumber(C.nameplates.width)
    local debuffsize = tonumber(C.nameplates.debuffsize)
    local debuffoffset = tonumber(C.nameplates.debuffoffset)
    local limit = floor(width / debuffsize)
    local font = C.nameplates.use_unitfonts == "1" and pfUI.font_unit or pfUI.font_default
    local font_size = C.nameplates.use_unitfonts == "1" and C.global.font_unit_size or C.global.font_size
    local font_style = C.nameplates.name.fontstyle

    local aligna, alignb, offs, space
    if C.nameplates.debuffs["position"] == "BOTTOM" then
      aligna, alignb, offs, space = "TOPLEFT", "BOTTOMLEFT", -debuffoffset, -1
    else
      aligna, alignb, offs, space = "BOTTOMLEFT", "TOPLEFT", debuffoffset, 1
    end

    nameplate.debuffs[i].stacks:SetFont(font, font_size, font_style)
    nameplate.debuffs[i]:ClearAllPoints()
    if i == 1 then
      nameplate.debuffs[i]:SetPoint(aligna, nameplate.health, alignb, 0, offs)
    elseif i <= limit then
      nameplate.debuffs[i]:SetPoint("LEFT", nameplate.debuffs[i-1], "RIGHT", 1, 0)
    elseif i > limit and limit > 0 then
      nameplate.debuffs[i]:SetPoint(aligna, nameplate.debuffs[i-limit], alignb, 0, space)
    end

    nameplate.debuffs[i]:SetWidth(tonumber(C.nameplates.debuffsize))
    nameplate.debuffs[i]:SetHeight(tonumber(C.nameplates.debuffsize))
    
    -- Update cooldown display settings
    if nameplate.debuffs[i].cd then
      local cooldown_text = debuffdurations and 1 or 0
      local cooldown_anim = tonumber(C.nameplates.debuffanim) or 0
      nameplate.debuffs[i].cd.pfCooldownStyleText = cooldown_text
      nameplate.debuffs[i].cd.pfCooldownStyleAnimation = cooldown_anim
      
      -- Update scale for TBC+
      if pfUI.client > 11200 then
        local cdScale = debuffsize / 32
        nameplate.debuffs[i].cd:SetScale(cdScale)
      end
    end
  end

  -- create nameplate core
  local nameplates = CreateFrame("Frame", "pfNameplates", UIParent)
  nameplates:RegisterEvent("PLAYER_ENTERING_WORLD")
  nameplates:RegisterEvent("PLAYER_TARGET_CHANGED")
  nameplates:RegisterEvent("UNIT_COMBO_POINTS")
  nameplates:RegisterEvent("PLAYER_COMBO_POINTS")
  nameplates:RegisterEvent("UNIT_AURA")
  nameplates:RegisterEvent("ZONE_CHANGED_NEW_AREA")
  
  -- NEW: Register cast events like Overhead.lua
  if superwow_active then
    nameplates:RegisterEvent("UNIT_CASTEVENT")
  end

  nameplates:SetScript("OnEvent", function()
    if event == "PLAYER_ENTERING_WORLD" or event == "ZONE_CHANGED_NEW_AREA" then
      if event == "PLAYER_ENTERING_WORLD" then
        _, PlayerGUID = UnitExists("player")
        CacheConfig()
        this:SetGameVariables()
      end
      
      -- Handle friendly zone nameplate disable feature
      local disableHostile = C.nameplates["disable_hostile_in_friendly"] == "1"
      local disableFriendly = C.nameplates["disable_friendly_in_friendly"] == "1"
      
      if disableHostile or disableFriendly then
        local pvpType = GetZonePVPInfo()
        local nowFriendly = (pvpType == "friendly")
        
        if nowFriendly and not inFriendlyZone then
          -- Entering friendly zone - save current state and hide based on options
          inFriendlyZone = true
          savedHostileState = C.nameplates["showhostile"]
          savedFriendlyState = C.nameplates["showfriendly"]
          
          if disableHostile then
            _G.NAMEPLATES_ON = nil
            HideNameplates()
          end
          
          if disableFriendly then
            _G.FRIENDNAMEPLATES_ON = nil
            HideFriendNameplates()
          end
        elseif not nowFriendly and inFriendlyZone then
          -- Leaving friendly zone - restore previous state
          inFriendlyZone = false
          
          if savedHostileState == "1" then
            _G.NAMEPLATES_ON = true
            ShowNameplates()
          end
          
          if savedFriendlyState == "1" then
            _G.FRIENDNAMEPLATES_ON = true
            ShowFriendNameplates()
          end
          
          savedHostileState = nil
          savedFriendlyState = nil
        end
      end

    elseif event == "UNIT_AURA" then
      -- SuperWoW: arg1 is the unit GUID - direct O(1) lookup
      local guid = arg1
      local plate = guidRegistry[guid]
      if plate and plate.nameplate then
        plate.nameplate.auraUpdate = true

        -- Track debuff start times for duration display
        if debuffdurations then
          if not debuffCache[guid] then debuffCache[guid] = {} end
          local seen = {}

          -- Scan current debuffs and track new ones
          for i = 1, 16 do
            local texture, stacks, dtype, spellID = UnitDebuff(guid, i)
            if not texture then break end

            seen[spellID] = true
            if not debuffCache[guid][spellID] then
              -- New debuff - record start time and lookup duration
              local spellName = SpellInfo(spellID)
              local duration = L["debuffs"][spellName] and L["debuffs"][spellName][0] or nil
              debuffCache[guid][spellID] = { start = GetTime(), duration = duration }
            end
          end

          -- Clear expired debuffs from cache
          for spellID in pairs(debuffCache[guid]) do
            if not seen[spellID] then
              debuffCache[guid][spellID] = nil
            end
          end
        end
      end

    elseif event == "UNIT_CASTEVENT" then
      local casterGUID = arg1
      local eventType = arg3  -- "START", "CAST", "FAIL", "CHANNEL", "MAINHAND", "OFFHAND"
      local spellID = arg4
      local castDuration = arg5

      -- Skip player casts and melee
      if casterGUID == PlayerGUID then return end
      if eventType == "MAINHAND" or eventType == "OFFHAND" then return end

      -- Store cast data
      if eventType == "START" or eventType == "CHANNEL" then
        if not CastEvents[casterGUID] then CastEvents[casterGUID] = {} end
        wipe(CastEvents[casterGUID])

        local spellName, _, icon = SpellInfo(spellID)
        CastEvents[casterGUID].event = eventType
        CastEvents[casterGUID].spellID = spellID
        CastEvents[casterGUID].spellName = spellName
        CastEvents[casterGUID].icon = icon
        CastEvents[casterGUID].startTime = GetTime()
        CastEvents[casterGUID].endTime = castDuration and GetTime() + castDuration / 1000
        CastEvents[casterGUID].duration = castDuration and castDuration / 1000

      elseif eventType == "CAST" or eventType == "FAIL" then
        if CastEvents[casterGUID] then
          wipe(CastEvents[casterGUID])
        end
      end

      -- Flag plate for castbar update via GUID registry (O(1) lookup)
      local plate = guidRegistry[casterGUID]
      if plate and plate.nameplate then
        plate.nameplate.castUpdate = true
      end

    elseif event == "PLAYER_TARGET_CHANGED" then
      -- Flag target plate for update via GUID registry
      local _, targetGuid = UnitExists("target")
      if targetGuid then
        local plate = guidRegistry[targetGuid]
        if plate and plate.nameplate then
          plate.nameplate.targetUpdate = true
        end
      end
      -- Also propagate to all plates for alpha/strata updates
      this.eventcache = true

    elseif event == "PLAYER_COMBO_POINTS" or event == "UNIT_COMBO_POINTS" then
      -- Only flag the target plate for combo point update
      local _, targetGuid = UnitExists("target")
      if targetGuid then
        local plate = guidRegistry[targetGuid]
        if plate and plate.nameplate then
          plate.nameplate.comboUpdate = true
        end
      end
    else
      this.eventcache = true
    end
  end)

  nameplates:SetScript("OnUpdate", function()
    -- Update frame-level cache once per frame
    frameState.now = GetTime()
    frameState.hasTarget, frameState.targetGuid = UnitExists("target")
    frameState.hasMouseover = UnitExists("mouseover")

    -- Throttle main scanner
    if (this.tick or 0) > frameState.now then return end
    this.tick = frameState.now + 0.05

    -- propagate events to all nameplates
    if this.eventcache then
      this.eventcache = nil
      for plate in pairs(registry) do
        plate.eventcache = true
      end
    end

    -- detect new nameplates
    parentcount = WorldFrame:GetNumChildren()
    if initialized < parentcount then
      childs = { WorldFrame:GetChildren() }
      for i = initialized + 1, parentcount do
        plate = childs[i]
        if IsNamePlate(plate) and not registry[plate] then
          nameplates.OnCreate(plate)
          registry[plate] = plate
        end
      end

      initialized = parentcount
    end

    -- Central OnUpdate for all visible plates
    for plate in pairs(registry) do
      if plate:IsVisible() then
        nameplates.OnUpdate(plate, frameState)
      else
        -- Clean up ALL caches for hidden plates to prevent memory leak
        local guid = plate.nameplate and plate.nameplate.cachedGuid
        if guid then
          -- Remove from guidRegistry
          if guidRegistry[guid] == plate then
            guidRegistry[guid] = nil
          end
          
          -- Clean CastEvents cache
          if CastEvents[guid] then
            CastEvents[guid] = nil
          end
          
          -- Clean debuffCache
          if debuffCache[guid] then
            debuffCache[guid] = nil
          end
          
          -- Clean threatMemory
          if threatMemory[guid] then
            threatMemory[guid] = nil
          end
        end
      end
    end
  end)

  -- combat tracker
  nameplates.combat = CreateFrame("Frame")
  nameplates.combat:RegisterEvent("PLAYER_ENTER_COMBAT")
  nameplates.combat:RegisterEvent("PLAYER_LEAVE_COMBAT")
  nameplates.combat:SetScript("OnEvent", function()
    if event == "PLAYER_ENTER_COMBAT" then
      this.inCombat = 1
      if PlayerFrame then PlayerFrame.inCombat = 1 end
    elseif event == "PLAYER_LEAVE_COMBAT" then
      this.inCombat = nil
      if PlayerFrame then PlayerFrame.inCombat = nil end
    end
  end)

  nameplates.OnCreate = function(frame)
    local parent = frame or this
    platecount = platecount + 1
    platename = "pfNamePlate" .. platecount

    -- create pfUI nameplate overlay
    local nameplate = CreateFrame("Button", platename, parent)
    nameplate.platename = platename
    nameplate:EnableMouse(0)
    nameplate.parent = parent
    nameplate.cache = {}
    nameplate.UnitDebuff = PlateUnitDebuff
    nameplate.CacheDebuffs = PlateCacheDebuffs
    nameplate.original = {}

    -- create shortcuts for all known elements and disable them
    nameplate.original.healthbar, nameplate.original.castbar = parent:GetChildren()
    DisableObject(nameplate.original.healthbar)
    DisableObject(nameplate.original.castbar)

    for i, object in pairs({parent:GetRegions()}) do
      if NAMEPLATE_OBJECTORDER[i] and NAMEPLATE_OBJECTORDER[i] == "raidicon" then
        nameplate[NAMEPLATE_OBJECTORDER[i]] = object
      elseif NAMEPLATE_OBJECTORDER[i] then
        nameplate.original[NAMEPLATE_OBJECTORDER[i]] = object
        DisableObject(object)
      else
        DisableObject(object)
      end
    end

    HookScript(nameplate.original.healthbar, "OnValueChanged", nameplates.OnValueChanged)

    -- adjust sizes and scaling of the nameplate
    nameplate:SetScale(UIParent:GetScale())

    nameplate.health = CreateFrame("StatusBar", nil, nameplate)
    nameplate.health:SetFrameLevel(4) -- keep above glow
    nameplate.health.text = nameplate.health:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    nameplate.health.text:SetAllPoints()
    nameplate.health.text:SetTextColor(1,1,1,1)

    nameplate.name = nameplate:CreateFontString(nil, "OVERLAY")
    nameplate.name:SetPoint("TOP", nameplate, "TOP", 0, 0)

    nameplate.glow = nameplate:CreateTexture(nil, "BACKGROUND")
    nameplate.glow:SetPoint("CENTER", nameplate.health, "CENTER", 0, 0)
    nameplate.glow:SetTexture(pfUI.media["img:dot"])
    nameplate.glow:Hide()

    nameplate.guild = nameplate:CreateFontString(nil, "OVERLAY")
    nameplate.guild:SetPoint("BOTTOM", nameplate.health, "BOTTOM", 0, 0)

    nameplate.level = nameplate:CreateFontString(nil, "OVERLAY")
    nameplate.level:SetPoint("RIGHT", nameplate.health, "LEFT", -3, 0)

    nameplate.raidicon:SetParent(nameplate.health)
    nameplate.raidicon:SetDrawLayer("OVERLAY")
    nameplate.raidicon:SetTexture(pfUI.media["img:raidicons"])

    nameplate.totem = CreateFrame("Frame", nil, nameplate)
    nameplate.totem:SetPoint("CENTER", nameplate, "CENTER", 0, 0)
    nameplate.totem:SetHeight(32)
    nameplate.totem:SetWidth(32)
    nameplate.totem.icon = nameplate.totem:CreateTexture(nil, "OVERLAY")
    nameplate.totem.icon:SetTexCoord(.078, .92, .079, .937)
    nameplate.totem.icon:SetAllPoints()
    CreateBackdrop(nameplate.totem)

    do -- debuffs
      nameplate.debuffs = {}
      CreateDebuffIcon(nameplate, 1)
    end

    do -- combopoints
      local combopoints = { }
      for i = 1, 5 do
        combopoints[i] = CreateFrame("Frame", nil, nameplate)
        combopoints[i]:Hide()
        combopoints[i]:SetFrameLevel(8)
        combopoints[i].tex = combopoints[i]:CreateTexture("OVERLAY")
        combopoints[i].tex:SetAllPoints()

        if i < 3 then
          combopoints[i].tex:SetTexture(1, .3, .3, .75)
        elseif i < 4 then
          combopoints[i].tex:SetTexture(1, 1, .3, .75)
        else
          combopoints[i].tex:SetTexture(.3, 1, .3, .75)
        end
      end
      nameplate.combopoints = combopoints
    end

    do -- castbar
      local castbar = CreateFrame("StatusBar", nil, nameplate.health)
      castbar:Hide()

      castbar:SetScript("OnShow", function()
        if C.nameplates.debuffs["position"] == "BOTTOM" then
          nameplate.debuffs[1]:SetPoint("TOPLEFT", this, "BOTTOMLEFT", 0, -4)
        end
      end)

      castbar:SetScript("OnHide", function()
        if C.nameplates.debuffs["position"] == "BOTTOM" then
          nameplate.debuffs[1]:SetPoint("TOPLEFT", this:GetParent(), "BOTTOMLEFT", 0, -4)
        end
      end)

      castbar.text = castbar:CreateFontString("Status", "DIALOG", "GameFontNormal")
      castbar.text:SetPoint("RIGHT", castbar, "LEFT", -4, 0)
      castbar.text:SetNonSpaceWrap(false)
      castbar.text:SetTextColor(1,1,1,.5)

      castbar.spell = castbar:CreateFontString("Status", "DIALOG", "GameFontNormal")
      castbar.spell:SetPoint("CENTER", castbar, "CENTER")
      castbar.spell:SetNonSpaceWrap(false)
      castbar.spell:SetTextColor(1,1,1,1)

      castbar.icon = CreateFrame("Frame", nil, castbar)
      castbar.icon.tex = castbar.icon:CreateTexture(nil, "BORDER")
      castbar.icon.tex:SetAllPoints()

      nameplate.castbar = castbar
    end

    -- Stagger tick to spread updates across frames (0.05s apart per plate)
    nameplate.tick = GetTime() + mathmod(platecount, 10) * 0.05

    parent.nameplate = nameplate
    HookScript(parent, "OnShow", nameplates.OnShow)
    -- NOTE: OnUpdate is now handled centrally, not per-plate
    parent:SetScript("OnUpdate", nil)  -- Disable Blizzard's OnUpdate

    nameplates.OnConfigChange(parent)
    nameplates.OnShow(parent)
  end

  nameplates.OnConfigChange = function(frame)
    local parent = frame
    local nameplate = frame.nameplate

    local font = C.nameplates.use_unitfonts == "1" and pfUI.font_unit or pfUI.font_default
    local font_size = C.nameplates.use_unitfonts == "1" and C.global.font_unit_size or C.global.font_size
    local font_style = C.nameplates.name.fontstyle
    local glowr, glowg, glowb, glowa = GetStringColor(C.nameplates.glowcolor)
    local hlr, hlg, hlb, hla = GetStringColor(C.nameplates.highlightcolor)
    local hptexture = pfUI.media[C.nameplates.healthtexture]
    local rawborder, default_border = GetBorderSize("nameplates")

    local plate_width = C.nameplates.width + 50
    local plate_height = C.nameplates.heighthealth + font_size + 5
    local plate_height_cast = C.nameplates.heighthealth + font_size + 5 + C.nameplates.heightcast + 5
    local combo_size = 5

    local width = tonumber(C.nameplates.width)
    local debuffsize = tonumber(C.nameplates.debuffsize)
    local healthoffset = tonumber(C.nameplates.health.offset)
    local orientation = C.nameplates.verticalhealth == "1" and "VERTICAL" or "HORIZONTAL"

    local c = combatstate -- load combat state colors
    c.CASTING.r, c.CASTING.g, c.CASTING.b, c.CASTING.a = GetStringColor(C.nameplates.combatcasting)
    c.THREAT.r, c.THREAT.g, c.THREAT.b, c.THREAT.a = GetStringColor(C.nameplates.combatthreat)
    c.NOTHREAT.r, c.NOTHREAT.g, c.NOTHREAT.b, c.NOTHREAT.a = GetStringColor(C.nameplates.combatnothreat)
    c.OFFTANK.r, c.OFFTANK.g, c.OFFTANK.b, c.OFFTANK.a = GetStringColor(C.nameplates.combatofftank)
    c.STUN.r, c.STUN.g, c.STUN.b, c.STUN.a = GetStringColor(C.nameplates.combatstun)

    offtanks = {}
    for k, v in pairs({strsplit("#", C.nameplates.combatofftanks)}) do
      offtanks[string.lower(v)] = true
    end

    nameplate:SetWidth(plate_width)
    nameplate:SetHeight(plate_height)
    nameplate:SetPoint("TOP", parent, "TOP", 0, 0)

    nameplate.name:SetFont(font, font_size, font_style)

    nameplate.health:SetOrientation(orientation)
    nameplate.health:SetPoint("TOP", nameplate.name, "BOTTOM", 0, healthoffset)
    nameplate.health:SetStatusBarTexture(hptexture)
    nameplate.health:SetWidth(C.nameplates.width)
    nameplate.health:SetHeight(C.nameplates.heighthealth)
    nameplate.health.hlr, nameplate.health.hlg, nameplate.health.hlb, nameplate.health.hla = hlr, hlg, hlb, hla

    CreateBackdrop(nameplate.health, default_border)

    nameplate.health.text:SetFont(font, font_size - 2, "OUTLINE")
    nameplate.health.text:SetJustifyH(C.nameplates.hptextpos)

    nameplate.guild:SetFont(font, font_size, font_style)

    nameplate.glow:SetWidth(C.nameplates.width + 60)
    nameplate.glow:SetHeight(C.nameplates.heighthealth + 30)
    nameplate.glow:SetVertexColor(glowr, glowg, glowb, glowa)

    nameplate.raidicon:ClearAllPoints()
    nameplate.raidicon:SetPoint(C.nameplates.raidiconpos, nameplate.health, C.nameplates.raidiconpos, C.nameplates.raidiconoffx, C.nameplates.raidiconoffy)
    nameplate.level:SetFont(font, font_size, font_style)
    nameplate.raidicon:SetWidth(C.nameplates.raidiconsize)
    nameplate.raidicon:SetHeight(C.nameplates.raidiconsize)

    for i=1,16 do
      UpdateDebuffConfig(nameplate, i)
    end

    for i=1,5 do
      nameplate.combopoints[i]:SetWidth(combo_size)
      nameplate.combopoints[i]:SetHeight(combo_size)
      nameplate.combopoints[i]:SetPoint("TOPRIGHT", nameplate.health, "BOTTOMRIGHT", -(i-1)*(combo_size+default_border*3), -default_border*3)
      CreateBackdrop(nameplate.combopoints[i], default_border)
    end

    nameplate.castbar:SetPoint("TOPLEFT", nameplate.health, "BOTTOMLEFT", 0, -default_border*3)
    nameplate.castbar:SetPoint("TOPRIGHT", nameplate.health, "BOTTOMRIGHT", 0, -default_border*3)
    nameplate.castbar:SetHeight(C.nameplates.heightcast)
    nameplate.castbar:SetStatusBarTexture(hptexture)
    nameplate.castbar:SetStatusBarColor(.9,.8,0,1)
    CreateBackdrop(nameplate.castbar, default_border)

    nameplate.castbar.text:SetFont(font, font_size, "OUTLINE")
    nameplate.castbar.spell:SetFont(font, font_size, "OUTLINE")
    nameplate.castbar.icon:SetPoint("BOTTOMLEFT", nameplate.castbar, "BOTTOMRIGHT", default_border*3, 0)
    nameplate.castbar.icon:SetPoint("TOPLEFT", nameplate.health, "TOPRIGHT", default_border*3, 0)
    nameplate.castbar.icon:SetWidth(C.nameplates.heightcast + default_border*3 + C.nameplates.heighthealth)
    CreateBackdrop(nameplate.castbar.icon, default_border)

    nameplates:OnDataChanged(nameplate)
  end

  nameplates.OnValueChanged = function(arg1)
    nameplates:OnDataChanged(this:GetParent().nameplate)
  end

  nameplates.OnDataChanged = function(self, plate)
    local visible = plate:IsVisible()
    local hp = plate.original.healthbar:GetValue()
    local hpmin, hpmax = plate.original.healthbar:GetMinMaxValues()
    local name = plate.original.name:GetText()
    local level = plate.original.level:IsShown() and plate.original.level:GetObjectType() == "FontString" and tonumber(plate.original.level:GetText()) or "??"
    local class, ulevel, elite, player, guild = GetUnitData(name, true)
    
    -- Use database level ONLY if current level is ?? (fixes ?? after reload, but doesn't override visible levels)
    local levelFromDB = false
    if level == "??" and ulevel and ulevel > 0 then
      level = ulevel
      levelFromDB = true
    end
    
    local target = plate.istarget
    local mouseover = UnitExists("mouseover") and plate.original.glow:IsShown() or nil
    local unitstr = target and "target" or mouseover and "mouseover" or nil
    local red, green, blue = plate.original.healthbar:GetStatusBarColor()
    local unittype = GetUnitType(red, green, blue) or "ENEMY_NPC"
    local font_size = C.nameplates.use_unitfonts == "1" and C.global.font_unit_size or C.global.font_size

    -- use superwow unit guid as unitstr if possible
    if superwow_active and not unitstr then
      unitstr = plate.parent:GetName(1)
    end

    -- ignore players with npc names if plate level is lower than player level
    if ulevel and ulevel > (level == "??" and -1 or level) then player = nil end

    -- cache name and reset unittype on change
    if plate.cache.name ~= name then
      plate.cache.name = name
      plate.cache.player = nil
    end

    -- read and cache unittype
    if plate.cache.player then
      -- overwrite unittype from cache if existing
      player = plate.cache.player == "PLAYER" and true or nil
    elseif unitstr then
      -- read unit type while unitstr is set
      plate.cache.player = UnitIsPlayer(unitstr) and "PLAYER" or "NPC"
    end

    if player and unittype == "ENEMY_NPC" then unittype = "ENEMY_PLAYER" end
    if player and unittype == "FRIENDLY_NPC" then unittype = "FRIENDLY_PLAYER" end
    elite = plate.original.levelicon:IsShown() and not player and "boss" or elite
    if not class then plate.wait_for_scan = true end

    -- skip data updates on invisible frames
    if not visible then return end

    -- target event sometimes fires too quickly, where nameplate identifiers are not
    -- yet updated. So while being inside this event, we cannot trust the unitstr.
    if event == "PLAYER_TARGET_CHANGED" then unitstr = nil end

    -- remove unitstr on unit name mismatch
    if unitstr and UnitName(unitstr) ~= name then unitstr = nil end

    -- use mobhealth values if addon is running
    if (MobHealth3 or MobHealthFrame) and target and name == UnitName('target') and MobHealth_GetTargetCurHP() then
      hp = MobHealth_GetTargetCurHP() > 0 and MobHealth_GetTargetCurHP() or hp
      hpmax = MobHealth_GetTargetMaxHP() > 0 and MobHealth_GetTargetMaxHP() or hpmax
    end

    -- always make sure to keep plate visible
    plate:Show()

    if target and cfg.targetglow then
      plate.glow:Show() else plate.glow:Hide()
    end

    -- target indicator
    if superwow_active and cfg.outcombatstate then
      local guid = plate.parent:GetName(1) or ""

      -- determine color based on combat state
      local color = GetCombatStateColor(guid)
      if not color then color = combatstate.NONE end

      -- set border color
      plate.health.backdrop:SetBackdropBorderColor(color.r, color.g, color.b, color.a)
    elseif target and cfg.targethighlight then
      plate.health.backdrop:SetBackdropBorderColor(plate.health.hlr, plate.health.hlg, plate.health.hlb, plate.health.hla)
    elseif C.nameplates.outfriendlynpc == "1" and unittype == "FRIENDLY_NPC" then
      plate.health.backdrop:SetBackdropBorderColor(unpack(unitcolors[unittype]))
    elseif C.nameplates.outfriendly == "1" and unittype == "FRIENDLY_PLAYER" then
      plate.health.backdrop:SetBackdropBorderColor(unpack(unitcolors[unittype]))
    elseif C.nameplates.outneutral == "1" and strfind(unittype, "NEUTRAL") then
      plate.health.backdrop:SetBackdropBorderColor(unpack(unitcolors[unittype]))
    elseif C.nameplates.outenemy == "1" and strfind(unittype, "ENEMY") then
      plate.health.backdrop:SetBackdropBorderColor(unpack(unitcolors[unittype]))
    else
      plate.health.backdrop:SetBackdropBorderColor(er,eg,eb,ea)
    end

    -- hide frames according to the configuration
    local TotemIcon = TotemPlate(name)

    if TotemIcon then
      -- create totem icon
      plate.totem.icon:SetTexture("Interface\\Icons\\" .. TotemIcon)

      plate.glow:Hide()
      plate.level:Hide()
      plate.name:Hide()
      plate.health:Hide()
      plate.guild:Hide()
      plate.totem:Show()
    elseif HidePlate(unittype, name, (hpmax-hp == hpmin), target) then
      plate.level:SetPoint("RIGHT", plate.name, "LEFT", -3, 0)
      plate.name:SetParent(plate)
      plate.guild:SetPoint("BOTTOM", plate.name, "BOTTOM", -2, -(font_size + 2))

      plate.level:Show()
      plate.name:Show()
      plate.health:Hide()
      if guild and C.nameplates.showguildname == "1" then
        plate.glow:SetPoint("CENTER", plate.name, "CENTER", 0, -(font_size / 2) - 2)
      else
        plate.glow:SetPoint("CENTER", plate.name, "CENTER", 0, 0)
      end
      plate.totem:Hide()
    else
      plate.level:SetPoint("RIGHT", plate.health, "LEFT", -5, 0)
      plate.name:SetParent(plate.health)
      plate.guild:SetPoint("BOTTOM", plate.health, "BOTTOM", 0, -(font_size + 4))

      plate.level:Show()
      plate.name:Show()
      plate.health:Show()
      plate.glow:SetPoint("CENTER", plate.health, "CENTER", 0, 0)
      plate.totem:Hide()
    end

    plate.name:SetText(GetNameString(name))
    plate.level:SetText(string.format("%s%s", level, (elitestrings[elite] or "")))
    
    -- Set level color from GetDifficultyColor when using DB level
    if levelFromDB and type(level) == "number" then
      local color = GetDifficultyColor(level)
      plate.level:SetTextColor(color.r + 0.3, color.g + 0.3, color.b + 0.3, 1)
    end

    if guild and C.nameplates.showguildname == "1" then
      plate.guild:SetText(guild)
      if guild == GetGuildInfo("player") then
        plate.guild:SetTextColor(0, 0.9, 0, 1)
      else
        plate.guild:SetTextColor(0.8, 0.8, 0.8, 1)
      end
      plate.guild:Show()
    else
      plate.guild:Hide()
    end

    plate.health:SetMinMaxValues(hpmin, hpmax)
    plate.health:SetValue(hp)

    if cfg.showhp then
      local rhp, rhpmax, estimated
      
      -- Try Nampower first for real HP values via GUID
      local guid = superwow_active and plate.parent:GetName(1) or nil
      if guid and GetUnitField then
        local npHp = GetUnitField(guid, "health")
        local npMaxHp = GetUnitField(guid, "maxHealth")
        if npHp and npHp > 0 and npMaxHp and npMaxHp > 0 then
          rhp, rhpmax = npHp, npMaxHp
        end
      end
      
      -- Fallback to existing methods
      if not rhp then
        if hpmax > 100 or (round(hpmax/100*hp) ~= hp) then
          rhp, rhpmax = hp, hpmax
        elseif pfUI.libhealth and pfUI.libhealth.enabled then
          rhp, rhpmax, estimated = pfUI.libhealth:GetUnitHealthByName(name,level,tonumber(hp),tonumber(hpmax))
        end
      end

      local setting = cfg.hptextformat
      local hasdata = ( rhp and rhpmax ) or estimated or hpmax > 100 or (round(hpmax/100*hp) ~= hp)

      if setting == "curperc" and hasdata and rhp then
        plate.health.text:SetText(string.format("%s | %s%%", Abbreviate(rhp), ceil(hp/hpmax*100)))
      elseif setting == "cur" and hasdata and rhp then
        plate.health.text:SetText(string.format("%s", Abbreviate(rhp)))
      elseif setting == "curmax" and hasdata and rhp then
        plate.health.text:SetText(string.format("%s - %s", Abbreviate(rhp), Abbreviate(rhpmax)))
      elseif setting == "curmaxs" and hasdata and rhp then
        plate.health.text:SetText(string.format("%s / %s", Abbreviate(rhp), Abbreviate(rhpmax)))
      elseif setting == "curmaxperc" and hasdata and rhp then
        plate.health.text:SetText(string.format("%s - %s | %s%%", Abbreviate(rhp), Abbreviate(rhpmax), ceil(hp/hpmax*100)))
      elseif setting == "curmaxpercs" and hasdata and rhp then
        plate.health.text:SetText(string.format("%s / %s | %s%%", Abbreviate(rhp), Abbreviate(rhpmax), ceil(hp/hpmax*100)))
      elseif setting == "deficit" and rhp then
        plate.health.text:SetText(string.format("-%s" .. (hasdata and "" or "%%"), Abbreviate(rhpmax - rhp)))
      else -- "percent" as fallback
        plate.health.text:SetText(string.format("%s%%", ceil(hp/hpmax*100)))
      end
    else
      plate.health.text:SetText()
    end

    local r, g, b, a = unpack(unitcolors[unittype])

    if unittype == "ENEMY_PLAYER" and C.nameplates["enemyclassc"] == "1" and class and RAID_CLASS_COLORS[class] then
      r, g, b, a = RAID_CLASS_COLORS[class].r, RAID_CLASS_COLORS[class].g, RAID_CLASS_COLORS[class].b, 1
    elseif unittype == "FRIENDLY_PLAYER" and C.nameplates["friendclassc"] == "1" and class and RAID_CLASS_COLORS[class] then
      r, g, b, a = RAID_CLASS_COLORS[class].r, RAID_CLASS_COLORS[class].g, RAID_CLASS_COLORS[class].b, 1
    end

    if superwow_active and unitstr and UnitIsTapped(unitstr) and not UnitIsTappedByPlayer(unitstr) then
      r, g, b, a = .5, .5, .5, .8
    end

    if superwow_active and cfg.barcombatstate then
      local guid = plate.parent:GetName(1) or ""
      local color = GetCombatStateColor(guid)

      if color then
        r, g, b, a = color.r, color.g, color.b, color.a
      end
    end

    if r ~= plate.cache.r or g ~= plate.cache.g or b ~= plate.cache.b then
      plate.health:SetStatusBarColor(r, g, b, a)
      plate.cache.r, plate.cache.g, plate.cache.b = r, g, b
    end

    if r + g + b ~= plate.cache.namecolor and unittype == "FRIENDLY_PLAYER" and C.nameplates["friendclassnamec"] == "1" and class and RAID_CLASS_COLORS[class] then
      plate.name:SetTextColor(r, g, b, a)
      plate.cache.namecolor = r + g + b
    end

    -- update combopoints
    for i=1, 5 do plate.combopoints[i]:Hide() end
    if target and C.nameplates.cpdisplay == "1" then
      for i=1, GetComboPoints("target") do plate.combopoints[i]:Show() end
    end

    -- update debuffs
    local index = 1

    if C.nameplates["showdebuffs"] == "1" then
      local verify = string.format("%s:%s", (name or ""), (level or ""))

      -- update cached debuffs
      if C.nameplates["guessdebuffs"] == "1" and unitstr then
        plate:CacheDebuffs(unitstr, verify)
      end

      -- update all debuff icons
      for i = 1, 16 do
        local effect, rank, texture, stacks, dtype, duration, timeleft

        if unitstr and C.nameplates.selfdebuff == "1" and libdebuff then
          effect, rank, texture, stacks, dtype, duration, timeleft = libdebuff:UnitOwnDebuff(unitstr, i)
        elseif unitstr and libdebuff then
          effect, rank, texture, stacks, dtype, duration, timeleft = libdebuff:UnitDebuff(unitstr, i)
        elseif plate.verify == verify then
          effect, rank, texture, stacks, dtype, duration, timeleft = plate:UnitDebuff(i)
        end

        if effect and texture and DebuffFilter(effect) then
          if not plate.debuffs[index] then
            CreateDebuffIcon(plate, index)
            UpdateDebuffConfig(plate, index)
          end

          plate.debuffs[index]:Show()
          plate.debuffs[index].icon:SetTexture(texture)
          plate.debuffs[index].icon:SetTexCoord(.078, .92, .079, .937)

          if stacks and stacks > 1 and C.nameplates.debuffs["showstacks"] == "1" then
            plate.debuffs[index].stacks:SetText(stacks)
            plate.debuffs[index].stacks:Show()
          else
            plate.debuffs[index].stacks:Hide()
          end

          if duration and timeleft and debuffdurations then
            -- Ensure cooldown flags are set
            local cooldown_anim = tonumber(C.nameplates.debuffanim) or 0
            if plate.debuffs[index].cd.pfCooldownStyleText == nil then
              plate.debuffs[index].cd.pfCooldownStyleText = 1
            end
            if plate.debuffs[index].cd.pfCooldownStyleAnimation == nil then
              plate.debuffs[index].cd.pfCooldownStyleAnimation = cooldown_anim
            end
            plate.debuffs[index].cd.pfCooldownType = "ALL"
            
            -- Set alpha based on animation config (0 = hide animation, 1 = show)
            plate.debuffs[index].cd:SetAlpha(cooldown_anim == 1 and 1 or 0)
            plate.debuffs[index].cd:Show()
            CooldownFrame_SetTimer(plate.debuffs[index].cd, GetTime() + timeleft - duration, duration, 1)
          end

          index = index + 1
        end
      end
    end

    -- hide remaining debuffs
    for i = index, 16 do
      if plate.debuffs[i] then
        plate.debuffs[i]:Hide()
      end
    end
  end

  nameplates.OnShow = function(frame)
    local frame = frame or this
    local nameplate = frame.nameplate

    -- Register GUID when plate becomes visible
    if superwow_active then
      local guid = frame:GetName(1)
      if guid then
        nameplate.cachedGuid = guid
        guidRegistry[guid] = frame
      end
    end

    nameplates:OnDataChanged(nameplate)
  end

  nameplates.OnUpdate = function(frame, state)
    local nameplate = frame.nameplate
    local now = state and state.now or GetTime()
    
    -- Update GUID registry (lightweight, needed for event routing)
    if superwow_active then
      local guid = frame:GetName(1)
      if guid and guid ~= nameplate.cachedGuid then
        if nameplate.cachedGuid and guidRegistry[nameplate.cachedGuid] == frame then
          guidRegistry[nameplate.cachedGuid] = nil
        end
        nameplate.cachedGuid = guid
        guidRegistry[guid] = frame
      end
    end
    
    -- Intelligent throttling based on target/castbar status
    local target = state and state.hasTarget and frame:GetAlpha() >= 0.99 or nil
    local isCasting = nameplate.castbar and nameplate.castbar:IsShown()
    
    local throttle
    if target or isCasting then
      throttle = 0.02  -- 50 FPS for target OR active castbar
    else
      throttle = 0.1   -- 10 FPS for others (healthbar updates)
    end
    
    -- Check for pending event updates (these bypass throttle for immediate response)
    local hasEventUpdate = nameplate.eventcache or nameplate.auraUpdate or nameplate.castUpdate or nameplate.targetUpdate or nameplate.comboUpdate
    
    -- Event updates bypass throttle
    if not hasEventUpdate and (nameplate.lasttick or 0) + throttle > now then return end
    nameplate.lasttick = now
    
    -- =========================================================================
    -- EVERYTHING BELOW RUNS AT THROTTLED RATE (50 FPS target, 10 FPS others)
    -- =========================================================================
    
    local update
    local original = nameplate.original
    local name = original.name:GetText()
    local mouseover = state and state.hasMouseover and original.glow:IsShown() or nil

    -- trigger queued event update
    if hasEventUpdate then
      nameplates:OnDataChanged(nameplate)
      nameplate.eventcache = nil
      nameplate.auraUpdate = nil
      nameplate.castUpdate = nil
      nameplate.targetUpdate = nil
      nameplate.comboUpdate = nil
    end

    -- =========================================================================
    -- VANILLA OVERLAP/CLICKTHROUGH HANDLING
    -- =========================================================================
    if pfUI.client <= 11200 then
      local useOverlap = C.nameplates["overlap"] == "1" or C.nameplates["vertical_offset"] ~= "0"
      local clickable = C.nameplates["clickthrough"] ~= "1"

      if not clickable then
        frame:EnableMouse(false)
        nameplate:EnableMouse(false)
      else
        local plate = useOverlap and nameplate or frame
        plate:EnableMouse(clickable)
      end

      if C.nameplates["overlap"] == "1" then
        if frame:GetWidth() > 1 then
          frame:SetWidth(1)
          frame:SetHeight(1)
        end
      else
        if not nameplate.dwidth then
          nameplate.dwidth = floor(nameplate:GetWidth() * UIParent:GetScale())
        end

        if floor(frame:GetWidth()) ~= nameplate.dwidth then
          frame:SetWidth(nameplate:GetWidth() * UIParent:GetScale())
          frame:SetHeight(nameplate:GetHeight() * UIParent:GetScale())
        end
      end

      local mouseEnabled = nameplate:IsMouseEnabled()
      if C.nameplates["clickthrough"] == "0" and C.nameplates["overlap"] == "1" and SpellIsTargeting() == mouseEnabled then
        nameplate:EnableMouse(not mouseEnabled)
      end
    end

    -- Cache strata changes
    if nameplate.istarget ~= target then
      nameplate.target_strata = nil
    end

    if target and nameplate.target_strata ~= 1 then
      nameplate:SetFrameStrata("LOW")
      nameplate.target_strata = 1
    elseif not target and nameplate.target_strata ~= 0 then
      nameplate:SetFrameStrata("BACKGROUND")
      nameplate.target_strata = 0
    end

    nameplate.istarget = target

    -- Set non-target plate alpha
    local configAlpha = cfg.notargalpha or 0.5
    local desiredAlpha = (target or not state.hasTarget) and 1 or configAlpha

    if nameplate.cachedAlpha ~= desiredAlpha then
      nameplate:SetAlpha(desiredAlpha)
      nameplate.cachedAlpha = desiredAlpha
    end

    -- queue update on visual target update
    if nameplate.cache.target ~= target then
      nameplate.cache.target = target
      update = true
    end

    -- queue update on visual mouseover update
    if nameplate.cache.mouseover ~= mouseover then
      nameplate.cache.mouseover = mouseover
      update = true
    end

    -- trigger update when unit was found
    if nameplate.wait_for_scan and GetUnitData(name, true) then
      nameplate.wait_for_scan = nil
      update = true
    end

    -- trigger update when name color changed (includes combat state check)
    local r, g, b = original.name:GetTextColor()
    local inCombatWithPlayer = false
    if superwow_active and cfg.namefightcolor then
      local guid = nameplate.cachedGuid
      if guid then
        inCombatWithPlayer = UnitAffectingCombat(guid) and UnitAffectingCombat("player")
      end
    end
    
    if r + g + b ~= nameplate.cache.namecolor or (cfg.namefightcolor and nameplate.cache.inCombat ~= inCombatWithPlayer) then
      nameplate.cache.namecolor = r + g + b
      nameplate.cache.inCombat = inCombatWithPlayer

      if cfg.namefightcolor then
        if (r > .9 and g < .2 and b < .2) or inCombatWithPlayer then
          nameplate.name:SetTextColor(1,0.4,0.2,1)
        else
          nameplate.name:SetTextColor(r,g,b,1)
        end
      else
        nameplate.name:SetTextColor(1,1,1,1)
      end
      update = true
    end

    -- trigger update when level color changed
    local r, g, b = original.level:GetTextColor()
    r, g, b = r + .3, g + .3, b + .3
    if r + g + b ~= nameplate.cache.levelcolor then
      nameplate.cache.levelcolor = r + g + b
      nameplate.level:SetTextColor(r,g,b,1)
      update = true
    end

    -- scan for debuff timeouts
    if nameplate.debuffcache then
      for id, data in pairs(nameplate.debuffcache) do
        if ( not data.stop or data.stop < now ) and not data.empty then
          data.empty = true
          update = true
        end
      end
    end

    -- use timer based updates
    if not nameplate.tick or nameplate.tick < now then
      update = true
    end

    -- run full updates if required
    if update then
      nameplates:OnDataChanged(nameplate)
      nameplate.tick = now + .5
    end

    -- Zoom animation
    if target and cfg.targetzoom then
      if not nameplate.health.zoomed then
        local zoomval = cfg.zoomval
        local wc = cfg.width * zoomval
        local hc = cfg.heighthealth * (zoomval * .9)
        nameplate.health.targetWidth = wc
        nameplate.health.targetHeight = hc
      end
      
      local w, h = nameplate.health:GetWidth(), nameplate.health:GetHeight()
      local wc, hc = nameplate.health.targetWidth, nameplate.health.targetHeight
      
      if wc and hc then
        if wc > w + 0.5 then
          nameplate.health:SetWidth(w*1.05)
          nameplate.health.zoomTransition = true
        elseif hc > h + 0.5 then
          nameplate.health:SetHeight(h*1.05)
          nameplate.health.zoomTransition = true
        else
          if nameplate.health.zoomTransition then
            nameplate.health:SetWidth(wc)
            nameplate.health:SetHeight(hc)
            nameplate.health.zoomTransition = nil
          end
          nameplate.health.zoomed = true
        end
      end
    elseif nameplate.health.zoomed or nameplate.health.zoomTransition then
      local w, h = nameplate.health:GetWidth(), nameplate.health:GetHeight()
      local wc = cfg.width
      local hc = cfg.heighthealth

      if w > wc + 0.5 then
        nameplate.health:SetWidth(w*.95)
      elseif h > hc + 0.5 then
        nameplate.health:SetHeight(h*0.95)
      else
        nameplate.health:SetWidth(wc)
        nameplate.health:SetHeight(hc)
        nameplate.health.zoomTransition = nil
        nameplate.health.zoomed = nil
        nameplate.health.targetWidth = nil
        nameplate.health.targetHeight = nil
      end
    end

    -- queue update on visual mouseover update
    if nameplate.cache.mouseover ~= mouseover then
      nameplate.cache.mouseover = mouseover
      update = true
    end

    -- trigger update when unit was found
    if nameplate.wait_for_scan and GetUnitData(name, true) then
      nameplate.wait_for_scan = nil
      update = true
    end

    -- trigger update when level color changed
    local r, g, b = original.level:GetTextColor()
    r, g, b = r + .3, g + .3, b + .3
    if r + g + b ~= nameplate.cache.levelcolor then
      nameplate.cache.levelcolor = r + g + b
      nameplate.level:SetTextColor(r,g,b,1)
      update = true
    end

    -- scan for debuff timeouts
    if nameplate.debuffcache then
      for id, data in pairs(nameplate.debuffcache) do
        if ( not data.stop or data.stop < now ) and not data.empty then
          data.empty = true
          update = true
        end
      end
    end

    -- use timer based updates
    if not nameplate.tick or nameplate.tick < now then
      update = true
    end

    -- run full updates if required
    if update then
      nameplates:OnDataChanged(nameplate)
      nameplate.tick = now + .5
    end

    -- OPTIMIZED: UNIT_CASTEVENT implementation
    -- Use multiple checks for target detection (target variable, istarget flag, or zoomed state)
    local isTargetPlate = target or nameplate.istarget or (nameplate.health and nameplate.health.zoomed)
    if cfg.showcastbar and ( not cfg.targetcastbar or isTargetPlate ) then
      local unitstr = nil
      local targetGUID = nil
      
      -- Get GUID for CastEvents lookup - use cached GUID when available
      if isTargetPlate then
        targetGUID = state and state.targetGuid
      end
      
      -- Use cached GUID for non-target plates
      if superwow_active and not isTargetPlate then
        unitstr = nameplate.cachedGuid
      end
      
      -- Check event-based cast cache first (use GUID)
      local castInfo = (targetGUID and CastEvents[targetGUID]) or (unitstr and CastEvents[unitstr])
      
      if castInfo and castInfo.spellID then
        -- Check if cast is still valid
        if castInfo.startTime + castInfo.duration < now then
          wipe(castInfo)
          nameplate.castbar:Hide()
        elseif castInfo.event == "CAST" or castInfo.event == "FAIL" then
          wipe(castInfo)
          nameplate.castbar:Hide()
        else
          -- Update from cached event data
          nameplate.castbar:SetMinMaxValues(castInfo.startTime, castInfo.endTime)
          
          local barValue
          if castInfo.event == "CHANNEL" then
            barValue = castInfo.startTime + (castInfo.endTime - now)
          else
            barValue = now
          end
          
          nameplate.castbar:SetValue(barValue)
          nameplate.castbar.text:SetText(round(now - castInfo.startTime, 1))
          
          if cfg.spellname then
            nameplate.castbar.spell:SetText(castInfo.spellName)
          else
            nameplate.castbar.spell:SetText("")
          end
          
          if castInfo.icon then
            nameplate.castbar.icon.tex:SetTexture(castInfo.icon)
            nameplate.castbar.icon.tex:SetTexCoord(.1,.9,.1,.9)
          end
          
          nameplate.castbar:Show()
        end
      else
        -- Fallback to API calls if no event data (for non-SuperWoW or target)
        local channel, cast, nameSubtext, text, texture, startTime, endTime, isTradeSkill
        
        if isTargetPlate and UnitExists("target") then
          cast, nameSubtext, text, texture, startTime, endTime, isTradeSkill = UnitCastingInfo("target")
          if not cast then 
            channel, nameSubtext, text, texture, startTime, endTime, isTradeSkill = UnitChannelInfo("target")
          end
        end
        
        if not cast and not channel then
          nameplate.castbar:Hide()
        else
          local effect = cast or channel
          local duration = endTime - startTime
          local max = duration / 1000
          local cur = GetTime() - startTime / 1000

          if channel then cur = max + startTime/1000 - GetTime() end

          nameplate.castbar:SetMinMaxValues(0, duration/1000)
          nameplate.castbar:SetValue(cur)
          nameplate.castbar.text:SetText(round(cur,1))
          
          if C.nameplates.spellname == "1" then
            nameplate.castbar.spell:SetText(effect)
          else
            nameplate.castbar.spell:SetText("")
          end
          
          nameplate.castbar:Show()

          if texture then
            nameplate.castbar.icon.tex:SetTexture(texture)
            nameplate.castbar.icon.tex:SetTexCoord(.1,.9,.1,.9)
          end
        end
      end
    else
      nameplate.castbar:Hide()
    end
  end

  -- set nameplate game settings
  nameplates.SetGameVariables = function()
    -- update visibility (hostile)
    if C.nameplates["showhostile"] == "1" then
      _G.NAMEPLATES_ON = true
      ShowNameplates()
    else
      _G.NAMEPLATES_ON = nil
      HideNameplates()
    end

    -- update visibility (hostile)
    if C.nameplates["showfriendly"] == "1" then
      _G.FRIENDNAMEPLATES_ON = true
      ShowFriendNameplates()
    else
      _G.FRIENDNAMEPLATES_ON = nil
      HideFriendNameplates()
    end
  end

  nameplates:SetGameVariables()

  nameplates.UpdateConfig = function()
    -- Refresh config cache for all cfg.* values
    CacheConfig()
    
    -- Update debuffdurations from appearance config
    debuffdurations = C.appearance.cd.debuffs == "1" and true or nil
    
    -- update debuff filters
    DebuffFilterPopulate()

    -- Check friendly zone state when config changes
    local disableHostile = C.nameplates["disable_hostile_in_friendly"] == "1"
    local disableFriendly = C.nameplates["disable_friendly_in_friendly"] == "1"
    local pvpType = GetZonePVPInfo()
    local nowFriendly = (pvpType == "friendly")
    
    if nowFriendly and (disableHostile or disableFriendly) then
      if not inFriendlyZone then
        -- Just entered friendly zone or feature just enabled
        inFriendlyZone = true
        savedHostileState = C.nameplates["showhostile"]
        savedFriendlyState = C.nameplates["showfriendly"]
      end
      
      -- Apply current settings based on options
      if disableHostile then
        _G.NAMEPLATES_ON = nil
        HideNameplates()
      else
        -- Restore hostile if option is off but we're in friendly zone
        if savedHostileState == "1" then
          _G.NAMEPLATES_ON = true
          ShowNameplates()
        end
      end
      
      if disableFriendly then
        _G.FRIENDNAMEPLATES_ON = nil
        HideFriendNameplates()
      else
        -- Restore friendly if option is off but we're in friendly zone
        if savedFriendlyState == "1" then
          _G.FRIENDNAMEPLATES_ON = true
          ShowFriendNameplates()
        end
      end
      
      return -- Don't call SetGameVariables
    elseif inFriendlyZone and not (disableHostile or disableFriendly) then
      -- Both features disabled while in friendly zone - restore state
      inFriendlyZone = false
      
      if savedHostileState == "1" then
        C.nameplates["showhostile"] = savedHostileState
      end
      
      if savedFriendlyState == "1" then
        C.nameplates["showfriendly"] = savedFriendlyState
      end
      
      savedHostileState = nil
      savedFriendlyState = nil
      -- Fall through to SetGameVariables to restore nameplates
    end

    -- update nameplate visibility
    nameplates:SetGameVariables()

    -- apply all config changes
    for plate in pairs(registry) do
      nameplates.OnConfigChange(plate)
    end
  end

  if pfUI.client <= 11200 then
    -- handle vanilla only settings
    local hookOnConfigChange = nameplates.OnConfigChange
    nameplates.OnConfigChange = function(self)
      hookOnConfigChange(self)

      local parent = self
      local nameplate = self.nameplate
      local plate = (C.nameplates["overlap"] == "1" or C.nameplates["vertical_offset"] ~= "0") and nameplate or parent

      -- disable all clicks for now
      parent:EnableMouse(false)
      nameplate:EnableMouse(false)

      -- adjust vertical offset
      if C.nameplates["vertical_offset"] ~= "0" then
        nameplate:SetPoint("TOP", parent, "TOP", 0, tonumber(C.nameplates["vertical_offset"]))
      end

      -- replace clickhandler
      if C.nameplates["overlap"] == "1" or C.nameplates["vertical_offset"] ~= "0" then
        plate:SetScript("OnClick", function() parent:Click() end)
      end

      -- enable mouselook on rightbutton down
      if C.nameplates["rightclick"] == "1" then
        plate:SetScript("OnMouseDown", nameplates.mouselook.OnMouseDown)
      else
        plate:SetScript("OnMouseDown", nil)
      end
    end

    local hookOnDataChanged = nameplates.OnDataChanged
    nameplates.OnDataChanged = function(self, nameplate)
      hookOnDataChanged(self, nameplate)

      -- make sure to keep mouse events disabled on parent nameplate
      if (C.nameplates["overlap"] == "1" or C.nameplates["vertical_offset"] ~= "0") then
        nameplate.parent:EnableMouse(false)
      end
    end

    -- enable mouselook on rightbutton down
    nameplates.mouselook = CreateFrame("Frame", nil, UIParent)
    nameplates.mouselook.time = nil
    nameplates.mouselook.frame = nil
    nameplates.mouselook.OnMouseDown = function()
      if arg1 and arg1 == "RightButton" then
        MouselookStart()

        -- start detection of the rightclick emulation
        nameplates.mouselook.time = GetTime()
        nameplates.mouselook.frame = this
        nameplates.mouselook:Show()
      end
    end

    nameplates.mouselook:SetScript("OnUpdate", function()
      -- break here if nothing to do
      if not this.time or not this.frame then
        this:Hide()
        return
      end

      -- if threshold is reached (0.5 second) no click action will follow
      if not IsMouselooking() and this.time + tonumber(C.nameplates["clickthreshold"]) < GetTime() then
        this:Hide()
        return
      end

      -- run a usual nameplate rightclick action
      if not IsMouselooking() then
        this.frame:Click("LeftButton")
        if UnitCanAttack("player", "target") and not nameplates.combat.inCombat then AttackTarget() end
        this:Hide()
        return
      end
    end)
  end

  pfUI.nameplates = nameplates
end)