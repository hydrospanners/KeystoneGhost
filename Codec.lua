-- Export/import strings — WeakAuras-style: serialize → deflate → printable encoding,
-- prefixed "!KG1". The payload carries the full run (timeline, boss kills with names and
-- forces%, route name) plus exporter identity, so an imported ghost races with the same
-- fidelity as a locally recorded one.
--
-- Uses bundled LibSerialize + LibDeflate via LibStub. Every imported run passes through
-- GhostMath.CleanRun before touching SavedVariables — unknown fields never survive.
local ADDON_NAME, NS = ...
local KG = NS.KG
local M = KG.Math

local Codec = {}
KG.Codec = Codec

local PREFIX = "!KG1"

local function Libs()
    local stub = _G.LibStub
    if not stub then return nil end
    return stub:GetLibrary("LibSerialize", true), stub:GetLibrary("LibDeflate", true)
end

--- @return string|nil, string|nil errorMessage
function Codec.Export(payload)
    local LS, LD = Libs()
    if not LS or not LD then return nil, "LibSerialize/LibDeflate unavailable" end
    local ok, serialized = pcall(LS.Serialize, LS, payload)
    if not ok then return nil, "serialize failed" end
    local compressed = LD:CompressDeflate(serialized, { level = 9 })
    return PREFIX .. LD:EncodeForPrint(compressed)
end

--- @return table|nil payload, string|nil errorMessage
function Codec.Decode(str)
    local LS, LD = Libs()
    if not LS or not LD then return nil, "LibSerialize/LibDeflate unavailable" end
    if type(str) ~= "string" then return nil, "not a string" end
    str = str:gsub("%s+", "")
    if str:sub(1, #PREFIX) ~= PREFIX then return nil, "not a KeystoneGhost export string" end
    local decoded = LD:DecodeForPrint(str:sub(#PREFIX + 1))
    if not decoded then return nil, "corrupt encoding" end
    local decompressed = LD:DecompressDeflate(decoded)
    if not decompressed then return nil, "corrupt compression" end
    local ok, payload = LS:Deserialize(decompressed)
    if not ok or type(payload) ~= "table" then return nil, "corrupt payload" end
    return payload
end

--- Build the export payload for one run.
function Codec.BuildPayload(run, exporter)
    return {
        v = 1,
        exporter = exporter,
        exportedAt = time and time() or 0,
        run = run,
    }
end

--- Validate a decoded payload → clean run + exporter name, or nil + error.
function Codec.ValidatePayload(payload)
    if type(payload) ~= "table" or payload.v ~= 1 then return nil, nil, "unsupported version" end
    local exporter = type(payload.exporter) == "string" and payload.exporter:sub(1, 60) or "Unknown"
    local run = M.CleanRun(payload.run)
    if not run then return nil, nil, "invalid run data" end
    if not run.mapID or not run.level then return nil, nil, "missing dungeon/level" end
    return run, exporter
end
