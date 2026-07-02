local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local Workspace = game:GetService("Workspace")

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

-- Cleanup existing UI
local existing = PlayerGui:FindFirstChild("VincitoreUI")
if existing then existing:Destroy() end

local ScreenGui = Instance.new("ScreenGui")
ScreenGui.Name = "VincitoreUI"
ScreenGui.ResetOnSpawn = false
ScreenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
ScreenGui.Parent = PlayerGui

--========================== CONFIG ==============================--
local CONFIG = {
    Name = "Vincitore",
    WindowSize = UDim2.new(0, 420, 0, 250),
    SidebarWidth = 110,
    HotKey = Enum.KeyCode.RightShift,
    Colors = {
        Background = Color3.fromRGB(15, 13, 20),
        TopBar = Color3.fromRGB(24, 20, 32),
        Card = Color3.fromRGB(30, 25, 42),
        Stroke = Color3.fromRGB(50, 42, 65),
        Accent = Color3.fromRGB(168, 85, 247),
        TextPrimary = Color3.fromRGB(240, 238, 245),
        TextSecondary = Color3.fromRGB(155, 148, 172),
        ToggleOff = Color3.fromRGB(50, 44, 62),
        InputBg = Color3.fromRGB(40, 35, 55),
        Green = Color3.fromRGB(80, 220, 130),
        Red = Color3.fromRGB(220, 80, 80),
        Gold = Color3.fromRGB(255, 215, 0),
        Rainbow = Color3.fromRGB(255, 0, 255),
    },
}

--========================== STATE ================================--
local States = {
    -- Farm
    AutoHarvest = false,
    AutoSellAll = false,
    SellInterval = 30,
    HarvestDelay = 0.5,
    DisableHarvestTeleport = false,   -- when true, Auto Harvest never teleports to the garden

    -- Auto Plant (Farm tab)
    AutoPlant = false,
    PlantSeeds = {},           -- selected seed names; empty = plant every seed you own
    PlantReserve = 0,          -- keep this many of each seed unplanted
    MaxPerCycle = 40,          -- cap on how many seeds get planted per cycle
    PlantDelay = 0.14,         -- delay between each individual PlantSeed fire
    PlantLoopDelay = 1.2,      -- delay between planting cycles
    SmartReplant = false,      -- only plant the single most profitable seed you own
    PlantPattern = "Fill",     -- Fill / Checkerboard / Rows / Columns / Diagonal / Spaced

    -- Mail
    MailRecipient = "",
    MailNote = "",
    MailItemTypes = { "Seeds" },   -- {"Seeds","Pets","Fruits","Gear"} - multi-select
    MailSelectedItems = {},
    MailCount = 1,
    MailMinCount = 1,
    MailAutoSend = false,

    -- Steal
    AutoSteal = false,
    StealDelay = 0.3,
    StealReturn = true,
    SkipIfOwnerPresent = true,
    StealBestOnly = false,
    StealMinValue = 100,
    
    -- Shop
    AutoBuySeed = false,
    AutoBuyGear = false,
    BuySeeds = {},
    BuyGears = {},
    BuyDelay = 0.5,
    
    -- Visual
    ESPFruit = false,
    ESPRareOnly = false,
    ESPMaxDistance = 500,
    ESPFruitValue = false,   -- show calculated value on each fruit billboard
    ESPTotalValue = false,   -- show total backpack fruit value HUD
    ESPFruitValueMode = "Boost+Mult", -- "Base Price" (no friend/mult) or "Boost+Mult" (full price)
    ESPTotalValueMode  = "Boost+Mult", -- same for total backpack HUD
    
    -- Collect
    AutoCollectGold = false,
    AutoCollectRainbow = false,
    AutoCollectMega = false,
    CollectDelay = 0.2,
}

-- Active loops tracker
local ActiveLoops = {}
local function stopLoop(name)
    ActiveLoops[name] = false
end
local function startLoop(name)
    ActiveLoops[name] = true
    return ActiveLoops[name]
end
local function isLoopActive(name)
    return ActiveLoops[name] == true
end

--========================== GAME API ============================--
local Net = (function() 
    local ok,m = pcall(function() return require(ReplicatedStorage.SharedModules.Networking) end) 
    return ok and m or nil 
end)()

local PSC = (function() 
    local ok,m = pcall(function() return require(ReplicatedStorage.ClientModules.PlayerStateClient) end) 
    return ok and m or nil 
end)()

local SeedData = (function() 
    local ok,d = pcall(function() return require(ReplicatedStorage.SharedModules.SeedData) end) 
    return ok and d or {} 
end)()

local SeedPrice = {}
for _, e in ipairs(SeedData) do
    if type(e) == "table" and e.SeedName then 
        SeedPrice[e.SeedName] = tonumber(e.PurchasePrice) or math.huge 
    end
end

-- ▸ Auto Plant support: cache each seed's base sell value so "Smart Replant"
--   can pick the most profitable seed without calling FruitValueCalc from a
--   spawned loop thread (executor limitation - must run on the main thread).
local FruitValueCalc = (function()
    local ok, m = pcall(function() return require(ReplicatedStorage.SharedModules.FruitValueCalc) end)
    return (ok and type(m) == "function") and m or nil
end)()
local SeedBaseValue = {}
if FruitValueCalc then
    for _, e in ipairs(SeedData) do
        if type(e) == "table" and e.SeedName then
            local ok, v = pcall(FruitValueCalc, e.SeedName, 1, nil, LocalPlayer, nil)
            SeedBaseValue[e.SeedName] = (ok and type(v) == "number") and v or 0
        end
    end
end

-- ▸ Read Game.Selling.SizeMultiplier (the active sell-price multiplier, e.g. ×4 during events).
--   Used to strip it out when "Base Price" mode is selected.
local SellMultFlag = (function()
    local ok1, ff = pcall(function() return require(ReplicatedStorage.UserGenerated.FastFlags) end)
    if not ok1 then return nil end
    local ok2, lg = pcall(function() return require(ReplicatedStorage.UserGenerated.Lang.Asserts) end)
    if not ok2 then return nil end
    local ok3, sm = pcall(function() return ff.Replicated("Game.Selling.SizeMultiplier", lg.FinitePositive, 1) end)
    return ok3 and sm or nil
end)()

local function getSellMultiplier()
    if SellMultFlag then
        local ok, v = pcall(function() return SellMultFlag:Get() end)
        if ok and type(v) == "number" and v > 0 then return v end
    end
    return 1
end

-- Proxy passed as the "player" arg to FruitValueCalc when Base Price mode is active.
-- Responds to :GetAttribute("Friends") with 0 so the friend bonus (v37) becomes ×1.
local noFriendProxy = {
    GetAttribute = function(self, k)
        if k == "Friends" then return 0 end
        return LocalPlayer:GetAttribute(k)
    end
}

-- Returns the correct player object for FruitValueCalc based on the selected mode.
local function getPlayerForValueMode(mode)
    return (mode == "Base Price") and noFriendProxy or LocalPlayer
end

local function getReplica() 
    if not PSC then return nil end 
    local ok,r = pcall(function() return PSC:GetLocalReplica() end) 
    return ok and r or nil 
end

local function getData() 
    local r = getReplica() 
    return r and r.Data or nil 
end

local function getSheckles() 
    local d = getData() 
    return d and d.Sheckles or 0 
end

local function myPlot()
    local g = Workspace:FindFirstChild("Gardens") 
    if not g then return nil end
    for _, plot in ipairs(g:GetChildren()) do 
        if plot:GetAttribute("OwnerUserId") == LocalPlayer.UserId then return plot end 
    end
end

-- seeds you currently own (count > 0), sorted by shop display order
local function getOwnedSeedOptions()
    local d = getData()
    local list = {}
    if d and d.Inventory and d.Inventory.Seeds then
        for n, c in pairs(d.Inventory.Seeds) do if (c or 0) > 0 then list[#list + 1] = n end end
    end
    table.sort(list)
    return list
end

-- most valuable seed you currently own (uses cached base values) - for Smart Replant
local function bestOwnedSeed()
    local d = getData()
    local seeds = d and d.Inventory and d.Inventory.Seeds
    if not seeds then return nil end
    local best, bestV
    for name, count in pairs(seeds) do
        if (count or 0) > 0 then
            local v = SeedBaseValue[name] or 0
            if not bestV or v > bestV then best, bestV = name, v end
        end
    end
    return best, bestV
end

local function isNight() 
    local n = ReplicatedStorage:FindFirstChild("Night") 
    return n and n.Value == true 
end

local function char() return LocalPlayer.Character end
local function hrp() 
    local c = char() 
    return c and c:FindFirstChild("HumanoidRootPart") 
end

local function fire(pkt, ...) 
    if not Net then return false end
    local a = {...} 
    return pcall(function() return pkt:Fire(table.unpack(a)) end) 
end

local HOP = 70
local function reach(pos)
    local r = hrp() 
    if not (r and pos) then return end
    local target = pos + Vector3.new(0, 3, 0)
    for _ = 1, 60 do
        local cur = r.Position 
        local delta = target - cur
        if delta.Magnitude <= HOP then r.CFrame = CFrame.new(target) break end
        r.CFrame = CFrame.new(cur + delta.Unit * HOP) 
        RunService.Heartbeat:Wait()
    end
end

local function stockItems(shop)
    local sv = ReplicatedStorage:FindFirstChild("StockValues")
    sv = sv and sv:FindFirstChild(shop)
    return sv and sv:FindFirstChild("Items")
end

--========================== HARVEST LOGIC =======================--
local function modelRipe(m)
    local age = tonumber(m:GetAttribute("Age"))
    local mx = tonumber(m:GetAttribute("MaxAge"))
    if age and mx then return age >= mx - 0.001 end
    for _, d in ipairs(m:GetDescendants()) do
        if d:IsA("ProximityPrompt") and CollectionService:HasTag(d, "HarvestPrompt") then
            return true
        end
    end
    return false
end

local function ownHarvestTargets()
    local out = {}
    local plot = myPlot()
    if not plot then return out end
    local plants = plot:FindFirstChild("Plants")
    if not plants then return out end
    
    local function consider(m)
        if not m:GetAttribute("PlantId") then return end
        table.insert(out, m)
    end
    
    for _, plant in ipairs(plants:GetChildren()) do
        local fr = plant:FindFirstChild("Fruits")
        local fruits = fr and fr:GetChildren() or {}
        if #fruits > 0 then
            for _, m in ipairs(fruits) do
                if modelRipe(m) then consider(m) end
            end
        elseif modelRipe(plant) then
            consider(plant)
        end
    end
    return out
end

local function harvestAll()
    local plot = myPlot()
    local ref = plot and plot:FindFirstChild("PlotSizeReference")
    local r = hrp()
    -- "Disable Harvest Teleport": when on, never hop the character to the plot
    -- centre before collecting - CollectFruit is fired in place regardless.
    if not States.DisableHarvestTeleport and ref and r then
        local dist = (Vector3.new(r.Position.X, 0, r.Position.Z) - Vector3.new(ref.Position.X, 0, ref.Position.Z)).Magnitude
        if dist > 16 then
            reach(ref.Position)
            task.wait(0.12)
        end
    end
    
    local t = ownHarvestTargets()
    local n = 0
    for _, m in ipairs(t) do
        local pid = m:GetAttribute("PlantId")
        if pid then
            fire(Net.Garden.CollectFruit, pid, m:GetAttribute("FruitId") or "")
            n = n + 1
            task.wait(0.05)
        end
    end
    return n
end

--========================== AUTO PLANT LOGIC =====================--
-- Ported from 360's GAG (Grow a Garden 2 hub): lays seeds out over the plot's
-- plantable area on a grid, optionally skipping tiles per a chosen pattern.
local PLANT_PATTERNS = { "Fill", "Checkerboard", "Rows", "Columns", "Diagonal", "Spaced" }

local function patternKeep(pat, gx, gz)
    if pat == "Checkerboard" then return (gx + gz) % 2 == 0
    elseif pat == "Rows" then return gz % 2 == 0
    elseif pat == "Columns" then return gx % 2 == 0
    elseif pat == "Diagonal" then return (gx - gz) % 3 == 0
    elseif pat == "Spaced" then return gx % 2 == 0 and gz % 2 == 0 end
    return true  -- Fill
end

local function plantAreas(plot)
    local areas = {}
    for _, p in ipairs(CollectionService:GetTagged("PlantArea")) do
        if p:IsA("BasePart") and p:IsDescendantOf(plot) and p.Size.X * p.Size.Z > 400 then areas[#areas + 1] = p end
    end
    if #areas == 0 then
        local ref = plot:FindFirstChild("PlotSizeReference")
        if ref then areas = { ref } end
    end
    return areas
end

local function plantPositions(plot)
    local pat = States.PlantPattern or "Fill"
    local step = 6
    local seen, list = {}, {}
    for _, area in ipairs(plantAreas(plot)) do
        local cf, sz = area.CFrame, area.Size
        local topY = area.Position.Y + sz.Y / 2 + 0.3
        local hx, hz = sz.X / 2 - 3, sz.Z / 2 - 3
        local nx, nz = math.floor((2 * hx) / step), math.floor((2 * hz) / step)
        for ix = 0, nx do
            for iz = 0, nz do
                local w = (cf * CFrame.new(-hx + ix * step, 0, -hz + iz * step)).Position
                local gx, gz = math.floor(w.X / step + 0.5), math.floor(w.Z / step + 0.5)
                if patternKeep(pat, gx, gz) then
                    local key = math.floor(w.X / 4 + 0.5) .. "," .. math.floor(w.Z / 4 + 0.5)
                    if not seen[key] then
                        seen[key] = true
                        list[#list + 1] = Vector3.new(w.X, topY, w.Z)
                    end
                end
            end
        end
    end
    return list
end

local function freePlantPositions(plot)
    local grid = plantPositions(plot)
    local plants = plot:FindFirstChild("Plants")
    local occ = {}
    if plants then
        for _, pl in ipairs(plants:GetChildren()) do
            local ok, pv = pcall(function() return pl:GetPivot().Position end)
            if ok then occ[#occ + 1] = pv end
        end
    end
    local free = {}
    for _, pos in ipairs(grid) do
        local clear = true
        for _, o in ipairs(occ) do
            if (Vector3.new(o.X, 0, o.Z) - Vector3.new(pos.X, 0, pos.Z)).Magnitude < 6 then clear = false break end
        end
        if clear then free[#free + 1] = pos end
    end
    return free
end

--========================== STEAL LOGIC =========================--
local function stealTargets()
    local out = {}
    for _, p in ipairs(CollectionService:GetTagged("StealPrompt")) do
        local prompt = p:IsA("ProximityPrompt") and p or nil
        local m = prompt and prompt.Parent and prompt.Parent:FindFirstAncestorWhichIsA("Model")
        if m then
            local uid = tonumber(m:GetAttribute("UserId"))
            if uid and uid ~= LocalPlayer.UserId and m:GetAttribute("PlantId") then
                table.insert(out, {
                    model = m,
                    prompt = prompt,
                    value = 0,
                })
            end
        end
    end
    return out
end

local function TriggerViaMovePart(prompt)
    local root = hrp()
    if not root then return false end
    if not prompt or not prompt:IsA("ProximityPrompt") then return false end

    local parent = prompt.Parent
    if not parent or not parent:IsA("BasePart") then return false end

    local originalCFrame = parent.CFrame
    local originalAnchored = parent.Anchored
    local originalCanCollide = parent.CanCollide

    local targetPos = root.Position + (root.CFrame.LookVector * 2.5) + Vector3.new(0, 1, 0)

    parent.Anchored = true
    parent.CanCollide = false
    parent.CFrame = CFrame.new(targetPos)

    task.wait(0.2)

    local success = false
    pcall(function()
        prompt:InputHoldBegin()
        task.wait((tonumber(prompt.HoldDuration) or 0) + 0.15)
        prompt:InputHoldEnd()
        success = true
    end)

    if not success then
        pcall(function()
            prompt.Triggered:Fire()
            success = true
        end)
    end

    if not success then
        pcall(function()
            local oldDist = prompt.MaxActivationDistance
            prompt.MaxActivationDistance = 999999
            prompt.RequiresLineOfSight = false
            prompt:InputHoldBegin()
            task.wait(0.2)
            prompt:InputHoldEnd()
            prompt.MaxActivationDistance = oldDist
            success = true
        end)
    end

    task.wait(0.1)
    parent.CFrame = originalCFrame
    parent.Anchored = originalAnchored
    parent.CanCollide = originalCanCollide

    return success
end

local function stealModel(m, prompt, mult)
    if not m or not m.Parent then return false end

    local uid = tonumber(m:GetAttribute("UserId"))
    local pid = m:GetAttribute("PlantId")
    if not (uid and pid) then return false end

    if prompt then
        return TriggerViaMovePart(prompt)
    end

    fire(Net.Steal.BeginSteal, uid, pid, m:GetAttribute("FruitId") or "")
    for _ = 1, math.max(1, mult or 1) do
        fire(Net.Steal.CompleteSteal)
    end
    return true
end

--========================== MAIL LOGIC ===========================--
-- Ported from AutoMail (Grow a Garden 2 - Auto-Send Edition): mail seeds,
-- pets, fruits, or gear to another player, with an optional auto-send loop
-- that fires whenever a selected item's stock reaches a minimum threshold.
local function getCount(val)
    if type(val) == "number" then return val end
    if type(val) == "table" then
        return (val.Count or val.count or val.Amount or val.amount or 0)
    end
    return 0
end

-- Fruits/Crops aren't stored under one fixed inventory key across versions,
-- so detect them by name instead of hard-coding "HarvestedFruits".
local fruitKeyCache = {}
local function isFruitKey(key)
    if type(key) ~= "string" then return false end
    if fruitKeyCache[key] == nil then
        local lower = key:lower()
        fruitKeyCache[key] = (lower:find("fruit") ~= nil) or (lower:find("crop") ~= nil)
    end
    return fruitKeyCache[key]
end

-- Inventory key -> UI category label ("Seeds"/"Pets"/"Fruits"), or nil = Gear
local function categoryOf(key)
    if key == "Seeds" then return "Seeds" end
    if key == "Pets" then return "Pets" end
    if isFruitKey(key) then return "Fruits" end
    return nil
end

local function mailActiveTypeSet()
    local set = {}
    for _, t in ipairs(States.MailItemTypes) do set[t] = true end
    return set
end

-- Combines every inventory bag whose category is currently selected.
-- Also scans LocalPlayer.Backpack (and Character) for Tools with HarvestedFruit=true.
-- Returns: bag (name -> value/count), itc (name -> real inventory key)
local function getMailInventory()
    local d = getData()
    local combined, itc = {}, {}
    local typeSet = mailActiveTypeSet()

    if d and d.Inventory then
        for key, bag in pairs(d.Inventory) do
            if type(bag) == "table" then
                local include = false
                local catLabel = categoryOf(key)
                if catLabel then
                    include = typeSet[catLabel] == true
                else
                    include = typeSet["Gear"] == true
                end
                if include then
                    for itemName, val in pairs(bag) do
                        combined[itemName] = val
                        itc[itemName] = key
                    end
                end
            end
        end
    end

    -- Scan Backpack & equipped slot for harvested fruit Tools
    if typeSet["Fruits"] then
        local function scanContainer(container)
            if not container then return end
            for _, tool in ipairs(container:GetChildren()) do
                if tool:IsA("Tool") then
                    local isHarvested = tool:GetAttribute("HarvestedFruit") == true
                    local hasFruitAttr = tool:GetAttribute("Fruit") ~= nil
                    local toolNameLower = tool.Name:lower()
                    local looksLikeFruit = toolNameLower:find("fruit") ~= nil
                        or toolNameLower:find("crop") ~= nil
                        or isHarvested or hasFruitAttr
                    if looksLikeFruit then
                        -- Use Fruit attribute name if available, else tool name
                        local fruitName = tool:GetAttribute("Fruit") or tool.Name
                        -- Accumulate count (multiple tools of same fruit)
                        local prev = type(combined[fruitName]) == "number" and combined[fruitName] or 0
                        combined[fruitName] = prev + 1
                        if not itc[fruitName] then
                            itc[fruitName] = "HarvestedFruits"
                        end
                    end
                end
            end
        end
        scanContainer(LocalPlayer:FindFirstChild("Backpack"))
        scanContainer(LocalPlayer.Character)   -- equipped tool lives in Character
    end

    return combined, itc
end

local function getMailItemOptions()
    local bag = getMailInventory()
    local list = {}
    for name, val in pairs(bag) do
        if getCount(val) > 0 then list[#list + 1] = name end
    end
    table.sort(list)
    return list
end

local mailRecipientIdCache = {}
local function resolveRecipientId(username)
    if not username or username == "" then return 0 end
    local key = username:lower()
    if mailRecipientIdCache[key] then return mailRecipientIdCache[key] end
    local ok, uid = pcall(function() return Net.Mailbox.LookupPlayer:Fire(username) end)
    if ok and type(uid) == "number" and uid > 0 then
        mailRecipientIdCache[key] = uid
        return uid
    end
    return 0
end

local function sendMailBatch(username, items, note)
    if not username or username == "" then return false, "no recipient" end
    if not items or #items == 0 then return false, "no items" end
    note = tostring(note or "")
    local userId = resolveRecipientId(username)
    if userId == 0 then return false, "player not found: " .. username end
    local ok, success, msg = pcall(function()
        return Net.Mailbox.SendBatch:Fire(userId, items, note)
    end)
    if not ok then return false, tostring(success) end
    if not success then return false, tostring(msg or "server rejected") end
    return true, tostring(msg or "Gift sent!")
end

-- isAuto = true -> only send items that meet MailMinCount (used by the auto-send loop)
local function doMailSend(isAuto)
    if States.MailRecipient == "" then return false, "enter a recipient first" end
    if not next(States.MailSelectedItems) then return false, "select at least 1 item" end
    if #States.MailItemTypes == 0 then return false, "select at least 1 category" end

    local bag, itc = getMailInventory()
    local items = {}

    for name in pairs(States.MailSelectedItems) do
        local have = getCount(bag[name])
        if have == nil or have == 0 then
            -- item not present in the active categories, skip
        elseif isAuto and have < States.MailMinCount then
            -- auto mode: not enough stock yet, skip
        else
            local cnt = (States.MailCount and States.MailCount > 0) and math.min(States.MailCount, have) or have
            if cnt > 0 then
                local cat = (itc and itc[name]) or (States.MailItemTypes[1] or "Seeds")
                items[#items + 1] = { Category = cat, ItemKey = name, Count = cnt }
            end
        end
    end

    if #items == 0 then
        return false, isAuto and "waiting for stock" or "no eligible items (check min stock / category)"
    end

    local ok, msg = sendMailBatch(States.MailRecipient, items, States.MailNote)
    if ok then
        local toastMsg
        if #items == 1 then
            toastMsg = items[1].ItemKey .. " x" .. tostring(items[1].Count) .. " sent"
        else
            local names = {}
            for _, it in ipairs(items) do names[#names+1] = it.ItemKey end
            toastMsg = table.concat(names, ", ") .. " sent"
        end
        return true, ("sent %d item(s) to %s"):format(#items, States.MailRecipient), toastMsg
    end
    return false, tostring(msg)
end

--========================== TOAST NOTIFICATION ==================--
local function showMailToast(message)
    local existing = ScreenGui:FindFirstChild("MailToast")
    if existing then existing:Destroy() end

    local toast = Instance.new("Frame")
    toast.Name = "MailToast"
    toast.AnchorPoint = Vector2.new(0.5, 0)
    toast.Position = UDim2.new(0.5, 0, 0, -50)
    toast.Size = UDim2.new(0, 340, 0, 38)
    toast.BackgroundColor3 = CONFIG.Colors.Card
    toast.BorderSizePixel = 0
    toast.ZIndex = 200
    toast.Parent = ScreenGui

    local toastCorner = Instance.new("UICorner")
    toastCorner.CornerRadius = UDim.new(0, 10)
    toastCorner.Parent = toast

    local toastStroke = Instance.new("UIStroke")
    toastStroke.Color = CONFIG.Colors.Accent
    toastStroke.Thickness = 1.5
    toastStroke.Parent = toast

    -- Left accent bar
    local accent = Instance.new("Frame")
    accent.Size = UDim2.new(0, 3, 0.6, 0)
    accent.AnchorPoint = Vector2.new(0, 0.5)
    accent.Position = UDim2.new(0, 8, 0.5, 0)
    accent.BackgroundColor3 = CONFIG.Colors.Accent
    accent.BorderSizePixel = 0
    accent.ZIndex = 201
    accent.Parent = toast

    local accentCorner = Instance.new("UICorner")
    accentCorner.CornerRadius = UDim.new(1, 0)
    accentCorner.Parent = accent

    local toastLabel = Instance.new("TextLabel")
    toastLabel.BackgroundTransparency = 1
    toastLabel.Size = UDim2.new(1, -32, 1, 0)
    toastLabel.Position = UDim2.new(0, 20, 0, 0)
    toastLabel.Font = Enum.Font.GothamMedium
    toastLabel.Text = message
    toastLabel.TextColor3 = CONFIG.Colors.TextPrimary
    toastLabel.TextSize = 12
    toastLabel.TextXAlignment = Enum.TextXAlignment.Left
    toastLabel.TextTruncate = Enum.TextTruncate.AtEnd
    toastLabel.ZIndex = 201
    toastLabel.Parent = toast

    -- Slide in from top
    TweenService:Create(toast, TweenInfo.new(0.28, Enum.EasingStyle.Quart, Enum.EasingDirection.Out), {
        Position = UDim2.new(0.5, 0, 0, 14)
    }):Play()

    -- Wait 2 seconds then slide out
    task.delay(2, function()
        if toast and toast.Parent then
            TweenService:Create(toast, TweenInfo.new(0.22, Enum.EasingStyle.Quart, Enum.EasingDirection.In), {
                Position = UDim2.new(0.5, 0, 0, -50)
            }):Play()
            task.delay(0.25, function()
                if toast and toast.Parent then toast:Destroy() end
            end)
        end
    end)
end

--========================== VALUE HELPERS =======================--
-- Format a sheckle value like the game does: 1.23B / 4.56M / 789K
local function fmtSheckles(v)
    v = tonumber(v) or 0
    if v >= 1e9 then return ("%.2fB"):format(v / 1e9)
    elseif v >= 1e6 then return ("%.2fM"):format(v / 1e6)
    elseif v >= 1e3 then return ("%.1fK"):format(v / 1e3)
    end
    return tostring(math.floor(v + 0.5))
end

-- Calculate the sell value of a single ripe fruit model in the world.
-- mode = "Base Price"  → friend bonus stripped (proxy 0 friends) + sell-mult stripped (÷v33)
-- mode = "Boost+Mult"  → full price: real friend count + current server sell multiplier
local function getFruitWorldValue(fruit, mode)
    if not FruitValueCalc then return nil end
    local seedName = fruit:GetAttribute("SeedName") or fruit:GetAttribute("CorePartName")
    if not seedName then return nil end
    local weight   = tonumber(fruit:GetAttribute("Weight")) or 1
    local mutation = fruit:GetAttribute("Mutation")
    local playerObj = getPlayerForValueMode(mode or "Boost+Mult")
    local ok, v = pcall(FruitValueCalc, seedName, weight, mutation, playerObj, nil)
    if not (ok and type(v) == "number" and v > 0) then return nil end
    if mode == "Base Price" then v = v / getSellMultiplier() end
    return math.floor(v)
end

-- Sum value of all harvested fruit Tools currently in the player's Backpack / Character.
-- IMPORTANT: Only scan Tool items (not replica inventory) to avoid double-counting.
-- FIX: use correct attributes FruitName / SizeMultiplier / DecayAlpha (matching game's NPC sell logic)
-- mode = "Base Price" → no friend bonus, strip sell multiplier | "Boost+Mult" → full price
local function getTotalBackpackFruitValue(mode)
    if not FruitValueCalc then return 0 end
    mode = mode or "Boost+Mult"
    local playerObj = getPlayerForValueMode(mode)
    local sellMult  = getSellMultiplier()
    local total = 0
    local seenTools = {}   -- guard against a tool counted twice if Roblox puts it in both containers
    local function scanContainer(container)
        if not container then return end
        for _, tool in ipairs(container:GetChildren()) do
            if tool:IsA("Tool") and not seenTools[tool] then
                seenTools[tool] = true
                -- FIX: game stores fruit name in "FruitName", not "Fruit" or tool.Name
                local fruitName = tool:GetAttribute("FruitName")
                -- FIX: skip non-fruits and potted plants (matches NPC GetHeldFruitInfo logic)
                if fruitName and not (tool:GetAttribute("PottedPlant") == true) then
                    -- FIX: game stores size in "SizeMultiplier", not "Weight"
                    local sizeMult   = tonumber(tool:GetAttribute("SizeMultiplier")) or 1
                    local mutation   = tool:GetAttribute("Mutation")
                    -- FIX: pass DecayAlpha for accurate decay penalty calculation
                    local decayAlpha = tool:GetAttribute("DecayAlpha")
                    local ok, v = pcall(FruitValueCalc, fruitName, sizeMult, mutation, playerObj, decayAlpha)
                    if ok and type(v) == "number" then
                        if mode == "Base Price" then v = v / sellMult end
                        total = total + v
                    end
                end
            end
        end
    end
    scanContainer(LocalPlayer:FindFirstChild("Backpack"))
    scanContainer(LocalPlayer.Character)
    return total
end

-- Returns array of individual fruit entries from backpack, each with their own value.
-- Each Tool in Backpack/Character = one entry with actual SizeMultiplier + Mutation attributes.
-- ONLY scans Tool items (not replica inventory) to match getTotalBackpackFruitValue.
-- FIX: uses correct attribute names matching the game's NPC sell logic.
-- mode = "Base Price" → no friend bonus, strip sell multiplier | "Boost+Mult" → full price
local function getBackpackFruitBreakdown(mode)
    if not FruitValueCalc then return {} end
    mode = mode or "Boost+Mult"
    local playerObj = getPlayerForValueMode(mode)
    local sellMult  = getSellMultiplier()
    local list = {}
    local seenTools = {}

    local function scanContainer(container)
        if not container then return end
        for _, tool in ipairs(container:GetChildren()) do
            if tool:IsA("Tool") and not seenTools[tool] then
                seenTools[tool] = true
                -- FIX: use "FruitName" attribute (not "Fruit" or tool.Name)
                local fruitName = tool:GetAttribute("FruitName")
                -- FIX: skip non-fruits and potted plants
                if fruitName and not (tool:GetAttribute("PottedPlant") == true) then
                    -- FIX: use "SizeMultiplier" (not "Weight"), pass DecayAlpha
                    local sizeMult   = tonumber(tool:GetAttribute("SizeMultiplier")) or 1
                    local mutation   = tool:GetAttribute("Mutation")
                    local decayAlpha = tool:GetAttribute("DecayAlpha")
                    local ok, v = pcall(FruitValueCalc, fruitName, sizeMult, mutation, playerObj, decayAlpha)
                    if ok and type(v) == "number" and v > 0 then
                        if mode == "Base Price" then v = v / sellMult end
                        list[#list + 1] = {
                            name     = fruitName,
                            sizeMult = sizeMult,  -- FIX: was "weight", now "sizeMult"
                            mutation = mutation,
                            value    = math.floor(v),
                            tool     = tool,       -- store reference for slot matching
                        }
                    end
                end
            end
        end
    end
    scanContainer(LocalPlayer:FindFirstChild("Backpack"))
    scanContainer(LocalPlayer.Character)

    -- Sort by value descending (highest value fruit first)
    table.sort(list, function(a, b) return a.value > b.value end)
    return list
end

--========================== ESP LOGIC ===========================--
local ESPFolder = Instance.new("Folder")
ESPFolder.Name = "ESP_Fruits"
ESPFolder.Parent = ScreenGui

local function clearESP()
    for _, child in ipairs(ESPFolder:GetChildren()) do
        child:Destroy()
    end
end

local function createESP(part, text, color, valueStr)
    if not part or not part.Parent then return end
    local billboard = Instance.new("BillboardGui")
    billboard.Size = valueStr and UDim2.new(0, 160, 0, 52) or UDim2.new(0, 140, 0, 38)
    billboard.StudsOffset = Vector3.new(0, 3.5, 0)
    billboard.AlwaysOnTop = true
    billboard.Adornee = part
    billboard.Parent = ESPFolder

    -- Fruit name label
    local nameLbl = Instance.new("TextLabel")
    nameLbl.Size = valueStr and UDim2.new(1, 0, 0, 26) or UDim2.new(1, 0, 1, 0)
    nameLbl.BackgroundTransparency = 1
    nameLbl.Text = text
    nameLbl.TextColor3 = color or CONFIG.Colors.Accent
    nameLbl.TextSize = 12
    nameLbl.Font = Enum.Font.GothamBold
    nameLbl.TextStrokeTransparency = 0.4
    nameLbl.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
    nameLbl.Parent = billboard

    -- Value label (only when ESPFruitValue is on)
    if valueStr then
        local valLbl = Instance.new("TextLabel")
        valLbl.Size = UDim2.new(1, 0, 0, 22)
        valLbl.Position = UDim2.new(0, 0, 0, 28)
        valLbl.BackgroundTransparency = 1
        valLbl.Text = "\xc2\xa2" .. valueStr   -- ¢ prefix
        valLbl.TextColor3 = CONFIG.Colors.Gold
        valLbl.TextSize = 11
        valLbl.Font = Enum.Font.GothamBold
        valLbl.TextStrokeTransparency = 0.4
        valLbl.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
        valLbl.Parent = billboard
    end

    return billboard
end

local function updateESP()
    clearESP()
    if not States.ESPFruit then return end
    
    local root = hrp()
    if not root then return end
    local rp = root.Position
    
    -- Own crops
    local plot = myPlot()
    if plot then
        local plants = plot:FindFirstChild("Plants")
        if plants then
            for _, pl in ipairs(plants:GetChildren()) do
                local fruits = pl:FindFirstChild("Fruits")
                if fruits then
                    for _, fruit in ipairs(fruits:GetChildren()) do
                        if modelRipe(fruit) then
                            local ok, pos = pcall(function() return fruit:GetPivot().Position end)
                            if ok and (pos - rp).Magnitude <= States.ESPMaxDistance then
                                local mut = fruit:GetAttribute("Mutation")
                                local isRare = mut ~= nil
                                if not States.ESPRareOnly or isRare then
                                    local name = fruit:GetAttribute("CorePartName") or fruit:GetAttribute("SeedName") or "Fruit"
                                    local color = isRare and CONFIG.Colors.Gold or CONFIG.Colors.Green
                                    if mut == "Rainbow" then color = CONFIG.Colors.Rainbow end
                                    local valueStr = nil
                                    if States.ESPFruitValue then
                                        local v = getFruitWorldValue(fruit, States.ESPFruitValueMode)
                                        if v then valueStr = fmtSheckles(v) end
                                    end
                                    createESP(fruit, name .. (mut and " [" .. tostring(mut) .. "]" or ""), color, valueStr)
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    
    -- Other players' mutated crops
    if not States.ESPRareOnly then return end
    for _, p in ipairs(CollectionService:GetTagged("StealPrompt")) do
        local m = p.Parent and p.Parent:FindFirstAncestorWhichIsA("Model")
        if m and m:GetAttribute("Mutation") then
            local ok, pos = pcall(function() return m:GetPivot().Position end)
            if ok and (pos - rp).Magnitude <= States.ESPMaxDistance then
                local name = m:GetAttribute("CorePartName") or m:GetAttribute("SeedName") or "Fruit"
                local mut = m:GetAttribute("Mutation")
                local color = CONFIG.Colors.Gold
                if mut == "Rainbow" then color = CONFIG.Colors.Rainbow end
                local valueStr2 = nil
                if States.ESPFruitValue then
                    local v2 = getFruitWorldValue(m, States.ESPFruitValueMode)
                    if v2 then valueStr2 = fmtSheckles(v2) end
                end
                createESP(m, name .. " [" .. tostring(mut) .. "]", color, valueStr2)
            end
        end
    end
end

--========================== COLLECT LOGIC =======================--
local function collectSpecial(type)
    local map = Workspace:FindFirstChild("Map")
    local locs = map and map:FindFirstChild("SeedPackSpawnServerLocations")
    if not locs then return end
    
    for _, loc in ipairs(locs:GetChildren()) do
        local isTarget = false
        if type == "Gold" and loc:GetAttribute("GoldSeed") == true then isTarget = true
        elseif type == "Rainbow" and loc:GetAttribute("RainbowSeed") == true then isTarget = true
        elseif type == "Mega" and loc:GetAttribute("MegaSeed") == true then isTarget = true
        end
        
        if isTarget then
            local pos = loc:IsA("BasePart") and loc.Position or nil
            if not pos then
                local ok, p = pcall(function() return loc:GetPivot().Position end)
                if ok then pos = p end
            end
            
            if pos then
                reach(pos)
                -- Fire all prompts
                for _, d in ipairs(loc:GetDescendants()) do
                    if d:IsA("ProximityPrompt") then
                        pcall(function()
                            local hold = tonumber(d.HoldDuration) or 0
                            d:InputHoldBegin()
                            task.wait(hold + 0.1)
                            d:InputHoldEnd()
                        end)
                    end
                end
                -- Touch
                local part = loc:IsA("BasePart") and loc or loc:FindFirstChildWhichIsA("BasePart", true)
                if part and hrp() then
                    pcall(function()
                        if firetouchinterest then
                            firetouchinterest(hrp(), part, 0)
                            firetouchinterest(hrp(), part, 1)
                        end
                    end)
                end
                task.wait(0.2)
            end
        end
    end
end

--========================== UI LIBRARY ==========================--
local Main = Instance.new("Frame")
Main.Name = "Main"
Main.AnchorPoint = Vector2.new(0.5, 0.5)
Main.Position = UDim2.new(0.5, 0, 0.5, 0)
Main.Size = CONFIG.WindowSize
Main.BackgroundColor3 = CONFIG.Colors.Background
Main.BorderSizePixel = 0
Main.ClipsDescendants = true
Main.Parent = ScreenGui

local MainCorner = Instance.new("UICorner")
MainCorner.CornerRadius = UDim.new(0, 12)
MainCorner.Parent = Main

local MainStroke = Instance.new("UIStroke")
MainStroke.Color = CONFIG.Colors.Stroke
MainStroke.Thickness = 1
MainStroke.Parent = Main

-- TopBar
local TopBar = Instance.new("Frame")
TopBar.Name = "TopBar"
TopBar.Size = UDim2.new(1, 0, 0, 34)
TopBar.BackgroundColor3 = CONFIG.Colors.TopBar
TopBar.BorderSizePixel = 0
TopBar.Parent = Main

local TopBarCorner = Instance.new("UICorner")
TopBarCorner.CornerRadius = UDim.new(0, 12)
TopBarCorner.Parent = TopBar

local TopBarFix = Instance.new("Frame")
TopBarFix.BackgroundColor3 = CONFIG.Colors.TopBar
TopBarFix.BorderSizePixel = 0
TopBarFix.ZIndex = 0
TopBarFix.Size = UDim2.new(1, 0, 0, 12)
TopBarFix.Position = UDim2.new(0, 0, 1, -12)
TopBarFix.Parent = TopBar

local Title = Instance.new("TextLabel")
Title.Name = "Title"
Title.BackgroundTransparency = 1
Title.Position = UDim2.new(0, 14, 0, 0)
Title.Size = UDim2.new(1, -80, 1, 0)
Title.Font = Enum.Font.GothamBold
Title.Text = CONFIG.Name
Title.TextColor3 = Color3.fromRGB(255, 255, 255)
Title.TextSize = 14
Title.TextXAlignment = Enum.TextXAlignment.Left
Title.TextTruncate = Enum.TextTruncate.AtEnd
Title.Parent = TopBar

-- Animated purple→black moving gradient on the title text
local TitleGradient = Instance.new("UIGradient")
TitleGradient.Color = ColorSequence.new({
    ColorSequenceKeypoint.new(0,    Color3.fromRGB(200, 120, 255)),
    ColorSequenceKeypoint.new(0.28, Color3.fromRGB(168,  85, 247)),
    ColorSequenceKeypoint.new(0.45, Color3.fromRGB(10,    0,  20)),
    ColorSequenceKeypoint.new(0.55, Color3.fromRGB(10,    0,  20)),
    ColorSequenceKeypoint.new(0.72, Color3.fromRGB(168,  85, 247)),
    ColorSequenceKeypoint.new(1,    Color3.fromRGB(200, 120, 255)),
})
TitleGradient.Rotation = 0
TitleGradient.Parent = Title
RunService.Heartbeat:Connect(function()
    local t = tick() * 0.55
    TitleGradient.Offset = Vector2.new(math.sin(t) * 0.6, 0)
end)

local MinimizeBtn = Instance.new("TextButton")
MinimizeBtn.AnchorPoint = Vector2.new(1, 0.5)
MinimizeBtn.Position = UDim2.new(1, -38, 0.5, 0)
MinimizeBtn.Size = UDim2.new(0, 22, 0, 22)
MinimizeBtn.BackgroundTransparency = 1
MinimizeBtn.AutoButtonColor = false
MinimizeBtn.Font = Enum.Font.GothamBold
MinimizeBtn.Text = "-"
MinimizeBtn.TextColor3 = CONFIG.Colors.TextSecondary
MinimizeBtn.TextSize = 16
MinimizeBtn.Parent = TopBar

local CloseButton = Instance.new("TextButton")
CloseButton.AnchorPoint = Vector2.new(1, 0.5)
CloseButton.Position = UDim2.new(1, -10, 0.5, 0)
CloseButton.Size = UDim2.new(0, 22, 0, 22)
CloseButton.BackgroundTransparency = 1
CloseButton.AutoButtonColor = false
CloseButton.Font = Enum.Font.GothamBold
CloseButton.Text = "X"
CloseButton.TextColor3 = CONFIG.Colors.TextSecondary
CloseButton.TextSize = 13
CloseButton.Parent = TopBar

-- Button hover effects
MinimizeBtn.MouseEnter:Connect(function()
    TweenService:Create(MinimizeBtn, TweenInfo.new(0.15), {TextColor3 = CONFIG.Colors.Accent}):Play()
end)
MinimizeBtn.MouseLeave:Connect(function()
    TweenService:Create(MinimizeBtn, TweenInfo.new(0.15), {TextColor3 = CONFIG.Colors.TextSecondary}):Play()
end)

CloseButton.MouseEnter:Connect(function()
    TweenService:Create(CloseButton, TweenInfo.new(0.15), {TextColor3 = CONFIG.Colors.Accent}):Play()
end)
CloseButton.MouseLeave:Connect(function()
    TweenService:Create(CloseButton, TweenInfo.new(0.15), {TextColor3 = CONFIG.Colors.TextSecondary}):Play()
end)
CloseButton.MouseButton1Click:Connect(function()
    Main.Visible = false
end)

UserInputService.InputBegan:Connect(function(input, gameProcessed)
    if gameProcessed then return end
    if input.KeyCode == CONFIG.HotKey then
        Main.Visible = not Main.Visible
    end
end)

-- Minimized logo
local MinimizedLogo = Instance.new("TextButton")
MinimizedLogo.Size = UDim2.new(0, 48, 0, 48)
MinimizedLogo.Position = UDim2.new(0, 16, 0.5, -24)
MinimizedLogo.BackgroundColor3 = CONFIG.Colors.Accent
MinimizedLogo.Text = ""
MinimizedLogo.TextSize = 26
MinimizedLogo.Font = Enum.Font.GothamBold
MinimizedLogo.Visible = false
MinimizedLogo.Parent = ScreenGui
MinimizedLogo.AutoButtonColor = false

local MinLogoCorner = Instance.new("UICorner")
MinLogoCorner.CornerRadius = UDim.new(1, 0)
MinLogoCorner.Parent = MinimizedLogo

local MinLogoStroke = Instance.new("UIStroke")
MinLogoStroke.Color = CONFIG.Colors.Stroke
MinLogoStroke.Thickness = 2
MinLogoStroke.Parent = MinimizedLogo

MinimizeBtn.MouseButton1Click:Connect(function()
    Main.Visible = false
    MinimizedLogo.Visible = true
end)

MinimizedLogo.MouseButton1Click:Connect(function()
    MinimizedLogo.Visible = false
    Main.Visible = true
end)

-- Dragging
local dragging, dragInput, dragStart, startPos
TopBar.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        dragging = true
        dragStart = input.Position
        startPos = Main.Position
        input.Changed:Connect(function()
            if input.UserInputState == Enum.UserInputState.End then
                dragging = false
            end
        end)
    end
end)
TopBar.InputChanged:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
        dragInput = input
    end
end)
UserInputService.InputChanged:Connect(function(input)
    if input == dragInput and dragging then
        local delta = input.Position - dragStart
        Main.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
    end
end)

-- Minimized logo dragging
local dragging2, dragInput2, dragStart2, startPos2
MinimizedLogo.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        dragging2 = true
        dragStart2 = input.Position
        startPos2 = MinimizedLogo.Position
        input.Changed:Connect(function()
            if input.UserInputState == Enum.UserInputState.End then
                dragging2 = false
            end
        end)
    end
end)
MinimizedLogo.InputChanged:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
        dragInput2 = input
    end
end)
UserInputService.InputChanged:Connect(function(input)
    if input == dragInput2 and dragging2 then
        local delta = input.Position - dragStart2
        MinimizedLogo.Position = UDim2.new(startPos2.X.Scale, startPos2.X.Offset + delta.X, startPos2.Y.Scale, startPos2.Y.Offset + delta.Y)
    end
end)

-- Body
local Body = Instance.new("Frame")
Body.Name = "Body"
Body.BackgroundTransparency = 1
Body.Position = UDim2.new(0, 0, 0, 34)
Body.Size = UDim2.new(1, 0, 1, -34)
Body.Parent = Main

local Sidebar = Instance.new("Frame")
Sidebar.Name = "Sidebar"
Sidebar.BackgroundTransparency = 1
Sidebar.Size = UDim2.new(0, CONFIG.SidebarWidth, 1, 0)
Sidebar.Parent = Body

local SidebarPadding = Instance.new("UIPadding")
SidebarPadding.PaddingTop = UDim.new(0, 8)
SidebarPadding.PaddingLeft = UDim.new(0, 8)
SidebarPadding.PaddingRight = UDim.new(0, 6)
SidebarPadding.Parent = Sidebar

local SidebarList = Instance.new("UIListLayout")
SidebarList.Padding = UDim.new(0, 3)
SidebarList.SortOrder = Enum.SortOrder.LayoutOrder
SidebarList.Parent = Sidebar

local Divider = Instance.new("Frame")
Divider.Name = "Divider"
Divider.BackgroundColor3 = CONFIG.Colors.Stroke
Divider.BorderSizePixel = 0
Divider.Size = UDim2.new(0, 1, 1, 0)
Divider.Position = UDim2.new(0, CONFIG.SidebarWidth, 0, 0)
Divider.Parent = Body

local ContentContainer = Instance.new("Frame")
ContentContainer.Name = "ContentContainer"
ContentContainer.BackgroundTransparency = 1
ContentContainer.Position = UDim2.new(0, CONFIG.SidebarWidth + 1, 0, 0)
ContentContainer.Size = UDim2.new(1, -(CONFIG.SidebarWidth + 1), 1, 0)
ContentContainer.Parent = Body

local ContentPadding = Instance.new("UIPadding")
ContentPadding.PaddingTop = UDim.new(0, 10)
ContentPadding.PaddingBottom = UDim.new(0, 10)
ContentPadding.PaddingLeft = UDim.new(0, 10)
ContentPadding.PaddingRight = UDim.new(0, 10)
ContentPadding.Parent = ContentContainer

--========================== TAB SYSTEM ==========================--
local Library = {}
Library.Tabs = {}

function Library:selectTab(tabName)
    for _, tab in ipairs(self.Tabs) do
        local active = tab.Name == tabName
        tab.Content.Visible = active
        TweenService:Create(tab.Button, TweenInfo.new(0.15), {
            TextColor3 = active and CONFIG.Colors.TextPrimary or CONFIG.Colors.TextSecondary,
            BackgroundTransparency = active and 0 or 1,
        }):Play()
        TweenService:Create(tab.Indicator, TweenInfo.new(0.15), {
            BackgroundTransparency = active and 0 or 1,
        }):Play()
    end
end

function Library:addTab(tabName)
    local Button = Instance.new("TextButton")
    Button.Name = tabName
    Button.Size = UDim2.new(1, 0, 0, 28)
    Button.BackgroundColor3 = CONFIG.Colors.Card
    Button.BackgroundTransparency = 1
    Button.AutoButtonColor = false
    Button.Font = Enum.Font.GothamMedium
    Button.Text = tabName
    Button.TextColor3 = CONFIG.Colors.TextSecondary
    Button.TextSize = 12
    Button.TextXAlignment = Enum.TextXAlignment.Left
    Button.TextTruncate = Enum.TextTruncate.AtEnd
    Button.Parent = Sidebar

    local ButtonCorner = Instance.new("UICorner")
    ButtonCorner.CornerRadius = UDim.new(0, 6)
    ButtonCorner.Parent = Button

    local ButtonPadding = Instance.new("UIPadding")
    ButtonPadding.PaddingLeft = UDim.new(0, 10)
    ButtonPadding.PaddingRight = UDim.new(0, 6)
    ButtonPadding.Parent = Button

    local Indicator = Instance.new("Frame")
    Indicator.AnchorPoint = Vector2.new(0, 0.5)
    Indicator.Position = UDim2.new(0, 0, 0.5, 0)
    Indicator.Size = UDim2.new(0, 3, 0, 12)
    Indicator.BackgroundColor3 = CONFIG.Colors.Accent
    Indicator.BackgroundTransparency = 1
    Indicator.BorderSizePixel = 0
    Indicator.Parent = Button

    local IndicatorCorner = Instance.new("UICorner")
    IndicatorCorner.CornerRadius = UDim.new(1, 0)
    IndicatorCorner.Parent = Indicator

    local Content = Instance.new("ScrollingFrame")
    Content.Name = tabName .. "_Page"
    Content.BackgroundTransparency = 1
    Content.BorderSizePixel = 0
    Content.Size = UDim2.new(1, 0, 1, 0)
    Content.CanvasSize = UDim2.new(0, 0, 0, 0)
    Content.AutomaticCanvasSize = Enum.AutomaticSize.Y
    Content.ScrollingDirection = Enum.ScrollingDirection.Y
    Content.ScrollBarThickness = 2
    Content.ScrollBarImageColor3 = CONFIG.Colors.Accent
    Content.Visible = false
    Content.Parent = ContentContainer

    local ContentList = Instance.new("UIListLayout")
    ContentList.Padding = UDim.new(0, 6)
    ContentList.SortOrder = Enum.SortOrder.LayoutOrder
    ContentList.Parent = Content

    Button.MouseButton1Click:Connect(function()
        Library:selectTab(tabName)
    end)

    Button.MouseEnter:Connect(function()
        if Content.Visible then return end
        TweenService:Create(Button, TweenInfo.new(0.15), {BackgroundTransparency = 0.6}):Play()
    end)

    Button.MouseLeave:Connect(function()
        if Content.Visible then return end
        TweenService:Create(Button, TweenInfo.new(0.15), {BackgroundTransparency = 1}):Play()
    end)

    table.insert(self.Tabs, {
        Name = tabName,
        Button = Button,
        Content = Content,
        Indicator = Indicator,
    })

    if #self.Tabs == 1 then
        Library:selectTab(tabName)
    end

    local TabObject = {}
    function TabObject:addToggle(toggleName, default, callback)
        return Library:addToggle(Content, toggleName, default, callback)
    end
    function TabObject:addSlider(name, min, max, default, callback)
        return Library:addSlider(Content, name, min, max, default, callback)
    end
    function TabObject:addDropdown(name, options, callback)
        return Library:addDropdown(Content, name, options, callback)
    end
    function TabObject:addLabel(text)
        return Library:addLabel(Content, text)
    end
    function TabObject:addInput(name, placeholder, default, callback)
        return Library:addInput(Content, name, placeholder, default, callback)
    end
    function TabObject:addButton(name, callback)
        return Library:addButton(Content, name, callback)
    end
    function TabObject:addMultiSelect(name, getOptionsFn, selectedSet, callback)
        return Library:addMultiSelect(Content, name, getOptionsFn, selectedSet, callback)
    end
    function TabObject:addChoice(name, options, default, callback)
        return Library:addChoice(Content, name, options, default, callback)
    end
    function TabObject:addInlineDropdown(name, options, default, callback)
        return Library:addInlineDropdown(Content, name, options, default, callback)
    end
    return TabObject
end

function Library:addToggle(parent, toggleName, default, callback)
    default = default or false
    callback = callback or function() end

    local Row = Instance.new("Frame")
    Row.Name = toggleName
    Row.Size = UDim2.new(1, 0, 0, 34)
    Row.BackgroundColor3 = CONFIG.Colors.Card
    Row.BorderSizePixel = 0
    Row.Parent = parent

    local RowCorner = Instance.new("UICorner")
    RowCorner.CornerRadius = UDim.new(0, 8)
    RowCorner.Parent = Row

    local Label = Instance.new("TextLabel")
    Label.BackgroundTransparency = 1
    Label.Position = UDim2.new(0, 10, 0, 0)
    Label.Size = UDim2.new(1, -56, 1, 0)
    Label.Font = Enum.Font.Gotham
    Label.Text = toggleName
    Label.TextColor3 = CONFIG.Colors.TextPrimary
    Label.TextSize = 12
    Label.TextXAlignment = Enum.TextXAlignment.Left
    Label.TextTruncate = Enum.TextTruncate.AtEnd
    Label.Parent = Row

    local Switch = Instance.new("Frame")
    Switch.AnchorPoint = Vector2.new(1, 0.5)
    Switch.Position = UDim2.new(1, -10, 0.5, 0)
    Switch.Size = UDim2.new(0, 32, 0, 16)
    Switch.BackgroundColor3 = default and CONFIG.Colors.Accent or CONFIG.Colors.ToggleOff
    Switch.BorderSizePixel = 0
    Switch.Parent = Row

    local SwitchCorner = Instance.new("UICorner")
    SwitchCorner.CornerRadius = UDim.new(1, 0)
    SwitchCorner.Parent = Switch

    local Knob = Instance.new("Frame")
    Knob.AnchorPoint = Vector2.new(0, 0.5)
    Knob.Position = default and UDim2.new(1, -14, 0.5, 0) or UDim2.new(0, 2, 0.5, 0)
    Knob.Size = UDim2.new(0, 12, 0, 12)
    Knob.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
    Knob.BorderSizePixel = 0
    Knob.Parent = Switch

    local KnobCorner = Instance.new("UICorner")
    KnobCorner.CornerRadius = UDim.new(1, 0)
    KnobCorner.Parent = Knob

    local ClickArea = Instance.new("TextButton")
    ClickArea.BackgroundTransparency = 1
    ClickArea.Size = UDim2.new(1, 0, 1, 0)
    ClickArea.Text = ""
    ClickArea.Parent = Row

    local state = default
    local Toggle = {}

    local function refresh()
        TweenService:Create(Switch, TweenInfo.new(0.18), {
            BackgroundColor3 = state and CONFIG.Colors.Accent or CONFIG.Colors.ToggleOff,
        }):Play()
        TweenService:Create(Knob, TweenInfo.new(0.18), {
            Position = state and UDim2.new(1, -14, 0.5, 0) or UDim2.new(0, 2, 0.5, 0),
        }):Play()
    end

    ClickArea.MouseButton1Click:Connect(function()
        state = not state
        refresh()
        callback(state)
    end)

    function Toggle:Set(value)
        state = value
        refresh()
        callback(state)
    end

    function Toggle:Get()
        return state
    end

    return Toggle
end

-- NOTE: sliders were replaced with plain numeric input boxes (no drag track).
-- Same signature as before (parent, name, min, max, default, callback) so
-- every existing call site keeps working unmodified. Type a number + press
-- Enter/click away to apply it; out-of-range values are clamped.
function Library:addSlider(parent, name, min, max, default, callback)
    local Frame = Instance.new("Frame")
    Frame.Size = UDim2.new(1, 0, 0, 34)
    Frame.BackgroundColor3 = CONFIG.Colors.Card
    Frame.BorderSizePixel = 0
    Frame.Parent = parent

    local FrameCorner = Instance.new("UICorner")
    FrameCorner.CornerRadius = UDim.new(0, 8)
    FrameCorner.Parent = Frame

    local Label = Instance.new("TextLabel")
    Label.BackgroundTransparency = 1
    Label.Position = UDim2.new(0, 10, 0, 0)
    Label.Size = UDim2.new(1, -76, 1, 0)
    Label.Font = Enum.Font.Gotham
    Label.Text = name .. "  (" .. tostring(min) .. "-" .. tostring(max) .. ")"
    Label.TextColor3 = CONFIG.Colors.TextPrimary
    Label.TextSize = 12
    Label.TextXAlignment = Enum.TextXAlignment.Left
    Label.TextTruncate = Enum.TextTruncate.AtEnd
    Label.Parent = Frame

    local Box = Instance.new("Frame")
    Box.AnchorPoint = Vector2.new(1, 0.5)
    Box.Position = UDim2.new(1, -10, 0.5, 0)
    Box.Size = UDim2.new(0, 58, 0, 22)
    Box.BackgroundColor3 = CONFIG.Colors.InputBg
    Box.BorderSizePixel = 0
    Box.Parent = Frame

    local BoxCorner = Instance.new("UICorner")
    BoxCorner.CornerRadius = UDim.new(0, 6)
    BoxCorner.Parent = Box

    local function fmt(v)
        if v == math.floor(v) then return tostring(math.floor(v)) end
        return tostring(math.floor(v * 100 + 0.5) / 100)
    end

    local InputBox = Instance.new("TextBox")
    InputBox.Size = UDim2.new(1, -8, 1, 0)
    InputBox.Position = UDim2.new(0, 4, 0, 0)
    InputBox.BackgroundTransparency = 1
    InputBox.Font = Enum.Font.GothamBold
    InputBox.Text = fmt(default)
    InputBox.TextColor3 = CONFIG.Colors.Accent
    InputBox.TextSize = 12
    InputBox.ClearTextOnFocus = false
    InputBox.TextXAlignment = Enum.TextXAlignment.Center
    InputBox.Parent = Box

    local cur = default
    InputBox.FocusLost:Connect(function()
        local num = tonumber((tostring(InputBox.Text):gsub("[^%d%.%-]", "")))
        if num then
            cur = math.clamp(num, min, max)
        end
        InputBox.Text = fmt(cur)
        callback(cur)
    end)

    return Frame
end


local function _ensurePickerLayer()
    local layer = ScreenGui:FindFirstChild("VincitorePickerLayer")
    if layer then return layer end

    layer = Instance.new("ScreenGui")
    layer.Name = "VincitorePickerLayer"
    layer.IgnoreGuiInset = true
    layer.ResetOnSpawn = false
    layer.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    layer.Parent = PlayerGui

    return layer
end

function Library:_openPicker(title, optionsFn, selectedSet, multi, onSinglePick, onCommit)
    local layer = _ensurePickerLayer()
    for _, child in ipairs(layer:GetChildren()) do
        child:Destroy()
    end

    local selected = selectedSet or {}
    local popup = Instance.new("Frame")
    popup.Name = "Popup"
    popup.AnchorPoint = Vector2.new(0.5, 0.5)
    popup.Position = UDim2.new(0.5, 0, 0.5, 0)
    popup.Size = UDim2.new(0, 250, 0, 250)
    popup.BackgroundColor3 = CONFIG.Colors.Background
    popup.BorderSizePixel = 0
    popup.Parent = layer

    local pc = Instance.new("UICorner")
    pc.CornerRadius = UDim.new(0, 12)
    pc.Parent = popup

    local ps = Instance.new("UIStroke")
    ps.Color = CONFIG.Colors.Stroke
    ps.Thickness = 1
    ps.Parent = popup

    -- Accent header bar
    local headerBar = Instance.new("Frame")
    headerBar.Size = UDim2.new(1, 0, 0, 36)
    headerBar.BackgroundColor3 = CONFIG.Colors.TopBar
    headerBar.BorderSizePixel = 0
    headerBar.Parent = popup

    local headerCorner = Instance.new("UICorner")
    headerCorner.CornerRadius = UDim.new(0, 12)
    headerCorner.Parent = headerBar

    local headerFix = Instance.new("Frame")
    headerFix.BackgroundColor3 = CONFIG.Colors.TopBar
    headerFix.BorderSizePixel = 0
    headerFix.Size = UDim2.new(1, 0, 0, 12)
    headerFix.Position = UDim2.new(0, 0, 1, -12)
    headerFix.Parent = headerBar

    local headerAccent = Instance.new("Frame")
    headerAccent.Size = UDim2.new(0, 3, 0.6, 0)
    headerAccent.AnchorPoint = Vector2.new(0, 0.5)
    headerAccent.Position = UDim2.new(0, 8, 0.5, 0)
    headerAccent.BackgroundColor3 = CONFIG.Colors.Accent
    headerAccent.BorderSizePixel = 0
    headerAccent.Parent = headerBar

    local headerAccentCorner = Instance.new("UICorner")
    headerAccentCorner.CornerRadius = UDim.new(1, 0)
    headerAccentCorner.Parent = headerAccent

    local titleLbl = Instance.new("TextLabel")
    titleLbl.BackgroundTransparency = 1
    titleLbl.Position = UDim2.new(0, 18, 0, 0)
    titleLbl.Size = UDim2.new(1, -24, 1, 0)
    titleLbl.Font = Enum.Font.GothamBold
    titleLbl.Text = title
    titleLbl.TextColor3 = CONFIG.Colors.TextPrimary
    titleLbl.TextSize = 12
    titleLbl.TextXAlignment = Enum.TextXAlignment.Left
    titleLbl.Parent = headerBar

    local searchBg = Instance.new("Frame")
    searchBg.Position = UDim2.new(0, 12, 0, 44)
    searchBg.Size = UDim2.new(1, -24, 0, 28)
    searchBg.BackgroundColor3 = CONFIG.Colors.InputBg
    searchBg.BorderSizePixel = 0
    searchBg.Parent = popup

    local searchBgCorner = Instance.new("UICorner")
    searchBgCorner.CornerRadius = UDim.new(0, 8)
    searchBgCorner.Parent = searchBg

    local searchStroke = Instance.new("UIStroke")
    searchStroke.Color = CONFIG.Colors.Stroke
    searchStroke.Thickness = 1
    searchStroke.Parent = searchBg

    local search = Instance.new("TextBox")
    search.Size = UDim2.new(1, -16, 1, 0)
    search.Position = UDim2.new(0, 8, 0, 0)
    search.BackgroundTransparency = 1
    search.ClearTextOnFocus = false
    search.PlaceholderText = "Search..."
    search.PlaceholderColor3 = CONFIG.Colors.TextSecondary
    search.Text = ""
    search.Font = Enum.Font.Gotham
    search.TextSize = 12
    search.TextColor3 = CONFIG.Colors.TextPrimary
    search.TextXAlignment = Enum.TextXAlignment.Left
    search.Parent = searchBg

    search.Focused:Connect(function()
        TweenService:Create(searchStroke, TweenInfo.new(0.15), {Color = CONFIG.Colors.Accent}):Play()
    end)
    search.FocusLost:Connect(function()
        TweenService:Create(searchStroke, TweenInfo.new(0.15), {Color = CONFIG.Colors.Stroke}):Play()
    end)

    local list = Instance.new("ScrollingFrame")
    list.Position = UDim2.new(0, 12, 0, 80)
    list.Size = UDim2.new(1, -24, 1, -134)
    list.BackgroundColor3 = CONFIG.Colors.InputBg
    list.BorderSizePixel = 0
    list.ScrollBarThickness = 3
    list.ScrollBarImageColor3 = CONFIG.Colors.Accent
    list.AutomaticCanvasSize = Enum.AutomaticSize.Y
    list.CanvasSize = UDim2.new(0, 0, 0, 0)
    list.Parent = popup

    local listCorner = Instance.new("UICorner")
    listCorner.CornerRadius = UDim.new(0, 8)
    listCorner.Parent = list

    local layout = Instance.new("UIListLayout")
    layout.Padding = UDim.new(0, 4)
    layout.SortOrder = Enum.SortOrder.LayoutOrder
    layout.Parent = list

    local pad = Instance.new("UIPadding")
    pad.PaddingTop = UDim.new(0, 6)
    pad.PaddingBottom = UDim.new(0, 6)
    pad.PaddingLeft = UDim.new(0, 6)
    pad.PaddingRight = UDim.new(0, 6)
    pad.Parent = list

    local footer = Instance.new("Frame")
    footer.BackgroundTransparency = 1
    footer.Position = UDim2.new(0, 12, 1, -44)
    footer.Size = UDim2.new(1, -24, 0, 32)
    footer.Parent = popup

    local function close()
        if popup and popup.Parent then popup:Destroy() end
    end

    local function optionList()
        local raw = optionsFn and optionsFn() or {}
        local out = {}
        for _, v in ipairs(raw) do
            out[#out + 1] = tostring(v)
        end
        table.sort(out)
        return out
    end

    local function isOn(name)
        return selected[name] == true
    end

    local function setOn(name, on)
        if on then
            selected[name] = true
        else
            selected[name] = nil
        end
    end

    local function rebuild()
        for _, child in ipairs(list:GetChildren()) do
            if child:IsA("TextButton") or child:IsA("Frame") then child:Destroy() end
        end

        local q = string.lower(search.Text or "")
        local opts = optionList()
        for i, optName in ipairs(opts) do
            if q == "" or string.find(string.lower(optName), q, 1, true) then
                local on = isOn(optName)

                local row = Instance.new("TextButton")
                row.Size = UDim2.new(1, 0, 0, 30)
                row.BackgroundColor3 = on and Color3.fromRGB(90, 40, 140) or CONFIG.Colors.Card
                row.AutoButtonColor = false
                row.Text = ""
                row.LayoutOrder = i
                row.Parent = list

                local rc = Instance.new("UICorner")
                rc.CornerRadius = UDim.new(0, 6)
                rc.Parent = row

                local rs = Instance.new("UIStroke")
                rs.Color = on and CONFIG.Colors.Accent or CONFIG.Colors.Stroke
                rs.Thickness = 1
                rs.Parent = row

                -- Checkmark / radio dot on left
                local icon = Instance.new("TextLabel")
                icon.BackgroundTransparency = 1
                icon.Position = UDim2.new(0, 6, 0, 0)
                icon.Size = UDim2.new(0, 18, 1, 0)
                icon.Font = Enum.Font.GothamBold
                icon.Text = multi and (on and "v" or "-") or (on and "*" or "-")
                icon.TextColor3 = on and CONFIG.Colors.Accent or CONFIG.Colors.TextSecondary
                icon.TextSize = 11
                icon.TextXAlignment = Enum.TextXAlignment.Center
                icon.Parent = row

                local lbl = Instance.new("TextLabel")
                lbl.BackgroundTransparency = 1
                lbl.Position = UDim2.new(0, 26, 0, 0)
                lbl.Size = UDim2.new(1, -30, 1, 0)
                lbl.Font = on and Enum.Font.GothamMedium or Enum.Font.Gotham
                lbl.Text = optName
                lbl.TextColor3 = on and CONFIG.Colors.TextPrimary or CONFIG.Colors.TextSecondary
                lbl.TextSize = 11
                lbl.TextXAlignment = Enum.TextXAlignment.Left
                lbl.TextTruncate = Enum.TextTruncate.AtEnd
                lbl.Parent = row

                row.MouseEnter:Connect(function()
                    if not isOn(optName) then
                        TweenService:Create(row, TweenInfo.new(0.1), {BackgroundColor3 = CONFIG.Colors.InputBg}):Play()
                        TweenService:Create(rs, TweenInfo.new(0.1), {Color = CONFIG.Colors.Accent}):Play()
                    end
                end)
                row.MouseLeave:Connect(function()
                    if not isOn(optName) then
                        TweenService:Create(row, TweenInfo.new(0.1), {BackgroundColor3 = CONFIG.Colors.Card}):Play()
                        TweenService:Create(rs, TweenInfo.new(0.1), {Color = CONFIG.Colors.Stroke}):Play()
                    end
                end)

                row.MouseButton1Click:Connect(function()
                    if multi then
                        setOn(optName, not isOn(optName))
                        if onCommit then onCommit(selected) end
                        rebuild()
                    else
                        if onSinglePick then onSinglePick(optName) end
                        close()
                    end
                end)
            end
        end
    end

    local clearBtn = Instance.new("TextButton")
    clearBtn.Size = UDim2.new(0.5, -4, 1, 0)
    clearBtn.BackgroundColor3 = CONFIG.Colors.Card
    clearBtn.AutoButtonColor = false
    clearBtn.Text = multi and "Clear" or "Cancel"
    clearBtn.Font = Enum.Font.GothamBold
    clearBtn.TextSize = 11
    clearBtn.TextColor3 = CONFIG.Colors.TextSecondary
    clearBtn.Parent = footer
    local clearCorner = Instance.new("UICorner"); clearCorner.CornerRadius = UDim.new(0, 8); clearCorner.Parent = clearBtn
    local clearStroke = Instance.new("UIStroke"); clearStroke.Color = CONFIG.Colors.Stroke; clearStroke.Thickness = 1; clearStroke.Parent = clearBtn
    clearBtn.MouseEnter:Connect(function()
        TweenService:Create(clearBtn, TweenInfo.new(0.12), {TextColor3 = CONFIG.Colors.Red, BackgroundColor3 = CONFIG.Colors.InputBg}):Play()
    end)
    clearBtn.MouseLeave:Connect(function()
        TweenService:Create(clearBtn, TweenInfo.new(0.12), {TextColor3 = CONFIG.Colors.TextSecondary, BackgroundColor3 = CONFIG.Colors.Card}):Play()
    end)

    local doneBtn = Instance.new("TextButton")
    doneBtn.Size = UDim2.new(0.5, -4, 1, 0)
    doneBtn.Position = UDim2.new(0.5, 4, 0, 0)
    doneBtn.BackgroundColor3 = CONFIG.Colors.Accent
    doneBtn.AutoButtonColor = false
    doneBtn.Text = multi and "Done" or "Select"
    doneBtn.Font = Enum.Font.GothamBold
    doneBtn.TextSize = 11
    doneBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
    doneBtn.Parent = footer
    local doneCorner = Instance.new("UICorner"); doneCorner.CornerRadius = UDim.new(0, 8); doneCorner.Parent = doneBtn
    doneBtn.MouseEnter:Connect(function()
        TweenService:Create(doneBtn, TweenInfo.new(0.12), {BackgroundColor3 = Color3.fromRGB(190, 110, 255)}):Play()
    end)
    doneBtn.MouseLeave:Connect(function()
        TweenService:Create(doneBtn, TweenInfo.new(0.12), {BackgroundColor3 = CONFIG.Colors.Accent}):Play()
    end)

    if multi then
        clearBtn.MouseButton1Click:Connect(function()
            for k in pairs(selected) do selected[k] = nil end
            if onCommit then onCommit(selected) end
            rebuild()
        end)
        doneBtn.MouseButton1Click:Connect(function()
            if onCommit then onCommit(selected) end
            close()
        end)
    else
        clearBtn.MouseButton1Click:Connect(close)
        doneBtn.MouseButton1Click:Connect(function()
            local opts = optionList()
            if #opts > 0 and onSinglePick then
                onSinglePick(opts[1])
            end
            close()
        end)
    end

    search:GetPropertyChangedSignal("Text"):Connect(rebuild)
    rebuild()
    return close
end

function Library:addDropdown(parent, name, options, callback)
    local Frame = Instance.new("Frame")
    Frame.Size = UDim2.new(1, 0, 0, 48)
    Frame.BackgroundColor3 = CONFIG.Colors.Card
    Frame.BorderSizePixel = 0
    Frame.Parent = parent

    local FrameCorner = Instance.new("UICorner")
    FrameCorner.CornerRadius = UDim.new(0, 8)
    FrameCorner.Parent = Frame

    local Label = Instance.new("TextLabel")
    Label.BackgroundTransparency = 1
    Label.Position = UDim2.new(0, 10, 0, 5)
    Label.Size = UDim2.new(1, -20, 0, 13)
    Label.Font = Enum.Font.GothamMedium
    Label.Text = name
    Label.TextColor3 = CONFIG.Colors.TextSecondary
    Label.TextSize = 10
    Label.TextXAlignment = Enum.TextXAlignment.Left
    Label.Parent = Frame

    -- Trigger button
    local Trig = Instance.new("TextButton")
    Trig.Position = UDim2.new(0, 8, 0, 21)
    Trig.Size = UDim2.new(1, -16, 0, 22)
    Trig.BackgroundColor3 = CONFIG.Colors.InputBg
    Trig.AutoButtonColor = false
    Trig.Text = ""
    Trig.Parent = Frame

    local TrigCorner = Instance.new("UICorner")
    TrigCorner.CornerRadius = UDim.new(0, 6)
    TrigCorner.Parent = Trig

    local TrigStroke = Instance.new("UIStroke")
    TrigStroke.Color = CONFIG.Colors.Stroke
    TrigStroke.Thickness = 1
    TrigStroke.Parent = Trig

    local ValueLbl = Instance.new("TextLabel")
    ValueLbl.BackgroundTransparency = 1
    ValueLbl.Position = UDim2.new(0, 8, 0, 0)
    ValueLbl.Size = UDim2.new(1, -28, 1, 0)
    ValueLbl.Font = Enum.Font.GothamBold
    ValueLbl.Text = options[1] or "Select..."
    ValueLbl.TextColor3 = CONFIG.Colors.Accent
    ValueLbl.TextSize = 11
    ValueLbl.TextXAlignment = Enum.TextXAlignment.Left
    ValueLbl.TextTruncate = Enum.TextTruncate.AtEnd
    ValueLbl.Parent = Trig

    local Chevron = Instance.new("TextLabel")
    Chevron.BackgroundTransparency = 1
    Chevron.AnchorPoint = Vector2.new(1, 0.5)
    Chevron.Position = UDim2.new(1, -7, 0.5, 0)
    Chevron.Size = UDim2.new(0, 14, 0, 14)
    Chevron.Font = Enum.Font.GothamBold
    Chevron.Text = "▾"
    Chevron.TextColor3 = CONFIG.Colors.Accent
    Chevron.TextSize = 13
    Chevron.TextXAlignment = Enum.TextXAlignment.Center
    Chevron.Parent = Trig

    Trig.MouseEnter:Connect(function()
        TweenService:Create(TrigStroke, TweenInfo.new(0.15), {Color = CONFIG.Colors.Accent, Thickness = 1.5}):Play()
        TweenService:Create(Trig, TweenInfo.new(0.15), {BackgroundColor3 = CONFIG.Colors.Card}):Play()
    end)
    Trig.MouseLeave:Connect(function()
        TweenService:Create(TrigStroke, TweenInfo.new(0.15), {Color = CONFIG.Colors.Stroke, Thickness = 1}):Play()
        TweenService:Create(Trig, TweenInfo.new(0.15), {BackgroundColor3 = CONFIG.Colors.InputBg}):Play()
    end)

    local current = options[1]
    Trig.MouseButton1Click:Connect(function()
        TweenService:Create(Chevron, TweenInfo.new(0.12), {Rotation = 180}):Play()
        TweenService:Create(TrigStroke, TweenInfo.new(0.1), {Color = CONFIG.Colors.Accent}):Play()
        self:_openPicker(name, function() return options end, {}, false, function(choice)
            current = choice
            ValueLbl.Text = choice
            if callback then callback(choice) end
        end, nil)
        task.delay(0.2, function()
            TweenService:Create(Chevron, TweenInfo.new(0.12), {Rotation = 0}):Play()
            TweenService:Create(TrigStroke, TweenInfo.new(0.2), {Color = CONFIG.Colors.Stroke}):Play()
        end)
    end)

    local Drop = {}
    function Drop:Get() return current end
    function Drop:Set(v)
        current = v
        ValueLbl.Text = tostring(v or "Select...")
        if callback then callback(current) end
    end
    return Drop
end

-- simple labeled text input row (recipient username, note, webhook, etc.)
function Library:addInput(parent, name, placeholder, default, callback)
    local Frame = Instance.new("Frame")
    Frame.Size = UDim2.new(1, 0, 0, 50)
    Frame.BackgroundColor3 = CONFIG.Colors.Card
    Frame.BorderSizePixel = 0
    Frame.Parent = parent

    local FrameCorner = Instance.new("UICorner")
    FrameCorner.CornerRadius = UDim.new(0, 8)
    FrameCorner.Parent = Frame

    local Label = Instance.new("TextLabel")
    Label.BackgroundTransparency = 1
    Label.Position = UDim2.new(0, 10, 0, 4)
    Label.Size = UDim2.new(1, -20, 0, 14)
    Label.Font = Enum.Font.Gotham
    Label.Text = name
    Label.TextColor3 = CONFIG.Colors.TextPrimary
    Label.TextSize = 12
    Label.TextXAlignment = Enum.TextXAlignment.Left
    Label.Parent = Frame

    local Box = Instance.new("Frame")
    Box.Position = UDim2.new(0, 8, 0, 22)
    Box.Size = UDim2.new(1, -16, 0, 22)
    Box.BackgroundColor3 = CONFIG.Colors.InputBg
    Box.BorderSizePixel = 0
    Box.Parent = Frame

    local BoxCorner = Instance.new("UICorner")
    BoxCorner.CornerRadius = UDim.new(0, 6)
    BoxCorner.Parent = Box

    local InputBox = Instance.new("TextBox")
    InputBox.Size = UDim2.new(1, -12, 1, 0)
    InputBox.Position = UDim2.new(0, 6, 0, 0)
    InputBox.BackgroundTransparency = 1
    InputBox.Font = Enum.Font.Gotham
    InputBox.PlaceholderText = placeholder or ""
    InputBox.PlaceholderColor3 = CONFIG.Colors.TextSecondary
    InputBox.Text = default or ""
    InputBox.TextColor3 = CONFIG.Colors.TextPrimary
    InputBox.TextSize = 12
    InputBox.ClearTextOnFocus = false
    InputBox.TextXAlignment = Enum.TextXAlignment.Left
    InputBox.TextTruncate = Enum.TextTruncate.AtEnd
    InputBox.Parent = Box

    InputBox.FocusLost:Connect(function()
        if callback then callback(InputBox.Text) end
    end)

    local Input = {}
    function Input:Get() return InputBox.Text end
    function Input:Set(v) InputBox.Text = tostring(v or "") end
    return Input
end

-- simple action button row (Send Now, Harvest Now, etc.)
function Library:addButton(parent, name, callback)
    local Row = Instance.new("TextButton")
    Row.Size = UDim2.new(1, 0, 0, 34)
    Row.BackgroundColor3 = CONFIG.Colors.Card
    Row.AutoButtonColor = false
    Row.Text = ""
    Row.Parent = parent

    local RowCorner = Instance.new("UICorner")
    RowCorner.CornerRadius = UDim.new(0, 8)
    RowCorner.Parent = Row

    local Label = Instance.new("TextLabel")
    Label.BackgroundTransparency = 1
    Label.Size = UDim2.new(1, -20, 1, 0)
    Label.Position = UDim2.new(0, 10, 0, 0)
    Label.Font = Enum.Font.GothamMedium
    Label.Text = name
    Label.TextColor3 = CONFIG.Colors.Accent
    Label.TextSize = 12
    Label.TextXAlignment = Enum.TextXAlignment.Left
    Label.Parent = Row

    Row.MouseEnter:Connect(function()
        TweenService:Create(Row, TweenInfo.new(0.12), { BackgroundColor3 = CONFIG.Colors.InputBg }):Play()
    end)
    Row.MouseLeave:Connect(function()
        TweenService:Create(Row, TweenInfo.new(0.12), { BackgroundColor3 = CONFIG.Colors.Card }):Play()
    end)
    Row.MouseButton1Click:Connect(function()
        if callback then callback() end
    end)

    return Row
end

-- functional single-select dropdown (radio-style) - e.g. Plant Pattern
function Library:addChoice(parent, name, options, default, callback)
    local Frame = Instance.new("Frame")
    Frame.Size = UDim2.new(1, 0, 0, 48)
    Frame.BackgroundColor3 = CONFIG.Colors.Card
    Frame.BorderSizePixel = 0
    Frame.Parent = parent

    local FrameCorner = Instance.new("UICorner")
    FrameCorner.CornerRadius = UDim.new(0, 8)
    FrameCorner.Parent = Frame

    local Label = Instance.new("TextLabel")
    Label.BackgroundTransparency = 1
    Label.Position = UDim2.new(0, 10, 0, 5)
    Label.Size = UDim2.new(1, -20, 0, 13)
    Label.Font = Enum.Font.GothamMedium
    Label.Text = name
    Label.TextColor3 = CONFIG.Colors.TextSecondary
    Label.TextSize = 10
    Label.TextXAlignment = Enum.TextXAlignment.Left
    Label.Parent = Frame

    local Trig = Instance.new("TextButton")
    Trig.Position = UDim2.new(0, 8, 0, 21)
    Trig.Size = UDim2.new(1, -16, 0, 22)
    Trig.BackgroundColor3 = CONFIG.Colors.InputBg
    Trig.AutoButtonColor = false
    Trig.Text = ""
    Trig.Parent = Frame

    local tc = Instance.new("UICorner")
    tc.CornerRadius = UDim.new(0, 6)
    tc.Parent = Trig

    local TrigStroke = Instance.new("UIStroke")
    TrigStroke.Color = CONFIG.Colors.Stroke
    TrigStroke.Thickness = 1
    TrigStroke.Parent = Trig

    local ValueLbl = Instance.new("TextLabel")
    ValueLbl.BackgroundTransparency = 1
    ValueLbl.Position = UDim2.new(0, 8, 0, 0)
    ValueLbl.Size = UDim2.new(1, -28, 1, 0)
    ValueLbl.Font = Enum.Font.GothamBold
    ValueLbl.Text = tostring(default or options[1] or "-")
    ValueLbl.TextColor3 = CONFIG.Colors.Accent
    ValueLbl.TextSize = 11
    ValueLbl.TextXAlignment = Enum.TextXAlignment.Left
    ValueLbl.TextTruncate = Enum.TextTruncate.AtEnd
    ValueLbl.Parent = Trig

    local Chevron = Instance.new("TextLabel")
    Chevron.BackgroundTransparency = 1
    Chevron.AnchorPoint = Vector2.new(1, 0.5)
    Chevron.Position = UDim2.new(1, -7, 0.5, 0)
    Chevron.Size = UDim2.new(0, 14, 0, 14)
    Chevron.Font = Enum.Font.GothamBold
    Chevron.Text = "▾"
    Chevron.TextColor3 = CONFIG.Colors.Accent
    Chevron.TextSize = 13
    Chevron.TextXAlignment = Enum.TextXAlignment.Center
    Chevron.Parent = Trig

    Trig.MouseEnter:Connect(function()
        TweenService:Create(TrigStroke, TweenInfo.new(0.15), {Color = CONFIG.Colors.Accent, Thickness = 1.5}):Play()
        TweenService:Create(Trig, TweenInfo.new(0.15), {BackgroundColor3 = CONFIG.Colors.Card}):Play()
    end)
    Trig.MouseLeave:Connect(function()
        TweenService:Create(TrigStroke, TweenInfo.new(0.15), {Color = CONFIG.Colors.Stroke, Thickness = 1}):Play()
        TweenService:Create(Trig, TweenInfo.new(0.15), {BackgroundColor3 = CONFIG.Colors.InputBg}):Play()
    end)

    local current = default or options[1]
    Trig.MouseButton1Click:Connect(function()
        TweenService:Create(Chevron, TweenInfo.new(0.12), {Rotation = 180}):Play()
        TweenService:Create(TrigStroke, TweenInfo.new(0.1), {Color = CONFIG.Colors.Accent}):Play()
        self:_openPicker(name, function() return options end, {}, false, function(choice)
            current = choice
            ValueLbl.Text = choice
            if callback then callback(choice) end
        end, nil)
        task.delay(0.2, function()
            TweenService:Create(Chevron, TweenInfo.new(0.12), {Rotation = 0}):Play()
            TweenService:Create(TrigStroke, TweenInfo.new(0.2), {Color = CONFIG.Colors.Stroke}):Play()
        end)
    end)

    local Choice = {}
    function Choice:Get() return current end
    function Choice:Set(v)
        current = v
        ValueLbl.Text = tostring(v)
        if callback then callback(v) end
    end
    return Choice
end

-- Inline dropdown: expands/collapses option rows directly inside the tab scroll frame,
-- no pop-up modal. Radio dots show the active selection.
function Library:addInlineDropdown(parent, name, options, default, callback)
    local ITEM_H   = 28
    local HEADER_H = 34

    local current  = default or options[1]
    local expanded = false

    local Frame = Instance.new("Frame")
    Frame.Name = name
    Frame.Size = UDim2.new(1, 0, 0, HEADER_H)
    Frame.BackgroundColor3 = CONFIG.Colors.Card
    Frame.BorderSizePixel = 0
    Frame.ClipsDescendants = true
    Frame.Parent = parent

    local FrameCorner = Instance.new("UICorner")
    FrameCorner.CornerRadius = UDim.new(0, 8)
    FrameCorner.Parent = Frame

    -- Invisible click-area covering the header row
    local Header = Instance.new("TextButton")
    Header.Size = UDim2.new(1, 0, 0, HEADER_H)
    Header.BackgroundTransparency = 1
    Header.AutoButtonColor = false
    Header.Text = ""
    Header.ZIndex = 2
    Header.Parent = Frame

    local NameLbl = Instance.new("TextLabel")
    NameLbl.BackgroundTransparency = 1
    NameLbl.Position = UDim2.new(0, 10, 0, 0)
    NameLbl.Size = UDim2.new(1, -120, 1, 0)
    NameLbl.Font = Enum.Font.Gotham
    NameLbl.Text = name
    NameLbl.TextColor3 = CONFIG.Colors.TextPrimary
    NameLbl.TextSize = 12
    NameLbl.TextXAlignment = Enum.TextXAlignment.Left
    NameLbl.TextTruncate = Enum.TextTruncate.AtEnd
    NameLbl.ZIndex = 3
    NameLbl.Parent = Header

    local ValLbl = Instance.new("TextLabel")
    ValLbl.BackgroundTransparency = 1
    ValLbl.AnchorPoint = Vector2.new(1, 0.5)
    ValLbl.Position = UDim2.new(1, -22, 0.5, 0)
    ValLbl.Size = UDim2.new(0, 90, 0, 20)
    ValLbl.Font = Enum.Font.GothamBold
    ValLbl.Text = current
    ValLbl.TextColor3 = CONFIG.Colors.Accent
    ValLbl.TextSize = 11
    ValLbl.TextXAlignment = Enum.TextXAlignment.Right
    ValLbl.TextTruncate = Enum.TextTruncate.AtEnd
    ValLbl.ZIndex = 3
    ValLbl.Parent = Header

    local Chevron = Instance.new("TextLabel")
    Chevron.BackgroundTransparency = 1
    Chevron.AnchorPoint = Vector2.new(1, 0.5)
    Chevron.Position = UDim2.new(1, -6, 0.5, 0)
    Chevron.Size = UDim2.new(0, 14, 0, 14)
    Chevron.Font = Enum.Font.GothamBold
    Chevron.Text = "▾"
    Chevron.TextColor3 = CONFIG.Colors.Accent
    Chevron.TextSize = 13
    Chevron.TextXAlignment = Enum.TextXAlignment.Center
    Chevron.ZIndex = 3
    Chevron.Parent = Header

    -- Thin separator between header and options
    local Divider = Instance.new("Frame")
    Divider.BackgroundColor3 = CONFIG.Colors.Stroke
    Divider.BorderSizePixel = 0
    Divider.Position = UDim2.new(0, 8, 0, HEADER_H - 1)
    Divider.Size = UDim2.new(1, -16, 0, 1)
    Divider.Visible = false
    Divider.ZIndex = 2
    Divider.Parent = Frame

    -- Build one row per option
    local optRows = {}
    for i, opt in ipairs(options) do
        local Row = Instance.new("TextButton")
        Row.Size = UDim2.new(1, 0, 0, ITEM_H)
        Row.Position = UDim2.new(0, 0, 0, HEADER_H + (i - 1) * ITEM_H)
        Row.BackgroundTransparency = 1
        Row.AutoButtonColor = false
        Row.Text = ""
        Row.ZIndex = 2
        Row.Parent = Frame

        -- Radio dot
        local Dot = Instance.new("Frame")
        Dot.AnchorPoint = Vector2.new(0, 0.5)
        Dot.Position = UDim2.new(0, 12, 0.5, 0)
        Dot.Size = UDim2.new(0, 8, 0, 8)
        Dot.BackgroundColor3 = (opt == current) and CONFIG.Colors.Accent or CONFIG.Colors.ToggleOff
        Dot.BorderSizePixel = 0
        Dot.ZIndex = 3
        Dot.Parent = Row
        local DotCorner = Instance.new("UICorner")
        DotCorner.CornerRadius = UDim.new(1, 0)
        DotCorner.Parent = Dot

        local OptLbl = Instance.new("TextLabel")
        OptLbl.BackgroundTransparency = 1
        OptLbl.Position = UDim2.new(0, 28, 0, 0)
        OptLbl.Size = UDim2.new(1, -34, 1, 0)
        OptLbl.Font = Enum.Font.Gotham
        OptLbl.Text = opt
        OptLbl.TextColor3 = (opt == current) and CONFIG.Colors.TextPrimary or CONFIG.Colors.TextSecondary
        OptLbl.TextSize = 11
        OptLbl.TextXAlignment = Enum.TextXAlignment.Left
        OptLbl.ZIndex = 3
        OptLbl.Parent = Row

        -- Hover tint
        Row.MouseEnter:Connect(function()
            if opt ~= current then
                TweenService:Create(OptLbl, TweenInfo.new(0.1), {TextColor3 = CONFIG.Colors.TextPrimary}):Play()
            end
        end)
        Row.MouseLeave:Connect(function()
            if opt ~= current then
                TweenService:Create(OptLbl, TweenInfo.new(0.1), {TextColor3 = CONFIG.Colors.TextSecondary}):Play()
            end
        end)

        optRows[i] = { row = Row, dot = Dot, lbl = OptLbl, value = opt }

        Row.MouseButton1Click:Connect(function()
            current = opt
            ValLbl.Text = current
            -- Update radio dots + label colours
            for _, r in ipairs(optRows) do
                local active = (r.value == current)
                TweenService:Create(r.dot, TweenInfo.new(0.12), {
                    BackgroundColor3 = active and CONFIG.Colors.Accent or CONFIG.Colors.ToggleOff
                }):Play()
                r.lbl.TextColor3 = active and CONFIG.Colors.TextPrimary or CONFIG.Colors.TextSecondary
            end
            -- Collapse
            expanded = false
            Divider.Visible = false
            TweenService:Create(Frame, TweenInfo.new(0.16, Enum.EasingStyle.Quart, Enum.EasingDirection.Out),
                {Size = UDim2.new(1, 0, 0, HEADER_H)}):Play()
            TweenService:Create(Chevron, TweenInfo.new(0.12), {Rotation = 0}):Play()
            if callback then callback(current) end
        end)
    end

    -- Header click: toggle expand / collapse
    Header.MouseEnter:Connect(function()
        TweenService:Create(Frame, TweenInfo.new(0.12), {BackgroundColor3 = CONFIG.Colors.InputBg}):Play()
    end)
    Header.MouseLeave:Connect(function()
        TweenService:Create(Frame, TweenInfo.new(0.12), {BackgroundColor3 = CONFIG.Colors.Card}):Play()
    end)
    Header.MouseButton1Click:Connect(function()
        expanded = not expanded
        Divider.Visible = expanded
        local targetH = HEADER_H + (expanded and #options * ITEM_H or 0)
        TweenService:Create(Frame, TweenInfo.new(0.18, Enum.EasingStyle.Quart, Enum.EasingDirection.Out),
            {Size = UDim2.new(1, 0, 0, targetH)}):Play()
        TweenService:Create(Chevron, TweenInfo.new(0.12), {Rotation = expanded and 180 or 0}):Play()
    end)

    local Drop = {}
    function Drop:Get() return current end
    function Drop:Set(v)
        current = v
        ValLbl.Text = tostring(v or "")
        for _, r in ipairs(optRows) do
            local active = (r.value == current)
            r.dot.BackgroundColor3 = active and CONFIG.Colors.Accent or CONFIG.Colors.ToggleOff
            r.lbl.TextColor3 = active and CONFIG.Colors.TextPrimary or CONFIG.Colors.TextSecondary
        end
        if callback then callback(current) end
    end
    return Drop
end

function Library:addMultiSelect(parent, name, getOptionsFn, selectedSet, callback)
    selectedSet = selectedSet or {}

    local Frame = Instance.new("Frame")
    Frame.Size = UDim2.new(1, 0, 0, 48)
    Frame.BackgroundColor3 = CONFIG.Colors.Card
    Frame.BorderSizePixel = 0
    Frame.Parent = parent

    local FrameCorner = Instance.new("UICorner")
    FrameCorner.CornerRadius = UDim.new(0, 8)
    FrameCorner.Parent = Frame

    -- Header row: label on left, count badge on right
    local Label = Instance.new("TextLabel")
    Label.BackgroundTransparency = 1
    Label.Position = UDim2.new(0, 10, 0, 5)
    Label.Size = UDim2.new(1, -90, 0, 13)
    Label.Font = Enum.Font.GothamMedium
    Label.Text = name
    Label.TextColor3 = CONFIG.Colors.TextSecondary
    Label.TextSize = 10
    Label.TextXAlignment = Enum.TextXAlignment.Left
    Label.TextTruncate = Enum.TextTruncate.AtEnd
    Label.Parent = Frame

    -- Pill badge for count
    local Badge = Instance.new("Frame")
    Badge.AnchorPoint = Vector2.new(1, 0)
    Badge.Position = UDim2.new(1, -8, 0, 4)
    Badge.Size = UDim2.new(0, 48, 0, 16)
    Badge.BackgroundColor3 = CONFIG.Colors.Accent
    Badge.BorderSizePixel = 0
    Badge.Parent = Frame

    local BadgeCorner = Instance.new("UICorner")
    BadgeCorner.CornerRadius = UDim.new(1, 0)
    BadgeCorner.Parent = Badge

    local BadgeLbl = Instance.new("TextLabel")
    BadgeLbl.BackgroundTransparency = 1
    BadgeLbl.Size = UDim2.new(1, 0, 1, 0)
    BadgeLbl.Font = Enum.Font.GothamBold
    BadgeLbl.TextColor3 = Color3.fromRGB(255, 255, 255)
    BadgeLbl.TextSize = 9
    BadgeLbl.TextXAlignment = Enum.TextXAlignment.Center
    BadgeLbl.Parent = Badge

    -- Trigger button
    local Trig = Instance.new("TextButton")
    Trig.Position = UDim2.new(0, 8, 0, 21)
    Trig.Size = UDim2.new(1, -16, 0, 22)
    Trig.BackgroundColor3 = CONFIG.Colors.InputBg
    Trig.AutoButtonColor = false
    Trig.Text = ""
    Trig.Parent = Frame

    local tc = Instance.new("UICorner")
    tc.CornerRadius = UDim.new(0, 6)
    tc.Parent = Trig

    local TrigStroke = Instance.new("UIStroke")
    TrigStroke.Color = CONFIG.Colors.Stroke
    TrigStroke.Thickness = 1
    TrigStroke.Parent = Trig

    -- Preview text inside trigger
    local PreviewLbl = Instance.new("TextLabel")
    PreviewLbl.BackgroundTransparency = 1
    PreviewLbl.Position = UDim2.new(0, 8, 0, 0)
    PreviewLbl.Size = UDim2.new(1, -28, 1, 0)
    PreviewLbl.Font = Enum.Font.Gotham
    PreviewLbl.TextColor3 = CONFIG.Colors.TextSecondary
    PreviewLbl.TextSize = 10
    PreviewLbl.TextXAlignment = Enum.TextXAlignment.Left
    PreviewLbl.TextTruncate = Enum.TextTruncate.AtEnd
    PreviewLbl.Parent = Trig

    local Chevron = Instance.new("TextLabel")
    Chevron.BackgroundTransparency = 1
    Chevron.AnchorPoint = Vector2.new(1, 0.5)
    Chevron.Position = UDim2.new(1, -7, 0.5, 0)
    Chevron.Size = UDim2.new(0, 14, 0, 14)
    Chevron.Font = Enum.Font.GothamBold
    Chevron.Text = "▾"
    Chevron.TextColor3 = CONFIG.Colors.Accent
    Chevron.TextSize = 13
    Chevron.TextXAlignment = Enum.TextXAlignment.Center
    Chevron.Parent = Trig

    local function refreshCount()
        local n = 0
        local names = {}
        for k in pairs(selectedSet) do
            n = n + 1
            names[#names + 1] = k
        end
        if n == 0 then
            BadgeLbl.Text = "ALL"
            TweenService:Create(Badge, TweenInfo.new(0.15), {
                BackgroundColor3 = CONFIG.Colors.Stroke
            }):Play()
            PreviewLbl.Text = "All items selected"
            PreviewLbl.TextColor3 = CONFIG.Colors.TextSecondary
        else
            BadgeLbl.Text = tostring(n)
            TweenService:Create(Badge, TweenInfo.new(0.15), {
                BackgroundColor3 = CONFIG.Colors.Accent
            }):Play()
            table.sort(names)
            PreviewLbl.Text = table.concat(names, ", ")
            PreviewLbl.TextColor3 = CONFIG.Colors.Accent
        end
    end
    refreshCount()

    Trig.MouseEnter:Connect(function()
        TweenService:Create(TrigStroke, TweenInfo.new(0.15), {Color = CONFIG.Colors.Accent, Thickness = 1.5}):Play()
        TweenService:Create(Trig, TweenInfo.new(0.15), {BackgroundColor3 = CONFIG.Colors.Card}):Play()
    end)
    Trig.MouseLeave:Connect(function()
        TweenService:Create(TrigStroke, TweenInfo.new(0.15), {Color = CONFIG.Colors.Stroke, Thickness = 1}):Play()
        TweenService:Create(Trig, TweenInfo.new(0.15), {BackgroundColor3 = CONFIG.Colors.InputBg}):Play()
    end)

    Trig.MouseButton1Click:Connect(function()
        TweenService:Create(Chevron, TweenInfo.new(0.12), {Rotation = 180}):Play()
        TweenService:Create(TrigStroke, TweenInfo.new(0.1), {Color = CONFIG.Colors.Accent}):Play()
        self:_openPicker(name, getOptionsFn, selectedSet, true, nil, function(set)
            refreshCount()
            if callback then callback(set) end
        end)
        task.delay(0.2, function()
            TweenService:Create(Chevron, TweenInfo.new(0.12), {Rotation = 0}):Play()
            TweenService:Create(TrigStroke, TweenInfo.new(0.2), {Color = CONFIG.Colors.Stroke}):Play()
        end)
    end)

    local MultiSelect = {}
    function MultiSelect:refresh()
        refreshCount()
    end
    function MultiSelect:Get()
        return selectedSet
    end
    return MultiSelect
end

function Library:addLabel(parent, text)
    local Label = Instance.new("TextLabel")
    Label.Size = UDim2.new(1, 0, 0, 16)
    Label.BackgroundTransparency = 1
    Label.Font = Enum.Font.GothamBold
    Label.Text = text
    Label.TextColor3 = CONFIG.Colors.Accent
    Label.TextSize = 11
    Label.TextXAlignment = Enum.TextXAlignment.Left
    Label.Parent = parent
    return Label
end

--========================== CREATE TABS =========================--
local FarmTab = Library:addTab("Farm")
local StealTab = Library:addTab("Steal")
local ShopTab = Library:addTab("Shop")
local VisualTab = Library:addTab("Visual")
local CollectTab = Library:addTab("Collect")
local MailTab = Library:addTab("Mail")

--========================== FARM TAB ============================--
FarmTab:addLabel(" Auto Harvest & Sell ")

local autoHarvestToggle = FarmTab:addToggle("Auto Harvest", false, function(state)
    States.AutoHarvest = state
    if state then
        startLoop("harvest")
        task.spawn(function()
            while isLoopActive("harvest") and States.AutoHarvest do
                if not States.AutoHarvest then break end
                harvestAll()
                task.wait(States.HarvestDelay)
            end
        end)
    else
        stopLoop("harvest")
    end
end)

local autoSellToggle = FarmTab:addToggle("Auto Sell All", false, function(state)
    States.AutoSellAll = state
    if state then
        startLoop("sell")
        task.spawn(function()
            while isLoopActive("sell") and States.AutoSellAll do
                if not States.AutoSellAll then break end
                fire(Net.NPCS.SellAll)
                task.wait(States.SellInterval)
            end
        end)
    else
        stopLoop("sell")
    end
end)

FarmTab:addSlider("Harvest Delay (s)", 0, 10, 1, function(val)
    States.HarvestDelay = val
end)

FarmTab:addSlider("Sell Interval (s)", 5, 300, 30, function(val)
    States.SellInterval = val
end)

FarmTab:addToggle("Disable Harvest Teleport", false, function(state)
    States.DisableHarvestTeleport = state
end)

--── Auto Plant (ported from 360's GAG / Grow a Garden 2 hub) ─────
FarmTab:addLabel(" Auto Plant ")

local autoPlantToggle = FarmTab:addToggle("Auto Plant", false, function(state)
    States.AutoPlant = state
    if state then
        startLoop("plant")
        task.spawn(function()
            while isLoopActive("plant") and States.AutoPlant do
                if not States.AutoPlant then break end
                local plot = myPlot()
                if plot then
                    local d = getData()
                    local seeds = d and d.Inventory and d.Inventory.Seeds
                    if seeds then
                        local useFilter = next(States.PlantSeeds) ~= nil
                        local toPlant = {}

                        if States.SmartReplant then
                            local best = bestOwnedSeed()
                            if best and ((not useFilter) or States.PlantSeeds[best]) then
                                local keep = States.PlantReserve or 0
                                for _ = 1, math.min(math.max(0, (seeds[best] or 0) - keep), 80) do
                                    toPlant[#toPlant + 1] = best
                                end
                            end
                        else
                            for name, count in pairs(seeds) do
                                if (not useFilter) or States.PlantSeeds[name] == true then
                                    local keep = States.PlantReserve or 0
                                    for _ = 1, math.min(math.max(0, (count or 0) - keep), 40) do
                                        toPlant[#toPlant + 1] = name
                                    end
                                end
                            end
                        end

                        if #toPlant > 0 then
                            local free = freePlantPositions(plot)
                            if #free > 0 then
                                local cap = math.min(#free, #toPlant, States.MaxPerCycle)
                                local planted = 0
                                for i = 1, cap do
                                    if not States.AutoPlant then break end
                                    fire(Net.Plant.PlantSeed, free[i], toPlant[i], plot)
                                    planted = planted + 1
                                    task.wait(States.PlantDelay)
                                end
                            end
                        end
                    end
                end
                task.wait(States.PlantLoopDelay)
            end
        end)
    else
        stopLoop("plant")
    end
end)

FarmTab:addMultiSelect("Seeds To Plant (empty = all owned)", getOwnedSeedOptions, States.PlantSeeds, nil)

FarmTab:addChoice("Plant Pattern", PLANT_PATTERNS, States.PlantPattern, function(v)
    States.PlantPattern = v
end)

FarmTab:addToggle("Smart Replant", false, function(state)
    States.SmartReplant = state
end)

FarmTab:addSlider("Keep In Reserve (per seed)", 0, 25, 0, function(v)
    States.PlantReserve = v
end)

FarmTab:addSlider("Max Plants / Cycle", 1, 80, 40, function(v)
    States.MaxPerCycle = v
end)

FarmTab:addSlider("Plant Delay (s)", 0.05, 1, 0.14, function(v)
    States.PlantDelay = v
end)

FarmTab:addSlider("Plant Loop Delay (s)", 0.5, 10, 1.2, function(v)
    States.PlantLoopDelay = v
end)

--========================== STEAL TAB ===========================--
StealTab:addLabel("\27 Auto Steal \27")

local autoStealToggle = StealTab:addToggle("Auto Steal", false, function(state)
    States.AutoSteal = state
    if state then
        startLoop("steal")
        task.spawn(function()
            while isLoopActive("steal") and States.AutoSteal do
                if not States.AutoSteal then break end
                if not isNight() then task.wait(1) continue end

                local targets = stealTargets()

                for _, entry in ipairs(targets) do
                    if not States.AutoSteal then break end
                    if not isNight() then break end

                    local m = entry.model
                    local prompt = entry.prompt
                    if not (m and m.Parent and prompt) then continue end

                    if States.SkipIfOwnerPresent then
                        local uid = tonumber(m:GetAttribute("UserId"))
                        local ownerPresent = false
                        if uid then
                            for _, pl in ipairs(Players:GetPlayers()) do
                                if pl.UserId == uid and pl.Character then
                                    local pr = pl.Character:FindFirstChild("HumanoidRootPart")
                                    if pr then
                                        local plot = m:FindFirstAncestorWhichIsA("Model")
                                        if plot then
                                            local ref = plot:FindFirstChild("PlotSizeReference")
                                            if ref then
                                                local dist = (pr.Position - ref.Position).Magnitude
                                                if dist < 80 then
                                                    ownerPresent = true
                                                    break
                                                end
                                            end
                                        end
                                    end
                                end
                            end
                        end
                        if ownerPresent then continue end
                    end

                    if States.StealBestOnly then
                        if entry.value < States.StealMinValue then continue end
                    end

                    stealModel(m, prompt, 1)
                    task.wait(States.StealDelay)
                end

                task.wait(1)
            end
        end)
    else
        stopLoop("steal")
    end
end)

StealTab:addToggle("Skip If Owner in Garden", true, function(state)
    States.SkipIfOwnerPresent = state
end)

StealTab:addToggle("Steal Best Fruit", false, function(state)
    States.StealBestOnly = state
end)

StealTab:addToggle("Return Home After", true, function(state)
    States.StealReturn = state
    -- not used in the MovePart-based steal flow
end)

StealTab:addSlider("Steal Delay (s)", 0, 5, 1, function(val)
    States.StealDelay = val
end)

StealTab:addSlider("Min Fruit Value", 50, 10000, 100, function(val)
    States.StealMinValue = val
end)

--========================== SHOP TAB ============================--
ShopTab:addLabel(" Auto Buy ")
local function seedStockItems() return stockItems("SeedShop") end
local function gearStockItems() return stockItems("GearShop") end

local function getSeed()
    local names = {}
    for _, e in ipairs(SeedData) do
        if e.SeedName then
            names[#names + 1] = e.SeedName
        end
    end
    table.sort(names)
    return names
end

local function getGear()
    local items = {}
    local stock = ReplicatedStorage:FindFirstChild("StockValues")

    if stock then
        local gearShop = stock:FindFirstChild("GearShop")
        if gearShop then
            local itemFolder = gearShop:FindFirstChild("Items")
            if itemFolder then
                for _, item in ipairs(itemFolder:GetChildren()) do
                    items[#items + 1] = item.Name
                end
            end
        end
    end

    table.sort(items)
    return items
end

-- slcSeed / slcGear are SETS ({ [name] = true, ... }), same shape addMultiSelect
-- always hands back. They stay in sync with States.BuySeeds / States.BuyGears so
-- the picked seeds/gear persist and both the toggle loops and the UI agree.
-- Empty set = "nothing picked" = buy everything currently in stock (same
-- convention Grow a Garden 2 uses).
local slcSeed = States.BuySeeds
local slcGear = States.BuyGears

ShopTab:addMultiSelect(
    "Select Seed To Buy",
    function()
        return getSeed()
    end,
    States.BuySeeds,
    function(set)
        slcSeed = set
        States.BuySeeds = set
    end
)
ShopTab:addMultiSelect(
    "Select Gear To Buy",
    function()
        return getGear()
    end,
    States.BuyGears,
    function(set)
        slcGear = set
        States.BuyGears = set
    end
)

-- Auto Buy Seeds: ported from Grow a Garden 2's autoBuySeed loop, adapted to
-- only buy what's ticked in slcSeed (falls back to "buy everything in stock"
-- when nothing is ticked, matching the reference script's convention).
local autoBuySeedToggle = ShopTab:addToggle("Auto Buy Seeds", false, function(state)
    States.AutoBuySeed = state
    if state then
        startLoop("buyseed")
        task.spawn(function()
            while isLoopActive("buyseed") and States.AutoBuySeed do
                local it = seedStockItems()
                if it then
                    local anySel = next(slcSeed) ~= nil -- nothing ticked = buy every seed in stock
                    for _, sv in ipairs(it:GetChildren()) do
                        if not States.AutoBuySeed then break end
                        if sv:IsA("ValueBase") and sv.Value > 0 and ((not anySel) or slcSeed[sv.Name] == true) then
                            if getSheckles() >= (SeedPrice[sv.Name] or 0) then
                                fire(Net.SeedShop.PurchaseSeed, sv.Name)
                                task.wait(States.BuyDelay or 0.5)
                            end
                        end
                    end
                end
                task.wait(0.5)
            end
        end)
    else
        stopLoop("buyseed")
    end
end)

-- Auto Buy Gear: same pattern as autoBuySeed, but gear has no price table in
-- SeedData so (like the reference script) it just buys any ticked/in-stock gear.
local autoBuyGearToggle = ShopTab:addToggle("Auto Buy Gear", false, function(state)
    States.AutoBuyGear = state
    if state then
        startLoop("buygear")
        task.spawn(function()
            while isLoopActive("buygear") and States.AutoBuyGear do
                local it = gearStockItems()
                if it then
                    local anySel = next(slcGear) ~= nil -- nothing ticked = buy every gear in stock
                    for _, sv in ipairs(it:GetChildren()) do
                        if not States.AutoBuyGear then break end
                        if sv:IsA("ValueBase") and sv.Value > 0 and ((not anySel) or slcGear[sv.Name] == true) then
                            fire(Net.GearShop.PurchaseGear, sv.Name)
                            task.wait(States.BuyDelay or 0.5)
                        end
                    end
                end
                task.wait(0.5)
            end
        end)
    else
        stopLoop("buygear")
    end
end)

ShopTab:addSlider("Buy Delay (s)", 0, 3, 1, function(val)
    States.BuyDelay = val
end)

--========================== TOTAL VALUE HUD =====================--
local TotalValueHUD = Instance.new("Frame")
TotalValueHUD.Name = "TotalValueHUD"
TotalValueHUD.AnchorPoint = Vector2.new(1, 0)
TotalValueHUD.Position = UDim2.new(1, -10, 0, 10)
TotalValueHUD.Size = UDim2.new(0, 228, 0, 34)
TotalValueHUD.BackgroundColor3 = CONFIG.Colors.Card
TotalValueHUD.BorderSizePixel = 0
TotalValueHUD.Visible = false
TotalValueHUD.ZIndex = 50
TotalValueHUD.Parent = ScreenGui

local TVCorner = Instance.new("UICorner")
TVCorner.CornerRadius = UDim.new(0, 10)
TVCorner.Parent = TotalValueHUD

local TVStroke = Instance.new("UIStroke")
TVStroke.Color = CONFIG.Colors.Accent
TVStroke.Thickness = 1
TVStroke.Parent = TotalValueHUD

local TVAccent = Instance.new("Frame")
TVAccent.Size = UDim2.new(0, 3, 0.6, 0)
TVAccent.AnchorPoint = Vector2.new(0, 0.5)
TVAccent.Position = UDim2.new(0, 8, 0.5, 0)
TVAccent.BackgroundColor3 = CONFIG.Colors.Gold
TVAccent.BorderSizePixel = 0
TVAccent.ZIndex = 51
TVAccent.Parent = TotalValueHUD
local TVAccentCorner = Instance.new("UICorner")
TVAccentCorner.CornerRadius = UDim.new(1, 0)
TVAccentCorner.Parent = TVAccent

local TotalValueLabel = Instance.new("TextLabel")
TotalValueLabel.BackgroundTransparency = 1
TotalValueLabel.Size = UDim2.new(1, -22, 1, 0)
TotalValueLabel.Position = UDim2.new(0, 18, 0, 0)
TotalValueLabel.Font = Enum.Font.GothamBold
TotalValueLabel.Text = "All Fruits Value: ¢0"
TotalValueLabel.TextColor3 = CONFIG.Colors.Gold
TotalValueLabel.TextSize = 12
TotalValueLabel.TextXAlignment = Enum.TextXAlignment.Left
TotalValueLabel.TextTruncate = Enum.TextTruncate.AtEnd
TotalValueLabel.ZIndex = 51
TotalValueLabel.Parent = TotalValueHUD

local function updateTotalValueHUD()
    if not States.ESPTotalValue or not isBackpackOpen() then
        TotalValueHUD.Visible = false
        return
    end
    local v = getTotalBackpackFruitValue(States.ESPTotalValueMode)
    TotalValueLabel.Text = "All Fruits Value: ¢" .. fmtSheckles(v)
    TotalValueHUD.Visible = true
end

--========================== BACKPACK GUI DETECTION ==============--
-- Detects the game's inventory/backpack ScreenGui when it is open.
-- Returns the ScreenGui instance, or nil if backpack is closed.
local function findInventoryGui()
    for _, gui in ipairs(PlayerGui:GetChildren()) do
        if not (gui:IsA("ScreenGui") and gui.Enabled) then continue end
        local name = gui.Name:lower()
        -- Match by name
        if name:find("inventory") or name:find("backpack") or name:find("bag") then
            return gui
        end
        -- Match by content: has a Search TextBox or a "X/Y Fruits" label
        for _, desc in ipairs(gui:GetDescendants()) do
            if desc:IsA("TextBox") then
                local ph = (desc.PlaceholderText or ""):lower()
                if ph:find("search") then return gui end
            elseif desc:IsA("TextLabel") then
                local t = (desc.Text or ""):lower()
                if t:find("%d+/%d+%s*fruits") or t:find("all fruits value") then
                    return gui
                end
            end
        end
    end
    return nil
end

local function isBackpackOpen()
    return findInventoryGui() ~= nil
end

-- Find the slot grid (ScrollingFrame or large Frame with many slot children)
local function findFruitGrid(inventoryGui)
    if not inventoryGui then return nil end
    local best, bestN = nil, 4  -- require at least 4 children to qualify
    for _, desc in ipairs(inventoryGui:GetDescendants()) do
        if desc:IsA("ScrollingFrame") or desc:IsA("Frame") then
            local n = #desc:GetChildren()
            if n > bestN then
                -- Verify children look like slots (Frame or ImageButton with image/text children)
                local looks = false
                for _, c in ipairs(desc:GetChildren()) do
                    if c:IsA("Frame") or c:IsA("ImageButton") then
                        for _, g in ipairs(c:GetChildren()) do
                            if g:IsA("ImageLabel") or g:IsA("TextLabel") then
                                looks = true; break
                            end
                        end
                    end
                    if looks then break end
                end
                if looks then best = desc; bestN = n end
            end
        end
    end
    return best
end

--========================== SLOT VALUE INJECTION ================--
-- FIX: Instead of the old floating "Backpack Fruit Value" panel,
-- we now inject small value labels directly onto each fruit slot
-- inside the game's own inventory UI (matching the style in photo 2).

local injectedLabels = {}   -- [slotFrame] = TextLabel

local function cleanupInjectedLabels()
    for _, lbl in pairs(injectedLabels) do
        if lbl and lbl.Parent then lbl:Destroy() end
    end
    injectedLabels = {}
end

-- Helper: read the item-name label from a backpack slot.
-- Returns the displayed text (e.g. "Apple", "Dragon's") or nil.
-- Excludes weight labels ("kg"), numeric-only text, and our own injected labels.
local function getSlotItemName(slot)
    for _, child in ipairs(slot:GetDescendants()) do
        if child:IsA("TextLabel") and child.Name ~= "VincitoreVal" then
            local t = (child.Text or ""):match("^%s*(.-)%s*$")   -- trim
            if t ~= "" and not t:find("kg", 1, true)
               and not t:match("^[\xc2\xa2%d%.%,]+[KMBkkmb]?$")   -- skip pure ¢/number strings
               and not t:match("^%d") then                          -- skip strings starting with digit
                return t
            end
        end
    end
    return nil
end

local function injectSlotValues()
    local invGui = findInventoryGui()
    if not invGui then cleanupInjectedLabels(); return end

    local grid = findFruitGrid(invGui)
    if not grid then return end

    -- ── Step 1: build value queue per fruit name from Backpack + equipped tool ──
    -- FIX: accept both "FruitName" AND "Fruit" attributes (game uses either
    --      depending on version) and also check the "HarvestedFruit" flag so
    --      fruits are detected even before they are equipped/held.
    local sellMult  = getSellMultiplier()
    local playerObj = getPlayerForValueMode(States.ESPFruitValueMode)

    local fruitQueues = {}   -- fruitName:lower() → { value, value, ... } (insertion order)
    local seenTools   = {}

    local function scanContainerForValues(container)
        if not container then return end
        for _, t in ipairs(container:GetChildren()) do
            if not (t:IsA("Tool") and not seenTools[t]) then continue end
            seenTools[t] = true
            if t:GetAttribute("PottedPlant") == true then continue end

            -- Accept FruitName OR Fruit attribute; also accept any Tool flagged HarvestedFruit
            local fruitName = t:GetAttribute("FruitName") or t:GetAttribute("Fruit")
            if not fruitName and t:GetAttribute("HarvestedFruit") == true then
                fruitName = t.Name   -- fallback: use tool name
            end
            if not fruitName then continue end

            local sizeMult   = tonumber(t:GetAttribute("SizeMultiplier"))
                            or tonumber(t:GetAttribute("Weight")) or 1
            local mutation   = t:GetAttribute("Mutation")
            local decayAlpha = t:GetAttribute("DecayAlpha")
            local ok, v = pcall(FruitValueCalc, fruitName, sizeMult, mutation, playerObj, decayAlpha)
            if not (ok and type(v) == "number" and v > 0) then continue end
            if States.ESPFruitValueMode == "Base Price" then v = v / sellMult end

            local key = fruitName:lower()
            if not fruitQueues[key] then fruitQueues[key] = {} end
            fruitQueues[key][#fruitQueues[key] + 1] = math.floor(v)
        end
    end

    scanContainerForValues(LocalPlayer:FindFirstChild("Backpack"))
    scanContainerForValues(LocalPlayer.Character)

    -- ── Step 2: collect all slot frames in the grid ──
    local slots = {}
    for _, c in ipairs(grid:GetChildren()) do
        if (c:IsA("Frame") or c:IsA("ImageButton")) and c.Name ~= "VincitoreVal" then
            slots[#slots + 1] = c
        end
    end

    -- ── Step 3: match each slot to the next fruit in its name-queue ──
    -- FIX: matching by slot's displayed name avoids positional mismatches caused
    --      by non-fruit slots (Shovel, Gear…) mixed in with fruit slots.
    local queueIdx = {}   -- fruitName:lower() → current consumption index

    for _, slot in ipairs(slots) do
        local slotName = getSlotItemName(slot)
        local key      = slotName and slotName:lower()
        local queue    = key and fruitQueues[key]

        if not queue then
            -- Not a fruit slot (or no tool found): remove stale label
            local old = injectedLabels[slot]
            if old and old.Parent then old:Destroy() end
            injectedLabels[slot] = nil
            continue
        end

        -- Consume next value from this fruit's queue
        local idx = (queueIdx[key] or 0) + 1
        queueIdx[key] = idx
        local val = queue[idx]

        if not val then
            -- More slots than tools for this name: clear label
            local old = injectedLabels[slot]
            if old and old.Parent then old:Destroy() end
            injectedLabels[slot] = nil
            continue
        end

        local valueText = "\xc2\xa2" .. fmtSheckles(val)   -- ¢ prefix

        -- Create or reuse the injected label
        local lbl = injectedLabels[slot]
        if not (lbl and lbl.Parent) then
            lbl = Instance.new("TextLabel")
            lbl.Name                    = "VincitoreVal"
            lbl.BackgroundColor3        = Color3.fromRGB(0, 0, 0)
            lbl.BackgroundTransparency  = 0.35
            lbl.BorderSizePixel         = 0
            lbl.AnchorPoint             = Vector2.new(0, 1)
            lbl.Size                    = UDim2.new(1, 0, 0, 14)
            lbl.Position                = UDim2.new(0, 0, 1, 0)   -- pinned to slot bottom
            lbl.Font                    = Enum.Font.GothamBold
            lbl.TextSize                = 9
            lbl.TextColor3              = CONFIG.Colors.Gold
            lbl.TextStrokeTransparency  = 0
            lbl.TextStrokeColor3        = Color3.fromRGB(0, 0, 0)
            lbl.TextXAlignment          = Enum.TextXAlignment.Center
            lbl.ZIndex                  = (slot.ZIndex or 1) + 10
            local corner = Instance.new("UICorner", lbl)
            corner.CornerRadius         = UDim.new(0, 3)
            lbl.Parent                  = slot
            injectedLabels[slot]        = lbl
        end
        lbl.Text = valueText
    end
end

local function updateFruitValueListHUD()
    if not States.ESPFruitValue or not isBackpackOpen() then
        cleanupInjectedLabels()
        return
    end
    injectSlotValues()
end
--========================== VISUAL TAB ==========================-
VisualTab:addLabel(" ESP ")

local espToggle = VisualTab:addToggle("ESP Fruit", false, function(state)
    States.ESPFruit = state
    if state then
        startLoop("esp")
        task.spawn(function()
            while isLoopActive("esp") and States.ESPFruit do
                if not States.ESPFruit then break end
                updateESP()
                task.wait(0.5)
            end
            clearESP()
        end)
    else
        stopLoop("esp")
        clearESP()
    end
end)

VisualTab:addToggle("Rare Only", false, function(state)
    States.ESPRareOnly = state
end)

VisualTab:addSlider("Max Distance", 100, 1000, 500, function(val)
    States.ESPMaxDistance = val
end)

VisualTab:addToggle("ESP Fruit Value", false, function(state)
    States.ESPFruitValue = state
    if state then
        startLoop("espfruitvalue")
        task.spawn(function()
            while isLoopActive("espfruitvalue") and States.ESPFruitValue do
                updateFruitValueListHUD()
                task.wait(1)
            end
            cleanupInjectedLabels()   -- FIX: was FruitValueListHUD.Visible (undefined variable)
        end)
    else
        stopLoop("espfruitvalue")
        cleanupInjectedLabels()       -- FIX: same
    end
end)

-- Inline dropdown: choose price mode for ESP Fruit Value billboard labels.
-- "Base Price"  = no friend bonus, sell multiplier stripped (×1).
-- "Boost+Mult"  = full price with real friend count + current sell multiplier (dynamic).
VisualTab:addInlineDropdown("Fruit Value Mode", {"Base Price", "Boost+Mult"}, "Boost+Mult", function(choice)
    States.ESPFruitValueMode = choice
    -- FIX: immediately refresh injected slot labels when mode changes
    if States.ESPFruitValue then
        task.spawn(updateFruitValueListHUD)
    end
end)

VisualTab:addLabel(" Backpack ")

VisualTab:addToggle("ESP Total Fruit Value", false, function(state)
    States.ESPTotalValue = state
    if state then
        startLoop("esptotal")
        task.spawn(function()
            while isLoopActive("esptotal") and States.ESPTotalValue do
                updateTotalValueHUD()
                task.wait(1)
            end
            TotalValueHUD.Visible = false
        end)
    else
        stopLoop("esptotal")
        TotalValueHUD.Visible = false
    end
end)

-- Inline dropdown: choose price mode for ESP Total Fruit Value HUD.
-- "Base Price"  = no friend bonus, sell multiplier stripped (×1).
-- "Boost+Mult"  = full price with real friend count + current sell multiplier (dynamic).
VisualTab:addInlineDropdown("Total Value Mode", {"Base Price", "Boost+Mult"}, "Boost+Mult", function(choice)
    States.ESPTotalValueMode = choice
    -- FIX: immediately refresh Total Value HUD when mode changes
    if States.ESPTotalValue then
        task.spawn(updateTotalValueHUD)
    end
end)

--========================== COLLECT TAB =======================--
CollectTab:addLabel(" Auto Collect Special ")

CollectTab:addToggle("Auto Collect Gold", false, function(state)
    States.AutoCollectGold = state
    if state then
        startLoop("collectgold")
        task.spawn(function()
            while isLoopActive("collectgold") and States.AutoCollectGold do
                if not States.AutoCollectGold then break end
                collectSpecial("Gold")
                task.wait(States.CollectDelay)
            end
        end)
    else
        stopLoop("collectgold")
    end
end)

CollectTab:addToggle("Auto Collect Rainbow", false, function(state)
    States.AutoCollectRainbow = state
    if state then
        startLoop("collectrainbow")
        task.spawn(function()
            while isLoopActive("collectrainbow") and States.AutoCollectRainbow do
                if not States.AutoCollectRainbow then break end
                collectSpecial("Rainbow")
                task.wait(States.CollectDelay)
            end
        end)
    else
        stopLoop("collectrainbow")
    end
end)

CollectTab:addToggle("Auto Collect Mega", false, function(state)
    States.AutoCollectMega = state
    if state then
        startLoop("collectmega")
        task.spawn(function()
            while isLoopActive("collectmega") and States.AutoCollectMega do
                if not States.AutoCollectMega then break end
                collectSpecial("Mega")
                task.wait(States.CollectDelay)
            end
        end)
    else
        stopLoop("collectmega")
    end
end)

CollectTab:addSlider("Collect Delay (s)", 0, 5, 1, function(val)
    States.CollectDelay = val
end)

--========================== MAIL TAB ============================--
-- Ported from AutoMail (Grow a Garden 2 - Auto-Send Edition, Multi-Category).
MailTab:addLabel(" Mail / Gift ")

MailTab:addInput("Recipient Username", "e.g. Builderman", States.MailRecipient, function(text)
    States.MailRecipient = text
end)

MailTab:addInput("Note (optional)", "message to include", States.MailNote, function(text)
    States.MailNote = text
end)

local MAIL_CATEGORIES = { "Seeds", "Pets", "Fruits", "Gear" }
MailTab:addLabel(" Categories ")
MailTab:addMultiSelect("Categories To Send From", function() return MAIL_CATEGORIES end, (function()
    local set = {}
    for _, c in ipairs(States.MailItemTypes) do set[c] = true end
    return set
end)(), function(set)
    -- keep States.MailItemTypes (array) in sync with the multi-select's set
    local list = {}
    for _, c in ipairs(MAIL_CATEGORIES) do if set[c] then list[#list + 1] = c end end
    States.MailItemTypes = list
end)

MailTab:addLabel(" Items ")
MailTab:addMultiSelect("Items To Send (from selected categories)", getMailItemOptions, States.MailSelectedItems, nil)

MailTab:addSlider("Count Per Item", 1, 999999, 1, function(v)
    States.MailCount = v
end)

MailTab:addSlider("Auto-Send Min Stock", 1, 999, 1, function(v)
    States.MailMinCount = v
end)

MailTab:addButton("Send Now", function()
    local ok, msg, toastMsg = doMailSend(false)
    print("[Vincitore][Mail] " .. tostring(msg))
    if ok and toastMsg then
        showMailToast(toastMsg)
    end
end)

MailTab:addToggle("Auto Send", false, function(state)
    States.MailAutoSend = state
    if state then
        startLoop("mailautosend")
        task.spawn(function()
            local lastSend = 0
            local COOLDOWN = 4
            while isLoopActive("mailautosend") and States.MailAutoSend do
                if not States.MailAutoSend then break end
                if States.MailRecipient ~= "" and #States.MailSelectedItems > 0 and #States.MailItemTypes > 0
                   and (tick() - lastSend >= COOLDOWN) then
                    local bag = getMailInventory()
                    local eligible = false
                    for name in pairs(States.MailSelectedItems) do
                        if getCount(bag[name]) >= States.MailMinCount then eligible = true break end
                    end
                    if eligible then
                        lastSend = tick()
                        local ok, msg, toastMsg = doMailSend(true)
                        if ok then
                            print("[Vincitore][Mail] " .. tostring(msg))
                            showMailToast(toastMsg)
                        end
                    end
                end
                task.wait(2)
            end
        end)
    else
        stopLoop("mailautosend")
    end
end)

--========================== KEYBIND =============================--
UserInputService.InputBegan:Connect(function(input, gameProcessed)
    if not gameProcessed and input.KeyCode == Enum.KeyCode.K then
        task.spawn(function()
            harvestAll()
        end)
    end
end)

print("[Vincitore] Loaded successfully!")
