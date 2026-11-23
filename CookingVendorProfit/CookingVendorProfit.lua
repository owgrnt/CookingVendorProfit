local addonName, ns = ...
local isRussian = GetLocale() == "ruRU"
local L = isRussian and {
    label = "Торговцу +40%: ",
    expectation = "Средняя прибыль за одно приготовление. Шанс получить одну дополнительную единицу еды — 40%.",
    assumption = "Расчёт использует заданные 40%. Ранг навыка наследия не проверяется.",
    loading = "Загрузка данных…",
    noPrice = "Нет цены: %s",
    noSellPrice = "Нет данных о цене продажи",
    unknown = "Применимость бонуса не определена",
    excluded = "Бонус не применяется",
    missing = "Требуется Auctionator",
    incompatible = "Несовместимая версия Auctionator",
    cached = "%s — кэш аукциона",
    vendor = "%s — кэш закупочных цен торговца",
    days = " (дн.: %d)",
    reagent = "Ингредиент %d",
} or {
    label = "To Vendor +40%: ",
    expectation = "Expected profit per craft. The chance to make one extra unit of food is 40%.",
    assumption = "Uses the assumed 40% chance. The active Legacy perk rank is not checked.",
    loading = "Loading item data…",
    noPrice = "No price: %s",
    noSellPrice = "No vendor sell price available",
    unknown = "Bonus eligibility could not be determined",
    excluded = "Bonus does not apply",
    missing = "Auctionator is required",
    incompatible = "Incompatible Auctionator version",
    cached = "%s — cached auction price",
    vendor = "%s — cached vendor purchase price",
    days = " (%d d)",
    reagent = "Ingredient %d",
}

local COOKING_SKILL = 185
local COOKING_SPELL = 2550
local DRINK_SPELL = 430
-- Cooking outputs in the Forever client's Camping recipe category, including the deployable feast.
local CAMPING_OUTPUTS = {
    ["279981"] = true, ["279961"] = true, ["279957"] = true, ["279974"] = true, ["279982"] = true,
}
local BONUS = 0.4
local ROW_HEIGHT = 16

local row, parent, baseHeight, fallback
local scheduled, dbAPI, render, schedule
local pendingItems = {}
local visibleReagents, watchedDatabase = {}, nil

local function CoinText(copper)
    -- Round for display only. Use the game's own money string so the icons
    -- and spacing match Auctionator, including when the copper has a decimal.
    local tenths = math.floor(math.abs(copper) * 10 + 0.5)
    local whole, fraction = math.floor(tenths / 10), tenths % 10
    local money
    if fraction == 0 then
        money = GetMoneyString(whole, true)
    else
        local copperPart = whole % 100
        local nativeCopper = math.max(copperPart, 1)
        money = GetMoneyString(whole - copperPart + nativeCopper, true)
        local copperIcon = GetMoneyString(1, true):gsub("^%d+", "")
        local amount = copperPart .. (isRussian and "," or ".") .. fraction
        money = money:sub(1, #money - #copperIcon):gsub("%d+$", amount) .. copperIcon
    end
    if tenths == 0 then return WHITE_FONT_COLOR:WrapTextInColorCode(money) end
    local color = copper < 0 and RED_FONT_COLOR or GREEN_FONT_COLOR
    return color:WrapTextInColorCode((copper < 0 and "-" or "+") .. money)
end

local function GetProfessionHost()
    local frame = ProfessionsFrame
    local page = frame and frame.CraftingPage
    local form = page and page.SchematicForm
    if form and form:IsVisible() then return frame, form end
    if TradeSkillFrame and TradeSkillFrame:IsVisible() then return TradeSkillFrame end
end

local function IsCooking(host, form)
    if not host then return false end
    local info, line
    if form then
        local api = C_TradeSkillUI
        info = api.GetBaseProfessionInfo and api.GetBaseProfessionInfo()
        if info and info.professionID == COOKING_SKILL then return true end
        line = info and info.professionName
    elseif GetTradeSkillLine then
        line = GetTradeSkillLine()
    end
    local cooking = C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(COOKING_SPELL)
    if not cooking and GetSpellInfo then cooking = GetSpellInfo(COOKING_SPELL) end
    return line and (line == cooking or line == "Cooking" or line == "Кулинария")
end

local function ReadAPI()
    if not Auctionator then return nil, L.missing end
    local api = Auctionator.API and Auctionator.API.v1
    if not (api and type(api.GetVendorPriceByItemLink) == "function"
        and type(api.GetAuctionPriceByItemLink) == "function"
        and type(api.RegisterForDBUpdate) == "function") then
        return nil, L.incompatible
    end
    return api
end

local function GetItemID(link)
    return link and link:match("item:(%d+)")
end

local function WaitForItem(key)
    if pendingItems[key] == false then return false end
    if C_Item and C_Item.IsItemDataCachedByID and C_Item.IsItemDataCachedByID(tonumber(key)) then return false end
    if pendingItems[key] == nil then
        pendingItems[key] = true
        if C_Item and C_Item.RequestLoadItemDataByID then
            C_Item.RequestLoadItemDataByID(tonumber(key))
        end
    end
    return true
end

local function LegacyRecipe()
    local index = GetTradeSkillSelectionIndex()
    if not index or index <= 0 then return end
    local _, kind = GetTradeSkillInfo(index)
    if kind == "header" or kind == "subheader" then return end
    local minMade, maxMade = GetTradeSkillNumMade(index)
    local inputs = {}
    for slot = 1, GetTradeSkillNumReagents(index) or 0 do
        local name, _, count = GetTradeSkillReagentInfo(index, slot)
        inputs[slot] = {name = name, count = count, link = GetTradeSkillReagentItemLink(index, slot)}
    end
    local link = GetTradeSkillItemLink(index)
    return GetTradeSkillRecipeLink and GetTradeSkillRecipeLink(index) or link or tostring(index),
        link, minMade, maxMade, inputs
end

local function ModernRecipe(form, id)
    local schematic = form and form.recipeSchematic
    if not schematic or schematic.recipeID ~= id then
        if form then
            schematic = C_TradeSkillUI.GetRecipeSchematic(id, false, form:GetCurrentRecipeLevel())
        else
            schematic = C_TradeSkillUI.GetRecipeSchematic(id, false)
        end
    end
    if not schematic then return id end

    local transaction = form and form:GetTransaction()
    local output = form and C_TradeSkillUI.GetRecipeOutputItemData(id,
        transaction and transaction:CreateOptionalCraftingReagentInfoTbl(),
        transaction and transaction:GetAllocationItemGUID())
    local itemID = output and output.itemID or schematic.outputItemID
    if not itemID and not form and C_TradeSkillUI.GetRecipeOutputItemData then
        output = C_TradeSkillUI.GetRecipeOutputItemData(id)
        itemID = output and output.itemID
    end
    local link = output and output.hyperlink or (itemID and "item:" .. itemID)
    local inputs = {}

    for slotIndex, slot in ipairs(schematic.reagentSlotSchematics or {}) do
        local selected = 0
        local allocations = transaction and transaction:GetAllocations(slotIndex)
        for _, candidate in ipairs(slot.reagents) do
            local allocation = allocations and allocations:FindAllocationByReagent(candidate)
            local count = allocation and allocation:GetQuantity() or 0
            if count > 0 then
                inputs[#inputs + 1] = {itemID = candidate.itemID, count = count}
                selected = selected + count
            end
        end
        if slot.reagentType == Enum.CraftingReagentType.Basic and selected < slot.quantityRequired then
            local reagent = #slot.reagents == 1 and slot.reagents[1]
            inputs[#inputs + 1] = {itemID = reagent and reagent.itemID or nil,
                count = slot.quantityRequired - selected}
        end
    end
    return id, link, schematic.quantityMin, schematic.quantityMax, inputs
end

local function ReadRecipe(id, link, minMade, maxMade, inputs)
    if not id then return end
    local outputKey = GetItemID(link)
    local recipe = {reagents = {}}
    if not outputKey then
        recipe.problem = L.unknown
        return recipe
    end

    if CAMPING_OUTPUTS[outputKey] then
        recipe.problem = L.excluded
        return recipe
    end

    local getInstant = C_Item and C_Item.GetItemInfoInstant or GetItemInfoInstant
    local getInfo = C_Item and C_Item.GetItemInfo or GetItemInfo
    if not getInstant or not getInfo then
        recipe.problem = L.unknown
        return recipe
    end

    local _, _, _, _, _, class, subclass = getInstant(link)
    local name, _, _, _, _, _, _, _, _, _, sellPrice = getInfo(link)
    local consumable = Enum and Enum.ItemClass and Enum.ItemClass.Consumable or 0
    local foodAndDrink = Enum and Enum.ItemConsumableSubclass and Enum.ItemConsumableSubclass.FoodandDrink or 5
    if class ~= nil and (class ~= consumable or subclass ~= nil and subclass ~= foodAndDrink) then
        recipe.problem = L.excluded
        return recipe
    end
    if not name then
        recipe.problem = WaitForItem(outputKey) and L.loading or L.noSellPrice
        return recipe
    end
    local getSpell = C_Item and C_Item.GetItemSpell or GetItemSpell
    local useName = getSpell and getSpell(link)
    if class ~= consumable or subclass ~= foodAndDrink or not useName then
        recipe.problem = L.unknown
        return recipe
    end

    local drink = C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(DRINK_SPELL)
    if not drink and GetSpellInfo then drink = GetSpellInfo(DRINK_SPELL) end
    if useName == drink then
        recipe.problem = L.excluded
        return recipe
    end

    recipe.minMade, recipe.maxMade = minMade, maxMade or minMade
    recipe.sellPrice = sellPrice
    recipe.output = {key = outputKey, link = link, name = name}
    for slot, input in ipairs(inputs or {}) do
        local reagentLink = input.link or (input.itemID and "item:" .. input.itemID)
        local key = GetItemID(reagentLink)
        local count = input.count
        local reagentName = input.name or (reagentLink and getInfo(reagentLink))
        local reagent = {
            key = key, link = reagentLink, count = count, name = reagentName or L.reagent:format(slot),
        }
        recipe.reagents[slot] = reagent
        if key and not reagentName and WaitForItem(key) then
            recipe.problem = L.loading
        end
        if not (key and count and reagentName) then
            recipe.incomplete = recipe.incomplete or L.noPrice:format(reagent.name)
        end
    end
    return recipe
end

local function CurrentRecipe(form)
    local id, link, minMade, maxMade, inputs
    if form then
        local info = form:GetRecipeInfo()
        if info and info.recipeID then
            id, link, minMade, maxMade, inputs = ModernRecipe(form, info.recipeID)
        end
    else
        id, link, minMade, maxMade, inputs = LegacyRecipe()
    end
    if not id then return end
    return ReadRecipe(id, link, minMade, maxMade, inputs)
end

local function Profit(recipe, api, tooltip, freshPrices)
    if recipe.problem then return nil, recipe.problem end
    if type(recipe.sellPrice) ~= "number" or recipe.sellPrice < 0 then return nil, L.noSellPrice end
    if not recipe.minMade or recipe.minMade <= 0 or recipe.maxMade < recipe.minMade then return nil, L.unknown end
    if recipe.incomplete then return nil, recipe.incomplete end
    local cost = 0
    for _, reagent in ipairs(recipe.reagents) do
        local price = api.GetVendorPriceByItemLink(addonName, reagent.link)
        if type(price) == "number" then
            if tooltip then tooltip[#tooltip + 1] = L.vendor:format(reagent.name) end
        elseif freshPrices then
            price = freshPrices[reagent.key]
            if price == nil then return nil, L.noPrice:format(reagent.name) end
        else
            price = api.GetAuctionPriceByItemLink(addonName, reagent.link)
            if type(price) ~= "number" then return nil, L.noPrice:format(reagent.name) end
            local age = api.GetAuctionAgeByItemLink and api.GetAuctionAgeByItemLink(addonName, reagent.link)
            local source = L.cached:format(reagent.name)
            tooltip[#tooltip + 1] = source .. (age and L.days:format(age) or "")
        end
        cost = cost + price * reagent.count
    end
    local lower = recipe.sellPrice * (recipe.minMade + BONUS) - cost
    local upper = recipe.sellPrice * (recipe.maxMade + BONUS) - cost
    return lower, upper
end

function ns.MoneyRange(lower, upper)
    if lower == upper then return CoinText(lower) end
    return CoinText(lower) .. " – " .. CoinText(upper)
end

ns.GetProfit = Profit
ns.ReadRecipe = ReadRecipe
ns.ReadAPI = ReadAPI
ns.ReadSchematic = ModernRecipe
ns.IsExcluded = function(recipe) return recipe.problem == L.excluded end

local function ProfitText(recipe, api, tooltip)
    local lower, upper = Profit(recipe, api, tooltip)
    if lower == nil then return upper end
    return ns.MoneyRange(lower, upper)
end

local function ShowTooltip(owner)
    GameTooltip:SetOwner(owner, "ANCHOR_BOTTOMLEFT")
    local tooltip = row.tooltip or {}
    GameTooltip:SetText(tooltip[1] or L.label:sub(1, -3))
    for index = 2, #tooltip do
        GameTooltip:AddLine(tooltip[index], 1, 1, 1, true)
    end
    GameTooltip:Show()
end

local function MakeRow(frame)
    local widget = CreateFrame("Frame", nil, frame)
    widget:SetHeight(ROW_HEIGHT)
    widget:EnableMouse(true)
    widget:SetScript("OnEnter", ShowTooltip)
    widget:SetScript("OnLeave", function() GameTooltip:Hide() end)
    widget.text = widget:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    widget.text:SetAllPoints()
    widget.text:SetJustifyH("LEFT")
    local fontObject = frame.Total:GetFontObject()
    if fontObject then widget.text:SetFontObject(fontObject) end
    widget.text:SetFont(frame.Total:GetFont())
    widget.text:SetTextColor(frame.Total:GetTextColor())
    widget.text:SetWordWrap(false)
    widget:Hide()
    return widget
end

local function Attach(host, form)
    local frame = form and AuctionatorCraftingInfoProfessionsFrame or AuctionatorCraftingInfo
    if not (frame and frame.Total and type(frame.UpdateTotal) == "function") then return end
    if frame ~= parent then
        if row then row:Hide() end
        parent = frame
        baseHeight = frame:GetHeight()
        row = MakeRow(frame)
        row:SetPoint("TOPLEFT", frame.Total, "BOTTOMLEFT", 0, -2)
        host:HookScript("OnSizeChanged", schedule)
        hooksecurefunc(frame, "UpdateTotal", function(self)
            if self == parent then
                baseHeight = self:GetHeight()
                if row:IsShown() then self:SetHeight(baseHeight + ROW_HEIGHT) end
            end
            schedule()
        end)
        frame:HookScript("OnShow", schedule)
        frame:HookScript("OnHide", schedule)
    end
    return frame
end

local function ShowFallback(message, host, form)
    local description = form and form.Reagents or TradeSkillDescription or TradeSkillReagentLabel
    if message and description and host then
        if not fallback then
            fallback = host:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        end
        fallback:ClearAllPoints()
        if form then
            fallback:SetPoint("TOPLEFT", description, "BOTTOMLEFT", 0, -5)
        else
            fallback:SetPoint("BOTTOMLEFT", description, "TOPLEFT", 0, 2)
        end
    end
    if not fallback then return end
    fallback:SetShown(message ~= nil)
    if message then fallback:SetText(L.label .. message) end
end

render = function()
    visibleReagents = {}
    local host, form = GetProfessionHost()
    local cooking = IsCooking(host, form)
    if ns.ShowScanPanel then ns.ShowScanPanel(cooking and form and host or nil) end
    if not cooking then
        if row then
            row:Hide()
            parent:SetHeight(baseHeight)
        end
        ShowFallback(nil)
        return
    end

    local api, unavailable = ReadAPI()
    local frame = Attach(host, form)
    if not frame then
        ShowFallback(unavailable or L.incompatible, host, form)
        return
    end
    ShowFallback(nil)

    local recipe = frame:IsVisible() and CurrentRecipe(form)
    local left, right = frame.Total:GetLeft(), host:GetRight()
    if left and right then
        local rightInRowUnits = right * host:GetEffectiveScale() / row:GetEffectiveScale()
        row:SetWidth(math.max(150, rightInRowUnits - left - 22))
    else
        row:SetWidth(270)
    end
    row:SetShown(not not recipe)
    frame:SetHeight(baseHeight + (recipe and ROW_HEIGHT or 0))
    if not recipe then return end

    local tooltip = {L.expectation, L.assumption}
    local value = api and ProfitText(recipe, api, tooltip) or unavailable
    for _, reagent in ipairs(recipe.reagents) do
        if reagent.key then visibleReagents[reagent.key] = true end
    end
    local text = L.label .. value
    row.tooltip = tooltip
    table.insert(row.tooltip, 1, text)
    row.text:SetText(text)
end

schedule = function()
    if scheduled then return end
    scheduled = true
    C_Timer.After(0, function()
        scheduled = false
        render()
    end)
end

local events = CreateFrame("Frame")
for _, event in ipairs({
    "PLAYER_LOGIN", "ADDON_LOADED", "TRADE_SKILL_SHOW", "TRADE_SKILL_UPDATE", "TRADE_SKILL_CLOSE",
    "TRADE_SKILL_LIST_UPDATE", "TRADE_SKILL_DETAILS_UPDATE", "TRADE_SKILL_DATA_SOURCE_CHANGED",
    "GET_ITEM_INFO_RECEIVED", "ITEM_DATA_LOAD_RESULT", "MERCHANT_SHOW",
}) do
    pcall(events.RegisterEvent, events, event)
end

local selectionHooked
events:SetScript("OnEvent", function(_, event, arg, success)
    if event == "GET_ITEM_INFO_RECEIVED" or event == "ITEM_DATA_LOAD_RESULT" then
        local key = tostring(arg)
        if pendingItems[key] == nil and not visibleReagents[key] then return end
        if success then
            pendingItems[key] = nil
        elseif pendingItems[key] then
            pendingItems[key] = false
        end
    end

    if not selectionHooked and type(TradeSkillFrame_SetSelection) == "function" then
        hooksecurefunc("TradeSkillFrame_SetSelection", schedule)
        selectionHooked = true
    end
    local api = ReadAPI()
    if api and api ~= dbAPI then
        local ok = pcall(api.RegisterForDBUpdate, addonName, schedule)
        if ok then dbAPI = api end
    end
    local database = api and Auctionator.Database
    if database and not watchedDatabase and type(database.SetPrice) == "function" then
        watchedDatabase = database
        hooksecurefunc(database, "SetPrice", function(_, key)
            if visibleReagents[key] then schedule() end
        end)
    end
    schedule()
end)
