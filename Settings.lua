-- Keystone Percentile: Options > AddOns page, addon compartment button, and
-- keeping saved data small.
local ADDON, ns = ...
local L = ns.L

local REGIONS = { false, "us", "eu", "kr", "tw" } -- false = auto
local MAX_RUNS = 1500

---------------------------------------------------------------------------
-- Settings page
---------------------------------------------------------------------------
local page = CreateFrame("Frame")
page:Hide()
local category

local title = page:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
title:SetPoint("TOPLEFT", 16, -16)
title:SetText("Keystone Percentile")
local sub = page:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
sub:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)
sub:SetText(L["Where your Mythic+ rating and DPS rank."])

local y = -70
local checks = {}

-- get/set read and write KP_DB; onChange runs after a change.
local function Check(label, tip, get, set)
  local cb = CreateFrame("CheckButton", nil, page, "UICheckButtonTemplate")
  cb:SetPoint("TOPLEFT", 16, y)
  local text = page:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  text:SetPoint("LEFT", cb, "RIGHT", 4, 1)
  text:SetText(label)
  cb:SetScript("OnClick", function(self) set(self:GetChecked() and true or false) end)
  cb:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:AddLine(label); GameTooltip:AddLine(tip, 1, 1, 1, true)
    GameTooltip:Show()
  end)
  cb:SetScript("OnLeave", GameTooltip_Hide)
  cb.get = get
  checks[#checks + 1] = cb
  y = y - 30
end

Check(L["Show next to the Mythic+ window"], L["Your Top % and goals beside Blizzard's Mythic+ window whenever you open it."],
  function() return KP_DB.dock ~= false end,
  function(v) KP_DB.dock = v; if ns.RefreshDock then ns.RefreshDock() end end)
Check(L["Place it beside the window instead"], L["Puts the panel to the right of the Mythic+ window instead of inside it. Other addons, like Raider.IO, often use that spot."],
  function() return KP_DB.dockOutside end,
  function(v) KP_DB.dockOutside = v; if ns.RefreshDock then ns.RefreshDock() end end)
Check(L["Show minimap button"], L["Left-click opens the window, right-click opens these settings."],
  function() return not (KP_DB.minimap and KP_DB.minimap.hide) end,
  function(v) KP_DB.minimap = KP_DB.minimap or {}; KP_DB.minimap.hide = not v; ns.RefreshMinimap() end)
Check(L["Show floating panel"], L["A small always-on panel with your Top % and next goal. Drag the corner to resize."],
  function() return KP_DB.floating end,
  function(v) KP_DB.floating = v; ns.RefreshPanel() end)
Check(L["Lock floating panel"], L["Stops the floating panel from being moved or resized."],
  function() return KP_DB.locked end,
  function(v) KP_DB.locked = v end)
Check(L["Show end-of-key pop-up"], L["Your DPS or HPS rank, the gap to the top, and what happened in the key."],
  function() return KP_DB.popup ~= false end,
  function(v) KP_DB.popup = v end)
Check(L["Rank your whole group in the pop-up"], L["Every group member against players of their own spec."],
  function() return KP_DB.groupRanks ~= false end,
  function(v) KP_DB.groupRanks = v end)
Check(L["Show Top % on player tooltips"], L["Overall and class percentile for players whose rating the game knows."],
  function() return KP_DB.tooltips end,
  function(v) KP_DB.tooltips = v end)

y = y - 10
local regionLabel = page:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
regionLabel:SetPoint("TOPLEFT", 20, y - 4)
regionLabel:SetText(L["Region"])
local regionBtn = CreateFrame("Button", nil, page, "UIPanelButtonTemplate")
regionBtn:SetSize(120, 22)
regionBtn:SetPoint("LEFT", regionLabel, "RIGHT", 12, 0)
local function RegionText()
  return KP_DB.region and KP_DB.region:upper() or (L["Auto"] .. " (" .. (ns.GetRegion() or "?"):upper() .. ")")
end
regionBtn:SetScript("OnClick", function(self)
  local idx = 1
  for i, r in ipairs(REGIONS) do if (r or nil) == KP_DB.region then idx = i end end
  KP_DB.region = REGIONS[idx % #REGIONS + 1] or nil
  self:SetText(RegionText())
  ns.RefreshPanel()
end)
y = y - 44

local historyBtn = CreateFrame("Button", nil, page, "UIPanelButtonTemplate")
historyBtn:SetSize(150, 22)
historyBtn:SetPoint("TOPLEFT", 16, y)
historyBtn:SetText(L["Open window"])
historyBtn:SetScript("OnClick", function() ns.ToggleHistory("overview") end)
local resetBtn = CreateFrame("Button", nil, page, "UIPanelButtonTemplate")
resetBtn:SetSize(150, 22)
resetBtn:SetPoint("LEFT", historyBtn, "RIGHT", 8, 0)
resetBtn:SetText(L["Reset panel position"])
resetBtn:SetScript("OnClick", function() SlashCmdList.KEYSTONEPERCENTILE("reset") end)
y = y - 40

local info = page:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
info:SetPoint("TOPLEFT", 16, y)
info:SetWidth(560); info:SetJustifyH("LEFT")

page:SetScript("OnShow", function()
  for _, cb in ipairs(checks) do cb:SetChecked(cb.get() and true or false) end
  regionBtn:SetText(RegionText())
  local nb = 0
  local seen = {}
  for _, src in ipairs({ KP_DATA, KP_PERSONAL or {} }) do
    for m, sp in pairs(src.dps or {}) do
      for s, lv in pairs(sp) do
        for l in pairs(lv) do
          local k = m .. ":" .. s .. ":" .. l
          if not seen[k] then seen[k] = true; nb = nb + 1 end
        end
      end
    end
  end
  local imported = 0
  for _, list in pairs((KP_PERSONAL and KP_PERSONAL.imported) or KP_DATA.imported or {}) do imported = imported + #list end
  info:SetText(string.format(L["Data: %s · updated %s\n%d Warcraft Logs benchmarks · %d imported runs\nCommands: /kp, /kp runs, /kp progress, /kp goals, /kp last"],
    KP_DATA.season or "?", KP_DATA.updatedAt or L["never"], nb, imported))
end)

function ns.OpenSettings()
  if category and Settings and Settings.OpenToCategory then
    Settings.OpenToCategory(category:GetID())
  end
end

---------------------------------------------------------------------------
-- Addon compartment (the addon icon dropdown by the minimap)
---------------------------------------------------------------------------
function KeystonePercentile_OnCompartmentClick(_, button)
  if button == "RightButton" then ns.OpenSettings() else ns.ToggleHistory() end
end

function KeystonePercentile_OnCompartmentEnter(_, frame)
  GameTooltip:SetOwner(frame, "ANCHOR_LEFT")
  GameTooltip:AddLine("Keystone Percentile")
  GameTooltip:AddLine(L["Left-click: run history"], 1, 1, 1)
  GameTooltip:AddLine(L["Right-click: settings"], 1, 1, 1)
  GameTooltip:Show()
end

function KeystonePercentile_OnCompartmentLeave()
  GameTooltip:Hide()
end

---------------------------------------------------------------------------
-- Keep saved data small: full details for the current season, slimmer
-- records for older ones, and at most MAX_RUNS runs per character.
---------------------------------------------------------------------------
local function Prune()
  local current = KP_DATA.season
  for _, runs in pairs(KP_RUNS or {}) do
    for _, r in ipairs(runs) do
      if current and r.season and r.season ~= current then
        r.group, r.hero, r.approx = nil, nil, nil
      end
    end
    while #runs > MAX_RUNS do table.remove(runs, 1) end
  end
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")
ev:SetScript("OnEvent", function(self, _, name)
  if name ~= ADDON then return end
  self:UnregisterEvent("ADDON_LOADED")
  Prune()
  if Settings and Settings.RegisterCanvasLayoutCategory then
    category = Settings.RegisterCanvasLayoutCategory(page, "Keystone Percentile")
    Settings.RegisterAddOnCategory(category)
  end
end)
