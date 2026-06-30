local function AddTooltipData(tooltip)

    local _, unit = tooltip:GetUnit()

    if not unit then
        return
    end

    if not UnitIsPlayer(unit) then
        return
    end

    local name, realm = UnitName(unit)

    if realm == "" then
        realm = GetRealmName()
    end

    local data = ParseFiend:GetPlayerData(name, realm)

    if not data then
        return
    end

    tooltip:AddLine(" ")

    tooltip:AddDoubleLine(
        "|cff00ff96Parse Points|r",
        "|cffffff00" .. data.pp .. "|r"
    )

    tooltip:AddDoubleLine(
        "World Rank",
        "#" .. data.rank
    )

    tooltip:Show()

end

GameTooltip:HookScript("OnTooltipSetUnit", function(self)
    AddTooltipData(self)
end)