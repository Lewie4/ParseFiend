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

local function ResolveUnitFromTooltip(tooltip)
    if tooltip and tooltip.GetUnit then
        local _, unit = SafeCall(tooltip.GetUnit, tooltip)
        if unit and not IsSecret(unit) then
            return unit
        end
    end

    if tooltip and tooltip.GetPrimaryTooltipData then
        local data = SafeCall(tooltip.GetPrimaryTooltipData, tooltip)
        if data and not IsSecret(data) then
            local guid = data.guid
            if guid and not IsSecret(guid) then
                local unit = SafeCall(UnitTokenFromGUID, guid)
                if unit and not IsSecret(unit) then
                    return unit
                end
            end
        end
    end

    if not IsSecret("mouseover") and SafeUnitIsPlayer("mouseover") then
        return "mouseover"
    end

    return nil
end

local function ResolveCharacterFromTooltip(tooltip)
    local unit = ResolveUnitFromTooltip(tooltip)
    if not unit then return nil end

    if not SafeUnitIsPlayer(unit) then return nil end

    local name, realm = SafeCall(UnitFullName, unit)
    if not name then
        name, realm = SafeCall(UnitName, unit)
    end

    if not name or name == "" or IsSecret(name) then return nil end

    if not realm or realm == "" or IsSecret(realm) then
        realm = SafeCall(GetNormalizedRealmName)
    end

    if not realm or realm == "" then return nil end

    return name, realm
end

local function AppendParsePoints(tooltip, data, name, realm)
    local lookupKey = realm:gsub("%s+", "")
    local pfData = ParseFiendDB and ParseFiendDB[name .. "-" .. lookupKey]

    if ParseFiendConfig and ParseFiendConfig.debug then
        print("PF   lookup=" .. (name or "?") .. "-" .. (realm or "?") ..
            " hit=" .. tostring(pfData and true or false))
    end

    if not pfData then return end

    local ppColor = ParseFiend and ParseFiend.GetPPColor
        and ParseFiend:GetPPColor(pfData.pp)
        or "|cff1eff00"

    tooltip:AddLine(" ")
    tooltip:AddDoubleLine(
        "Parse Points|r",
        ppColor .. pfData.pp .. "|r"
    )
end

local function DebugProbe(label, tooltip, data)
    if not (ParseFiendConfig and ParseFiendConfig.debug) then return end

    print("PF [" .. label .. "] type=" .. tostring(data and data.type) ..
        " guid=" .. tostring(data and data.guid) ..
        " name=" .. tostring(data and data.name) ..
        " realm=" .. tostring(data and data.realm) ..
        " fullName=" .. tostring(data and data.fullName))

    local unit = ResolveUnitFromTooltip(tooltip)
    print("PF   unit=" .. tostring(unit) ..
        " isPlayer=" .. tostring(unit and SafeUnitIsPlayer(unit)))

    if unit and SafeUnitIsPlayer(unit) then
        local name, realm = ResolveCharacterFromTooltip(tooltip)
        print("PF   resolved=" .. tostring(name) .. "-" .. tostring(realm))
    end
end

local function UnitTooltipProcessor(tooltip, data)
    DebugProbe("Unit", tooltip, data)
    if not SafeUnitIsPlayer(data and data.unitToken or "mouseover") then
        local name, realm = ResolveCharacterFromTooltip(tooltip)
        if name and realm then
            AppendParsePoints(tooltip, data, name, realm)
        end
        return
    end

    local name, realm = ResolveCharacterFromTooltip(tooltip)
    if name and realm then
        AppendParsePoints(tooltip, data, name, realm)
    end
end

local function GetPlayerRealmFromFullName(fullName)
    if not fullName or fullName == "" or IsSecret(fullName) then return nil, nil end
    local name, realm = strsplit("-", fullName)
    if not realm or realm == "" then
        realm = SafeCall(GetNormalizedRealmName)
    end
    if not realm or realm == "" then return name, nil end
    return name, realm
end

local function FriendTooltipProcessor(tooltip, data)
    DebugProbe("Friend", tooltip, data)
    if ParseFiendConfig and ParseFiendConfig.debug then
        local dbgUnit = ResolveUnitFromTooltip(tooltip)
        local dbgName, dbgRealm = ResolveCharacterFromTooltip(tooltip)
        print("PF [Friend Debug] unit="..tostring(dbgUnit))
        print("PF [Friend Debug] resolved via unit name="..tostring(dbgName).." realm="..tostring(dbgRealm))
        print("PF [Friend Debug] data.fullName="..tostring(data and data.fullName).." data.name="..tostring(data and data.name))
        if data then
            for k,v in pairs(data) do
                print("PF [Friend Debug] data field "..tostring(k).." = "..tostring(v))
            end
        end
    end
    -- First attempt to resolve via unit token (handles Battle.net friends showing current character)
    local name, realm = ResolveCharacterFromTooltip(tooltip)
    if not (name and realm) then
        -- Try using GUID if provided
        if data and data.guid then
            local unit = SafeCall(UnitTokenFromGUID, data.guid)
            if unit then
                name, realm = SafeCall(UnitFullName, unit)
                if not name then
                    name = SafeCall(UnitName, unit)
                end
                if not realm or realm == "" then
                    realm = SafeCall(GetNormalizedRealmName)
                end
            end
        end
        if not (name and realm) then
            local fullName = data and (data.fullName or data.name)
            name, realm = GetPlayerRealmFromFullName(fullName)
        end
    end
    if name and realm then AppendParsePoints(tooltip, data, name, realm) end
end

local function GuildMemberTooltipProcessor(tooltip, data)
    DebugProbe("Guild", tooltip, data)
    local name = data and data.name
    local realm = data and (data.realm or data.guildRealm)
    if name and (not realm or realm == "") then
        realm = SafeCall(GetNormalizedRealmName)
    end
    if name and realm then AppendParsePoints(tooltip, data, name, realm) end
end

local function WhoTooltipProcessor(tooltip, data)
    DebugProbe("Who", tooltip, data)
    local fullName = data and (data.fullName or data.name)
    local name, realm = GetPlayerRealmFromFullName(fullName)
    if name and realm then AppendParsePoints(tooltip, data, name, realm) end
end

local function SearchTooltipProcessor(tooltip, data)
    DebugProbe("Search", tooltip, data)
    local name = data and data.name
    local realm = data and (data.realm or data.serverName)
    if name and (not realm or realm == "") then
        realm = SafeCall(GetNormalizedRealmName)
    end
    if name and realm then AppendParsePoints(tooltip, data, name, realm) end
end

TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Unit, UnitTooltipProcessor)
TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Friend, FriendTooltipProcessor)
TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.GuildMember, GuildMemberTooltipProcessor)
TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.ClubMessageInfo, FriendTooltipProcessor)
TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.ClubFinderMember, SearchTooltipProcessor)
TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Who, WhoTooltipProcessor)
TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.GuildFinderApplicant, SearchTooltipProcessor)
TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.PvPFinderApplicant, SearchTooltipProcessor)
TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.LFGListSearchEntry, SearchTooltipProcessor)
