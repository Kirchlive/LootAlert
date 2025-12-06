-- LootAlert
-- Add any item to watchlist and get notified when it drops or posted by raid.

-- Default Settings
local LootAlert_DefaultSettings = {
	enabled = "yes",
	scale = 1,
	auto_close = "yes",
	auto_close_delay = 10,
	tooltips = "yes",
	sound = "yes",
	item_list = {},
}

-- Main addon table
local LootAlert = {}
LootAlert.alertFrame = nil
LootAlert.autoCloseTimer = 0
LootAlert.currentItemLink = nil
LootAlert.currentLooter = nil
LootAlert.itemQueryTimer = 0.5
LootAlert.itemQueryRetries = 5

-- Cache item by creating a tooltip (like LootBlare2.0's CacheItem function)
local function LootAlert_CacheItem(itemLink)
	if (not itemLink) then
		return nil
	end

	-- Extract hyperlink (item:ID:0:0:0 format)
	local _, _, hyperlink = string.find(itemLink, "|H(item:[^|]+)|h")

	if (not hyperlink) then
		return nil
	end

	-- Store the extracted hyperlink for GetItemInfo to use later
	LootAlert.currentHyperlink = hyperlink

	-- Create a NEW tooltip each time (this forces WoW to query the server)
	local tooltipName = "LootAlertCache" .. GetTime()
	local tooltip = CreateFrame("GameTooltip", tooltipName, nil, "GameTooltipTemplate")
	tooltip:SetOwner(UIParent, "ANCHOR_NONE")

	-- Cache the item via tooltip
	pcall(function()
		tooltip:SetHyperlink(hyperlink)
	end)

	tooltip:Hide()
	return hyperlink
end

-- Item Quality Colors
local ITEM_QUALITY_COLORS = {
	[0] = {r=0.62, g=0.62, b=0.62},  -- Poor (Gray)
	[1] = {r=1.00, g=1.00, b=1.00},  -- Common (White)
	[2] = {r=0.12, g=1.00, b=0.00},  -- Uncommon (Green)
	[3] = {r=0.00, g=0.44, b=0.87},  -- Rare (Blue)
	[4] = {r=0.64, g=0.21, b=0.93},  -- Epic (Purple)
	[5] = {r=1.00, g=0.50, b=0.00},  -- Legendary (Orange)
	[6] = {r=0.90, g=0.80, b=0.50},  -- Artifact (Gold)
}

-- Initialize the addon
local function LootAlert_Initialize()
	if (not LootAlert_Config) then
		LootAlert_Config = {}
	end

	if (not LootAlert_Config[LootAlert_Player]) then
		LootAlert_Config[LootAlert_Player] = {}
	end

	-- Apply default settings
	for key, value in pairs(LootAlert_DefaultSettings) do
		if (LootAlert_Config[LootAlert_Player][key] == nil) then
			if (type(value) == "table") then
				LootAlert_Config[LootAlert_Player][key] = {}
				for k, v in pairs(value) do
					LootAlert_Config[LootAlert_Player][key][k] = v
				end
			else
				LootAlert_Config[LootAlert_Player][key] = value
			end
		end
	end

	-- Register slash commands
	SlashCmdList["LOOTALERT"] = LootAlert_Command
	SLASH_LOOTALERT1 = "/la"
	SLASH_LOOTALERT2 = "/lootalert"

	-- Initialize alert frame reference
	LootAlert.alertFrame = LootAlert_AlertFrame

	-- Set black background color
	if (LootAlert.alertFrame) then
		LootAlert.alertFrame:SetBackdropColor(0, 0, 0, 0.95)  -- Schwarz mit 95% Deckkraft
		LootAlert.alertFrame:SetBackdropBorderColor(0, 0, 0, 0)  -- Kein Rahmen
	end

	-- Set Remove button text to yellow (to match close button X)
	local removeButton = getglobal(LootAlert.alertFrame:GetName() .. "_RemoveButton")
	if (removeButton) then
		local buttonText = getglobal(removeButton:GetName() .. "Text")
		if (buttonText) then
			buttonText:SetTextColor(1, 0.82, 0)  -- Gelb wie das X
		end
	end

	-- Create icon texture dynamically (like LootBlare does)
	if (LootAlert.alertFrame and not LootAlert.alertFrame.iconTexture) then
		-- Remove old icon if exists
		local oldIcon = getglobal(LootAlert.alertFrame:GetName() .. "_Icon")
		if (oldIcon) then
			oldIcon:Hide()
		end

		-- Create new icon texture on OVERLAY layer to ensure it's on top
		LootAlert.alertFrame.iconTexture = LootAlert.alertFrame:CreateTexture(nil, "OVERLAY")
		LootAlert.alertFrame.iconTexture:SetWidth(44)
		LootAlert.alertFrame.iconTexture:SetHeight(44)
		-- Position 7px higher: -50 + 7 = -43
		LootAlert.alertFrame.iconTexture:SetPoint("TOP", LootAlert.alertFrame, "TOP", 0, -36)
		LootAlert.alertFrame.iconTexture:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
		LootAlert.alertFrame.iconTexture:SetAlpha(1)
		LootAlert.alertFrame.iconTexture:SetTexCoord(0.07, 0.93, 0.07, 0.93)  -- Standard icon border crop
	end

	LootAlert_Print("v1.0.0 - /la for help")
end

-- OnLoad handler
function LootAlert_OnLoad()
	LootAlert_Player = (UnitName("player").." - "..GetRealmName())
	this:RegisterEvent("VARIABLES_LOADED")
	this:RegisterEvent("PLAYER_ENTERING_WORLD")
	this:RegisterEvent("CHAT_MSG_LOOT")
	this:RegisterEvent("CHAT_MSG_SYSTEM")
	this:RegisterEvent("CHAT_MSG_PARTY")
	this:RegisterEvent("CHAT_MSG_RAID")
	this:RegisterEvent("CHAT_MSG_RAID_WARNING")
	this:RegisterEvent("CHAT_MSG_RAID_LEADER")
end

-- Event handler
function LootAlert_OnEvent(event, arg1, arg2, arg3, arg4, arg5, arg6, arg7, arg8, arg9)
	if (event == "VARIABLES_LOADED") then
		this:UnregisterEvent("VARIABLES_LOADED")
		LootAlert_Initialize()
	elseif (event == "PLAYER_ENTERING_WORLD") then
		this:UnregisterEvent("PLAYER_ENTERING_WORLD")
		LootAlertFrame:SetScale(LootAlert_Config[LootAlert_Player]["scale"] * UIParent:GetScale())
	elseif (event == "CHAT_MSG_LOOT" or event == "CHAT_MSG_SYSTEM" or event == "CHAT_MSG_PARTY" or event == "CHAT_MSG_RAID" or event == "CHAT_MSG_RAID_WARNING" or event == "CHAT_MSG_RAID_LEADER") then
		if (LootAlert_Config[LootAlert_Player]["enabled"] == "yes") then
			LootAlert_ParseChatMessage(arg1, arg2)  -- arg2 = sender
		end
	end
end

-- Extract all item links from a message (like LootBlare's ExtractItemLinksFromMessage)
local function LootAlert_ExtractItemLinks(message)
	if (not message) then return {} end

	local links = {}
	local startPos = 1

	-- Find all item links in the message: |cXXXXXXXX|Hitem:ID:...|h[Name]|h|r
	while true do
		local linkStart, linkEnd, fullLink = string.find(message, "(|c%x+|Hitem:[^|]+|h%[.-%]|h|r)", startPos)
		if (not linkStart) then break end

		table.insert(links, fullLink)
		startPos = linkEnd + 1
	end

	return links
end

-- Parse chat messages for loot
function LootAlert_ParseChatMessage(message, sender)
	if (not message) then return end

	local looter = sender or "Unknown"
	local itemLink = nil

	-- Try each pattern manually (vanilla safe)
	local i, j, match1, match2

	-- Pattern 1: "(.+) receives? loot: (.+)%."
	i, j, match1, match2 = string.find(message, "(.+) receives? loot: (.+)%.")
	if (match1 and match2) then
		looter = match1
		itemLink = match2
	end

	-- Pattern 2: "You receive loot: (.+)%."
	if (not itemLink) then
		i, j, match1 = string.find(message, "You receive loot: (.+)%.")
		if (match1) then
			looter = UnitName("player")
			itemLink = match1
		end
	end

	-- Pattern 3: "(.+) receives item: (.+)%."
	if (not itemLink) then
		i, j, match1, match2 = string.find(message, "(.+) receives item: (.+)%.")
		if (match1 and match2) then
			looter = match1
			itemLink = match2
		end
	end

	-- Pattern 4: German "(.+) erh\195\164lt Beute: (.+)%."
	if (not itemLink) then
		i, j, match1, match2 = string.find(message, "(.+) erh\195\164lt Beute: (.+)%.")
		if (match1 and match2) then
			looter = match1
			itemLink = match2
		end
	end

	-- Pattern 5: German "Ihr erhaltet Beute: (.+)%."
	if (not itemLink) then
		i, j, match1 = string.find(message, "Ihr erhaltet Beute: (.+)%.")
		if (match1) then
			looter = UnitName("player")
			itemLink = match1
		end
	end

	-- If no loot pattern matched, try to extract any item link from the message
	-- This handles: Master Looter announcements, raid warnings, etc.
	if (not itemLink) then
		local links = LootAlert_ExtractItemLinks(message)
		if (links and table.getn(links) > 0) then
			-- Use the first item link found
			itemLink = links[1]
			-- For non-loot messages, we don't know who will get it
			looter = "Announced"
		end
	end

	-- Check if we found an item
	if (itemLink) then
		LootAlert_CheckItemMatch(itemLink, looter)
	end
end

-- Check if item matches watched list
function LootAlert_CheckItemMatch(itemLink, looter)
	if (not itemLink) then return end

	-- Extract item name from link
	local itemName = LootAlert_GetItemNameFromLink(itemLink)

	if (not itemName) then return end

	-- Check if item is in watch list
	if (LootAlert_Config[LootAlert_Player]["item_list"][itemName]) then
		LootAlert_ShowAlert(itemLink, looter)
	end
end

-- Extract item name from item link
function LootAlert_GetItemNameFromLink(itemLink)
	if (not itemLink) then return nil end

	-- Try to extract from link format |cXXXXXXXX|Hitem:...|h[ItemName]|h|r
	local _, _, name = string.find(itemLink, "%[(.+)%]")

	if (name) then
		return name
	end

	-- If not a link, return as-is
	return itemLink
end

-- Show alert frame
function LootAlert_ShowAlert(itemLink, looter)
	-- Initialize alert frame reference if not done yet
	if (not LootAlert.alertFrame) then
		LootAlert.alertFrame = getglobal("LootAlert_AlertFrame")
	end

	if (not LootAlert.alertFrame) then
		return
	end

	-- Store current item data
	LootAlert.currentItemLink = itemLink
	LootAlert.currentLooter = looter or "Unknown"

	-- Reset timers
	LootAlert.autoCloseTimer = 0
	LootAlert.itemQueryTimer = 0.5  -- Query every 0.5 seconds
	LootAlert.itemQueryRetries = 5  -- Try 5 times

	-- Cache the item immediately
	LootAlert_CacheItem(itemLink)

	-- Try to update frame (will show question mark if item not ready)
	LootAlert_UpdateAlertFrame()

	-- Play sound
	if (LootAlert_Config[LootAlert_Player]["sound"] == "yes") then
		PlaySound("AuctionWindowOpen")
	end

	-- Show the frame
	LootAlert.alertFrame:Show()
end

-- Update alert frame with item data
function LootAlert_UpdateAlertFrame()
	if (not LootAlert.alertFrame) then
		return false
	end
	if (not LootAlert.currentItemLink) then
		return false
	end

	-- Use the hyperlink that CacheItem extracted and stored
	-- This is CRITICAL because currentItemLink might be just "[ItemName]"
	-- but we need the actual "item:ID:0:0:0" format
	local hyperlink = LootAlert.currentHyperlink
	if (not hyperlink) then
		return false
	end

	-- Try GetItemInfo (works after item is cached by tooltip)
	local itemName, itemLink, itemRarity, _, _, _, _, _, itemTexture = GetItemInfo(hyperlink)

	-- If GetItemInfo failed, show placeholder and return false
	if (not itemName or not itemTexture) then
		-- Show question mark as placeholder
		local icon = LootAlert.alertFrame.iconTexture
		if (icon) then
			icon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
			icon:Show()
		end

		-- Set name from link
		local nameLabel = getglobal(LootAlert.alertFrame:GetName() .. "_ItemNameLabel")
		if (nameLabel) then
			local fallbackName = LootAlert_GetItemNameFromLink(LootAlert.currentItemLink)
			nameLabel:SetText(fallbackName or "Loading...")
		end

		return false  -- Item not ready yet
	end

	-- Update dropped label
	local droppedLabel = getglobal(LootAlert.alertFrame:GetName() .. "_DroppedLabel")
	droppedLabel:SetText("DROPPED!")

	-- Update icon (use dynamically created texture)
	local icon = LootAlert.alertFrame.iconTexture
	if (not icon) then
		return false
	end
	icon:SetTexture(itemTexture)
	icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)  -- Standard icon border crop
	icon:SetVertexColor(1, 1, 1)  -- Ensure icon has full color (not tinted)
	icon:SetAlpha(1)
	icon:Show()

	-- Update icon border with quality color
	local iconBorder = getglobal(LootAlert.alertFrame:GetName() .. "_IconBorder")
	local qualityColor = ITEM_QUALITY_COLORS[itemRarity or 1]
	if (iconBorder) then
		iconBorder:SetVertexColor(qualityColor.r, qualityColor.g, qualityColor.b)
	end

	-- Update item name with quality color
	local itemNameText = getglobal(LootAlert.alertFrame:GetName() .. "_ItemName")
	local colorCode = string.format("|cff%02x%02x%02x", qualityColor.r * 255, qualityColor.g * 255, qualityColor.b * 255)
	itemNameText:SetText(colorCode .. itemName .. "|r")

	return true  -- Successfully updated
end

-- Hide alert frame
function LootAlert_HideAlert()
	if (LootAlert.alertFrame) then
		LootAlert.alertFrame:Hide()
		LootAlert.currentItemLink = nil
		LootAlert.currentLooter = nil
		LootAlert.autoCloseTimer = 0
	end
end

-- Alert frame OnUpdate (for auto-close timer and item query retries)
function LootAlert_AlertFrame_OnUpdate(elapsed)
	if (not LootAlert.alertFrame:IsVisible()) then return end

	-- Auto-close timer
	if (LootAlert_Config[LootAlert_Player]["auto_close"] == "yes") then
		LootAlert.autoCloseTimer = LootAlert.autoCloseTimer + elapsed

		if (LootAlert.autoCloseTimer >= LootAlert_Config[LootAlert_Player]["auto_close_delay"]) then
			LootAlert_HideAlert()
			return
		end
	end

	-- Item query retry timer
	if (LootAlert.itemQueryRetries > 0) then
		LootAlert.itemQueryTimer = LootAlert.itemQueryTimer - elapsed

		if (LootAlert.itemQueryTimer < 0) then
			-- Try to cache the item (creates tooltip which queries server)
			LootAlert_CacheItem(LootAlert.currentItemLink)

			-- Try to update the frame
			local success = LootAlert_UpdateAlertFrame()

			if (success) then
				LootAlert.itemQueryRetries = 0
			else
				-- Decrement retries and reset timer
				LootAlert.itemQueryRetries = LootAlert.itemQueryRetries - 1
				LootAlert.itemQueryTimer = 0.5  -- Try again in 0.5 seconds
			end
		end
	end
end

-- Alert frame mouse down handler (frei beweglich - kein Shift nötig!)
function LootAlert_AlertFrame_OnMouseDown(button)
	if (button == "LeftButton") then
		-- Nur bewegen, wenn nicht auf den Close-Button geklickt wurde
		LootAlert.alertFrame:StartMoving()
		LootAlert.alertFrame.isMoving = true
	end
end

-- Alert frame mouse up handler
function LootAlert_AlertFrame_OnMouseUp(button)
	if (button == "LeftButton") then
		LootAlert.alertFrame:StopMovingOrSizing()
		LootAlert.alertFrame.isMoving = false
	end
end

-- Icon button OnEnter (tooltip)
function LootAlert_IconButton_OnEnter()
	if (LootAlert_Config[LootAlert_Player]["tooltips"] == "yes" and LootAlert.currentItemLink) then
		-- Use the stored hyperlink for tooltip
		local hyperlink = LootAlert.currentHyperlink
		if (hyperlink) then
			-- ANCHOR_CURSOR = Tooltip folgt der Maus-Position
			GameTooltip:SetOwner(this, "ANCHOR_CURSOR")
			-- Protect against invalid links
			local success = pcall(function()
				GameTooltip:SetHyperlink(hyperlink)
			end)
			if (success) then
				GameTooltip:Show()
			end
		end
	end
end

-- Icon button OnClick
function LootAlert_IconButton_OnClick(button)
	if (button == "LeftButton" and LootAlert.currentItemLink) then
		-- Insert item link into chat
		if (ChatFrameEditBox:IsVisible()) then
			ChatFrameEditBox:Insert(LootAlert.currentItemLink)
		end
	end
end

-- Remove button OnClick - Removes item from watch list and closes alert
function LootAlert_RemoveButton_OnClick()
	if (not LootAlert.currentItemLink) then
		return
	end

	-- Extract item name from current item
	local itemName = LootAlert_GetItemNameFromLink(LootAlert.currentItemLink)

	if (itemName) then
		-- Remove from watch list
		if (LootAlert_Config[LootAlert_Player]["item_list"][itemName]) then
			LootAlert_Config[LootAlert_Player]["item_list"][itemName] = nil
			LootAlert_Print("Removed from watch list: |cff00ccff" .. itemName .. "|r")
		end
	end

	-- Close the alert window
	LootAlert_HideAlert()
end

-- Print message to chat
function LootAlert_Print(msg)
	DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00LootAlert|r: " .. msg)
end

-- Add item to watch list
function LootAlert_AddItem(itemInput)
	if (not itemInput or itemInput == "") then
		LootAlert_Print("Please specify an item name.")
		return
	end

	-- Store original input (might be item link)
	local originalInput = itemInput

	-- Extract item name from link if provided
	local itemName = LootAlert_GetItemNameFromLink(itemInput)

	-- Add to list
	LootAlert_Config[LootAlert_Player]["item_list"][itemName] = 1

	-- Check if input was already a link
	if (string.find(originalInput, "|H")) then
		-- Input was an item link, use it directly
		DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00LootAlert|r: Now watching for: " .. originalInput)
	else
		-- Plain text, show colored name
		LootAlert_Print("Now watching for: |cff00ccff" .. itemName .. "|r")
		LootAlert_Print("Tip: Shift-click an item to add it with full item link.")
	end
end

-- Remove item from watch list
function LootAlert_RemoveItem(itemInput)
	if (not itemInput or itemInput == "") then
		LootAlert_Print("Please specify an item name.")
		return
	end

	-- Store original input (might be item link)
	local originalInput = itemInput

	-- Extract item name from link if provided
	local itemName = LootAlert_GetItemNameFromLink(itemInput)

	-- Remove from list
	if (LootAlert_Config[LootAlert_Player]["item_list"][itemName]) then
		LootAlert_Config[LootAlert_Player]["item_list"][itemName] = nil

		-- Check if input was an item link
		if (string.find(originalInput, "|H")) then
			DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00LootAlert|r: No longer watching for: " .. originalInput)
		else
			LootAlert_Print("No longer watching for: |cff00ccff" .. itemName .. "|r")
		end
	else
		-- Item not found
		if (string.find(originalInput, "|H")) then
			DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00LootAlert|r: Item not found in watch list: " .. originalInput)
		else
			LootAlert_Print("Item not found in watch list: |cff00ccff" .. itemName .. "|r")
		end
	end
end

-- List all watched items
function LootAlert_ListItems()
	local count = 0
	LootAlert_Print("Currently watched items:")

	for itemName, _ in pairs(LootAlert_Config[LootAlert_Player]["item_list"]) do
		-- Show item name with color
		DEFAULT_CHAT_FRAME:AddMessage("  |cff00ccff" .. itemName .. "|r")
		count = count + 1
	end

	if (count == 0) then
		DEFAULT_CHAT_FRAME:AddMessage("  |cffcccccc(no items)|r")
	else
		DEFAULT_CHAT_FRAME:AddMessage("|cff888888Total: " .. count .. " items|r")
	end
end

-- Show help
function LootAlert_ShowHelp()
	DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00LootAlert|r Commands:")
	DEFAULT_CHAT_FRAME:AddMessage("/la |cff00ccffinfo|r - Show addon info")
	DEFAULT_CHAT_FRAME:AddMessage("/la |cff00ccfflist|r - List all watched items")
	DEFAULT_CHAT_FRAME:AddMessage("/la |cff00ccffadd [item]|r - Add item to watch list")
	DEFAULT_CHAT_FRAME:AddMessage("/la |cff00ccffdel [item]|r - Remove item from watch list")
	DEFAULT_CHAT_FRAME:AddMessage("/la |cff00ccffconfig|r - Show configuration commands")
end

-- Show config help
function LootAlert_ShowConfig()
	DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00LootAlert|r Configuration:")
	DEFAULT_CHAT_FRAME:AddMessage("/la |cff00ccffscale [0.5-3.0]|r - Set frame scale")
	DEFAULT_CHAT_FRAME:AddMessage("/la |cff00ccffautoclose|r - Toggle auto-close")
	DEFAULT_CHAT_FRAME:AddMessage("/la |cff00ccffdelay [1-60]|r - Set auto-close delay (seconds)")
	DEFAULT_CHAT_FRAME:AddMessage("/la |cff00cccfsound|r - Toggle sound alerts")
	DEFAULT_CHAT_FRAME:AddMessage("/la |cff00ccfftooltips|r - Toggle tooltips")
	DEFAULT_CHAT_FRAME:AddMessage("/la |cff00ccffstatus|r - Show current settings")
	DEFAULT_CHAT_FRAME:AddMessage("|cffccccccTip: LeftClick and drag to move alert frame|r")
end

-- Show addon info
function LootAlert_ShowInfo()
	LootAlert_Print("Version 1.0")
	LootAlert_Print("Add any item to watchlist and get notified when it drops or posted by raid")
	LootAlert_Print("Type |cff00ccff/la|r for help")
end

-- Show current status
function LootAlert_ShowStatus()
	LootAlert_Print("Current Settings:")
	LootAlert_Print("Enabled: |cff00ccff" .. LootAlert_Config[LootAlert_Player]["enabled"] .. "|r")
	LootAlert_Print("Scale: |cff00ccff" .. LootAlert_Config[LootAlert_Player]["scale"] .. "|r")
	LootAlert_Print("Auto-close: |cff00ccff" .. LootAlert_Config[LootAlert_Player]["auto_close"] .. "|r")
	LootAlert_Print("Auto-close delay: |cff00ccff" .. LootAlert_Config[LootAlert_Player]["auto_close_delay"] .. "s|r")
	LootAlert_Print("Sound: |cff00ccff" .. LootAlert_Config[LootAlert_Player]["sound"] .. "|r")
	LootAlert_Print("Tooltips: |cff00ccff" .. LootAlert_Config[LootAlert_Player]["tooltips"] .. "|r")

	local count = 0
	for _ in pairs(LootAlert_Config[LootAlert_Player]["item_list"]) do
		count = count + 1
	end
	LootAlert_Print("Watched items: |cff00ccff" .. count .. "|r")
end

-- Test alert display
function LootAlert_TestAlert()
	-- Create a proper epic item link (purple/epic color)
	local testLink = "|cffa335ee|Hitem:19019:0:0:0:0:0:0:0|h[Thunderfury, Blessed Blade of the Windseeker]|h|r"
	LootAlert_ShowAlert(testLink, UnitName("player"))
	LootAlert_Print("Test alert displayed!")
	LootAlert_Print("Note: Test uses default icon. Real looted items will show correct icons.")
end

-- Main command handler
function LootAlert_Command(msg)
	if (not msg) then msg = "" end

	-- Parse command and parameters (vanilla compatible)
	local i, j, cmd, param = string.find(msg, "^([^ ]+) (.+)$")
	if (not cmd) then
		cmd = msg
	end
	cmd = string.lower(cmd or "")

	if (cmd == "" or cmd == "help") then
		LootAlert_ShowHelp()
	elseif (cmd == "info") then
		LootAlert_ShowInfo()
	elseif (cmd == "list") then
		LootAlert_ListItems()
	elseif (cmd == "add") then
		LootAlert_AddItem(param)
	elseif (cmd == "del" or cmd == "delete" or cmd == "remove") then
		LootAlert_RemoveItem(param)
	elseif (cmd == "config") then
		LootAlert_ShowConfig()
	elseif (cmd == "status") then
		LootAlert_ShowStatus()
	elseif (cmd == "test") then
		LootAlert_TestAlert()
	elseif (cmd == "scale") then
		if (tonumber(param) and tonumber(param) >= 0.5 and tonumber(param) <= 3.0) then
			LootAlert_Config[LootAlert_Player]["scale"] = tonumber(param)
			LootAlertFrame:SetScale(LootAlert_Config[LootAlert_Player]["scale"] * UIParent:GetScale())
			LootAlert_Print("Scale set to: |cff00ccff" .. param .. "|r")
		else
			LootAlert_Print("Please specify a number between 0.5 and 3.0")
			LootAlert_Print("Current scale: |cff00ccff" .. LootAlert_Config[LootAlert_Player]["scale"] .. "|r")
		end
	elseif (cmd == "autoclose") then
		if (LootAlert_Config[LootAlert_Player]["auto_close"] == "yes") then
			LootAlert_Config[LootAlert_Player]["auto_close"] = "no"
			LootAlert_Print("Auto-close |cffff0000disabled|r")
		else
			LootAlert_Config[LootAlert_Player]["auto_close"] = "yes"
			LootAlert_Print("Auto-close |cff00ff00enabled|r")
		end
	elseif (cmd == "delay") then
		if (tonumber(param) and tonumber(param) >= 1 and tonumber(param) <= 60) then
			LootAlert_Config[LootAlert_Player]["auto_close_delay"] = tonumber(param)
			LootAlert_Print("Auto-close delay set to: |cff00ccff" .. param .. "s|r")
		else
			LootAlert_Print("Please specify a number between 1 and 60")
			LootAlert_Print("Current delay: |cff00ccff" .. LootAlert_Config[LootAlert_Player]["auto_close_delay"] .. "s|r")
		end
	elseif (cmd == "sound") then
		if (LootAlert_Config[LootAlert_Player]["sound"] == "yes") then
			LootAlert_Config[LootAlert_Player]["sound"] = "no"
			LootAlert_Print("Sound alerts |cffff0000disabled|r")
		else
			LootAlert_Config[LootAlert_Player]["sound"] = "yes"
			LootAlert_Print("Sound alerts |cff00ff00enabled|r")
		end
	elseif (cmd == "tooltips") then
		if (LootAlert_Config[LootAlert_Player]["tooltips"] == "yes") then
			LootAlert_Config[LootAlert_Player]["tooltips"] = "no"
			LootAlert_Print("Tooltips |cffff0000disabled|r")
		else
			LootAlert_Config[LootAlert_Player]["tooltips"] = "yes"
			LootAlert_Print("Tooltips |cff00ff00enabled|r")
		end
	elseif (cmd == "enable") then
		LootAlert_Config[LootAlert_Player]["enabled"] = "yes"
		LootAlert_Print("LootAlert |cff00ff00enabled|r")
	elseif (cmd == "disable") then
		LootAlert_Config[LootAlert_Player]["enabled"] = "no"
		LootAlert_HideAlert()
		LootAlert_Print("LootAlert |cffff0000disabled|r")
	else
		LootAlert_Print("Unknown command. Type |cff00ccff/la|r for help.")
	end
end
