local build = "5875"

GetBuildInfo = function()
    return "1.12.1", build, ""
end

dofile("util.lua")

assert(Chronicle_IsUrsolClient() == false, "native 1.12 build must not be detected as Ursol")
build = "7272"
assert(Chronicle_IsUrsolClient() == true, "build 7272 must be detected as Ursol")

-- Native clients can expose every capability API through extensions. Those APIs
-- must not enable Ursol logging unless the client build itself is Ursol.
build = "5875"
GetUnitField = function() return 1 end
GetUnitGUID = function() return "0xF130000000000001" end
UnitPosition = function() return 1, 2, 3, 4 end
GetRaidTargetIndex = function() return 1 end

strfind = string.find
strlen = string.len
strlower = string.lower
strsub = string.sub

local messages = {}
Chronicle = {
    Print = function(self, message)
        table.insert(messages, message)
    end,
}

ChronicleLog = {
    events = {},
    enabled = false,
}
function ChronicleLog:CheckUnit() end
function ChronicleLog:WriteZoneInfo() end
function ChronicleLog:Enable() self.enabled = true end
function ChronicleLog:CreateOptionsPanel() end
function ChronicleLog:RefreshOptionsPanel() end

local frame
CreateFrame = function()
    frame = {}
    function frame:SetScript(name, callback)
        self[name] = callback
    end
    return frame
end

dofile("advancedlogging/ursol.lua")

assert(ChronicleUrsol.caps.client == false, "native client must fail the Ursol client gate")
assert(ChronicleUrsol.caps.fields == false, "capability APIs must stay disabled on native clients")
assert(ChronicleUrsol:Available("unitState") == false, "unit state must be unavailable on native clients")
assert(ChronicleUrsol:Available("threat") == false, "threat must be unavailable on native clients")
assert(ChronicleUrsol:ThreatQueryActive() == false, "native clients must not query the Ursol threat API")
assert(table.getn(ChronicleLog.events) == 0, "native clients must not register Ursol events")
assert(frame and frame.OnUpdate, "Ursol polling frame should still initialize safely")

ChronicleUrsol:Status()
assert(string.find(messages[1], "unavailable: needs the Ursol client", 1, true),
    "native client status must explain why Ursol is unavailable")

build = "7272"
ChronicleUrsol:DetectCaps()
assert(ChronicleUrsol.caps.client == true, "Ursol client gate must accept build 7272")
assert(ChronicleUrsol:Available("unitState") == true, "Ursol capabilities must be available on build 7272")
assert(ChronicleUrsol:Available("threat") == true, "Ursol threat logging must be available on build 7272")

print("ursol_client_test.lua: ok")
