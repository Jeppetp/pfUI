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

-- Check for Nampower
local hasNampower = GetNampowerVersion ~= nil
if not hasNampower then
  DEFAULT_CHAT_FRAME:AddMessage("|cffff0000[pfUI]|r libdebuff requires Nampower! Download from https://gitea.com/avitasia/nampower")
  return
end

-- Nampower Debuff Tracking
local nampowerDebuffs = {}  -- [targetGUID][spellID] = {name, slot, stacks, startTime, duration, casterGUID}
local playerGUID = nil

-- Combo Point Tracking
local currentComboPoints = 0
local lastSpentComboPoints = 0
local lastSpentTime = 0

-- Carnage Talent Detection (Druid Feral, Tab 2, Slot 17)
local carnageRank = 0  -- 0, 1, or 2

-- Speichert die Ranks der zuletzt gecasteten Spells (bleibt länger als pending)
local lastCastRanks = {}

-- Speichert Spells die gefailed sind (miss/dodge/parry/etc.) für 1 Sekunde
local lastFailedSpells = {}

-- Update Carnage Talent
local function UpdateCarnageTalent()
  if class ~= "DRUID" then return end
  local _, _, _, _, rank = GetTalentInfo(2, 17)  -- Tab 2 (Feral), Slot 17 (Carnage)
  carnageRank = rank or 0
end

-- Track Combo Point Changes
local function OnComboPointsChanged()
  if class ~= "ROGUE" and class ~= "DRUID" then return end
  
  local newCP = GetComboPoints()
  if newCP ~= currentComboPoints then
    local oldCP = currentComboPoints
    currentComboPoints = newCP
    
    -- Combo Points spent (went to 0)
    if newCP == 0 and oldCP > 0 then
      lastSpentComboPoints = oldCP
      lastSpentTime = GetTime()
    end
  end
end

-- Get Stored Combo Points (within 1 second of spending)
local function GetStoredComboPoints()
  if lastSpentComboPoints > 0 and (GetTime() - lastSpentTime) < 1 then
    return lastSpentComboPoints
  end
  return 0
end

-- Calculate Duration with Combo Points
local function CalculateDurationWithCP(spellName, baseDuration)
  local cp = GetStoredComboPoints()
  if cp == 0 then
    cp = GetComboPoints()
  end
  
  if spellName == "Rip" then
    return 8 + (cp * 2)
  elseif spellName == "Rupture" then
    return 6 + (cp * 2)
  elseif spellName == "Kidney Shot" then
    return 1 + cp
  end
  
  return baseDuration
end

-- Refresh Rip/Rake on Bite (Carnage 2/2)
local function RefreshDebuffsOnBite(targetGUID)
  if carnageRank < 2 then return end
  if not targetGUID or not nampowerDebuffs[targetGUID] then return end
  
  local now = GetTime()
  
  -- Refresh Rip
  if nampowerDebuffs[targetGUID]["Rip"] and nampowerDebuffs[targetGUID]["Rip"][playerGUID] then
    local ripData = nampowerDebuffs[targetGUID]["Rip"][playerGUID]
    local timeLeft = (ripData.startTime + ripData.duration) - now
    if timeLeft > 0 then
      ripData.startTime = now
    end
  end
  
  -- Refresh Rake
  if nampowerDebuffs[targetGUID]["Rake"] and nampowerDebuffs[targetGUID]["Rake"][playerGUID] then
    local rakeData = nampowerDebuffs[targetGUID]["Rake"][playerGUID]
    local timeLeft = (rakeData.startTime + rakeData.duration) - now
    if timeLeft > 0 then
      rakeData.startTime = now
    end
  end
end

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

    -- Use stored combo points if available
    local cp = GetStoredComboPoints()
    if cp == 0 then
      cp = GetComboPoints()
    end

    if effect == L["dyndebuffs"]["Rupture"] then
      duration = duration + cp * 2
    elseif effect == L["dyndebuffs"]["Kidney Shot"] then
      duration = duration + cp * 1
    elseif effect == "Rip" or effect == L["dyndebuffs"]["Rip"] then
      duration = 8 + cp * 2
    elseif effect == L["dyndebuffs"]["Demoralizing Shout"] then
      local _,_,_,_,count = GetTalentInfo(2,1)
      if count and count > 0 then duration = duration + ( duration / 100 * (count*10)) end
    elseif effect == L["dyndebuffs"]["Shadow Word: Pain"] then
      local _,_,_,_,count = GetTalentInfo(3,4)
      if count and count > 0 then duration = duration + count * 3 end
    elseif effect == L["dyndebuffs"]["Frostbolt"] then
      local _,_,_,_,count = GetTalentInfo(3,7)
      if count and count > 0 then duration = duration + count end
    elseif effect == L["dyndebuffs"]["Gouge"] then
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
    -- Niedrigerer Rank darf höheren NICHT überschreiben
    if rank < existing.rank then
      return  -- Blockiere das Update
    end
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
libdebuff:RegisterEvent("PLAYER_COMBO_POINTS")
libdebuff:RegisterEvent("CHARACTER_POINTS_CHANGED")
libdebuff:RegisterEvent("PLAYER_ENTERING_WORLD")

-- Nampower Events
libdebuff:RegisterEvent("DEBUFF_ADDED_SELF")
libdebuff:RegisterEvent("DEBUFF_ADDED_OTHER")
libdebuff:RegisterEvent("DEBUFF_REMOVED_SELF")
libdebuff:RegisterEvent("DEBUFF_REMOVED_OTHER")
libdebuff:RegisterEvent("AURA_CAST_ON_SELF")
libdebuff:RegisterEvent("AURA_CAST_ON_OTHER")
libdebuff:RegisterEvent("SPELL_GO_SELF")

-- Enable Nampower CVars
SetCVar("NP_EnableAuraCastEvents", "1")
SetCVar("NP_EnableSpellGoEvents", "1")

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
  -- Initialize player GUID
  if event == "PLAYER_ENTERING_WORLD" then
    local _, guid = UnitExists("player")
    playerGUID = guid
    UpdateCarnageTalent()
    return
  end
  
  -- Track Carnage talent changes
  if event == "CHARACTER_POINTS_CHANGED" then
    UpdateCarnageTalent()
    return
  end
  
  -- Track Combo Point changes
  if event == "PLAYER_COMBO_POINTS" then
    OnComboPointsChanged()
    return
  end
  
  -- Nampower: AURA_CAST (fires BEFORE DEBUFF_ADDED - this is where we capture CPs!)
  if event == "AURA_CAST_ON_SELF" or event == "AURA_CAST_ON_OTHER" then
    local spellID = arg1
    local casterGUID = arg2
    local targetGUID = arg3
    local effect = arg4
    local effectAuraName = arg5
    local effectAmplitude = arg6
    local effectMiscValue = arg7
    local durationMs = arg8
    local auraCapStatus = arg9
    
    if not spellID or not targetGUID or not casterGUID then return end
    
    -- Get spell name and rank
    local spellName, spellRank
    if SpellInfo then
      spellName, spellRank = SpellInfo(spellID)
    end
    
    if not spellName then return end
    
    -- Only track own casts
    if casterGUID ~= playerGUID then return end
    
    -- Extract rank number
    local rankNum = 0
    if spellRank and spellRank ~= "" then
      local _, _, num = string.find(spellRank, "(%d+)")
      rankNum = tonumber(num) or 0
    end
    
    -- Calculate duration with CPs (BEFORE they're spent!)
    local duration = durationMs / 1000  -- Convert to seconds
    local cp = 0
    
    if spellName == "Rip" then
      cp = GetStoredComboPoints()
      if cp == 0 then cp = GetComboPoints() end
      duration = 8 + (cp * 2)
    elseif spellName == "Rupture" then
      cp = GetStoredComboPoints()
      if cp == 0 then cp = GetComboPoints() end
      duration = 6 + (cp * 2)
    elseif spellName == "Kidney Shot" then
      cp = GetStoredComboPoints()
      if cp == 0 then cp = GetComboPoints() end
      duration = 1 + cp
    elseif spellName == "Rake" then
      duration = 9  -- Rake is always 9s
    elseif duration == 0 then
      -- Fallback to locale table
      duration = libdebuff:GetDuration(spellName, spellRank)
    end
    
    -- Initialize storage
    if not nampowerDebuffs[targetGUID] then
      nampowerDebuffs[targetGUID] = {}
    end
    if not nampowerDebuffs[targetGUID][spellName] then
      nampowerDebuffs[targetGUID][spellName] = {}
    end
    
    -- RANK PROTECTION: Check if existing debuff has higher rank
    local existing = nampowerDebuffs[targetGUID][spellName][playerGUID]
    if existing and existing.rank and rankNum > 0 then
      local existingIsActive = existing.startTime and existing.duration and 
                               (existing.startTime + existing.duration) > GetTime()
      
      if existingIsActive and rankNum < existing.rank then
        -- Lower rank cannot overwrite higher rank
        return
      end
    end
    
    -- Store debuff data per caster (DEBUFF_ADDED will update slot/texture)
    nampowerDebuffs[targetGUID][spellName][playerGUID] = {
      name = spellName,
      slot = 0,  -- Will be updated by DEBUFF_ADDED
      stacks = 1,
      startTime = GetTime(),
      duration = duration,
      casterGUID = playerGUID,
      texture = nil,  -- Will be updated by DEBUFF_ADDED
      spellID = spellID,
      comboPoints = cp,
      rank = rankNum
    }
    
    return
  end
  
  -- Nampower: DEBUFF_ADDED
  if event == "DEBUFF_ADDED_SELF" or event == "DEBUFF_ADDED_OTHER" then
    local targetGUID = arg1
    local slot = arg2
    local spellID = arg3
    local stackCount = arg4
    local auraLevel = arg5
    
    if not targetGUID or not spellID then return end
    
    -- Get spell name
    local spellName, _, texture
    if SpellInfo then
      spellName, _, texture = SpellInfo(spellID)
    end
    
    if spellName then
      if not nampowerDebuffs[targetGUID] then
        nampowerDebuffs[targetGUID] = {}
      end
      if not nampowerDebuffs[targetGUID][spellName] then
        nampowerDebuffs[targetGUID][spellName] = {}
      end
      
      -- Determine caster GUID
      local casterGUID = (event == "DEBUFF_ADDED_SELF") and playerGUID or nil
      
      -- Check if we already have this from AURA_CAST (our cast)
      if casterGUID and nampowerDebuffs[targetGUID][spellName][casterGUID] then
        -- Update slot and texture from AURA_CAST data
        nampowerDebuffs[targetGUID][spellName][casterGUID].slot = slot
        nampowerDebuffs[targetGUID][spellName][casterGUID].texture = texture
        nampowerDebuffs[targetGUID][spellName][casterGUID].stacks = stackCount or 1
      elseif not casterGUID then
        -- Other player's debuff - create a placeholder entry
        -- We don't know their GUID, so use a generic key
        local otherKey = "other_" .. slot
        nampowerDebuffs[targetGUID][spellName][otherKey] = {
          name = spellName,
          slot = slot,
          stacks = stackCount or 1,
          startTime = GetTime(),
          duration = 0,  -- No duration for other players
          casterGUID = nil,
          texture = texture,
          spellID = spellID
        }
      end
    end
    return
  end
  
  -- Nampower: DEBUFF_REMOVED
  if event == "DEBUFF_REMOVED_SELF" or event == "DEBUFF_REMOVED_OTHER" then
    local targetGUID = arg1
    local slot = arg2
    local spellID = arg3
    
    if not targetGUID or not spellID then return end
    
    -- Get spell name
    local spellName
    if SpellInfo then
      spellName = SpellInfo(spellID)
    end
    
    if spellName and nampowerDebuffs[targetGUID] and nampowerDebuffs[targetGUID][spellName] then
      -- Find and remove by slot
      for casterGUID, data in pairs(nampowerDebuffs[targetGUID][spellName]) do
        if data.slot == slot then
          nampowerDebuffs[targetGUID][spellName][casterGUID] = nil
          break
        end
      end
      
      -- Clean up empty spell table
      local hasAny = false
      for _ in pairs(nampowerDebuffs[targetGUID][spellName]) do
        hasAny = true
        break
      end
      if not hasAny then
        nampowerDebuffs[targetGUID][spellName] = nil
      end
    end
    return
  end
  
  -- Nampower: SPELL_GO (Ferocious Bite detection)
  if event == "SPELL_GO_SELF" then
    local itemId = arg1
    local spellID = arg2
    local casterGUID = arg3
    local targetGUID = arg4
    local castFlags = arg5
    local numTargetsHit = arg6
    local numTargetsMissed = arg7
    
    if not spellID or not targetGUID then return end
    
    -- Get spell name
    local spellName
    if SpellInfo then
      spellName = SpellInfo(spellID)
    end
    
    -- Check if Ferocious Bite hit
    if spellName == "Ferocious Bite" and numTargetsHit and numTargetsHit > 0 then
      RefreshDebuffsOnBite(targetGUID)
    end
    return
  end
  
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
  local rank = nil
  local caster = nil
  local effect

  if texture then
    scanner:SetUnitDebuff(unit, id)
    effect = scanner:Line(1) or ""
  end

  -- Try Nampower data first (most accurate)
  local _, targetGUID = UnitExists(unit)
  if targetGUID and nampowerDebuffs[targetGUID] and effect and nampowerDebuffs[targetGUID][effect] then
    -- Find debuff by matching slot ID
    for casterGUID, npData in pairs(nampowerDebuffs[targetGUID][effect]) do
      if npData and npData.slot == id then
        duration = npData.duration
        timeleft = npData.duration + npData.startTime - GetTime()
        caster = (casterGUID == playerGUID) and "player" or nil
        stacks = npData.stacks or stacks
        texture = npData.texture or texture
        
        -- Clean up expired debuffs
        if timeleft < 0 then
          nampowerDebuffs[targetGUID][effect][casterGUID] = nil
          timeleft = -1
        else
          return effect, rank, texture, stacks, dtype, duration, timeleft, caster
        end
      end
    end
  end

  -- Fallback to old system (combat log tracking)
  local data = libdebuff.objects[unitname] and libdebuff.objects[unitname][unitlevel]
  data = data or libdebuff.objects[unitname] and libdebuff.objects[unitname][0]

  if data and data[effect] then
    if data[effect].duration and data[effect].start and data[effect].duration + data[effect].start > GetTime() then
      duration = data[effect].duration
      timeleft = duration + data[effect].start - GetTime()
      caster = data[effect].caster
    else
      data[effect] = nil
    end
  end

  return effect, rank, texture, stacks, dtype, duration, timeleft, caster
end

local cache = {}
function libdebuff:UnitOwnDebuff(unit, id)
  -- clean cache
  for k, v in pairs(cache) do cache[k] = nil end

  -- detect own debuffs
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

-- add libdebuff to pfUI API
pfUI.api.libdebuff = libdebuff

-- Expose Nampower debuff tracking for other addons (per-caster format)
function libdebuff:GetEnhancedDebuffs(targetGUID)
  return nampowerDebuffs[targetGUID]
end