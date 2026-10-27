-- Keystone Percentile: minimap button. Left-click opens the window,
-- right-click opens the settings, drag to move it around the minimap.
local ADDON, ns = ...
local L = ns.L

local atan2 = math.atan2 or math.atan
local btn = CreateFrame("Button", "KeystonePercentileMinimapButton", Minimap)
btn:SetSize(31, 31)
btn:SetFrameStrata("MEDIUM")
btn:SetFrameLevel(8)
btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
btn:RegisterForDrag("LeftButton")
btn:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

local overlay = btn:CreateTexture(nil, "OVERLAY")
overlay:SetSize(53, 53)
overlay:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
overlay:SetPoint("TOPLEFT")
-- Our own round icon (Media/IconMinimap.tga) fills the hole in the border.
local icon = btn:CreateTexture(nil, "ARTWORK")
icon:SetSize(21, 21)
icon:SetTexture("Interface\\AddOns\\Keystone_Percentile\\Media\\IconMinimap")
icon:SetPoint("TOPLEFT", 6, -5)

local function Settings()
  KP_DB.minimap = KP_DB.minimap or {}
  if KP_DB.minimap.angle == nil then KP_DB.minimap.angle = 220 end
  return KP_DB.minimap
end

local function Place()
  local a = math.rad(Settings().angle)
  local r = (Minimap:GetWidth() or 140) / 2 + 10
  btn:ClearAllPoints()
  btn:SetPoint("CENTER", Minimap, "CENTER", math.cos(a) * r, math.sin(a) * r)
end

function ns.RefreshMinimap()
  if Settings().hide then btn:Hide() else Place(); btn:Show() end
end

btn:SetScript("OnClick", function(_, button)
  if button == "RightButton" then ns.OpenSettings() else ns.ToggleHistory() end
end)
btn:SetScript("OnDragStart", function(self)
  self:SetScript("OnUpdate", function()
    local mx, my = Minimap:GetCenter()
    local px, py = GetCursorPosition()
    local scale = Minimap:GetEffectiveScale()
    if not mx or not scale or scale == 0 then return end
    Settings().angle = math.deg(atan2(py / scale - my, px / scale - mx))
    Place()
  end)
end)
btn:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
btn:SetScript("OnEnter", function(self)
  GameTooltip:SetOwner(self, "ANCHOR_LEFT")
  GameTooltip:AddLine("Keystone Percentile")
  GameTooltip:AddLine(L["Left-click: open window"], 1, 1, 1)
  GameTooltip:AddLine(L["Right-click: settings"], 1, 1, 1)
  GameTooltip:AddLine(L["Drag to move"], 0.6, 0.6, 0.6)
  GameTooltip:Show()
end)
btn:SetScript("OnLeave", GameTooltip_Hide)

local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_LOGIN")
ev:SetScript("OnEvent", function() ns.RefreshMinimap() end)
