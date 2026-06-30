local AddonName = ...

local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_LOGIN")

local function OpenSettings() end

frame:SetScript("OnEvent", function()
	if Settings and Settings.RegisterAddOnCategory and Settings.RegisterVerticalLayoutCategory then
		local category = Settings.RegisterVerticalLayoutCategory("ParseFiend")

		do
			local function GetValue()
				return ParseFiendConfig.debug
			end

			local function SetValue(value)
				ParseFiendConfig.debug = value
			end

			local setting = Settings.RegisterProxySetting(
				category,
				"PARSEFIEND_DEV",
				Settings.VarType.Boolean,
				"Dev",
				Settings.Default.False,
				GetValue,
				SetValue
			)

			Settings.CreateCheckbox(category, setting, "Enable developer logging in tooltips.")
		end

		Settings.RegisterAddOnCategory(category)

		OpenSettings = function()
			Settings.OpenToCategory(category.ID)
		end
	end

	if AddonCompartmentFrame then
		AddonCompartmentFrame:RegisterAddon({
			text = "ParseFiend",
			icon = C_AddOns.GetAddOnMetadata(AddonName, "IconTexture"),
			registerForAnyClick = true,
			notCheckable = true,
			func = OpenSettings,
			funcOnEnter = function()
				if MenuUtil and MenuUtil.ShowTooltip then
					MenuUtil.ShowTooltip(AddonCompartmentFrame, function(tooltip)
						GameTooltip:SetText("ParseFiend", 1, 1, 1)
						GameTooltip:AddLine("Click to open settings.")
					end)
				else
					GameTooltip:SetOwner(AddonCompartmentFrame, "ANCHOR_LEFT")
					GameTooltip:SetText("ParseFiend", 1, 1, 1)
					GameTooltip:AddLine("Click to open settings.")
					GameTooltip:Show()
				end
			end,
			funcOnLeave = function()
				if MenuUtil.HideTooltip then
					MenuUtil.HideTooltip(AddonCompartmentFrame)
				else
					GameTooltip:Hide()
				end
			end,
		})
	end

	SLASH_PARSEFIEND1 = "/parsefiend"

	SlashCmdList["PARSEFIEND"] = function(message)
		local command = message:match("^(%S+)")

		if command == "options" or command == "settings" or command == "" then
			OpenSettings()
		else
			print("|cff00ff96ParseFiend|r - available commands:")
			print("/parsefiend settings - Open the ParseFiend settings panel.")
		end
	end
end)
