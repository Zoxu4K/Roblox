-- =========================================================
-- AUTO SAMBUNG KATA | ZoyyHub Style GUI v3
-- Retry otomatis kalau kata ditolak server
-- =========================================================

if not game:IsLoaded() then
    game.Loaded:Wait()
end

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService      = game:GetService("TweenService")
local UserInputService  = game:GetService("UserInputService")
local LocalPlayer       = Players.LocalPlayer

-- =========================
-- CONFIG
-- =========================
local config = {
    minDelay      = 350,
    maxDelay      = 650,
    aggression    = 20,
    minLength     = 2,
    maxLength     = 12,
    useDelay      = true,
    useWordFilter = true,
    retryEnabled  = true,
    maxRetry      = 3,
}

-- =========================
-- DEBUG
-- =========================
local function debugPrint(...)
    local parts, msg = {...}, "[AutoKata] "
    for i, v in ipairs(parts) do
        msg = msg .. tostring(v)
        if i < #parts then msg = msg .. " " end
    end
    print(msg)
end
debugPrint("Script dimulai...")

-- =========================
-- WORDLIST
-- =========================
local kataModule = {}
local kataSet    = {}

local function downloadWordlist()
    debugPrint("Downloading wordlist...")
    local ok, response = pcall(function()
        return game:HttpGet("https://raw.githubusercontent.com/danzzy1we/roblox-script-dump/refs/heads/main/WordListDump/withallcombination2.lua")
    end)
    if not ok or not response then debugPrint("GAGAL: Download failed") return false end
    local content = string.match(response, "return%s*(.+)")
    if not content then debugPrint("GAGAL: Format tidak dikenali") return false end
    content = string.gsub(content, "^%s*{", "")
    content = string.gsub(content, "}%s*$", "")
    local totalProcessed, duplicateCount = 0, 0
    for word in string.gmatch(content, '"([^"]+)"') do
        totalProcessed = totalProcessed + 1
        local w = string.lower(word)
        if #w > 1 then
            if not kataSet[w] then
                kataSet[w] = true
                table.insert(kataModule, w)
            else
                duplicateCount = duplicateCount + 1
            end
        end
    end
    debugPrint(string.format("Wordlist: %d total, %d unik, %d duplikat", totalProcessed, #kataModule, duplicateCount))
    return true
end

local wordOk = downloadWordlist()
if not wordOk or #kataModule == 0 then debugPrint("GAGAL: Wordlist kosong") end
debugPrint("Wordlist loaded:", #kataModule)

-- =========================
-- REMOTES
-- =========================
local remotes         = ReplicatedStorage:WaitForChild("Remotes", 15)
local MatchUI         = remotes and remotes:WaitForChild("MatchUI",        10)
local SubmitWord      = remotes and remotes:WaitForChild("SubmitWord",     10)
local BillboardUpdate = remotes and remotes:WaitForChild("BillboardUpdate",10)
local BillboardEnd    = remotes and remotes:WaitForChild("BillboardEnd",   10)
local TypeSound       = remotes and remotes:WaitForChild("TypeSound",      10)
local UsedWordWarn    = remotes and remotes:WaitForChild("UsedWordWarn",   10)
debugPrint("Remotes loaded")

-- =========================
-- STATE
-- =========================
local matchActive    = false
local isMyTurn       = false
local serverLetter   = ""
local usedWordsSet   = {}
local autoEnabled    = false
local autoRunning    = false
local lastWord       = "-"
local wordsPlayed    = 0
local retryCount     = 0
local triedThisTurn  = {}   -- kata yang sudah dicoba giliran ini (untuk skip saat retry)
local statusRetry    = ""   -- untuk status display

local function isUsed(word)
    return usedWordsSet[string.lower(word)] == true
end

local function isTriedThisTurn(word)
    return triedThisTurn[string.lower(word)] == true
end

local function addUsedWord(w)
    local lw = string.lower(w)
    if not usedWordsSet[lw] then usedWordsSet[lw] = true end
end

local function addTriedThisTurn(w)
    triedThisTurn[string.lower(w)] = true
end

local function resetUsedWords()
    usedWordsSet = {}
end

local function resetTurnState()
    triedThisTurn = {}
    retryCount    = 0
    statusRetry   = ""
end

-- =========================
-- WORD LOGIC
-- =========================
local function getSmartWords(prefix, skipTried)
    local results     = {}
    local lowerPrefix = string.lower(prefix)
    local prefixLen   = #lowerPrefix
    for _, word in ipairs(kataModule) do
        if string.sub(word, 1, prefixLen) == lowerPrefix then
            local skip = isUsed(word)
            if not skip and skipTried then
                skip = isTriedThisTurn(word)
            end
            if not skip then
                if config.useWordFilter then
                    local len = #word
                    if len >= config.minLength and len <= config.maxLength then
                        table.insert(results, word)
                    end
                else
                    table.insert(results, word)
                end
            end
        end
    end
    table.sort(results, function(a, b) return #a > #b end)
    return results
end

local function humanDelay()
    if not config.useDelay then return end
    local mn = config.minDelay
    local mx = config.maxDelay
    if mn > mx then mn = mx end
    task.wait(math.random(mn, mx) / 1000)
end

-- ketik kata ke billboard lalu submit
local function typeAndSubmit(selectedWord)
    local remain      = string.sub(selectedWord, #serverLetter + 1)
    local currentWord = serverLetter

    for i = 1, #remain do
        if not matchActive or not isMyTurn then return false end
        currentWord = currentWord .. string.sub(remain, i, i)
        pcall(function()
            TypeSound:FireServer()
            BillboardUpdate:FireServer(currentWord)
        end)
        humanDelay()
    end

    humanDelay()
    pcall(function()
        SubmitWord:FireServer(selectedWord)
    end)
    return true
end

-- =========================
-- AI ENGINE + RETRY
-- =========================
local function startUltraAI()
    if autoRunning    then return end
    if not autoEnabled then return end
    if not matchActive then return end
    if not isMyTurn   then return end
    if serverLetter == "" then return end
    if #kataModule == 0   then return end

    autoRunning = true

    -- loop retry
    while true do
        -- cek state masih valid
        if not autoEnabled or not matchActive or not isMyTurn then
            autoRunning = false
            return
        end

        -- cek batas retry
        if config.retryEnabled and retryCount > 0 then
            if retryCount >= config.maxRetry then
                debugPrint("Max retry tercapai (" .. config.maxRetry .. "x), berhenti")
                statusRetry = "Menyerah (" .. retryCount .. "x)"
                autoRunning = false
                return
            end
        end

        -- ambil kata, skip yang sudah dicoba giliran ini
        local words = getSmartWords(serverLetter, config.retryEnabled)

        -- kalau semua kata sudah dicoba, coba tanpa skip (fallback)
        if #words == 0 then
            words = getSmartWords(serverLetter, false)
            if #words == 0 then
                debugPrint("Tidak ada kata untuk huruf:", serverLetter)
                autoRunning = false
                return
            end
            debugPrint("Fallback: semua kata sudah dicoba, ulang dari awal")
        end

        -- pilih kata berdasarkan aggression
        local topN = math.max(1, math.floor(#words * (1 - config.aggression / 100)))
        if topN > #words then topN = #words end
        local selectedWord = words[math.random(1, topN)]

        if retryCount == 0 then
            debugPrint("Mencoba:", selectedWord)
        else
            debugPrint(string.format("Retry %d/%d: mencoba kata lain '%s'", retryCount, config.maxRetry, selectedWord))
            statusRetry = string.format("Retry %d/%d", retryCount, config.maxRetry)
        end

        -- tandai sudah dicoba giliran ini
        addTriedThisTurn(selectedWord)

        -- kirim delay awal (hanya jika bukan retry atau delay aktif)
        if retryCount == 0 then
            humanDelay()
        else
            -- delay lebih pendek untuk retry biar natural
            if config.useDelay then
                task.wait(math.random(150, 350) / 1000)
            else
                task.wait(0.1)
            end
        end

        -- cek state sekali lagi setelah delay
        if not matchActive or not isMyTurn then
            autoRunning = false
            return
        end

        -- ketik dan submit
        local submitted = typeAndSubmit(selectedWord)
        if not submitted then
            -- giliran berakhir saat ketik
            autoRunning = false
            return
        end

        -- tunggu respons server (apakah kata diterima atau ditolak)
        -- kalau diterima: giliran akan berpindah ke lawan (isMyTurn = false)
        -- kalau ditolak:  giliran tetap kita (isMyTurn = true setelah ~0.8 detik)
        local checkStart = os.clock()
        local waitTime   = 0.8  -- waktu tunggu respons server

        while os.clock() - checkStart < waitTime do
            task.wait(0.05)
            -- kalau giliran sudah bukan kita = kata diterima
            if not isMyTurn then
                addUsedWord(selectedWord)
                lastWord    = selectedWord
                wordsPlayed = wordsPlayed + 1
                statusRetry = ""
                debugPrint("Diterima:", selectedWord)
                autoRunning = false
                return
            end
        end

        -- setelah 0.8 detik masih giliran kita = kata DITOLAK server
        debugPrint("Kata ditolak server:", selectedWord)

        if not config.retryEnabled then
            -- fitur retry off, langsung berhenti
            autoRunning = false
            return
        end

        retryCount = retryCount + 1
        -- lanjut loop retry dengan kata lain
    end
end

-- =========================
-- GUI SYSTEM
-- =========================
local CFG = {
    MainSize    = UDim2.new(0, 440, 0, 340),
    IconSize    = UDim2.new(0, 55, 0, 55),
    HeaderH     = 38,
    TabWidth    = 130,
    BgColor     = Color3.fromRGB(18, 18, 24),
    AccentColor = Color3.fromRGB(88, 166, 255),
}

local function Tween(obj, props, dur)
    TweenService:Create(obj, TweenInfo.new(dur or 0.25, Enum.EasingStyle.Quart, Enum.EasingDirection.Out), props):Play()
end

local gui = Instance.new("ScreenGui")
gui.Name = "AutoKataHub"
gui.ResetOnSpawn = false
gui.ZIndexBehavior = Enum.ZIndexBehavior.Global
gui.DisplayOrder = 999
pcall(function() gui.Parent = game:GetService("CoreGui") end)
if not gui.Parent then gui.Parent = LocalPlayer:WaitForChild("PlayerGui") end

-- ============================================
-- CONFIRM EXIT DIALOG
-- ============================================
local confirmOverlay = Instance.new("Frame", gui)
confirmOverlay.BackgroundTransparency = 1
confirmOverlay.Size = UDim2.new(1,0,1,0)
confirmOverlay.ZIndex = 200
confirmOverlay.Visible = false

local confirmDialog = Instance.new("Frame", confirmOverlay)
confirmDialog.BackgroundColor3 = Color3.fromRGB(22,22,30)
confirmDialog.Size = UDim2.new(0,240,0,100)
confirmDialog.Position = UDim2.new(0.5,-120,0.5,-50)
confirmDialog.ZIndex = 201
Instance.new("UICorner", confirmDialog).CornerRadius = UDim.new(0,10)
local dStroke = Instance.new("UIStroke", confirmDialog)
dStroke.Color = CFG.AccentColor; dStroke.Thickness = 1.5; dStroke.Transparency = 0.4

local confirmText = Instance.new("TextLabel", confirmDialog)
confirmText.BackgroundTransparency = 1
confirmText.Position = UDim2.new(0,0,0,14)
confirmText.Size = UDim2.new(1,0,0,26)
confirmText.Font = Enum.Font.GothamBold
confirmText.Text = "Keluar dari script?"
confirmText.TextColor3 = Color3.fromRGB(235,235,245)
confirmText.TextSize = 13
confirmText.ZIndex = 202

local function MakeDialogBtn(text, xOffset)
    local b = Instance.new("TextButton", confirmDialog)
    b.BackgroundColor3 = Color3.fromRGB(45,45,58)
    b.BorderSizePixel = 0
    b.Position = UDim2.new(0.5,xOffset,1,-36)
    b.Size = UDim2.new(0,90,0,26)
    b.Font = Enum.Font.GothamSemibold
    b.Text = text
    b.TextColor3 = Color3.fromRGB(200,200,210)
    b.TextSize = 12; b.ZIndex = 202; b.AutoButtonColor = false
    Instance.new("UICorner", b).CornerRadius = UDim.new(0,7)
    b.MouseEnter:Connect(function() Tween(b,{BackgroundColor3=Color3.fromRGB(60,60,75)},0.15) end)
    b.MouseLeave:Connect(function() Tween(b,{BackgroundColor3=Color3.fromRGB(45,45,58)},0.15) end)
    return b
end
local cancelBtn      = MakeDialogBtn("Batal",  -95)
local exitConfirmBtn = MakeDialogBtn("Keluar",   5)

local function ShowConfirmDialog()
    confirmOverlay.Visible = true
    confirmDialog.Size = UDim2.new(0,0,0,0)
    confirmDialog.Position = UDim2.new(0.5,0,0.5,0)
    Tween(confirmDialog,{Size=UDim2.new(0,240,0,100),Position=UDim2.new(0.5,-120,0.5,-50)},0.25)
end
local function HideConfirmDialog()
    Tween(confirmDialog,{Size=UDim2.new(0,0,0,0),Position=UDim2.new(0.5,0,0.5,0)},0.2)
    task.wait(0.2); confirmOverlay.Visible = false
end
cancelBtn.MouseButton1Click:Connect(HideConfirmDialog)
exitConfirmBtn.MouseButton1Click:Connect(function()
    HideConfirmDialog(); autoEnabled = false; task.wait(0.3); gui:Destroy()
end)

-- ============================================
-- FLOATING ICON
-- ============================================
local icon = Instance.new("ImageButton", gui)
icon.BackgroundColor3 = Color3.fromRGB(25,25,32)
icon.BackgroundTransparency = 0.1
icon.BorderSizePixel = 0
icon.Position = UDim2.new(0.02,0,0.5,-27)
icon.Size = CFG.IconSize
icon.Image = "rbxassetid://93126193050316"
icon.ScaleType = Enum.ScaleType.Fit
icon.ZIndex = 100
Instance.new("UICorner", icon).CornerRadius = UDim.new(0,12)
local iconStroke = Instance.new("UIStroke", icon)
iconStroke.Color = CFG.AccentColor; iconStroke.Thickness = 2; iconStroke.Transparency = 0.5

local iconDragging, iconDragStart, iconStartPos
icon.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        iconDragging = true; iconDragStart = input.Position; iconStartPos = icon.Position
        input.Changed:Connect(function()
            if input.UserInputState == Enum.UserInputState.End then iconDragging = false end
        end)
    end
end)
UserInputService.InputChanged:Connect(function(input)
    if iconDragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
        local d = input.Position - iconDragStart
        icon.Position = UDim2.new(iconStartPos.X.Scale, iconStartPos.X.Offset+d.X, iconStartPos.Y.Scale, iconStartPos.Y.Offset+d.Y)
    end
end)

-- ============================================
-- MAIN WINDOW
-- ============================================
local main = Instance.new("Frame", gui)
main.BackgroundColor3 = CFG.BgColor
main.BackgroundTransparency = 0.15
main.BorderSizePixel = 0
main.Position = UDim2.new(0.5,-220,0.5,-170)
main.Size = CFG.MainSize
main.Visible = false
main.ZIndex = 10
Instance.new("UICorner", main).CornerRadius = UDim.new(0,10)
local mainStroke = Instance.new("UIStroke", main)
mainStroke.Color = CFG.AccentColor; mainStroke.Thickness = 1.5; mainStroke.Transparency = 0.6

local header = Instance.new("Frame", main)
header.BackgroundColor3 = Color3.fromRGB(28,28,36)
header.BackgroundTransparency = 0.3
header.BorderSizePixel = 0
header.Size = UDim2.new(1,0,0,CFG.HeaderH)
header.ZIndex = 11
Instance.new("UICorner", header).CornerRadius = UDim.new(0,10)

local titleLabel = Instance.new("TextLabel", header)
titleLabel.BackgroundTransparency = 1
titleLabel.Position = UDim2.new(0,15,0,0)
titleLabel.Size = UDim2.new(1,-80,1,0)
titleLabel.Font = Enum.Font.GothamBold
titleLabel.Text = "Auto Sambung Kata"
titleLabel.TextColor3 = Color3.fromRGB(245,245,255)
titleLabel.TextSize = 14
titleLabel.TextXAlignment = Enum.TextXAlignment.Left
titleLabel.ZIndex = 12

local function MakeHeaderBtn(txt, xOff)
    local b = Instance.new("TextButton", header)
    b.BackgroundColor3 = Color3.fromRGB(32,32,42)
    b.BorderSizePixel = 0
    b.Position = UDim2.new(1,xOff,0.5,-10)
    b.Size = UDim2.new(0,20,0,20)
    b.Font = Enum.Font.GothamBold
    b.Text = txt
    b.TextColor3 = Color3.fromRGB(255,255,255)
    b.TextSize = 15; b.ZIndex = 12; b.AutoButtonColor = false
    Instance.new("UICorner", b).CornerRadius = UDim.new(0,5)
    return b
end
local minimizeBtn = MakeHeaderBtn("−", -53)
local exitBtn     = MakeHeaderBtn("×", -28)

local tabPanel = Instance.new("ScrollingFrame", main)
tabPanel.BackgroundColor3 = Color3.fromRGB(22,22,30)
tabPanel.BackgroundTransparency = 0.3
tabPanel.BorderSizePixel = 0
tabPanel.Position = UDim2.new(0,0,0,CFG.HeaderH)
tabPanel.Size = UDim2.new(0,CFG.TabWidth,1,-CFG.HeaderH)
tabPanel.ScrollBarThickness = 4
tabPanel.ScrollBarImageColor3 = CFG.AccentColor
tabPanel.CanvasSize = UDim2.new(0,0,0,0)
tabPanel.ZIndex = 11
Instance.new("UICorner", tabPanel).CornerRadius = UDim.new(0,10)
local tabLayout = Instance.new("UIListLayout", tabPanel)
tabLayout.Padding = UDim.new(0,4); tabLayout.SortOrder = Enum.SortOrder.LayoutOrder
tabLayout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
    tabPanel.CanvasSize = UDim2.new(0,0,0,tabLayout.AbsoluteContentSize.Y+10)
end)
local tabPad = Instance.new("UIPadding", tabPanel)
tabPad.PaddingLeft = UDim.new(0,8); tabPad.PaddingRight = UDim.new(0,8); tabPad.PaddingTop = UDim.new(0,8)

local divider = Instance.new("Frame", main)
divider.BackgroundColor3 = Color3.fromRGB(45,45,58)
divider.BorderSizePixel = 0
divider.Position = UDim2.new(0,CFG.TabWidth,0,CFG.HeaderH)
divider.Size = UDim2.new(0,1,1,-CFG.HeaderH)
divider.ZIndex = 11

local contentPanel = Instance.new("ScrollingFrame", main)
contentPanel.BackgroundTransparency = 1
contentPanel.BorderSizePixel = 0
contentPanel.Position = UDim2.new(0,CFG.TabWidth+1,0,CFG.HeaderH+5)
contentPanel.Size = UDim2.new(1,-(CFG.TabWidth+1),1,-(CFG.HeaderH+5))
contentPanel.ScrollBarThickness = 4
contentPanel.ScrollBarImageColor3 = CFG.AccentColor
contentPanel.CanvasSize = UDim2.new(0,0,0,0)
contentPanel.ZIndex = 11
local contentLayout = Instance.new("UIListLayout", contentPanel)
contentLayout.Padding = UDim.new(0,8); contentLayout.SortOrder = Enum.SortOrder.LayoutOrder
contentLayout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
    contentPanel.CanvasSize = UDim2.new(0,0,0,contentLayout.AbsoluteContentSize.Y+10)
end)
local contentPad = Instance.new("UIPadding", contentPanel)
contentPad.PaddingLeft = UDim.new(0,10); contentPad.PaddingRight = UDim.new(0,10); contentPad.PaddingTop = UDim.new(0,5)

-- ============================================
-- TAB SYSTEM
-- ============================================
local Tabs = {}
local CurrentTab = nil

local function SwitchTab(tabName)
    for name, tab in pairs(Tabs) do
        local isActive = (name == tabName)
        tab.Container.Visible = isActive
        local stroke = tab.Button:FindFirstChild("UIStroke")
        if isActive then
            tab.Button.BackgroundColor3 = CFG.AccentColor
            tab.Button.TextColor3 = Color3.fromRGB(255,255,255)
            tab.Button.BackgroundTransparency = 0.1
            if stroke then stroke.Transparency = 0.2 end
        else
            tab.Button.BackgroundColor3 = Color3.fromRGB(32,32,42)
            tab.Button.TextColor3 = Color3.fromRGB(200,200,210)
            tab.Button.BackgroundTransparency = 0.2
            if stroke then stroke.Transparency = 0.4 end
        end
    end
    CurrentTab = tabName
end

local function CreateTab(tabName, layoutOrder)
    local tabBtn = Instance.new("TextButton", tabPanel)
    tabBtn.BackgroundColor3 = Color3.fromRGB(32,32,42)
    tabBtn.BackgroundTransparency = 0.2
    tabBtn.BorderSizePixel = 0
    tabBtn.Size = UDim2.new(1,0,0,35)
    tabBtn.LayoutOrder = layoutOrder
    tabBtn.Font = Enum.Font.GothamSemibold
    tabBtn.Text = tabName
    tabBtn.TextColor3 = Color3.fromRGB(200,200,210)
    tabBtn.TextSize = 12; tabBtn.ZIndex = 12; tabBtn.AutoButtonColor = false
    Instance.new("UICorner", tabBtn).CornerRadius = UDim.new(0,7)
    local ts = Instance.new("UIStroke", tabBtn)
    ts.Color = Color3.fromRGB(45,45,58); ts.Thickness = 1; ts.Transparency = 0.4

    local container = Instance.new("Frame", contentPanel)
    container.BackgroundTransparency = 1
    container.BorderSizePixel = 0
    container.Size = UDim2.new(1,0,0,0)
    container.Visible = false; container.ZIndex = 12
    local cl = Instance.new("UIListLayout", container)
    cl.Padding = UDim.new(0,8); cl.SortOrder = Enum.SortOrder.LayoutOrder
    cl:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
        container.Size = UDim2.new(1,0,0,cl.AbsoluteContentSize.Y)
    end)

    tabBtn.MouseButton1Click:Connect(function() SwitchTab(tabName) end)
    Tabs[tabName] = {Button=tabBtn, Container=container}
    if not CurrentTab then SwitchTab(tabName) end
    return container
end

-- ============================================
-- SECTION (COLLAPSIBLE)
-- ============================================
local function CreateSection(parent, sectionName, layoutOrder)
    local sectionHeader = Instance.new("TextButton", parent)
    sectionHeader.BackgroundColor3 = Color3.fromRGB(32,32,42)
    sectionHeader.BackgroundTransparency = 0.2
    sectionHeader.BorderSizePixel = 0
    sectionHeader.Size = UDim2.new(1,0,0,32)
    sectionHeader.LayoutOrder = layoutOrder
    sectionHeader.ZIndex = 12; sectionHeader.AutoButtonColor = false; sectionHeader.Text = ""
    Instance.new("UICorner", sectionHeader).CornerRadius = UDim.new(0,7)
    local ss = Instance.new("UIStroke", sectionHeader)
    ss.Color = Color3.fromRGB(45,45,58); ss.Thickness = 1; ss.Transparency = 0.4

    local arrow = Instance.new("TextLabel", sectionHeader)
    arrow.BackgroundTransparency = 1
    arrow.Position = UDim2.new(0,10,0,0); arrow.Size = UDim2.new(0,15,1,0)
    arrow.Font = Enum.Font.GothamBold; arrow.Text = "▶"
    arrow.TextColor3 = CFG.AccentColor; arrow.TextSize = 10; arrow.ZIndex = 13

    local sectionLabel = Instance.new("TextLabel", sectionHeader)
    sectionLabel.BackgroundTransparency = 1
    sectionLabel.Position = UDim2.new(0,30,0,0); sectionLabel.Size = UDim2.new(1,-30,1,0)
    sectionLabel.Font = Enum.Font.GothamSemibold; sectionLabel.Text = sectionName
    sectionLabel.TextColor3 = Color3.fromRGB(235,235,245); sectionLabel.TextSize = 12
    sectionLabel.TextXAlignment = Enum.TextXAlignment.Left; sectionLabel.ZIndex = 13

    local sectionContent = Instance.new("Frame", parent)
    sectionContent.BackgroundTransparency = 1; sectionContent.BorderSizePixel = 0
    sectionContent.Size = UDim2.new(1,0,0,0)
    sectionContent.LayoutOrder = layoutOrder + 0.5
    sectionContent.ClipsDescendants = true; sectionContent.Visible = false; sectionContent.ZIndex = 12
    local sl = Instance.new("UIListLayout", sectionContent)
    sl.Padding = UDim.new(0,6); sl.SortOrder = Enum.SortOrder.LayoutOrder
    local sp = Instance.new("UIPadding", sectionContent)
    sp.PaddingTop = UDim.new(0,6); sp.PaddingBottom = UDim.new(0,6); sp.PaddingLeft = UDim.new(0,8)

    local expanded = false
    local collapseThread = nil
    local function Toggle()
        expanded = not expanded
        Tween(arrow,{Rotation = expanded and 90 or 0},0.2)
        if collapseThread then task.cancel(collapseThread); collapseThread = nil end
        if expanded then
            sectionContent.Visible = true
            task.defer(function()
                local h = sl.AbsoluteContentSize.Y + 12
                if h <= 12 then h = 200 end
                Tween(sectionContent,{Size=UDim2.new(1,0,0,h)},0.25)
            end)
        else
            Tween(sectionContent,{Size=UDim2.new(1,0,0,0)},0.2)
            collapseThread = task.delay(0.2, function()
                if not expanded then sectionContent.Visible = false end
                collapseThread = nil
            end)
        end
    end
    sectionHeader.MouseButton1Click:Connect(Toggle)
    sl:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
        if expanded then sectionContent.Size = UDim2.new(1,0,0,sl.AbsoluteContentSize.Y+12) end
    end)
    return sectionContent
end

-- ============================================
-- UI COMPONENTS
-- ============================================

-- Toggle pill biasa
local function CreateToggle(parent, name, layoutOrder, defaultValue)
    local Container = Instance.new("Frame", parent)
    Container.BackgroundColor3 = Color3.fromRGB(32,32,42)
    Container.BackgroundTransparency = 0.2
    Container.BorderSizePixel = 0
    Container.Size = UDim2.new(1,0,0,35)
    Container.LayoutOrder = layoutOrder; Container.ZIndex = 13
    Instance.new("UICorner", Container).CornerRadius = UDim.new(0,7)
    local stroke = Instance.new("UIStroke", Container)
    stroke.Color = Color3.fromRGB(45,45,58); stroke.Thickness = 1; stroke.Transparency = 0.4

    local Label = Instance.new("TextLabel", Container)
    Label.BackgroundTransparency = 1
    Label.Position = UDim2.new(0,12,0,0); Label.Size = UDim2.new(1,-60,1,0)
    Label.Font = Enum.Font.GothamSemibold; Label.Text = name
    Label.TextColor3 = Color3.fromRGB(235,235,245); Label.TextSize = 11
    Label.TextXAlignment = Enum.TextXAlignment.Left; Label.ZIndex = 14

    local toggleButton = Instance.new("TextButton", Container)
    toggleButton.BackgroundColor3 = Color3.fromRGB(32,32,42)
    toggleButton.BorderSizePixel = 0
    toggleButton.Position = UDim2.new(1,-45,0.5,-10); toggleButton.Size = UDim2.new(0,35,0,20)
    toggleButton.Text = ""; toggleButton.ZIndex = 14; toggleButton.AutoButtonColor = false
    Instance.new("UICorner", toggleButton).CornerRadius = UDim.new(1,0)
    local ts = Instance.new("UIStroke", toggleButton)
    ts.Color = Color3.fromRGB(45,45,58); ts.Thickness = 1; ts.Transparency = 0.4

    local indicator = Instance.new("Frame", toggleButton)
    indicator.BackgroundColor3 = defaultValue and CFG.AccentColor or Color3.fromRGB(255,255,255)
    indicator.BorderSizePixel = 0
    indicator.Position = defaultValue and UDim2.new(1,-18,0.5,-8) or UDim2.new(0,2,0.5,-8)
    indicator.Size = UDim2.new(0,16,0,16); indicator.ZIndex = 15
    Instance.new("UICorner", indicator).CornerRadius = UDim.new(1,0)

    return toggleButton, indicator
end

-- Toggle + input box sejajar (style AutoLeaveOnPlayers)
local function CreateToggleWithInput(parent, name, desc, layoutOrder, defaultToggle, defaultValue)
    local Container = Instance.new("Frame", parent)
    Container.BackgroundColor3 = Color3.fromRGB(32,32,42)
    Container.BackgroundTransparency = 0.2
    Container.BorderSizePixel = 0
    Container.Size = UDim2.new(1,0,0,58)
    Container.LayoutOrder = layoutOrder; Container.ZIndex = 13
    Instance.new("UICorner", Container).CornerRadius = UDim.new(0,7)
    local stroke = Instance.new("UIStroke", Container)
    stroke.Color = Color3.fromRGB(45,45,58); stroke.Thickness = 1; stroke.Transparency = 0.4

    local TitleLabel = Instance.new("TextLabel", Container)
    TitleLabel.BackgroundTransparency = 1
    TitleLabel.Position = UDim2.new(0,12,0,8); TitleLabel.Size = UDim2.new(1,-60,0,15)
    TitleLabel.Font = Enum.Font.GothamSemibold; TitleLabel.Text = name
    TitleLabel.TextColor3 = Color3.fromRGB(235,235,245); TitleLabel.TextSize = 12
    TitleLabel.TextXAlignment = Enum.TextXAlignment.Left; TitleLabel.ZIndex = 14

    local toggleButton = Instance.new("TextButton", Container)
    toggleButton.BackgroundColor3 = Color3.fromRGB(32,32,42)
    toggleButton.BorderSizePixel = 0
    toggleButton.Position = UDim2.new(1,-45,0,8); toggleButton.Size = UDim2.new(0,35,0,20)
    toggleButton.Text = ""; toggleButton.ZIndex = 14; toggleButton.AutoButtonColor = false
    Instance.new("UICorner", toggleButton).CornerRadius = UDim.new(1,0)
    local ts = Instance.new("UIStroke", toggleButton)
    ts.Color = Color3.fromRGB(45,45,58); ts.Thickness = 1; ts.Transparency = 0.4

    local indicator = Instance.new("Frame", toggleButton)
    indicator.BackgroundColor3 = defaultToggle and CFG.AccentColor or Color3.fromRGB(255,255,255)
    indicator.BorderSizePixel = 0
    indicator.Position = defaultToggle and UDim2.new(1,-18,0.5,-8) or UDim2.new(0,2,0.5,-8)
    indicator.Size = UDim2.new(0,16,0,16); indicator.ZIndex = 15
    Instance.new("UICorner", indicator).CornerRadius = UDim.new(1,0)

    local DescLabel = Instance.new("TextLabel", Container)
    DescLabel.BackgroundTransparency = 1
    DescLabel.Position = UDim2.new(0,12,0,32); DescLabel.Size = UDim2.new(1,-120,0,18)
    DescLabel.Font = Enum.Font.Gotham; DescLabel.Text = desc
    DescLabel.TextColor3 = Color3.fromRGB(180,180,190); DescLabel.TextSize = 11
    DescLabel.TextXAlignment = Enum.TextXAlignment.Left; DescLabel.ZIndex = 14

    local InputBox = Instance.new("TextBox", Container)
    InputBox.BackgroundColor3 = Color3.fromRGB(28,28,36)
    InputBox.BackgroundTransparency = 0.3; InputBox.BorderSizePixel = 0
    InputBox.Position = UDim2.new(1,-58,0,32); InputBox.Size = UDim2.new(0,48,0,18)
    InputBox.Font = Enum.Font.GothamMedium; InputBox.Text = tostring(defaultValue)
    InputBox.TextColor3 = Color3.fromRGB(235,235,245); InputBox.TextSize = 11
    InputBox.ZIndex = 14; InputBox.ClearTextOnFocus = false
    InputBox.TextXAlignment = Enum.TextXAlignment.Center
    Instance.new("UICorner", InputBox).CornerRadius = UDim.new(0,5)
    local boxStroke = Instance.new("UIStroke", InputBox)
    boxStroke.Color = Color3.fromRGB(45,45,58); boxStroke.Thickness = 1; boxStroke.Transparency = 0.4

    InputBox.Focused:Connect(function()
        Tween(InputBox,{BackgroundColor3=Color3.fromRGB(38,38,46)},0.2)
        Tween(boxStroke,{Color=CFG.AccentColor,Transparency=0.2},0.2)
    end)
    InputBox.FocusLost:Connect(function()
        Tween(InputBox,{BackgroundColor3=Color3.fromRGB(28,28,36)},0.2)
        Tween(boxStroke,{Color=Color3.fromRGB(45,45,58),Transparency=0.4},0.2)
    end)

    return toggleButton, indicator, InputBox
end

-- Text box standalone
local function CreateTextBox(parent, name, layoutOrder, defaultValue, placeholder)
    local Container = Instance.new("Frame", parent)
    Container.BackgroundColor3 = Color3.fromRGB(32,32,42)
    Container.BackgroundTransparency = 0.2; Container.BorderSizePixel = 0
    Container.Size = UDim2.new(1,0,0,35)
    Container.LayoutOrder = layoutOrder; Container.ZIndex = 13
    Instance.new("UICorner", Container).CornerRadius = UDim.new(0,7)
    local stroke = Instance.new("UIStroke", Container)
    stroke.Color = Color3.fromRGB(45,45,58); stroke.Thickness = 1; stroke.Transparency = 0.4

    local Label = Instance.new("TextLabel", Container)
    Label.BackgroundTransparency = 1
    Label.Position = UDim2.new(0,12,0,0); Label.Size = UDim2.new(1,-80,1,0)
    Label.Font = Enum.Font.GothamSemibold; Label.Text = name
    Label.TextColor3 = Color3.fromRGB(235,235,245); Label.TextSize = 11
    Label.TextXAlignment = Enum.TextXAlignment.Left; Label.ZIndex = 14

    local TextBox = Instance.new("TextBox", Container)
    TextBox.BackgroundColor3 = Color3.fromRGB(28,28,36)
    TextBox.BackgroundTransparency = 0.3; TextBox.BorderSizePixel = 0
    TextBox.Position = UDim2.new(1,-64,0.5,-10); TextBox.Size = UDim2.new(0,56,0,20)
    TextBox.Font = Enum.Font.GothamMedium; TextBox.PlaceholderText = placeholder or ""
    TextBox.Text = defaultValue or ""; TextBox.TextColor3 = Color3.fromRGB(235,235,245)
    TextBox.TextSize = 11; TextBox.ZIndex = 14; TextBox.ClearTextOnFocus = false
    TextBox.TextXAlignment = Enum.TextXAlignment.Center
    Instance.new("UICorner", TextBox).CornerRadius = UDim.new(0,5)
    local boxStroke = Instance.new("UIStroke", TextBox)
    boxStroke.Color = Color3.fromRGB(45,45,58); boxStroke.Thickness = 1; boxStroke.Transparency = 0.4

    TextBox.Focused:Connect(function()
        Tween(TextBox,{BackgroundColor3=Color3.fromRGB(38,38,46)},0.2)
        Tween(boxStroke,{Color=CFG.AccentColor,Transparency=0.2},0.2)
    end)
    TextBox.FocusLost:Connect(function()
        Tween(TextBox,{BackgroundColor3=Color3.fromRGB(28,28,36)},0.2)
        Tween(boxStroke,{Color=Color3.fromRGB(45,45,58),Transparency=0.4},0.2)
    end)
    return TextBox
end

-- Info card
local function CreateInfoCard(parent, text, layoutOrder)
    local label = Instance.new("TextLabel", parent)
    label.BackgroundColor3 = Color3.fromRGB(32,32,42)
    label.BackgroundTransparency = 0.2; label.BorderSizePixel = 0
    label.Size = UDim2.new(1,0,0,35)
    label.LayoutOrder = layoutOrder; label.Font = Enum.Font.GothamMedium
    label.Text = text; label.TextColor3 = Color3.fromRGB(200,200,210)
    label.TextSize = 11; label.TextWrapped = true
    label.TextYAlignment = Enum.TextYAlignment.Center; label.ZIndex = 13
    Instance.new("UICorner", label).CornerRadius = UDim.new(0,7)
    local stroke = Instance.new("UIStroke", label)
    stroke.Color = Color3.fromRGB(45,45,58); stroke.Thickness = 1; stroke.Transparency = 0.4
    local padding = Instance.new("UIPadding", label)
    padding.PaddingLeft = UDim.new(0,12); padding.PaddingRight = UDim.new(0,12)
    return label
end

-- Status grid 3x2
local function CreateStatusGrid(parent, layoutOrder)
    local grid = Instance.new("Frame", parent)
    grid.BackgroundColor3 = Color3.fromRGB(28,28,36)
    grid.BackgroundTransparency = 0.1; grid.BorderSizePixel = 0
    grid.Size = UDim2.new(1,0,0,144)  -- 4 baris
    grid.LayoutOrder = layoutOrder; grid.ZIndex = 13
    Instance.new("UICorner", grid).CornerRadius = UDim.new(0,7)
    local gStroke = Instance.new("UIStroke", grid)
    gStroke.Color = CFG.AccentColor; gStroke.Thickness = 1; gStroke.Transparency = 0.5

    local labels = {
        {"Match",        "Inactive"},
        {"Giliran",      "Menunggu"},
        {"Huruf",        "-"},
        {"Tersedia",     "0 kata"},
        {"Kata Terakhir","-"},
        {"Dimainkan",    "0"},
        {"Retry",        "Off"},
        {"Status",       "-"},
    }

    local cells = {}
    for i, pair in ipairs(labels) do
        local col = (i - 1) % 2
        local row = math.floor((i - 1) / 2)

        local cell = Instance.new("Frame", grid)
        cell.BackgroundTransparency = 1
        cell.Position = UDim2.new(col * 0.5, col == 0 and 8 or 4, 0, 8 + row * 34)
        cell.Size = UDim2.new(0.5, -12, 0, 30)
        cell.ZIndex = 14

        local keyLabel = Instance.new("TextLabel", cell)
        keyLabel.BackgroundTransparency = 1
        keyLabel.Size = UDim2.new(1,0,0,13)
        keyLabel.Font = Enum.Font.Gotham; keyLabel.Text = pair[1]
        keyLabel.TextColor3 = Color3.fromRGB(130,130,145)
        keyLabel.TextSize = 9; keyLabel.TextXAlignment = Enum.TextXAlignment.Left
        keyLabel.ZIndex = 15

        local valLabel = Instance.new("TextLabel", cell)
        valLabel.BackgroundTransparency = 1
        valLabel.Position = UDim2.new(0,0,0,14); valLabel.Size = UDim2.new(1,0,0,16)
        valLabel.Font = Enum.Font.GothamBold; valLabel.Text = pair[2]
        valLabel.TextColor3 = Color3.fromRGB(235,235,245)
        valLabel.TextSize = 11; valLabel.TextXAlignment = Enum.TextXAlignment.Left
        valLabel.TextTruncate = Enum.TextTruncate.AtEnd; valLabel.ZIndex = 15

        cells[i] = valLabel
    end

    -- separator horizontal
    for r = 1, 3 do
        local sep = Instance.new("Frame", grid)
        sep.BackgroundColor3 = Color3.fromRGB(45,45,58)
        sep.BackgroundTransparency = 0.5; sep.BorderSizePixel = 0
        sep.Position = UDim2.new(0,8,0,8 + r*34 - 2)
        sep.Size = UDim2.new(1,-16,0,1); sep.ZIndex = 14
    end

    -- separator vertikal
    local vsep = Instance.new("Frame", grid)
    vsep.BackgroundColor3 = Color3.fromRGB(45,45,58)
    vsep.BackgroundTransparency = 0.5; vsep.BorderSizePixel = 0
    vsep.Position = UDim2.new(0.5,0,0,8)
    vsep.Size = UDim2.new(0,1,0,128); vsep.ZIndex = 14

    return cells
end

-- ============================================
-- BUILD TABS
-- ============================================
local mainTab   = CreateTab("MAIN",   1)
local configTab = CreateTab("CONFIG", 2)

-- ========== MAIN TAB ==========
local autoSection = CreateSection(mainTab, "Auto Play", 0)

local autoToggle, autoIndicator = CreateToggle(autoSection, "Aktifkan Auto", 1, false)
autoToggle.MouseButton1Click:Connect(function()
    autoEnabled = not autoEnabled
    if autoEnabled then
        Tween(autoIndicator,{Position=UDim2.new(1,-18,0.5,-8),BackgroundColor3=CFG.AccentColor},0.2)
        debugPrint("Auto ON")
        if matchActive and isMyTurn and not autoRunning then
            task.spawn(startUltraAI)
        end
    else
        Tween(autoIndicator,{Position=UDim2.new(0,2,0.5,-8),BackgroundColor3=Color3.fromRGB(255,255,255)},0.2)
        debugPrint("Auto OFF")
    end
end)

local wordlistCard = CreateInfoCard(autoSection, #kataModule .. " kata dimuat", 2)
wordlistCard.TextColor3 = #kataModule > 0 and Color3.fromRGB(100,255,100) or Color3.fromRGB(255,100,100)

-- Status grid (8 cell = 4 baris x 2 kolom)
local statusSection = CreateSection(mainTab, "Status", 2)
local cells = CreateStatusGrid(statusSection, 1)
-- [1]Match [2]Giliran [3]Huruf [4]Tersedia [5]LastWord [6]Count [7]Retry [8]StatusRetry

local function updateStatus()
    pcall(function()
        cells[1].Text = matchActive and "Active" or "Inactive"
        cells[1].TextColor3 = matchActive and Color3.fromRGB(100,255,100) or Color3.fromRGB(255,100,100)

        cells[2].Text = isMyTurn and "Giliran Kamu" or "Lawan"
        cells[2].TextColor3 = isMyTurn and CFG.AccentColor or Color3.fromRGB(200,200,210)

        cells[3].Text = serverLetter ~= "" and string.upper(serverLetter) or "-"
        cells[3].TextColor3 = Color3.fromRGB(255,220,80)

        local w = serverLetter ~= "" and getSmartWords(serverLetter, false) or {}
        cells[4].Text = #w .. " kata"
        cells[4].TextColor3 = #w > 0 and Color3.fromRGB(100,255,100) or Color3.fromRGB(255,150,100)

        cells[5].Text = lastWord
        cells[5].TextColor3 = Color3.fromRGB(180,220,255)

        cells[6].Text = tostring(wordsPlayed)
        cells[6].TextColor3 = Color3.fromRGB(235,235,245)

        -- retry status
        if config.retryEnabled then
            cells[7].Text = "ON (" .. config.maxRetry .. "x)"
            cells[7].TextColor3 = Color3.fromRGB(100,255,100)
        else
            cells[7].Text = "OFF"
            cells[7].TextColor3 = Color3.fromRGB(180,180,190)
        end

        -- status retry aktif
        if autoRunning and retryCount > 0 then
            cells[8].Text = "Retry " .. retryCount .. "/" .. config.maxRetry
            cells[8].TextColor3 = Color3.fromRGB(255,200,80)
        elseif autoRunning then
            cells[8].Text = "Sedang proses..."
            cells[8].TextColor3 = CFG.AccentColor
        else
            cells[8].Text = statusRetry ~= "" and statusRetry or "-"
            cells[8].TextColor3 = statusRetry ~= "" and Color3.fromRGB(255,150,100) or Color3.fromRGB(160,160,175)
        end
    end)
end

-- ========== CONFIG TAB ==========

-- Delay
local delaySection = CreateSection(configTab, "Delay", 0)
local delayToggle, delayIndicator, minDelayInput = CreateToggleWithInput(
    delaySection, "Gunakan Delay", "Min delay (ms)", 1, config.useDelay, config.minDelay
)
delayToggle.MouseButton1Click:Connect(function()
    config.useDelay = not config.useDelay
    if config.useDelay then
        Tween(delayIndicator,{Position=UDim2.new(1,-18,0.5,-8),BackgroundColor3=CFG.AccentColor},0.2)
    else
        Tween(delayIndicator,{Position=UDim2.new(0,2,0.5,-8),BackgroundColor3=Color3.fromRGB(255,255,255)},0.2)
    end
end)
minDelayInput.FocusLost:Connect(function()
    local v = tonumber(minDelayInput.Text)
    if v and v >= 10 and v <= 5000 then config.minDelay = math.floor(v)
    else minDelayInput.Text = tostring(config.minDelay) end
end)

local maxDelayBox = CreateTextBox(delaySection, "Max Delay (ms)", 2, tostring(config.maxDelay), "650")
maxDelayBox.FocusLost:Connect(function()
    local v = tonumber(maxDelayBox.Text)
    if v and v >= 10 and v <= 5000 then config.maxDelay = math.floor(v)
    else maxDelayBox.Text = tostring(config.maxDelay) end
end)

-- Filter kata
local wordSection = CreateSection(configTab, "Filter Kata", 2)
local filterToggle, filterIndicator, minLenInput = CreateToggleWithInput(
    wordSection, "Gunakan Filter Panjang", "Min panjang kata", 1, config.useWordFilter, config.minLength
)
filterToggle.MouseButton1Click:Connect(function()
    config.useWordFilter = not config.useWordFilter
    if config.useWordFilter then
        Tween(filterIndicator,{Position=UDim2.new(1,-18,0.5,-8),BackgroundColor3=CFG.AccentColor},0.2)
    else
        Tween(filterIndicator,{Position=UDim2.new(0,2,0.5,-8),BackgroundColor3=Color3.fromRGB(255,255,255)},0.2)
    end
end)
minLenInput.FocusLost:Connect(function()
    local v = tonumber(minLenInput.Text)
    if v and v >= 1 and v <= 20 then config.minLength = math.floor(v)
    else minLenInput.Text = tostring(config.minLength) end
end)

local maxLenBox = CreateTextBox(wordSection, "Max Panjang Kata", 2, tostring(config.maxLength), "12")
maxLenBox.FocusLost:Connect(function()
    local v = tonumber(maxLenBox.Text)
    if v and v >= 1 and v <= 30 then config.maxLength = math.floor(v)
    else maxLenBox.Text = tostring(config.maxLength) end
end)

-- Retry (toggle + input max retry)
local retrySection = CreateSection(configTab, "Retry Kata Ditolak", 4)
local retryToggle, retryIndicator, maxRetryInput = CreateToggleWithInput(
    retrySection, "Aktifkan Retry", "Max percobaan", 1, config.retryEnabled, config.maxRetry
)
retryToggle.MouseButton1Click:Connect(function()
    config.retryEnabled = not config.retryEnabled
    if config.retryEnabled then
        Tween(retryIndicator,{Position=UDim2.new(1,-18,0.5,-8),BackgroundColor3=CFG.AccentColor},0.2)
    else
        Tween(retryIndicator,{Position=UDim2.new(0,2,0.5,-8),BackgroundColor3=Color3.fromRGB(255,255,255)},0.2)
    end
end)
maxRetryInput.FocusLost:Connect(function()
    local v = tonumber(maxRetryInput.Text)
    if v and v >= 1 and v <= 10 then
        config.maxRetry = math.floor(v)
    else
        maxRetryInput.Text = tostring(config.maxRetry)
    end
end)

local retryInfoCard = CreateInfoCard(retrySection,
    "Jika kata ditolak server, otomatis coba kata lain sampai batas max percobaan", 2)
retryInfoCard.TextColor3 = Color3.fromRGB(150,150,165)
retryInfoCard.TextSize = 10
retryInfoCard.Size = UDim2.new(1,0,0,42)

-- Aggression
local aggressionSection = CreateSection(configTab, "Strategi", 6)
local aggressionBox = CreateTextBox(aggressionSection, "Aggression (0-100)", 1, tostring(config.aggression), "20")
aggressionBox.FocusLost:Connect(function()
    local v = tonumber(aggressionBox.Text)
    if v and v >= 0 and v <= 100 then config.aggression = math.floor(v)
    else aggressionBox.Text = tostring(config.aggression) end
end)

local aggrInfoCard = CreateInfoCard(aggressionSection, "0 = kata terpanjang | 100 = acak total", 2)
aggrInfoCard.TextColor3 = Color3.fromRGB(150,150,165)
aggrInfoCard.TextSize = 10

-- ============================================
-- WINDOW TOGGLE & DRAG
-- ============================================
local IsOpen = false
local function ToggleGUI()
    IsOpen = not IsOpen
    main.Visible = IsOpen
    if IsOpen then
        main.Size = UDim2.new(0,0,0,0)
        main.Position = UDim2.new(0.5,0,0.5,0)
        Tween(main,{Size=CFG.MainSize,Position=UDim2.new(0.5,-220,0.5,-170)},0.3)
    end
end

icon.MouseButton1Click:Connect(ToggleGUI)
minimizeBtn.MouseButton1Click:Connect(ToggleGUI)
exitBtn.MouseButton1Click:Connect(ShowConfirmDialog)

local mainDragging, mainDragStart, mainStartPos
header.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        mainDragging = true; mainDragStart = input.Position; mainStartPos = main.Position
        input.Changed:Connect(function()
            if input.UserInputState == Enum.UserInputState.End then mainDragging = false end
        end)
    end
end)
UserInputService.InputChanged:Connect(function(input)
    if mainDragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
        local d = input.Position - mainDragStart
        main.Position = UDim2.new(mainStartPos.X.Scale, mainStartPos.X.Offset+d.X, mainStartPos.Y.Scale, mainStartPos.Y.Offset+d.Y)
    end
end)

-- ============================================
-- REMOTE EVENTS
-- ============================================
if MatchUI then
    MatchUI.OnClientEvent:Connect(function(cmd, value)
        if cmd == "ShowMatchUI" then
            matchActive = true; isMyTurn = false
            resetUsedWords(); resetTurnState()

        elseif cmd == "HideMatchUI" then
            matchActive = false; isMyTurn = false; serverLetter = ""
            resetUsedWords(); resetTurnState()

        elseif cmd == "StartTurn" then
            isMyTurn = true
            resetTurnState()   -- reset retry state tiap giliran baru mulai
            if autoEnabled and not autoRunning then
                task.spawn(startUltraAI)
            end

        elseif cmd == "EndTurn" then
            isMyTurn = false
            -- kalau AI lagi jalan, state isMyTurn=false akan menghentikan loop typeAndSubmit

        elseif cmd == "UpdateServerLetter" then
            serverLetter = string.lower(value or "")
        end

        updateStatus()
    end)
end

-- UsedWordWarn: kata sudah pernah dipakai, langsung retry tanpa nunggu timer
if UsedWordWarn then
    UsedWordWarn.OnClientEvent:Connect(function(word)
        if word then
            addUsedWord(word)
            -- kalau masih giliran kita dan AI lagi jalan = server tolak kata kita
            -- loop di startUltraAI akan detect isMyTurn masih true dan retry sendiri
            -- tapi kalau AI sudah berhenti (mis: setelah submit), mulai lagi
            if autoEnabled and matchActive and isMyTurn and not autoRunning then
                task.spawn(startUltraAI)
            end
        end
    end)
end

-- Status update loop
task.spawn(function()
    while gui.Parent do
        task.wait(0.5)
        updateStatus()
    end
end)

debugPrint("LOADED OK | Klik ikon untuk buka menu")
