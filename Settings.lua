local AddonName = ... or "ParseFiend"

-- =====================================================================
-- OPTIONS PANEL TOGGLE
-- =====================================================================
-- Set this flag to `true` to re‑enable the ParseFiend entry under
-- Esc > Options > AddOns and the `/pf settings` slash command.
-- All the registration code below is preserved; this flag is the only
-- switch that needs to be flipped to bring the panel back.
local REGISTER_OPTIONS_PANEL = false
-- =====================================================================

-- Single forward declaration. The actual implementation is assigned below
-- only when the Settings API registration succeeds; calling /pf before that
-- fails loudly with a clear error rather than silently no-op'ing like the
-- old empty local did.
local OpenSettings = function() print("|cffff5555ParseFiend|r - settings UI not available on this client.") end

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")

frame:SetScript("OnEvent", function(self, event, ...) 
    if event ~= "ADDON_LOADED" then return end
    local addonName = ...
    if addonName ~= AddonName then return end
    if REGISTER_OPTIONS_PANEL and Settings and Settings.RegisterAddOnCategory and Settings.RegisterVerticalLayoutCategory then
        local category = Settings.RegisterVerticalLayoutCategory("ParseFiend")
        if category then
            local function GetValue()
                return ParseFiendConfig and ParseFiendConfig.debug
            end

            local function SetValue(value)
                if ParseFiendConfig then ParseFiendConfig.debug = value end
            end

            local setting = Settings.RegisterProxySetting(
                category,
                "PARSEFIEND_DEV",
                Settings.VarType.Boolean,
                "Debug",
                Settings.Default.False,
                GetValue,
                SetValue
            )

            Settings.CreateCheckbox(category, setting, "Enable developer logging in tooltips.")

            Settings.RegisterAddOnCategory(category)

            -- Reassign only after the registration succeeded. Anything
            -- already calling /pf before this point gets the safe no-op.
            OpenSettings = function()
                Settings.OpenToCategory(category.ID)
            end
        end
    end

    if AddonCompartmentFrame then
        AddonCompartmentFrame:RegisterAddon({
            text = "ParseFiend",
            icon = C_AddOns.GetAddOnMetadata(AddonName, "IconTexture"),
            registerForAnyClick = true,
            notCheckable = true,
            func = function() OpenSettings() end,
            funcOnEnter = function(self)
                if MenuUtil and MenuUtil.ShowTooltip then
                    MenuUtil.ShowTooltip(self, function(tooltip)
                        GameTooltip:SetText("ParseFiend", 1, 1, 1)
                        GameTooltip:AddLine("Click to open settings.")
                    end)
                else
                    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
                    GameTooltip:SetText("ParseFiend", 1, 1, 1)
                    GameTooltip:AddLine("Click to open settings.")
                    GameTooltip:Show()
                end
            end,
            funcOnLeave = function(self)
                if MenuUtil and MenuUtil.HideTooltip then
                    MenuUtil.HideTooltip(self)
                else
                    GameTooltip:Hide()
                end
            end,
        })
    end

    SLASH_PARSEFIEND1 = "/parsefiend"
    SLASH_PARSEFIEND2 = "/pf"

    SlashCmdList["PARSEFIEND"] = function(message)
        local command = (message or ""):match("^(%S+)") or ""

        if command == "d" then
            ParseFiendConfig.debug = not ParseFiendConfig.debug
            print("|cff00ff96ParseFiend|r - Debug mode " .. (ParseFiendConfig.debug and "enabled" or "disabled") .. ".")
        elseif command == "rc" or command == "readycheck" then
            if DoReadyCheck then
                DoReadyCheck()
            elseif SlashCmdList and SlashCmdList["READYCHECK"] then
                SlashCmdList["READYCHECK"]("")
            else
                print("|cffff5555ParseFiend|r - Ready check command not available on this client.")
            end
        elseif command == "options" or command == "settings" or command == "" then
            OpenSettings()
        else
            print("|cff00ff96ParseFiend|r - available commands:")
            print("/pf settings - Open the ParseFiend settings panel.")
            print("/pf d - Toggle debug mode.")
            print("/pf rc - Issue a ready check.")
        end
    end
end)
