local function TooltipProcessor(tooltip, data)

    if not data or not data.guid then
        return
    end
	
	if ParseFiendConfig and ParseFiendConfig.debug then
        print("ParseFiend GUID:", data.guid)
    end

    local pfData = ParseFiendDB[data.guid]

    if not pfData then
        return
    end

    local ppColor = ParseFiend:GetPPColor(pfData.pp)

    tooltip:AddLine(" ")

    -- Parse Points (COLOURED)
    tooltip:AddDoubleLine(
        "Parse Points|r",
        ppColor .. pfData.pp .. "|r"
    )

    -- World Rank (WHITE)
    -- tooltip:AddDoubleLine(
    --    "|cffffffffWorld Rank|r",
    --    "|cffffffff#" .. pfData.rank .. "|r"
    --)

end

TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Unit, TooltipProcessor)