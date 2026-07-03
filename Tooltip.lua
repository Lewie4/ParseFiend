local PF_Hooked = {}

-- Global alias; available at retail logo frame.
-- Direct call avoids creating a closure-then-calling every hover.
local IsSecretValue = issecretvalue or function() return false end

-- SafeCall is used only for APIs that throw on secret/invalid inputs:
--   * UnitName, UnitTokenFromGUID (return secret or taint-throw)
--   * C_FriendList.*, C_BattleNet.*, C_LFGList.* (namespace calls can throw
--     in restricted contexts)
-- Sacrificing IS-safe APIs (GetNormalizedRealmName, IsAddOnLoaded,
-- SelectUnit, etc.) for performance: each pcall frames a closure on
-- every hover and we hover a lot.
local function SafeCall(fn, ...)
    local ok, a, b = pcall(fn, ...)
    if not ok then return nil, nil end
    return a, b
end

local function IsPFDepLoaded(name)
    if not name or name == "" then return false end
    -- C_AddOns.IsAddOnLoaded is the modern, non-throwing API. The classic
    -- IsAddOnLoaded(name) is also safe but we don't need to cover it.
    if C_AddOns and C_AddOns.IsAddOnLoaded then
        local loaded = C_AddOns.IsAddOnLoaded(name)
        if loaded and loaded ~= "missing" then return true end
    end
    return false
end

-- GetNormalizedRealmName is documented to never throw; safe direct call.
-- PLAYER_ENTERING_WORLD fires on login, reload, and zone transitions
-- (rare). Clearing the cache on each event costs us nothing and keeps the
-- cache consistent with all rare scenarios without a dedicated frame.
local _cachedRealm
local function GetCurrentRealm()
    if _cachedRealm then return _cachedRealm end
    _cachedRealm = GetNormalizedRealmName()
    return _cachedRealm
end

local function SplitNameRealm(text)
    if not text or text == "" or IsSecretValue(text) then return nil, nil end
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
    if not tooltip or not name or IsSecretValue(name) or name == "" then
        AppendUnknownIfDebug(tooltip)
        return
    end

    local effectiveRealm = (realm and realm ~= "" and not IsSecretValue(realm)) and realm or GetCurrentRealm()
    if not effectiveRealm or effectiveRealm == "" then
        AppendUnknownIfDebug(tooltip)
        return
    end

    -- Direct calls into ParseFiend namespace; these are pure Lua and
    -- never throw, so we don't need the SafeCall frame overhead.
    local record = ParseFiend.GetPlayerRecord(ParseFiend, name, effectiveRealm, ParseFiend.GetRegion(ParseFiend))

    if not record then
        AppendUnknownIfDebug(tooltip)
        return
    end

    local ppTable = record.pp
    if type(ppTable) ~= "table" or #ppTable < ParseFiend.PP_CELL_COUNT then
        AppendUnknownIfDebug(tooltip)
        return
    end

    local totalPoints = ParseFiend.AggregateTotal(ParseFiend, ppTable)
    if totalPoints <= 0 then
        AppendUnknownIfDebug(tooltip)
        return
    end

    local ppColor = ParseFiend:GetPPColor(totalPoints) or ParseFiend.Colors.GREY

    tooltip:AddLine(" ")
    tooltip:AddDoubleLine("Parse Points|r", ppColor .. tostring(totalPoints) .. "|r")
end

local function Emit(tooltip, name, realm, source)
    if not tooltip or not name then return end
    DebugPrint("PF [" .. source .. "] name=" .. tostring(name) .. " realm=" .. tostring(realm or "<implicit>"))
    AppendParsePoints(tooltip, name, realm)
end

-- Cached by iterating with #frames for slightly faster dense-array walk
-- (skipping ipairs function-call overhead per iteration). ScrollBox
-- `:GetFrames()` returns a dense integer-keyed array.
local function HookAllFrames(frames, hookMap)
    if not frames then return end
    for i = 1, #frames do
        local frame = frames[i]
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

-- RaiderIO's canonical helper (core.lua:551): returns UnitToken if
-- `tooltip` is a Unit-type tooltip, otherwise nil. Avoids invoking
-- GetPrimaryTooltipData on non-Unit tooltips so we don't trigger
-- unnecessary Cop tooltip work. We use direct (non-pcall) calls
-- with explicit `issecretvalue` gating, which is the lightweight
-- pattern used by the reference addons.
---@param tooltip GameTooltip
---@return UnitToken? unit, string? guid
local function GetTooltipUnit(tooltip)
    if not tooltip then return nil end

    -- Modern API path (Retail 12.x): check IsTooltipType first.
    if tooltip.IsTooltipType then
        if not tooltip:IsTooltipType(Enum.TooltipDataType.Unit) then return nil end
    end

    -- GetPrimaryTooltipData runs only when we know we want Unit data.
    local data = tooltip.GetPrimaryTooltipData and tooltip:GetPrimaryTooltipData()
        or nil
    local guid = data and data.guid
    if guid and not IsSecretValue(guid) then
        local unit = UnitTokenFromGUID(guid)
        if unit then return unit, guid end
    end

    -- Legacy / fallback path (older clients without IsTooltipType).
    if tooltip.GetUnit then
        local _, unit = tooltip:GetUnit()
        if unit and not IsSecretValue(unit) then return unit end
    end

    -- mouseover fallback only valid if there's an actual player unit there.
    -- "mouseover" is a literal unit-id string, never a secret value, so this
    -- collapses to two cheap calls.
    if UnitExists("mouseover") and UnitIsPlayer("mouseover") then
        return "mouseover"
    end
    return nil
end

local function UnitTooltipHandler(tooltip, data)
    if not tooltip then return end
    if tooltip ~= GameTooltip then return end
    if data and data.type and Enum.TooltipDataType.Unit and data.type ~= Enum.TooltipDataType.Unit then
        return
    end

    local unit = GetTooltipUnit(tooltip)
    -- `unit` is already validated (non-secret, real unit). UnitIsPlayer can
    -- throw on secret input but we never pass a secret.
    if not unit or not UnitIsPlayer(unit) then return end

    -- `UnitName` returns `(name, realm)`. pcall is required because in
    -- rare taint cases it can be a secret value.
    local ok, name, realm = pcall(UnitName, unit)
    if not ok or not name then return end
    if not realm or realm == "" then realm = GetCurrentRealm() end
    Emit(tooltip, name, realm, "Unit")
end

local function ResolveNameRealmFromFriendsButton(button)
    if not button or button.id == nil then return nil, nil end

    if button.buttonType == FRIENDS_BUTTON_TYPE_WOW then
        local info = SafeCall(C_FriendList.GetFriendInfoByIndex, button.id)
        if info and info.name and info.name ~= "" then
            return info.name, GetCurrentRealm()
        end
    elseif button.buttonType == FRIENDS_BUTTON_TYPE_BNET then
        local info = SafeCall(C_BattleNet.GetFriendAccountInfo, button.id)
        if info and info.gameAccountInfo then
            local gai = info.gameAccountInfo
            if gai.clientProgram == BNET_CLIENT_WOW and gai.characterName and gai.characterName ~= "" then
                local realm = gai.realmDisplayName or gai.realmName or GetCurrentRealm()
                return gai.characterName, realm
            end
        end
    end
    return nil, nil
end

local function SetupFriendsTooltip()
    print("PFDBG [Friends] SetupFriendsTooltip called; FF=" .. tostring(FriendsFrame) .. " FT=" .. tostring(FriendsTooltip))
    if PF_Hooked.Friends then return end
    PF_Hooked.Friends = true

    local function RegisterFriendsShowHook()
        if PF_Hooked.FriendsShowHook then return end
        PF_Hooked.FriendsShowHook = true
        print("PFDBG [Friends] RegisterFriendsShowHook now installing hooksecurefunc on FriendsTooltip:Show")

        hooksecurefunc(FriendsTooltip, "Show", function(self)
            if PF_Hooked.FriendsShowInFlight then return end
            PF_Hooked.FriendsShowInFlight = true

            local button = self.button
            print("PFDBG [Friends] Show fired; button=" .. tostring(button) .. " type=" .. tostring(button and button.buttonType) .. " id=" .. tostring(button and button.id))
            local name, realm = ResolveNameRealmFromFriendsButton(button)
            if not name then
                print("PFDBG [Friends] ResolveNameRealmFromFriendsButton returned nil name; aborting")
                PF_Hooked.FriendsShowInFlight = nil
                return
            end

            DebugPrint("PF [Friends] name=" .. tostring(name) .. " realm=" .. tostring(realm or "<implicit>"))
            -- Write directly to the FriendsTooltip frame we hooked, NOT to
            -- GameTooltip. FriendsTooltip renders its own content separately
            -- from GameTooltip.
            Emit(self, name, realm, "Friends")
            -- Force a re-layout so the lines we just added render. Without
            -- this, AddLine/AddDoubleLine after Show() can leave the new
            -- strings invisible because the tooltip height is already settled.
            self:Show()
            PF_Hooked.FriendsShowInFlight = nil
        end)
    end

    if FriendsFrame:IsShown() then
        print("PFDBG [Friends] FF already shown; registering hook now")
        RegisterFriendsShowHook()
    else
        print("PFDBG [Friends] FF hidden; HookScript(OnShow, RegisterFriendsShowHook)")
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
        Emit(GameTooltip, name, realm, "Who")
        -- Re-show so newly-added lines re-layout (Blizzard already
        -- finalised the tooltip height on initial HookScript OnEnter).
        GameTooltip:Show()
    end

    WhoFrame:HookScript("OnShow", function()
        local frames = WhoFrame.ScrollBox:GetFrames()
        if frames then HookAllFrames(frames, { OnEnter = OnListEnter }) end

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
    -- Note: CommunitiesFrame exists at PLAYER_LOGIN, but MemberList's
    -- ScrollBox is populated lazily when the player actually opens the
    -- panel. The OnShow hook covers first-open; the OnUpdate callback
    -- (registered on the ScrollBox) covers later scroll/render updates.
    print("PFDBG [Communities] SetupBlizzardCommunities called; CFs=" .. tostring(CommunitiesFrame))
    local function OnCommunitiesLoaded()
        print("PFDBG [Communities] OnCommunitiesLoaded entered; PF_Hooked=" .. tostring(PF_Hooked.CommunitiesFrameHooked) .. " MemberList=" .. tostring(CommunitiesFrame and CommunitiesFrame.MemberList))
        if PF_Hooked.CommunitiesFrameHooked then return end
        if not CommunitiesFrame or not CommunitiesFrame.MemberList then
            print("PFDBG [Communities] No CommunitiesFrame or MemberList yet; aborting setup")
            return
        end
        PF_Hooked.CommunitiesFrameHooked = true

        local function MemberListOnEnter(button)
            print("PFDBG [Communities] MemberListOnEnter fired; btn=" .. tostring(button) .. " hasGetMemberInfo=" .. tostring(button and button.GetMemberInfo ~= nil))
            if not button or not button.GetMemberInfo then return end
            local memberInfo = button:GetMemberInfo()
            print("PFDBG [Communities] memberInfo=" .. tostring(memberInfo) .. " name=" .. tostring(memberInfo and memberInfo.name))
            if not memberInfo or not memberInfo.name or memberInfo.name == "" then return end
            local name, realm = SplitNameRealm(memberInfo.name)
            Emit(GameTooltip, name, realm, "Communities")
            print("PFDBG [Communities] appended to tooltip; name=" .. tostring(name) .. " realm=" .. tostring(realm))
            -- Re-show so the new lines are positioned; without this the
            -- tooltip was finalised at the previous Show call.
            GameTooltip:Show()
        end

        local function Reframe()
            if not CommunitiesFrame.MemberList then
                print("PFDBG [Communities] Reframe: no MemberList")
                return
            end
            local scrollBox = CommunitiesFrame.MemberList.ScrollBox
            if not scrollBox then
                print("PFDBG [Communities] Reframe: no ScrollBox")
                return
            end
            HookAllFrames(SafeCall(scrollBox.GetFrames, scrollBox), { OnEnter = MemberListOnEnter })
        end

        -- Initial pass: hooks any rows already rendered at PLAYER_LOGIN
        -- (rare but possible if CommunitiesFrame built itself early).
        Reframe()

        -- ScrollBox reflows as new rows appear; re-hook each rebuild.
        if CommunitiesFrame.MemberList.ScrollBox
            and CommunitiesFrame.MemberList.ScrollBox.RegisterCallback
            and ScrollBoxListMixin
            and ScrollBoxListMixin.Event
        then
            CommunitiesFrame.MemberList.ScrollBox:RegisterCallback(ScrollBoxListMixin.Event.OnUpdate, Reframe)
        end

        -- First-open: the panel is built lazily when the player opens the
        -- CommunitiesUI. OnShow fires then and re-installs hooks for any
        -- rows now in the scrollbox that weren't there at login.
        CommunitiesFrame:HookScript("OnShow", Reframe)
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

    -- Search panel: button has `resultID` directly (LFGListFrameSearchEntryTemplate)
    local function HookSearchEntryEnter(button)
        if not button then return end
        local id = (button.GetResultID and button:GetResultID()) or button.resultID
        if not id then return end
        local info = SafeCall(C_LFGList.GetSearchResultInfo, id)
        if not info or not info.leaderName or info.leaderName == "" then return end
        local name, realm = SplitNameRealm(info.leaderName)
        Emit(GameTooltip, name, realm, "LFGListSearch")
        GameTooltip:Show()
    end

    local function HookSearchScrollBox(scrollBox)
        if not scrollBox then return end

        local function Reframe()
            HookAllFrames(SafeCall(scrollBox.GetFrames, scrollBox), { OnEnter = HookSearchEntryEnter })
        end

        if LFGListFrame then
            LFGListFrame:HookScript("OnShow", Reframe)
        end
        if scrollBox.RegisterCallback and ScrollBoxListMixin and ScrollBoxListMixin.Event then
            scrollBox:RegisterCallback(ScrollBoxListMixin.Event.OnUpdate, Reframe)
        end
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
        GameTooltip:Show()
    end

    local function ApplyApplicantGlobalHook()
        if type(_G.LFGListApplicantMember_OnEnter) == "function" then
            hooksecurefunc("LFGListApplicantMember_OnEnter", OnLFGListApplicantRowEnter)
            return true
        end
        return false
    end

    if not ApplyApplicantGlobalHook() then
        local g = CreateFrame("Frame")
        g:RegisterEvent("ADDON_LOADED")
        g:SetScript("OnEvent", function(self, name)
            if name == "Blizzard_GroupFinder" or name == "Blizzard_LFGList" then
                if ApplyApplicantGlobalHook() then
                    self:UnregisterEvent("ADDON_LOADED")
                    self:SetScript("OnEvent", nil)
                end
            end
        end)
    end

    if LFGListFrame and LFGListFrame.SearchPanel and LFGListFrame.SearchPanel.ScrollBox then
        HookSearchScrollBox(LFGListFrame.SearchPanel.ScrollBox)
    end
end

-- TooltipDataProcessor: only the Unit type, matching Archon/RaiderIO.
if Enum and Enum.TooltipDataType and Enum.TooltipDataType.Unit and TooltipDataProcessor then
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Unit, UnitTooltipHandler)
end

-- =====================================================================
-- SETUP REGISTRY
-- =====================================================================
-- Each entry in `_SETUPS` is `{ name, fn }`; the boot loop runs them once
-- at PLAYER_LOGIN. Adding a new tooltip source = appending a new module
-- here. Each setup MUST be idempotent (it is -- PF_Hooked gates re-entry)
-- AND MUST guard its dependencies (typical: `if not Frame then return end`).
local _SETUPS = {
    { "Friends",     SetupFriendsTooltip },
    { "Who",         SetupWhoFrame },
    { "Communities", SetupBlizzardCommunities },
    { "LFG",         SetupLFGListTooltips },
}

local setupFrame = CreateFrame("Frame")
setupFrame:RegisterEvent("PLAYER_LOGIN")
setupFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
setupFrame:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_LOGIN" then
        for _, mod in ipairs(_SETUPS) do
            pcall(mod.fn)
        end
        -- Drop the realm cache on subsequent world entries; PLAYER_LOGIN
        -- cached the value, ENTERING_WORLD only fires later transitions.
    elseif event == "PLAYER_ENTERING_WORLD" then
        _cachedRealm = nil
    end

    if ParseFiendConfig and ParseFiendConfig.debug then
        print("PF init/" .. event ..
              " RAID=" .. tostring(IsPFDepLoaded("RaiderIO")) ..
              " ARCH=" .. tostring(IsPFDepLoaded("ArchonTooltip")) ..
              " COMM=" .. tostring(IsPFDepLoaded("Blizzard_Communities")))
    end
end)

