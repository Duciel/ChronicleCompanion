-- =============================================================================
-- ChronicleLog Octo extensions
--
-- Extra log lines for deeper raid analysis on OctoWoW (1.12 client):
--   HEALTH         unit health, for overheal / death recaps / boss %
--   POWER          mana / rage / energy of group members
--   UNIT_TARGET    target of the hostile units in combat (who is tanking)
--   UNIT_POSITION  world position of group members and hostile units
--   RAID_MARK      raid target icons
--   THREAT         server threat table of a mob (TWThreat API)
--   THREAT_TANK    "mobs I am tanking" table (TWThreat tank mode API)
--   OCTO_INFO      format version and the client APIs that were available
--
-- Every line uses the usual TIMESTAMP|EVENT|field|... layout with event names
-- Chronicle does not know: Chronicle skips them, the separate analysis tool
-- reads them. Field order of existing events is never changed.
-- See OCTO_EVENTS.md for the format of each line.
--
-- Requirements: Nampower (GetUnitField, *_GUID events). Optional: ClassicAPI or
-- SuperWoW (UnitPosition, GUID / markN unit tokens). Lua 5.0 syntax only.
-- =============================================================================

local Octo = {
    formatVersion = 1,
    hostiles = {},      -- [guid] = GetTime() of the last combat event involving it
    lastHealth = {},    -- [guid] = last logged health
    lastPower = {},     -- [guid .. ":" .. powerType] = last logged value
    lastTarget = {},    -- [guid] = last logged target guid
    lastPos = {},       -- [guid] = { x, y, z }
    marks = {},         -- [guid] = raid icon index
    lastThreat = {},    -- [mobGuid] = { list, time }
    lastQuery = 0,
    lastTargetPoll = 0,
    lastPosPoll = 0,
    lastMarkPoll = 0,
    lastCleanup = 0,
}
ChronicleOcto = Octo

local EMPTY_GUID = "0x0000000000000000"
local HOSTILE_TTL = 15          -- seconds a hostile stays tracked after its last event
local MAX_POLL_UNITS = 60       -- cap of hostile units polled per tick
local THREAT_API = "TWTv4="
local TANKMODE_API = "TMTv1="
local RELAY_API = "TWTRelayV2:"
local TANKSHARE_API = "PFTPTankV1:"
local UDTS_TM = "TWT_UDTSv4_TM"

-- Default settings (stored in ChronicleCompanionDB.advancedLog with an "octo_" prefix)
local DEFAULTS = {
    health = true,
    power = true,
    target = true,
    targetInterval = 0.25,
    position = true,
    positionInterval = 1.0,
    positionMinMove = 0.5,
    marks = true,
    threat = true,
    threatQuery = "auto",   -- "auto": only if TWThreat / pfUI-ThreatPlates are not loaded, "on", "off"
    threatInterval = 1.0,
    threatLimit = 10,
}

function Octo:Get(key)
    local db = ChronicleCompanionDB and ChronicleCompanionDB.advancedLog
    if db and db["octo_" .. key] ~= nil then
        return db["octo_" .. key]
    end
    return DEFAULTS[key]
end

function Octo:Set(key, value)
    ChronicleLog:SetSetting("octo_" .. key, value)
end

-- =============================================================================
-- Helpers
-- =============================================================================

local function IsCreature(guid)
    return guid and strsub(guid, 1, 5) == "0xF13"
end

local function ValidGuid(guid)
    return guid and guid ~= "" and guid ~= EMPTY_GUID
end

local function SafeField(unit, field)
    if not GetUnitField then return nil end
    local ok, value = pcall(GetUnitField, unit, field)
    if ok then return value end
    return nil
end

local function GuidOf(unit)
    if GetUnitGUID then
        local guid = GetUnitGUID(unit)
        if ValidGuid(guid) then return guid end
    end
    return nil
end

local function GroupTokens()
    local tokens = {}
    local raid = GetNumRaidMembers() or 0
    if raid > 0 then
        for i = 1, raid do
            table.insert(tokens, "raid" .. i)
        end
    else
        table.insert(tokens, "player")
        for i = 1, (GetNumPartyMembers() or 0) do
            table.insert(tokens, "party" .. i)
        end
    end
    return tokens
end

local function UnitTokenByName(name)
    local raid = GetNumRaidMembers() or 0
    if raid > 0 then
        for i = 1, raid do
            if UnitName("raid" .. i) == name then return "raid" .. i end
        end
    else
        for i = 1, (GetNumPartyMembers() or 0) do
            if UnitName("party" .. i) == name then return "party" .. i end
        end
    end
    return nil
end

local function GroupChannel()
    if (GetNumRaidMembers() or 0) > 0 then return "RAID" end
    if (GetNumPartyMembers() or 0) > 0 then return "PARTY" end
    return nil
end

-- Detects which UnitPosition is active. ClassicAPI returns posY, posX, posZ,
-- instanceID; SuperWoW returns x, y, z. When both DLLs are loaded the last one
-- to register wins, so the shape is checked at runtime.
function Octo:DetectPositionApi()
    if not UnitPosition then
        self.positionApi = "none"
        return
    end
    local ok, a, b, c, d = pcall(UnitPosition, "player")
    if not ok or not a then
        self.positionApi = "unknown"
    elseif d ~= nil then
        self.positionApi = "classicapi"
    else
        self.positionApi = "superwow"
    end
end

--- Returns world x, y, z of a unit token or GUID, or nil.
function Octo:Position(unit)
    if self.positionApi == "none" or not UnitPosition then return nil end
    local ok, a, b, c = pcall(UnitPosition, unit)
    if not ok or not a then return nil end
    if self.positionApi == "classicapi" then
        return b, a, c
    end
    return a, b, c
end

local function Round(value, decimals)
    local mult = 1
    for i = 1, (decimals or 0) do mult = mult * 10 end
    return math.floor(value * mult + 0.5) / mult
end

function Octo:ThreatQueryActive()
    local mode = self:Get("threatQuery")
    if mode == "on" then return true end
    if mode == "off" then return false end
    -- auto: let TWThreat / pfUI-ThreatPlates do the querying, we only listen
    if TWT and TWT.UDTS then return false end
    if pfUI and pfUI.threatplates then return false end
    return true
end

-- =============================================================================
-- Hostile unit tracking (fed by every combat event through CheckUnit)
-- =============================================================================

local originalCheckUnit = ChronicleLog.CheckUnit
function ChronicleLog:CheckUnit(guid)
    if IsCreature(guid) then
        Octo.hostiles[guid] = GetTime()
    end
    return originalCheckUnit(self, guid)
end

function Octo:IsTracked(guid)
    local seen = self.hostiles[guid]
    return seen and (GetTime() - seen) < HOSTILE_TTL
end

function Octo:Cleanup(now)
    for guid, seen in pairs(self.hostiles) do
        if now - seen > HOSTILE_TTL then
            self.hostiles[guid] = nil
            self.lastTarget[guid] = nil
            self.lastPos[guid] = nil
            self.lastHealth[guid] = nil
        end
    end
    for guid, data in pairs(self.lastThreat) do
        if now - data.time > 30 then self.lastThreat[guid] = nil end
    end
end

function Octo:Reset()
    self.hostiles = {}
    self.lastHealth = {}
    self.lastPower = {}
    self.lastTarget = {}
    self.lastPos = {}
    self.marks = {}
    self.lastThreat = {}
end

-- =============================================================================
-- OCTO_INFO
-- =============================================================================

function Octo:WriteInfo()
    self:DetectPositionApi()
    local classicApi = (C_NamePlate ~= nil or GetClassicExpansionLevel ~= nil) and 1 or 0
    local superWow = SUPERWOW_VERSION or ""
    local threat = self:ThreatQueryActive() and "query" or "listen"
    ChronicleLog:Write("OCTO_INFO", self.formatVersion, self.positionApi, classicApi, superWow, threat)
end

local originalWriteZoneInfo = ChronicleLog.WriteZoneInfo
function ChronicleLog:WriteZoneInfo(force)
    originalWriteZoneInfo(self, force)
    if self:IsEnabled() then
        Octo:Reset()
        Octo:WriteInfo()
    end
end

local originalEnable = ChronicleLog.Enable
function ChronicleLog:Enable()
    local wasEnabled = self.enabled
    originalEnable(self)
    if not wasEnabled and self.enabled then
        Octo:Reset()
        Octo:WriteInfo()
        Octo:ScanMarks()
    end
end

-- =============================================================================
-- HEALTH / POWER (Nampower *_GUID events)
-- =============================================================================

local function IsGrouped(isPlayer, isPet, partyIndex, raidIndex)
    return isPlayer == 1 or isPet == 1
        or (tonumber(partyIndex) or 0) > 0
        or (tonumber(raidIndex) or 0) > 0
end

function ChronicleLog:UNIT_HEALTH_GUID(guid, isPlayer, isTarget, isMouseover, isPet, partyIndex, raidIndex)
    if not Octo:Get("health") or not ValidGuid(guid) then return end
    if not IsGrouped(isPlayer, isPet, partyIndex, raidIndex) and not Octo:IsTracked(guid) then
        return
    end
    local hp = SafeField(guid, "health")
    if not hp then return end
    if Octo.lastHealth[guid] == hp then return end
    Octo.lastHealth[guid] = hp
    self:CheckUnit(guid)
    self:Write("HEALTH", guid, hp, SafeField(guid, "maxHealth") or "")
end

local POWER_FIELDS = {
    UNIT_MANA_GUID = { field = "power1", max = "maxPower1", type = 0 },
    UNIT_RAGE_GUID = { field = "power2", max = "maxPower2", type = 1 },
    UNIT_ENERGY_GUID = { field = "power4", max = "maxPower4", type = 3 },
}

function Octo:Power(event, guid, isPlayer, isPet, partyIndex, raidIndex)
    if not self:Get("power") or not ValidGuid(guid) then return end
    if not IsGrouped(isPlayer, isPet, partyIndex, raidIndex) then return end
    local spec = POWER_FIELDS[event]
    local value = SafeField(guid, spec.field)
    if not value then return end
    local key = guid .. ":" .. spec.type
    if self.lastPower[key] == value then return end
    self.lastPower[key] = value
    ChronicleLog:CheckUnit(guid)
    ChronicleLog:Write("POWER", guid, spec.type, value, SafeField(guid, spec.max) or "")
end

function ChronicleLog:UNIT_MANA_GUID(guid, isPlayer, isTarget, isMouseover, isPet, partyIndex, raidIndex)
    Octo:Power("UNIT_MANA_GUID", guid, isPlayer, isPet, partyIndex, raidIndex)
end

function ChronicleLog:UNIT_RAGE_GUID(guid, isPlayer, isTarget, isMouseover, isPet, partyIndex, raidIndex)
    Octo:Power("UNIT_RAGE_GUID", guid, isPlayer, isPet, partyIndex, raidIndex)
end

function ChronicleLog:UNIT_ENERGY_GUID(guid, isPlayer, isTarget, isMouseover, isPet, partyIndex, raidIndex)
    Octo:Power("UNIT_ENERGY_GUID", guid, isPlayer, isPet, partyIndex, raidIndex)
end

-- =============================================================================
-- UNIT_TARGET (polled: 1.12 has no event for another unit's target change)
-- =============================================================================

function Octo:PollTargets()
    local count = 0
    for guid in pairs(self.hostiles) do
        if self:IsTracked(guid) then
            count = count + 1
            if count > MAX_POLL_UNITS then return end
            -- health too: UNIT_HEALTH_GUID may only fire for units bound to a token
            if Octo:Get("health") then
                local hp = SafeField(guid, "health")
                if hp and self.lastHealth[guid] ~= hp then
                    self.lastHealth[guid] = hp
                    ChronicleLog:Write("HEALTH", guid, hp, SafeField(guid, "maxHealth") or "")
                end
            end
            local target = SafeField(guid, "target")
            if not ValidGuid(target) then target = "" end
            if self.lastTarget[guid] ~= target then
                -- nil means the unit is out of range / gone: keep the last known value
                if SafeField(guid, "health") then
                    self.lastTarget[guid] = target
                    ChronicleLog:Write("UNIT_TARGET", guid, target)
                end
            end
        end
    end
end

-- =============================================================================
-- UNIT_POSITION (polled, only while the player is in combat)
-- =============================================================================

function Octo:LogPosition(guid, unit, minMove)
    local x, y, z = self:Position(unit)
    if not x then return end
    local last = self.lastPos[guid]
    if last then
        local dx, dy, dz = x - last[1], y - last[2], z - last[3]
        if (dx * dx + dy * dy + dz * dz) < minMove * minMove then return end
    end
    self.lastPos[guid] = { x, y, z }
    ChronicleLog:Write("UNIT_POSITION", guid, Round(x, 2), Round(y, 2), Round(z, 2))
end

function Octo:PollPositions()
    if self.positionApi == "none" or self.positionApi == "unknown" then return end
    local minMove = tonumber(self:Get("positionMinMove")) or 0.5
    local tokens = GroupTokens()
    for i = 1, table.getn(tokens) do
        local guid = GuidOf(tokens[i])
        if guid then self:LogPosition(guid, tokens[i], minMove) end
    end
    local count = 0
    for guid in pairs(self.hostiles) do
        if self:IsTracked(guid) then
            count = count + 1
            if count > MAX_POLL_UNITS then return end
            self:LogPosition(guid, guid, minMove)
        end
    end
end

-- =============================================================================
-- RAID_MARK
-- =============================================================================

function Octo:ScanMarks()
    if not self:Get("marks") or not ChronicleLog:IsEnabled() then return end
    local current = {}
    -- markN tokens (SuperWoW / ClassicAPI)
    for i = 1, 8 do
        local guid = GuidOf("mark" .. i)
        if guid then current[guid] = i end
    end
    -- plain 1.12 fallback: group members and their targets
    local tokens = GroupTokens()
    for i = 1, table.getn(tokens) do
        local units = { tokens[i], tokens[i] .. "target" }
        for j = 1, 2 do
            local guid = GuidOf(units[j])
            if guid and not current[guid] then
                local index = GetRaidTargetIndex(units[j])
                if index then current[guid] = index end
            end
        end
    end
    for guid, index in pairs(current) do
        if self.marks[guid] ~= index then
            ChronicleLog:CheckUnit(guid)
            ChronicleLog:Write("RAID_MARK", guid, index)
        end
    end
    for guid in pairs(self.marks) do
        if not current[guid] then
            ChronicleLog:Write("RAID_MARK", guid, 0)
        end
    end
    self.marks = current
end

function ChronicleLog:RAID_TARGET_UPDATE()
    Octo:ScanMarks()
end

-- =============================================================================
-- THREAT (TWThreat server API, also relayed by TWThreat / pfUI-ThreatPlates)
-- =============================================================================

function Octo:WriteThreat(mobGuid, mobName, source, list)
    if not list or list == "" then return end
    local key = mobGuid ~= "" and mobGuid or ("name:" .. (mobName or ""))
    local now = GetTime()
    local last = self.lastThreat[key]
    -- several addons can receive / relay the same table within the same second
    if last and last.list == list and (now - last.time) < 1.5 then return end
    self.lastThreat[key] = { list = list, time = now }
    if mobGuid ~= "" then ChronicleLog:CheckUnit(mobGuid) end
    ChronicleLog:Write("THREAT", mobGuid, mobName or "", source, list)
end

--- Server answer to a TWT_UDTSv4[_TM] request sent by this client (any addon).
--- The table belongs to the mob this client currently targets.
function Octo:HandleServerThreat(message)
    local threatPart, tankPart = message, nil
    local split = strfind(message, "#", 1, true)
    if split then
        threatPart = strsub(message, 1, split - 1)
        tankPart = strsub(message, split + 1)
    end

    local _, e = strfind(threatPart, THREAT_API, 1, true)
    if e then
        local mobGuid = GuidOf("target") or ""
        self:WriteThreat(mobGuid, UnitName("target"), "self", strsub(threatPart, e + 1))
    end

    if tankPart then
        local _, te = strfind(tankPart, TANKMODE_API, 1, true)
        if te then
            local list = strsub(tankPart, te + 1)
            if list ~= "" then
                ChronicleLog:Write("THREAT_TANK", "self", list)
            end
        end
    end
end

--- TWTRelayV2:<mob>#name:tank:threat:perc:melee;...   (mob = the sender's target)
function Octo:HandleRelay(message, sender)
    local body = strsub(message, strlen(RELAY_API) + 1)
    local sep = strfind(body, "#", 1, true)
    if not sep then return end
    local mobName = strsub(body, 1, sep - 1)
    local mobGuid = ""
    local unit = UnitTokenByName(sender)
    if unit and UnitName(unit .. "target") == mobName then
        mobGuid = GuidOf(unit .. "target") or ""
    end
    self:WriteThreat(mobGuid, mobName, "relay:" .. sender, strsub(body, sep + 1))
end

local originalChatMsgAddon = ChronicleLog.CHAT_MSG_ADDON
function ChronicleLog:CHAT_MSG_ADDON(prefix, message, channel, sender)
    if message and Octo:Get("threat") then
        if strfind(message, THREAT_API, 1, true) then
            Octo:HandleServerThreat(message)
            return
        end
        if prefix == "TWT" and sender ~= UnitName("player") then
            if strsub(message, 1, strlen(RELAY_API)) == RELAY_API then
                Octo:HandleRelay(message, sender)
                return
            end
            if strsub(message, 1, strlen(TANKSHARE_API)) == TANKSHARE_API then
                local list = strsub(message, strlen(TANKSHARE_API) + 1)
                if list ~= "" then
                    self:Write("THREAT_TANK", "relay:" .. sender, list)
                end
                return
            end
        end
    end
    if originalChatMsgAddon then
        return originalChatMsgAddon(self, prefix, message, channel, sender)
    end
end

function Octo:QueryThreat()
    local channel = GroupChannel()
    if not channel then return end
    if not UnitExists("target") or UnitIsPlayer("target") or not UnitCanAttack("player", "target") then return end
    SendAddonMessage(UDTS_TM, "limit=" .. (tonumber(self:Get("threatLimit")) or 10), channel)
end

-- =============================================================================
-- Polling frame
-- =============================================================================

Octo.frame = CreateFrame("Frame", "ChronicleOctoFrame")
Octo.frame:SetScript("OnUpdate", function()
    if not ChronicleLog.enabled then return end
    local now = GetTime()
    local inCombat = UnitAffectingCombat("player")

    if now - Octo.lastCleanup > 5 then
        Octo.lastCleanup = now
        Octo:Cleanup(now)
    end

    if Octo:Get("target") and now - Octo.lastTargetPoll >= (tonumber(Octo:Get("targetInterval")) or 0.25) then
        Octo.lastTargetPoll = now
        Octo:PollTargets()
    end

    if inCombat and Octo:Get("position") and now - Octo.lastPosPoll >= (tonumber(Octo:Get("positionInterval")) or 1) then
        Octo.lastPosPoll = now
        Octo:PollPositions()
    end

    -- RAID_TARGET_UPDATE has no payload and can fire before units are known
    if inCombat and Octo:Get("marks") and now - Octo.lastMarkPoll >= 5 then
        Octo.lastMarkPoll = now
        Octo:ScanMarks()
    end

    if inCombat and Octo:Get("threat") and Octo:ThreatQueryActive()
        and now - Octo.lastQuery >= math.max(0.3, tonumber(Octo:Get("threatInterval")) or 1) then
        Octo.lastQuery = now
        Octo:QueryThreat()
    end
end)

-- New events (registered by ChronicleLog:Enable with the rest)
table.insert(ChronicleLog.events, "UNIT_HEALTH_GUID")
table.insert(ChronicleLog.events, "UNIT_MANA_GUID")
table.insert(ChronicleLog.events, "UNIT_RAGE_GUID")
table.insert(ChronicleLog.events, "UNIT_ENERGY_GUID")
table.insert(ChronicleLog.events, "RAID_TARGET_UPDATE")

-- =============================================================================
-- Slash command: /chronicle octo [setting] [value]
-- =============================================================================

local BOOL_KEYS = { health = true, power = true, target = true, position = true, marks = true, threat = true }
local NUM_KEYS = { targetInterval = true, positionInterval = true, positionMinMove = true, threatInterval = true, threatLimit = true }

function Octo:Status()
    self:DetectPositionApi()
    Chronicle:Print("Octo log format v" .. self.formatVersion .. " - position API: " .. self.positionApi
        .. ", threat: " .. (self:ThreatQueryActive() and "query" or "listen only"))
    for key in pairs(DEFAULTS) do
        Chronicle:Print("  " .. key .. " = " .. tostring(self:Get(key)))
    end
end

local KEY_BY_LOWER = {}
for key in pairs(DEFAULTS) do KEY_BY_LOWER[strlower(key)] = key end

function Octo:Slash(key, value)
    if key and key ~= "" then key = KEY_BY_LOWER[strlower(key)] or key end
    if value then value = strlower(value) end
    if not key or key == "" then
        self:Status()
        Chronicle:Print("/chronicle octo <setting> <value>  (on/off, a number, or auto/on/off for threatQuery)")
        return
    end
    if BOOL_KEYS[key] then
        local new
        if value == "on" or value == "1" or value == "true" then new = true
        elseif value == "off" or value == "0" or value == "false" then new = false
        else new = not self:Get(key) end
        self:Set(key, new)
        Chronicle:Print("octo " .. key .. " = " .. tostring(new))
    elseif NUM_KEYS[key] and tonumber(value) then
        self:Set(key, tonumber(value))
        Chronicle:Print("octo " .. key .. " = " .. value)
    elseif key == "threatQuery" and (value == "auto" or value == "on" or value == "off") then
        self:Set(key, value)
        Chronicle:Print("octo threatQuery = " .. value)
    else
        Chronicle:Print("Unknown octo setting or value: " .. key .. " " .. (value or ""))
    end
end
