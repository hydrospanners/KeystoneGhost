-- In-game chat share (DESIGN "Sharing" → 3b; APIs verified 2026-07-21 via
-- wow-api-verify — see the commit):
--
-- The honest mechanics, as designed: the export string itself NEVER travels
-- through visible chat (255-byte cap). A short marker goes into visible chat —
-- plain text for people without the addon; a ChatFrame message filter rewrites
-- it into a clickable |Haddon:…|h link for people with it (the modern `addon`
-- hyperlink type — the shape BugGrabber/DBM ship; clicks arrive through the
-- EventRegistry "SetItemRef" callback). Clicking asks for a confirm, then the
-- receiver REQUESTS the ghost, and the sender streams the EXISTING export
-- string (print-encoded — already chat-safe) in ≤240-byte chunks over the
-- hidden addon channel, whisper-to-whisper. Reassembly hands into
-- Ghosts:ImportString — one import pipeline for all three doors (popup paste,
-- chat link, KPG1 codes).
--
-- Throttling reality (verified): each prefix has a native allowance of 10
-- messages, regenerating 1/s; SendAddonMessage returns a result enum
-- (3 = AddonMessageThrottle). A full ghost is 3–8 chunks — inside one burst —
-- so the pipe self-paces at 0.25 s/chunk and retries a throttled chunk after
-- 1.5 s. No ChatThrottleLib: single prefix, tiny payloads, result-checked.
--
-- Security shape: a sender only answers requests carrying its own session
-- nonce (tokens it minted this login); a receiver only accepts data chunks for
-- tokens it explicitly requested, and only from the player it asked. Nothing
-- unsolicited imports.
local ADDON_NAME, NS = ...
local KG = NS.KG
local M = KG.Math

local Comm = {}
KG.Comm = Comm

local PREFIX = "KeystoneGhost" -- 13 chars (cap 16); also the |Haddon namespace
local CHUNK = 240              -- payload bytes per message (255 minus header room)
local PACE = 0.25              -- seconds between chunks (allowance regen 1/s, burst 10)
local RETRY = 1.5              -- back-off after a throttle result
local MAX_RETRY = 10
local REQUEST_TTL = 30         -- seconds a receiver waits for a full transfer

-- ── pure protocol helpers (offline-tested in tests/test_comm.lua) ─────────────

--- Marker placed in visible chat. Plain text for the addon-less; the filter
--- below rewrites it for everyone else. Token shape: KG<nonce>.<slot>.
function Comm.BuildMarker(pretty, token)
    return string.format("[KeystoneGhost: %s #%s]", pretty, token)
end

--- Find a marker inside a chat line → pretty, token (nil when none).
function Comm.ParseMarker(text)
    if type(text) ~= "string" then return nil end
    return text:match("%[KeystoneGhost: (.-) #(KG%x+%.%d+)%]")
end

--- Rewrite a chat line's marker into the clickable addon link (idempotent-safe:
--- one marker per line is the emitted shape). `hex` = accent color "rrggbb".
--- The pretty text rides INSIDE the link data (last, greedy — it may contain
--- anything but pipes) so the click handler can name the offer without relying
--- on the display text reaching the SetItemRef callback.
function Comm.RewriteMarker(text, sender, hex)
    local pretty, token = Comm.ParseMarker(text)
    if not pretty then return nil end
    local link = string.format("|Haddon:%s:%s:%s:%s|h|cff%s[KeystoneGhost: %s]|r|h",
        PREFIX, token, sender or "?", pretty, hex or "0dd39e", pretty)
    return (text:gsub("%[KeystoneGhost: .-%]", link, 1))
end

--- Parse our addon-link data → token, sender, pretty (nil when not ours).
function Comm.ParseLink(link)
    return tostring(link or ""):match("^addon:" .. PREFIX .. ":(KG%x+%.%d+):([^:]+):(.+)$")
end

--- Split a string into ≤size chunks (never empty; preserves every byte).
function Comm.SplitChunks(s, size)
    local out = {}
    for i = 1, #s, size do
        out[#out + 1] = s:sub(i, i + size - 1)
    end
    return out
end

--- Protocol lines. Q = request, D = data chunk.
function Comm.BuildRequest(token) return "Q:" .. token end
function Comm.ParseRequest(msg) return msg:match("^Q:(KG%x+%.%d+)$") end
function Comm.BuildChunk(token, i, n, part)
    return string.format("D:%s:%d:%d:%s", token, i, n, part)
end
function Comm.ParseChunk(msg)
    local token, i, n, part = msg:match("^D:(KG%x+%.%d+):(%d+):(%d+):(.*)$")
    if not token then return nil end
    return token, tonumber(i), tonumber(n), part
end

-- ── sender side ───────────────────────────────────────────────────────────────

local slots, nonce = {}, nil

local function Mint()
    if not nonce then
        nonce = string.format("%04x", math.random(0, 65535))
    end
    return nonce
end

--- Offer a stored run for chat sharing → the marker string for the editbox,
--- or nil when the run can't be shared (Depleted never exports). Slots live
--- for the session; the token is meaningless to anyone we didn't hand it to.
function Comm.OfferText(charKey, mapID, level, tier, pretty)
    if not tier or tier < 1 then return nil end
    slots[#slots + 1] = { charKey = charKey, mapID = mapID, level = level, tier = tier }
    return Comm.BuildMarker(pretty, string.format("KG%s.%d", Mint(), #slots))
end

--- Insert a share link for a run into the active chat editbox. Returns true on
--- insert; false when no editbox is open (callers keep their normal click).
function Comm.InsertShareLink(charKey, mapID, level, tier, pretty)
    local getWin = _G.ChatEdit_GetActiveWindow
        or (_G.ChatFrameUtil and _G.ChatFrameUtil.GetActiveWindow) -- 12.x rename in flight
    local box = getWin and getWin()
    if not box then return false end
    local marker = Comm.OfferText(charKey, mapID, level, tier, pretty)
    if not marker then
        print("|cff88ccffKeystoneGhost|r: depleted runs are never shared — the pin is their only door.")
        return true -- shift-click consumed either way
    end
    box:Insert(marker)
    return true
end

local function ResolveSlot(token)
    local n, slot = token:match("^KG(%x+)%.(%d+)$")
    if n ~= nonce then return nil end -- not minted this session, not ours
    return slots[tonumber(slot)]
end

local function IsThrottle(result)
    local e = _G.Enum and _G.Enum.SendAddonMessageResult
    return result == (e and e.AddonMessageThrottle or 3)
end

--- Paced chunk streamer: one chunk per PACE seconds, throttle-aware retry.
local function StreamChunks(token, chunks, target)
    local i, tries = 1, 0
    local function step()
        if i > #chunks then return end
        local result = C_ChatInfo.SendAddonMessage(PREFIX,
            Comm.BuildChunk(token, i, #chunks, chunks[i]), "WHISPER", target)
        if IsThrottle(result) then
            tries = tries + 1
            if tries <= MAX_RETRY then C_Timer.After(RETRY, step) end
            return
        end
        i, tries = i + 1, 0
        if i <= #chunks then C_Timer.After(PACE, step) end
    end
    step()
end

local function AnswerRequest(token, requester)
    local slot = ResolveSlot(token)
    if not slot then return end
    local str = KG.Ghosts:ExportString(slot.mapID, slot.level, slot.charKey, slot.tier)
    if not str then return end
    StreamChunks(token, Comm.SplitChunks(str, CHUNK), requester)
end

-- ── receiver side ─────────────────────────────────────────────────────────────

local requested = {} -- [token] = { from = sender, parts = {}, n = nil, at = GetTime }

local function OnChunk(token, i, n, part, sender)
    local req = requested[token]
    if not req or req.from ~= sender then return end -- never asked this player
    if not i or not n or n < 1 or n > 64 or i < 1 or i > n then return end
    req.n = req.n or n
    if req.n ~= n then return end
    req.parts[i] = part
    for k = 1, req.n do
        if not req.parts[k] then return end -- still incomplete
    end
    requested[token] = nil
    local run, err = KG.Ghosts:ImportString(table.concat(req.parts))
    if run then
        print(string.format("|cff88ccffKeystoneGhost|r: imported %s's %s +%d ghost (%s) — racing it next key.",
            run.importedFrom, M.TierLabel(run.chests), run.level, M.FormatClock(run.durationSec)))
        KG.Library:RefreshIfShown()
    else
        print("|cff88ccffKeystoneGhost|r: transfer arrived broken — " .. (err or "unknown error"))
    end
end

if StaticPopupDialogs then -- absent only in the offline test harness
    StaticPopupDialogs["KEYSTONEGHOST_OFFER"] = {
        text = "%s offers their %s ghost.|nRace it?",
        button1 = ACCEPT,
        button2 = CANCEL,
        OnAccept = function(self, data)
            requested[data.token] = { from = data.sender, parts = {}, at = GetTime() }
            C_ChatInfo.SendAddonMessage(PREFIX, Comm.BuildRequest(data.token), "WHISPER", data.sender)
            C_Timer.After(REQUEST_TTL, function()
                if requested[data.token] then
                    requested[data.token] = nil
                    print("|cff88ccffKeystoneGhost|r: ghost transfer timed out — ask "
                        .. data.sender .. " to send a fresh link.")
                end
            end)
        end,
        timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
    }
end

-- ── wiring ────────────────────────────────────────────────────────────────────

local FILTERED_EVENTS = {
    "CHAT_MSG_PARTY", "CHAT_MSG_PARTY_LEADER",
    "CHAT_MSG_RAID", "CHAT_MSG_RAID_LEADER",
    "CHAT_MSG_GUILD", "CHAT_MSG_INSTANCE_CHAT", "CHAT_MSG_INSTANCE_CHAT_LEADER",
    "CHAT_MSG_WHISPER", "CHAT_MSG_WHISPER_INFORM",
}

function Comm:Setup()
    math.random() -- warm the shared RNG before minting the session nonce
    if not (C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix) then return end
    C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)

    -- Receiver render: the marker becomes a clickable accent link for addon users.
    local addFilter = _G.ChatFrame_AddMessageEventFilter
        or (_G.ChatFrameUtil and _G.ChatFrameUtil.AddMessageEventFilter)
    if addFilter then
        local function filter(_, _, msg, sender, ...)
            local rewritten = Comm.RewriteMarker(msg, sender, KG.Style.AccentHex())
            if rewritten then return false, rewritten, sender, ... end
        end
        for _, ev in ipairs(FILTERED_EVENTS) do addFilter(ev, filter) end
    end

    -- Clicks: the modern addon-link path (EventRegistry callback on SetItemRef).
    if EventRegistry and EventRegistry.RegisterCallback then
        EventRegistry:RegisterCallback("SetItemRef", function(_, link)
            local token, sender, pretty = Comm.ParseLink(link)
            if not token then return end
            StaticPopup_Show("KEYSTONEGHOST_OFFER", sender, pretty, { token = token, sender = sender })
        end, Comm)
    end

    -- The hidden channel.
    local f = CreateFrame("Frame")
    f:RegisterEvent("CHAT_MSG_ADDON")
    f:SetScript("OnEvent", function(_, _, prefix, msg, _, sender)
        if prefix ~= PREFIX or type(msg) ~= "string" then return end
        local qtoken = Comm.ParseRequest(msg)
        if qtoken then
            AnswerRequest(qtoken, sender)
            return
        end
        local token, i, n, part = Comm.ParseChunk(msg)
        if token then OnChunk(token, i, n, part, sender) end
    end)
end
