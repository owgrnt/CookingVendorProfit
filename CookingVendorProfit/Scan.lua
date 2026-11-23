local addonName, ns = ...
local L = GetLocale() == "ruRU" and {
    title = "Топ‑10 · торговцу +40%",
    open = "Откройте аукцион",
    ready = "Прибыль за одно приготовление",
    loading = "Загрузка рецептов…",
    scanning = "Поиск предметов · %d",
    done = "Рецептов с ценами: %d · без данных: %d",
    noProfit = "Прибыльных рецептов: 0 · без данных: %d",
    noRecipes = "Нет доступных рецептов для поиска",
    busy = "Auctionator уже выполняет поиск",
    interrupted = "Поиск прерван",
    missing = "Требуется совместимый Auctionator",
} or {
    title = "Top 10 · To Vendor +40%",
    open = "Open the auction house",
    ready = "Profit per craft",
    loading = "Loading recipes…",
    scanning = "Searching %d items…",
    done = "Priced recipes: %d · missing data: %d",
    noProfit = "Profitable recipes: 0 · missing data: %d",
    noRecipes = "No available recipes to scan",
    busy = "Auctionator is already searching",
    interrupted = "Search interrupted",
    missing = "Compatible Auctionator required",
}

local RANK_LIMIT = 10
local WIDTH, HEIGHT = 344, 233
local panel, anchor, hookedBus
local hookedProviders = setmetatable({}, {__mode = "k"})
local request, entries, message, topRecipeIDs

local function AuctionWindow()
    if AuctionHouseFrame and AuctionHouseFrame:IsVisible() then return AuctionHouseFrame end
    if AuctionFrame and AuctionFrame:IsVisible() then return AuctionFrame end
end

local function UpdatePanel()
    if not panel or not anchor then return end
    local available = AuctionWindow() ~= nil and not request
    panel.scan:SetEnabled(available)
    panel.scanTop:SetEnabled(available and topRecipeIDs ~= nil and #topRecipeIDs > 0)
    local status = message or L.ready
    if not request and not AuctionWindow() then status = L.open end
    panel.status:SetText(status)
    for i, row in ipairs(panel.rows) do
        local entry = entries and entries[i]
        row:SetShown(entry ~= nil)
        if entry then
            row.name:SetText(entry.name)
            row.money:SetText(ns.MoneyRange(entry.lower, entry.upper))
            row.entry = entry
        end
    end
end

local function Finish(status, results)
    request = nil
    message, entries = status, results
    UpdatePanel()
end

local function Publish(current, results)
    if request ~= current then return end
    if current.aborted or not AuctionWindow() or type(results) ~= "table" then
        Finish(L.interrupted)
        return
    end

    local prices = {}
    for _, result in ipairs(results) do
        local id = result.itemKey and result.itemKey.itemID
        local key = id and tostring(id) or (result.itemString and result.itemString:match("item:(%d+)"))
        if key and current.items[key] and result.totalQuantity and result.totalQuantity > 0
            and result.minPrice and result.minPrice > 0 then
            prices[key] = math.min(prices[key] or result.minPrice, result.minPrice)
        end
    end

    local ranked, priced, missing = {}, 0, current.missing
    for _, recipe in ipairs(current.recipes) do
        local lower, upper = ns.GetProfit(recipe, current.api, nil, prices)
        if lower == nil then
            missing = missing + 1
        else
            priced = priced + 1
            if lower > 0 then
                ranked[#ranked + 1] = {name = recipe.output.name, lower = lower, upper = upper, id = recipe.id}
            end
        end
    end
    table.sort(ranked, function(a, b)
        if a.lower ~= b.lower then return a.lower > b.lower end
        if a.upper ~= b.upper then return a.upper > b.upper end
        if a.name ~= b.name then return a.name < b.name end
        return a.id < b.id
    end)
    for i = #ranked, RANK_LIMIT + 1, -1 do ranked[i] = nil end
    if not current.recipeIDs then
        topRecipeIDs = {}
        for index, entry in ipairs(ranked) do topRecipeIDs[index] = entry.id end
    end
    Finish(#ranked > 0 and L.done:format(priced, missing) or L.noProfit:format(missing), ranked)
end

local function OwnTerms(actual, expected)
    if type(actual) ~= "table" or #actual ~= #expected then return false end
    for index, term in ipairs(expected) do
        if actual[index] ~= term then return false end
    end
    return true
end

local function WatchShopping(bus, events, provider)
    if hookedBus and hookedBus ~= bus then return false end
    if not hookedBus then
        bus:Register({
            ReceiveEvent = function(_, event, data)
                local current = request
                if not current or not current.expected then return end
                if event == events.SearchStart then
                    if not current.started and OwnTerms(data, current.expected) then
                        current.started = true
                    else
                        Finish(L.interrupted)
                    end
                elseif current.started and not current.ended then
                    current.ended = true
                    -- Let the provider's abort hook run before interpreting SearchEnd.
                    C_Timer.After(0, function() Publish(current, data) end)
                end
            end,
        }, {events.SearchStart, events.SearchEnd})
        hookedBus = bus
    end
    if not hookedProviders[provider] then
        hooksecurefunc(provider, "AbortSearch", function(self)
            if request and request.started and request.provider == self then request.aborted = true end
        end)
        if type(provider.OnSearchEventReceived) == "function" then
            hooksecurefunc(provider, "OnSearchEventReceived", function(self, event)
                if event == "AUCTION_HOUSE_BROWSE_FAILURE" and request and request.started
                    and request.provider == self then
                    Finish(L.interrupted)
                end
            end)
        end
        hookedProviders[provider] = true
    end
    return true
end

local function BeginShopping(current)
    local shopping = AuctionatorShoppingFrame
    if shopping and shopping.searchRunning then Finish(L.busy); return end
    local tab = AuctionatorTabs_Shopping
    if not tab then Finish(L.missing); return end
    if not shopping or not shopping:IsVisible() then tab:Click() end
    shopping = AuctionatorShoppingFrame
    local provider = shopping and shopping.SearchProvider
    if not (provider and type(provider.AbortSearch) == "function") then Finish(L.missing); return end
    if shopping.searchRunning then Finish(L.busy); return end
    local a = Auctionator
    local events = a.Shopping and a.Shopping.Tab and a.Shopping.Tab.Events
    if not (a.EventBus and events and WatchShopping(a.EventBus, events, provider)) then
        Finish(L.missing)
        return
    end
    current.provider = provider
    current.expected = {}
    for index, term in ipairs(current.terms) do
        current.expected[index] = current.api.ConvertToSearchString(addonName, term)
    end
    message = L.scanning:format(#current.terms)
    UpdatePanel()
    local searchName = current.recipeIDs and " Scan Top 10" or " Scan All"
    current.api.MultiSearchAdvanced(addonName .. searchName, current.terms)
    if request == current and not current.started then Finish(L.interrupted) end
end

local function AddTerm(current, item)
    if current.items[item.key] then return end
    current.items[item.key] = true
    if current.names[item.name] then return end
    current.names[item.name] = true
    current.terms[#current.terms + 1] = {searchString = item.name, isExact = true}
end

local function PrepareRecipes(current)
    if request ~= current or current.expected then return end
    if not AuctionWindow() then Finish(L.interrupted); return end
    if next(current.pending) and not current.itemDeadline then return end

    for _, data in ipairs(current.schematics) do
        local recipe = ns.ReadRecipe(unpack(data, 1, 5))
        if recipe and not ns.IsExcluded(recipe) then
            if recipe.problem or recipe.incomplete then
                current.missing = current.missing + 1
            else
                recipe.id = data[1]
                current.recipes[#current.recipes + 1] = recipe
                local auctionatorIsBound = Auctionator.Utilities and Auctionator.Utilities.IsBound
                if not auctionatorIsBound or not auctionatorIsBound({C_Item.GetItemInfo(recipe.output.link)}) then
                    AddTerm(current, recipe.output)
                end
                for _, reagent in ipairs(recipe.reagents) do AddTerm(current, reagent) end
            end
        end
    end

    if #current.terms == 0 then
        if #current.recipes > 0 then
            Publish(current, {})
        else
            Finish(L.noRecipes)
        end
        return
    end
    BeginShopping(current)
end

local function Prepare(current)
    local ok = pcall(PrepareRecipes, current)
    if not ok and request == current then Finish(L.interrupted) end
end

local function QueuePreparation(current)
    if current.prepareQueued then return end
    current.prepareQueued = true
    C_Timer.After(0, function()
        current.prepareQueued = false
        Prepare(current)
    end)
end

local function Collect(current)
    local api = C_TradeSkillUI
    local ids = {}
    local recipeIDs = current.recipeIDs or api.GetAllRecipeIDs() or {}
    for _, id in ipairs(recipeIDs) do
        local info = api.GetRecipeInfo(id)
        if info and info.learned then
            local ok, recipeID, link, minimum, maximum, inputs = pcall(ns.ReadSchematic, nil, id)
            if ok and link then
                current.schematics[#current.schematics + 1] = {recipeID, link, minimum, maximum, inputs}
                local outputID = tonumber(link:match("item:(%d+)"))
                if outputID then ids[outputID] = true end
                for _, input in ipairs(inputs or {}) do
                    if input.itemID then ids[input.itemID] = true end
                end
            else
                current.missing = current.missing + 1
            end
        end
    end
    for id in pairs(ids) do
        if not C_Item.GetItemInfo(id) then current.pending[id] = true end
    end
    for id in pairs(current.pending) do C_Item.RequestLoadItemDataByID(id) end
    QueuePreparation(current)
    if next(current.pending) then
        C_Timer.After(12, function()
            if request == current and not current.expected then
                current.itemDeadline = true
                Prepare(current)
            end
        end)
    end
end

local function Scan(topOnly)
    if request or not AuctionWindow() then return end
    if topOnly and (not topRecipeIDs or #topRecipeIDs == 0) then return end
    if not (C_TradeSkillUI.GetAllRecipeIDs and C_TradeSkillUI.GetRecipeInfo
        and C_Item.GetItemInfo and C_Item.RequestLoadItemDataByID) then
        Finish(L.noRecipes)
        return
    end
    local api = ns.ReadAPI()
    if not (api and type(api.MultiSearchAdvanced) == "function" and type(api.ConvertToSearchString) == "function") then
        Finish(L.missing)
        return
    end
    if AuctionatorShoppingFrame and AuctionatorShoppingFrame.searchRunning then
        Finish(L.busy)
        return
    end
    local current = {
        api = api, schematics = {}, pending = {}, items = {}, names = {},
        terms = {}, recipes = {}, missing = 0,
        recipeIDs = topOnly and topRecipeIDs or nil,
    }
    request, message, entries = current, L.loading, nil
    UpdatePanel()
    local ok = pcall(Collect, current)
    if not ok and request == current then Finish(L.interrupted) end
end

local function StopDrag(widget)
    if not widget.dragging then return end
    widget.dragging = nil
    widget:StopMovingOrSizing()
    local x, y = widget:GetCenter()
    local width, height = UIParent:GetSize()
    if x and y and width > 0 and height > 0 then
        local scale = widget:GetEffectiveScale() / UIParent:GetEffectiveScale()
        if type(CookingVendorProfitDB) ~= "table" then CookingVendorProfitDB = {} end
        CookingVendorProfitDB.panelX = x * scale / width
        CookingVendorProfitDB.panelY = y * scale / height
    end
end

local function CreatePanel(host)
    local widget = CreateFrame("Frame", nil, host, "BackdropTemplate")
    widget:SetSize(WIDTH, HEIGHT)
    widget:SetClampedToScreen(true)
    widget:SetMovable(true)
    widget:HookScript("OnHide", StopDrag)
    widget:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 12,
        insets = {left = 3, right = 3, top = 3, bottom = 3},
    })
    widget:SetBackdropColor(0.055, 0.045, 0.04, 0.96)
    widget:SetBackdropBorderColor(0.7, 0.6, 0.42, 0.9)

    local title = widget:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", 10, -13)
    title:SetText(L.title)
    widget.scan = CreateFrame("Button", nil, widget, "UIPanelButtonTemplate")
    widget.scan:SetSize(76, 21)
    widget.scanTop = CreateFrame("Button", nil, widget, "UIPanelButtonTemplate")
    widget.scanTop:SetSize(92, 21)
    widget.scanTop:SetPoint("TOPRIGHT", -8, -7)
    widget.scanTop:SetText("Scan Top 10")
    widget.scanTop:SetScript("OnClick", function() Scan(true) end)
    widget.scan:SetPoint("RIGHT", widget.scanTop, "LEFT", -4, 0)
    widget.scan:SetText("Scan All")
    widget.scan:SetScript("OnClick", function() Scan(false) end)

    local header = CreateFrame("Frame", nil, widget)
    header:SetPoint("TOPLEFT", 4, -4)
    header:SetPoint("BOTTOMRIGHT", widget.scan, "BOTTOMLEFT", -4, 0)
    header:EnableMouse(true)
    header:RegisterForDrag("LeftButton")
    header:SetScript("OnDragStart", function()
        widget.dragging = true
        widget:StartMoving()
    end)
    header:SetScript("OnDragStop", function() StopDrag(widget) end)
    widget.status = widget:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    widget.status:SetPoint("BOTTOMLEFT", 10, 9)
    widget.rows = {}
    for index = 1, RANK_LIMIT do
        local row = CreateFrame("Frame", nil, widget)
        row:SetSize(WIDTH - 20, 18)
        row:SetPoint("TOPLEFT", 10, -32 - (index - 1) * 18)
        row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.name:SetPoint("LEFT")
        row.name:SetWidth(180)
        row.name:SetJustifyH("LEFT")
        row.name:SetWordWrap(false)
        row.money = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.money:SetPoint("RIGHT")
        row.money:SetPoint("LEFT", row.name, "RIGHT", 4, 0)
        row.money:SetJustifyH("RIGHT")
        row.money:SetWordWrap(false)
        row:EnableMouse(true)
        row:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_BOTTOMLEFT")
            GameTooltip:SetText(self.entry.name)
            GameTooltip:AddLine(ns.MoneyRange(self.entry.lower, self.entry.upper))
            GameTooltip:Show()
        end)
        row:SetScript("OnLeave", function() GameTooltip:Hide() end)
        widget.rows[index] = row
    end
    return widget
end

local function PositionPanel()
    if panel.dragging then return end
    local saved = CookingVendorProfitDB
    local width, height = UIParent:GetSize()
    panel:ClearAllPoints()
    if type(saved) == "table" and type(saved.panelX) == "number" and type(saved.panelY) == "number"
        and width > 0 and height > 0 then
        local scale = UIParent:GetEffectiveScale() / panel:GetEffectiveScale()
        panel:SetPoint("CENTER", UIParent, "BOTTOMLEFT", saved.panelX * width * scale, saved.panelY * height * scale)
        return
    end

    local auction = AuctionWindow()
    local left, right = anchor:GetLeft(), anchor:GetRight()
    local screenRight = (UIParent:GetRight() or 0) * UIParent:GetEffectiveScale() / anchor:GetEffectiveScale()
    if right and screenRight - right >= WIDTH + 8 then
        panel:SetPoint("TOPLEFT", anchor, "TOPRIGHT", 8, 0)
    elseif left and left >= WIDTH + 8 and (not auction or not auction:GetRight()
        or auction:GetRight() * auction:GetEffectiveScale() / anchor:GetEffectiveScale() < left - WIDTH - 8) then
        panel:SetPoint("TOPRIGHT", anchor, "TOPLEFT", -8, 0)
    else
        panel:SetPoint("TOPRIGHT", anchor, "BOTTOMRIGHT", 0, -5)
    end
end

function ns.ShowScanPanel(host)
    if not host then
        anchor = nil
        if panel then panel:Hide() end
        return
    end
    if not panel then panel = CreatePanel(host) end
    if anchor ~= host then panel:SetParent(host) end
    anchor = host
    PositionPanel()
    panel:Show()
    UpdatePanel()
end

local events = CreateFrame("Frame")
for _, event in ipairs({
    "AUCTION_HOUSE_SHOW", "AUCTION_HOUSE_CLOSED", "PLAYER_INTERACTION_MANAGER_FRAME_SHOW",
    "PLAYER_INTERACTION_MANAGER_FRAME_HIDE", "ITEM_DATA_LOAD_RESULT", "GET_ITEM_INFO_RECEIVED",
}) do
    pcall(events.RegisterEvent, events, event)
end
events:SetScript("OnEvent", function(_, event, arg)
    if event == "ITEM_DATA_LOAD_RESULT" or event == "GET_ITEM_INFO_RECEIVED" then
        if request and request.pending[arg] then
            request.pending[arg] = nil
            QueuePreparation(request)
        end
        return
    end
    if event:find("^PLAYER_INTERACTION") and Enum.PlayerInteractionType
        and arg ~= Enum.PlayerInteractionType.Auctioneer then return end
    if request and (event == "AUCTION_HOUSE_CLOSED" or event == "PLAYER_INTERACTION_MANAGER_FRAME_HIDE") then
        Finish(L.interrupted)
    end
    C_Timer.After(0, function()
        if anchor then PositionPanel(); UpdatePanel() end
    end)
end)