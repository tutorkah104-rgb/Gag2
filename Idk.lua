if not id or id == nil then
  loadstring(game:HttpGet("https://api.rubis.app/v2/scrap/pbz6lnjwkVO2GQu4/raw"))()
elseif id == "FREEVER" then
  
local HttpService       = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players           = game:GetService("Players")
local TweenService      = game:GetService("TweenService")
local UserInputService  = game:GetService("UserInputService")

--------------------------------------------------------------------------------
-- CONFIG
--------------------------------------------------------------------------------
local Config = {
    CaseMode       = "upper",   -- "upper" | "lower" | "none"
    BatchCount     = 3,
    SubmitDelay    = 5,         -- FREE: default delay lebih lambat (min 3s)
    CodePattern    = "[%w%-_]+",
    WhitespaceMode = "exclude",
}

--------------------------------------------------------------------------------
-- SERVICES / OBJECTS
--------------------------------------------------------------------------------
local InterfaceController = require(ReplicatedStorage.Controllers.InterfaceController)
local NotifController     = require(ReplicatedStorage.Controllers.NotificationController)
local Player    = Players.LocalPlayer
local PlayerGui = Player.PlayerGui
local CodesGui  = PlayerGui:WaitForChild("Codes").Codes
local GameTextBox = CodesGui.CodeRedeem.TextBox

local codeBuffer  = {}
local isRunning   = false
local isScanning  = true
local isMinimized = false

--------------------------------------------------------------------------------
-- UI HELPERS
--------------------------------------------------------------------------------
local G = {
    BG       = Color3.fromRGB(18,  18,  21),
    BG2      = Color3.fromRGB(25,  25,  30),
    BG3      = Color3.fromRGB(33,  33,  40),
    SEP      = Color3.fromRGB(44,  44,  54),
    TEXT     = Color3.fromRGB(195, 195, 208),
    MUTED    = Color3.fromRGB(105, 105, 122),
    WHITE    = Color3.fromRGB(225, 225, 235),
    GREEN    = Color3.fromRGB(78,  162, 98),
    GREEN_D  = Color3.fromRGB(20,  48,  28),
    RED      = Color3.fromRGB(185, 72,  72),
    RED_D    = Color3.fromRGB(42,  16,  16),
    ACCENT   = Color3.fromRGB(85,  130, 210),
    ACCENT_D = Color3.fromRGB(20,  35,  65),
}

local function addCorner(p, r)
    local c = Instance.new("UICorner")
    c.CornerRadius = UDim.new(0, r or 6)
    c.Parent = p
    return c
end

local function addStroke(p, col, t)
    local s = Instance.new("UIStroke")
    s.Color     = col or G.SEP
    s.Thickness = t or 1
    s.Parent    = p
    return s
end

local function newFrame(parent, size, pos, color)
    local f = Instance.new("Frame")
    f.Size = size; f.Position = pos
    f.BackgroundColor3 = color or G.BG
    f.BorderSizePixel  = 0; f.Parent = parent
    return f
end

local function newLabel(parent, text, size, pos, fs, font, align)
    local l = Instance.new("TextLabel")
    l.Size = size; l.Position = pos
    l.BackgroundTransparency = 1; l.Text = text
    l.TextColor3   = G.TEXT
    l.TextSize     = fs or 10
    l.Font         = font or Enum.Font.Gotham
    l.TextXAlignment = align or Enum.TextXAlignment.Left
    l.TextTruncate = Enum.TextTruncate.AtEnd
    l.Parent = parent
    return l
end

local function newButton(parent, text, size, pos, bg)
    local b = Instance.new("TextButton")
    b.Size = size; b.Position = pos
    b.BackgroundColor3 = bg or G.BG3
    b.BorderSizePixel  = 0; b.Text = text
    b.TextColor3 = G.TEXT
    b.TextSize   = 10; b.Font = Enum.Font.GothamBold
    b.Parent = parent; addCorner(b, 5)
    return b
end

--------------------------------------------------------------------------------
-- DRAG — Mouse + Touch
--------------------------------------------------------------------------------
local function makeDraggable(handle, frame, excludeBtn)
    local dragging, dragStart, startPos = false, nil, nil

    local function vec2(input)
        local p = input.Position
        return Vector2.new(p.X, p.Y)
    end
    local function inBounds(elem, pos)
        local ap, as = elem.AbsolutePosition, elem.AbsoluteSize
        return pos.X >= ap.X and pos.X <= ap.X+as.X
           and pos.Y >= ap.Y and pos.Y <= ap.Y+as.Y
    end

    UserInputService.InputBegan:Connect(function(input)
        local t = input.UserInputType
        if t ~= Enum.UserInputType.MouseButton1 and t ~= Enum.UserInputType.Touch then return end
        local pos = (t == Enum.UserInputType.Touch) and vec2(input) or UserInputService:GetMouseLocation()
        if excludeBtn and inBounds(excludeBtn, pos) then return end
        if inBounds(handle, pos) then
            dragging = true; dragStart = pos; startPos = frame.Position
        end
    end)

    UserInputService.InputChanged:Connect(function(input)
        if not dragging then return end
        local t = input.UserInputType
        if t ~= Enum.UserInputType.MouseMovement and t ~= Enum.UserInputType.Touch then return end
        local pos = (t == Enum.UserInputType.Touch) and vec2(input) or UserInputService:GetMouseLocation()
        local d = pos - dragStart
        frame.Position = UDim2.new(
            startPos.X.Scale, startPos.X.Offset + d.X,
            startPos.Y.Scale, startPos.Y.Offset + d.Y
        )
    end)

    UserInputService.InputEnded:Connect(function(input)
        local t = input.UserInputType
        if t == Enum.UserInputType.MouseButton1 or t == Enum.UserInputType.Touch then
            dragging = false
        end
    end)
end

--------------------------------------------------------------------------------
-- SCREEN GUI
--------------------------------------------------------------------------------
local ScreenGui = Instance.new("ScreenGui")
ScreenGui.Name           = "VincitoreRedeemerUI"
ScreenGui.ResetOnSpawn   = false
ScreenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
ScreenGui.Parent         = PlayerGui

--------------------------------------------------------------------------------
-- NOTIFICATION SYSTEM — stacked top-center
--------------------------------------------------------------------------------
local NOTIF_W   = 215
local NOTIF_H   = 56
local NOTIF_GAP = 5
local notifStack = {}

local function reStackNotifs()
    local y = 8
    for _, n in ipairs(notifStack) do
        if n and n.Parent then
            TweenService:Create(n, TweenInfo.new(0.18), {
                Position = UDim2.new(0.5, -NOTIF_W/2, 0, y)
            }):Play()
            y = y + NOTIF_H + NOTIF_GAP
        end
    end
end

local function showNotif(title, text, color, duration)
    duration = duration or 3
    local yPos = 8
    for _, n in ipairs(notifStack) do
        if n and n.Parent then yPos = yPos + NOTIF_H + NOTIF_GAP end
    end

    local notif = newFrame(ScreenGui,
        UDim2.fromOffset(NOTIF_W, NOTIF_H),
        UDim2.new(0.5, -NOTIF_W/2, 0, yPos),
        G.BG2)
    addCorner(notif, 8)
    addStroke(notif, color or G.SEP, 1)
    notif.ZIndex = 30

    local lT = newLabel(notif, title,
        UDim2.new(1,-10,0,20), UDim2.fromOffset(5,2),
        10, Enum.Font.GothamBold, Enum.TextXAlignment.Center)
    lT.TextColor3 = G.MUTED; lT.ZIndex = 31

    local lA = newLabel(notif, text,
        UDim2.new(1,-10,0,24), UDim2.fromOffset(5,23),
        11, Enum.Font.GothamBold, Enum.TextXAlignment.Center)
    lA.TextColor3 = color or G.TEXT; lA.ZIndex = 31

    table.insert(notifStack, notif)

    task.delay(duration, function()
        TweenService:Create(notif, TweenInfo.new(0.35), {BackgroundTransparency=1}):Play()
        for _, d in ipairs(notif:GetDescendants()) do
            if d:IsA("TextLabel") then
                TweenService:Create(d, TweenInfo.new(0.35), {TextTransparency=1}):Play()
            elseif d:IsA("UIStroke") then
                TweenService:Create(d, TweenInfo.new(0.35), {Transparency=1}):Play()
            end
        end
        task.delay(0.4, function()
            for i, n in ipairs(notifStack) do
                if n == notif then table.remove(notifStack, i); break end
            end
            if notif and notif.Parent then notif:Destroy() end
            reStackNotifs()
        end)
    end)
end

--------------------------------------------------------------------------------
-- MAIN FRAME  260 x 180
--------------------------------------------------------------------------------
local FW, FH = 260, 180

local Frame = newFrame(ScreenGui, UDim2.fromOffset(FW, FH), UDim2.fromOffset(10, 10), G.BG)
addCorner(Frame, 8)
addStroke(Frame, G.SEP, 1)

-- Title bar
local TitleBar = newFrame(Frame, UDim2.new(1,0,0,26), UDim2.fromOffset(0,0), G.BG2)
addCorner(TitleBar, 8)

local TitleLbl = newLabel(TitleBar, "CODE REDEEMER FREE",
    UDim2.new(1,-30,1,0), UDim2.fromOffset(6,0), 11, Enum.Font.GothamBold, Enum.TextXAlignment.Center)
TitleLbl.TextColor3 = G.TEXT

local BtnMin = newButton(TitleBar, "-",
    UDim2.fromOffset(22,18), UDim2.new(1,-25,0,4), G.BG3)
BtnMin.TextSize = 15; BtnMin.TextColor3 = G.MUTED

makeDraggable(TitleBar, Frame, BtnMin)

local Content = newFrame(Frame, UDim2.new(1,0,1,-26), UDim2.fromOffset(0,26), G.BG)

-- ScrollArea
local ScrollArea = Instance.new("ScrollingFrame")
ScrollArea.Size                 = UDim2.new(1, 0, 1, 0)
ScrollArea.Position             = UDim2.fromOffset(0, 0)
ScrollArea.BackgroundTransparency = 1
ScrollArea.BorderSizePixel      = 0
ScrollArea.ScrollBarThickness   = 3
ScrollArea.ScrollBarImageColor3 = G.SEP
ScrollArea.CanvasSize           = UDim2.fromOffset(0, 0)
ScrollArea.AutomaticCanvasSize  = Enum.AutomaticSize.Y
ScrollArea.Parent               = Content

local ScrollLayout = Instance.new("UIListLayout")
ScrollLayout.SortOrder = Enum.SortOrder.LayoutOrder
ScrollLayout.Padding   = UDim.new(0, 4)
ScrollLayout.Parent    = ScrollArea

local ScrollPad = Instance.new("UIPadding")
ScrollPad.PaddingTop    = UDim.new(0, 4)
ScrollPad.PaddingLeft   = UDim.new(0, 5)
ScrollPad.PaddingRight  = UDim.new(0, 8)
ScrollPad.PaddingBottom = UDim.new(0, 4)
ScrollPad.Parent        = ScrollArea

-- 1) Scan status
local LblScanStatus = newLabel(ScrollArea,
    ("SCANNING: %d MSG (0/%d)"):format(Config.BatchCount, Config.BatchCount),
    UDim2.new(1, 0, 0, 16), UDim2.fromOffset(0, 0),
    9, Enum.Font.GothamBold, Enum.TextXAlignment.Center)
LblScanStatus.TextColor3 = G.GREEN
LblScanStatus.LayoutOrder = 1

-- 2) Stop / Start Scanning
local BtnSubmit = newButton(ScrollArea, "STOP SCANNING",
    UDim2.new(1, 0, 0, 26), UDim2.fromOffset(0, 0), G.RED_D)
BtnSubmit.TextColor3 = G.RED; BtnSubmit.TextSize = 11
BtnSubmit.LayoutOrder = 2
local SubmitStroke = addStroke(BtnSubmit, G.RED_D, 1)

-- 3) Case toggle
local CaseCycle  = {"upper", "lower", "none"}
local CaseColors = {
    upper = Color3.fromRGB(20, 28, 58),
    lower = Color3.fromRGB(38, 18, 58),
    none  = G.BG3,
}
local CaseText = {upper = "CASE: UPPER", lower = "CASE: LOWER", none = "CASE: NONE"}
local BtnCase = newButton(ScrollArea, CaseText[Config.CaseMode],
    UDim2.new(1, 0, 0, 22), UDim2.fromOffset(0, 0), CaseColors[Config.CaseMode])
BtnCase.TextColor3 = G.TEXT; BtnCase.TextSize = 9
BtnCase.LayoutOrder = 3

-- 4) MSG counter row  [- LABEL +]
local BatchRow = Instance.new("Frame")
BatchRow.Size                = UDim2.new(1, 0, 0, 22)
BatchRow.BackgroundTransparency = 1
BatchRow.BorderSizePixel     = 0
BatchRow.LayoutOrder         = 4
BatchRow.Parent              = ScrollArea

local BtnBM = newButton(BatchRow, "-", UDim2.fromOffset(26, 22), UDim2.fromOffset(0, 0), G.BG3)
BtnBM.TextColor3 = G.MUTED; BtnBM.TextSize = 14

local LblBatch = newLabel(BatchRow, ("MSG: 0/%d"):format(Config.BatchCount),
    UDim2.new(1, -52, 1, 0), UDim2.fromOffset(26, 0),
    10, Enum.Font.GothamBold, Enum.TextXAlignment.Center)
LblBatch.TextColor3 = G.TEXT

local BtnBP = newButton(BatchRow, "+", UDim2.fromOffset(26, 22), UDim2.new(1, -26, 0, 0), G.BG3)
BtnBP.TextColor3 = G.MUTED; BtnBP.TextSize = 14

-- 5) Status
local LblStatus = newLabel(ScrollArea, "STATUS: WAITING...",
    UDim2.new(1, 0, 0, 14), UDim2.fromOffset(0, 0),
    9, Enum.Font.Gotham, Enum.TextXAlignment.Center)
LblStatus.TextColor3 = G.MUTED
LblStatus.LayoutOrder = 5

-- 6) Mode
local LblMode = newLabel(ScrollArea, ("MODE: %d GLOBAL MSG"):format(Config.BatchCount),
    UDim2.new(1, 0, 0, 14), UDim2.fromOffset(0, 0),
    9, Enum.Font.GothamBold, Enum.TextXAlignment.Center)
LblMode.TextColor3 = G.MUTED
LblMode.LayoutOrder = 6

-- 7) FORCE SUBMIT
local BtnForce = newButton(ScrollArea, "FORCE SUBMIT",
    UDim2.new(1, 0, 0, 22), UDim2.fromOffset(0, 0), G.BG3)
BtnForce.TextColor3 = G.MUTED; BtnForce.TextSize = 10
BtnForce.LayoutOrder = 7
local ForceStroke = addStroke(BtnForce, G.SEP, 1)

-- 8) CLEAR MSG
local BtnReset = newButton(ScrollArea, "CLEAR MSG",
    UDim2.new(1, 0, 0, 22), UDim2.fromOffset(0, 0), G.RED_D)
BtnReset.TextColor3 = G.RED; BtnReset.TextSize = 10
BtnReset.LayoutOrder = 8
addStroke(BtnReset, G.RED_D, 1)

-- 9) DELAY counter row  [- LABEL +]
local DelayRow = Instance.new("Frame")
DelayRow.Size                = UDim2.new(1, 0, 0, 22)
DelayRow.BackgroundTransparency = 1
DelayRow.BorderSizePixel     = 0
DelayRow.LayoutOrder         = 9
DelayRow.Parent              = ScrollArea

local BtnDM = newButton(DelayRow, "-", UDim2.fromOffset(26, 22), UDim2.fromOffset(0, 0), G.BG3)
BtnDM.TextColor3 = G.MUTED; BtnDM.TextSize = 14

local LblDelay = newLabel(DelayRow, ("DELAY: %ds"):format(Config.SubmitDelay),
    UDim2.new(1, -52, 1, 0), UDim2.fromOffset(26, 0),
    10, Enum.Font.GothamBold, Enum.TextXAlignment.Center)
LblDelay.TextColor3 = G.TEXT

local BtnDP = newButton(DelayRow, "+", UDim2.fromOffset(26, 22), UDim2.new(1, -26, 0, 0), G.BG3)
BtnDP.TextColor3 = G.MUTED; BtnDP.TextSize = 14

--------------------------------------------------------------------------------
-- UI UPDATE HELPERS
--------------------------------------------------------------------------------
local function updateUI()
    local buf = #codeBuffer
    local bc  = Config.BatchCount
    LblBatch.Text       = ("MSG: %d/%d"):format(buf, bc)
    LblBatch.TextColor3 = G.TEXT
    LblDelay.Text       = ("DELAY: %ds"):format(Config.SubmitDelay)
    LblScanStatus.Text  = ("SCANNING: %d MSG (%d/%d)"):format(bc, buf, bc)
    LblMode.Text        = ("MODE: %d GLOBAL MSG"):format(bc)
end

local function setStatus(text, color)
    LblStatus.Text       = "STATUS: " .. text:upper()
    LblStatus.TextColor3 = color or G.MUTED
end

local function setScanState(scanning)
    isScanning = scanning
    if isScanning then
        BtnSubmit.Text             = "STOP SCANNING"
        BtnSubmit.TextColor3       = G.RED
        SubmitStroke.Color         = G.RED_D
        BtnSubmit.BackgroundColor3 = G.RED_D
        LblScanStatus.TextColor3   = G.GREEN
    else
        BtnSubmit.Text             = "START SCANNING"
        BtnSubmit.TextColor3       = G.GREEN
        SubmitStroke.Color         = G.GREEN_D
        BtnSubmit.BackgroundColor3 = G.GREEN_D
        LblScanStatus.TextColor3   = G.MUTED
    end
end

--------------------------------------------------------------------------------
-- CODE HELPERS
--------------------------------------------------------------------------------
local function stripRichText(t) return t:gsub("<[^>]+>", "") end

local function passesCase(code)
    if Config.CaseMode == "upper" then return code == code:upper()
    elseif Config.CaseMode == "lower" then return code == code:lower() end
    return true
end

local function extractCode(raw)
    local clean = stripRichText(raw):match("^%s*(.-)%s*$")
    local code
    if Config.WhitespaceMode == "include" then
        local parts = {}
        for part in clean:gmatch(Config.CodePattern) do
            table.insert(parts, part)
        end
        if #parts == 0 then return nil end
        code = table.concat(parts, "")
    else
        code = clean:match(Config.CodePattern)
    end
    if not code or #code == 0 then return nil end
    if not passesCase(code) then return nil end
    return code
end

local function waitReady()
    task.wait(0.01)
    local e = 0
    while not GameTextBox.Active and e < 1.5 do task.wait(0.1); e += 0.1 end
end

-- submitCode — FREE: delay lebih lambat, ada jeda di setiap tahap
local function submitCode(code)
    InterfaceController:Toggle("Codes", true)
    task.wait(0.5)                      -- jeda buka UI
    GameTextBox:CaptureFocus()
    task.wait(0.5)       -- jeda sesuai setting (min 3s)
    GameTextBox.Text = code
    task.wait(0.8)                      -- jeda sebelum release
    GameTextBox:ReleaseFocus(true)
    waitReady()
end

--------------------------------------------------------------------------------
-- MSG PROCESSOR
--------------------------------------------------------------------------------
local function processMsg()
    if isRunning or #codeBuffer == 0 then return end
    isRunning = true
    local batch = table.clone(codeBuffer)
    updateUI()
    task.spawn(function()
        local combined = table.concat(batch, "")
        setStatus("Submitting: " .. combined, G.GREEN)
        submitCode(combined)
        showNotif("Submitted!", combined, G.GREEN, 2)
        setStatus("Done", G.GREEN)
        task.wait(0.1); setStatus("Waiting...", G.MUTED)
        isRunning = false
    end)
end

--------------------------------------------------------------------------------
-- MINIMIZE
--------------------------------------------------------------------------------
BtnMin.MouseButton1Click:Connect(function()
    isMinimized = not isMinimized
    Content.Visible = not isMinimized
    Frame.Size = UDim2.fromOffset(FW, isMinimized and 26 or FH)
    BtnMin.Text = isMinimized and "+" or "-"
end)

--------------------------------------------------------------------------------
-- MAIN BUTTON LOGIC
--------------------------------------------------------------------------------
BtnCase.MouseButton1Click:Connect(function()
    for i, m in ipairs(CaseCycle) do
        if m == Config.CaseMode then
            Config.CaseMode = CaseCycle[(i % #CaseCycle) + 1]; break
        end
    end
    BtnCase.Text             = CaseText[Config.CaseMode]
    BtnCase.BackgroundColor3 = CaseColors[Config.CaseMode]
    codeBuffer = {}; updateUI()
end)

BtnReset.MouseButton1Click:Connect(function()
    codeBuffer = {}
    updateUI()
    setStatus("Buffer cleared", G.MUTED)
    showNotif("Clear", "MSG buffer cleared", G.MUTED, 2)
end)

BtnBM.MouseButton1Click:Connect(function()
    Config.BatchCount = math.max(1, Config.BatchCount - 1)
    updateUI()
end)
BtnBP.MouseButton1Click:Connect(function()
    Config.BatchCount = math.min(20, Config.BatchCount + 1)
    updateUI()
end)

-- FREE: minimum delay 3 detik
BtnDM.MouseButton1Click:Connect(function()
    Config.SubmitDelay = math.max(3, Config.SubmitDelay - 1); updateUI()
end)
BtnDP.MouseButton1Click:Connect(function()
    Config.SubmitDelay = math.min(30, Config.SubmitDelay + 1); updateUI()
end)

BtnForce.MouseButton1Click:Connect(function()
    if #codeBuffer == 0 then
        showNotif("Force Submit", "Buffer is empty", G.MUTED, 2)
        return
    end
    BtnForce.Text             = "SUBMITTING..."
    BtnForce.TextColor3       = G.GREEN
    BtnForce.BackgroundColor3 = G.GREEN_D
    ForceStroke.Color         = G.GREEN_D
    processMsg()
    task.spawn(function()
        if not isRunning then
            BtnForce.Text             = "FORCE SUBMIT"
            BtnForce.TextColor3       = G.MUTED
            BtnForce.BackgroundColor3 = G.BG3
            ForceStroke.Color         = G.SEP
            return
        end
        while isRunning do task.wait(0.1) end
        BtnForce.Text             = "FORCE SUBMIT"
        BtnForce.TextColor3       = G.MUTED
        BtnForce.BackgroundColor3 = G.BG3
        ForceStroke.Color         = G.SEP
    end)
end)

BtnSubmit.MouseButton1Click:Connect(function()
    if isScanning then
        setScanState(false)
        setStatus("Stopped", G.MUTED)
    else
        setScanState(true)
        setStatus("Scanning...", G.GREEN)
        if #codeBuffer > 0 then processMsg() end
    end
end)

--------------------------------------------------------------------------------
-- WRAP NotificationController.Notify
--------------------------------------------------------------------------------
local _originalNotify = NotifController.Notify

NotifController.Notify = function(self, message, duration, sound, position, avatar, key, destroy)
    _originalNotify(self, message, duration, sound, position, avatar, key, destroy)
    if not message or message == "" or destroy then return end
    if not isScanning then return end
    local code = extractCode(message)
    if not code then return end
    table.insert(codeBuffer, code); updateUI()
    setStatus("Captured: " .. code, G.ACCENT)
    if #codeBuffer >= Config.BatchCount then processMsg() end
end

else 
  game:GetService("Players").LocalPlayer:Kick("Unexpected error,try again") 
end
