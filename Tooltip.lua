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
        print("PF lookup=" .. name .. "-" .. effectiveRealm .. " hit=" .. tostring(record and true or false))
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

    local ppColor = ParseFiend:GetPPColor(totalPoints) or ParseFiend.Colors.GREY

    tooltip:AddLine(" ")
    tooltip:AddDoubleLine("Parse Points|r", ppColor .. tostring(totalPoints) .. "|r")
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

    -- `UnitName` returns `(name, realm)`. Multi-return through pcall
    -- drops values past the first by default; capture explicitly.
    local ok, name, realm = pcall(UnitName, unit)
    if not ok or not name then return end
    if not realm or realm == "" then realm = GetNormalizedRealmNameSafe() end
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
        Emit(GameTooltip, name, realm, "Who")
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

    -- Search panel: button has `resultID` directly (LFGListFrameSearchEntryTemplate)
    local function HookSearchEntryEnter(button)
        if not button then return end
        local id = (button.GetResultID and button:GetResultID()) or button.resultID
        if not id then return end
        local info = SafeCall(C_LFGList.GetSearchResultInfo, id)
        if not info or not info.leaderName or info.leaderName == "" then return end
        local name, realm = SplitNameRealm(info.leaderName)
        Emit(GameTooltip, name, realm, "LFGListSearch")
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
