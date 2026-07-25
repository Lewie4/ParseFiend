local PF_Hooked = {}
local PF_RaiderIoLoaded = false

local function OnRaiderIoLoaded()
    PF_RaiderIoLoaded = true
end

local function IsSecret(v)
    return issecretvalue and issecretvalue(v)
end

local function SafeCall(fn, ...)
    local ok, a, b = pcall(fn, ...)
    if not ok then return nil, nil end
    return a, b
end

local function SafeUnitIsPlayer(unit)
    if not unit or IsSecret(unit) then return false end
    local ok, result = pcall(UnitIsPlayer, unit)
    return ok and result
end

local function IsPFDepLoaded(name)
    if not name then return false end
    if C_AddOns and C_AddOns.IsAddOnLoaded then
        local loaded = C_AddOns.IsAddOnLoaded(name)
        if loaded then return true end
    end
    return SafeCall(IsAddOnLoaded, name) == true
end

local function GetNormalizedRealmNameSafe()
    return SafeCall(GetNormalizedRealmName)
end

local function SplitNameRealm(text)
    if not text or text == "" or IsSecret(text) then return nil, nil end
    if text:find("-", 1, true) then
        local n, r = strsplit("-", text, 2)
        if n and n ~= "" then return n, r end
        return nil, nil
    end
    return text, nil
end

local function DebugPrint(msg)
    if ParseFiendConfig and ParseFiendConfig.debug then
        print(msg)
    end
end

local function AppendUnknownIfDebug(tooltip)
    if tooltip and ParseFiendConfig and ParseFiendConfig.debug then
        tooltip:AddLine(" ")
        tooltip:AddDoubleLine("Parse Points|r", ParseFiend.Colors.GREY .. "Unknown|r")
    end
end

local function AppendParsePoints(tooltip, name, realm)
    -- `tooltip` is mandatory; guarantees we don't silently write into the
    -- wrong frame (e.g. GameTooltip when caller meant unit tooltip).
    if not tooltip or not name or IsSecret(name) or name == "" then
        AppendUnknownIfDebug(tooltip)
        return
    end

    local effectiveRealm = realm
    if not effectiveRealm or effectiveRealm == "" or IsSecret(realm) then
        effectiveRealm = GetNormalizedRealmNameSafe()
    end
    if not effectiveRealm or effectiveRealm == "" then
        AppendUnknownIfDebug(tooltip)
        return
    end

    local region  = SafeCall(ParseFiend.GetRegion, ParseFiend)
    local record  = SafeCall(ParseFiend.GetPlayerRecord, ParseFiend, name, effectiveRealm, region)

    if ParseFiendConfig and ParseFiendConfig.debug then
        -- The second line always uses the slug form so it's directly
        -- comparable to the database keys in Data.lua. The preceding
        -- `[Communities]` etc. line keeps the human-readable realm
        -- ("Quel'Thalas") so the source is unambiguous.
        -- NOTE: `ParseFiend.SlugifyRealm` is a free function attached to
        -- the namespace; do NOT pass `ParseFiend` as `self` — it's a
        -- static helper called with one positional arg (the realm).
        local realmKey = SafeCall(ParseFiend.SlugifyRealm, effectiveRealm)
                   or SafeCall(ParseFiend.NormalizeKey, effectiveRealm)
                   or effectiveRealm
        print("PF lookup=" .. name .. "-" .. realmKey .. " hit=" .. tostring(record and true or false))
    end

    if not record then
        AppendUnknownIfDebug(tooltip)
        return
    end

    local ppTable = record.pp
    if type(ppTable) ~= "table" or #ppTable < ParseFiend.PP_CELL_COUNT then
        AppendUnknownIfDebug(tooltip)
        return
    end

    local totalPoints = tonumber(SafeCall(ParseFiend.AggregateTotal, ParseFiend, ppTable)) or 0
    if totalPoints <= 0 then
        AppendUnknownIfDebug(tooltip)
        return
    end

    -- Determine the per‑difficulty and overall maximum points from the actual
    -- data set (each present boss cell is worth 100 points). This makes the
    -- colour/percent calculation tier‑agnostic: for a full 10‑boss tier the
    -- overall max is 4000 and each difficulty max is 1000, but it scales for
    -- partial data or any future tier size without code changes.
    local maxes = SafeCall(ParseFiend.ComputeMaxPoints, ParseFiend, ppTable)
              or { total = 0, lfr = 0, normal = 0, heroic = 0, mythic = 0 }
    if maxes.total <= 0 then
        AppendUnknownIfDebug(tooltip)
        return
    end

    local display = SafeCall(ParseFiend.FormatPP, ParseFiend, totalPoints, maxes.total)
    if not display then
        AppendUnknownIfDebug(tooltip)
        return
    end

    tooltip:AddLine(" ")
    tooltip:AddDoubleLine("Parse Points|r", display)

    -- When Alt, Shift or Ctrl is held, break the aggregate down by difficulty.
    -- Per‑difficulty rows are drawn directly under the total (no extra spacer)
    -- and listed from hardest to easiest.
    if (IsAltKeyDown and IsAltKeyDown()) or (IsShiftKeyDown and IsShiftKeyDown())
        or (IsControlKeyDown and IsControlKeyDown()) then
        local diffOrder = {
            { key = "mythic", label = "Mythic" },
            { key = "heroic", label = "Heroic" },
            { key = "normal", label = "Normal" },
            { key = "lfr",    label = "LFR"    },
        }

        for _, entry in ipairs(diffOrder) do
            local diffIdx = ParseFiend.DIFFICULTY_INDEX[entry.key]
            local diffPoints = SafeCall(ParseFiend.AggregateByDifficulty, ParseFiend, ppTable, diffIdx) or 0
            local diffDisplay = SafeCall(ParseFiend.FormatPP, ParseFiend, diffPoints, maxes[entry.key])
                or (ParseFiend.Colors.GREY .. "0|r")
            tooltip:AddDoubleLine(ParseFiend.Colors.WHITE .. entry.label .. "|r", diffDisplay)
        end
    end
end

local function Emit(tooltip, name, realm, source)
    if not tooltip or not name then return end
    DebugPrint("PF [" .. source .. "] name=" .. tostring(name) .. " realm=" .. tostring(realm or "<implicit>"))
    AppendParsePoints(tooltip, name, realm)
end

local function HookAllFrames(frames, hookMap)
    if not frames then return end
    for _, frame in ipairs(frames) do
        if frame and not frame.PF_Hooked then
            frame.PF_Hooked = true
            for eventName, callback in pairs(hookMap) do
                if frame.HasScript and frame:HasScript(eventName) then
                    frame:HookScript(eventName, callback)
                end
            end
        end
    end
end

-- RaiderIO's canonical helper: returns UnitToken if `tooltip` is a
-- Unit-type tooltip, otherwise nil. Avoids invoking GetPrimaryTooltipData
-- on non-Unit tooltips so we don't trigger unnecessary Cop tooltip work.
---@param tooltip GameTooltip
---@return UnitToken? unit, string? guid
local function GetTooltipUnit(tooltip)
    if not tooltip then return nil end

    -- Modern API path (Retail 12.x): check IsTooltipType first so we never
    -- generate a payload for non-Unit tooltips.
    if tooltip.IsTooltipType then
        if not tooltip:IsTooltipType(Enum.TooltipDataType.Unit) then return nil end
    end

    if tooltip.GetPrimaryTooltipData then
        local data = SafeCall(tooltip.GetPrimaryTooltipData, tooltip)
        if data and not IsSecret(data) and data.guid and not IsSecret(data.guid) then
            local unit = SafeCall(UnitTokenFromGUID, data.guid)
            if unit and not IsSecret(unit) then
                return unit, data.guid
            end
        end
    end

    -- Legacy / fallback path (older clients without IsTooltipType).
    if tooltip.GetUnit then
        local _, unit = SafeCall(tooltip.GetUnit, tooltip)
        if unit and not IsSecret(unit) then return unit end
    end

    -- mouseover fallback only valid if there's a player unit there.
    if SafeCall(UnitIsPlayer, "mouseover") then return "mouseover" end
    return nil
end

local function UnitTooltipHandler(tooltip, data)
    if not tooltip then return end
    if tooltip ~= GameTooltip then return end
    if data and data.type and Enum.TooltipDataType.Unit and data.type ~= Enum.TooltipDataType.Unit then
        return
    end

    local unit = GetTooltipUnit(tooltip)
    if not unit or not SafeUnitIsPlayer(unit) then return end

    -- `UnitName` returns `(name, realm)`. Both fields can be secret strings
    -- (when the source is a cross‑realm unit the Blizzard API marks as
    -- protected); any comparison against them while our execution is
    -- tainted will raise "attempt to compare secret string". Use the
    -- `IsSecret` helper to detect this and fall back to the implicit realm
    -- instead of touching the secret directly.
    local ok, name, realm = pcall(UnitName, unit)
    if not ok or not name or IsSecret(name) then return end
    if IsSecret(realm) or not realm then
        realm = GetNormalizedRealmNameSafe()
    end
    Emit(tooltip, name, realm, "Unit")
end

local function ResolveNameRealmFromFriendsButton(button)
    if not button or button.id == nil then return nil, nil end

    if button.buttonType == FRIENDS_BUTTON_TYPE_WOW then
        local info = SafeCall(C_FriendList.GetFriendInfoByIndex, button.id)
        if info and info.name and info.name ~= "" then
            return info.name, GetNormalizedRealmNameSafe()
        end
    elseif button.buttonType == FRIENDS_BUTTON_TYPE_BNET then
        local info = SafeCall(C_BattleNet.GetFriendAccountInfo, button.id)
        if info and info.gameAccountInfo then
            local gai = info.gameAccountInfo
            if gai.clientProgram == BNET_CLIENT_WOW and gai.characterName and gai.characterName ~= "" then
                local realm = gai.realmDisplayName or gai.realmName or GetNormalizedRealmNameSafe()
                return gai.characterName, realm
            end
        end
    end
    return nil, nil
end

local function SetupFriendsTooltip()
    if PF_Hooked.Friends or not FriendsFrame or not FriendsTooltip then return end
    PF_Hooked.Friends = true

    local function RegisterFriendsShowHook()
        if PF_Hooked.FriendsShowHook then return end
        PF_Hooked.FriendsShowHook = true

        hooksecurefunc(FriendsTooltip, "Show", function(self)
            local name, realm = ResolveNameRealmFromFriendsButton(self.button)
            if not name then return end

            DebugPrint("PF [Friends] name=" .. tostring(name) .. " realm=" .. tostring(realm or "<implicit>"))

            -- Archon pattern (Tooltip.lua line 326-330): when RaiderIO is
            -- loaded it owns the GameTooltip owner/clearing dance, so we
            -- must NOT touch SetOwner (it would re-show the tooltip and
            -- clear RaiderIO's already-appended lines). AppendParsePoints
            -- adds its own blank separator before the Parse Points line,
            -- so no extra GameTooltip_AddBlankLineToTooltip here. When
            -- RaiderIO is absent we re-anchor GameTooltip under the
            -- friend's row so parse points render visibly.
            if not PF_RaiderIoLoaded then
                GameTooltip:SetOwner(FriendsTooltip, "ANCHOR_BOTTOMRIGHT", -FriendsTooltip:GetWidth(), -4)
            end

            Emit(GameTooltip, name, realm, "Friends")
            GameTooltip:Show()
        end)
    end

    -- Archon pattern: late-register so other addons (RaiderIO) hook first.
    -- (Archon Tooltip.lua line 279-281: "don't hook instantly to ensure
    -- other addons (namely Raider) can hook before us otherwise raider sets
    -- the owner after us, which hides the tooltip and clears its lines")
    if FriendsFrame:IsShown() then
        RegisterFriendsShowHook()
    else
        FriendsFrame:HookScript("OnShow", RegisterFriendsShowHook)
    end
end

local function SetupWhoFrame()
    if PF_Hooked.Who or not WhoFrame or not WhoFrame.ScrollBox then return end
    PF_Hooked.Who = true

    local function OnListEnter(button)
        if not button or not button.index then return end
        local info = SafeCall(C_FriendList.GetWhoInfo, button.index)
        if not info or not info.fullName then return end
        local name, realm = SplitNameRealm(info.fullName)

        -- Archon pattern (Archon Tooltip.lua line 432-453): append inline
        -- during OnEnter. No C_Timer.After(0) — the Blizzard OnEnter has
        -- already populated GameTooltip by the time we run, and RaiderIO
        -- uses the same TooltipDataProcessor Unit post-call path so our
        -- AddLine/AddDoubleLine lands after their entries. AppendParsePoints
        -- adds its own blank separator line so no extra spacer is needed.
        -- Calling GameTooltip:Show() at the end (also Archon) ensures the
        -- tooltip is laid out/re-laid-out even when RaiderIO clears it via
        -- SetOwnerSafely upstream.
        Emit(GameTooltip, name, realm, "Who")
        GameTooltip:Show()
    end

    WhoFrame:HookScript("OnShow", function()
        local frames = SafeCall(WhoFrame.ScrollBox.GetFrames, WhoFrame.ScrollBox)
        if frames then
            HookAllFrames(frames, { OnEnter = OnListEnter })
        end

        if WhoFrame.ScrollBox.RegisterCallback and ScrollBoxListMixin and ScrollBoxListMixin.Event then
            WhoFrame.ScrollBox:RegisterCallback(ScrollBoxListMixin.Event.OnUpdate, function()
                local current = SafeCall(WhoFrame.ScrollBox.GetFrames, WhoFrame.ScrollBox)
                if current then HookAllFrames(current, { OnEnter = OnListEnter }) end
            end)
        end
    end)
end

local function SetupBlizzardCommunities()
    -- Archon style: wait for Blizzard_Communities to load before hooking.
    local function OnCommunitiesLoaded()
        if PF_Hooked.CommunitiesHooked then return end
        if not CommunitiesFrame or not CommunitiesFrame.MemberList then return end
        PF_Hooked.CommunitiesHooked = true

        local function OnGuildMembersLoaded(scrollBox)
            local function OnEntryEnter(button)
                if not button or not button.GetMemberInfo then return end
                local memberInfo = button:GetMemberInfo()
                if not memberInfo or not memberInfo.name or memberInfo.name == "" then return end
                local name, realm = SplitNameRealm(memberInfo.name)
                Emit(GameTooltip, name, realm, "Communities")
            end

            HookAllFrames(SafeCall(scrollBox.GetFrames, scrollBox), { OnEnter = OnEntryEnter })

            if scrollBox.RegisterCallback and ScrollBoxListMixin and ScrollBoxListMixin.Event then
                scrollBox:RegisterCallback(ScrollBoxListMixin.Event.OnUpdate, function()
                    HookAllFrames(SafeCall(scrollBox.GetFrames, scrollBox), { OnEnter = OnEntryEnter })
                end)
            end
        end

        OnGuildMembersLoaded(CommunitiesFrame.MemberList.ScrollBox)
    end

    if EventUtil and EventUtil.ContinueOnAddOnLoaded then
        EventUtil.ContinueOnAddOnLoaded("Blizzard_Communities", OnCommunitiesLoaded)
    elseif PF_Hooked.CommunitiesTried == nil then
        PF_Hooked.CommunitiesTried = true
        if IsPFDepLoaded("Blizzard_Communities") then
            OnCommunitiesLoaded()
        else
            local f = CreateFrame("Frame")
            f:RegisterEvent("ADDON_LOADED")
            f:SetScript("OnEvent", function(self, name)
                if name == "Blizzard_Communities" then
                    self:UnregisterEvent("ADDON_LOADED")
                    self:SetScript("OnEvent", nil)
                    OnCommunitiesLoaded()
                end
            end)
        end
    end
end

local function SetupLFGListTooltips()
    if PF_Hooked.LFG then return end
    PF_Hooked.LFG = true

    -- Archon pattern (Archon Tooltip.lua line 1061-1089): hook the
    -- Blizzard-emitted global `LFGListUtil_SetSearchEntryTooltip` to
    -- append to the LFG search-entry tooltip. The Blizzard function has
    -- signature `(tooltip, resultID, autoAcceptOption)` and is called
    -- from `LFGListSearchEntry_OnEnter` AFTER Blizzard adds its standard
    -- leader/activity/members lines but BEFORE the final `:Show()` —
    -- so any lines we add are part of the layout pass and survive.
    -- This is also the same hook RaiderIO uses (RaiderIO core.lua line
    -- 7817) — it's the canonical integration point for the LFG search
    -- panel tooltip on retail.
    local function OnLFGListUtilSearchEntry(tooltip, resultID)
        if not tooltip or not resultID then return end
        local info = SafeCall(C_LFGList.GetSearchResultInfo, resultID)
        if not info or not info.leaderName or info.leaderName == "" then return end
        local name, realm = SplitNameRealm(info.leaderName)
        Emit(tooltip, name, realm, "LFGListSearch")
    end

    local function ApplySearchEntryTooltipHook()
        if type(_G.LFGListUtil_SetSearchEntryTooltip) ~= "function" then return false end
        hooksecurefunc("LFGListUtil_SetSearchEntryTooltip", OnLFGListUtilSearchEntry)
        return true
    end

    -- ApplicationViewer (applicants): each row is a different template
    -- (LFGListFrameApplicantMemberTemplate) and DOES NOT have a `resultID`.
    -- Hook the Blizzard-emitted global `LFGListApplicantMember_OnEnter(self)`
    -- so we get the button. Archon does the same (Tooltip.lua line 1007).
    local function OnLFGListApplicantRowEnter(button)
        if not button then return end
        -- `applicantID` lives on the parent frame, not on the row itself
        -- (Archon Tooltip.lua line 986).
        local parent = button:GetParent()
        if not parent then return end
        local applicantID = parent.applicantID
        if not applicantID then return end
        local memberIdx = button.memberIdx
        if not memberIdx then return end
        -- `GetApplicantMemberInfo` returns `(name, class, localizedClass,
        -- level, ...)`. Character `name` is "Name-Realm" cross-realm, or
        -- just "Name" same-realm. Empty means we can't show anything.
        local charName = SafeCall(C_LFGList.GetApplicantMemberInfo, applicantID, memberIdx)
        if not charName or charName == "" then return end
        local name, realm = SplitNameRealm(charName)
        Emit(GameTooltip, name, realm, "LFGListApplicant")
    end

    local function ApplyGroupFinderGlobalHooks()
        local hooked = ApplySearchEntryTooltipHook()
        if type(_G.LFGListApplicantMember_OnEnter) == "function" then
            hooksecurefunc("LFGListApplicantMember_OnEnter", OnLFGListApplicantRowEnter)
            hooked = true
        end
        return hooked
    end

    if not ApplyGroupFinderGlobalHooks() then
        local g = CreateFrame("Frame")
        g:RegisterEvent("ADDON_LOADED")
        g:SetScript("OnEvent", function(self, name)
            if name == "Blizzard_GroupFinder" or name == "Blizzard_LFGList" then
                if ApplyGroupFinderGlobalHooks() then
                    self:UnregisterEvent("ADDON_LOADED")
                    self:SetScript("OnEvent", nil)
                end
            end
        end)
    end
end

-- Archon pattern (Init.lua line 104-131): track RaiderIO loaded state so
-- our Show hooks can take a different code path. If RaiderIO is loaded we
-- must NOT call SetOwner() — RaiderIO already owns the GameTooltip lifetime
-- and re-anchoring triggers its hide/clear sequence, stomping our content.
if IsPFDepLoaded("RaiderIO") then
    PF_RaiderIoLoaded = true
elseif EventUtil and EventUtil.ContinueOnAddOnLoaded then
    EventUtil.ContinueOnAddOnLoaded("RaiderIO", OnRaiderIoLoaded)
else
    local rioFrame = CreateFrame("Frame")
    rioFrame:RegisterEvent("ADDON_LOADED")
    rioFrame:SetScript("OnEvent", function(self, name)
        if name == "RaiderIO" then
            OnRaiderIoLoaded()
            self:UnregisterEvent("ADDON_LOADED")
            self:SetScript("OnEvent", nil)
        end
    end)
end

-- TooltipDataProcessor: only the Unit type, matching Archon/RaiderIO.
-- We intentionally do NOT register MinimapMouseover (separate data flow,
-- the mouseover fallback inside ResolveUnitFromTooltip already covers it).
if Enum and Enum.TooltipDataType and Enum.TooltipDataType.Unit and TooltipDataProcessor then
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Unit, UnitTooltipHandler)
end

-- Single setup frame, listens for PLAYER_LOGIN; Blizzard's setup frames
-- like FriendsFrame/CommunitiesFrame are lazily loaded and Ar/Ra addon-
-- tracked below via dedicated entry points.
local setupFrame = CreateFrame("Frame")
setupFrame:RegisterEvent("PLAYER_LOGIN")
setupFrame:SetScript("OnEvent", function(_, event)
    if event ~= "PLAYER_LOGIN" then return end

    pcall(SetupFriendsTooltip)
    pcall(SetupWhoFrame)
    pcall(SetupBlizzardCommunities)
    pcall(SetupLFGListTooltips)

    if ParseFiendConfig and ParseFiendConfig.debug then
        print("PF init RAIDERIO=" .. tostring(IsPFDepLoaded("RaiderIO")) ..
              " ARCHON=" .. tostring(IsPFDepLoaded("ArchonTooltip")) ..
              " COMMUNITY=" .. tostring(IsPFDepLoaded("Blizzard_Communities")))
    end
end)

-- =====================================================================
-- /who chat output
-- Patterns and approach mirror Archon (Archon Chat.lua) and RaiderIO
-- (RaiderIO core.lua WhoChatFrame module line 6710-6775). We:
--   1. Hook `CHAT_MSG_SYSTEM` via `ChatFrame_AddMessageEventFilter`.
--   2. Match the `WHO_LIST_FORMAT` (no guild) / `WHO_LIST_GUILD_FORMAT`
--      (with guild) global patterns. Lazy-build once.
--   3. Extract (nameLink, name, level) via the same capture positions.
--   4. Resolve Name-Realm from `nameLink` (handles cross-realm) or fall
--      back to `name` + local realm when no link is rendered.
--   5. Look up the ParseFiend record. If found and total>0, append
--      ` - Parse Points: N` to the message text.
--   6. Return `false, modifiedText, ...rest` so the upstream message is
--      replaced but not blocked. *Because filters run in registration
--      order and we register at PLAYER_LOGIN (after RaiderIO registers
--      during its own module init), our filter receives RaiderIO's
--      already-patched text as `text` — so we naturally append AFTER
--      their ` - RIO Score: NN` segment.
-- =====================================================================

-- Archon's pattern-to-lua converter (Archon Chat.lua line 6-20).
local function PF_FormatToPattern(text)
    text = text:gsub("%%", "%%%%")
    text = text:gsub("%.", "%%%.")
    text = text:gsub("%?", "%%%?")
    text = text:gsub("%+", "%%%+")
    text = text:gsub("%-", "%%%-")
    text = text:gsub("%(", "%%%(")
    text = text:gsub("%)", "%%%)")
    text = text:gsub("%[", "%%%[")
    text = text:gsub("%]", "%%%]")
    text = text:gsub("%%%%s", "(.-)")
    text = text:gsub("%%%%d", "(%%d+)")
    text = text:gsub("%%%%%%[%d%.%,]+f", "([%%d%%.%%,]+)")
    return text
end

local PF_WhoPatterns
local function PF_BuildWhoPatterns()
    if PF_WhoPatterns then return PF_WhoPatterns end
    if type(WHO_LIST_GUILD_FORMAT) ~= "string" or type(WHO_LIST_FORMAT) ~= "string" then
        return nil
    end
    -- Anchor at start only (`^`) — NOT at end. When RaiderIO has already
    -- appended ` - RIO Score: NN` to the text, our pattern still matches
    -- the leading WHO-list portion and we read out the name/link/level
    -- captures. The trailing Rio data goes through unchanged because we
    -- return `text .. suffix` and only suffix changes the end.
    PF_WhoPatterns = {
        guild = "^" .. PF_FormatToPattern(WHO_LIST_GUILD_FORMAT),
        nogl  = "^" .. PF_FormatToPattern(WHO_LIST_FORMAT),
    }
    return PF_WhoPatterns
end

-- Extract (name, realm) from a chat link `|Hplayer:Name-Realm|h[Name]|h`.
-- Returns nil for both if not parseable.
local function PF_ResolveNameLink(linkText)
    if not linkText or linkText == "" then return nil, nil end
    local data = linkText:match("^|Hplayer:(.-)|h")
    if not data then return nil, nil end
    return SplitNameRealm(data)
end

local PF_WhoFilterRegistered = false
local function PF_RegisterWhoChatFilter()
    if PF_WhoFilterRegistered then return end
    PF_WhoFilterRegistered = true

    local patterns = PF_BuildWhoPatterns()
    if not patterns then return end

    -- Archon pattern (Archon Chat.lua line 79-83): prefer the newer
    -- EventUtil/ChatFrameUtil API, fall back to the classic global.
    -- Filters stack in registration order; we run after RaiderIO since
    -- we register at PLAYER_LOGIN (after RAID/C_Timer based addons
    -- have already installed their filters), which means we see the
    -- already-appended RaiderIO text as the `text` argument and append
    -- *after* it.
    local function OnWhoChatMessage(self, event, text, ...)
        if event ~= "CHAT_MSG_SYSTEM" then return false end

        -- Try guild-format first, fall back to no-guild. Mirrors Archon
        -- Chat.lua line 34-38 and RaiderIO core.lua line 6743-6751.
        -- Discarded `_` capture positions line up with the WHO-list
        -- layout but Parse Points doesn't care about level/race/class
        -- here — only the character identity matters.
        local nameLink, name
        nameLink, name, _, _, _, _, _ = text:match(patterns.guild)
        if not nameLink then
            nameLink, name = text:match(patterns.nogl)
        end
        if not nameLink or not name then
            return false
        end

        local charName, charRealm = PF_ResolveNameLink(nameLink)
        if not charName then
            charName = name
            charRealm = GetNormalizedRealmNameSafe()
        end
        if not charName or charName == "" or IsSecret(charName) then return false end

        local region = SafeCall(ParseFiend.GetRegion, ParseFiend)
        local record = SafeCall(ParseFiend.GetPlayerRecord, ParseFiend, charName, charRealm, region)
        if not record then return false end

        local ppTable = record.pp
        if type(ppTable) ~= "table" or #ppTable < ParseFiend.PP_CELL_COUNT then
            return false
        end
        local total = tonumber(SafeCall(ParseFiend.AggregateTotal, ParseFiend, ppTable)) or 0
        if total <= 0 then return false end

        local maxes = SafeCall(ParseFiend.ComputeMaxPoints, ParseFiend, ppTable)
                  or { total = 0, lfr = 0, normal = 0, heroic = 0, mythic = 0 }
        if maxes.total <= 0 then return false end

        local display = SafeCall(ParseFiend.FormatPP, ParseFiend, total, maxes.total)
        if not display then return false end

        local suffix = " - Parse Points: " .. display

        if ParseFiendConfig and ParseFiendConfig.debug then
            print("PF [WhoChat] name=" .. charName .. "-" .. (charRealm or "?") ..
                  " total=" .. total)
        end

        return false, text .. suffix, ...
    end

    if ChatFrameUtil and ChatFrameUtil.AddMessageEventFilter then
        ChatFrameUtil.AddMessageEventFilter("CHAT_MSG_SYSTEM", OnWhoChatMessage)
    else
        ChatFrame_AddMessageEventFilter("CHAT_MSG_SYSTEM", OnWhoChatMessage)
    end
end

-- Hook the chat filter setup into PLAYER_LOGIN so we register after
-- addon init (RaiderIO has already installed their filter by then).
local chatFilterFrame = CreateFrame("Frame")
chatFilterFrame:RegisterEvent("PLAYER_LOGIN")
chatFilterFrame:SetScript("OnEvent", function(_, event)
    if event ~= "PLAYER_LOGIN" then return end
    pcall(PF_RegisterWhoChatFilter)
end)
