-- load pfUI environment
setfenv(1, pfUI:GetEnvironment())

--[[ libdebuff ]]--
-- A pfUI library that detects and saves all ongoing debuffs of players, NPCs and enemies.
-- The functions UnitDebuff is exposed to the modules which allows to query debuffs like you
-- would on later expansions.
--
--  libdebuff:UnitDebuff(unit, id)
--    Returns debuff informations on the given effect of the specified unit.
--    name, rank, texture, stacks, dtype, duration, timeleft

-- return instantly if we're not on a vanilla client
if pfUI.client > 11200 then return end

-- return instantly when another libdebuff is already active
if pfUI.api.libdebuff then return end

-- fix a typo (missing $) in ruRU capture index
if GetLocale() == "ruRU" then
  SPELLREFLECTSELFOTHER = gsub(SPELLREFLECTSELFOTHER, "%%2s", "%%2%$s")
end

local libdebuff = CreateFrame("Frame", "pfdebuffsScanner", UIParent)
local scanner = libtipscan:GetScanner("libdebuff")
local _, class = UnitClass("player")
local lastspell

-- Nampower Support
local hasNampower = GetNampowerVersion ~= nil

-- Nampower Debuff Storage für Target Debuff Bar "Only Show Own"
-- [targetGUID][spellName] = {startTime, duration, texture, rank}
pfUI.libdebuff_own = pfUI.libdebuff_own or {}
local ownDebuffs = pfUI.libdebuff_own

-- Own Debuff Slots: [targetGUID][slot] = spellName (nur eigene!)
pfUI.libdebuff_own_slots = pfUI.libdebuff_own_slots or {}
local ownSlots = pfUI.libdebuff_own_slots

-- Cleveroids Compatibility: spellID-indexed structure
-- [targetGUID][spellID] = {start, duration, caster, stacks}
pfUI.libdebuff_objects_guid = pfUI.libdebuff_objects_guid or {}
local objectsByGuid = pfUI.libdebuff_objects_guid

-- Combo Point Tracking für Druid Finisher
local currentComboPoints = 0
local lastSpentComboPoints = 0
local lastSpentTime = 0

-- Carnage Talent Rank (0-2)
local carnageRank = 0

-- Player GUID
local playerGUID = nil

-- Helper: Get Player GUID
local function GetPlayerGUID()
  if not playerGUID and UnitExists then
    local _, guid = UnitExists("player")
    playerGUID = guid
  end
  return playerGUID
end

-- Helper: Get Stored Combo Points
local function GetStoredComboPoints()
  if lastSpentComboPoints > 0 and (GetTime() - lastSpentTime) < 1 then
    return lastSpentComboPoints
  end
  return 0
end

-- Helper: Update Carnage Talent
local function UpdateCarnageRank()
  if class ~= "DRUID" then return end
  local _, _, _, _, rank = GetTalentInfo(2, 17)  -- Tab 2 (Feral), Slot 17
  carnageRank = rank or 0
end

-- Speichert die Ranks der zuletzt gecasteten Spells (bleibt länger als pending)
local lastCastRanks = {}

-- Speichert Spells die gefailed sind (miss/dodge/parry/etc.) für 1 Sekunde
local lastFailedSpells = {}

-- Prüft ob ein Spell kürzlich gefailed ist (öffentliche Funktion für andere Module)
function libdebuff:DidSpellFail(spell)
  if not spell then return false end
  local data = lastFailedSpells[spell]
  if data and (GetTime() - data.time) < 1 then
    return true
  end
  return false
end

-- Shared Debuffs: Diese werden von allen Spielern geteilt (nur einer kann drauf sein)
-- Timer darf von anderen Spielern aktualisiert werden
local sharedDebuffs = {
  -- Warrior
  ["Sunder Armor"] = true,
  ["Demoralizing Shout"] = true,
  ["Thunder Clap"] = true,
  
  -- Rogue
  ["Expose Armor"] = true,
  
  -- Druid
  ["Faerie Fire"] = true,
  ["Faerie Fire (Feral)"] = true,
  
  -- Hunter
  ["Hunter's Mark"] = true,
  
  -- Warlock Curses (nur eine pro Typ kann auf Target sein)
  ["Curse of Weakness"] = true,
  ["Curse of Recklessness"] = true,
  ["Curse of the Elements"] = true,
  ["Curse of Shadow"] = true,
  ["Curse of Tongues"] = true,
  ["Curse of Exhaustion"] = true,
  -- NICHT: Curse of Agony, Curse of Doom (jeder Warlock hat seinen eigenen!)
  
  -- Priest
  ["Shadow Weaving"] = true,
  
  -- Mage
  ["Winter's Chill"] = true,
  
  -- Paladin Judgements
  ["Judgement of Wisdom"] = true,
  ["Judgement of Light"] = true,
  ["Judgement of the Crusader"] = true,
  ["Judgement of Justice"] = true,
}

function libdebuff:GetDuration(effect, rank)
  if L["debuffs"][effect] then
    local rank = rank and tonumber((string.gsub(rank, RANK, ""))) or 0
    local rank = L["debuffs"][effect][rank] and rank or libdebuff:GetMaxRank(effect)
    local duration = L["debuffs"][effect][rank]

    if effect == L["dyndebuffs"]["Rupture"] then
      -- Rupture: +2 sec per combo point
      local cp = GetComboPoints() or 0
      if cp == 0 then cp = GetStoredComboPoints() end
      duration = duration + cp * 2
    elseif effect == L["dyndebuffs"]["Kidney Shot"] then
      -- Kidney Shot: +1 sec per combo point
      local cp = GetComboPoints() or 0
      if cp == 0 then cp = GetStoredComboPoints() end
      duration = duration + cp * 1
    elseif effect == "Rip" or effect == L["dyndebuffs"]["Rip"] then
      -- Rip: 8s base + 2s per combo point
      local cp = GetComboPoints() or 0
      if cp == 0 then cp = GetStoredComboPoints() end
      duration = 8 + cp * 2
    elseif effect == L["dyndebuffs"]["Demoralizing Shout"] then
      -- Booming Voice: 10% per talent
      local _,_,_,_,count = GetTalentInfo(2,1)
      if count and count > 0 then duration = duration + ( duration / 100 * (count*10)) end
    elseif effect == L["dyndebuffs"]["Shadow Word: Pain"] then
      -- Improved Shadow Word: Pain: +3s per talent
      local _,_,_,_,count = GetTalentInfo(3,4)
      if count and count > 0 then duration = duration + count * 3 end
    elseif effect == L["dyndebuffs"]["Frostbolt"] then
      -- Permafrost: +1s per talent
      local _,_,_,_,count = GetTalentInfo(3,7)
      if count and count > 0 then duration = duration + count end
    elseif effect == L["dyndebuffs"]["Gouge"] then
      -- Improved Gouge: +.5s per talent
      local _,_,_,_,count = GetTalentInfo(3,3)
      if count and count > 0 then duration = duration + (count*.5) end
    end
    return duration
  else
    return 0
  end
end

function libdebuff:UpdateDuration(unit, unitlevel, effect, duration)
  if not unit or not effect or not duration then return end
  unitlevel = unitlevel or 0

  if libdebuff.objects[unit] and libdebuff.objects[unit][unitlevel] and libdebuff.objects[unit][unitlevel][effect] then
    libdebuff.objects[unit][unitlevel][effect].duration = duration
  end
end

function libdebuff:GetMaxRank(effect)
  local max = 0
  for id in pairs(L["debuffs"][effect]) do
    if id > max then max = id end
  end
  return max
end

function libdebuff:UpdateUnits()
  if not pfUI.uf or not pfUI.uf.target then return end
  pfUI.uf:RefreshUnit(pfUI.uf.target, "aura")
end

function libdebuff:AddPending(unit, unitlevel, effect, duration, caster, rank)
  if not unit or duration <= 0 then return end
  if not L["debuffs"][effect] then return end
  if libdebuff.pending[3] then return end

  libdebuff.pending[1] = unit
  libdebuff.pending[2] = unitlevel or 0
  libdebuff.pending[3] = effect
  libdebuff.pending[4] = duration
  libdebuff.pending[5] = caster
  libdebuff.pending[6] = rank

  QueueFunction(libdebuff.PersistPending)
end

function libdebuff:RemovePending()
  libdebuff.pending[1] = nil
  libdebuff.pending[2] = nil
  libdebuff.pending[3] = nil
  libdebuff.pending[4] = nil
  libdebuff.pending[5] = nil
  libdebuff.pending[6] = nil
end

function libdebuff:PersistPending(effect)
  if not libdebuff.pending[3] then return end

  if libdebuff.pending[3] == effect or ( effect == nil and libdebuff.pending[3] ) then
    local p1, p2, p3, p4, p5, p6 = libdebuff.pending[1], libdebuff.pending[2], libdebuff.pending[3], libdebuff.pending[4], libdebuff.pending[5], libdebuff.pending[6]
    libdebuff.AddEffect(libdebuff, p1, p2, p3, p4, p5, p6)
  end

  libdebuff:RemovePending()
end

function libdebuff:RevertLastAction()
  if lastspell and lastspell.effect then
  end
  lastspell.start = lastspell.start_old
  lastspell.start_old = nil
  libdebuff:UpdateUnits()
end

function libdebuff:AddEffect(unit, unitlevel, effect, duration, caster, rank)
  -- WORKAROUND: Wenn rank nil ist und wir einen eigenen Cast haben, hole rank aus lastCastRanks
  if not rank and caster == "player" and effect then
    -- Erst aus pending versuchen
    if libdebuff.pending[3] == effect and libdebuff.pending[6] then
      rank = libdebuff.pending[6]
    -- Dann aus lastCastRanks (bleibt länger)
    elseif lastCastRanks[effect] and (GetTime() - lastCastRanks[effect].time) < 2 then
      rank = lastCastRanks[effect].rank
    end
  end
  
  if not unit or not effect then return end
  
  -- SCHUTZ: Wenn der Spell gerade gefailed ist (miss/dodge/parry/etc.), nicht anwenden
  -- Nur für eigene Spells prüfen, nicht für andere Spieler
  if caster == "player" and libdebuff:DidSpellFail(effect) then
    return  -- Spell hat nicht getroffen, keinen Timer setzen
  end
  
  unitlevel = unitlevel or 0
  if not libdebuff.objects[unit] then libdebuff.objects[unit] = {} end
  if not libdebuff.objects[unit][unitlevel] then libdebuff.objects[unit][unitlevel] = {} end
  if not libdebuff.objects[unit][unitlevel][effect] then libdebuff.objects[unit][unitlevel][effect] = {} end

  local existing = libdebuff.objects[unit][unitlevel][effect]
  local now = GetTime()
  
  -- Wenn kein Caster übergeben wurde, behalte den existierenden (wichtig für Refresh-Mechaniken wie Ferocious Bite)
  if not caster and existing.caster then
    caster = existing.caster
  end
  
  -- Wenn kein Rank übergeben wurde, behalte den existierenden
  if not rank and existing.rank then
    rank = existing.rank
  end
  
  -- Prüfe ob ein existierender Debuff noch aktiv ist
  local existingIsActive = existing.start and existing.duration and (existing.start + existing.duration) > now
  
  -- SCHUTZ: Wenn MEIN Debuff aktiv ist, darf ein anderer Spieler ihn NICHT überschreiben
  -- AUSNAHME: Shared Debuffs (Sunder Armor, Curses, etc.) dürfen aktualisiert werden
  if existingIsActive and existing.caster == "player" and caster ~= "player" then
    if not sharedDebuffs[effect] then
      return  -- Blockiere das Update
    end
  end
  
  -- Rank-Prüfung wenn beide vom Player sind und beide Ranks bekannt sind
  if existingIsActive and existing.rank and rank and existing.caster == "player" and caster == "player" then
    DEFAULT_CHAT_FRAME:AddMessage(string.format("|cffff9900[RANK CHECK]|r %s: existing=%d new=%d active=%s", effect, existing.rank, rank, tostring(existingIsActive)))
    -- Niedrigerer Rank darf höheren NICHT überschreiben
    if rank < existing.rank then
      DEFAULT_CHAT_FRAME:AddMessage(string.format("|cffff0000[BLOCKED]|r Rank %d cannot overwrite Rank %d", rank, existing.rank))
      return  -- Blockiere das Update
    end
    DEFAULT_CHAT_FRAME:AddMessage(string.format("|cff00ff00[ALLOWED]|r Rank %d can overwrite Rank %d", rank, existing.rank))
    -- Gleicher oder höherer Rank darf überschreiben (Timer erneuern)
  end

  -- save current effect as lastspell
  lastspell = existing

  existing.effect = effect
  existing.start_old = existing.start
  existing.start = now
  existing.duration = duration or libdebuff:GetDuration(effect)
  existing.caster = caster
  existing.rank = rank
  
  DEFAULT_CHAT_FRAME:AddMessage(string.format("|cff00ff00[AddEffect SAVED]|r objects[%s][%d][%s] = rank=%d duration=%.1f", unit, unitlevel, effect, rank or 0, existing.duration))

  libdebuff:UpdateUnits()
end

-- scan for debuff application
libdebuff:RegisterEvent("CHAT_MSG_SPELL_PERIODIC_HOSTILEPLAYER_DAMAGE")
libdebuff:RegisterEvent("CHAT_MSG_SPELL_PERIODIC_CREATURE_DAMAGE")
libdebuff:RegisterEvent("CHAT_MSG_SPELL_FAILED_LOCALPLAYER")
libdebuff:RegisterEvent("CHAT_MSG_SPELL_SELF_DAMAGE")
libdebuff:RegisterEvent("PLAYER_TARGET_CHANGED")
libdebuff:RegisterEvent("SPELLCAST_STOP")
libdebuff:RegisterEvent("UNIT_AURA")

-- register seal handler
if class == "PALADIN" then
  libdebuff:RegisterEvent("CHAT_MSG_COMBAT_SELF_HITS")
end

-- Remove Pending
libdebuff.rp = { SPELLIMMUNESELFOTHER, IMMUNEDAMAGECLASSSELFOTHER,
  SPELLMISSSELFOTHER, SPELLRESISTSELFOTHER, SPELLEVADEDSELFOTHER,
  SPELLDODGEDSELFOTHER, SPELLDEFLECTEDSELFOTHER, SPELLREFLECTSELFOTHER,
  SPELLPARRIEDSELFOTHER, SPELLLOGABSORBSELFOTHER, SPELLFAILCASTSELF }

libdebuff.objects = {}
libdebuff.pending = {}

-- Gather Data by Events
libdebuff:SetScript("OnEvent", function()
  -- paladin seal refresh
  if event == "CHAT_MSG_COMBAT_SELF_HITS" then
    local hit = cmatch(arg1, COMBATHITSELFOTHER)
    local crit = cmatch(arg1, COMBATHITCRITSELFOTHER)
    if hit or crit then
      for seal in L["judgements"] do
        local name = UnitName("target")
        local level = UnitLevel("target")
        if name and libdebuff.objects[name] then
          if level and libdebuff.objects[name][level] and libdebuff.objects[name][level][seal] then
            libdebuff:AddEffect(name, level, seal)
          elseif libdebuff.objects[name][0] and libdebuff.objects[name][0][seal] then
            libdebuff:AddEffect(name, 0, seal)
          end
        end
      end
    end

  -- Add Combat Log
  elseif event == "CHAT_MSG_SPELL_PERIODIC_HOSTILEPLAYER_DAMAGE" or event == "CHAT_MSG_SPELL_PERIODIC_CREATURE_DAMAGE" then
    local unit, effect = cmatch(arg1, AURAADDEDOTHERHARMFUL)
    if unit and effect then
      local unitlevel = UnitName("target") == unit and UnitLevel("target") or 0
      if not libdebuff.objects[unit] or not libdebuff.objects[unit][unitlevel] or not libdebuff.objects[unit][unitlevel][effect] then
        libdebuff:AddEffect(unit, unitlevel, effect, nil, nil, nil)  -- Explizit nil für rank
      end
    end

  -- Add Missing Buffs by Iteration
  elseif ( event == "UNIT_AURA" and arg1 == "target" ) or event == "PLAYER_TARGET_CHANGED" then
    for i=1, 16 do
      local effect, rank, texture, stacks, dtype, duration, timeleft = libdebuff:UnitDebuff("target", i)

      -- abort when no further debuff was found
      if not texture then return end

      if texture and effect and effect ~= "" then
        -- don't overwrite existing timers
        local unitlevel = UnitLevel("target") or 0
        local unit = UnitName("target")
        if not libdebuff.objects[unit] or not libdebuff.objects[unit][unitlevel] or not libdebuff.objects[unit][unitlevel][effect] then
          libdebuff:AddEffect(unit, unitlevel, effect, nil, nil, nil)  -- Explizit nil für rank
        end
      end
    end

  -- Update Pending Spells und tracke failed spells
  elseif event == "CHAT_MSG_SPELL_FAILED_LOCALPLAYER" or event == "CHAT_MSG_SPELL_SELF_DAMAGE" then
    -- Prüfe ob ein Spell gefailed ist und speichere ihn
    for _, msg in pairs(libdebuff.rp) do
      local effect = cmatch(arg1, msg)
      if effect then
        -- Speichere den failed spell für 1 Sekunde
        lastFailedSpells[effect] = { time = GetTime() }
        
        -- Bestehende Logik: Remove pending spell
        if libdebuff.pending[3] == effect then
          libdebuff:RemovePending()
          return
        elseif lastspell and lastspell.start_old and lastspell.effect == effect then
          -- late removal of debuffs (e.g hunter arrows as they hit late)
          libdebuff:RevertLastAction()
          return
        end
      end
    end
  elseif event == "SPELLCAST_STOP" then
    libdebuff:PersistPending()
  end
end)

-- Gather Data by User Actions
hooksecurefunc("CastSpell", function(id, bookType)
  local rawEffect, rank = libspell.GetSpellInfo(id, bookType)
  local duration = libdebuff:GetDuration(rawEffect, rank)
  local rankNum = 0
  if rank then
    local _, _, num = string.find(rank, "(%d+)")
    rankNum = num and tonumber(num) or 0
  end
  
  -- Speichere rank für später (bleibt 2 Sekunden)
  if rawEffect and rankNum > 0 then
    lastCastRanks[rawEffect] = { rank = rankNum, time = GetTime() }
  end
  
  libdebuff:AddPending(UnitName("target"), UnitLevel("target"), rawEffect, duration, "player", rankNum)
end)

hooksecurefunc("CastSpellByName", function(effect, target)
  local rawEffect, rank = libspell.GetSpellInfo(effect)
  local duration = libdebuff:GetDuration(rawEffect, rank)
  local rankNum = 0
  if rank then
    local _, _, num = string.find(rank, "(%d+)")
    rankNum = num and tonumber(num) or 0
  end
  
  -- Speichere rank für später (bleibt 2 Sekunden)
  if rawEffect and rankNum > 0 then
    lastCastRanks[rawEffect] = { rank = rankNum, time = GetTime() }
  end
  
  libdebuff:AddPending(UnitName("target"), UnitLevel("target"), rawEffect, duration, "player", rankNum)
end)

hooksecurefunc("UseAction", function(slot, target, button)
  if GetActionText(slot) or not IsCurrentAction(slot) then return end
  scanner:SetAction(slot)
  local rawEffect, rank = scanner:Line(1)
  local duration = libdebuff:GetDuration(rawEffect, rank)
  local rankNum = 0
  if rank then
    local _, _, num = string.find(rank, "(%d+)")
    rankNum = num and tonumber(num) or 0
  end
  
  -- Speichere rank für später (bleibt 2 Sekunden)
  if rawEffect and rankNum > 0 then
    lastCastRanks[rawEffect] = { rank = rankNum, time = GetTime() }
  end
  
  libdebuff:AddPending(UnitName("target"), UnitLevel("target"), rawEffect, duration, "player", rankNum)
end)

function libdebuff:UnitDebuff(unit, id)
  local unitname = UnitName(unit)
  local unitlevel = UnitLevel(unit)
  local texture, stacks, dtype = UnitDebuff(unit, id)
  local duration, timeleft = nil, -1
  local rank = nil -- no backport
  local caster = nil -- experimental
  local effect

  if texture then
    scanner:SetUnitDebuff(unit, id)
    effect = scanner:Line(1) or ""
  end

  -- Nampower Check: Nutze ownSlots für präzises Slot Matching!
  if hasNampower and UnitExists and effect then
    local _, guid = UnitExists(unit)
    
    -- Check: Ist DIESER SLOT von uns?
    if guid and ownSlots[guid] and ownSlots[guid][id] == effect then
      -- Dieser Slot ist definitiv von uns!
      if ownDebuffs[guid] and ownDebuffs[guid][effect] then
        local data = ownDebuffs[guid][effect]
        local remaining = (data.startTime + data.duration) - GetTime()
        
        if remaining > 0 then
          duration = data.duration
          timeleft = remaining
          caster = "player"
          rank = data.rank
        end
      end
    end
    -- Wenn nicht in ownSlots[guid][id]: KEIN Timer (nicht unser Slot!)
  else
    -- Fallback: Alte Methode (nur wenn Nampower NICHT aktiv)
    local data = libdebuff.objects[unitname] and libdebuff.objects[unitname][unitlevel]
    data = data or libdebuff.objects[unitname] and libdebuff.objects[unitname][0]

    if data and data[effect] then
      if data[effect].duration and data[effect].start and data[effect].duration + data[effect].start > GetTime() then
        -- read valid debuff data
        duration = data[effect].duration
        timeleft = duration + data[effect].start - GetTime()
        caster = data[effect].caster
      else
        -- clean up invalid values
        data[effect] = nil
      end
    end
  end

  return effect, rank, texture, stacks, dtype, duration, timeleft, caster
end

local cache = {}
function libdebuff:UnitOwnDebuff(unit, id)
  -- Mit Nampower: Lese direkt aus ownDebuffs (kein Scanning!)
  if hasNampower and UnitExists then
    local _, guid = UnitExists(unit)
    if guid and ownDebuffs[guid] then
      -- Clean cache
      for k, v in pairs(cache) do cache[k] = nil end
      
      local count = 1
      for spellName, data in pairs(ownDebuffs[guid]) do
        -- Check if still active
        local timeleft = (data.startTime + data.duration) - GetTime()
        if timeleft > 0 then
          cache[spellName] = true
          
          if count == id then
            local texture = data.texture or pfUI_cache.buff_icons[spellName] or "Interface\\Icons\\Spell_Shadow_CurseOfTongues"
            local rank = data.rank
            local stacks = 1
            local dtype = nil -- Wird von buffwatch nicht gebraucht
            
            return spellName, rank, texture, stacks, dtype, data.duration, timeleft, "player"
          else
            count = count + 1
          end
        else
          -- Cleanup expired
          ownDebuffs[guid][spellName] = nil
        end
      end
    end
    -- Kein Fallback mehr! Wenn Nampower aktiv ist, zeigen wir NUR ownDebuffs
    return nil
  end
  
  -- Fallback NUR wenn Nampower NICHT aktiv (sollte nicht passieren)
  for k, v in pairs(cache) do cache[k] = nil end

  local count = 1
  for i=1,16 do
    local effect, rank, texture, stacks, dtype, duration, timeleft, caster = libdebuff:UnitDebuff(unit, i)
    if effect and not cache[effect] and caster and caster == "player" then
      cache[effect] = true

      if count == id then
        return effect, rank, texture, stacks, dtype, duration, timeleft, caster
      else
        count = count + 1
      end
    end
  end
end

-- UnitBuff: Returns buff data from libdebuff.objects (respects Rank Protection!)
local lastUnitBuffDebug = {}
function libdebuff:UnitBuff(unit, id)
  local unitname = UnitName(unit)
  local unitlevel = UnitLevel(unit)
  local texture, stacks = UnitBuff(unit, id)
  local duration, timeleft = nil, -1
  local rank = nil
  local caster = nil
  local effect
  
  if texture then
    scanner:SetUnitBuff(unit, id)
    effect = scanner:Line(1) or ""
    
    -- Anti-Spam: Nur debuggen wenn es Rejuvenation ist und sich was geändert hat
    if effect == "Rejuvenation" then
      local key = unit.."-"..id.."-"..effect
      local now = GetTime()
      if not lastUnitBuffDebug[key] or (now - lastUnitBuffDebug[key]) > 0.5 then
        DEFAULT_CHAT_FRAME:AddMessage(string.format("|cff00ffff[UnitBuff]|r unit=%s id=%d effect=%s", unit, id, effect or "nil"))
        lastUnitBuffDebug[key] = now
      end
    end
  end
  
  -- Read from libdebuff.objects (where AddEffect stores rank-protected data)
  if effect then
    local data = libdebuff.objects[unitname] and libdebuff.objects[unitname][unitlevel]
    data = data or libdebuff.objects[unitname] and libdebuff.objects[unitname][0]
    
    if effect == "Rejuvenation" then
      local key = "objects-"..effect
      local now = GetTime()
      if not lastUnitBuffDebug[key] or (now - lastUnitBuffDebug[key]) > 0.5 then
        DEFAULT_CHAT_FRAME:AddMessage(string.format("|cff00ffff[UnitBuff]|r objects[%s][%d] exists: %s", unitname or "nil", unitlevel or 0, tostring(data ~= nil)))
        lastUnitBuffDebug[key] = now
      end
    end
    
    if data and data[effect] then
      if effect == "Rejuvenation" then
        local key = "data-"..effect
        local now = GetTime()
        if not lastUnitBuffDebug[key] or (now - lastUnitBuffDebug[key]) > 0.5 then
          DEFAULT_CHAT_FRAME:AddMessage(string.format("|cff00ffff[UnitBuff]|r data[%s] exists, rank=%s duration=%s", effect, tostring(data[effect].rank), tostring(data[effect].duration)))
          lastUnitBuffDebug[key] = now
        end
      end
      
      if data[effect].duration and data[effect].start and data[effect].duration + data[effect].start > GetTime() then
        -- Valid buff data from AddEffect (rank-protected!)
        duration = data[effect].duration
        timeleft = duration + data[effect].start - GetTime()
        caster = data[effect].caster
        rank = data[effect].rank
        
        if effect == "Rejuvenation" then
          local key = "found-"..effect
          local now = GetTime()
          if not lastUnitBuffDebug[key] or (now - lastUnitBuffDebug[key]) > 0.5 then
            DEFAULT_CHAT_FRAME:AddMessage(string.format("|cff00ff00[UnitBuff FOUND]|r %s rank=%d duration=%.1f timeleft=%.1f", effect, rank or 0, duration, timeleft))
            lastUnitBuffDebug[key] = now
          end
        end
      else
        -- Clean up invalid values
        data[effect] = nil
        if effect == "Rejuvenation" then
          DEFAULT_CHAT_FRAME:AddMessage(string.format("|cffff0000[UnitBuff EXPIRED]|r %s", effect))
        end
      end
    else
      if effect == "Rejuvenation" then
        local key = "notfound-"..effect
        local now = GetTime()
        if not lastUnitBuffDebug[key] or (now - lastUnitBuffDebug[key]) > 0.5 then
          DEFAULT_CHAT_FRAME:AddMessage(string.format("|cffff9900[UnitBuff NOT IN OBJECTS]|r %s not found in libdebuff.objects", effect))
          lastUnitBuffDebug[key] = now
        end
      end
    end
  end
  
  return effect, rank, texture, stacks, nil, duration, timeleft, caster
end

-- Nampower Integration für Combo Points und Carnage
if hasNampower then
  local nampowerFrame = CreateFrame("Frame")
  nampowerFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
  nampowerFrame:RegisterEvent("PLAYER_COMBO_POINTS")
  nampowerFrame:RegisterEvent("PLAYER_TALENT_UPDATE")
  
  -- Nur wenn CVars aktiv
  if GetCVar("NP_EnableSpellGoEvents") == "1" then
    nampowerFrame:RegisterEvent("SPELL_GO_SELF")
  end
  
  if GetCVar("NP_EnableAuraCastEvents") == "1" then
    nampowerFrame:RegisterEvent("AURA_CAST_ON_SELF")
    nampowerFrame:RegisterEvent("AURA_CAST_ON_OTHER")
  end
  
  -- DEBUFF_ADDED für Slot Tracking (immer, braucht kein CVar)
  nampowerFrame:RegisterEvent("DEBUFF_ADDED_OTHER")
  nampowerFrame:RegisterEvent("DEBUFF_REMOVED_OTHER")
  
  nampowerFrame:SetScript("OnEvent", function()
    if event == "PLAYER_ENTERING_WORLD" then
      UpdateCarnageRank()
      GetPlayerGUID()
      
    elseif event == "PLAYER_TALENT_UPDATE" then
      UpdateCarnageRank()
      
    elseif event == "PLAYER_COMBO_POINTS" then
      -- Track Combo Points für Druid Finisher
      if class ~= "DRUID" then return end
      
      local current = GetComboPoints("player", "target") or 0
      
      -- CPs wurden ausgegeben
      if current < currentComboPoints then
        lastSpentComboPoints = currentComboPoints
        lastSpentTime = GetTime()
      end
      
      currentComboPoints = current
      
    elseif event == "DEBUFF_ADDED_OTHER" or event == "DEBUFF_REMOVED_OTHER" then
      -- arg1=guid, arg2=slot, arg3=spellId, arg4=stackCount, arg5=auraLevel
      local guid = arg1
      local slot = arg2
      local spellId = arg3
      
      if not guid or not slot then return end
      
      if event == "DEBUFF_ADDED_OTHER" then
        -- Check ob dieser Debuff von uns ist
        local spellName = SpellInfo and SpellInfo(spellId)
        if spellName then
          -- Check: Haben wir diesen Debuff KÜRZLICH (< 1s) gecastet?
          local isOurs = false
          if ownDebuffs[guid] and ownDebuffs[guid][spellName] then
            local timeSinceCast = GetTime() - ownDebuffs[guid][spellName].startTime
            isOurs = timeSinceCast < 1.0  -- Muss innerhalb 1 Sekunde sein!
          end
          
          if isOurs then
            -- Dieser Debuff ist von uns! Speichere Slot
            ownSlots[guid] = ownSlots[guid] or {}
            ownSlots[guid][slot] = spellName
          end
        end
      elseif event == "DEBUFF_REMOVED_OTHER" then
        -- Remove slot tracking
        if ownSlots[guid] and ownSlots[guid][slot] then
          ownSlots[guid][slot] = nil
        end
      end
      
    elseif event == "AURA_CAST_ON_SELF" or event == "AURA_CAST_ON_OTHER" then
      -- Track eigene Debuffs für "Only Show Own" Feature
      -- arg1=spellId, arg2=casterGuid, arg3=targetGuid, arg8=durationMs
      local spellId = arg1
      local casterGuid = arg2
      local targetGuid = arg3
      local durationMs = arg8
      
      -- NUR eigene Casts speichern!
      if not spellId or not targetGuid or not casterGuid then return end
      
      local myGuid = GetPlayerGUID()
      if not myGuid or casterGuid ~= myGuid then return end
      
      local spellName, spellRank, texture
      if SpellInfo then
        spellName, spellRank, texture = SpellInfo(spellId)
      end
      
      if not spellName then return end
      
      -- Extract rank number
      local rankNum = 0
      if spellRank and spellRank ~= "" then
        rankNum = tonumber((string.gsub(spellRank, RANK, ""))) or 0
      end
      
      local duration = durationMs and (durationMs / 1000) or 0
      local startTime = GetTime()
      
      -- Wenn es auf DICH selbst ist (targetGuid == myGuid), speichere in lastCastRanks
      -- für Rank Protection bei Self-Buffs (z.B. Rejuvenation)
      if targetGuid == myGuid then
        DEFAULT_CHAT_FRAME:AddMessage(string.format("|cffff00ff[SELF BUFF]|r %s Rank %d", spellName, rankNum))
        
        lastCastRanks[spellName] = { rank = rankNum, time = startTime }
        -- Auch in libdebuff.objects speichern für Rank Protection
        local unitName = UnitName("player")
        local unitLevel = UnitLevel("player")
        if unitName and unitLevel then
          DEFAULT_CHAT_FRAME:AddMessage(string.format("|cff00ffff[CALLING AddEffect]|r unit=%s level=%d spell=%s rank=%d", unitName, unitLevel, spellName, rankNum))
          libdebuff:AddEffect(unitName, unitLevel, spellName, duration, "player", rankNum)
        end
        return  -- Für Self-Buffs nutzen wir AddEffect, nicht ownDebuffs
      end
      
      -- Für Debuffs auf Targets: Speichere in ownDebuffs
      
      -- Rank Protection: Check if higher rank already exists
      local existing = ownDebuffs[targetGuid] and ownDebuffs[targetGuid][spellName]
      if existing then
        local existingRank = 0
        if existing.rank and existing.rank ~= "" then
          existingRank = tonumber((string.gsub(existing.rank, RANK, ""))) or 0
        end
        
        -- Check if existing is still active
        local timeleft = (existing.startTime + existing.duration) - startTime
        if timeleft > 0 and rankNum < existingRank then
          -- Lower rank cannot overwrite higher rank - skip!
          return
        end
      end
      
      -- Speichere für Target Debuff Bar "Only Show Own"
      ownDebuffs[targetGuid] = ownDebuffs[targetGuid] or {}
      ownDebuffs[targetGuid][spellName] = {
        startTime = startTime,
        duration = duration,
        texture = texture,
        rank = spellRank
      }
      
      -- Speichere auch für Cleveroids (spellID-indexed!)
      objectsByGuid[targetGuid] = objectsByGuid[targetGuid] or {}
      objectsByGuid[targetGuid][spellId] = {
        start = startTime,
        duration = duration,
        caster = "player",
        stacks = 1
      }
      
    elseif event == "SPELL_GO_SELF" then
      -- Ferocious Bite mit Carnage 2/2 refresht Rip & Rake
      if class ~= "DRUID" or carnageRank ~= 2 then return end
      
      local spellId = arg2
      local targetGuid = arg4
      local numHit = arg6
      
      if numHit == 0 then return end -- Miss
      
      local spellName = SpellInfo and SpellInfo(spellId)
      
      if spellName == "Ferocious Bite" then
        local targetName = UnitName("target")
        local targetLevel = UnitLevel("target")
        
        if not targetName or not targetLevel then return end
        
        -- Refresh in libdebuff.objects (für normale Debuff Anzeige)
        local ripData = libdebuff.objects[targetName] and libdebuff.objects[targetName][targetLevel] and libdebuff.objects[targetName][targetLevel]["Rip"]
        if ripData and ripData.caster == "player" then
          local remaining = ripData.duration + ripData.start - GetTime()
          if remaining > 0 then
            ripData.start = GetTime()
          end
        end
        
        local rakeData = libdebuff.objects[targetName] and libdebuff.objects[targetName][targetLevel] and libdebuff.objects[targetName][targetLevel]["Rake"]
        if rakeData and rakeData.caster == "player" then
          local remaining = rakeData.duration + rakeData.start - GetTime()
          if remaining > 0 then
            rakeData.start = GetTime()
          end
        end
        
        -- Refresh in ownDebuffs (für "Only Show Own" Feature)
        if targetGuid and ownDebuffs[targetGuid] then
          if ownDebuffs[targetGuid]["Rip"] then
            ownDebuffs[targetGuid]["Rip"].startTime = GetTime()
          end
          if ownDebuffs[targetGuid]["Rake"] then
            ownDebuffs[targetGuid]["Rake"].startTime = GetTime()
          end
        end
      end
    end
  end)
end

-- PUBLIC API: GetEnhancedDebuffs für CleveRoids Kompatibilität
-- Returns: [spellName][casterGUID] = {startTime, duration, texture, rank}
function libdebuff:GetEnhancedDebuffs(targetGUID)
  if not hasNampower or not targetGUID then return nil end
  
  -- Convert ownDebuffs structure to CleveRoids format
  -- ownDebuffs: [targetGUID][spellName] = {startTime, duration, ...}
  -- CleveRoids needs: [spellName][casterGUID] = {startTime, duration, ...}
  
  local result = {}
  local myGuid = GetPlayerGUID()
  
  if ownDebuffs[targetGUID] then
    for spellName, data in pairs(ownDebuffs[targetGUID]) do
      -- Check if still active
      local timeleft = (data.startTime + data.duration) - GetTime()
      if timeleft > 0 then
        result[spellName] = result[spellName] or {}
        result[spellName][myGuid] = {
          startTime = data.startTime,
          duration = data.duration,
          texture = data.texture,
          rank = data.rank
        }
      end
    end
  end
  
  return result
end

-- add libdebuff to pfUI API
pfUI.api.libdebuff = libdebuff

-- API für Cleveroids: GetEnhancedDebuffs
-- Returns: [spellName][casterGUID] = {startTime, duration, ...}
function libdebuff:GetEnhancedDebuffs(targetGUID)
  if not targetGUID or not hasNampower then return nil end
  
  -- Convert from ownDebuffs format to Cleveroids format
  local result = {}
  if ownDebuffs[targetGUID] then
    local myGuid = GetPlayerGUID()
    for spellName, data in pairs(ownDebuffs[targetGUID]) do
      result[spellName] = {
        [myGuid] = {
          startTime = data.startTime,
          duration = data.duration,
          texture = data.texture,
          rank = data.rank
        }
      }
    end
  end
  
  return result
end

-- Expose for CleveRoids compatibility
if not CleveRoids then CleveRoids = {} end
CleveRoids.libdebuff = libdebuff
libdebuff.objects = objectsByGuid  -- CleveRoids checkt lib.objects[guid][spellID]