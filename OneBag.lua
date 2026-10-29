
OneCore = AceLibrary("AceAddon-2.0"):new("AceEvent-2.0", "AceModuleCore-2.0", "AceHook-2.0")
local AceLocale = AceLibrary and AceLibrary("AceLocale-2.1")
local L = AceLocale and AceLocale:GetInstance("OneBag") or setmetatable({}, {__index = function(self, key) return key end})
local LC = AceLocale and AceLocale:GetInstance("OneCore", true) or setmetatable({}, {__index = function(self, key) return key end})
local function HasItemLock()
    return ItemLockDB and true or false
end

-- 性能优化：缓存 GetItemInfo 结果（itemID 在会话内不变），避免每次背包更新/整理重复调用昂贵的 API。
-- 统一挂在 OneCore 上，OneBag 主界面与 SortBags 共用同一份缓存，杜绝两份缓存漂移、重复占内存。
OneCore.itemInfoCache = OneCore.itemInfoCache or {}
local function GetItemInfoCached(id)
    id = tonumber(id)
    if not id then return nil end
    local cached = OneCore.itemInfoCache[id]
    if cached then
        return cached[1], cached[2], cached[3], cached[4], cached[5], cached[6], cached[7], cached[8], cached[9]
    end
    local ok, name, link, quality, level, itemType, subType, count, slot, texture = pcall(GetItemInfo, id)
    if ok and name then
        OneCore.itemInfoCache[id] = {name, link, quality, level, itemType, subType, count, slot, texture}
    end
    return name, link, quality, level, itemType, subType, count, slot, texture
end
OneCore.GetItemInfoCached = GetItemInfoCached

-- 灵魂石物品 ID：乌龟服中灵魂石 1 格可叠 3 个，且灵魂袋内还能放置其它召唤恶魔物品，
-- 因此不能按“灵魂袋已占用格数”统计，必须按物品 ID 真实计数（含堆叠）。
local SOUL_STONE_ID = 6265

-- 职业材料统计表：按玩家职业统计对应材料的真实数量（含堆叠），显示在窗口左下信息区。
-- 本客户端 GetItemInfo 不接受裸数字 ID，故显示名走 locals.lua 本地化表（键=英文名，值=中文名），不动态取名。
local CLASS_REAGENTS = {
    WARLOCK = { {16583, "Demonic Figurine"}, {5565, "Infernal Stone"} },
    MAGE    = { {17020, "Arcane Powder"}, {17031, "Rune of Teleportation"}, {17032, "Rune of Portals"} },
    PALADIN = { {21177, "Symbol of Kings"}, {17033, "Holy Symbol"} },
    PRIEST  = { {17029, "Holy Candle"} },
    SHAMAN  = { {17030, "Ankh"} },
    DRUID   = { {17026, "Wild Thornroot"}, {17038, "Ironwood Seed"} },
    ROGUE   = { {5140, "Flash Powder"} },
}

--=============================================================================
-- 材料计数配置层：职业材料逐个开关 + 自定义物品（按物品 ID）
-- 数据统一挂在 OneBag.db.profile 上（背包/银行/OneView 菜单共用同一份设置）：
--   profile.show.reagents[id]      = true/false  职业材料显示开关
--   profile.customReagents         = { itemID, ... }
--   profile.customReagentNames[id] = "物品名"     解析成功后缓存，避免反复调用 GetItemInfo
-- 说明：已移除原先对所有职业强制显示的“公共材料（草药茶）”列表。
--=============================================================================
local function GetReagentProfile()
    if OneBag and OneBag.db and OneBag.db.profile then return OneBag.db.profile end
    return nil
end

local function EnsureReagentTables(p)
    if not p then return nil end
    if type(p.show) ~= "table" then p.show = {} end
    if type(p.show.reagents) ~= "table" then p.show.reagents = {} end
    if type(p.customReagents) ~= "table" then p.customReagents = {} end
    if type(p.customReagentNames) ~= "table" then p.customReagentNames = {} end
    return p
end

-- 职业材料是否显示（默认全部显示）
function OneCore_IsReagentEnabled(id)
    local p = GetReagentProfile()
    local t = p and p.show and p.show.reagents
    if type(t) == "table" and t[id] ~= nil then return t[id] and true or false end
    return true
end

function OneCore_SetReagentEnabled(id, value)
    local p = EnsureReagentTables(GetReagentProfile())
    if not p then return end
    p.show.reagents[id] = value and true or false
    OneCore_InvalidateReagentList()
end

-- 自定义物品列表（数组，元素为数字 ID）
function OneCore_GetCustomReagents()
    local p = EnsureReagentTables(GetReagentProfile())
    if not p then return {} end
    return p.customReagents
end

-- 兜底取名：物品就在背包/银行里时，链接自带名称（本客户端 GetContainerItemLink 可靠带名，
-- 见 ItemLock 实战），直接正则提取，比 GetItemInfo 更稳。不在包里则返回 nil。
function OneCore_FindItemNameInBags(id)
    id = tonumber(id)
    if not id or not GetContainerItemLink then return nil end
    local bags = {0, 1, 2, 3, 4, -1, 5, 6, 7, 8, 9, 10, 11}
    for i = 1, table.getn(bags) do
        local bag = bags[i]
        local num = GetContainerNumSlots(bag) or 0
        for slot = 1, num do
            local link = GetContainerItemLink(bag, slot)
            if link then
                local lid = tonumber(string.match(link, "item:(%d+)"))
                if lid == id then
                    local nm = string.match(link, "%[(.-)%]")
                    if nm and nm ~= "" then return nm end
                end
            end
        end
    end
    return nil
end

-- 本客户端 GetItemInfo 对裸数字 ID 可能报错，故依次尝试
-- “完整超链接 -> 物品串 -> 包内链接 -> 裸数字”，全部 pcall 包裹，任一成功即用。
function OneCore_QueryItemName(id)
    id = tonumber(id)
    if not id then return nil end
    local ok, name = pcall(GetItemInfo, "|cffffffff|Hitem:" .. id .. ":0:0:0|h[item]|h|r")
    if ok and type(name) == "string" and name ~= "" then return name end
    local ok2, name2 = pcall(GetItemInfo, "item:" .. id .. ":0:0:0")
    if ok2 and type(name2) == "string" and name2 ~= "" then return name2 end
    local okBag, fromBag = pcall(OneCore_FindItemNameInBags, id)
    if okBag and fromBag then return fromBag end
    local ok3, name3 = pcall(GetItemInfo, id)
    if ok3 and type(name3) == "string" and name3 ~= "" then return name3 end
    return nil
end

-- 物品未缓存时 GetItemInfo 返回 nil，故失败也要限流重试（每 3 秒最多一次/物品），
-- 名称拿不到时回退显示 "ID:xxxxx"，不会阻塞计数显示。
OneCore._reagentNameRetry = OneCore._reagentNameRetry or {}

function OneCore_GetReagentName(id)
    id = tonumber(id)
    if not id then return "?" end
    local p = EnsureReagentTables(GetReagentProfile())
    if p then
        local cached = p.customReagentNames[id]
        if type(cached) == "string" and cached ~= "" then return cached end
        local now = GetTime()
        local last = OneCore._reagentNameRetry[id] or 0
        if (now - last) >= 3 then
            OneCore._reagentNameRetry[id] = now
            local name = OneCore_QueryItemName(id)
            if name then
                p.customReagentNames[id] = name
                return name
            end
        end
    end
    return "ID:" .. tostring(id)
end

-- 材料列表缓存：DoSlotCounts 每次刷新都要重建该表并对每个自定义物品取名，
-- 但它只在"职业材料开关 / 自定义物品增删 / 物品名解析结果"变化时才需要重建。
-- 签名 = 版本号（开关与增删）+ 职业 + 自定义清单 + 已解析名称快照；
-- 名称快照直接读 customReagentNames（纯表查询，不调 GetReagentName），
-- 因此名称一旦解析成功签名就会变、缓存自动失效；稳态下零 GetReagentName 调用。
OneCore._reagentListVersion = OneCore._reagentListVersion or 0

function OneCore_InvalidateReagentList()
    OneCore._reagentListVersion = (OneCore._reagentListVersion or 0) + 1
end

-- 返回可直接用于计数的材料列表 { {id, name, isFinalName}, ... }（已按开关过滤职业材料）
function OneCore_GetReagentList()
    local p = EnsureReagentTables(GetReagentProfile())
    if not p then return {} end
    local _, englishClass = UnitClass("player")
    local customs = p.customReagents or {}
    local nCustom = table.getn(customs)
    local names = p.customReagentNames or {}

    local sig = tostring(OneCore._reagentListVersion or 0) .. "|" .. tostring(englishClass) .. "|" .. nCustom
    for i = 1, nCustom do
        local cid = customs[i]
        sig = sig .. "|" .. tostring(cid) .. "=" .. tostring(names[cid])
    end

    local cache = OneCore._reagentListCache
    if cache and cache.sig == sig then return cache.list end

    local list = {}
    local classReagents = CLASS_REAGENTS[englishClass]
    if classReagents then
        for i = 1, table.getn(classReagents) do
            if OneCore_IsReagentEnabled(classReagents[i][1]) then
                table.insert(list, classReagents[i])
            end
        end
    end
    local allResolved = true
    for i = 1, nCustom do
        local cid = customs[i]
        if not names[cid] then allResolved = false end
        -- 第 3 项为 true 表示名称已是最终显示名（无需再走本地化表）
        table.insert(list, {cid, OneCore_GetReagentName(cid), true})
    end
    -- 仍有名称未解析（物品未缓存）时不落缓存：下次刷新继续走 GetReagentName 的 3 秒限流重试，
    -- 直到名称写进 customReagentNames（签名随之变化）后才开始命中缓存。
    if allResolved then
        OneCore._reagentListCache = { sig = sig, list = list }
    else
        OneCore._reagentListCache = nil
    end
    return list
end

-- 返回：true=新添加，false=已存在，nil=ID 非法
function OneCore_AddCustomReagent(id)
    id = tonumber(id)
    if not id or id <= 0 then return nil end
    local p = EnsureReagentTables(GetReagentProfile())
    if not p then return nil end
    local list = p.customReagents
    for i = 1, table.getn(list) do
        if list[i] == id then return false end
    end
    table.insert(list, id)
    if not p.customReagentNames[id] then
        local n = OneCore_QueryItemName(id)
        if n then p.customReagentNames[id] = n end
    end
    OneCore_InvalidateReagentList()
    OneCore_RefreshReagentOptions()
    OneCore_RefreshReagentCounts()
    return true
end

function OneCore_RemoveCustomReagent(id)
    id = tonumber(id)
    if not id then return end
    local p = EnsureReagentTables(GetReagentProfile())
    if not p then return end
    local list = p.customReagents
    for i = table.getn(list), 1, -1 do
        if list[i] == id then table.remove(list, i) end
    end
    p.customReagentNames[id] = nil
    OneCore._reagentNameRetry[id] = nil
    OneCore_InvalidateReagentList()
    OneCore_RefreshReagentOptions()
    OneCore_RefreshReagentCounts()
end

function OneCore_ClearCustomReagents()
    local p = EnsureReagentTables(GetReagentProfile())
    if not p then return end
    local list = p.customReagents
    for i = table.getn(list), 1, -1 do table.remove(list, i) end
    p.customReagentNames = {}
    OneCore._reagentNameRetry = {}
    OneCore_InvalidateReagentList()
    OneCore_RefreshReagentOptions()
    OneCore_RefreshReagentCounts()
end

-- 开关/增删自定义物品后立刻重算信息区计数（背包与银行共用 DoSlotCounts）。
-- 只刷新已经布局过的窗口：没跑过 OrganizeFrame 时 slotCount 为 nil，此时重算无意义且会写脏信息区。
function OneCore_RefreshReagentCounts()
    local mods = {OneBag, OneBank}
    for i = 1, 2 do
        local m = mods[i]
        if m and m.frame and m.DoSlotCounts and type(m.slotCount) == "number" then
            pcall(m.DoSlotCounts, m)
        end
    end
end

-- 安全版容器刷新：只更新图标/堆叠/锁定/冷却/可读标志，不触碰 tooltip，
-- 避免整理后高频重绘触发 tooltip 增强插件反复重建导致闪烁。
function OneBag_SafeContainerFrame_Update(frame)
    if not frame or not frame.size then return end
    local id = frame:GetID()
    local name = frame:GetName()
    for slot = 1, frame.size do
        local itemButton = getglobal(name .. "Item" .. slot)
        if itemButton then
            local texture, itemCount, locked, quality, readable = GetContainerItemInfo(id, itemButton:GetID())
            -- 锁定 + texture 为空：保留上一帧图标（不刷空），只置灰；避免把锁定槽定格成空白。
            -- 陈旧锁感知：连续锁定超 5 秒视为锁标志残留 —— 但只有"贴图空 + 链接也没有"
            -- 才是真空槽（清掉已卖物品的幽灵图标）；粘锁且有物（link 还在）保留旧图标。
            local isEmpty = (not texture or texture == "")
            if not (isEmpty and locked) or (OneBag_IsSlotLockStale(itemButton, locked) and OneBag_SlotReallyEmpty(id, itemButton:GetID())) then
                OneBag_SetSlotTexture(itemButton, texture)
                OneBag_SetSlotCount(itemButton, itemCount, OneBag_GetSlotCharges(id, itemButton:GetID(), itemCount))
                if isEmpty then
                    itemButton.hasItem = nil
                else
                    itemButton.hasItem = 1
                end
            end
            -- 统一着色出口：锁定灰 / 白 + 已缓存红染（红染只取缓存，不在这里扫描 tooltip）
            local shadeLink
            if not locked then shadeLink = GetContainerItemLink(id, itemButton:GetID()) end
            OneBag_SetSlotShade(itemButton, locked, shadeLink)
            if not isEmpty then
                if type(ContainerFrame_UpdateCooldown) == "function" then
                    pcall(ContainerFrame_UpdateCooldown, id, itemButton)
                end
            else
                local cooldown = getglobal(name .. "Item" .. slot .. "Cooldown")
                if cooldown then cooldown:Hide() end
            end
            itemButton.readable = readable
        end
    end
end

-- 光标更新：只更新光标，不每帧重设 tooltip。
-- 整理后若仍由原 OnUpdate 驱动，会反复 SetBagItem -> tooltip 内容抖动/闪烁。
--
-- 性能改造：原先 **每个** 物品按钮各挂一个这个 OnUpdate，100+ 个按钮每帧各跑一次 Lua 函数；
-- 而且所有非悬停按钮都会调用 ResetCursor()，哪个按钮最后执行是不确定的，
-- 反而可能把悬停按钮刚设置的读取/出售光标冲掉。
-- 现在整个背包框只跑一个共享 OnUpdate：一次 GetMouseFocus() 定位到当前悬停那一格再处理。
local _obHoveredButton = nil

local function OneBag_UpdateItemCursor(button)
    local bag = button:GetParent():GetID()
    local slot = button:GetID()
    if button.readable or (IsControlKeyDown() and button.hasItem) then
        ShowInspectCursor()
    elseif MerchantFrame and MerchantFrame:IsShown() and MerchantFrame.selectedTab == 1 then
        local texture, _, locked = GetContainerItemInfo(bag, slot)
        if texture and not locked and type(ShowContainerSellCursor) == "function" then
            ShowContainerSellCursor(bag, slot)
        else
            ResetCursor()
        end
    else
        ResetCursor()
    end
    return true
end

-- 共享 OnUpdate：每帧只处理鼠标所在那一格
function OneBag_BagFrame_OnUpdate()
    local button = GetMouseFocus()
    -- 焦点可能落在按钮的子区域（如冷却模型）上，向上找两级
    if button and not button.isOneBagItemButton then button = button:GetParent() end
    if button and not button.isOneBagItemButton then button = button:GetParent() end
    if button and not button.isOneBagItemButton then button = nil end

    if button then
        _obHoveredButton = button
        OneBag_UpdateItemCursor(button)
    elseif _obHoveredButton then
        -- 刚离开物品格：复位一次即可，无需每帧无条件 ResetCursor
        _obHoveredButton = nil
        ResetCursor()
    end
end

-- 兼容旧引用（不再逐按钮挂载）
function OneBag_ItemButton_OnUpdate()
    OneBag_UpdateItemCursor(this)
end

-- 同帧防抖：同一帧内对同一对象(obj)的多次刷新请求合并，在下一帧统一执行 obj[method](arg)，参数去重
local function RequestDebounced(obj, field, method, arg)
    arg = arg or 0
    local d = obj[field]
    if not d then
        d = CreateFrame("Frame")
        d.owner = obj
        d.method = method
        d.pending = {}
        d:SetScript("OnUpdate", function()
            d:Hide()
            local pending = d.pending
            d.pending = {}
            for a in pairs(pending) do
                d.owner[d.method](d.owner, a)
            end
        end)
        obj[field] = d
    end
    d.pending[arg] = true
    d:Show()
end

-- 时间窗节流：与 RequestDebounced 类似，但执行间隔不小于 interval 秒（尾沿触发）。
-- 用于"不知道哪格变了"的低频事件（邮件邮资更新/耐久警报）：这些事件的视觉职责
-- 只有变灰，而 ITEM_LOCK_CHANGED 单格同步已即时覆盖，这里只做 0.25s 一次的兜底。
local function RequestThrottled(obj, field, method, arg, interval)
    local d = obj[field]
    if not d then
        d = CreateFrame("Frame")
        d.owner = obj
        d.method = method
        d.interval = interval
        d.pendingArgs = {}
        d.elapsed = 0
        d:SetScript("OnUpdate", function()
            local df = this
            df.elapsed = df.elapsed + arg1
            if df.elapsed < df.interval then return end
            df.elapsed = 0
            df:Hide()
            local pending = df.pendingArgs
            df.pendingArgs = {}
            for a in pairs(pending) do df.owner[df.method](df.owner, a) end
        end)
        obj[field] = d
    end
    d.pendingArgs[arg or 0] = true
    d:Show()
end

--=============================================================================
-- 帧预算调度器（参考 Guda / Baganator）：将开销大的后台工作分摊到多帧执行，
-- 避免单次操作造成卡顿。每个工作单元在每帧 100ms 预算内执行，超出则推迟到下一帧。
--=============================================================================
local FRAME_BUDGET_SECONDS = 0.1
local _qwLastEntry = 0
local _qwQueue = {}
local _qwFrame = nil
local _qwPaused = false

local function QWReportEntry() _qwLastEntry = GetTime() end
local function QWTimeout() return (GetTime() - _qwLastEntry) > FRAME_BUDGET_SECONDS end

local function QueueWork(callback)
    if type(callback) ~= "function" then return end
    table.insert(_qwQueue, callback)
    if not _qwFrame then
        _qwFrame = CreateFrame("Frame")
        _qwFrame:Hide()
        _qwFrame:SetScript("OnUpdate", function()
            if _qwPaused then return end
            QWReportEntry()
            local processed = 0
            while table.getn(_qwQueue) > 0 and processed < 50 do
                if QWTimeout() then return end
                local work = table.remove(_qwQueue, 1)
                if work then
                    local ok, err = pcall(work)
                    if not ok then DEFAULT_CHAT_FRAME:AddMessage("|cFFFF0000[OneBag] QueueWork error: " .. tostring(err) .. "|r") end
                end
                processed = processed + 1
            end
            if table.getn(_qwQueue) == 0 then _qwFrame:Hide() end
        end)
    end
    _qwFrame:Show()
end

-- 以批处理方式处理 items，每批 batchSize 个，帧预算感知；onComplete 在所有项处理完后调用
local function ProcessWithBudget(items, processor, onComplete, batchSize)
    if not items or table.getn(items) == 0 then
        if onComplete then pcall(onComplete) end
        return
    end
    batchSize = batchSize or 10
    local index = 1
    local total = table.getn(items)
    local function processNextBatch()
        QWReportEntry()
        local count = 0
        while index <= total and count < batchSize do
            if QWTimeout() then
                QueueWork(processNextBatch)
                return
            end
            local item = items[index]
            if item then
                local ok, err = pcall(processor, item, index)
                if not ok then DEFAULT_CHAT_FRAME:AddMessage("|cFFFF0000[OneBag] ProcessWithBudget error: " .. tostring(err) .. "|r") end
            end
            index = index + 1
            count = count + 1
        end
        if index <= total then
            QueueWork(processNextBatch)
        elseif onComplete then
            pcall(onComplete)
        end
    end
    processNextBatch()
end

-- 拖动框架时由 XML 拖拽处理器调用，暂停/恢复后台队列，
-- 以免缓存预热等工作占用每帧预算、拖慢拖拽帧率（参考 Guda 的 PauseWorkQueue/ResumeWorkQueue）。
function OneBag_PauseWorkQueue() _qwPaused = true end
function OneBag_ResumeWorkQueue() _qwPaused = false end

-- 供其它文件使用帧预算队列：SortBags.lua 有独立 fenv（setfenv(1, ...)），
-- 看不到本文件的 local QueueWork，只能通过全局转发。
function OneBag_QueueWork(callback) QueueWork(callback) end

--=============================================================================
-- 整理锁定（sort-lock，参考 Guda 的 slot-lock）：
--   Alt+右键点击物品 → 该物品不参与整理（整理时固定原位、也不接受别的物品搬入），
--   再次 Alt+右键 → 取消。标记以黄色星星显示在物品右上角，类似于“锁定”。
--   按物品名称记录（与 ItemLock 的“按名锁定”一致，与 ItemLock 相互独立、互不干扰），
--   每个角色/服务器一份数据，随存档持久化（见 OneBag.toc 的 SavedVariables）。
--=============================================================================
OneBagSortLockDB = OneBagSortLockDB or {}

-- 会话内缓存 玩家-服务器 key：UnitName/GetRealmName 是 C 侧调用且登录后就不再变，
-- 但整理锁定循环（ToggleSortLock 一次 12 轮）、UpdateLockedItems、中键切换都会反复拼接，
-- 没必要每次重算。
local _oneBagPlayerKey = nil
local function OneBag_GetPlayerKey()
    if not _oneBagPlayerKey then
        _oneBagPlayerKey = UnitName("player") .. "-" .. GetRealmName()
    end
    return _oneBagPlayerKey
end

local function OneBag_GetSortLockTable()
    local playerKey = OneBag_GetPlayerKey()
    if not OneBagSortLockDB[playerKey] then OneBagSortLockDB[playerKey] = {} end
    return OneBagSortLockDB[playerKey]
end

-- 取某槽位物品是否被整理锁定（按物品名称判定，与 ItemLock 的“按名锁定”一致）
function OneBag_IsSortLockedSlot(container, position)
    local link = GetContainerItemLink(container, position)
    if not link then return false end
    local itemName = string.match(link, "%[(.-)%]")
    if not itemName then return false end
    local t = OneBag_GetSortLockTable()
    return t[itemName] or false
end

-- Alt+右键点击物品：切换整理锁定状态，并刷新可见背包/银行框上的星星标记
-- 按物品名称存储锁定（与 ItemLock 完全一致，不调用 GetItemInfo，避免本客户端参数类型报错）
function OneBag_ToggleSortLock(bag, slot)
    local link = GetContainerItemLink(bag, slot)
    if not link then return end
    local itemName = string.match(link, "%[(.-)%]")
    if not itemName then return end
    local t = OneBag_GetSortLockTable()
    if t[itemName] then
        t[itemName] = nil
        DEFAULT_CHAT_FRAME:AddMessage("|cFFFFCC00[OneBag]|r 已取消整理锁定: " .. itemName)
    else
        t[itemName] = true
        DEFAULT_CHAT_FRAME:AddMessage("|cFF00FF00[OneBag]|r 已锁定(不参与整理): " .. itemName)
    end
    -- 刷新可见背包/银行框上的星星标记（按名锁定，星星会跟随物品走）
    for b = -1, 10 do
        if OneBag and OneBag.UpdateSortLocks then pcall(OneBag.UpdateSortLocks, OneBag, b) end
        if OneBank and OneBank.UpdateSortLocks then pcall(OneBank.UpdateSortLocks, OneBank, b) end
    end
end

-- 左键点击「整理锁定」按钮：查看当前角色/服务器的整理锁定列表
function OneBagSortLock_List()
    local t = OneBag_GetSortLockTable()
    local count = 0
    for _ in pairs(t) do count = count + 1 end
    if count == 0 then
        DEFAULT_CHAT_FRAME:AddMessage("|cFFFFCC00[OneBag] 整理锁定列表为空|r")
        return
    end
    DEFAULT_CHAT_FRAME:AddMessage("|cFF00FF00[OneBag] 整理锁定列表 (" .. count .. "):|r")
    for itemName in pairs(t) do
        DEFAULT_CHAT_FRAME:AddMessage("  - " .. tostring(itemName))
    end
end

-- 离线银行：清理其他角色的离线数据（保留本角色，供确认框 OnAccept 调用，避免闭包捕获问题，仿 OneBag_GetSortLockTable 的全局写法）
function OneBag_ClearOtherOfflineData()
    if not OneCore then DEFAULT_CHAT_FRAME:AddMessage("|cFFFF0000[OneBag] OneCore 未加载！|r") return end
    if not OneCore:HasModule("OneView") then DEFAULT_CHAT_FRAME:AddMessage("|cFFFF0000[OneBag] OneView 模块未找到！|r") return end
    local mod = OneCore:GetModule("OneView")
    if not mod then DEFAULT_CHAT_FRAME:AddMessage("|cFFFF0000[OneBag] 无法获取 OneView 模块！|r") return end
    mod:ClearOtherOfflineData()
end

-- 右键点击「整理锁定」按钮：弹出确认框，避免误操作（仿 ItemLock 的解除锁定确认）
function OneBagSortLock_UnlockAll()
    local t = OneBag_GetSortLockTable()
    local count = 0
    for _ in pairs(t) do count = count + 1 end
    if count == 0 then
        DEFAULT_CHAT_FRAME:AddMessage("|cFFFFCC00[OneBag] 没有整理锁定的物品|r")
        return
    end
    -- 复用静态确认框（仿 ItemLock 的 ITEMLOCK_UNLOCK_ALL）
    StaticPopupDialogs["ONEBAG_SORTLOCK_UNLOCK_ALL"] = {
        text = "确定要解除全部 " .. count .. " 个整理锁定吗？\n解除后这些物品将恢复正常参与整理。",
        button1 = "确定解除",
        button2 = "取消",
        OnAccept = function()
            local tt = OneBag_GetSortLockTable()
            for k in pairs(tt) do tt[k] = nil end
            -- 刷新可见背包/银行框上的星星标记（全部移除）
            for b = -1, 10 do
                if OneBag and OneBag.UpdateSortLocks then pcall(OneBag.UpdateSortLocks, OneBag, b) end
                if OneBank and OneBank.UpdateSortLocks then pcall(OneBank.UpdateSortLocks, OneBank, b) end
            end
            DEFAULT_CHAT_FRAME:AddMessage("|cFF00FF00[OneBag] 已去除全部整理锁定 (" .. count .. ")|r")
        end,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
        preferredIndex = 3,
    }
    StaticPopup_Show("ONEBAG_SORTLOCK_UNLOCK_ALL")
end

-- 整理（排序）期间：不再隐藏物品按钮（参考 SUCC-bag），保持物品全程可见，
-- 每次 PickupContainerItem 引发的 BAG_UPDATE 走轻量刷新（UpdateBagSlots，只同步
-- 图标/数量/灰度/冷却），既不掉帧，也不会出现"整包空白 + 结束才弹出"的割裂感。
-- 只禁用鼠标：避免整理途中误点把物品拖走、打断整理模型（整理结束 ShowButtons 恢复）。
-- isSorting 仍然拦住重量级 UpdateBag（布局重建/染色/任务标记等）→ 整理全程零重活。
-- 恢复时仍逐按钮检查 _sortHiddenBySort 标记，兼容任何残留的隐藏状态。
function OneBag_SortHideButtons(frame)
    if not frame then return end
    OneBag_PauseWorkQueue()
    frame.isSorting = true
    for bag = -1, 10 do
        if frame.bags[bag] then
            for slot = 1, frame.bags[bag].size do
                local btn = frame.bags[bag][slot]
                if btn then
                    btn:EnableMouse(false)
                end
            end
        end
    end
end

function OneBag_SortShowButtons(frame)
    if not frame then return end
    frame.isSorting = false
    for bag = -1, 10 do
        if frame.bags[bag] then
            for slot = 1, frame.bags[bag].size do
                local btn = frame.bags[bag][slot]
                if btn then
                    if btn._sortHiddenBySort then
                        btn._sortHiddenBySort = nil
                        btn:Show()
                    end
                    btn:EnableMouse(true)
                end
            end
        end
    end
    OneBag_ResumeWorkQueue()
    if frame.handler and frame.handler.fBags then
        local handler = frame.handler
        for _, b in ipairs(handler.fBags) do
            -- 先强制同步"置灰"标志与当前锁定状态，再完整重绘一次
            -- （顺序很重要：去灰在前，重绘在后，保证不可装备染色最后涂上不被冲掉）。
            -- 这里同步调用而非防抖：整理队列里可能紧接着开始下一次整理（其 HideButtons
            -- 会置 isSorting 拦掉后来才执行的 UpdateBag），延后一帧会丢掉这次完整重绘。
            pcall(OneBag_SortResyncLockVisuals, frame, b)
            pcall(handler.UpdateBag, handler, b, true)
        end
        -- 信息区计数只需全包扫描一次，循环内跳过（见 UpdateBag 的 skipCounts 说明）
        pcall(handler.DoSlotCounts, handler)
    end
end

-- 整理结束后强制把图标"置灰"标志与当前服务器锁定状态同步（移植 SUCC-bag 的 FrameUpdateLock）：
-- 本客户端对服务器锁定（locked）槽位的图标会做置灰（desaturate）处理，
-- 解锁后若没有代码去恢复该标志，图标就一直灰着（"卡灰"）——单靠重绘内容不保证翻回来。
-- 逐槽位读取 locked，SetItemButtonDesaturated 强制归位：仍锁定的保持灰，已解锁的立即恢复彩色。
function OneBag_SortResyncLockVisuals(frame, bag)
    if not frame or not frame.bags or not frame.bags[bag] then return end
    if not SetItemButtonDesaturated then return end
    local bagFrame = frame.bags[bag]
    if not bagFrame.size then return end
    for slot = 1, bagFrame.size do
        local btn = bagFrame[slot]
        if btn then
            local _, _, locked = GetContainerItemInfo(bag, slot)
            -- 统一着色出口：解锁槽恢复白/红染（红染取缓存），而不是一律刷白——
            -- 否则整理结束的红染物品会被这里冲成白色，下一轮又表现成"颜色不对/发灰"
            local shadeLink
            if not locked then shadeLink = GetContainerItemLink(bag, slot) end
            -- 整理结束的强制去灰路径，必须无条件重设（2026.10.27）
            btn._obShadeState = nil
            OneBag_SetSlotShade(btn, locked, shadeLink)
        end
    end
end

--=============================================================================
-- 换装（Outfitter 等）时临时隐藏背包物品图标
-- 现象：换装时 Outfitter 会批量 Pickup/Equip，触发大量 BAG_UPDATE，背包打开时
--       OneBag 逐格重绘物品图标（ContainerFrame_Update）导致明显掉帧；关掉背包则无此问题。
-- 思路：与排序隐藏一致——隐藏物品按钮，并置 frame.isOutfitSwapping 让 UpdateBag 提前返回，
--       换装（含连续换装）全部结束、过一小段宽限期后再显示并一次性完整刷新。
--=============================================================================
local _outfitSwapFrames = {}    -- frame -> true（当前处于隐藏状态）
local _outfitSwapButtons = {}   -- frame -> {btn = true}
local _outfitSwapTimer = nil

local function OneBag_OutfitSwapRestore()
    _outfitSwapTimer = nil

    -- 先清除标志，再显示按钮，最后完整刷新（顺序很重要：刷新时 UpdateBag 才不会被拦截）
    for frame in pairs(_outfitSwapFrames) do
        frame.isOutfitSwapping = false
    end
    for frame, btns in pairs(_outfitSwapButtons) do
        for btn in pairs(btns) do
            if btn then btn:Show() end
        end
    end

    -- 换装结束后一次性完整刷新所有受影响的背包/银行/离线银行
    for _, mod in ipairs({ OneBag, OneBank, OneView }) do
        if mod and mod.frame and mod.frame:IsVisible() and mod.fBags then
            for _, b in ipairs(mod.fBags) do
                pcall(mod.UpdateBag, mod, b, true)
            end
            pcall(mod.DoSlotCounts, mod)
        end
    end

    _outfitSwapFrames = {}
    _outfitSwapButtons = {}
end

-- 换装开始：隐藏当前可见背包/银行/离线银行的物品按钮，并（重新）启动宽限期计时器
function OneBag_OutfitSwapBegin()
    for _, mod in ipairs({ OneBag, OneBank, OneView }) do
        if mod and mod.frame and mod.frame:IsVisible() then
            local frame = mod.frame
            if not _outfitSwapFrames[frame] then
                _outfitSwapFrames[frame] = true
                frame.isOutfitSwapping = true
                _outfitSwapButtons[frame] = {}
            end
            local btns = _outfitSwapButtons[frame]
            for bag = -1, 10 do
                if frame.bags[bag] and frame.bags[bag].size then
                    for slot = 1, frame.bags[bag].size do
                        local btn = frame.bags[bag][slot]
                        if btn and btn:IsShown() then
                            btns[btn] = true
                            btn:Hide()
                        end
                    end
                end
            end
        end
    end

    -- 宽限期：换装（含后续连续换装）全部结束后再显示并刷新。
    -- 连续换装会不断重置计时器，保证图标在整个换装过程中一直隐藏。
    if not _outfitSwapTimer then
        _outfitSwapTimer = CreateFrame("Frame")
        _outfitSwapTimer.elapsed = 0
        _outfitSwapTimer.delay = 0.6
        _outfitSwapTimer:SetScript("OnUpdate", function()
            this.elapsed = this.elapsed + arg1
            if this.elapsed >= this.delay then
                this:SetScript("OnUpdate", nil)
                this:Hide()
                OneBag_OutfitSwapRestore()
            end
        end)
    end
    _outfitSwapTimer.elapsed = 0
    _outfitSwapTimer:Show()
end

-- 让 Outfitter 在真正执行换装（实际发生 Pickup/Equip）时通知 OneBag 隐藏图标。
-- 包裹全局函数 Outfitter_ExecuteEquipmentChangeList / ...2：它们仅在存在实际装备变更列表时
-- 才会被调用，且只在换装/存取衣柜时发生，普通背包操作不会触发，是最精准的“换装进行中”信号。
local function OneBag_WrapOutfitterEquip(pFuncName)
    local orig = _G[pFuncName]
    if type(orig) == "function" then
        local wrapper = function(...)
            OneBag_OutfitSwapBegin()
            return orig(unpack(arg))
        end
        _G[pFuncName] = wrapper
    end
end

function OneBag_HookOutfitter()
    if OneBag_OutfitterHooked then return end
    OneBag_WrapOutfitterEquip("Outfitter_ExecuteEquipmentChangeList")
    OneBag_WrapOutfitterEquip("Outfitter_ExecuteEquipmentChangeList2")
    -- 只要任一装备函数存在即视为已挂钩（幂等，避免重复包裹）
    if type(Outfitter_ExecuteEquipmentChangeList) == "function"
            or type(Outfitter_ExecuteEquipmentChangeList2) == "function" then
        OneBag_OutfitterHooked = true
    end
end

-- 一次性延迟定时器（池化，避免临时框架内存泄漏）
local _timerPool = {}
local function ScheduleTimer(delay, callback)
    local frame = table.remove(_timerPool)
    if not frame then frame = CreateFrame("Frame") end
    frame.elapsed = 0
    frame.delay = delay
    frame.callback = callback
    frame:SetScript("OnUpdate", function()
        this.elapsed = this.elapsed + arg1
        if this.elapsed >= this.delay then
            this:SetScript("OnUpdate", nil)
            this:Hide()
            if table.getn(_timerPool) < 10 then table.insert(_timerPool, this) end
            local ok, err = pcall(this.callback)
            if not ok then DEFAULT_CHAT_FRAME:AddMessage("|cFFFF0000[OneBag] ScheduleTimer error: " .. tostring(err) .. "|r") end
        end
    end)
    frame:Show()
end

--=============================================================================
-- 诊断（临时，2026.10.29）：定位「预热窗口里到底是谁闪了一下」。
-- 用法：/obdbg 开启（写入 profile.dbgShow）→ /reload → 看聊天框。
--
-- 实现说明：**不能用 Lua 覆写 frame.Show/frame.Hide 来挂钩**。1.12 的 C 方法
-- 依赖隐式 `this`，在 Lua 包装里用 `oShow()` 再调出去会变成
-- "Attempt to find 'this' in non-table object"，直接报错 —— 实测把
-- 背包的 Show 和标签条的 Hide 全废了（标签条因此一直亮着）。
-- 改用「预热窗口内逐帧轮询 IsVisible」，只读不改，安全。
--=============================================================================
local _dbgOn = false
local _dbgStart = 0
local _dbgCand = {}          -- 各标签条 buttonFrame（工厂里注册，子框，跟着主框走）
local _dbgWatch = nil        -- { list = {{frame, name}, ...}, seen = {[frame]=bool}, stopAt = 秒 }

local function OneBag_DbgReg(frame, name)
    if frame then table.insert(_dbgCand, { frame = frame, name = name }) end
end

local function OneBag_DbgSay(msg)
    DEFAULT_CHAT_FRAME:AddMessage(string.format("|cFFFF8000[OBDbg]|r %.2fs %s",
        GetTime() - _dbgStart, msg))
end

local _dbgDriver
_dbgDriver = CreateFrame("Frame")
_dbgDriver:SetScript("OnUpdate", function()
    if not _dbgWatch then _dbgDriver:Hide(); return end
    local w = _dbgWatch
    local now = GetTime()
    for _, e in ipairs(w.list) do
        local f, name = e[1], e[2]
        local vis = f:IsVisible()
        if vis and not w.seen[f] then
            w.seen[f] = true
            local top, left = f:GetTop(), f:GetLeft()
            OneBag_DbgSay(string.format("APPEAR %s alpha=%.2f x=%s y=%s warming=%s",
                name, f:GetAlpha(),
                tostring(left and math.floor(left) or "nil"),
                tostring(top and math.floor(top) or "nil"),
                tostring(OneBag and OneBag._warming)))
        elseif not vis then
            w.seen[f] = false
        end
    end
    if now > w.stopAt then
        _dbgWatch = nil
        OneBag_DbgSay("轮询结束")
    end
end)
_dbgDriver:Hide()

-- 预热开始处调用：把候选框当前可见状态记下来，之后谁从"不可见"变成"可见"就报谁
local function OneBag_DbgStartWatch(seconds)
    if not _dbgOn then return end
    local list = {}
    local names = { "OneBagFrame", "OBBagFram", "OneBankFrame", "OBBBagFra",
                    "OneRingFrame", "OneViewFrame" }
    -- 连原生 ContainerFrame 一起盯：预热窗口里 IsBagOpen 对外返回 nil，
    -- 若客户端因此自己把默认背包框放出来，也是一闪的来源
    for i = 1, 5 do table.insert(names, "ContainerFrame" .. i) end
    for _, n in ipairs(names) do
        local f = getglobal(n)
        if f then table.insert(list, { f, n }) end
    end
    for _, e in ipairs(_dbgCand) do table.insert(list, { e.frame, e.name }) end
    local seen = {}
    for _, e in ipairs(list) do seen[e[1]] = e[1]:IsVisible() end
    _dbgWatch = { list = list, seen = seen, stopAt = GetTime() + (seconds or 1.5) }
    _dbgDriver:Show()
end

SlashCmdList["ONEBAG_DBG"] = function()
    if not (OneBag and OneBag.db and OneBag.db.profile) then
        DEFAULT_CHAT_FRAME:AddMessage("|cFFFF0000[OBDbg]|r OneBag 未就绪")
        return
    end
    local p = OneBag.db.profile
    p.dbgShow = not p.dbgShow
    DEFAULT_CHAT_FRAME:AddMessage("|cFFFF8000[OBDbg]|r 预热框体记录已"
        .. (p.dbgShow and "开启" or "关闭") .. "，输入 /reload 生效")
end
SLASH_ONEBAG_DBG1 = "/obdbg"

--=============================================================================
-- 后台缓存预热（参考 Guda 的 CacheWarmer）：登录后把背包物品 GetItemInfo 填满，
-- 物品数据从服务器到达后重渲染可见背包，使首次打开时任务标记/品质着色不因
-- 客户端物品缓存冷启动而缺失。全部经帧预算调度器分摊到多帧，登录瞬间不卡顿。
--=============================================================================
local _warmupStarted = false
local _warmupComplete = false

local function RetintVisibleBags()
    for _, mod in ipairs({ OneBag, OneBank, OneView }) do
        if mod and mod.frame and mod.frame:IsVisible() and mod.fBags then
            for _, b in ipairs(mod.fBags) do
                pcall(mod.UpdateBag, mod, b, true)
            end
            pcall(mod.DoSlotCounts, mod)
        end
    end
end

local function AllBagItemsResolved()
    for _, bag in ipairs({0, 1, 2, 3, 4}) do
        local n = GetContainerNumSlots(bag)
        if n and n > 0 then
            for slot = 1, n do
                if GetContainerItemInfo(bag, slot) then
                    local link = GetContainerItemLink(bag, slot)
                    if link then
                        local id = tonumber(string.match(link, "item:(%d+)"))
                        if id and not GetItemInfo(id) then return false end
                    end
                end
            end
        end
    end
    return true
end

local function WarmupPass()
    local slots = {}
    for _, bag in ipairs({0, 1, 2, 3, 4}) do
        local n = GetContainerNumSlots(bag)
        if n and n > 0 then
            for slot = 1, n do
                if GetContainerItemInfo(bag, slot) then
                    table.insert(slots, {bag, slot})
                end
            end
        end
    end
    if table.getn(slots) == 0 then
        RetintVisibleBags()
        return
    end
    ProcessWithBudget(slots, function(entry)
        local link = GetContainerItemLink(entry[1], entry[2])
        if link then
            local id = tonumber(string.match(link, "item:(%d+)"))
            if id then GetItemInfoCached(id) end
        end
    end, RetintVisibleBags, 8)
end

--=============================================================================
-- 预建背包物品按钮（2026.10.27）
-- 首次打开背包时 BuildFrame 要现场 CreateFrame 80+ 个带模板的按钮
-- （每个含图标贴图 / 数量字体 / 冷却模型 / 两个脚本闭包），这笔开销全砸在
-- "按下背包键"的那一帧上，是最容易感知的一次顿挫。
-- 改成登录后由帧预算队列按背包分批预建（框架此时是隐藏的，看不见，不会闪），
-- 首次打开就只剩布局 + 上色。
-- 只预建随身 5 个背包：银行/离线银行的容器数量随买包装备变化、打开频率也低，不预建。
-- 换包后 size 变化由 BuildFrame 的 curBag.size 比较正常兜住。
local PREBUILD_BAGS = { 0, 1, 2, 3, 4 }
local function PrebuildItemButtons()
    if not (OneBag and OneBag.frame) then return end
    if OneBag.frame:IsVisible() then return end   -- 已经打开着：正常路径会建，别插手
    for index, bagID in ipairs(PREBUILD_BAGS) do
        -- 每个背包错开 0.35s：一个包 16 个模板按钮约 5ms，全堆在一帧里
        -- 登录后也会看到一次顿挫，分开就没有单帧尖峰了。
        ScheduleTimer(3 + (index - 1) * 0.35, function()
            if not (OneBag and OneBag.frame) then return end
            if OneBag.frame:IsVisible() then return end
            QueueWork(function()
                local mod = OneBag
                if not (mod and mod.frame) then return end
                if mod.frame:IsVisible() then return end
                -- BuildFrame 只补建缺失的按钮，新建时它自己会置 needToOrganize，
                -- 首次打开时 OrganizeFrame 才会真正给这些按钮排坐标。
                pcall(mod.BuildFrame, mod, bagID)
            end)
        end)
    end
end

--=============================================================================
-- 预热「真画一次」（2026.10.28；2026.10.29 改为「先挪到屏幕外再画」）
-- 为什么预建还不够：预建只是 CreateFrame，80+ 个按钮的首次绘制、每张图标贴图的
-- 首次上传、边框背景的首次构建，全都发生在「第一次真正被绘制」的那一帧。
-- 实测证据：Lua 侧 OnShow 均 2.5ms，但打开背包时仍有 52~78ms 的帧间隙，
-- 差值全在引擎侧 —— 这笔成本没法在 Lua 里省，只能挪到按背包键之前。
-- 做法（照抄本机 S_ItemTip 装等面板的预热，它不闪）：关掉 SetClampedToScreen，
-- 把整个框挪到屏幕外（y=-2000），alpha 0，真画一帧，下一帧立刻收掉并恢复原锚点。
-- 关键教训一：**只压 alpha 压不住**。0.02 在 1.12 上肉眼照样看得见（加法混合的
-- 边框/图标尤其明显），实测就是「进游戏几秒后背包自己弹出来又消失」；挪到屏外才是根治。
-- 关键教训二（2026.10.29 第二次修）：原来可见窗口长达 0.35 秒 = 约 21 帧，
-- 玩家实测「/reload 不闪、小退进游戏却闪」，说明窗口太长时总有东西漏进画面
-- （顶层独立框不继承主框 alpha，窗口内的异步刷新也能把它们 Show 出来）。
-- 而预热真正需要的只是「第一次被绘制的那一帧」——贴图首次上传、边框构建、
-- 几何提交都在那一帧完成。所以改成**只画 1 帧**：OnUpdate 第 2 帧就 Hide，
-- 可见时间 16~30ms，肉眼抓不到，成本照付。不要再改回固定秒数。
--=============================================================================
-- 预热窗口内要一并压成透明的 OneBag 顶层框。它们都是 parent=UIParent 的独立框，
-- 不继承主框 alpha；其中 OneBankFrame / OneRingFrame 在 XML 里根本没有锚点，
-- 默认就停在屏幕左下角 —— 玩家反馈「闪在左下角」就是它们这一类。
-- 主框自己单独处理（要按 profile.alpha 还原），不放在这里。
-- 分类/品质标签条不用列：它们是 CreateFrame("Frame", nil, owner.frame) 的匿名子框，
-- 继承主框 alpha，主框压 0 它们就跟着没。这里只列真正的顶层独立框。
local WARMUP_ALPHA_FRAMES = {
    "OBBagFram",      -- 背包左侧换包栏（parent=UIParent，锚在 OneBagFrame 左上）
    "OneBankFrame",   -- 银行（parent=UIParent，XML 无锚点 → 默认左下角）
    "OBBBagFra",      -- 银行侧边换包栏
    "OneRingFrame",   -- 戒指/饰品栏
    "OneViewFrame",   -- 离线银行/查看（parent=UIParent）
}

local function WarmupDraw(attempt, force)
    local mod = OneBag
    if not (mod and mod.frame) then return end
    local frame = mod.frame
    if frame:IsVisible() then return end          -- 玩家已经开着：别抢（force 也不抢）
    if frame._warmupDrawn and not force then return end   -- 已经预热过
    -- A/B 开关：/obwarmup 可关掉（profile.warmupDraw == false）；/obwarm 手动强制时无视
    if not force and mod.db and mod.db.profile and mod.db.profile.warmupDraw == false then return end

    -- 物品数据还没全就绪时图标贴图是空的，这时候画一遍等于白跑，等下一次
    attempt = attempt or 0
    if not AllBagItemsResolved() and attempt < 6 then
        ScheduleTimer(1.5, function() WarmupDraw(attempt + 1, force) end)
        return
    end
    frame._warmupDrawn = true
    mod._warmupAborted = nil          -- 清掉可能残留的上一次中断标记

    local profile = mod.db and mod.db.profile
    local realAlpha = (profile and profile.alpha) or 1

    -- 抑制标志：OnShow/OnHide 里的开/关背包音效、标签条/侧边栏刷新都要跳过。
    -- 必须整个可见窗口都保持 true，否则窗口内任何 BAG_UPDATE → Refresh →
    -- UpdateButtons 都会把标签条（独立顶层框，不吃主框 alpha）重新 Show 出来。
    mod._warming = true

    -- 把其余 OneBag 顶层框全部临时压成透明，记下原值等窗口结束再还原。
    -- 这一步是「兜底」：不管窗口内是谁被 Show 出来的，都绝对看不见。
    local alphaBackup = {}
    for _, n in ipairs(WARMUP_ALPHA_FRAMES) do
        local f = getglobal(n)
        if f then
            table.insert(alphaBackup, { f, f:GetAlpha() })
            f:SetAlpha(0)
        end
    end

    frame:SetAlpha(0)
    frame:EnableMouse(false)              -- 这一帧别抢玩家鼠标
    -- 关掉屏幕钳制（挪出屏幕后不会被客户端拉回来）。注意 _baseClamped 缓存也要同步：
    -- OnBaseShow 里是「_baseClamped ~= profile.clamped 才 SetClampedToScreen」，
    -- 光调 SetClampedToScreen 不改缓存，Show() 时会被它按 profile 改回去 ——
    -- 那正是「明明挪到屏外，却闪在屏幕左下角」的原因。
    local prevBaseClamped = mod._baseClamped
    mod._baseClamped = false
    frame:SetClampedToScreen(false)
    if frame.bagFrame then frame.bagFrame:SetClampedToScreen(false) end
    if OneBag_DbgStartWatch then OneBag_DbgStartWatch(0.5) end   -- 诊断：抓窗口内的异动
    pcall(function()
        frame:Show()                      -- 走完整 OnShow：布局/上色/首次绘制全付
        -- OnShow → OnCustomShow 会按 db.profile.point 把框贴回原位，
        -- 所以「挪出屏幕」必须放在 Show() 之后：绘制在帧末发生，这一帧还来得及。
        -- Show 之后再把 clamped 压一次，兜住 OnBaseShow 可能刚做的设置。
        frame:SetClampedToScreen(false)
        frame:ClearAllPoints()
        -- 挪到左下外侧很远（而不是只在正下方 2000）：斜着挪，任何方向上的钳制/边缘
        -- 计算都落不到屏幕里。玩家反馈「闪在左下角」就是被钳回屏幕底部造成的。
        frame:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", -4000, -4000)
        frame:SetAlpha(0)                 -- OnBaseShow 可能重设过 alpha，再压一次
    end)

    -- 只画 1 帧：第 1 次 OnUpdate（本帧开始）返回，让本帧末完成首次绘制；
    -- 第 2 次 OnUpdate 立即 Hide，本帧末就不再画了。可见窗口 ~16ms。
    local frames = 0
    local ticker = CreateFrame("Frame")
    ticker:SetScript("OnUpdate", function()
        frames = frames + 1
        if frames < 2 then return end
        ticker:SetScript("OnUpdate", nil)
        ticker:Hide()
        -- 先还原被临时压透明的其余顶层框（不论是第几帧，哪怕主框没了也要还原）
        for _, e in ipairs(alphaBackup) do e[1]:SetAlpha(e[2]) end
        local f = mod.frame
        if not f then
            mod._baseClamped = prevBaseClamped
            mod._warming = nil
            return
        end
        -- 玩家在窗口里自己开了背包（ToggleBag/OpenBag/CloseBag 会置位），
        -- 那就只恢复外观，不能把他刚打开的背包关掉
        local aborted = mod._warmupAborted
        mod._warmupAborted = nil
        if not aborted then f:Hide() end
        -- 还原锚点：清过 points 就必须自己贴回去，不能指望 OnCustomShow ——
        -- db.profile.point 为 nil（从没拖动过）时它什么都不做，框会掉到左下角
        f:ClearAllPoints()
        local pt = mod.db and mod.db.profile and mod.db.profile.point
        if pt then
            f:SetPoint("TOPLEFT", pt.parent, "BOTTOMLEFT", pt.left, pt.top)
        else
            f:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 400, -300)   -- 与 OneBag.xml 默认锚点一致
        end
        -- 还原屏幕钳制，并把 _baseClamped 缓存写成「当前实际值」，否则预热时
        -- 临时设的 false 会被缓存记成"已经设过"，下次 OnBaseShow 就不再纠正
        local clamped = (mod.db and mod.db.profile and mod.db.profile.clamped) and true or false
        f:SetClampedToScreen(clamped)
        if f.bagFrame then f.bagFrame:SetClampedToScreen(clamped) end
        mod._baseClamped = clamped
        f:SetAlpha(realAlpha)
        f:EnableMouse(true)
        -- 作废 alpha 缓存：万一预热中途出错没恢复，下次开包 OnBaseShow 会重新套用
        -- profile.alpha，兜底避免背包变成"打开了但看不见"。
        mod._baseAlpha = nil
        mod._warming = nil
        if aborted and f:IsVisible() then
            -- 玩家现在能看到背包了：把被压制掉的侧边栏/标签条按正常逻辑补回来
            if f.bagFrame and f.bagFrame.wasShown then
                f.bagFrame:Show()
                f.bagFrame.wasShown = false
            end
            if OneBagCategory then OneBagCategory:UpdateButtons() end
            if OneBagQuality then OneBagQuality:UpdateButtons() end
        end
    end)
    ticker:Show()
end

-- 预热开关（A/B 排查用，1.12 无选项面板依赖）：/obwarmup 切换，持久化到 profile
SlashCmdList["ONEBAG_WARMUPDRAW"] = function()
    if not (OneBag and OneBag.db and OneBag.db.profile) then return end
    local p = OneBag.db.profile
    p.warmupDraw = not (p.warmupDraw ~= false)
    DEFAULT_CHAT_FRAME:AddMessage("|cFF00FF00[OneBag]|r 登录预热真画已"
        .. (p.warmupDraw and "开启" or "关闭") .. "（下次进入游戏生效）")
end
SLASH_ONEBAG_WARMUPDRAW1 = "/obwarmup"

-- 手动立即预热一次（2026.10.29）：/obwarm
-- 正常路径是「进入游戏后 6.5 秒自动跑一次」，但玩家实测 /reload 后不闪、只有小退
-- 进游戏才闪，说明两个入口的时机不一致。有了这个命令，不用反复小退就能验证。
SlashCmdList["ONEBAG_WARMUPNOW"] = function()
    if not (OneBag and OneBag.frame) then
        DEFAULT_CHAT_FRAME:AddMessage("|cFFFF0000[OneBag]|r 还没就绪")
        return
    end
    if OneBag.frame:IsVisible() then
        DEFAULT_CHAT_FRAME:AddMessage("|cFFFF0000[OneBag]|r 背包正开着，先关掉再试")
        return
    end
    OneBag.frame._warmupDrawn = nil
    DEFAULT_CHAT_FRAME:AddMessage("|cFF00FF00[OneBag]|r 正在执行一次预热真画（1 帧，屏外）")
    WarmupDraw(0, true)
end
SLASH_ONEBAG_WARMUPNOW1 = "/obwarm"

local function StartCacheWarmup()
    if _warmupStarted then return end
    _warmupStarted = true
    -- 诊断开关：/obdbg 会写 profile.dbgShow，重新登录时在这里装钩子
    if OneBag and OneBag.db and OneBag.db.profile and OneBag.db.profile.dbgShow then
        _dbgOn = true
        _dbgStart = GetTime()
    end
    for _, delay in ipairs({0.5, 2, 5, 10}) do
        ScheduleTimer(delay, function()
            if _warmupComplete then return end
            WarmupPass()
            if AllBagItemsResolved() then _warmupComplete = true end
        end)
    end
    -- 物品数据基本就绪后再预建按钮：1.5s 起排，每个包再错开 0.35s
    -- （即 3.0s ~ 4.4s 建完，早于玩家通常第一次开背包的时刻）
    ScheduleTimer(1.5, PrebuildItemButtons)
    -- 预建全部走完（4.4s 入队 + 帧预算队列执行）之后再真画一次，
    -- 留 2 秒余量：6.5s 时物品数据通常也已就绪
    ScheduleTimer(6.5, WarmupDraw)
end

-- 全局开关变量 - 初始化为true，后续从数据库加载
local FILTER_MODULES_VISIBLE = true

-- 切换过滤模块显示状态的函数
-- 修改ToggleFilterModulesVisibility函数，使其可以被选项系统调用
function ToggleFilterModulesVisibility(value)
    if value ~= nil then
        FILTER_MODULES_VISIBLE = value
    else
        FILTER_MODULES_VISIBLE = not FILTER_MODULES_VISIBLE
    end
    
    -- 保存到 OneBag 数据库
    if OneBag and OneBag.db then
        OneBag.db.profile.filterModulesVisible = FILTER_MODULES_VISIBLE
    end
    
    -- 更新所有已加载的模块
    if FILTER_MODULES_VISIBLE then
        DEFAULT_CHAT_FRAME:AddMessage("|cFF00FF00[OneBag] 已显示分类过滤模块|r")
        
        -- 更新OneBag模块
        if OneBag and OneBag.frame and OneBag.frame:IsVisible() then
            if OneBagCategory then
                OneBagCategory:UpdateButtons()
            end
            -- Quality模块不做处理，它会自动显示
        end
        
        -- 更新OneBank模块
        if OneBank and OneBank.frame and OneBank.frame:IsVisible() then
            if OneBankCategory then
                OneBankCategory:UpdateButtons()
            end
            -- Quality模块不做处理，它会自动显示
        end
        
        -- 更新OneView模块
        if OneView and OneView.frame and OneView.frame:IsVisible() then
            if OneViewCategory then
                OneViewCategory:UpdateButtons()
            end
            -- Quality模块不做处理，它会自动显示
        end
    else
        DEFAULT_CHAT_FRAME:AddMessage("|cFF00FF00[OneBag] 已隐藏分类过滤模块|r")
        
        -- 隐藏所有Category模块
        if OneBagCategory then
            OneBagCategory:Hide()
        end
        -- 不隐藏Quality模块
        if OneBankCategory then
            OneBankCategory:Hide()
        end
        -- 不隐藏Quality模块
        if OneViewCategory then
            OneViewCategory:Hide()
        end
        -- 不隐藏Quality模块
    end
end

-- 保留斜杠命令，但调用修改后的函数
SlashCmdList["ONEBAG_TOGGLE_FILTERS"] = function() ToggleFilterModulesVisibility() end
SLASH_ONEBAG_TOGGLE_FILTERS1 = "/obtogglefilters"
SLASH_ONEBAG_TOGGLE_FILTERS2 = "/obtf"

function CreateCategoryModule(name)
    local Module = OneCore:NewModule(name, "AceEvent-2.0")
    local L = AceLibrary("AceLocale-2.1"):GetInstance("OneBag")

    local CATEGORY_LIST = {
        { id = "quest", name = "任务", icon = "Interface\\Icons\\INV_Misc_Note_02", priority = 100, color = { 1.0, 0.82, 0.0 } },
        { id = "equipment", name = "装备", icon = "Interface\\Icons\\INV_Chest_Plate01", priority = 90, color = { 0.7, 0.7, 0.9 } },
        { id = "consumable", name = "消耗品", icon = "Interface\\Icons\\INV_Potion_51", priority = 80, color = { 0.4, 0.9, 0.4 } },
        { id = "tradeskill", name = "商业技能", icon = "Interface\\Icons\\Trade_Engineering", priority = 70, color = { 0.9, 0.6, 1.0 } },
        { id = "reagent", name = "材料", icon = "Interface\\Icons\\INV_Fabric_Silk_02", priority = 60, color = { 1.0, 0.9, 0.5 } },
        { id = "container", name = "容器", icon = "Interface\\Icons\\INV_Misc_Bag_08", priority = 50, color = { 0.7, 0.7, 0.7 } },
        { id = "projectile", name = "弹药", icon = "Interface\\Icons\\INV_Ammo_Arrow_01", priority = 40, color = { 0.5, 0.8, 1.0 } },
        { id = "misc", name = "杂项", icon = "Interface\\Icons\\INV_Misc_Bag_10_Green", priority = 10, color = { 0.6, 0.6, 0.6 } },
    }

    local owner
    local buttonFrame
    local buttons
    local activeCategory

    function Module:Embed(parent)
        owner = parent
        self:CreateUI()
        self:RegisterEvents()
    end

    function Module:CreateUI()
        buttonFrame = CreateFrame("Frame", nil, owner.frame)
        if OneBag_DbgReg then OneBag_DbgReg(buttonFrame, tostring(name) .. "-Tabs") end
        buttonFrame:SetWidth(40)
        buttonFrame:SetHeight(300)
        buttonFrame:SetPoint("TOPLEFT", owner.frame, "TOPLEFT", -169, -40)
        buttonFrame:SetFrameStrata("HIGH")
        buttonFrame:Hide()

        buttons = {}
        for i, info in ipairs(CATEGORY_LIST) do
            local btn = CreateFrame("CheckButton", nil, buttonFrame)
            btn:SetWidth(36); btn:SetHeight(36)
            btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")

            if i == 1 then
                btn:SetPoint("TOP", buttonFrame, "TOP", 0, 0)
            else
                btn:SetPoint("TOP", buttons[i - 1], "BOTTOM", 0, -3)
            end

            btn.bg = btn:CreateTexture(nil, "BACKGROUND")
            btn.bg:SetAllPoints()
            btn.bg:SetTexture(0, 0, 0, 0.5)

            btn.normalBorder = btn:CreateTexture(nil, "BORDER")
            btn.normalBorder:SetWidth(40)
            btn.normalBorder:SetHeight(40)
            btn.normalBorder:SetPoint("CENTER", btn, "CENTER", 0, 0)
            btn.normalBorder:SetTexture("Interface\\Buttons\\UI-Quickslot2")
            btn.normalBorder:SetVertexColor(0.5, 0.5, 0.5, 1)

            btn.icon = btn:CreateTexture(nil, "ARTWORK")
            btn.icon:SetWidth(30)
            btn.icon:SetHeight(30)
            btn.icon:SetPoint("CENTER", btn, "CENTER", 0, 0)
            btn.icon:SetTexture(info.icon)
            btn.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

            btn.highlight = btn:CreateTexture(nil, "HIGHLIGHT")
            btn.highlight:SetWidth(40)
            btn.highlight:SetHeight(40)
            btn.highlight:SetPoint("CENTER", btn, "CENTER", 0, 0)
            btn.highlight:SetTexture("Interface\\Buttons\\ButtonHilight-Square")
            btn.highlight:SetBlendMode("ADD")

            btn.border = btn:CreateTexture(nil, "OVERLAY")
            btn.border:SetWidth(64)
            btn.border:SetHeight(64)
            btn.border:SetPoint("CENTER", btn, "CENTER", 0, 0)
            btn.border:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
            btn.border:SetBlendMode("ADD")
            btn.border:SetVertexColor(1, 0.8, 0, 1)
            btn.border:Hide()

            btn.categoryId = info.id
            btn.qualityName = info.name
            btn.qualityColor = info.color
            btn:SetScript("OnClick", function()
                self:OnClick(btn.categoryId)
                for k, v in pairs(buttons) do
                    v.border:Hide()
                end
                if activeCategory == btn.categoryId then
                    btn.border:Show()
                else
                    btn.border:Hide()
                end
            end)
            btn:SetScript("OnEnter", function()
                GameTooltip:SetOwner(btn, "ANCHOR_RIGHT")
                GameTooltip:SetText(btn.qualityName, unpack(btn.qualityColor))
                GameTooltip:AddLine(format("物品数量: %d", self:CountCategoryItems(btn.categoryId)), 0.7, 0.7, 0.7)
                GameTooltip:AddLine("点击：筛选该类型", 0, 1, 0)
                GameTooltip:AddLine("再点：取消筛选", 1, 1, 0)
                GameTooltip:Show()
            end)
            btn:SetScript("OnLeave", function() GameTooltip:Hide() end)

            buttons[i] = btn
        end
    end

    function Module:RegisterEvents()
        self:RegisterEvent("BAG_UPDATE", function() RequestDebounced(self, "refreshDebounce", "Refresh", true) end)
        self:RegisterEvent("BAG_OPEN", function() self:Refresh() end)
        self:RegisterEvent("PLAYER_ENTERING_WORLD", function() self:Refresh() end)
        self:RegisterEvent("BANKFRAME_OPENED", function() self:Refresh() end)
        self:RegisterEvent("MERCHANT_SHOW", function() self:Refresh() end)
        self:RegisterEvent("MAIL_SHOW", function() self:Refresh() end)
        self:RegisterEvent("TRADE_SHOW", function() self:Refresh() end)

        self:RegisterEvent("BANKFRAME_CLOSED", function() self:Refresh() end)
        self:RegisterEvent("MERCHANT_CLOSED", function() self:Refresh() end)
        self:RegisterEvent("MAIL_CLOSED", function() self:Refresh() end)
        self:RegisterEvent("TRADE_CLOSED", function() self:Refresh() end)
    end

    function Module:OnClick(categoryId)
        if activeCategory == categoryId then
            activeCategory = nil
        else
            activeCategory = categoryId
        end

        if owner.GetActiveQuality and owner:GetActiveQuality() then
            owner:SetActiveQuality()
        end
        
        self:UpdateButtons()
        if owner.OrganizeFrame then
            owner:OrganizeFrame(true)
        end
        self:ApplyFilter()
    end

    function Module:HasAnyButtonVisible(counts)
        for _, info in ipairs(CATEGORY_LIST) do
            if (counts[info.id] or 0) > 0 then return true end
        end
        return false
    end

    function Module:Refresh()
        if _G.OneBag_SortInProgress then return end
        if not (owner and owner.frame and owner.frame:IsVisible()) then
            self:Hide(); return
        end
        self:UpdateButtons()
        self:ApplyFilter()
    end

    function Module:Hide()
        if buttonFrame then buttonFrame:Hide() end
    end

    function Module:UpdateButtons()
        if not (owner and owner.frame and owner.frame:IsVisible()) then
            self:Hide()
            return
        end

        -- 预热窗口内不弹标签页：分类/品质标签是独立顶层框，不吃主框的 alpha，
        -- 会在预热那 0.35 秒里整块亮一下再消失
        if owner._warming then buttonFrame:Hide(); return end

        -- 检查全局开关 - 从 OneBag 数据库获取
        local filterVisible = true
        if OneBag and OneBag.db and OneBag.db.profile then
            filterVisible = OneBag.db.profile.filterModulesVisible
        end
        if not filterVisible then
            buttonFrame:Hide()
            return
        end

        -- 修复：检查背包栏位框架是否可见或即将可见，如果是则隐藏分类标签
        if owner.frame.bagFrame and (owner.frame.bagFrame:IsVisible() or owner.frame.bagFrame.wasShown) then
            buttonFrame:Hide()
            return
        end
        
        buttonFrame:Show()
        
        for i, btn in ipairs(buttons) do
            if activeCategory == btn.categoryId then
                btn.border:Show()
            else
                btn.border:Hide()
            end
        end
        
        local width = math.max(table.getn(buttons) * 38 - 2, 50)
        buttonFrame:SetWidth(width)
        
        self:ApplyFilter()
    end

    function Module:BuildCountTable()
        local t = {}
        for _, bagID in ipairs(owner.fBags) do
            local bagFrame = owner.frame.bags[bagID]
            if bagFrame and type(bagFrame) == "table" and bagFrame.size and bagFrame.size > 0 then
                for slot = 1, bagFrame.size do
                    local texture = GetContainerItemInfo(bagID, slot)
                    if texture then
                        local cat = self:GetItemCategory(bagID, slot)
                        t[cat] = (t[cat] or 0) + 1
                    end
                end
            end
        end
        return t
    end

    function Module:GetItemCategory(bagID, slotID)
        local link = GetContainerItemLink(bagID, slotID)
        if not link then return "misc" end
        local _, _, id = strfind(link, "item:(%d+)")
        if not id then return "misc" end
        local name, _, quality, _, itemType, subType = GetItemInfoCached(id)
        if not name then return "misc" end

        if itemType == "Quest" or itemType == "任务" or itemType == "Key" or itemType == "钥匙" then return "quest" end
        if itemType == "Armor" or itemType == "护甲" or itemType == "Weapon" or itemType == "武器" then return "equipment" end
        if itemType == "Consumable" or itemType == "消耗品" or itemType == "Food" or itemType == "食物" or itemType == "Potion" or itemType == "药水" or itemType == "烹饪" then return "consumable" end
        if itemType == "Trade Goods" or itemType == "商业" or itemType == "商品" or itemType == "商业技能" or itemType == "交易商品" or itemType == "Recipe" or itemType == "配方" or itemType == "食谱" then return "tradeskill" end
        if itemType == "Reagent" or itemType == "材料" then return "reagent" end
        if itemType == "Container" or itemType == "容器" or itemType == "Quiver" or itemType == "箭袋" then return "container" end
        if itemType == "Projectile" or itemType == "弹药" then return "projectile" end
        if quality == 0 then return "misc" end
        return "misc"
    end

    function Module:CountCategoryItems(categoryId)
        local counts = self:BuildCountTable()
        return counts[categoryId] or 0
    end

    function Module:ApplyFilter()
        local categoryId = self:GetActiveCategory()
        if not categoryId then
            for _, bagID in ipairs(owner.fBags) do
                local bagFrame = owner.frame.bags[bagID]
                if bagFrame and type(bagFrame) == "table" and bagFrame.size and bagFrame.size > 0 then
                    for slot = 1, bagFrame.size do
                        local btn = bagFrame[slot]
                        if btn then
                            btn:SetAlpha(1)
                        end
                    end
                end
            end
            return
        end

        for _, bagID in ipairs(owner.fBags) do
            local bagFrame = owner.frame.bags[bagID]
            if bagFrame and type(bagFrame) == "table" and bagFrame.size and bagFrame.size > 0 then
                for slot = 1, bagFrame.size do
                    local btn = bagFrame[slot]
                    if btn then
                        local texture = GetContainerItemInfo(bagID, slot)
                        if texture and self:GetItemCategory(bagID, slot) == categoryId then
                            btn:SetAlpha(1)
                        else
                            btn:SetAlpha(0.25)
                        end
                    end
                end
            end
        end
    end

    function Module:GetActiveCategory() return activeCategory end

    function Module:SetActiveCategory() 
        activeCategory = nil 
        self:ApplyFilter()
    end

    return Module
end

function CreateQualityModule(name)
    local Module = OneCore:NewModule(name, "AceEvent-2.0")
    local L = AceLocale and AceLocale:GetInstance("OneBag") or setmetatable({}, {__index = function(self, key) return key end})

    local QUALITY_LIST = {
        { id = 5, name = "传说", color = { r = 1, g = 0.5, b = 0 }, priority = 5 },
        { id = 4, name = "史诗", color = { r = 0.5, g = 0, b = 0.5 }, priority = 4 },
        { id = 3, name = "精良", color = { r = 0, g = 0.5, b = 1 }, priority = 3 },
        { id = 2, name = "优秀", color = { r = 0, g = 1, b = 0 }, priority = 2 },
        { id = 1, name = "普通/粗糙", color = { r = 1, g = 1, b = 1 }, priority = 1 },
    }

    local owner
    local buttonFrame
    local buttons
    local activeQuality

    function Module:Embed(parent)
        owner = parent
        self:CreateUI()
        self:RegisterEvents()
    end

    function Module:CreateUI()
        buttonFrame = CreateFrame("Frame", nil, owner.frame)
        if OneBag_DbgReg then OneBag_DbgReg(buttonFrame, tostring(name) .. "-Tabs") end
        buttonFrame:SetWidth(120)  
        buttonFrame:SetHeight(16)  
        buttonFrame:SetPoint("TOPLEFT", owner.frame, "TOPLEFT", 8, -36)
        buttonFrame:SetFrameStrata("DIALOG")
        buttonFrame:SetFrameLevel(owner.frame:GetFrameLevel()+100)
        buttonFrame:Hide()

        buttons = {}
        for i, info in ipairs(QUALITY_LIST) do
            local btn = CreateFrame("CheckButton", nil, buttonFrame)
            btn:SetWidth(21)  
            btn:SetHeight(21)  
            btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
            btn:SetFrameLevel(buttonFrame:GetFrameLevel() + 1)
            if i == 1 then
                btn:SetPoint("LEFT", buttonFrame, "LEFT", 0, 0)
            else
                btn:SetPoint("LEFT", buttons[i - 1], "RIGHT", 1, 0) 
            end

            btn.bg = btn:CreateTexture(nil, "BACKGROUND")
            btn.bg:SetAllPoints()
            btn.bg:SetTexture("Interface\\AddOns\\OneBag\\media\\BagSlot3")
            btn.bg:SetVertexColor(info.color.r, info.color.g, info.color.b, 1)
            btn.bg:SetAlpha(0.6)

            btn.border = btn:CreateTexture(nil, "OVERLAY")
            btn.border:SetAllPoints()
            btn.border:SetTexture("Interface\\AddOns\\OneBag\\media\\Border")
            btn.border:SetBlendMode("ADD")

            btn.highlightBorder = btn:CreateTexture(nil, "OVERLAY")
            btn.highlightBorder:SetAllPoints()
            btn.highlightBorder:SetTexture("Interface\\AddOns\\OneBag\\media\\Border")
            btn.highlightBorder:SetBlendMode("ADD")
            btn.highlightBorder:SetVertexColor(1, 0.8, 0, 1)
            btn.highlightBorder:Hide()

            btn.highlight = btn:CreateTexture(nil, "HIGHLIGHT")
            btn.highlight:SetAllPoints()
            btn.highlight:SetTexture("Interface\\AddOns\\OneBag\\media\\BagSlot3")
            btn.highlight:SetBlendMode("ADD")
            btn.highlight:SetVertexColor(1, 1, 1, 0.5)

            btn.text = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            btn.text:SetPoint("CENTER", btn, "CENTER", 0, 0)
            btn.text:SetText(string.sub(info.name, 1, 1))
            btn.text:SetTextColor(1, 1, 1)
            btn.text:SetShadowOffset(1, -1)
            btn.text:SetShadowColor(0, 0, 0, 0.8)

            btn.qualityId = info.id
            btn.qualityName = info.name
            btn.qualityColor = info.color

            btn:SetScript("OnClick", function(_, btnName)
                if btnName == "RightButton" then
                    self:OnClick(nil)
                else
                    self:OnClick(btn.qualityId)
                end
            end)

            btn:SetScript("OnEnter", function()
                GameTooltip:SetOwner(btn, "ANCHOR_TOP")
                GameTooltip:SetText(btn.qualityName, btn.qualityColor.r, btn.qualityColor.g, btn.qualityColor.b)
                GameTooltip:AddLine(format("装备数量: %d", self:CountCategoryItems(btn.qualityId)), 0.7, 0.7, 0.7)
                GameTooltip:AddLine("点击：筛选该品质", 0, 1, 0)
                GameTooltip:AddLine("再点：取消筛选", 1, 1, 0)
                GameTooltip:Show()
            end)

            btn:SetScript("OnLeave", function() GameTooltip:Hide() end)

            buttons[i] = btn
        end
    end

    function Module:RegisterEvents()
        self:RegisterEvent("BAG_UPDATE", function() RequestDebounced(self, "refreshDebounce", "Refresh", true) end)
        self:RegisterEvent("BAG_OPEN", function() self:Refresh() end)
        self:RegisterEvent("PLAYER_ENTERING_WORLD", function() self:Refresh() end)
        self:RegisterEvent("BANKFRAME_OPENED", function() self:Refresh() end)
        self:RegisterEvent("MERCHANT_SHOW", function() self:Refresh() end)
        self:RegisterEvent("MAIL_SHOW", function() self:Refresh() end)
        self:RegisterEvent("TRADE_SHOW", function() self:Refresh() end)

        self:RegisterEvent("BANKFRAME_CLOSED", function() self:Refresh() end)
        self:RegisterEvent("MERCHANT_CLOSED", function() self:Refresh() end)
        self:RegisterEvent("MAIL_CLOSED", function() self:Refresh() end)
        self:RegisterEvent("TRADE_CLOSED", function() self:Refresh() end)
    end

    function Module:OnClick(qualityId)
        if activeQuality == qualityId then
            activeQuality = nil
        else
            activeQuality = qualityId
        end

        if owner.GetActiveCategory and owner:GetActiveCategory() then
            owner:SetActiveCategory()
        end

        self:UpdateButtons()
        if owner.OrganizeFrame then
            owner:OrganizeFrame(true)
        end
        self:ApplyFilter()
    end

    function Module:Refresh()
        if _G.OneBag_SortInProgress then return end
        if not (owner and owner.frame and owner.frame:IsVisible()) then
            self:Hide(); return
        end
        self:UpdateButtons()
        self:ApplyFilter()
    end

    function Module:Hide()
        if buttonFrame then buttonFrame:Hide() end
    end

    -- 在Category模块的UpdateButtons函数中，确保正确读取设置：
function Module:UpdateButtons()
    if not (owner and owner.frame and owner.frame:IsVisible()) then
        self:Hide()
        return
    end

    -- 预热窗口内不弹标签页（独立顶层框，不吃主框 alpha）
    if owner._warming then buttonFrame:Hide(); return end

    -- Quality模块始终显示，不检查全局开关
    -- 只检查背包侧边栏是否显示
    if owner.frame.bagFrame and (owner.frame.bagFrame:IsVisible() or owner.frame.bagFrame.wasShown) then
        buttonFrame:Hide()
        return
    end
    
    buttonFrame:Show()
    
    for i, btn in ipairs(buttons) do
        btn.highlightBorder:Hide()
        btn.bg:SetAlpha(0.6)
        if activeQuality == btn.qualityId then
            btn.highlightBorder:Show()
            btn.bg:SetAlpha(1)
        end
    end
    
    self:ApplyFilter()
end

    function Module:BuildCountTable()
        local t = {}
        for _, bagID in ipairs(owner.fBags) do
            local bagFrame = owner.frame.bags[bagID]
            if bagFrame and type(bagFrame) == "table" and bagFrame.size and bagFrame.size > 0 then
                for slot = 1, bagFrame.size do
                    local texture, _, _, quality = GetContainerItemInfo(bagID, slot)
                    if texture then
                        local cat = (quality == 0 and 1) or quality
                        t[cat] = (t[cat] or 0) + 1
                    end
                end
            end
        end
        return t
    end

    function Module:CountCategoryItems(qualityId)
        local counts = self:BuildCountTable()
        return counts[qualityId] or 0
    end

    function Module:ApplyFilter()
        local qualityId = self:GetActiveQuality()
        if not qualityId then
            for _, bagID in ipairs(owner.fBags) do
                local bagFrame = owner.frame.bags[bagID]
                if bagFrame and type(bagFrame) == "table" and bagFrame.size and bagFrame.size > 0 then
                    for slot = 1, bagFrame.size do
                        local btn = bagFrame[slot]
                        if btn then
                            btn:SetAlpha(1)
                        end
                    end
                end
            end
            return
        end

        for _, bagID in ipairs(owner.fBags) do
            local bagFrame = owner.frame.bags[bagID]
            if bagFrame and type(bagFrame) == "table" and bagFrame.size and bagFrame.size > 0 then
                for slot = 1, bagFrame.size do
                    local btn = bagFrame[slot]
                    if btn then
                        local texture, _, _, quality = GetContainerItemInfo(bagID, slot)
                        if texture then
                            local match = (qualityId == 1 and (quality == 0 or quality == 1)) or (quality == qualityId)
                            if match then
                                btn:SetAlpha(1)
                            else
                                btn:SetAlpha(0.25)
                            end
                        else
                            btn:SetAlpha(0.25)
                        end
                    end
                end
            end
        end
    end

    function Module:GetActiveQuality() return activeQuality end

    function Module:SetActiveQuality() 
        activeQuality = nil 
        self:ApplyFilter()
    end

    return Module
end

-- 为OneView创建专用的分类模块
function CreateOneViewCategoryModule(name)
    local Module = OneCore:NewModule(name, "AceEvent-2.0")
    local L = AceLibrary and AceLibrary("AceLocale-2.1"):GetInstance("OneBag") or setmetatable({}, {__index = function(self, key) return key end})

    local CATEGORY_LIST = {
        { id = "quest", name = "任务", icon = "Interface\\Icons\\INV_Misc_Note_02", priority = 100, color = { 1.0, 0.82, 0.0 } },
        { id = "equipment", name = "装备", icon = "Interface\\Icons\\INV_Chest_Plate01", priority = 90, color = { 0.7, 0.7, 0.9 } },
        { id = "consumable", name = "消耗品", icon = "Interface\\Icons\\INV_Potion_51", priority = 80, color = { 0.4, 0.9, 0.4 } },
        { id = "tradeskill", name = "商业技能", icon = "Interface\\Icons\\Trade_Engineering", priority = 70, color = { 0.9, 0.6, 1.0 } },
        { id = "reagent", name = "材料", icon = "Interface\\Icons\\INV_Fabric_Silk_02", priority = 60, color = { 1.0, 0.9, 0.5 } },
        { id = "container", name = "容器", icon = "Interface\\Icons\\INV_Misc_Bag_08", priority = 50, color = { 0.7, 0.7, 0.7 } },
        { id = "projectile", name = "弹药", icon = "Interface\\Icons\\INV_Ammo_Arrow_01", priority = 40, color = { 0.5, 0.8, 1.0 } },
        { id = "misc", name = "杂项", icon = "Interface\\Icons\\INV_Misc_Bag_10_Green", priority = 10, color = { 0.6, 0.6, 0.6 } },
    }

    local owner
    local buttonFrame
    local buttons
    local activeCategory

    function Module:Embed(parent)
        owner = parent
        self:CreateUI()
        self:RegisterEvents()
    end

    function Module:CreateUI()
        buttonFrame = CreateFrame("Frame", nil, owner.frame)
        if OneBag_DbgReg then OneBag_DbgReg(buttonFrame, tostring(name) .. "-Tabs") end
        buttonFrame:SetWidth(40)
        buttonFrame:SetHeight(300)
        buttonFrame:SetPoint("TOPLEFT", owner.frame, "TOPLEFT", -38, -40)
        buttonFrame:SetFrameStrata("HIGH")
        buttonFrame:Hide()

        buttons = {}
        for i, info in ipairs(CATEGORY_LIST) do
            local btn = CreateFrame("CheckButton", nil, buttonFrame)
            btn:SetWidth(36); btn:SetHeight(36)
            btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")

            if i == 1 then
                btn:SetPoint("TOP", buttonFrame, "TOP", 0, 0)
            else
                btn:SetPoint("TOP", buttons[i - 1], "BOTTOM", 0, -3)
            end

            btn.bg = btn:CreateTexture(nil, "BACKGROUND")
            btn.bg:SetAllPoints()
            btn.bg:SetTexture(0, 0, 0, 0.5)

            btn.normalBorder = btn:CreateTexture(nil, "BORDER")
            btn.normalBorder:SetWidth(40)
            btn.normalBorder:SetHeight(40)
            btn.normalBorder:SetPoint("CENTER", btn, "CENTER", 0, 0)
            btn.normalBorder:SetTexture("Interface\\Buttons\\UI-Quickslot2")
            btn.normalBorder:SetVertexColor(0.5, 0.5, 0.5, 1)

            btn.icon = btn:CreateTexture(nil, "ARTWORK")
            btn.icon:SetWidth(30)
            btn.icon:SetHeight(30)
            btn.icon:SetPoint("CENTER", btn, "CENTER", 0, 0)
            btn.icon:SetTexture(info.icon)
            btn.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

            btn.highlight = btn:CreateTexture(nil, "HIGHLIGHT")
            btn.highlight:SetWidth(40)
            btn.highlight:SetHeight(40)
            btn.highlight:SetPoint("CENTER", btn, "CENTER", 0, 0)
            btn.highlight:SetTexture("Interface\\Buttons\\ButtonHilight-Square")
            btn.highlight:SetBlendMode("ADD")

            btn.border = btn:CreateTexture(nil, "OVERLAY")
            btn.border:SetWidth(64)
            btn.border:SetHeight(64)
            btn.border:SetPoint("CENTER", btn, "CENTER", 0, 0)
            btn.border:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
            btn.border:SetBlendMode("ADD")
            btn.border:SetVertexColor(1, 0.8, 0, 1)
            btn.border:Hide()

            btn.categoryId = info.id
            btn.qualityName = info.name
            btn.qualityColor = info.color
            btn:SetScript("OnClick", function()
                self:OnClick(btn.categoryId)
                for k, v in pairs(buttons) do
                    v.border:Hide()
                end
                if activeCategory == btn.categoryId then
                    btn.border:Show()
                else
                    btn.border:Hide()
                end
            end)
            btn:SetScript("OnEnter", function()
                GameTooltip:SetOwner(btn, "ANCHOR_RIGHT")
                GameTooltip:SetText(btn.qualityName, unpack(btn.qualityColor))
                GameTooltip:AddLine(format("物品数量: %d", self:CountCategoryItems(btn.categoryId)), 0.7, 0.7, 0.7)
                GameTooltip:AddLine("点击：筛选该类型", 0, 1, 0)
                GameTooltip:AddLine("再点：取消筛选", 1, 1, 0)
                GameTooltip:Show()
            end)
            btn:SetScript("OnLeave", function() GameTooltip:Hide() end)

            buttons[i] = btn
        end
    end

    function Module:RegisterEvents()
        self:RegisterEvent("PLAYER_ENTERING_WORLD", function() self:Refresh() end)
    end

    function Module:OnClick(categoryId)
        if activeCategory == categoryId then
            activeCategory = nil
        else
            activeCategory = categoryId
        end

        if owner.GetActiveQuality and owner:GetActiveQuality() then
            owner:SetActiveQuality()
        end
        
        self:UpdateButtons()
        if owner.OrganizeFrame then
            owner:OrganizeFrame(true)
        end
        self:ApplyFilter()
    end

    function Module:Refresh()
        if _G.OneBag_SortInProgress then return end
        if not (owner and owner.frame and owner.frame:IsVisible()) then
            self:Hide(); return
        end
        self:UpdateButtons()
        self:ApplyFilter()
    end

    function Module:Hide()
        if buttonFrame then buttonFrame:Hide() end
    end

    -- 在OneViewCategory模块的UpdateButtons函数中做类似修改：
function Module:UpdateButtons()
    if not (owner and owner.frame and owner.frame:IsVisible()) then
        self:Hide()
        return
    end

    -- 预热窗口内不弹标签页（独立顶层框，不吃主框 alpha）
    if owner._warming then buttonFrame:Hide(); return end

    -- 检查全局开关 - 从 OneBag 数据库获取
    local filterVisible = true
    if OneBag and OneBag.db and OneBag.db.profile then
        filterVisible = OneBag.db.profile.filterModulesVisible
    end
    if not filterVisible then
        buttonFrame:Hide()
        return
    end
    
    -- 只检查背包侧边栏是否显示
    if owner.frame.bagFrame and (owner.frame.bagFrame:IsVisible() or owner.frame.bagFrame.wasShown) then
        buttonFrame:Hide()
        return
    end
    
    buttonFrame:Show()
    
    for i, btn in ipairs(buttons) do
        if activeCategory == btn.categoryId then
            btn.border:Show()
        else
            btn.border:Hide()
        end
    end
    
    self:ApplyFilter()
end

    function Module:BuildCountTable()
        local t = {}
        for _, bagID in ipairs(owner.fBags) do
            local bagFrame = owner.frame.bags[bagID]
            if bagFrame and type(bagFrame) == "table" and bagFrame.size and bagFrame.size > 0 then
                for slot = 1, bagFrame.size do
                    local itemId = owner.storage:SlotInfo(owner.faction, owner.charId, bagID, slot)
                    if itemId then
                        local cat = self:GetItemCategory(itemId)
                        t[cat] = (t[cat] or 0) + 1
                    end
                end
            end
        end
        return t
    end

    function Module:GetItemCategory(itemId)
        if not itemId then return "misc" end
        local name, _, quality, _, itemType, subType = GetItemInfoCached(itemId)
        if not name then return "misc" end

        if itemType == "Quest" or itemType == "任务" or itemType == "Key" or itemType == "钥匙" then return "quest" end
        if itemType == "Armor" or itemType == "护甲" or itemType == "Weapon" or itemType == "武器" then return "equipment" end
        if itemType == "Consumable" or itemType == "消耗品" or itemType == "Food" or itemType == "食物" or itemType == "Potion" or itemType == "药水" or itemType == "烹饪" then return "consumable" end
        if itemType == "Trade Goods" or itemType == "商业" or itemType == "商品" or itemType == "商业技能" or itemType == "交易商品" or itemType == "Recipe" or itemType == "配方" or itemType == "食谱" then return "tradeskill" end
        if itemType == "Reagent" or itemType == "材料" then return "reagent" end
        if itemType == "Container" or itemType == "容器" or itemType == "Quiver" or itemType == "箭袋" then return "container" end
        if itemType == "Projectile" or itemType == "弹药" then return "projectile" end
        if quality == 0 then return "misc" end
        return "misc"
    end

    function Module:CountCategoryItems(categoryId)
        local counts = self:BuildCountTable()
        return counts[categoryId] or 0
    end

    function Module:ApplyFilter()
        local categoryId = self:GetActiveCategory()
        if not categoryId then
            for _, bagID in ipairs(owner.fBags) do
                local bagFrame = owner.frame.bags[bagID]
                if bagFrame and type(bagFrame) == "table" and bagFrame.size and bagFrame.size > 0 then
                    for slot = 1, bagFrame.size do
                        local btn = bagFrame[slot]
                        if btn then
                            btn:SetAlpha(1)
                        end
                    end
                end
            end
            return
        end

        for _, bagID in ipairs(owner.fBags) do
            local bagFrame = owner.frame.bags[bagID]
            if bagFrame and type(bagFrame) == "table" and bagFrame.size and bagFrame.size > 0 then
                for slot = 1, bagFrame.size do
                    local btn = bagFrame[slot]
                    if btn then
                        local itemId = owner.storage:SlotInfo(owner.faction, owner.charId, bagID, slot)
                        if itemId and self:GetItemCategory(itemId) == categoryId then
                            btn:SetAlpha(1)
                        else
                            btn:SetAlpha(0.25)
                        end
                    end
                end
            end
        end
    end

    function Module:GetActiveCategory() return activeCategory end

    function Module:SetActiveCategory() 
        activeCategory = nil 
        self:ApplyFilter()
    end

    return Module
end

-- 为OneView创建专用的品质模块
function CreateOneViewQualityModule(name)
    local Module = OneCore:NewModule(name, "AceEvent-2.0")
    local L = AceLocale and AceLocale:GetInstance("OneBag") or setmetatable({}, {__index = function(self, key) return key end})

    local QUALITY_LIST = {
        { id = 5, name = "传说", color = { r = 1, g = 0.5, b = 0 }, priority = 5 },
        { id = 4, name = "史诗", color = { r = 0.5, g = 0, b = 0.5 }, priority = 4 },
        { id = 3, name = "精良", color = { r = 0, g = 0.5, b = 1 }, priority = 3 },
        { id = 2, name = "优秀", color = { r = 0, g = 1, b = 0 }, priority = 2 },
        { id = 1, name = "普通/粗糙", color = { r = 1, g = 1, b = 1 }, priority = 1 },
    }

    local owner
    local buttonFrame
    local buttons
    local activeQuality

    function Module:Embed(parent)
        owner = parent
        self:CreateUI()
        self:RegisterEvents()
    end

    function Module:CreateUI()
        buttonFrame = CreateFrame("Frame", nil, owner.frame)
        if OneBag_DbgReg then OneBag_DbgReg(buttonFrame, tostring(name) .. "-Tabs") end
        buttonFrame:SetWidth(120)  
        buttonFrame:SetHeight(16)  
        buttonFrame:SetPoint("TOPLEFT", owner.frame, "TOPLEFT", 8, -36)
        buttonFrame:SetFrameStrata("DIALOG")
        buttonFrame:SetFrameLevel(owner.frame:GetFrameLevel()+100)
        buttonFrame:Hide()

        buttons = {}
        for i, info in ipairs(QUALITY_LIST) do
            local btn = CreateFrame("CheckButton", nil, buttonFrame)
            btn:SetWidth(21)  
            btn:SetHeight(21)  
            btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
            btn:SetFrameLevel(buttonFrame:GetFrameLevel() + 1)
            if i == 1 then
                btn:SetPoint("LEFT", buttonFrame, "LEFT", 0, 0)
            else
                btn:SetPoint("LEFT", buttons[i - 1], "RIGHT", 1, 0) 
            end

            btn.bg = btn:CreateTexture(nil, "BACKGROUND")
            btn.bg:SetAllPoints()
            btn.bg:SetTexture("Interface\\AddOns\\OneBag\\media\\BagSlot3")
            btn.bg:SetVertexColor(info.color.r, info.color.g, info.color.b, 1)
            btn.bg:SetAlpha(0.6)

            btn.border = btn:CreateTexture(nil, "OVERLAY")
            btn.border:SetAllPoints()
            btn.border:SetTexture("Interface\\AddOns\\OneBag\\media\\Border")
            btn.border:SetBlendMode("ADD")

            btn.highlightBorder = btn:CreateTexture(nil, "OVERLAY")
            btn.highlightBorder:SetAllPoints()
            btn.highlightBorder:SetTexture("Interface\\AddOns\\OneBag\\media\\Border")
            btn.highlightBorder:SetBlendMode("ADD")
            btn.highlightBorder:SetVertexColor(1, 0.8, 0, 1)
            btn.highlightBorder:Hide()

            btn.highlight = btn:CreateTexture(nil, "HIGHLIGHT")
            btn.highlight:SetAllPoints()
            btn.highlight:SetTexture("Interface\\AddOns\\OneBag\\media\\BagSlot3")
            btn.highlight:SetBlendMode("ADD")
            btn.highlight:SetVertexColor(1, 1, 1, 0.5)

            btn.text = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            btn.text:SetPoint("CENTER", btn, "CENTER", 0, 0)
            btn.text:SetText(string.sub(info.name, 1, 1))
            btn.text:SetTextColor(1, 1, 1)
            btn.text:SetShadowOffset(1, -1)
            btn.text:SetShadowColor(0, 0, 0, 0.8)

            btn.qualityId = info.id
            btn.qualityName = info.name
            btn.qualityColor = info.color

            btn:SetScript("OnClick", function(_, btnName)
                if btnName == "RightButton" then
                    self:OnClick(nil)
                else
                    self:OnClick(btn.qualityId)
                end
            end)

            btn:SetScript("OnEnter", function()
                GameTooltip:SetOwner(btn, "ANCHOR_TOP")
                GameTooltip:SetText(btn.qualityName, btn.qualityColor.r, btn.qualityColor.g, btn.qualityColor.b)
                GameTooltip:AddLine(format("装备数量: %d", self:CountCategoryItems(btn.qualityId)), 0.7, 0.7, 0.7)
                GameTooltip:AddLine("点击：筛选该品质", 0, 1, 0)
                GameTooltip:AddLine("再点：取消筛选", 1, 1, 0)
                GameTooltip:Show()
            end)

            btn:SetScript("OnLeave", function() GameTooltip:Hide() end)

            buttons[i] = btn
        end
    end

    function Module:RegisterEvents()
        self:RegisterEvent("PLAYER_ENTERING_WORLD", function() self:Refresh() end)
    end

    function Module:OnClick(qualityId)
        if activeQuality == qualityId then
            activeQuality = nil
        else
            activeQuality = qualityId
        end

        if owner.GetActiveCategory and owner:GetActiveCategory() then
            owner:SetActiveCategory()
        end

        self:UpdateButtons()
        if owner.OrganizeFrame then
            owner:OrganizeFrame(true)
        end
        self:ApplyFilter()
    end

    function Module:Refresh()
        if _G.OneBag_SortInProgress then return end
        if not (owner and owner.frame and owner.frame:IsVisible()) then
            self:Hide(); return
        end
        self:UpdateButtons()
        self:ApplyFilter()
    end

    function Module:Hide()
        if buttonFrame then buttonFrame:Hide() end
    end

   function Module:UpdateButtons()
    if not (owner and owner.frame and owner.frame:IsVisible()) then
        self:Hide()
        return
    end

    -- 预热窗口内不弹标签页（独立顶层框，不吃主框 alpha）
    if owner._warming then buttonFrame:Hide(); return end

    -- Quality模块始终显示，不检查全局开关
    -- 只检查背包侧边栏是否显示
    if owner.frame.bagFrame and (owner.frame.bagFrame:IsVisible() or owner.frame.bagFrame.wasShown) then
        buttonFrame:Hide()
        return
    end
    
    buttonFrame:Show()
    
    for i, btn in ipairs(buttons) do
        btn.highlightBorder:Hide()
        btn.bg:SetAlpha(0.6)
        if activeQuality == btn.qualityId then
            btn.highlightBorder:Show()
            btn.bg:SetAlpha(1)
        end
    end
    
    self:ApplyFilter()
end

    function Module:BuildCountTable()
        local t = {}
        for _, bagID in ipairs(owner.fBags) do
            local bagFrame = owner.frame.bags[bagID]
            if bagFrame and type(bagFrame) == "table" and bagFrame.size and bagFrame.size > 0 then
                for slot = 1, bagFrame.size do
                    local itemId = owner.storage:SlotInfo(owner.faction, owner.charId, bagID, slot)
                    if itemId then
                        local _, _, quality = GetItemInfo(itemId)
                        local cat = (quality == 0 and 1) or quality
                        t[cat] = (t[cat] or 0) + 1
                    end
                end
            end
        end
        return t
    end

    function Module:CountCategoryItems(qualityId)
        local counts = self:BuildCountTable()
        return counts[qualityId] or 0
    end

    function Module:ApplyFilter()
        local qualityId = self:GetActiveQuality()
        if not qualityId then
            for _, bagID in ipairs(owner.fBags) do
                local bagFrame = owner.frame.bags[bagID]
                if bagFrame and type(bagFrame) == "table" and bagFrame.size and bagFrame.size > 0 then
                    for slot = 1, bagFrame.size do
                        local btn = bagFrame[slot]
                        if btn then
                            btn:SetAlpha(1)
                        end
                    end
                end
            end
            return
        end

        for _, bagID in ipairs(owner.fBags) do
            local bagFrame = owner.frame.bags[bagID]
            if bagFrame and type(bagFrame) == "table" and bagFrame.size and bagFrame.size > 0 then
                for slot = 1, bagFrame.size do
                    local btn = bagFrame[slot]
                    if btn then
                        local itemId = owner.storage:SlotInfo(owner.faction, owner.charId, bagID, slot)
                        if itemId then
                            local _, _, quality = GetItemInfo(itemId)
                            local match = (qualityId == 1 and (quality == 0 or quality == 1)) or (quality == qualityId)
                            if match then
                                btn:SetAlpha(1)
                            else
                                btn:SetAlpha(0.25)
                            end
                        else
                            btn:SetAlpha(0.25)
                        end
                    end
                end
            end
        end
    end

    function Module:GetActiveQuality() return activeQuality end

    function Module:SetActiveQuality() 
        activeQuality = nil 
        self:ApplyFilter()
    end

    return Module
end

function OneCore:OnInitialize()
    -- 银行主容器(-1)悬停 tooltip 现已通过 BuildFrame 里对 -1 使用 OneBankItemButtonTemplate
    -- （继承 BankItemButtonGenericTemplate，OnEnter → BankFrameItemButton_OnEnter → SetInventoryItem
    -- 正确解析 -1，且幂等不会重复追加行）彻底解决，不再需要全局拦截 GameTooltip.SetBagItem。
    -- 早期用 SetBagItem(-1) + SetHyperlink 拦截的方案会触发"已有幻化"等 post-hook 行被每帧重入
    -- 累加成两行，已废弃。

    self:Hook("BankFrame_OnEvent", function(event) 
        if self:HasModule("OneBank") then
            local module = self:GetModule("OneBank")
            if not module or not module:IsActive() then
                self.hooks.BankFrame_OnEvent.orig(event)
            end
        end
    end)
    
    self:Hook("GetContainerNumSlots", function(id)
        if not id then error("Usage is GetContainerNumSlots(bagID)", 2) end
        if id == -2 then
            return GetKeyRingSize()
        else
            return self.hooks.GetContainerNumSlots.orig(id)
        end
    end)
    
    self.modulePrototype.colWidth = 39
    self.modulePrototype.rowHeight = 39
    self.modulePrototype.topBorder = 24
    self.modulePrototype.bottomBorder = 24
    self.modulePrototype.rightBorder = 5
    self.modulePrototype.leftBorder = 8
    self.modulePrototype.stratas = {"LOW", "MEDIUM", "HIGH", "DIALOG", "FULLSCREEN", "FULLSCREEN_DIALOG", "TOOLTIP"}
end

function OneCore:GetDefaults()
    if not self.defaults then
        self.defaults = {
            cols = 8,
            scale = 1,
            alpha = 1,
            colors = {
                mouseover = {r = 0, g = .7, b = 1},
                ammo = {r = 1, g = 1, b = 0},
                soul = {r = .5, g = .5, b = 1},
                prof = {r = 1, g = 0, b = 1},
                bground = {r = 0, g = 0, b = 0, a = .45},
                glow = false,
                rarity = true,
                unusable = {r = 1, g = 0.1, b = 0.1},  -- 不可装备物品染色颜色（默认红）
            },
            show = {['*'] = true, reagents = {['*'] = true}},
            -- 自定义材料：按物品 ID 追加计数，显示在窗口左下信息区
            customReagents = {},
            customReagentNames = {},
            unusableTint = true,  -- 不可装备物品染色（参考 pfUI unusable.lua）
            strata = 3,
            locked = false,
            clamped = true,
            confirmCleanup = true,
            -- 整理速度：不放默认值 —— 留空（nil）时由 SortBags.GetSortInterval 按客户端
            -- 选择默认（常规 0.05 / 乌龟服 1.2）。若此处写死 0.05，乌龟服的慢速防卡灰
            -- 默认会被存档默认值覆盖，永远不生效。
            bagBreak = false,
            vAlign = L["Top"] or "Top",
        }
    end
    return self.defaults
end

function OneCore:GetFreshOptionsTable(module)
    local self = module
    local opts = {
        type="group", 
        args = {
            frame = {
                name = L["Frame"], type = 'group',
                desc = L["Frame Options"], order = 2,
                args = {
                    cols = { 
                        name = L["Columns"], type = "range", step = 1,
                        desc = L["Sets the number of columns to use"], 
                        get = function() return self.db.profile.cols end, 
                        set = function(num) 
                            self.db.profile.cols = num
                            self:OrganizeFrame(true)
                        end, 
                        min = 5, max = 32,
                    },
                    scale = { 
                        name = L["Scale"], type = "range", 
                        desc = L["Sets the scale of the frame"], 
                        get = function() return self.db.profile.scale end, 
                        set = function(num) 
                            self.db.profile.scale = num
                            self.frame:SetScale(num)
                            if self.frame.bagFrame then
                                self.frame.bagFrame:SetScale(num)
                            end
                        end, 
                        min = .2, max = 2, isPercent = true,
                    },
                    strata = { 
                        name = L["Strata"], type = "range", 
                        desc = L["Sets the strata of the frame"], 
                        get = function() return self.db.profile.strata end, 
                        set = function(num) 
                            self.db.profile.strata = num
                            self.frame:SetFrameStrata(self.stratas[num])
                            if self.frame.bagFrame then
                                self.frame.bagFrame:SetFrameStrata(self.stratas[num])
                            end
                            StackSplitFrame:SetFrameStrata(self.stratas[num+1])
                        end, 
                        min = 1, max = 5, step = 1,
                    },
                    bagbreak = { 
                        name = L["Bag Break"], type = "toggle",
                        desc = L["Sets wether to start a new row at the beginning of a bag."], 
                        get = function() return self.db.profile.bagBreak end, 
                        set = function(value) 
                            self.db.profile.bagBreak = value
                            self:OrganizeFrame(true)
                        end, 
                    },
                    valign = { 
                        name = L["Vertical Alignment"], type = "text",
                        desc = L["Sets wether to have the extra spaces on the top or bottom."], 
                        get = function() return self.db.profile.vAlign end, 
                        set = function(value) 
                            self.db.profile.vAlign = value
                            self:OrganizeFrame(true)
                        end,
                        validate = {L["Top"], L["Bottom"]}
                    },
                    alpha = { 
                        name = L["Alpha"], type = "range", 
                        desc = L["Sets the alpha of the frame"], 
                        get = function() return self.db.profile.alpha end, 
                        set = function(num) 
                            self.db.profile.alpha = num
                            self.frame:SetAlpha(num)
                            if self.frame.bagFrame then
                                self.frame.bagFrame:SetAlpha(num)
                            end
                        end, 
                        min = .05, max = 1, isPercent = true,
                    },
                    locked = {
                        name = L["Locked"], type = 'toggle',
                        desc = L["Toggles the ability to move the frame"],
                        get = function() return self.db.profile.locked end,
                        set = function(v) self.db.profile.locked = v end,
                    },
                    clamped = {
                        name = L["Clamped"], type = 'toggle',
                        desc = L["Toggles the ability to drag the frame off screen."],
                        get = function() return self.db.profile.clamped end,
                        set = function(v) 
                            self.db.profile.clamped = v 
                            if self.frame then
                                self.frame:SetClampedToScreen(v)
                            end
                            if self.frame and self.frame.bagFrame then
                                self.frame.bagFrame:SetClampedToScreen(v)
                            end
                        end,
                    }, 
                    confirmCleanup = {
                        name = L["Confirm Cleanup"], type = 'toggle', order = 50,
                        desc = L["Toggles wether to show a confirmation dialog before cleaning/sorting."],
                        get = function() return (OneBag and OneBag.db and OneBag.db.profile and OneBag.db.profile.confirmCleanup) end,
                        set = function(v) if OneBag and OneBag.db and OneBag.db.profile then OneBag.db.profile.confirmCleanup = v end end,
                    },
                    sortInterval = {
                        name = "整理速度", type = 'range', order = 51, step = 0.05,
                        desc = "整理时每轮搬移的间隔（秒）。常规服默认 0.05（最快）；乌龟服默认 1.2、下限 0.5（服务器锁定可持续 2-3 秒，节奏太快会撞锁定窗口导致图标卡灰）。调大可放慢整理过程。",
                        get = function()
                            local turtle = TargetHPText ~= nil and TargetHPPercText ~= nil
                            local v = OneBag and OneBag.db and OneBag.db.profile and OneBag.db.profile.sortInterval
                            if type(v) ~= 'number' then v = turtle and 1.2 or 0.05 end
                            if turtle and v < 0.5 then v = 0.5 end
                            if v < 0.05 then v = 0.05 end
                            if v > 1.5 then v = 1.5 end
                            return v
                        end,
                        set = function(v)
                            local turtle = TargetHPText ~= nil and TargetHPPercText ~= nil
                            local minV = turtle and 0.5 or 0.05
                            if v < minV then v = minV end
                            if v > 1.5 then v = 1.5 end
                            if OneBag and OneBag.db and OneBag.db.profile then OneBag.db.profile.sortInterval = v end
                        end,
                        min = (TargetHPText ~= nil and TargetHPPercText ~= nil) and 0.5 or 0.05, max = 1.5,
                    },
                }
            },
            show = {
                name = L["Show"], type = 'group', order = 3,
                desc = L["Various Display Options"],
                args = {
                    counts = {
                        name = L["Counts"], type = 'toggle', order = 1,
                        desc = L["Toggles showing the counts for special bags."],
                        get = function() return self.db.profile.show.counts end,
                        set = function(v) 
                            self.db.profile.show.counts = v 
                            if self.DoBankSlotCounts then
                                self:DoBankSlotCounts()
                                self:DoInventorySlotCounts()
                            else
                                self:DoSlotCounts()
                            end
                        end,
                    },
                    direction = {
                        cmdName = L["Direction"], guiName = L["Forward"], type = 'toggle', order = 2,
                        desc = L["Toggles direction the bags are shown"],
                        get = function() return self.db.profile.show.direction end,
                        set = function(v) 
                            self.db.profile.show.direction = v 
                            self:OrganizeFrame(true)
                        end,
                        map = {[false] = L["|cffff0000Reverse|r"], [true] = L["|cff00ff00Forward|r"]}
                    },
                    ammo = {
                        name = L["Ammo Bag"], type = 'toggle', order = 3,
                        desc = L["Turns display of ammo bags on and off."],
                        get = function() return self.db.profile.show.ammo end,
                        set = function(v) 
                            self.db.profile.show.ammo = v 
                            self:OrganizeFrame(true)
                        end,
                    },
                    soul = {
                        name = L["Soul Bag"], type = 'toggle', order = 4,
                        desc = L["Turns display of soul bags on and off."],
                        get = function() return self.db.profile.show.soul end,
                        set = function(v) 
                            self.db.profile.show.soul = v 
                            self:OrganizeFrame(true)
                        end,
                    },
                    prof = {
                        name = L["Profession Bag"], type = 'toggle', order = 4.5,
                        desc = L["Turns display of profession bags on and off."],
                        get = function() return self.db.profile.show.prof end,
                        set = function(v) 
                            self.db.profile.show.prof = v 
                            self:OrganizeFrame(true)
                        end,
                    },
                   filtermodules = {
                        name = L["Category Filters"] , type = 'toggle', order = 100,
                        desc = L["Toggles visibility of category filter modules"] ,
                        get = function() 
                            -- 从OneBag数据库获取设置
                            if OneBag and OneBag.db and OneBag.db.profile then
                                return OneBag.db.profile.filterModulesVisible
                            end
                            return true  -- 默认显示
                        end,
                        set = function(v) 
                            ToggleFilterModulesVisibility(v)
                        end,
                    },
                    -- “不可装备物品”开关已移至“颜色”组（含可配置染色颜色）
                }
            },
            colors = {
                name = L["Colors"], type = 'group', order = 1,
                desc = L["Different color code settings."],
                args = {
                    mouseover = {
                        name = L["Mouseover Color"], type = "color", order = 1,
                        desc = L["Changes the highlight color for when you mouseover a bag slot."],
                        get = function() local color = self.db.profile.colors.mouseover; return color.r, color.g, color.b end,
                        set = function(r, g, b) self.db.profile.colors.mouseover = {r = r, g = g, b = b} end,
                    },
                    ammo = {
                        name = L["Ammo Bag Color"], type = "color", order = 2,
                        desc = L["Changes the highlight color for Ammo Bags."],
                        get = function() local color = self.db.profile.colors.ammo; return color.r, color.g, color.b end, 
                        set = function(r, g, b) 
                            self.db.profile.colors.ammo = {r = r, g = g, b = b} 
                            for k, bag in self.fBags do
                                if self.frame.bags[bag] then
                                    for k, v in ipairs(self.frame.bags[bag]) do self:SetBorderColor(v) end
                                end
                            end
                        end,
                    },
                    soul = {
                        name = L["Soul Bag Color"], type = "color", order = 3,
                        desc = L["Changes the highlight color for Soul Bags."],
                        get = function() local color = self.db.profile.colors.soul; return color.r, color.g, color.b end,
                        set = function(r, g, b) 
                            self.db.profile.colors.soul = {r = r, g = g, b = b} 
                            for k, bag in self.fBags do
                                if self.frame.bags[bag] then
                                    for k, v in ipairs(self.frame.bags[bag]) do self:SetBorderColor(v) end
                                end
                            end
                        end,
                    },
                    prof = {
                        name = L["Profession Bag Color"], type = "color", order = 4,
                        desc = L["Changes the highlight color for Profession Bags."],
                        get = function() local color = self.db.profile.colors.prof; return color.r, color.g, color.b end,
                        set = function(r, g, b) 
                            self.db.profile.colors.prof = {r = r, g = g, b = b} 
                            for k, bag in self.fBags do
                                if self.frame.bags[bag] then
                                    for k, v in ipairs(self.frame.bags[bag]) do self:SetBorderColor(v) end
                                end
                            end
                        end,
                    },
                    background = {
                        name = L["Background Color"], type = "color", order = 5,
                        desc = L["Changes the background color for the frame."],
                        get = function() local color = self.db.profile.colors.bground; return color.r, color.g, color.b, color.a end,
                        set = function(r, g, b, a) 
                            self.db.profile.colors.bground = {r = r, g = g, b = b, a = a} 
                            self.frame:SetBackdropColor(r, g, b, a)
                            if self.frame.bagFrame then
                                self.frame.bagFrame:SetBackdropColor(r, g, b, a)
                            end
                        end, hasAlpha = true,
                    },
                    glow = {
                        name = L["Highlight Glow"], type = 'toggle', order = 6,
                        desc = L["Turns hightlight glow on and off."],
                        get = function() return self.db.profile.colors.glow end,
                        set = function(v) 
                            self.db.profile.colors.glow = v 
                            for k, bag in self.fBags do
                                if self.frame.bags[bag] then
                                    for k, v in ipairs(self.frame.bags[bag]) do self:SetBorderColor(v) end
                                end
                            end
                        end,
                    },
                    rarity = {
                        name = L["Rarity Coloring"], type = 'toggle', order = 7,
                        desc = L["Turns rarity coloring on and off."],
                        get = function() return self.db.profile.colors.rarity end,
                        set = function(v)
                            self.db.profile.colors.rarity = v
                            for k, bag in self.fBags do
                                if self.frame.bags[bag] then
                                    for k, v in ipairs(self.frame.bags[bag]) do self:SetBorderColor(v) end
                                end
                            end
                        end,
                    },
                    unusable = {
                        name = "不可装备染色", type = 'toggle', order = 8,
                        desc = "开启后，当前角色无法装备/使用的物品图标按下方颜色染色（全局开关，银行/钥匙扣共用）。",
                        get = function()
                            if OneBag and OneBag.db and OneBag.db.profile then
                                return OneBag.db.profile.unusableTint
                            end
                            return true
                        end,
                        set = function(v)
                            if OneBag and OneBag.db and OneBag.db.profile then
                                OneBag.db.profile.unusableTint = v
                            end
                            -- 立即按新开关重染当前可见背包/银行
                            OneCore._unusableCache = nil
                            if OneBag and OneBag.frame then
                                for _, b in ipairs(OneBag.fBags) do OneBag:UpdateBag(b, true) end
                                OneBag:DoSlotCounts()
                            end
                            if OneBank and OneBank.frame then
                                for _, b in ipairs(OneBank.fBags) do OneBank:UpdateBag(b, true) end
                                OneBank:DoSlotCounts()
                            end
                        end,
                    },
                    unusableColor = {
                        name = "不可装备颜色", type = "color", order = 9,
                        desc = "不可装备/使用物品图标的染色颜色（即时生效）。",
                        get = function()
                            -- 旧存档无 colors.unusable 时回退默认红（注意：此处不能引用文件后部的 local UNUSABLE_TINT——5.0 前向引用会取到全局 nil）
                            local c = OneBag and OneBag.db and OneBag.db.profile and OneBag.db.profile.colors and OneBag.db.profile.colors.unusable
                            if not c then c = {r = 1, g = 0.1, b = 0.1} end
                            return c.r, c.g, c.b
                        end,
                        set = function(r, g, b)
                            if OneBag and OneBag.db and OneBag.db.profile then
                                if not OneBag.db.profile.colors then OneBag.db.profile.colors = {} end
                                OneBag.db.profile.colors.unusable = {r = r, g = g, b = b}
                            end
                            -- 立即用新颜色重染当前可见背包/银行
                            if OneBag and OneBag.frame then
                                for _, bag in ipairs(OneBag.fBags) do OneBag:UpdateBag(bag, true) end
                                OneBag:DoSlotCounts()
                            end
                            if OneBank and OneBank.frame then
                                for _, bag in ipairs(OneBank.fBags) do OneBank:UpdateBag(bag, true) end
                                OneBank:DoSlotCounts()
                            end
                        end,
                    },
                    reset = {
                        name = L['Reset'], type = 'group', order = -1,
                        desc = L["Reset the different colors."],
                        args = {
                            mouseover = {
                                name = L["Mouseover Color"], type = "execute",
                                desc = L["Returns your mouseover color to the default."],
                                func = function() self.db.profile.colors.mouseover = {r = 0, g = .7, b = 1} end, order = 1
                            },
                            ammo = {
                                name = L["Ammo Slot Color"], type = "execute",
                                desc = L["Returns your ammo slot color to the default."],
                                func = function() 
                                    self.db.profile.colors.ammo = {r = 1, g = 1, b = 0}
                                    for k, bag in self.fBags do
                                        if self.frame.bags[bag] then
                                            for k, v in ipairs(self.frame.bags[bag]) do self:SetBorderColor(v) end
                                        end
                                    end
                                end, order = 2
                            },
                            soul = {
                                name = L["Soul Slot Color"], type = "execute",
                                desc = L["Returns your soul slot color to the default."],
                                func = function() 
                                    self.db.profile.colors.soul = {r = .5, g = .5, b = 1}
                                    for k, bag in self.fBags do
                                        if self.frame.bags[bag] then
                                            for k, v in ipairs(self.frame.bags[bag]) do self:SetBorderColor(v) end
                                        end
                                    end
                                end, order = 3
                            },
                            prof = {
                                name = L["Profession Slot Color"], type = "execute",
                                desc = L["Returns your profession slot color to the default."],
                                func = function() 
                                    self.db.profile.colors.prof = {r = 1, g = 0, b = 1}
                                    for k, bag in self.fBags do
                                        if self.frame.bags[bag] then
                                            for k, v in ipairs(self.frame.bags[bag]) do self:SetBorderColor(v) end
                                        end
                                    end
                                end, order = 4
                            },
                            background = {
                                name = L["Background"], type = "execute",
                                desc = L["Returns your frame background to the default."],
                                func = function() 
                                    self.db.profile.colors.bground = {r = 0, g = 0, b = 0, a = .45}  
                                    self.frame:SetBackdropColor(0, 0, 0, .45)
                                    if self.frame.bagFrame then self.frame.bagFrame:SetBackdropColor(0, 0, 0, .45) end
                                end, order = 5
                            }
                        }
                    }
                }
            },
            -- 材料计数：职业材料逐个开关 + 自定义物品（按 ID 添加）
            reagents = {
                name = L["Reagent Counts"], type = 'group', order = 2.5,
                desc = L["Choose which reagent counts are shown in the info area."],
                args = {},
            },
        }
    }
    -- 分组内容由 BuildReagentOptions 填充（背包/银行/OneView 三份菜单各自持有一份，
    -- 统一登记到 OneCore.reagentArgsList，增删自定义物品时一起刷新）
    OneCore:BuildReagentOptions(opts.args.reagents.args, module)
    return opts
end

--=============================================================================
-- 材料计数菜单构建
-- 注意：Dewdrop 在每次展开分组时才读取 args，因此这里清空后重填即刻生效；
--      菜单项里的“当前数量”来自 OneBag.lastReagentCounts（DoSlotCounts 时缓存）。
--=============================================================================
OneCore.reagentArgsList = OneCore.reagentArgsList or {}

function OneCore:BuildReagentOptions(args, module)
    if type(args) ~= "table" then return end
    -- 去重登记
    local exists = false
    for i = 1, table.getn(self.reagentArgsList) do
        if self.reagentArgsList[i] == args then exists = true end
    end
    if not exists then table.insert(self.reagentArgsList, args) end
    OneCore_RefreshReagentOptions()
end

-- 清空并重建所有已登记菜单的“材料计数”分组
function OneCore_RefreshReagentOptions()
    local list = OneCore.reagentArgsList
    if type(list) ~= "table" then return end
    for n = 1, table.getn(list) do
        local args = list[n]
        if type(args) == "table" then
            for k in pairs(args) do args[k] = nil end
            OneCore_FillReagentArgs(args)
        end
    end
end

function OneCore_FillReagentArgs(args)
    -- 菜单里的“当前数量”优先取背包扫描结果，其次银行（DoSlotCounts 时缓存）
    local counts = (OneBag and OneBag.lastReagentCounts) or (OneBank and OneBank.lastReagentCounts) or {}
    local _, englishClass = UnitClass("player")

    -- 职业材料开关
    local classReagents = CLASS_REAGENTS[englishClass]
    if classReagents then
        args.classHeader = {
            type = 'header', order = 1,
            name = L["Class Reagents"],
            desc = L["Class Reagents"],
        }
        for i = 1, table.getn(classReagents) do
            local id, en = classReagents[i][1], classReagents[i][2]
            args["r" .. id] = {
                name = L[en], type = 'toggle', order = 10 + i,
                desc = string.format("%s (%d)", L[en], id),
                get = function() return OneCore_IsReagentEnabled(id) end,
                set = function(v)
                    OneCore_SetReagentEnabled(id, v)
                    OneCore_RefreshReagentCounts()
                end,
            }
        end
    end

    -- 自定义物品
    args.customHeader = {
        type = 'header', order = 50,
        name = L["Custom Items"],
        desc = L["Custom Items"],
    }
    args.addcustom = {
        name = L["Add Item ID"], type = 'text', order = 51,
        desc = L["Type an item ID and press Enter. Its total count will be shown in the info area."],
        usage = L["Item ID"],
        get = false,
        set = function(value)
            local ok, res = pcall(OneCore_AddCustomReagent, tonumber(value))
            if not ok or res == nil then
                DEFAULT_CHAT_FRAME:AddMessage("|cffff5555[OneBag]|r 材料：请输入有效的物品 ID")
            elseif res == false then
                DEFAULT_CHAT_FRAME:AddMessage("|cffffd100[OneBag]|r 材料：该物品 ID 已在列表中")
            else
                DEFAULT_CHAT_FRAME:AddMessage("|cff7fff7f[OneBag]|r 材料：已添加物品 ID " .. tostring(tonumber(value)))
            end
        end,
    }

    local customs = OneCore_GetCustomReagents()
    for i = 1, table.getn(customs) do
        local id = customs[i]
        local cname = OneCore_GetReagentName(id)
        local cnt = counts[id] or 0
        args["c" .. id] = {
            name = string.format("|cffff5555- %s|r (%d) x%d", cname, id, cnt),
            type = 'execute', order = 60 + i,
            desc = string.format("%s (%d) - %s", cname, id, L["Click to remove this custom item."]),
            func = function() OneCore_RemoveCustomReagent(id) end,
        }
    end
    if table.getn(customs) > 0 then
        args.clearcustom = {
            name = L["Clear Custom Items"], type = 'execute', order = 200,
            desc = L["Remove all custom items from the count list."],
            func = function() OneCore_ClearCustomReagents() end,
        }
    end
end

function OneCore:LoadOptionalCommands(baseArgs, module)
    local self = module
    if IsAddOnLoaded("MrPlow") then
        baseArgs.args.plow = {
            name = L["Plow!"], type = "execute",
            desc = L["Organizes your bags."],
            func = function() self:MrPlow() end, order = -6,
            notes = L["- Note: This option only appears if you have MrPlow installed"]
        }
    end
end

function OneCore:LoadLocaleCommands(baseArgs, module, bL)
    local self, values = module, {}
    for k, v in pairs(bL:GetLocaleList()) do tinsert(values, v) end
    tinsert(values, "None")
    baseArgs.args.Locale = {
        name = L["Pick Locale"], type = "text",
        desc = L["Sets the locale to use.  Will not take effect until you reload your UI."], 
        get = function() return self.db.profile.locale or "None" end, 
        set = function(value) 
            if value == "None" then value = nil end
            self.db.profile.locale = value
            L:SetLocale(value or true)
            self:TriggerEvent(string.format("%s_Locale_Changed", tostring(self)), value or true)
        end, order = -5, validate = values
    }
end

function OneCore:CopyTable(from, into)
    if type(into) ~= "table" then into = {} end
    for key, val in pairs(from) do
        if type(val) == "table" then into[key] = self:CopyTable(val) else into[key] = val end
    end
    if getn(from) then table.setn(into, getn(from)) end
    return into
end
local module = OneCore.modulePrototype

function module:BuildFrame(onlyBag)
    for k, bag in self.fBags do
        if not onlyBag or bag == onlyBag then
        local size = GetContainerNumSlots(bag)
        for slot = 1, size do
            if not self.frame.bags[bag] then 
                self.frame.bags[bag] = CreateFrame("Frame", tostring(self)..bag, self.frame)
                self.frame.bags[bag]:SetID(bag)
            end
            if not self.frame.bags[bag][slot] then
                -- 银行主容器(BANK_CONTAINER = -1)必须用 OneBankItemButtonTemplate（继承 BankItemButtonGenericTemplate）：
                -- 其 OnEnter → BankFrameItemButton_OnEnter → SetInventoryItem("player", 库存槽位)，能正确解析 -1，
                -- 与默认银行框、D:\OneBag 参考实现走同一套渲染——属性完整且幂等（不会重复追加"已有幻化"等行）。
                -- 其它背包(随身 0-4 / 购买银行袋 5-10)用 OneBagItemButtonTemplate（继承 ContainerFrameItemButtonTemplate），
                -- 走 SetBagItem(bag, slot) 幂等重设，行为不变。
                -- 注意：本客户端 SetBagItem 无法解析 -1，所以 -1 绝不能走 ContainerFrame 模板（否则悬停空白）。
                local template = (self.isBank and bag == -1) and "OneBankItemButtonTemplate" or "OneBagItemButtonTemplate"
                self.frame.bags[bag][slot] = CreateFrame("Button", tostring(self)..bag.."Item"..slot, self.frame.bags[bag], template)
                self.frame.bags[bag][slot]:SetID(slot)
                local button = self.frame.bags[bag][slot]
                -- 不再逐按钮挂 OnUpdate：由背包框上唯一的共享 OnUpdate 处理光标
                -- （详见 OneBag_BagFrame_OnUpdate 注释）。isOneBagItemButton 是其识别标记，
                -- 两种物品按钮模板都打上，银行主容器(-1)的 OneBankItemButtonTemplate 同样需要更新光标。
                button.isOneBagItemButton = true
                local moduleRef = self
                -- Alt+右键 → 切换整理锁定（星星标记）；否则沿用容器物品按钮默认点击行为
                -- （ContainerFrameItemButton_OnClick 对 -1 同样走 PickupContainerItem(-1, slot)，无需按模板分支）
                button:SetScript("OnClick", function()
                    if IsAltKeyDown() and arg1 == "RightButton" then
                        OneBag_ToggleSortLock(this:GetParent():GetID(), this:GetID())
                        return
                    end
                    if ContainerFrameItemButton_OnClick then ContainerFrameItemButton_OnClick(arg1) end
                end)
                button:SetScript("OnMouseDown", function()
                    if arg1 == "MiddleButton" then
                        local bag = this:GetParent():GetID()
                        local slot = this:GetID()
                        local itemLink = GetContainerItemLink(bag, slot)
                        if itemLink then
                            local itemName = string.match(itemLink, "%[(.-)%]")
                            if itemName then
                                if HasItemLock() then
                                    local playerKey = OneBag_GetPlayerKey()
                                    if ItemLockDB[playerKey] and ItemLockDB[playerKey].lockedItems and ItemLockDB[playerKey].lockedItems[itemName] then
                                        SlashCmdList.ITEMLOCK("remove " .. itemName)
                                    else
                                        SlashCmdList.ITEMLOCK("add " .. itemName)
                                    end
                                    if moduleRef.frame.bags[bag] then
                                        moduleRef:UpdateLockedItems(bag)
                                    end
                                else
                                    DEFAULT_CHAT_FRAME:AddMessage("[OneBag] 请先加载ItemLock插件以使用此功能")
                                end
                            end
                        end
                    end
                end)
                self.needToOrganize = true
            end
        end
        if self.frame.bags[bag] then
            local curBag = self.frame.bags[bag]
            local isAmmo, isSoul, isProf = self:GetBagTypes(bag)
            if curBag.size ~= size or curBag.isAmmo ~= isAmmo or curBag.isSoul ~= isSoul or curBag.isProf ~= isProf then
                self.needToOrganize = true
            end
            curBag.size, curBag.isAmmo, curBag.isSoul, curBag.isProf = size, isAmmo, isSoul, isProf
        end
        end -- if not onlyBag or bag == onlyBag（预建时只处理指定背包）
    end

    -- 光标更新：整个背包框只挂一个共享 OnUpdate，替代原先每个物品按钮一个。
    -- 用独立的小 frame 承载，避免覆盖 self.frame 上已有的脚本；框隐藏时直接跳过。
    if not self.frame.cursorFrame then
        local cf = CreateFrame("Frame")
        cf.owner = self
        cf:SetScript("OnUpdate", function()
            if this.owner.frame:IsVisible() then OneBag_BagFrame_OnUpdate() end
        end)
        self.frame.cursorFrame = cf
    end
end

function module:OrganizeFrame(needs)
    if not self.needToOrganize and not needs then return end
    self.needToOrganize = false
    
    local activeQuality = nil
    if self.GetActiveQuality then
        activeQuality = self:GetActiveQuality()
    end
    
    local activeCategory = nil
    if self.GetActiveCategory then
        activeCategory = self:GetActiveCategory()
    end
    
    local cols, curCol, curRow, justinc = self.db.profile.cols, 1, 1, false
    self.soulSlots, self.ammoSlots, self.profSlots, self.slotCount, self.totalCount = 0, 0, 0, 0, 0
    
    for k, bag in self.fBags do 
        if self.frame.bags[bag] then
            for k2, v2 in ipairs(self.frame.bags[bag]) do v2:Show() end
            self.totalCount = self.totalCount + (self.frame.bags[bag].size or 0)
        end
    end
    
    if self.db.profile.vAlign == L["Bottom"] then
        curCol = math.mod(self.totalCount, cols) > 0 and cols - math.mod(self.totalCount, cols) + 1 or 1
        if self.db.profile.bagBreak then
            for k, bag in self.fBags do 
                if self.frame.bags[bag] and self.frame.bags[bag].size then curCol = curCol - 1 end
            end
            curCol = curCol + 1
        end
    end

    -- 布局签名：仅当影响槽位排布的参数（列数/对齐/换行/方向/各包显隐与尺寸）变化时才
    -- 重算每个槽位的 ClearAllPoints/SetPoint（100+ 次重排很费）；否则沿用上次排布、只更新框架尺寸与过滤。
    local sig = self.db.profile.cols .. "|" .. tostring(self.db.profile.vAlign) .. "|" ..
                tostring(self.db.profile.bagBreak) .. "|" .. tostring(self.db.profile.show.direction)
    for k, bag in self.fBags do
        local cb = self.frame.bags[bag]
        sig = sig .. "|" .. (self:ShouldShow(bag, cb and cb.isAmmo, cb and cb.isSoul, cb and cb.isProf) and "1" or "0") .. ":" .. (cb and cb.size or 0)
    end
    local layoutChanged = (sig ~= self._layoutSig)
    self._layoutSig = sig

    for k, bag in (self.db.profile.show.direction and self.fBags or self.rBags) do
        local curBag = self.frame.bags[bag]
        if curBag and curBag.size and curBag.size > 0 then
            if bag > 0 and math.mod(self.frame.bags[bag-1] and self.frame.bags[bag-1].size or 0, cols) ~= 0 and self.db.profile.bagBreak then 
                curCol = curCol + 1
                if curCol > cols then curCol, curRow, justinc = 1, curRow + 1, true end
            end
            if curBag.isAmmo then
                self.ammoSlots = self.ammoSlots + curBag.size
            elseif curBag.isSoul then
                self.soulSlots = self.soulSlots + curBag.size
            elseif curBag.isProf then
                self.profSlots = self.profSlots + curBag.size
            else
                self.slotCount = self.slotCount + curBag.size
            end
            if self:ShouldShow(bag, curBag.isAmmo, curBag.isSoul, curBag.isProf) then
                for slot = 1, curBag.size do
                    justinc = false
                    if layoutChanged then
                        curBag[slot]:ClearAllPoints()
                        curBag[slot]:SetPoint("TOPLEFT", self.frame:GetName(), "TOPLEFT", self.leftBorder + (self.colWidth * (curCol - 1)) , 0 - self.topBorder - (self.rowHeight * curRow))
                    end
                    curBag[slot]:Show()                
                    curCol = curCol + 1
                    if curCol > cols then curCol, curRow, justinc = 1, curRow + 1, true end
                end
            end
        end
    end
    
    if not justinc then curRow = curRow + 1 end
    self.frame:SetHeight(curRow * self.rowHeight + self.bottomBorder + self.topBorder) 
    self.frame:SetWidth(cols * self.colWidth + self.leftBorder + self.rightBorder)
    
    if activeQuality and self.GetActiveQuality then
        self:ApplyFilter()
    end
    
    if activeCategory and self.GetActiveCategory then
        self:ApplyFilter()
    end
end

function module:SetBorderColor(slot)
    local color = {r = 1, g = 1, b = 1}
    local bag = slot:GetParent()
    local special = false
    if bag.isAmmo then 
        color = self.db.profile.colors.ammo
        special = true
    elseif bag.isSoul then
        color = self.db.profile.colors.soul
        special = true
    elseif bag.isProf then
        color = self.db.profile.colors.prof
        special = true
    elseif self.db.profile.colors.rarity then
        local d = self:GetSlotData(bag:GetID(), slot:GetID())
        local quality = d.quality
        if not quality or quality <= 1 then
            local itemLink = d.link
            if itemLink then
                local _, _, id = strfind(itemLink, "item:(%d+)")
                if id then
                    local _, _, q = GetItemInfoCached(id)
                    if q then quality = q end
                end
            end
        end
        local colorInfo = ITEM_QUALITY_COLORS[quality]
        if colorInfo then
            color = colorInfo
            if quality > 1 then special = true end
        end
    end
    
    -- 性能：边框（贴图 + 混合模式 + 顶点色）逐项比对（2026.10.27）
    -- 一次开关背包 / 每次 BAG_UPDATE 都会把全包 80+ 格的边框重设一遍，
    -- 而 SetNormalTexture 是"按路径重新绑定贴图"、SetPoint 会重建锚点，
    -- 两者在 1.12 下都不便宜；品质色 / 包类型决定的目标样式绝大多数时候没变。
    -- tpl: 1 = 发光边框，2 = 特殊（包类型 / 品质），3 = 普通
    local tpl = special and ((self.db.profile.colors.glow and 1) or 2) or 3
    if slot._obBcTpl == tpl and slot._obBcR == color.r and slot._obBcG == color.g and slot._obBcB == color.b then
        return
    end
    slot._obBcTpl, slot._obBcR, slot._obBcG, slot._obBcB = tpl, color.r, color.g, color.b

    if tpl == 1 then
        slot:SetNormalTexture("Interface\\Buttons\\UI-ActionButton-Border")
        slot:GetNormalTexture():SetBlendMode("ADD")
        slot:GetNormalTexture():SetAlpha(.8)
        slot:GetNormalTexture():SetPoint("CENTER", slot:GetName(), "CENTER", 0, 1)
    elseif tpl == 2 then
        slot:SetNormalTexture("Interface\\AddOns\\OneBag\\media\\BagSlot2")
        slot:GetNormalTexture():SetBlendMode("BLEND")
        slot:GetNormalTexture():SetPoint("CENTER", slot:GetName(), "CENTER", 0, 0)
    else
        slot:SetNormalTexture("Interface\\AddOns\\OneBag\\media\\BagSlot")
        slot:GetNormalTexture():SetBlendMode("BLEND")
        slot:GetNormalTexture():SetPoint("CENTER", slot:GetName(), "CENTER", 0, 0)
    end
    slot:GetNormalTexture():SetVertexColor(color.r, color.g, color.b)
end

function module:UpdateLockedItems(bag)
    if not HasItemLock() then return end
    
    if not self.frame.bags[bag] then return end
    
    -- 性能优化：playerKey（会话内缓存）与锁定表每次调用只取一次，避免每个格子重复调用 UnitName/GetRealmName
    local playerKey = OneBag_GetPlayerKey()
    local lockedItems = ItemLockDB[playerKey] and ItemLockDB[playerKey].lockedItems
    
    for slot = 1, self.frame.bags[bag].size do
        local button = self.frame.bags[bag][slot]
        if button then
            local isLocked = false
            if lockedItems then
                local itemLink = self:GetSlotData(bag, slot).link
                if itemLink then
                    local itemName = string.match(itemLink, "%[(.-)%]")
                    isLocked = itemName and lockedItems[itemName] or false
                end
            end
            
            local lockIcon = button.LockIcon
            if isLocked then
                if not lockIcon then
                    lockIcon = button:CreateTexture(nil, "OVERLAY")
                    lockIcon:SetTexture("Interface\\AddOns\\OneBag\\media\\fashu")
                    lockIcon:SetWidth(16)
                    lockIcon:SetHeight(16)
                    lockIcon:SetPoint("TOPLEFT", button, "TOPLEFT", 2, -2)
                    lockIcon:SetAlpha(0.8)
                    button.LockIcon = lockIcon
                end
                lockIcon:Show()
            elseif lockIcon then
                lockIcon:Hide()
            end
        end
    end
end

-- 添加任务标志函数
function module:UpdateQuestItems(bag)
    if not self.frame.bags[bag] then return end
    
    for slot = 1, self.frame.bags[bag].size do
        local button = self.frame.bags[bag][slot]
        if button then
            local link = self:GetSlotData(bag, slot).link
            if link then
                local _, _, id = strfind(link, "item:(%d+)")
                if id then
                    local name, _, quality, _, itemType = GetItemInfoCached(id)
                    if name then
                        -- 检查是否是任务物品
                        local isQuestItem = (itemType == "Quest" or itemType == "任务" or itemType == "Key" or itemType == "钥匙")
                        
                        -- 获取或创建任务标志
                        local questIcon = button.QuestIcon
                        if isQuestItem then
                            if not questIcon then
                                questIcon = button:CreateTexture(nil, "OVERLAY")
                                questIcon:SetTexture("Interface\\AddOns\\OneBag\\media\\questicon") -- 假设您有一个任务感叹号图标
                                questIcon:SetWidth(16)
                                questIcon:SetHeight(16)
                                questIcon:SetPoint("TOPLEFT", button, "TOPLEFT", 2, -2)
                                questIcon:SetAlpha(0.9)
                                button.QuestIcon = questIcon
                            end
                            questIcon:Show()
                            
                            -- 如果有锁定图标，调整位置避免重叠
                            local lockIcon = button.LockIcon
                            if lockIcon and lockIcon:IsVisible() then
                                questIcon:SetPoint("TOPLEFT", button, "TOPLEFT", 2, -2)
                                lockIcon:SetPoint("TOPLEFT", button, "TOPLEFT", 18, -2) -- 将锁定图标向右移动
                            end
                        elseif questIcon then
                            questIcon:Hide()
                        end
                    end
                end
            elseif button.QuestIcon then
                button.QuestIcon:Hide()
            end
        end
    end
end

-- 性能优化：单次 UpdateBag 内对每个格子的 GetContainerItemInfo / GetContainerItemLink 只调用一次，
-- SetBorderColor / UpdateLockedItems / UpdateQuestItems / DoSlotCounts 复用该缓存，避免重复调用昂贵 API。
-- 整理锁定标记：在右上角显示 fashu 图标，区分于左上角的锁定(fashu)图标（按名判定，与 ItemLock 一致）
function module:UpdateSortLocks(bag)
    if not self.frame.bags[bag] then return end

    -- 性能优化：playerKey 与锁定表每次调用只取一次
    local playerKey = UnitName("player") .. "-" .. GetRealmName()
    local locks = OneBagSortLockDB[playerKey]

    for slot = 1, self.frame.bags[bag].size do
        local button = self.frame.bags[bag][slot]
        if button then
            local isLocked = false
            if locks then
                local link = self:GetSlotData(bag, slot).link
                if link then
                    local itemName = string.match(link, "%[(.-)%]")
                    isLocked = itemName and locks[itemName] or false
                end
            end

            local starIcon = button.SortLockIcon
            if isLocked then
                if not starIcon then
                    starIcon = button:CreateTexture(nil, "OVERLAY")
                    starIcon:SetTexture("Interface\\AddOns\\OneBag\\media\\fashu") -- 复用 ItemLock 的 fashu 图标（本地贴图，必定存在）
                    starIcon:SetWidth(14)
                    starIcon:SetHeight(14)
                    starIcon:SetPoint("TOPRIGHT", button, "TOPRIGHT", -2, 2)
                    starIcon:SetAlpha(0.95)
                    button.SortLockIcon = starIcon
                end
                starIcon:Show()
            elseif starIcon then
                starIcon:Hide()
            end
        end
    end
end

-- 不可装备物品染色（参考 pfUI modules/unusable.lua）
-- 双路判定：
--   1) GetItemInfo 子类型 + 玩家职业查表，判定护甲类不匹配（布甲拿板甲/锁甲等典型场景，本客户端 tooltip 经常不显示红字，必须靠这条路）
--   2) tooltip 红字扫描兜底：等级要求/技能要求/阵营限制/武器类型限制等以红字形式提示的场景
-- 结果按 itemLink 缓存（OneCore._unusableCache），升级/学技能/切换开关时清空，避免高频重扫。
local UNUSABLE_TINT = { r = 1, g = 0.1, b = 0.1 }
local UNUSABLE_DURABILITY_PATTERN  -- 本地化耐久度模板转正则，首次扫描时生成

-- 统一的图标着色出口（整理卡灰根因修复）：
-- 1.12 客户端下 SetItemButtonDesaturated（服务器锁定灰）与 SetItemButtonTextureVertexColor
-- （不可装备红染）写的是【同一个】IconTexture 顶点色，两套逻辑各自调用会互相覆盖：
--   · 整理期间轻量刷新（锁定→灰、解锁→白）把红染冲掉；
--   · 全量刷新的红染/白复位又把锁定灰冲掉；
--   · 最后一笔是谁全看时序 → 整理后部分图标卡灰（红染物品灰化后最显眼）。
-- 所有刷新路径（全量/轻量/事件补刷）统一走本函数，结果与调用顺序无关：
--   服务器锁定 → 灰；未锁定 → 白 +（会话级缓存已判定的）不可装备红染。
-- 红染未缓存（nil）时按白色显示，由全量 UpdateUnusableItems 稍后纠正；false = 已判定可用。
--
-- 陈旧锁防线（卖店后卡灰场景）：卖掉物品后，该格子的服务器锁标志可能 sticky 残留
-- （真实锁在乌龟服最多 2-3 秒就解锁，但锁标志读取值可能一直是 true）。整理把物品
-- 搬进这种格子后，最后一次读到 locked=true 的刷新会把灰钉死——之后事件流结束、
-- 没有再读到 false 的刷新来翻回来。这里按按钮记录"首次观察到锁定"的时间，
-- 连续锁定超过 5 秒即判定为陈旧锁，按解锁着色（真实锁不可能持续这么久）。
local _slotLockSeen = {}   -- button -> 首次观察到 locked=true 的 GetTime()
local STALE_LOCK_SECONDS = 5

-- 该按钮的"锁定"是否已连续持续超过陈旧锁阈值（供 isEmpty+locked 保护等路径查询：
-- 陈旧锁下应按解锁处理，否则卖店格子的幽灵图标/灰格永远清不掉）。
function OneBag_IsSlotLockStale(button, locked)
    if not locked or not button then return false end
    local seen = _slotLockSeen[button]
    return seen ~= nil and (GetTime() - seen) >= STALE_LOCK_SECONDS
end

-- 陈旧锁下是否真的空槽：贴图为空【且】链接也没有，才算物品真的不在了（卖掉/移走）。
-- 粘锁期间物品可能仍在格子里 —— 本客户端锁定槽的贴图可能报告为空，但 link 正常返回。
-- 此时必须保留旧图标：仅凭"锁定超时"就 SetItemButtonTexture(nil) 会把有物格子刷成
-- 无图标，之后事件流结束、没有任何刷新再纠正（残留"卡灰/无图标"的最后一处漏洞）。
-- （参考 Guda：它靠整理期间隐藏按钮 + 结束整体重建躲开这个窗口，OneBag 按钮全程
--   可见，必须靠这个双重判定。）
function OneBag_SlotReallyEmpty(bag, slot)
    return not GetContainerItemLink(bag, slot)
end

--=============================================================================
-- 充能数量显示（参考 Guda 的 chargesText + 低频轮询，2026-09-23）：
-- 卓越法力之油(20748) / 卓越巫师之油(20749) 等带使用次数的道具，在图标右下角
-- 以橙字 "xN" 显示剩余次数（原版 SetItemButtonCount 对充能值 ≤1 / 负数一律隐藏，
-- 所以油类图标上从来不显示次数）。
-- 数据来源（零扫描优先）：
--   · SuperWoW/Nampower 下 GetContainerItemInfo 对带充能物品返回【负数】充能
--     （SortBags.lua 的 GetContainerItemCount 同款判定），实时读取，涂油后立即变化；
--   · 无 SuperWoW 降级：仅对已知油类物品把正数数量 (>1) 当作充能数显示，
--     避免把普通堆叠物品误判成充能。
-- 刷新时机：常规刷新路径（BAG_UPDATE→UpdateBagSlots 等）+ 涂油专用兜底——
-- 涂油不改变链接/堆叠数、部分客户端流程甚至不发 BAG_UPDATE（Guda README 实测），
-- 所以另有 ~1.2s 低频轮询（只轮询"上次显示过充能"的按钮）+ PLAYER_EQUIPMENT_CHANGED
-- 立即补刷（涂油成功会改变武器临时附魔）。见下方 OneBagChargesPollFrame。
--=============================================================================
local CHARGED_OILS = {
    [20744] = true, -- Minor Wizard Oil  次级巫师之油
    [20745] = true, -- Minor Mana Oil    次级法力之油
    [20746] = true, -- Lesser Wizard Oil 巫师之油
    [20747] = true, -- Lesser Mana Oil   法力之油
    [20748] = true, -- Brilliant Mana Oil   卓越法力之油
    [20749] = true, -- Brilliant Wizard Oil 卓越巫师之油
    [20750] = true, -- Wizard Oil        巫师之油
}

-- 读取某槽位的剩余充能数；无充能返回 nil。itemCount 传 GetContainerItemInfo 第 2 返回值。
function OneBag_GetSlotCharges(bag, slot, itemCount)
    if not itemCount or itemCount == 0 then return nil end
    if itemCount < 0 then
        -- SuperWoW：负数 = 剩余充能（-5 → 5 次）
        if SetAutoloot ~= nil then return -itemCount end
        return nil
    end
    -- 无 SuperWoW 降级：只有已知油类物品的正数数量才可能是充能
    if itemCount > 1 and SetAutoloot == nil then
        local link = GetContainerItemLink(bag, slot)
        local id = link and tonumber(string.match(link, 'item:(%d+)'))
        if id and CHARGED_OILS[id] then return itemCount end
    end
    return nil
end

-- 图标贴图逐项比对（2026.10.27）：SetItemButtonTexture 会重设图标贴图并按需 Show/Hide
-- 图标层，一次背包刷新每格都要调一遍；贴图路径没变就没有任何视觉收益。
-- texture 为空时照常调用（走清理路径，保守，避免按钮残留幽灵图标）。
function OneBag_SetSlotTexture(button, texture)
    if not button then return end
    if texture and button._obTex == texture then return end
    button._obTex = texture
    SetItemButtonTexture(button, texture)
end

-- 统一的数量/充能显示出口：所有刷新路径改走这里，保证同一槽位无论走哪条
-- 刷新链路，图标右下角显示的都是同一种东西（堆叠数白字 / 充能橙字 xN）。
-- 注意：SetItemButtonCount 不会重置字体颜色 —— 充能橙字显示过后必须显式复位，
-- 否则该槽位后续放入堆叠物品时会继承橙色。
function OneBag_SetSlotCount(button, count, charges)
    if not button then return end
    -- 必须保留 vanilla SetItemButtonCount 的副作用：button.count。
    -- Shift+点击拆分走 ContainerFrameItemButton_OnClick → OpenStackSplitFrame(this.count, this, ...)，
    -- 统一出口不写 button.count，拆分窗口拿到的 count 是 nil，永远不弹（2026-09-25 实测回归）。
    local rawCount = count or 0
    if rawCount < 0 then rawCount = 1 end -- SuperWoW 负充能编码（油类不堆叠，按 1 瓶计）
    button.count = rawCount
    local name = button.GetName and button:GetName()
    local text = name and getglobal(name .. "Count")
    if not text then return end
    -- 性能：堆叠数/充能文本逐项比对（2026.10.27）
    -- 每次背包刷新会对每格 SetText + SetTextColor + Show/Hide，即使数值完全没变
    -- （空槽的 Hide 也会走一遍 Hudoken 的子元素遍历）。用「模式 + 数值」两个标量做缓存，
    -- 数值没变就整块跳过，避免 80+ 格每帧重复排版同样文本。
    local cntMode, cntVal = 0, 0
    if charges and charges > 0 then
        cntMode, cntVal = 2, charges
    elseif count and count > 1 then
        cntMode, cntVal = 1, count
    end
    if button._obCntMode ~= cntMode or button._obCntVal ~= cntVal then
        button._obCntMode, button._obCntVal = cntMode, cntVal
        if cntMode == 2 then
            text:SetText("x" .. charges)
            text:SetTextColor(1, 0.82, 0)  -- 橙色，与 Guda 的充能文本同色
            text:Show()
        elseif cntMode == 1 then
            text:SetText(count)
            text:SetTextColor(1, 1, 1)
            text:Show()
        else
            text:Hide()
        end
    end
    if cntMode == 2 then
        button._hadCharges = true
        -- 有可见充能 → 唤醒低频轮询（涂油后无 BAG_UPDATE 也能在 1.2s 内跟上）
        if OneBagChargesPollFrame then OneBagChargesPollFrame:Show() end
    else
        button._hadCharges = nil
    end
end

-- 充能低频轮询（参考 Guda 的 RefreshVisibleChargedBags）：背包/银行打开时每 ~1.2s
-- 核对一次"上次显示了充能"的按钮（_hadCharges 标记），无充能按钮零开销；
-- 没有任何可见充能按钮时停帧（不空转）。PLAYER_EQUIPMENT_CHANGED（涂油成功）立即补一次。
do
    local poll = CreateFrame("Frame", "OneBagChargesPollFrame", UIParent)
    poll:Hide()
    poll.acc = 0
    poll:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
    poll:SetScript("OnEvent", function()
        this.force = true
        this:Show()
    end)
    poll:SetScript("OnUpdate", function()
        if not this.force then
            this.acc = this.acc + arg1
            if this.acc < 1.2 then return end
        end
        this.acc = 0
        this.force = nil
        local any = false
        for _, mod in ipairs({ _G.OneBag, _G.OneBank }) do
            if mod and mod.frame and mod.frame:IsVisible() and mod.frame.bags then
                for bag, bagFrame in pairs(mod.frame.bags) do
                    if type(bag) == "number" and bagFrame and bagFrame.size then
                        for slot = 1, bagFrame.size do
                            local btn = bagFrame[slot]
                            if btn and btn._hadCharges and btn:IsShown() then
                                any = true
                                local texture, itemCount = GetContainerItemInfo(bag, slot)
                                if texture then
                                    OneBag_SetSlotCount(btn, itemCount, OneBag_GetSlotCharges(bag, slot, itemCount))
                                else
                                    -- 充能耗尽物品消失 / 槽位被搬空：清掉 xN 残留
                                    OneBag_SetSlotCount(btn, nil, nil)
                                end
                            end
                        end
                    end
                end
            end
        end
        if not any then this:Hide() end
    end)
end

function OneBag_SetSlotShade(button, locked, link)
    if not SetItemButtonDesaturated then return end
    -- 性能：着色状态机 + 结果缓存（2026.10.27）
    -- SetItemButtonDesaturated / SetItemButtonTextureVertexColor 都是 C 侧改 GPU 着色状态，
    -- 一次背包刷新会对每格调 2 遍（SafeContainerFrame_Update 内 + UpdateBag 外层循环），
    -- 而 99% 的格子上次和这次的目标状态完全一致。目标状态没变就直接跳过。
    -- 状态编码：0 = 解锁白；1 = 服务器锁定灰。红染由 UpdateUnusableItems 单独负责，
    -- 它每次都会写顶点色，所以这里不把红染纳入状态（否则会互相顶掉缓存）。
    if locked then
        local seen = _slotLockSeen[button]
        if not seen then
            seen = GetTime()
            _slotLockSeen[button] = seen
        end
        if GetTime() - seen < STALE_LOCK_SECONDS then
            if button._obShadeState ~= 1 then
                button._obShadeState = 1
                SetItemButtonDesaturated(button, true, 0.5, 0.5, 0.5)
            end
            return
        end
        -- 连续锁定超时：视为陈旧锁，落到下方解锁着色路径（白/红染）
    else
        _slotLockSeen[button] = nil  -- 恢复解锁即清计时，下一轮真实锁重新起算
    end
    if button._obShadeState ~= 0 then
        button._obShadeState = 0
        SetItemButtonDesaturated(button, false, 1, 1, 1)
    end
    if link then
        local cache = OneCore._unusableCache
        if cache and cache[link] == true then
            local profColors = OneBag and OneBag.db and OneBag.db.profile and OneBag.db.profile.colors
            local t = (profColors and type(profColors.unusable) == "table" and profColors.unusable.r) and profColors.unusable or UNUSABLE_TINT
            SetItemButtonTextureVertexColor(button, t.r, t.g, t.b)
        end
    end
end

-- 1.12 经典职业可穿护甲表（含乌龟服常见职业）：
--   Warrior / Paladin / Hunter / Rogue / Priest / Shaman / Mage / Warlock / Druid
local ARMOR_USABLE = {
    cloth   = { WARRIOR=1, PALADIN=1, HUNTER=1, ROGUE=1, PRIEST=1, SHAMAN=1, MAGE=1, WARLOCK=1, DRUID=1 },
    leather = { WARRIOR=1, PALADIN=1, HUNTER=1, ROGUE=1, PRIEST=0, SHAMAN=1, MAGE=0, WARLOCK=0, DRUID=1 },
    mail    = { WARRIOR=1, PALADIN=1, HUNTER=1, ROGUE=0, PRIEST=0, SHAMAN=1, MAGE=0, WARLOCK=0, DRUID=0 },
    plate   = { WARRIOR=1, PALADIN=1, HUNTER=0, ROGUE=0, PRIEST=0, SHAMAN=0, MAGE=0, WARLOCK=0, DRUID=0 },
}
-- 兼容中英文 subType：英文短名 + 中文甲类名
local ARMOR_TYPE_MAP = {
    cloth = "cloth", leather = "leather", mail = "mail", plate = "plate",
    ["布甲"] = "cloth", ["皮甲"] = "leather", ["锁甲"] = "mail", ["板甲"] = "plate",
}
local _playerClassFile  -- UnitClass 缓存（同一角色登录会话内不变）

local function GetUnusableScanTooltip()
    if not OneBagUnusableScanTooltip then
        -- 完全照搬 pfUI libtipscan 的可靠模式（该库在本客户端验证可用）：
        -- parent 用 nil、owner 用 WorldFrame；Hide 会使 owner 失效，必须挂 OnHide 重新 SetOwner；
        -- 不强制尺寸、不依赖 Show（SetOwner 自带显示）。
        OneBagUnusableScanTooltip = CreateFrame("GameTooltip", "OneBagUnusableScanTooltip", nil, "GameTooltipTemplate")
        OneBagUnusableScanTooltip:SetOwner(WorldFrame, "ANCHOR_NONE")
        OneBagUnusableScanTooltip:SetScript("OnHide", function()
            this:SetOwner(WorldFrame, "ANCHOR_NONE")
        end)
    end
    return OneBagUnusableScanTooltip
end

-- 判断文本颜色是否接近红色（优先对比 RED_FONT_COLOR，不存在则宽松判红）
local function IsUnusableRed(r, g, b)
    if not r then return false end
    if RED_FONT_COLOR and RED_FONT_COLOR.r then
        return math.abs(r - RED_FONT_COLOR.r) < 0.1
            and math.abs(g - RED_FONT_COLOR.g) < 0.1
            and math.abs(b - RED_FONT_COLOR.b) < 0.1
    end
    return r > 0.8 and g < 0.25 and b < 0.25
end

-- 护甲类型不匹配判定：通过 GetItemInfo 子类型 + 玩家职业查表。
-- 三态返回：true=护甲类不匹配；false=非护甲/护甲类可穿；nil=GetItemInfo 数据未就绪（不缓存，
-- 进服瞬间物品数据常未加载，若此时返回 false 会被缓存成永久 false → 永不染红）。
function module:IsArmorClassMismatched(link)
    if not link then return false end
    -- 本环境（乌龟服）GetItemInfo 对彩色完整链接可能静默返回 nil；
    -- 按已验证格式优先传裸 hyperlink（|Hitem:...|h 的 H 内容，如 item:61174:0:0:0），失败再回退彩色链接
    local bare = string.match(link, "|H(item:[^|]+)|h") or link
    local ok, _, _, _, _, itemType, subType = pcall(GetItemInfo, bare)
    if not ok or not itemType or not subType then
        ok, _, _, _, _, itemType, subType = pcall(GetItemInfo, link)
        if not ok or not itemType or not subType then return nil end
    end
    if itemType ~= "Armor" and itemType ~= "护甲" then return false end
    local armorType = ARMOR_TYPE_MAP[subType] or ARMOR_TYPE_MAP[string.lower(subType)]
    if not armorType then return false end
    if not _playerClassFile then
        _, _playerClassFile = UnitClass("player")
        -- 本客户端 Lua 5.0 不支持 str:method() 语法糖（字符串元表 __index 未指向 string 库），
        -- 必须用全局函数 string.upper，否则此处报 attempt to index 导致整条染色链路中断
        _playerClassFile = _playerClassFile and string.upper(_playerClassFile)
    end
    if not _playerClassFile then return false end
    return ARMOR_USABLE[armorType][_playerClassFile] == 0
end

-- tooltip 红字扫描兜底：红字行 = 不可用（排除耐久度红字）。
-- 返回 nil 表示 tooltip 数据未就绪（只有物品名一行），不缓存；红字命中时附带返回行数（诊断用）。
function module:IsItemUnusableByTooltip(bag, slot)
    if not UNUSABLE_DURABILITY_PATTERN and DURABILITY_TEMPLATE then
        UNUSABLE_DURABILITY_PATTERN = string.gsub(DURABILITY_TEMPLATE, "%%[^%s]+", "(.+)")
    end
    local tip = GetUnusableScanTooltip()
    -- 仿 pfUI libtipscan：每次 Set 前先 ClearLines + 重新 SetOwner（1.12 Hide 会让 owner 失效，
    -- 不重置的话 SetBagItem 填充失败 → tooltip 空 → 行数恒 0 → 永远判"未就绪"）
    tip:ClearLines()
    tip:SetOwner(WorldFrame, "ANCHOR_NONE")
    local ok
    if bag == BANK_CONTAINER then
        ok = pcall(tip.SetInventoryItem, tip, "player", 39 + slot)
    else
        ok = pcall(tip.SetBagItem, tip, bag, slot)
    end
    if not ok then
        tip:Hide()
        return false
    end

    -- 用 NumLines() 取权威行数 + IsVisible() 过滤空行（libtipscan 同款），不用"遇空行 break"，
    -- 否则行间空行/右列独有内容会导致提前截断。
    local numLines = tip:NumLines()
    local lines = 0
    local red = false
    local playerLevel = UnitLevel("player")
    for i = 1, numLines do
        local left = getglobal("OneBagUnusableScanTooltipTextLeft" .. i)
        if left and left:IsVisible() then
            local text = left:GetText()
            if text and text ~= "" then
                lines = lines + 1
                local r, g, b = left:GetTextColor()
                if red == false and IsUnusableRed(r, g, b)
                    and not (UNUSABLE_DURABILITY_PATTERN and string.find(text, UNUSABLE_DURABILITY_PATTERN)) then
                    red = true
                end
                -- 等级不足主动判定：解析"需要等级 XX"/"Requires Level XX"，与玩家等级做数值比较，
                -- 不依赖红字颜色（红字漏检/颜色容差边缘时兜底）。等级足够时该行也存在但不判不可用。
                if red == false then
                    local req = tonumber(string.match(text, "需要等级%s*(%d+)"))
                        or tonumber(string.match(text, "Requires Level%s*(%d+)"))
                    if req and playerLevel < req then
                        red = true
                    end
                end
            end
        end
        -- 右列（冷却时间/ profession 等右对齐文本）也扫一遍红字
        local right = getglobal("OneBagUnusableScanTooltipTextRight" .. i)
        if right and right:IsVisible() then
            local rtext = right:GetText()
            if rtext and rtext ~= "" then
                local rr, rg, rb = right:GetTextColor()
                if red == false and IsUnusableRed(rr, rg, rb)
                    and not (UNUSABLE_DURABILITY_PATTERN and string.find(rtext, UNUSABLE_DURABILITY_PATTERN)) then
                    red = true
                end
            end
        end
    end
    tip:Hide()

    if lines < 2 then return nil end
    return red, lines
end

-- 综合判定（三态）：主路 true 立即结论；否则看副路结论；副路也未就绪则整体 nil（不缓存）
function module:IsItemUnusable(bag, slot, link)
    local mismatch = self:IsArmorClassMismatched(link)
    if mismatch == true then return true end
    local byTooltip = self:IsItemUnusableByTooltip(bag, slot)
    if byTooltip ~= nil then return byTooltip end
    return nil
end

-- 未决物品自动补扫计时器：物品数据（GetItemInfo/tooltip 缓存）由客户端异步加载，
-- 刚进服或首次见到的物品常未就绪（三态判定返回 nil、不缓存）。悬停物品会触发缓存加载
-- 但没有任何事件通知，因此对存在未决物品的背包按 1s→2s→…→8s（封顶）间隔自动重扫，
-- 直到全部就绪后自然停止。每次重扫只对未决物品调 GetItemInfo（本身即缓存请求），开销可忽略。
local _unusableRetryFrame
local function ScheduleUnusableRetry()
    if _unusableRetryFrame and _unusableRetryFrame:IsVisible() then
        _unusableRetryFrame.pending = true
        return
    end
    if not _unusableRetryFrame then
        _unusableRetryFrame = CreateFrame("Frame", "OneBagUnusableRetryFrame")
        local elapsed, wait = 0, 1
        _unusableRetryFrame:SetScript("OnUpdate", function()
            elapsed = elapsed + arg1
            if elapsed < wait then return end
            elapsed = 0
            if wait < 8 then wait = wait * 2 end
            _unusableRetryFrame.pending = false
            if OneBag and OneBag.frame then
                for _, b in ipairs(OneBag.fBags) do OneBag:UpdateUnusableItems(b) end
            end
            if OneBank and OneBank.frame then
                for _, b in ipairs(OneBank.fBags) do OneBank:UpdateUnusableItems(b) end
            end
            -- 重扫过程中有未决物品时 UpdateUnusableItems 会再次置 pending=true；
            -- 全部就绪则没人置位 → 停止计时器并重置间隔
            if not _unusableRetryFrame.pending then
                _unusableRetryFrame:Hide()
                wait = 1
            end
        end)
    end
    _unusableRetryFrame.pending = true
    _unusableRetryFrame:Show()
end

-- 不可装备染色入口：在 UpdateBag 末尾调用
function module:UpdateUnusableItems(bag)
    if not self.frame.bags[bag] then return end
    -- 离线银行(OneView)是存档数据、钥匙扣(-2)是特殊容器，tooltip 扫描不适用
    if self == OneView or bag == -2 then return end
    -- 开关全局统一存 OneBag 库（背包/银行共用同一开关）
    local enabled = OneBag and OneBag.db and OneBag.db.profile and OneBag.db.profile.unusableTint
    if enabled == false then
        -- 关闭开关：把可能残留的红色全部恢复默认（服务器锁定槽跳过，保留锁定灰）
        for slot = 1, self.frame.bags[bag].size do
            local button = self.frame.bags[bag][slot]
            if button then
                local data = self:GetSlotData(bag, slot)
                if not data.locked then SetItemButtonTextureVertexColor(button, 1, 1, 1) end
            end
        end
        return
    end

    if not OneCore._unusableCache then OneCore._unusableCache = {} end
    local cache = OneCore._unusableCache
    local hasPending = false

    -- 染色颜色可配置（设置菜单"颜色 → 不可装备颜色"，存 colors.unusable）；旧存档无此字段时回退默认红
    local tint = UNUSABLE_TINT
    local profColors = OneBag and OneBag.db and OneBag.db.profile and OneBag.db.profile.colors
    if profColors and type(profColors.unusable) == 'table' and profColors.unusable.r then
        tint = profColors.unusable
    end

    for slot = 1, self.frame.bags[bag].size do
        local button = self.frame.bags[bag][slot]
        if button then
            local data = self:GetSlotData(bag, slot)
            -- 服务器锁定槽跳过：锁定灰由统一着色出口（OneBag_SetSlotShade）负责，
            -- 这里若再涂红/白会把锁定灰冲掉（1.12 两者共用同一 IconTexture 顶点色）
            if data.locked then
                -- 保持锁定灰，不参与红染
            else
                local link = data.link
                local unusable = false
                if link then
                    local cached = cache[link]
                    if cached == nil then
                        cached = self:IsItemUnusable(bag, slot, link)
                        if cached ~= nil then
                            cache[link] = cached
                        else
                            -- 数据未就绪（物品缓存异步加载中）：不缓存，稍后自动补扫
                            hasPending = true
                        end
                    end
                    if cached ~= nil then
                        unusable = cached
                    end
                end
                if unusable then
                    SetItemButtonTextureVertexColor(button, tint.r, tint.g, tint.b)
                else
                    -- 可用/空槽/未就绪：恢复默认白色（ItemLock 灰化走 SetDesaturated 标志，不受顶点色影响）
                    SetItemButtonTextureVertexColor(button, 1, 1, 1)
                end
            end
        end
    end

    if hasPending then ScheduleUnusableRetry() end
end

-- 缓存在每次 UpdateBag 开始时清空（self._slotCache = nil），因此不会读取上次刷新的陈旧数据。
function module:GetSlotData(bag, slot)
    if not self._slotCache then self._slotCache = {} end
    local byBag = self._slotCache[bag]
    if not byBag then byBag = {}; self._slotCache[bag] = byBag end
    local d = byBag[slot]
    if not d then
        local texture, itemCount, locked, quality, readable, lootable = GetContainerItemInfo(bag, slot)
        d = {
            texture = texture,
            itemCount = itemCount,
            locked = locked,
            quality = quality,
            readable = readable,
            lootable = lootable,
            link = GetContainerItemLink(bag, slot),
        }
        byBag[slot] = d
    end
    return d
end

-- 游戏内诊断（手动调用）：/run OneBag_DebugUnusable(0, 1)
-- bag/slot 传目标背包与槽位（背包 0-4、银行主格 -1），逐环节输出染色判定链路的真实取值，
-- 用于定位"该红不红"卡在哪一环（开关/按钮/链接/GetItemInfo/主路/副路/染色 API）。
function OneBag_DebugUnusable(bag, slot)
    bag = bag or 0
    slot = slot or 1
    local function out(msg) DEFAULT_CHAT_FRAME:AddMessage("|cFFFF00FF[染色诊断]|r " .. msg) end
    out("bag=" .. bag .. " slot=" .. slot)
    local mod = OneBag
    if not (mod and mod.frame and mod.frame.bags and mod.frame.bags[bag]) then out("x frame/bags[" .. bag .. "] 不存在") return end
    out("开关 unusableTint = " .. tostring(OneBag.db and OneBag.db.profile and OneBag.db.profile.unusableTint))
    local button = mod.frame.bags[bag][slot]
    out("button = " .. (button and "存在(" .. tostring(button:GetName()) .. ")" or "nil"))
    out("SetItemButtonTextureVertexColor = " .. type(SetItemButtonTextureVertexColor))
    local data = mod:GetSlotData(bag, slot)
    out("link = " .. tostring(data.link and string.match(data.link, "item:%d+") or "nil"))
    if not data.link then out("x 该槽位无物品") return end
    -- 两种格式对比：本环境 GetItemInfo 对彩色链接/裸 hyperlink 的接受度可能不同
    local bare = string.match(data.link, "|H(item:[^|]+)|h")
    out("裸hyperlink = " .. tostring(bare))
    local ok1, n1 = pcall(GetItemInfo, data.link)
    out("GetItemInfo(彩色链接): ok=" .. tostring(ok1) .. " name=" .. tostring(n1))
    local ok2, n2 = pcall(GetItemInfo, bare or data.link)
    out("GetItemInfo(裸hyperlink): ok=" .. tostring(ok2) .. " name=" .. tostring(n2))
    if ok2 and n2 then
        local _, _, _, _, _, t2, s2 = pcall(GetItemInfo, bare or data.link)
        out("裸hyperlink明细: type=" .. tostring(t2) .. " subType=" .. tostring(s2))
    end
    out("补扫计时器 = " .. (_unusableRetryFrame and _unusableRetryFrame:IsVisible() and "运行中" or "停止"))
    local _, cls = UnitClass("player")
    out("UnitClass = " .. tostring(cls))
    out("主路 护甲查表 = " .. tostring(mod:IsArmorClassMismatched(data.link)))
    local red, lines = mod:IsItemUnusableByTooltip(bag, slot)
    out("副路 tooltip: lines=" .. tostring(lines) .. " 红字=" .. tostring(red))
    out("综合 IsItemUnusable = " .. tostring(mod:IsItemUnusable(bag, slot, data.link)))
    out("缓存命中 = " .. tostring(OneCore._unusableCache and OneCore._unusableCache[data.link]))
end

-- 轻量刷新（移植 SUCC-bag 的 FrameUpdate/ItemUpdate）：
-- 只同步图标 / 堆叠数 / 灰度 / 冷却 / 可读标志 / 槽位边框（品质·弹药·灵魂·专业袋染色），
-- 不跑 BuildFrame、OrganizeFrame、任务标记、整理锁定星星、不可装备染色、
-- 信息区计数、搜索过滤等重活。
-- 整理期间每次 BAG_UPDATE 走这条路：物品实时可见、灰度实时同步，
-- 既去掉"整包隐藏到整理结束才一次性弹出"的空白感，又不会因重活掉帧。
-- 注意：不改按钮可见性 —— 被品质/类别/搜索过滤隐藏的按钮保持隐藏，
-- 整理结束的完整 UpdateBag 会重新应用过滤。
-- 边框（品质/弹药/灵魂/专业袋染色）也要跟着换：物品换位后槽位边框必须匹配新物品，
-- 否则整理过程中会出现"绿装图标套白边框"的错位观感（对齐 SUCC-bag 的 ItemUpdateBorder）。
function module:UpdateBagSlots(bag)
    if self == OneView then return end  -- 离线银行是存档数据，实时容器 API 不适用
    -- 窗口没打开就不用刷（省开销）；不检查单个 bagFrame 的可见性，避免容器框架默认可见性
    -- 在个别客户端上判定不一致导致该刷没刷
    if not self.frame:IsVisible() then return end
    local bagFrame = self.frame.bags[bag]
    if not bagFrame or not bagFrame.size or bagFrame.size == 0 then return end
    -- 丢弃上次刷新残留的槽位缓存：物品已经换过位置，旧数据会让边框染错色
    self._slotCache = nil
    -- 先把本包所有槽位数据一次性灌进 _slotCache（每格 1 次 GetContainerItemInfo + 1 次 GetContainerItemLink）。
    -- 下面的循环以及 SetBorderColor 内部的 GetSlotData 都会命中缓存，
    -- 避免"图标刷新取一遍 + SetBorderColor 再取一遍"的 2N 次容器 API。
    for slot = 1, bagFrame.size do
        self:GetSlotData(bag, slot)
    end
    for slot = 1, bagFrame.size do
        local button = bagFrame[slot]
        if button then
            local d = self:GetSlotData(bag, slot)
            local texture, itemCount, locked, readable = d.texture, d.itemCount, d.locked, d.readable
            -- 关键修复：本客户端在服务器锁定窗口内 GetContainerItemInfo 的 texture 可能返回空，
            -- 若直接 SetItemButtonTexture(nil) 会把按钮刷成空白/定格空图标。
            -- 因此"锁定 + texture 为空"时保留上一帧图标（仅置灰），等解锁后 texture 恢复再正常刷新。
            -- 只有在 unlocked 时 texture 为空（物品确实被移走）才清除旧图标。
            local isEmpty = (not texture or texture == "")
            -- 陈旧锁感知：连续锁定超 5 秒视为锁标志残留 —— 但只有"贴图空 + 链接也没有"
            -- 才是真空槽；粘锁且有物（link 还在）保留旧图标（见 OneBag_SlotReallyEmpty）。
            if not (isEmpty and locked) or (OneBag_IsSlotLockStale(button, locked) and OneBag_SlotReallyEmpty(bag, slot)) then
                OneBag_SetSlotTexture(button, texture)
                OneBag_SetSlotCount(button, itemCount, OneBag_GetSlotCharges(bag, slot, itemCount))
                if not isEmpty then
                    if type(ContainerFrame_UpdateCooldown) == "function" then
                        pcall(ContainerFrame_UpdateCooldown, bag, button)
                    end
                    button.hasItem = 1
                else
                    local name = button.GetName and button:GetName()
                    local cooldown = name and getglobal(name .. "Cooldown")
                    if cooldown then cooldown:Hide() end
                    button.hasItem = nil
                end
            end
            -- 灰度/红染统一走统一着色出口：锁定→灰；解锁→白+已缓存红染。
            -- 旧版解锁一律刷白，把不可装备红染冲掉，红染物品整理后颜色错乱/发灰
            OneBag_SetSlotShade(button, locked, d.link)
            button.readable = readable
            -- 边框随新物品重染；背包栏位高亮期间(colorLocked)保持高亮色不被覆盖
            if not bagFrame.colorLocked then self:SetBorderColor(button) end
        end
    end
end

-- 解锁事件的即时同步（移植 SUCC-bag 的 FrameUpdateLock 并加强）：
-- 1) 本客户端解锁后不会主动恢复饱和度，必须主动翻回来，否则图标一直灰着（卡灰）；
-- 2) 本客户端服务器锁定期间贴图可能报告为空，若上一轮重绘把图标定格成"无图标"，
--    单纯去灰救不回来 —— 这里顺带把贴图/数量/hasItem 一并补回，解锁瞬间图标立刻恢复，
--    不必等补刷帧（对齐 SUCC-bag 的 BAG_UPDATE 全量 ItemUpdate 语义）。
function module:UpdateBagSlotLocks(bag)
    if self == OneView then return end
    local bagFrame = self.frame.bags[bag]
    if not bagFrame or not bagFrame.size then return end
    for slot = 1, bagFrame.size do
        local button = bagFrame[slot]
        if button then
            local texture, itemCount, locked, _, readable = GetContainerItemInfo(bag, slot)
            -- 锁定 + texture 为空：保留上一帧图标（不刷空），只置灰；解锁后 texture 恢复再更新。
            -- 不在 locked 时调 SetItemButtonTexture(nil) 是避免把锁定槽定格成空白图标。
            -- 陈旧锁分支同样要求"链接也没有"才算真空（见 OneBag_SlotReallyEmpty）。
            local isEmpty = (not texture or texture == "")
            if not (isEmpty and locked) or (OneBag_IsSlotLockStale(button, locked) and OneBag_SlotReallyEmpty(bag, slot)) then
                OneBag_SetSlotTexture(button, texture)
                OneBag_SetSlotCount(button, itemCount, OneBag_GetSlotCharges(bag, slot, itemCount))
                if isEmpty then
                    button.hasItem = nil
                else
                    button.hasItem = 1
                end
            end
            if SetItemButtonDesaturated then
                -- 统一着色出口：解锁槽保留/恢复已缓存红染，不再一律刷白
                local shadeLink
                if not locked then shadeLink = GetContainerItemLink(bag, slot) end
                -- 这条是「解锁抢救」路径（客户端解锁后不会自己恢复饱和度），必须无条件重设，
                -- 不能被 OneBag_SetSlotShade 的目标状态缓存挡掉（2026.10.27）
                button._obShadeState = nil
                OneBag_SetSlotShade(button, locked, shadeLink)
            end
            button.readable = readable
        end
    end
end

-- 单格同步（比 UpdateBagSlotLocks 更轻，~0.05ms）：ITEM_LOCK_CHANGED 自带 (bag, slot)，
-- 变化的只有这一个格子，无需扫全包。逻辑与 UpdateBagSlotLocks 逐槽分支一致。
function module:UpdateBagSlotLock(bag, slot)
    if self == OneView then return end
    if not self.frame or not self.frame:IsVisible() then return end
    local bagFrame = self.frame.bags[bag]
    if not bagFrame or not bagFrame.size or slot < 1 or slot > bagFrame.size then return end
    local button = bagFrame[slot]
    if not button then return end
    local texture, itemCount, locked, _, readable = GetContainerItemInfo(bag, slot)
    -- 锁定 + texture 为空：保留上一帧图标（不刷空），只置灰（与整包同步同一保护）。
    -- 陈旧锁分支同样要求"链接也没有"才算真空（见 OneBag_SlotReallyEmpty）。
    local isEmpty = (not texture or texture == "")
    if not (isEmpty and locked) or (OneBag_IsSlotLockStale(button, locked) and OneBag_SlotReallyEmpty(bag, slot)) then
        OneBag_SetSlotTexture(button, texture)
        OneBag_SetSlotCount(button, itemCount, OneBag_GetSlotCharges(bag, slot, itemCount))
        if isEmpty then
            button.hasItem = nil
        else
            button.hasItem = 1
        end
    end
    if SetItemButtonDesaturated then
        local shadeLink
        if not locked then shadeLink = GetContainerItemLink(bag, slot) end
        -- ITEM_LOCK_CHANGED 单格同步同样是「解锁抢救」路径，强制重设（2026.10.27）
        button._obShadeState = nil
        OneBag_SetSlotShade(button, locked, shadeLink)
    end
    button.readable = readable
end

-- skipCounts=true：跳过末尾的 DoSlotCounts（信息区计数），供"批量刷新所有包"的场景使用。
-- DoSlotCounts 遍历的是全部 fBags，若在 for 循环里每个包都跑一次就是 N 次全包扫描，
-- 其中 N-1 次纯属白跑；批量调用方应循环时传 true、循环结束后自己调一次 DoSlotCounts。
function module:UpdateBag(bag, skipCounts)
    if self.frame.isMoving or self.frame.isSorting or self.frame.isOutfitSwapping then return end
    if not self.frame.bags[bag] or not self.frame.bags[bag]:IsVisible() then return end
    self._slotCache = nil  -- 清空单次刷新内的槽位缓存，避免读取上次刷新的陈旧数据
    self:BuildFrame()
    self:OrganizeFrame()
    if not self.frame.bags[bag].colorLocked then
        for k, v in ipairs(self.frame.bags[bag]) do self:SetBorderColor(v) end
    end
    -- 槽位图标/堆叠数：用安全版刷新替换原生 ContainerFrame_Update，避免整理后高频重绘
    -- 触发 GameTooltip:SetBagItem -> tooltip 增强插件反复重建导致闪烁；离线银行(OneView) 仍走 FillBags。
    if self == OneView then
        self:FillBags()
    elseif self.frame.bags[bag].size and self.frame.bags[bag].size > 0 then
        pcall(OneBag_SafeContainerFrame_Update, self.frame.bags[bag])
    end
    if not skipCounts then self:DoSlotCounts() end

    if HasItemLock() then
        self:UpdateLockedItems(bag)
    end
    
    -- 更新任务物品标志
    self:UpdateQuestItems(bag)

    -- 更新整理锁定星星标记
    self:UpdateSortLocks(bag)

    -- 强制把图标"置灰"标志与当前服务器锁定状态同步（参考 SUCC-bag ItemUpdate 的每次同步）：
    -- 本客户端锁定槽图标会被置灰（desaturate），解锁后客户端不会主动恢复 → 卡灰。
    -- 每次刷新都逐槽位同步一次：仍锁定的保持灰，已解锁的立即恢复彩色。
    -- 放在不可装备染色之前：若该 API 以顶点色实现，染色随后重涂不会被冲掉。
    if self.frame.bags[bag].size then
        for slot = 1, self.frame.bags[bag].size do
            local button = self.frame.bags[bag][slot]
            if button then
                local d = self:GetSlotData(bag, slot)
                -- 统一着色出口（OneView 是存档数据不做红染，与 UpdateUnusableItems 的跳过一致）
                OneBag_SetSlotShade(button, d.locked, (self ~= OneView) and d.link or nil)
            end
        end
    end

    -- 不可装备物品染色
    self:UpdateUnusableItems(bag)

    if self.frame.searchFrame and self.frame.searchFrame.edit:GetText() and self.frame.searchFrame.edit:GetText() ~= "" and self.frame.searchFrame.edit:GetText() ~= L["Search"] then
        self:SearchFilter()
    end
end

function module:RequestBagUpdate(bag)
    -- 同帧防抖：把高频 BAG_UPDATE 合并为下一帧的一次刷新
    if not bag then
        -- nil 事件：刷新所有背包
        for _, b in ipairs(self.fBags) do
            self:RequestBagUpdate(b)
        end
        return
    end
    -- 整理进行中：走轻量路径（仍做同帧合并）。
    -- 旧行为是 UpdateBag 被 isSorting 拦掉、按钮又被隐藏 → 整理期间整包空白，
    -- 结束才一次性显示（且可能定格成灰图标）。轻量刷新让每步搬移实时可见，
    -- 灰度也跟着服务器锁定实时同步，收尾时不再需要"抢救式去灰"。
    if _G.OneBag_SortInProgress then
        RequestDebounced(self, "sortLightDebounce", "UpdateBagSlots", bag)
        return
    end
    RequestDebounced(self, "updateDebounce", "UpdateBag", bag)
end

function module:BagSlotButtonClicked(button)
    PlaySound("BAGMENUBUTTONPRESS")
    local inventorySlot = button:GetID()
    local bagID = inventorySlot - 19

    -- 原版 1.12 不允许替换非空背包（提示"只能空背包"），检测到后手动换包
    if self:BagHasItems(bagID) and CursorHasItem() then
        self:StartBagSwap(inventorySlot, bagID)
    else
        PutItemInBag(inventorySlot)
    end

    -- 高亮锁定逻辑（与原 XML 一致）
    if not button:GetChecked() then
        self:UnhighlightBagSlots(bagID)
        if self.frame.bags[bagID] then
            self.frame.bags[bagID].colorLocked = false
        end
    else
        if self.frame.bags[bagID] then
            self.frame.bags[bagID].colorLocked = true
        end
    end
    self:OrganizeFrame(true)
end

function module:BankBagSlotButtonClicked(button)
    PlaySound("BAGMENUBUTTONPRESS")
    local inventorySlot = button:GetInventorySlot()
    local bagID = button:GetID()
    if self:BagHasItems(bagID) and CursorHasItem() then
        self:StartBagSwap(inventorySlot, bagID)
    else
        PutItemInBag(inventorySlot)
    end
    if not button:GetChecked() and self.frame.bags[bagID] then
        self:UnhighlightBagSlots(bagID)
        self.frame.bags[bagID].colorLocked = false
    elseif self.frame.bags[bagID] then
        self.frame.bags[bagID].colorLocked = true
    end
    self:OrganizeFrame(true)
end

function module:BagHasItems(bagID)
    for slot = 1, GetContainerNumSlots(bagID) do
        if GetContainerItemInfo(bagID, slot) then
            return true
        end
    end
    return false
end

-- 换包操作间隔（TurtleWoW 服务器需要更长；换包时再判断，避免加载时全局变量未就绪）
local function GetSwapDelay()
    if TargetHPText ~= nil and TargetHPPercText ~= nil then
        return 0.6
    end
    return 0.25
end

function module:StartBagSwap(inventorySlot, bagID)
    if self.bagSwap then return end

    -- 记录旧背包里的物品格子
    local itemSlots = {}
    for slot = 1, GetContainerNumSlots(bagID) do
        if GetContainerItemInfo(bagID, slot) then
            tinsert(itemSlots, slot)
        end
    end

    -- 收集所有可用空格（排除被替换的 bagID 本身；范围用 self.fBags，随身/银行通用）
    local freeSlots = {}
    for _, bag in ipairs(self.fBags) do
        if bag ~= bagID then
            for slot = 1, GetContainerNumSlots(bag) do
                if not GetContainerItemInfo(bag, slot) then
                    tinsert(freeSlots, {bag = bag, slot = slot})
                end
            end
        end
    end

    -- 需要 1 个空格暂存新包 + N 个空格搬旧包物品 + 1 个空格放旧包
    if table.getn(freeSlots) < table.getn(itemSlots) + 2 then
        DEFAULT_CHAT_FRAME:AddMessage("|cFFFF0000[OneBag] 空格不足（需 " .. (table.getn(itemSlots) + 2) .. " 格，现有 " .. table.getn(freeSlots) .. " 格），无法自动换包|r")
        return
    end

    -- 第一个空格暂存新包，其余用来搬物品；旧包落点预规划，避免换包中每帧全包扫描
    local stash = freeSlots[1]
    local n = table.getn(itemSlots)

    -- 预规划：每个物品搬到 freeSlots[2 .. n+1]，旧包固定放到 freeSlots[n+2]
    local moves = {}
    for i = 1, n do
        moves[i] = { fromSlot = itemSlots[i], toBag = freeSlots[i + 1].bag, toSlot = freeSlots[i + 1].slot }
    end
    local backSlot = freeSlots[n + 2]

    self.bagSwap = {
        inventorySlot = inventorySlot,
        bagID = bagID,
        stash = stash,
        backSlot = backSlot,
        bagList = self.fBags,
        moves = moves,
        moveIndex = 1,
        moving = false,
        curDst = nil,
        phase = "stash",
        -- 锁定等待状态（取代原先固定 0.25~0.6s 的 delay 节流；参考 Guda BagReplacer）
        waiting = false,
        waitSlots = nil,
        waitStart = 0,
        waitTimeout = GetSwapDelay(),
        startTime = GetTime(),
        timeout = 60 + n * 1.5,
    }


    if not self.bagSwapFrame then
        local f = CreateFrame("Frame")
        f.handler = self
        f:SetScript("OnUpdate", function()
            this.handler:BagSwapOnUpdate(arg1)
        end)
        self.bagSwapFrame = f
    end
    self.bagSwapFrame:Show()
end

-- 换包锁定等待（参考 Guda BagReplacer 的 ITEM_LOCK_CHANGED 思路）：
-- 用「等待目标槽位解锁 / 安全超时」取代原先每步固定 0.25~0.6s 的轮询节流。
-- 快服务器上几乎零等待，慢服务器（Turtle）上按需等待，避免无谓空等与被吞重试。
local function OneBag_SwapAllUnlocked(swap)
    if not swap.waitSlots then return true end
    for _, v in ipairs(swap.waitSlots) do
        local _, _, locked = GetContainerItemInfo(v.bag, v.slot)
        if locked then return false end
    end
    return true
end

function module:BagSwapOnUpdate(elapsed)
    local swap = self.bagSwap
    if not swap then
        if self.bagSwapFrame then self.bagSwapFrame:Hide() end
        return
    end

    -- 超时保护（按物品数量动态计算）
    if GetTime() - swap.startTime > swap.timeout then
        self.bagSwap = nil
        if self.bagSwapFrame then self.bagSwapFrame:Hide() end
        self:BuildFrame()
        self:OrganizeFrame(true)
        return
    end

    -- 锁定等待：上一操作的目标槽位未解锁（或安全超时）前不发起下一步，
    -- 避免乌龟服因操作过快被服务器「吞掉」；解锁后立即继续，不再空等固定延迟。
    if swap.waiting then
        if OneBag_SwapAllUnlocked(swap) or (GetTime() - swap.waitStart > swap.waitTimeout) then
            swap.waiting = false
            swap.waitSlots = nil
        else
            return
        end
    end

    if swap.phase == "stash" then
        -- 把鼠标上的新包放进暂存位；放置失败（物品仍在光标）则下一帧重试
        PickupContainerItem(swap.stash.bag, swap.stash.slot)
        if not CursorHasItem() then
            swap.phase = "moveout"
        else
            swap.waiting = true
            swap.waitStart = GetTime()
            swap.waitSlots = nil
            return
        end

    elseif swap.phase == "moveout" then
        if swap.moving then
            -- 第二步：把光标上的物品放到目标空位；被吞则下一帧重试
            local dst = swap.curDst
            PickupContainerItem(dst.bag, dst.slot)
            if not CursorHasItem() then
                swap.moving = false
                swap.moveIndex = swap.moveIndex + 1
            else
                swap.waiting = true
                swap.waitStart = GetTime()
                swap.waitSlots = { {bag = dst.bag, slot = dst.slot} }
                return
            end
        elseif swap.moveIndex <= table.getn(swap.moves) then
            local move = swap.moves[swap.moveIndex]
            if GetContainerItemInfo(swap.bagID, move.fromSlot) then
                -- 第一步：拿起源格物品；被吞则下一帧重试
                PickupContainerItem(swap.bagID, move.fromSlot)
                if CursorHasItem() then
                    swap.moving = true
                    swap.curDst = {bag = move.toBag, slot = move.toSlot}
                else
                    swap.waiting = true
                    swap.waitStart = GetTime()
                    swap.waitSlots = { {bag = swap.bagID, slot = move.fromSlot} }
                    return
                end
            else
                -- 源格已空：跳过（例如上次已搬走）
                swap.moveIndex = swap.moveIndex + 1
            end
        else
            -- 搬移完成
            swap.phase = "pickup_old"
        end

    elseif swap.phase == "pickup_old" then
        -- 拿起旧包到光标（槽位清空）；被吞则下一帧重试
        PickupBagFromSlot(swap.inventorySlot)
        if CursorHasItem() then
            swap.phase = "drop_old"
        else
            swap.waiting = true
            swap.waitStart = GetTime()
            swap.waitSlots = nil
            return
        end

    elseif swap.phase == "drop_old" then
        -- 旧包放入预规划的空位（StartBagSwap 已算好，避免每帧全包扫描）
        PickupContainerItem(swap.backSlot.bag, swap.backSlot.slot)
        if not CursorHasItem() then
            swap.phase = "pickup_new"
        else
            swap.waiting = true
            swap.waitStart = GetTime()
            swap.waitSlots = { {bag = swap.backSlot.bag, slot = swap.backSlot.slot} }
            return
        end

    elseif swap.phase == "pickup_new" then
        -- 拿起暂存的新包；被吞则下一帧重试
        PickupContainerItem(swap.stash.bag, swap.stash.slot)
        if CursorHasItem() then
            swap.phase = "put_new"
        else
            swap.waiting = true
            swap.waitStart = GetTime()
            swap.waitSlots = { {bag = swap.stash.bag, slot = swap.stash.slot} }
            return
        end

    elseif swap.phase == "put_new" then
        -- 新包放入槽位（PutItemInBag 才有「把光标背包放入槽位」语义）；被吞则下一帧重试
        PutItemInBag(swap.inventorySlot)
        if not CursorHasItem() then
            swap.phase = "done"
        else
            swap.waiting = true
            swap.waitStart = GetTime()
            swap.waitSlots = nil
            return
        end

    elseif swap.phase == "abort" then
        -- 异常兜底：把旧包放回槽位并中止
        PutItemInBag(swap.inventorySlot)
        self.bagSwap = nil
        if self.bagSwapFrame then self.bagSwapFrame:Hide() end
        self:BuildFrame()
        self:OrganizeFrame(true)

    elseif swap.phase == "done" then
        self.bagSwap = nil
        if self.bagSwapFrame then self.bagSwapFrame:Hide() end
        self:BuildFrame()
        self:OrganizeFrame(true)
        for _, bag in ipairs(swap.bagList) do self:UpdateBag(bag, true) end
        self:DoSlotCounts()
    end
end

function module:IsItemLocked(bag, slot)
    if not HasItemLock() then return false end
    
    local itemLink = GetContainerItemLink(bag, slot)
    if not itemLink then return false end
    
    local itemName = string.match(itemLink, "%[(.-)%]")
    if not itemName then return false end
    
    local playerKey = UnitName("player") .. "-" .. GetRealmName()
    
    if ItemLockDB[playerKey] and ItemLockDB[playerKey].lockedItems then
        return ItemLockDB[playerKey].lockedItems[itemName] or false
    end
    
    return false
end

function module:GetBagTypes(bag)
    if bag <= 0 then return end
    local _, _, id = strfind(GetInventoryItemLink("player", ContainerIDToInventoryID(bag)) or "", "item:(%d+)"); 
    if id then 
        local _, _, _, _, itemType, subType = GetItemInfoCached(id);
        return (itemType == LC["Quiver"] or false), (subType == LC["Soul Bag"] or false), (( itemType == LC["Container"] and not (subType == LC["Bag"] or subType == LC["Soul Bag"])  ) or false)
    end
end

function module:HighlightBagSlots(bag)
    if not self.frame.bags[bag] then return end
    local color = self.db.profile.colors.mouseover 
    for k, v in ipairs(self.frame.bags[bag]) do 
        -- 高亮绕过了 SetBorderColor 的逐项比对缓存，必须把缓存清掉，
        -- 否则鼠标移开后 UnhighlightBagSlots → SetBorderColor 会误判"没变"而跳过，边框卡在高亮态（2026.10.27）
        v._obBcTpl, v._obBcR, v._obBcG, v._obBcB = nil, nil, nil, nil
        if self.db.profile.colors.glow then        
            v:SetNormalTexture("Interface\\Buttons\\UI-ActionButton-Border")
            v:GetNormalTexture():SetBlendMode("ADD")
            v:GetNormalTexture():SetAlpha(.8)
        else
            v:SetNormalTexture("Interface\\AddOns\\OneBag\\media\\BagSlot2")
            v:GetNormalTexture():SetBlendMode("BLEND")
        end
        v:GetNormalTexture():SetVertexColor(color.r, color.g, color.b)
    end
end

function module:UnhighlightBagSlots(bag)
    if not self.frame.bags[bag] then return end
    for k, v in ipairs(self.frame.bags[bag]) do self:SetBorderColor(v) end
end

function module:DoSlotCounts()
    local soulStoneCount = 0
    local usedSlots, usedAmmoSlots, usedSoulSlots, usedProfSlots, ammoQuantity = 0, 0, 0, 0, 0
    -- 有效材料表 = 职业材料（按开关过滤） + 自定义物品。
    -- 走 OneCore_GetReagentList 缓存：开关/增删/名称解析结果不变时直接复用上次的列表，
    -- 省掉每次刷新重建表 + 对每个自定义物品调 OneCore_GetReagentName（内含 GetTime）的开销。
    local reagentList = OneCore_GetReagentList()
    -- 计数表复用（模块级），避免每次刷新新建：先清零再累加
    local reagentCounts = self._reagentCounts
    if not reagentCounts then reagentCounts = {}; self._reagentCounts = reagentCounts end
    for k in pairs(reagentCounts) do reagentCounts[k] = nil end
    for i = 1, table.getn(reagentList) do reagentCounts[reagentList[i][1]] = 0 end
    for k, bag in self.fBags do
        if self.frame.bags[bag] then
            local tmp, qty = 0, 0
            for slot = 1, GetContainerNumSlots(bag) do
                local d = self:GetSlotData(bag, slot)
                if d.texture then
                    tmp = tmp + 1
                    qty = qty + d.itemCount
                    -- 按物品 ID 统计灵魂石真实数量（乌龟服 1 格叠 3 个，且灵魂袋可放其它召唤恶魔物品）
                    -- 用 GetContainerItemLink 取链接：本 1.12 客户端 GetContainerItemInfo 的第 7 返回值（link）为空，
                    -- 但 GetContainerItemLink 可靠可用（OneStorage 存档同样依赖它），故以此为准；GetContainerItemID 在此环境非函数全局，不再使用。
                    local itemLink = d.link
                    if itemLink then
                        local id = tonumber(string.match(itemLink, "item:(%d+)"))
                        if id == SOUL_STONE_ID then
                            soulStoneCount = soulStoneCount + (d.itemCount or 1)
                        end
                        if reagentCounts and id and reagentCounts[id] then
                            reagentCounts[id] = reagentCounts[id] + (d.itemCount or 1)
                        end
                    end
                end
            end
            if self.frame.bags[bag].isAmmo then
                usedAmmoSlots = usedAmmoSlots + tmp
                ammoQuantity = ammoQuantity + qty
            elseif self.frame.bags[bag].isSoul then
                usedSoulSlots = usedSoulSlots + tmp
            elseif self.frame.bags[bag].isProf then
                usedProfSlots = usedProfSlots + tmp
            else
                usedSlots = usedSlots + tmp
            end
        end
    end
    -- 缓存最近一次的材料计数，供设置菜单里显示“当前数量”
    self.lastReagentCounts = reagentCounts
    -- 未跑过 OrganizeFrame 时（如 OneBank 从未打开、或帧尚未布局）这些计数仍是 nil，
    -- 直接传给 format 会在本客户端报 "bad argument #3 to `format'"，故统一兜底为 0。
    local slotCount  = self.slotCount  or 0
    local ammoSlots  = self.ammoSlots  or 0
    local soulSlots  = self.soulSlots  or 0
    local profSlots  = self.profSlots  or 0
    local info = 1
    local name = self.frame:GetName() .. "Info"    

getglobal(name .. info):SetText(format(L["%s/%s Slots"], usedSlots, slotCount))
    info = info + 1
    for i = 2, 4 do getglobal(name .. i):SetText("") end
    if self.db.profile.show.counts then        
        if ammoSlots > 0 then
            getglobal(name .. info):SetText(format(L["%s/%s Ammo"], ammoQuantity, ammoSlots * 200))
            info = info + 1
        end
        if soulSlots > 0 or soulStoneCount > 0 then
            getglobal(name .. info):SetText(format(L["Soul Stones: %s"], soulStoneCount))
            info = info + 1
        end
        -- 材料行：职业材料（已开启的）+ 自定义物品；信息区共 4 行，每行最多 4 项，防越界/防超宽
        -- 钥匙链（OneRing）只显示槽位行，不显示材料计数
        if self ~= OneRing and reagentList and info <= 4 then
            local parts = {}
            for i = 1, table.getn(reagentList) do
                local entry = reagentList[i]
                local label = entry[3] and entry[2] or L[entry[2]]
                table.insert(parts, format(L["%s: %s"], label, reagentCounts[entry[1]] or 0))
            end
            local n = table.getn(parts)
            if n > 0 then
                local PER_LINE = 4
                local idx = 1
                while idx <= n and info <= 4 do
                    local chunk = {}
                    local last = idx + PER_LINE - 1
                    if last > n then last = n end
                    for j = idx, last do table.insert(chunk, parts[j]) end
                    getglobal(name .. info):SetText(table.concat(chunk, "  "))
                    info = info + 1
                    idx = last + 1
                end
            end
        end
        if profSlots > 0 then
            getglobal(name .. info):SetText(format(L["%s/%s Profession Slots"], usedProfSlots, profSlots))
            info = info + 1
        end
    end
end

function module:ShouldShow(bag, isAmmo, isSoul, isProf) 
    local show = true
    show = show and self.db.profile.show[bag] or false
    if isAmmo then
        show = show and self.db.profile.show.ammo or false
    elseif isSoul then
        show = show and self.db.profile.show.soul or false
    elseif isProf then
        show = show and self.db.profile.show.prof or false
    end
    return (show or self.frame.bags[bag].colorLocked )
end

function module:OpenMenu()    
    if self.dewdrop:IsOpen(getglobal(self.frame:GetName() .. "ConfigButton")) then
        self.dewdrop:Close()
    else
        -- 展开前刷新“材料计数”分组，使菜单里的自定义物品显示当前数量
        if OneCore_RefreshReagentOptions then OneCore_RefreshReagentOptions() end
        self.dewdrop:Open(getglobal(self.frame:GetName() .. "ConfigButton"), self.frame)
    end
end
function module:MrPlow()
    MrPlow:Works(self.isBank and "bank" or nil)
end

function module:OnBaseShow()
    local frame = self.frame
    if not frame then return end
    local profile = self.db.profile
    -- 性能：外观参数逐项比对（2026.10.27）
    -- 这些值几乎只在用户改设置时变化，但每次打开背包都会全量重设一遍；
    -- 其中 SetFrameStrata 会把这套 UI 重新挂进 strata 链表并重建绘制顺序，
    -- 在 pfUI 这类大 UI 下是打开瞬间最不该付的开销。
    if self._baseScale ~= profile.scale then
        self._baseScale = profile.scale
        frame:SetScale(profile.scale)
    end
    if self._baseAlpha ~= profile.alpha then
        self._baseAlpha = profile.alpha
        frame:SetAlpha(profile.alpha)
    end
    local strata = self.stratas[profile.strata]
    if self._baseStrata ~= strata then
        self._baseStrata = strata
        frame:SetFrameStrata(strata)
        StackSplitFrame:SetFrameStrata(self.stratas[profile.strata + 1])
    end
    local color = profile.colors.bground
    if self._baseBgR ~= color.r or self._baseBgG ~= color.g
        or self._baseBgB ~= color.b or self._baseBgA ~= color.a then
        self._baseBgR, self._baseBgG, self._baseBgB, self._baseBgA = color.r, color.g, color.b, color.a
        frame:SetBackdropColor(color.r, color.g, color.b, color.a)
    end
    local clamped = profile.clamped or false
    if self._baseClamped ~= clamped then
        self._baseClamped = clamped
        frame:SetClampedToScreen(clamped)
    end
end

function module:OnShow()
    -- 玩家手动打开过就等于"真画过了"，登录后的预热不必再跑一次；
    -- 若预热正进行中（0.35s 窗口内）被玩家打断，标记一下别把刚开的背包关掉
    if not self._warming then
        self.frame._warmupDrawn = true
        self._warmupAborted = true
    end
    self:OnBaseShow()
    self:OnCustomShow()
    -- 预热期间不播开关背包音效（否则登录后突然"哗"一声）
    if not self._warming then PlaySound("igBackPackOpen") end
    -- 预热期间不要连带把侧边背包栏（OBBagFram，独立顶层框，不受主框 alpha 影响）拉出来
    if self.frame.bagFrame and self.frame.bagFrame.wasShown and not self._warming then
        self.frame.bagFrame:Show()
        self.frame.bagFrame.wasShown = false
    end
    self:BuildFrame()
    self:OrganizeFrame()
    -- 循环内跳过信息区计数，末尾只跑一次全包扫描：原来 5 个包 = 5 次全包扫描（约数百次容器 API），其中 4 次白跑
    for k, i in self.fBags do self:UpdateBag(i, true) end
    if self.frame.bags[-1] and (not self.frame.bags[-1].colorLocked) then
        for k, v in ipairs(self.frame.bags[-1]) do self:SetBorderColor(v) end
    end
    self:DoSlotCounts()

    if self.frame.searchFrame then
        self.frame.searchFrame.edit:SetText(L["Search"])
        self.frame.searchFrame.button:Hide()
    end

    -- 修复：检查背包侧边栏是否可见或即将可见（wasShown），如果是则不显示分类标签页
    local bagFrameVisible = self.frame.bagFrame and (self.frame.bagFrame:IsVisible() or self.frame.bagFrame.wasShown)
    if self._warming then
        -- 预热期间不碰分类标签页（否则登录后侧边栏按钮会闪一下）
    elseif not bagFrameVisible then
        -- 检查全局开关 - 从 OneBag 数据库获取
        local filterVisible = true
        if OneBag and OneBag.db and OneBag.db.profile then
            filterVisible = OneBag.db.profile.filterModulesVisible
        end
        if filterVisible then
            if OneBagCategory then
                OneBagCategory:UpdateButtons()
            end
            -- Quality模块不做处理
        else
            -- 如果全局开关关闭，隐藏分类标签页
            if OneBagCategory then
                OneBagCategory:Hide()
            end
            -- Quality模块不做处理
        end
    else
        -- 如果背包侧边栏正在显示或即将显示，隐藏分类标签页
        if OneBagCategory then
            OneBagCategory:Hide()
        end
        -- Quality模块不做处理
    end
end

function module:OnCustomShow() end

function module:OnBaseHide()
    if self.dewdrop and self.dewdrop:IsOpen(getglobal(self.frame:GetName() .. "ConfigButton")) then
        self.dewdrop:Close()
    end
end

function module:OnHide()
    self:OnBaseHide()
    self:OnCustomHide()
    if not self._warming then PlaySound("igBackPackClose") end
    if self.frame.bagFrame and self.frame.bagFrame:IsVisible() then
        self.frame.bagFrame:Hide()
        self.frame.bagFrame.wasShown = true
    end
end

function module:OnCustomHide() end

function module:RegisterDewdrop(baseArgs)
    self.dewdrop = AceLibrary("Dewdrop-2.0")
    self.dewdrop:Register(self.frame, 'children', baseArgs, 'point', function(parent)
        if parent:GetTop() < GetScreenHeight() / 2 then
            return "BOTTOMRIGHT", "TOPRIGHT"
        else
            return "TOPRIGHT", "BOTTOMRIGHT"
        end
    end, 'dontHook', true)
end

function module:CreateSearchFrame()
    if self.frame.searchFrame then return end
    
    local search = CreateFrame("Frame", self.frame:GetName() .. "SearchFrame", self.frame)
    
    search:SetPoint("TOPLEFT", self.frame, "TOPLEFT", 120, -32)  
    search:SetPoint("TOPRIGHT", self.frame, "TOPRIGHT", -110, -32)  -- 修改这里：从-115改为-110
    
    search:SetHeight(24)  
    search:SetBackdrop({
        bgFile = 'Interface\\Tooltips\\UI-Tooltip-Background',
        -- edgeFile = 'Interface\\Tooltips\\UI-Tooltip-Border',
        tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 5, right = 25, top = 5, bottom = 5 }
    })
    search:SetBackdropBorderColor(1, 1, 1, 1)
    search:SetBackdropColor(0, 0, 0, 0) 
    search.text = search:CreateFontString(nil, "HIGH", "GameTooltipTextSmall")
    local font, size = search.text:GetFont()
    
    search.edit = CreateFrame("EditBox", nil, search)
    search.edit:SetMaxLetters(20)  
    search.edit:SetPoint("LEFT", search, "LEFT", 8, 0)
    search.edit:SetPoint("RIGHT", search, "RIGHT", -30, 0)
    search.edit:SetHeight(20)  
    search.edit:SetFont(font, size, "OUTLINE")
    search.edit:SetAutoFocus(false)
    search.edit:SetText(L["Search"])
    search.edit:SetTextColor(1,1,1,1)
    search.button = CreateFrame("Button", nil, search)   
    search.button:SetWidth(20)
    search.button:SetHeight(20)
    search.button:SetPoint("RIGHT", search, "RIGHT", -5, 0)
    search.button:SetFrameLevel(search:GetFrameLevel() + 2)
    search.button:SetNormalTexture('Interface\\Buttons\\UI-GroupLoot-Pass-Up')
    search.button:SetPushedTexture('Interface\\Buttons\\UI-GroupLoot-Pass-Up')
    search.button:SetHighlightTexture('Interface\\Buttons\\UI-GroupLoot-Pass-Up')
    search.button:EnableMouse(true)
    search.button:RegisterForClicks("LeftButtonUp")
    search.button:Hide()
    self.frame.searchFrame = search
    
    local function resetSearch()
        search.edit:SetText(L["Search"])
        self:ResetSearchFilter()
        search.button:Hide()
    end

    search.edit:SetScript("OnEditFocusGained", function()
        if this:GetText() == L["Search"] then
            this:SetText("")
        end
    end)

    search.edit:SetScript("OnEditFocusLost", function()
        if this:GetText() == "" then
            resetSearch()
        end
    end)

    search.edit:SetScript("OnTabPressed", function()
        this:ClearFocus()
        resetSearch()
    end)

    search.edit:SetScript("OnEscapePressed", function()
        this:ClearFocus()
        resetSearch()
    end)

    search.button:SetScript("OnClick", function()
        search.edit:ClearFocus()
        resetSearch()
    end) 

    search.edit:SetScript("OnTextChanged", function()
        if this:GetText() == L["Search"] then 
            resetSearch()
            return 
        end
        
        if not search.button:IsVisible() then
            search.button:Show()
        end
        
        self:SearchFilter()
    end)
    
    return search
end

function module:SearchFilter()
    local searchText = self.frame.searchFrame.edit:GetText()
    if not searchText or searchText == "" or searchText == L["Search"] then
        self:ResetSearchFilter()
        return
    end
    
    searchText = string.lower(searchText)
    
    for k, bag in self.fBags do
        if self.frame.bags[bag] then
            for slot = 1, self.frame.bags[bag].size do
                local item = self.frame.bags[bag][slot]
                if item and item:IsVisible() then
                    local texture, itemCount, locked = GetContainerItemInfo(bag, slot)
                    if texture then
                        local itemLink = GetContainerItemLink(bag, slot)
                        if itemLink then
                            local itemName = string.gsub(itemLink, ".*%[(.*)%].*", "%1")
                            if string.find(string.lower(itemName), searchText) then
                                item:SetAlpha(1)
                            else
                                item:SetAlpha(0.25)
                            end
                        else
                            item:SetAlpha(0.25)
                        end
                    else
                        item:SetAlpha(0.25)
                    end
                end
            end
        end
    end
end

function module:ResetSearchFilter()
    for k, bag in self.fBags do
        if self.frame.bags[bag] then
            for slot = 1, self.frame.bags[bag].size do
                local item = self.frame.bags[bag][slot]
                if item then
                    item:SetAlpha(1)
                end
            end
        end
    end
end

OneBag = OneCore:NewModule("OneBag", "AceEvent-2.0", "AceHook-2.0", "AceDebug-2.0", "AceConsole-2.0", "AceDB-2.0")
OneBank = OneCore:NewModule("OneBank", "AceEvent-2.0", "AceHook-2.0", "AceDebug-2.0", "AceConsole-2.0", "AceDB-2.0")
OneRing = OneCore:NewModule("OneRing", "AceEvent-2.0", "AceHook-2.0", "AceDebug-2.0", "AceConsole-2.0", "AceDB-2.0")
OneView = OneCore:NewModule("OneView", "AceEvent-2.0", "AceHook-2.0", "AceDebug-2.0", "AceConsole-2.0", "AceDB-2.0")
OneBagButton = OneCore:NewModule("OneBagButton", "AceEvent-2.0")

-- 删除或注释掉文件开始部分的这个函数：
-- function OneBagButton:OnEnable()
--     self:RegisterEvent("SPELLS_CHANGED", "RefreshSpells")
--     self:RegisterEvent("PLAYER_ENTERING_WORLD", "RefreshSpells")
-- end

OneBagCategory = CreateCategoryModule("OneBagCategory")
OneBagQuality = CreateQualityModule("OneBagQuality")
OneBankCategory = CreateCategoryModule("OneBankCategory")
OneBankQuality = CreateQualityModule("OneBankQuality")

-- 为OneView创建专用的分类和品质模块
OneViewCategory = CreateOneViewCategoryModule("OneViewCategory")
OneViewQuality = CreateOneViewQualityModule("OneViewQuality")

-- ===== 全角色金币统计：悬停金币栏(MoneyFrame)显示所有角色金币与总和 =====
-- 数据源为 OneStorage-2.0（PLAYER_MONEY 时自动为当前角色存档，跨角色数据来自 SavedVariables）。
-- Lua 5.0 兼容：不用 #t（table.getn）、不用字符串方法语法糖、OnEnter 用全局 this。
function OneBag_GetCharShortName(charId)
    if type(charId) ~= "string" then return tostring(charId) end
    local _, _, name = string.find(charId, "(.+) of (.+)")
    if not name then _, _, name = string.find(charId, "(.+)的(.+)") end
    return name or charId
end

function OneBag_FormatCoinText(copper)
    copper = tonumber(copper) or 0
    local gold = math.floor(copper / 10000)
    local silver = math.floor(math.mod(copper, 10000) / 100)
    local coin = math.mod(copper, 100)
    local out = ""
    if gold > 0 then
        out = out .. string.format("|cffffd100%d|r金 ", gold)
        out = out .. string.format("|cffbdbdff%d|r银 ", silver)
    elseif silver > 0 then
        out = out .. string.format("|cffbdbdff%d|r银 ", silver)
    end
    out = out .. string.format("|cffd99165%d|r铜", coin)
    return out
end

function OneBag_ShowAllMoneyTooltip()
    local storage = nil
    if AceLibrary and AceLibrary:HasInstance("OneStorage-2.0") then
        storage = AceLibrary("OneStorage-2.0")
    end
    if not (storage and storage.db and storage.db.account) then return end
    local currentCharId = AceLibrary("AceDB-2.0").CHAR_ID
    local entries = {}
    local total = 0
    for faction, chars in pairs(storage.db.account) do
        if type(chars) == "table" then
            for charId, data in pairs(chars) do
                if type(data) == "table" and data["money"] then
                    table.insert(entries, { name = OneBag_GetCharShortName(charId), charId = charId, money = data["money"] })
                    total = total + data["money"]
                end
            end
        end
    end
    if table.getn(entries) == 0 then return end
    table.sort(entries, function(a, b)
        if a.money == b.money then return a.name < b.name end
        return a.money > b.money
    end)
    GameTooltip:SetOwner(this, "ANCHOR_TOPRIGHT")
    GameTooltip:ClearLines()
    GameTooltip:AddLine("所有角色金币", 1, 0.82, 0)
    GameTooltip:AddLine(" ")
    for i = 1, table.getn(entries) do
        local e = entries[i]
        if e.charId == currentCharId then
            GameTooltip:AddDoubleLine(e.name .. " ◀", OneBag_FormatCoinText(e.money), 0.1, 1, 0.1, 1, 1, 1)
        else
            GameTooltip:AddDoubleLine(e.name, OneBag_FormatCoinText(e.money), 1, 1, 1, 1, 1, 1)
        end
    end
    GameTooltip:AddLine(" ")
    GameTooltip:AddDoubleLine("总和", OneBag_FormatCoinText(total), 0.33, 1, 0.33, 0.33, 1, 0.33)
    GameTooltip:Show()
end

function OneBag_SetupMoneyTooltip(moneyFrame)
    if not moneyFrame then return end
    if moneyFrame.SetHitRectInsets then
        -- 原判定区仅 206x14 太小：负内缩向外扩（上下扩更多，金币栏矮）
        moneyFrame:EnableMouse(true)
        moneyFrame:SetHitRectInsets(-8, -8, -10, -6)
        moneyFrame:SetScript("OnEnter", OneBag_ShowAllMoneyTooltip)
        moneyFrame:SetScript("OnLeave", function() GameTooltip:Hide() end)
    else
        -- 兜底：API 不存在时用透明子框架扩大悬停区（子框架可超出父边界接收鼠标）
        local overlay = CreateFrame("Frame", moneyFrame:GetName() .. "HoverExt", moneyFrame)
        overlay:EnableMouse(true)
        overlay:SetPoint("TOPLEFT", moneyFrame, "TOPLEFT", -8, 10)
        overlay:SetPoint("BOTTOMRIGHT", moneyFrame, "BOTTOMRIGHT", 8, -6)
        overlay:SetScript("OnEnter", OneBag_ShowAllMoneyTooltip)
        overlay:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end
end

function OneBag:OnInitialize()
    self:RegisterDB("OneBagDB")
    if self.db.profile.locale then L:SetLocale(self.db.profile.locale) else L:SetLocale(true) end
    self:RegisterDefaults('profile', OneCore:GetDefaults())
    
    -- 初始化过滤模块显示状态设置
    if self.db.profile.filterModulesVisible == nil then
        self.db.profile.filterModulesVisible = true  -- 默认显示
    end
    FILTER_MODULES_VISIBLE = self.db.profile.filterModulesVisible
    
    local baseArgs = OneCore:GetFreshOptionsTable(self)
    local customArgs = {
        ["0"] = {
            name = L["Backpack"], type = 'toggle', order = 5,
            desc = L["Turns display of your backpack on and off."],
            get = function() return self.db.profile.show[0] end,
            set = function(v) 
                self.db.profile.show[0] = v 
                self:OrganizeFrame(true)
            end,
        },
        ["1"] = {
            name = L["First Bag"], type = 'toggle', order = 6,
            desc = L["Turns display of your first bag on and off."],
            get = function() return self.db.profile.show[1] end,
            set = function(v) 
                self.db.profile.show[1] = v 
                self:OrganizeFrame(true)
            end,
        },
        ["2"] = {
            name = L["Second Bag"], type = 'toggle', order = 7,
            desc = L["Turns display of your second bag on and off."],
            get = function() return self.db.profile.show[2] end,
            set = function(v) 
                self.db.profile.show[2] = v 
                self:OrganizeFrame(true)
            end,
        },
        ["3"] = {
            name = L["Third Bag"], type = 'toggle', order = 8,
            desc = L["Turns display of your third bag on and off."],
            get = function() return self.db.profile.show[3] end,
            set = function(v) 
                self.db.profile.show[3] = v 
                self:OrganizeFrame(true)
            end,
        },
        ["4"] = {
            name = L["Fourth Bag"], type = 'toggle', order = 9,
            desc = L["Turns display of your fourth bag on and off."],
            get = function() return self.db.profile.show[4] end,
            set = function(v) 
                self.db.profile.show[4] = v 
                self:OrganizeFrame(true)
            end,
        },
    }
    OneCore:CopyTable(customArgs, baseArgs.args.show.args)
    OneCore:LoadOptionalCommands(baseArgs, self)
    OneCore:LoadLocaleCommands(baseArgs, self, L)
    self:RegisterChatCommand({"/ob", "/OneBag"}, baseArgs, string.upper(self.title))
    self.fBags = {0, 1, 2, 3, 4}
    self.rBags = {4, 3, 2, 1, 0}
    OneBagFrameName:SetText(L["Bags"])
    self.frame = OneBagFrame
    self.frame.handler = self
    OneBag_SetupMoneyTooltip(OneBagFrameMoneyFrame)
    self.frame.bagFrame = OBBagFram
    self.frame.bagFrame.handler = self
    self.frame.bags = {}
    self:RegisterDewdrop(baseArgs)
    OneBagFramepackupButton:Hide()
    
    self:CreateSearchFrame()
    
    OneBagCategory:Embed(self)
    OneBagQuality:Embed(self)
end

function OneBag:OnEnable()    
    self:Hook("IsBagOpen")
    self:Hook("ToggleBag")
    self:Hook("OpenBag")
    self:Hook("CloseBag")
    self:Hook("OpenBackpack", "OpenBag")
    self:Hook("CloseBackpack", "CloseBag")
    self:Hook("ToggleBackpack", "ToggleBag")
    
    local openEvents = {"BANKFRAME_OPENED", "MERCHANT_SHOW",}
    local closeEvents = {"BANKFRAME_CLOSED", "MERCHANT_CLOSED"}
    
    for _, event in ipairs(openEvents) do
        self:RegisterEvent(event, function() self:OpenBag() end)
    end
    for _, event in ipairs(closeEvents) do
        self:RegisterEvent(event, function() self:CloseBag() end)
    end
    
    self:RegisterEvent(string.format("%s_Locale_Changed", tostring(self)), "UpdateLocale")

    -- 后台预热物品缓存（参考 Guda 的 CacheWarmer）：登录后把背包 GetItemInfo 填满，
    -- 物品数据到达后重渲染可见背包，避免首次打开时任务标记/品质着色缺失。
    StartCacheWarmup()

    -- 换装时隐藏背包物品图标，避免 Outfitter 批量换装触发高频 BAG_UPDATE 重绘掉帧
    OneBag_HookOutfitter()
    -- 兜底：若 Outfitter 晚于本插件启用加载，则在登录时再尝试挂钩一次
    self:RegisterEvent("PLAYER_LOGIN", function() OneBag_HookOutfitter() end)
    -- 升级/学技能可能改变"能否装备"判定，清空不可装备染色缓存
    self:RegisterEvent("PLAYER_LEVEL_UP", function() OneCore._unusableCache = nil end)
    self:RegisterEvent("SPELLS_CHANGED", function() OneCore._unusableCache = nil end)
end

function OneBag:OnDisable()
    for id=1, 12 do
        local frame = getglobal("ContainerFrame"..id)
        frame:ClearAllPoints()
        frame:SetScale(1)
        frame:SetAlpha(1)        
    end
end

function OneBag:OnKeyRingButtonClick()
    if CursorHasItem() then
        PutKeyInKeyRing()
    else
        ToggleKeyRing()
    end
    local shownContainerID = IsBagOpen(KEYRING_CONTAINER)
    if shownContainerID then
        local frame = getglobal("ContainerFrame"..shownContainerID)
        frame:ClearAllPoints()
        frame:SetPoint("BOTTOMLEFT", this:GetParent():GetName(), "TOPLEFT", -9, 0)
        frame:SetScale(OneBag.db.profile.scale)
        frame:SetAlpha(OneBag.db.profile.alpha)
    else
        for id=1, 12 do
            local frame = getglobal("ContainerFrame"..id)
            frame:ClearAllPoints()
            frame:SetScale(1)
            frame:SetAlpha(1)        
        end
    end
end

function OneBag:ToggleBag(bag)
    if bag and (bag < 0 or bag > 4) then return self.hooks.ToggleBag.orig(bag) end
    -- 预热窗口内玩家自己按了背包键：标记中断，窗口结束时别把他刚开的背包关掉
    if self._warming then self._warmupAborted = true end
    if self.frame:IsVisible() then self.frame:Hide() else self.frame:Show() end
end

function OneBag:IsBagOpen(bag)
    if bag < 0 or bag > 4 then return self.hooks.IsBagOpen.orig(bag) end
    -- 预热窗口内对外一律表现为「背包没开」：此时框是被挪到屏幕外画着的，
    -- 如果骗外面说开着，遍历 IsBagOpen 的逻辑（隐藏原生 ContainerFrame 等）会跟着乱动
    if self._warming then return nil end
    if self.frame:IsVisible() then return bag else return nil end
end

function OneBag:OpenBag(bag)
    if bag and (bag < 0 or bag > 4) then return self.hooks.OpenBag.orig(bag) end
    if self._warming then self._warmupAborted = true end
    self.frame:Show()
end

function OneBag:CloseBag(bag)
    if bag and (bag < 0 or bag > 4) then return self.hooks.CloseBag.orig(bag) end
    if self._warming then self._warmupAborted = true end
    self.frame:Hide()
end

-- 确保按钮在背包显示时更新技能状态
-- 在 OneBag:OnCustomShow() 函数中，确保也调用了技能刷新
function OneBag:OnCustomShow()
    if self.db.profile.point then
        local point = self.db.profile.point
        this:ClearAllPoints()
        this:SetPoint("TOPLEFT", point.parent, "BOTTOMLEFT", point.left, point.top)
    end
    self:RegisterEvent("BAG_UPDATE", function() self:RequestBagUpdate(arg1) end)
    -- 冷却事件在整理期间没有意义（物品在不停换位），跳过可省掉大量无效刷新
    self:RegisterEvent("BAG_UPDATE_COOLDOWN", function()
        if _G.OneBag_SortInProgress then return end
        self:RequestBagUpdate(arg1)
    end)
    -- 服务器锁定状态变化：只同步灰度（移植 SUCC-bag 的 ITEM_LOCK_CHANGED → FrameUpdateLock）。
    -- 本客户端锁定槽图标会被置灰，解锁后不会自动恢复 → 必须主动翻回来，否则长期卡灰。
    self:RegisterEvent("ITEM_LOCK_CHANGED", function()
        if not self.frame:IsVisible() then return end
        -- 整理中不再丢弃该事件（对齐 SUCC-bag 新版语义）：SUCC 整理中照常走
        -- FrameUpdateLock 只做去灰同步。本客户端解锁时常常只发 ITEM_LOCK_CHANGED、
        -- 不发 BAG_UPDATE，旧版把事件丢掉后，已解锁槽位要等下一次搬动/收尾补刷才去灰，
        -- 表现为整个整理过程"卡灰明显"。这里改走最廉价的逐槽去灰同步
        -- （OneBag_SortResyncLockVisuals：只读 locked + SetItemButtonDesaturated，
        -- 不动贴图/计数，与 SUCC 的 FrameUpdateLock 开销一致）。
        if _G.OneBag_SortInProgress then
            for _, b in ipairs(self.fBags) do
                pcall(OneBag_SortResyncLockVisuals, self.frame, b)
            end
            return
        end
        -- 单格定向：事件自带 (bag, slot)，只同步这一格（~0.05ms，直接执行不防抖）；
        -- arg2 缺失或异常时退回整包轻量同步（同帧防抖）。arg1 不在管理范围
        -- （如装备栏来源的锁事件）时保留全量兜底，行为不回退。
        if type(arg1) == "number" and self.frame.bags[arg1] then
            if type(arg2) == "number" and self.frame.bags[arg1][arg2] then
                self:UpdateBagSlotLock(arg1, arg2)
            else
                RequestDebounced(self, "lockDebounce", "UpdateBagSlotLocks", arg1)
            end
            return
        end
        for _, b in ipairs(self.fBags) do self:UpdateBagSlotLocks(b) end
    end)
    -- 邮件邮资更新/耐久警报/收件箱更新：变灰已由上面的单格锁同步即时覆盖，
    -- 这里只做 0.25s 一次的时间窗节流兜底（RequestThrottled）。
    -- 旧版每批仍是 5 包轻量同步（~5.5ms），放/取附件一次触发两批 ≈ 11ms/点击。
    self:RegisterEvent("UPDATE_INVENTORY_ALERTS", function()
        for _, b in ipairs(self.fBags) do RequestThrottled(self, "slowSyncThrottle", "UpdateBagSlotLocks", b, 0.25) end
    end)
    self:RegisterEvent("MAIL_SEND_INFO_UPDATE", function()
        for _, b in ipairs(self.fBags) do RequestThrottled(self, "slowSyncThrottle", "UpdateBagSlotLocks", b, 0.25) end
    end)
    self:RegisterEvent("MAIL_INBOX_UPDATE", function()
        for _, b in ipairs(self.fBags) do RequestThrottled(self, "slowSyncThrottle", "UpdateBagSlotLocks", b, 0.25) end
    end)
    self:RegisterEvent("MAIL_SEND_SUCCESS", function() for i = 0, 4 do self:RequestBagUpdate(i) end end)
    self:RegisterEvent("MAIL_SEND_FAILED", function() for i = 0, 4 do self:RequestBagUpdate(i) end end)
    self:RegisterEvent("MAIL_CLOSED", function() for i = 0, 4 do self:RequestBagUpdate(i) end end)

    if self.frame.searchFrame then
        self.frame.searchFrame:Show()
    end
    
    -- 更新技能按钮状态 - 确保每次打开背包都检查
    if OneBagButton and OneBagButton.RefreshSpells then
        OneBagButton:RefreshSpells()
    end
    
    -- 检查背包侧边栏是否显示
    local bagFrameVisible = self.frame.bagFrame and (self.frame.bagFrame:IsVisible() or self.frame.bagFrame.wasShown)
    
    -- 分类模块的显示逻辑
    if not bagFrameVisible then
        -- 检查全局开关 - 从 OneBag 数据库获取
        local filterVisible = true
        if OneBag and OneBag.db and OneBag.db.profile then
            filterVisible = OneBag.db.profile.filterModulesVisible
        end
        
        if filterVisible then
            if OneBagCategory then
                OneBagCategory:UpdateButtons()
            end
        else
            -- 如果全局开关关闭，隐藏分类标签页
            if OneBagCategory then
                OneBagCategory:Hide()
            end
        end
    else
        -- 如果背包侧边栏正在显示，隐藏分类标签页
        if OneBagCategory then
            OneBagCategory:Hide()
        end
    end
    
    -- 品质模块的显示逻辑 - 始终显示（除非侧边栏显示）
    if not bagFrameVisible then
        if OneBagQuality then
            OneBagQuality:UpdateButtons()
        end
    else
        -- 如果背包侧边栏正在显示，隐藏品质模块
        if OneBagQuality then
            OneBagQuality:Hide()
        end
    end
end

function OneBag:OnCustomHide()
    local shownContainerID = IsBagOpen(KEYRING_CONTAINER)
    if shownContainerID then getglobal("ContainerFrame"..shownContainerID):Hide() end
    for id=1, 12 do
        local frame = getglobal("ContainerFrame"..id)
        frame:ClearAllPoints()
        frame:SetScale(1)
        frame:SetAlpha(1)        
    end
    self:UnregisterEvent("BAG_UPDATE")
    self:UnregisterEvent("BAG_UPDATE_COOLDOWN")
    self:UnregisterEvent("ITEM_LOCK_CHANGED")
    self:UnregisterEvent("UPDATE_INVENTORY_ALERTS")
    
    -- 总是隐藏分类标签页
    if OneBagCategory then
        OneBagCategory:Hide()
    end
    -- 也需要隐藏品质模块
    if OneBagQuality then
        OneBagQuality:Hide()
    end
end

function OneBag:UpdateLocale(locale)
    L:SetLocale(locale)
    OneBagFrameConfigButton:SetText(L["Menu"])
    OneBagFrameName:SetText(L["Bags"])
    self:DoSlotCounts()

    if self.frame.searchFrame then
        self.frame.searchFrame.edit:SetText(L["Search"])
    end
end

-- 分解/开锁技能按钮的图标纹理映射（参考 pfUI modules/bags.lua）
-- 通过法术图标纹理识别技能，而不是匹配本地化名称，中/英/其它语言客户端都可靠；
-- 子串匹配兼容客户端返回短名（Spell_Holy_RemoveCurse）或带路径的完整纹理名。
local knownInventorySpellTextures = {
    Spell_Holy_RemoveCurse = "DisenchantButton", -- 附魔：分解
    Spell_Nature_MoonKey   = "PickLockButton",   -- 盗贼：开锁
}

-- 在OneBagButton:OnInitialize()函数中添加分解和开锁按钮
-- 在OneBagButton:OnInitialize()函数中，修改按钮创建顺序和定位逻辑
function OneBagButton:OnInitialize()
    -- 首先获取或创建基础框架引用
    local OneBagFrame = _G["OneBagFrame"]
    if not OneBagFrame then return end
    
    -- 确保按钮都创建在正确的父框架上
    local parentFrame = OneBagFrame
    
    -- 获取已有的配置按钮位置作为参考
    local configButton = _G["OneBagFrameConfigButton"]
    if not configButton then
        -- 如果配置按钮不存在，使用背包框架作为参考
        configButton = parentFrame
    end
    
    -- 创建整理按钮 - 放在配置按钮左边
    local OneBagClean_Up = CreateFrame("Button", "OneBagClean_Up", parentFrame)
    OneBagClean_Up:SetWidth(20)
    OneBagClean_Up:SetHeight(20)
    OneBagClean_Up:SetPoint("RIGHT", configButton, "LEFT", -5, 0)
    OneBagClean_Up:SetFrameLevel(parentFrame:GetFrameLevel() + 5)
    OneBagClean_Up:SetNormalTexture("Interface\\AddOns\\OneBag\\media\\Sorting.BLP")
    OneBagClean_Up:SetPushedTexture("Interface\\AddOns\\OneBag\\media\\Sorting.BLP")
    OneBagClean_Up:GetPushedTexture():SetTexCoord(.09,.91,.09,.91)
    OneBagClean_Up:SetScript("OnMouseDown", function()
        -- 修改：左键使用反序（不传参数），右键使用正序（传参数1）
        if arg1 == "LeftButton" then
            Clean_Up("bags")  -- 反序整理
        else
            Clean_Up("bags", 1)  -- 正序整理
        end
    end)
    OneBagClean_Up:SetScript("OnEnter", function()
        GameTooltip:ClearLines()
        GameTooltip:SetOwner(this, "ANCHOR_TOPRIGHT")
        GameTooltip:AddLine("[左键]:正序|N[右键]:倒序")
        GameTooltip:Show()    
    end)
    OneBagClean_Up:SetScript("OnLeave", function() GameTooltip:Hide() end)
    
    -- 创建离线银行按钮 - 在整理按钮左边
    local OneBagView = CreateFrame("Button", "OneBagView", parentFrame)
    OneBagView:SetWidth(20)
    OneBagView:SetHeight(20)
    OneBagView:SetPoint("RIGHT", OneBagClean_Up, "LEFT", -5, 0)
    OneBagView:SetFrameLevel(parentFrame:GetFrameLevel() + 5)
    OneBagView:SetNormalTexture("Interface\\AddOns\\OneBag\\media\\Chest.BLP")
    OneBagView:SetPushedTexture("Interface\\AddOns\\OneBag\\media\\Chest.BLP")
    OneBagView:SetScript('OnMouseDown', function()
        if not OneCore then DEFAULT_CHAT_FRAME:AddMessage("|cFFFF0000OneCore 未加载！|r") return end
        if not OneCore:HasModule("OneView") then DEFAULT_CHAT_FRAME:AddMessage("|cFFFF0000OneView 模块未找到！|r") return end
        local oneViewModule = OneCore:GetModule("OneView")
        if not oneViewModule then DEFAULT_CHAT_FRAME:AddMessage("|cFFFF0000无法获取 OneView 模块！|r") return end
        if not oneViewModule:IsActive() then oneViewModule:Enable() end
        if arg1 == "RightButton" then
            -- 右键：清理所有账号的离线银行数据
            if not oneViewModule.storage or not oneViewModule.storage.db then
                DEFAULT_CHAT_FRAME:AddMessage("|cFFFF0000离线银行数据未就绪，无法清理！|r") return
            end
            -- 复用静态确认框（仿 ONEBAG_SORTLOCK_UNLOCK_ALL）
            StaticPopupDialogs["ONEBAG_CLEAR_OFFLINE"] = {
                text = "确定要清理其他角色的离线银行数据吗？\n将删除本地保存的其他角色银行/背包离线存档（当前角色的数据会被保留），且无法恢复。",
                button1 = "确定清理",
                button2 = "取消",
                OnAccept = OneBag_ClearOtherOfflineData,
                timeout = 0,
                whileDead = true,
                hideOnEscape = true,
                preferredIndex = 3,
            }
            StaticPopup_Show("ONEBAG_CLEAR_OFFLINE")
            return
        end
        if arg1 == "MiddleButton" then
            -- 中键：逐角色单个删除离线银行数据（交互同自定义材料的单个删除）
            oneViewModule:OpenCharDeleteMenu(this)
            return
        end
        -- 左键：切换离线银行界面
        if not OneViewFrame then DEFAULT_CHAT_FRAME:AddMessage("|cFFFF0000OneViewFrame 未创建，请重载界面！|r") return end
        if OneViewFrame:IsVisible() then OneViewFrame:Hide() else OneViewFrame:Show() end
    end)
    OneBagView:SetScript("OnEnter", function()
        GameTooltip:ClearLines()
        GameTooltip:SetOwner(this, "ANCHOR_TOPRIGHT")
        GameTooltip:AddLine("离线银行")
        GameTooltip:AddLine("左键: 打开/关闭离线银行")
        GameTooltip:AddLine("中键: 删除单个角色数据")
        GameTooltip:AddLine("右键: 清理全部离线数据")
        GameTooltip:Show()
    end)
    OneBagView:SetScript("OnLeave", function() GameTooltip:Hide() end)
    
    -- 创建锁定按钮 - 在离线银行按钮左边
    local OneBagLockButton = CreateFrame("Button", "OneBagLockButton", parentFrame)
    OneBagLockButton:SetWidth(20)
    OneBagLockButton:SetHeight(20)
    OneBagLockButton:SetPoint("RIGHT", OneBagView, "LEFT", -5, 0)
    OneBagLockButton:SetFrameLevel(parentFrame:GetFrameLevel() + 5)
    OneBagLockButton:SetNormalTexture("Interface\\AddOns\\OneBag\\media\\lock.BLP")
    OneBagLockButton:SetPushedTexture("Interface\\AddOns\\OneBag\\media\\lock.BLP")
    OneBagLockButton:GetPushedTexture():SetTexCoord(.09,.91,.09,.91)
    OneBagLockButton:SetScript('OnMouseDown', function()
        if arg1 == "LeftButton" then
        SlashCmdList["ITEMLOCK"]("list")
        else
        SlashCmdList["ITEMLOCK"]("unlockall")
        end
    end)
    OneBagLockButton:SetScript("OnEnter", function()
        GameTooltip:ClearLines()
        GameTooltip:SetOwner(this, "ANCHOR_TOPRIGHT")
        GameTooltip:AddLine("物品锁定")
        GameTooltip:AddLine("中键点击物品: 锁定/解锁")
        GameTooltip:AddLine("左键点击此按钮: 查看锁定列表")
        GameTooltip:AddLine("右键点击此按钮: 一键解锁物品")
        GameTooltip:Show()    
    end)
    OneBagLockButton:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- 创建整理锁定按钮 - 在锁定按钮左边（参考 OneBagLockButton 的逻辑）
    local OneBagSortLockButton = CreateFrame("Button", "OneBagSortLockButton", parentFrame)
    OneBagSortLockButton:SetWidth(20)
    OneBagSortLockButton:SetHeight(20)
    OneBagSortLockButton:SetPoint("RIGHT", OneBagLockButton, "LEFT", -5, 0)
    OneBagSortLockButton:SetFrameLevel(parentFrame:GetFrameLevel() + 5)
    OneBagSortLockButton:SetNormalTexture("Interface\\AddOns\\OneBag\\media\\guild.BLP")
    OneBagSortLockButton:SetPushedTexture("Interface\\AddOns\\OneBag\\media\\guild.BLP")
    OneBagSortLockButton:GetPushedTexture():SetTexCoord(.09,.91,.09,.91)
    OneBagSortLockButton:SetScript('OnMouseDown', function()
        if arg1 == "LeftButton" then
            OneBagSortLock_List()
        else
            OneBagSortLock_UnlockAll()
        end
    end)
    OneBagSortLockButton:SetScript("OnEnter", function()
        GameTooltip:ClearLines()
        GameTooltip:SetOwner(this, "ANCHOR_TOPRIGHT")
        GameTooltip:AddLine("整理锁定")
        GameTooltip:AddLine("Alt+右键点击物品: 锁定/解锁(不参与整理)")
        GameTooltip:AddLine("左键点击此按钮: 查看整理锁定列表")
        GameTooltip:AddLine("右键点击此按钮: 一键去除全部整理锁定")
        GameTooltip:Show()
    end)
    OneBagSortLockButton:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- 存储当前最左边的按钮，用于后续定位
    local leftMostButton = OneBagSortLockButton
    
    -- 打开 AutomatonEx 工具箱并定位到指定模块（默认自动需求物品）
    local function OpenAutomatonModule(moduleName)
        moduleName = moduleName or "AutoNeed"
        if not Automaton then
            DEFAULT_CHAT_FRAME:AddMessage("|cFFFF0000[OneBag] 未加载 AutomatonEx 工具箱|r")
            return
        end
        if type(Automaton.ToggleMainWindow) ~= "function" then
            DEFAULT_CHAT_FRAME:AddMessage("|cFFFF0000[OneBag] AutomatonEx 版本过旧，无法打开配置窗口|r")
            return
        end
        -- 窗口已打开：若已在目标模块则关闭，否则切换到目标模块
        if Automaton.mainFrame and Automaton.mainFrame:IsShown() then
            if Automaton.selectedModule == moduleName then
                Automaton:ToggleMainWindow()
            else
                Automaton:SelectModule(moduleName)
            end
            return
        end
        -- 窗口未打开：先定位到目标模块再打开，避免默认选中第一个模块
        Automaton.selectedModule = moduleName
        Automaton:ToggleMainWindow()
    end
    
    -- 如果LootFilter已加载，优先创建拾取过滤按钮（图标复用自动需求的 roll.BLP），自动需求按钮不再显示
    local OneBagLootFilter
    if IsAddOnLoaded("LootFilter") then
        OneBagLootFilter = CreateFrame("Button", "OneBagLootFilter", parentFrame)
        OneBagLootFilter:SetWidth(20)
        OneBagLootFilter:SetHeight(20)
        OneBagLootFilter:SetPoint("RIGHT", leftMostButton, "LEFT", -5, 0)
        OneBagLootFilter:SetFrameLevel(parentFrame:GetFrameLevel() + 5)
        OneBagLootFilter:SetNormalTexture("Interface\\AddOns\\OneBag\\media\\roll.BLP")
        OneBagLootFilter:SetPushedTexture("Interface\\AddOns\\OneBag\\media\\roll.BLP")
        OneBagLootFilter:GetPushedTexture():SetTexCoord(.09,.91,.09,.91)
        OneBagLootFilter:SetScript('OnClick', function()
            if not LootFilterOptions:IsShown() then
                LootFilterOptions:Show()
            else
                LootFilterOptions:Hide()
            end
        end)
        OneBagLootFilter:SetScript("OnEnter", function()
            GameTooltip:ClearLines()
            GameTooltip:SetOwner(this, "ANCHOR_TOPRIGHT")
            GameTooltip:AddLine("拾取过滤")
            GameTooltip:Show()
        end)
        OneBagLootFilter:SetScript("OnLeave", function() GameTooltip:Hide() end)

        -- 更新最左边的按钮
        leftMostButton = OneBagLootFilter
    end

    -- 如果AutomatonEx工具箱已加载且LootFilter未加载，创建自动需求按钮 - 基于锁定按钮定位
    local OneBagAutoNeed
    if IsAddOnLoaded("Automatonex") and not IsAddOnLoaded("LootFilter") then
        OneBagAutoNeed = CreateFrame("Button", "OneBagAutoNeed", parentFrame)
        OneBagAutoNeed:SetWidth(20)
        OneBagAutoNeed:SetHeight(20)
        OneBagAutoNeed:SetPoint("RIGHT", leftMostButton, "LEFT", -5, 0)
        OneBagAutoNeed:SetFrameLevel(parentFrame:GetFrameLevel() + 5)
        OneBagAutoNeed:SetNormalTexture("Interface\\AddOns\\OneBag\\media\\roll.BLP")
        OneBagAutoNeed:SetPushedTexture("Interface\\AddOns\\OneBag\\media\\roll.BLP")
        OneBagAutoNeed:GetPushedTexture():SetTexCoord(.09,.91,.09,.91)
        OneBagAutoNeed:SetScript('OnMouseDown', function()
            if arg1 == "RightButton" then
                -- 右键：打开工具箱自动售卖模块
                OpenAutomatonModule("Sell")
            elseif arg1 == "LeftButton" then
                -- 左键：打开工具箱自动需求模块
                OpenAutomatonModule("AutoNeed")
            end
        end)
        OneBagAutoNeed:SetScript("OnEnter", function()
            GameTooltip:ClearLines()
            GameTooltip:SetOwner(this, "ANCHOR_TOPRIGHT")
            GameTooltip:AddLine("自动需求 / 自动售卖")
            GameTooltip:AddLine("左键：打开工具箱自动需求模块")
            GameTooltip:AddLine("右键：打开工具箱自动售卖模块")
            GameTooltip:Show()
        end)
        OneBagAutoNeed:SetScript("OnLeave", function() GameTooltip:Hide() end)

        -- 更新最左边的按钮
        leftMostButton = OneBagAutoNeed
    end
    
    -- 创建分解按钮 - 基于自动需求或锁定按钮定位
    local OneBagDisenchant = CreateFrame("Button", "OneBagDisenchant", parentFrame)
    OneBagDisenchant:SetWidth(20)
    OneBagDisenchant:SetHeight(20)
    OneBagDisenchant:SetPoint("RIGHT", leftMostButton, "LEFT", -5, 0)
    OneBagDisenchant:SetFrameLevel(parentFrame:GetFrameLevel() + 5)
    OneBagDisenchant:SetNormalTexture("Interface\\AddOns\\OneBag\\media\\soul.BLP")
    OneBagDisenchant:SetPushedTexture("Interface\\AddOns\\OneBag\\media\\soul.BLP")
    OneBagDisenchant:GetPushedTexture():SetTexCoord(.09,.91,.09,.91)
    OneBagDisenchant:SetScript('OnClick', function()
        -- 直接用按钮上缓存的技能ID施放，无需重新扫描法术书
        local spellId = this:GetID()
        if spellId and spellId > 0 then
            CastSpell(spellId, BOOKTYPE_SPELL)
            DEFAULT_CHAT_FRAME:AddMessage("|cFF00FF00使用了分解技能|r")
        else
            DEFAULT_CHAT_FRAME:AddMessage("|cFFFF0000未学会分解技能|r")
        end
    end)
    OneBagDisenchant:SetScript("OnEnter", function()
        GameTooltip:ClearLines()
        GameTooltip:SetOwner(this, "ANCHOR_TOPRIGHT")
        local id = this:GetID()
        if id and id > 0 then
            GameTooltip:AddLine(GetSpellName(id, BOOKTYPE_SPELL) or "分解")
        else
            GameTooltip:AddLine("分解")
        end
        GameTooltip:AddLine("点击：使用分解技能", 0, 1, 0)
        GameTooltip:Show()    
    end)
    OneBagDisenchant:SetScript("OnLeave", function() GameTooltip:Hide() end)
    OneBagDisenchant:Hide() -- 默认隐藏，等检测到技能后再显示
    self.DisenchantButton = OneBagDisenchant
    
    -- 更新最左边的按钮
    leftMostButton = OneBagDisenchant
    
    -- 创建开锁按钮 - 基于分解按钮定位（如果存在），否则基于自动需求或锁定按钮
    local OneBagPickLock = CreateFrame("Button", "OneBagPickLock", parentFrame)
    OneBagPickLock:SetWidth(20)
    OneBagPickLock:SetHeight(20)
    
    -- 如果分解按钮存在，基于分解按钮定位，否则基于当前最左边的按钮
    if self.DisenchantButton then
        OneBagPickLock:SetPoint("RIGHT", self.DisenchantButton, "LEFT", -5, 0)
    else
        OneBagPickLock:SetPoint("RIGHT", leftMostButton, "LEFT", -5, 0)
    end
    
    OneBagPickLock:SetFrameLevel(parentFrame:GetFrameLevel() + 5)
    OneBagPickLock:SetNormalTexture("Interface\\AddOns\\OneBag\\media\\unlock.BLP")
    OneBagPickLock:SetPushedTexture("Interface\\AddOns\\OneBag\\media\\unlock.BLP")
    OneBagPickLock:GetPushedTexture():SetTexCoord(.09,.91,.09,.91)
    OneBagPickLock:SetScript('OnClick', function()
        -- 直接用按钮上缓存的技能ID施放，无需重新扫描法术书
        local spellId = this:GetID()
        if spellId and spellId > 0 then
            CastSpell(spellId, BOOKTYPE_SPELL)
            DEFAULT_CHAT_FRAME:AddMessage("|cFF00FF00使用了开锁技能|r")
        else
            DEFAULT_CHAT_FRAME:AddMessage("|cFFFF0000未学会开锁技能|r")
        end
    end)
    OneBagPickLock:SetScript("OnEnter", function()
        GameTooltip:ClearLines()
        GameTooltip:SetOwner(this, "ANCHOR_TOPRIGHT")
        local id = this:GetID()
        if id and id > 0 then
            GameTooltip:AddLine(GetSpellName(id, BOOKTYPE_SPELL) or "开锁")
        else
            GameTooltip:AddLine("开锁")
        end
        GameTooltip:AddLine("点击：使用开锁技能", 0, 1, 0)
        GameTooltip:Show()    
    end)
    OneBagPickLock:SetScript("OnLeave", function() GameTooltip:Hide() end)
    OneBagPickLock:Hide() -- 默认隐藏，等检测到技能后再显示
    self.PickLockButton = OneBagPickLock
    
    -- 注册SPELLS_CHANGED事件来更新按钮状态
    self:RegisterEvent("SPELLS_CHANGED")
    self:RegisterEvent("PLAYER_ENTERING_WORLD")
    
    -- 立即尝试刷新一次
    self:ScheduleEvent("OneBagButtonInitialRefresh", self.RefreshSpells, 1, self)
end

-- 重排分解/开锁按钮：分解不可见时，开锁直接锚到基准按钮，避免左侧出现空位
function OneBagButton:ReanchorSpellButtons()
    if not (self.DisenchantButton and self.PickLockButton) then return end
    -- 定位基准：拾取过滤 > 自动需求 > 整理锁定
    local baseButton = _G["OneBagLootFilter"] or _G["OneBagAutoNeed"] or _G["OneBagSortLockButton"]
    if not baseButton then return end

    if self.DisenchantButton:IsVisible() then
        self.DisenchantButton:ClearAllPoints()
        self.DisenchantButton:SetPoint("RIGHT", baseButton, "LEFT", -5, 0)
    end

    if self.PickLockButton:IsVisible() then
        local anchor = baseButton
        if self.DisenchantButton:IsVisible() then
            anchor = self.DisenchantButton
        end
        self.PickLockButton:ClearAllPoints()
        self.PickLockButton:SetPoint("RIGHT", anchor, "LEFT", -5, 0)
    end
end

-- 刷新分解/开锁技能按钮
-- 参考 pfUI modules/bags.lua：用图标纹理识别技能（不依赖本地化名称，中/英/其它语言客户端都可靠），
-- 只扫职业技能页 GetSpellTabInfo(1)，命中结果缓存到按钮 ID，点击时直接取用不再扫描。
function OneBagButton:RefreshSpells()
    -- 先隐藏并清空，避免上一次结果残留
    if self.DisenchantButton then self.DisenchantButton:Hide() self.DisenchantButton:SetID(0) end
    if self.PickLockButton then self.PickLockButton:Hide() self.PickLockButton:SetID(0) end

    local _, _, offset, numSpells = GetSpellTabInfo(1)
    for spellIndex = offset + 1, offset + numSpells do
        local spellTexture = GetSpellTexture(spellIndex, BOOKTYPE_SPELL)
        if spellTexture then
            for texture, buttonName in pairs(knownInventorySpellTextures) do
                if string.find(spellTexture, texture) then
                    local btn = self[buttonName]
                    if btn then
                        btn:SetID(spellIndex)
                        btn:Show()
                    end
                end
            end
        end
    end

    self:ReanchorSpellButtons()
end

-- 确保 OneBagButton 模块正确启用
function OneBagButton:OnEnable()    
    self:RefreshSpells()
end

-- 添加事件处理方法
function OneBagButton:SPELLS_CHANGED()
    self:RefreshSpells()
end

function OneBagButton:PLAYER_ENTERING_WORLD()
    self:RefreshSpells()
end

function OneBank:OnInitialize()
    local baseArgs = OneCore:GetFreshOptionsTable(self)
    local customArgs = {
        -- 5-10 号是银行包，用独立的 bank key（OneBag 语系里已有对应翻译，此前一直未被使用）
        ["5"] = {name = L["First Bank Bag"], type = 'toggle', order = 5, desc = L["Turns display of your first bank bag on and off."], get = function() return self.db.profile.show[5] end, set = function(v) self.db.profile.show[5] = v self:OrganizeFrame(true) end},
        ["6"] = {name = L["Second Bank Bag"], type = 'toggle', order = 6, desc = L["Turns display of your second bank bag on and off."], get = function() return self.db.profile.show[6] end, set = function(v) self.db.profile.show[6] = v self:OrganizeFrame(true) end},
        ["7"] = {name = L["Third Bank Bag"], type = 'toggle', order = 7, desc = L["Turns display of your third bank bag on and off."], get = function() return self.db.profile.show[7] end, set = function(v) self.db.profile.show[7] = v self:OrganizeFrame(true) end},
        ["8"] = {name = L["Fourth Bank Bag"], type = 'toggle', order = 8, desc = L["Turns display of your fourth bank bag on and off."], get = function() return self.db.profile.show[8] end, set = function(v) self.db.profile.show[8] = v self:OrganizeFrame(true) end},
        ["9"] = {name = L["Fifth Bank Bag"], type = 'toggle', order = 9, desc = L["Turns display of your fifth bank bag on and off."], get = function() return self.db.profile.show[9] end, set = function(v) self.db.profile.show[9] = v self:OrganizeFrame(true) end},
        ["10"] = {name = L["Sixth Bank Bag"], type = 'toggle', order = 10, desc = L["Turns display of your sixth bank bag on and off."], get = function() return self.db.profile.show[10] end, set = function(v) self.db.profile.show[10] = v self:OrganizeFrame(true) end},
    }
    OneCore:CopyTable(customArgs, baseArgs.args.show.args)
    OneCore:LoadOptionalCommands(baseArgs, self)
    self:RegisterDB("OneBankDB")
    self:RegisterDefaults('profile', OneBank:GetDefaults())
    self:RegisterChatCommand({"/obb", "/OneBank"}, baseArgs, string.upper(self.title))
    self.fBags = {-1, 5, 6, 7, 8, 9, 10}
    self.rBags = {10, 9, 8, 7, 6, 5, -1}
    OneBankFrameName:SetText(L["Bank Bags"])
    self.frame = OneBankFrame
    self.frame.handler = self
    OneBag_SetupMoneyTooltip(OneBankFrameMoneyFrame)
    self.frame.bagFrame = OBBBagFra
    self.frame.bagFrame.handler = self
    self.frame.bags = {["cols"] = 16}
    self.lastCounts = {}
    self.isBank = true
    self:RegisterDewdrop(baseArgs)
    
    self:CreateSearchFrame()
    
    OneBankCategory:Embed(self)
    OneBankQuality:Embed(self)
end

function OneBank:OnUpdate()
    local total, bagChanged = 0, false
    for i, k in self.fBags do
        local count = GetContainerNumSlots(k)
        if self.lastCounts[k] ~= count then
            self.lastCounts[k] = count
            bagChanged = true
        end
        total = total + count
    end
    if self.lastCount ~= total or bagChanged then
        -- 窗口拖动/整理/换装期间跳过重建与按钮显示：OnDragStart 已隐藏全部物品按钮，
        -- 若此处仍 BuildFrame/OrganizeFrame 会把按钮重新 Show 出来，使 StartMoving 逐帧
        -- 重绘成百上千个按钮导致严重掉帧；这些状态结束时都会补刷，故跳过安全。
        if not self.frame.isMoving and not self.frame.isSorting and not self.frame.isOutfitSwapping then
            self:BuildFrame()
            self:OrganizeFrame()
            -- 尺寸变化（如初次进游戏银行背包数据延迟就绪，尺寸从 0 变 N）时，
            -- 必须同步刷新图标，否则新建/扩容的银行背包槽位会漏填图标（表现出"图标不全"）。
            for _, b in self.fBags do
                self:UpdateBag(b, true)
            end
            self:DoSlotCounts()
        end
        self.lastCount = total
    end
    if self.bagPurchased then self:UpdateBagSlotStatus() end
end

function OneBank:StartOnUpdate()
    self:ScheduleRepeatingEvent(self.title, self.OnUpdate, .25, self)
    -- 初次打开银行：逐个刷新所有银行容器（主格 -1 + 背包 5..10），确保图标/堆叠数被填充。
    -- 旧版只刷了 -1，导致银行背包初次打开图标不全，必须拖动触发 OnDragStop 的 UpdateBag 才补齐。
    for _, b in self.fBags do
        self:UpdateBag(b, true)
    end
    self:DoSlotCounts()
end

function OneBank:StopOnUpdate()
    self:CancelScheduledEvent(self.title)
end

function OneBank:UpdateBagSlotStatus() 
    local purchaseFrame = OBBBagFraPurchaseInfo
    if purchaseFrame == nil then return end
    local numSlots, full = GetNumBankSlots()
    local button
    for i=1, NUM_BANKBAGSLOTS, 1 do
        button = getglobal("OBBBagFraBag"..i)
        if button then
            if i <= numSlots then
                SetItemButtonTextureVertexColor(button, 1.0,1.0,1.0)
                button.tooltipText = BANK_BAG
            else
                SetItemButtonTextureVertexColor(button, 1.0,0.1,0.1)
                button.tooltipText = BANK_BAG_PURCHASE
            end
        end
    end
    local cost = GetBankSlotCost(numSlots)
    BankFrame.nextSlotCost = cost
    if GetMoney() >= cost then
        SetMoneyFrameColor("OBBBagFraPurchaseInfoDetailMoneyFrame", 1.0, 1.0, 1.0)
    else
        SetMoneyFrameColor("OBBBagFraPurchaseInfoDetailMoneyFrame", 1.0, 0.1, 0.1)
    end
    MoneyFrame_Update("OBBBagFraPurchaseInfoDetailMoneyFrame", cost)
    if full then purchaseFrame:Hide() else purchaseFrame:Show() end
end

function OneBank:OnCustomShow() 
    if self.db.profile.point then
        local point = self.db.profile.point
        this:ClearAllPoints()
        this:SetPoint("TOPLEFT", point.parent, "BOTTOMLEFT", point.left, point.top)
    else
        if not OneBag:IsActive() then 
            this:ClearAllPoints() 
            this:SetPoint("CENTER", UIParent, "CENTER", 0, 0) 
        else 
            this:ClearAllPoints() 
            this:SetPoint("BOTTOMLEFT", OneBagFrame, "LEFT", -500, 25) 
        end
    end
    self:StartOnUpdate()
    self:UpdateBagSlotStatus()
    if self.frame then self.frame:SetClampedToScreen(self.db.profile.clamped or false) end
    
    if self.frame.searchFrame then
        self.frame.searchFrame:Show()
    end
    
    -- 只在银行侧边栏隐藏时显示分类标签页，并且检查全局开关
    if not self.frame.bagFrame or not self.frame.bagFrame:IsVisible() then
        -- 检查全局开关 - 从 OneBag 数据库获取
        local filterVisible = true
        if OneBag and OneBag.db and OneBag.db.profile then
            filterVisible = OneBag.db.profile.filterModulesVisible
        end
        
        if filterVisible then
            if OneBankCategory then
                OneBankCategory:UpdateButtons()
            end
        else
            -- 如果全局开关关闭，隐藏分类标签页
            if OneBankCategory then
                OneBankCategory:Hide()
            end
        end
        
        -- 无论全局开关如何，都显示Quality模块
        if OneBankQuality then
            OneBankQuality:UpdateButtons()
        end
    else
        -- 如果银行侧边栏正在显示，隐藏分类标签页
        if OneBankCategory then
            OneBankCategory:Hide()
        end
        -- Quality模块不做处理
    end
end

function OneBank:OnCustomHide()
    CloseBankFrame()
    self:StopOnUpdate()
    
    -- 总是隐藏分类标签页
    if OneBankCategory then
        OneBankCategory:Hide()
    end
    -- Quality模块不做处理
end

function OneBank:OnEnable()
    if self.frame then self.frame:SetClampedToScreen(true) end
    self:RegisterEvent("BAG_UPDATE", function() self:RequestBagUpdate(arg1) end)
    self:RegisterEvent("BAG_UPDATE_COOLDOWN", function()
        if _G.OneBag_SortInProgress then return end
        self:RequestBagUpdate(arg1)
    end)
    -- 服务器锁定状态变化：只同步灰度（同上，防银行物品整理/存取后卡灰）。
    -- 整理中同样不丢弃：走廉价去灰同步（见 OneBag OnCustomShow 内同名注释）。
    self:RegisterEvent("ITEM_LOCK_CHANGED", function()
        if not self.frame:IsVisible() then return end
        if _G.OneBag_SortInProgress then
            for _, b in ipairs(self.fBags) do
                pcall(OneBag_SortResyncLockVisuals, self.frame, b)
            end
            return
        end
        -- 同 OneBag：单格定向（bag+slot，~0.05ms 直接执行）；arg2 异常退回整包
        -- 轻量同步（含主银行 -1），arg1 不在管理范围时才全量兜底。
        if type(arg1) == "number" and self.frame.bags[arg1] then
            if type(arg2) == "number" and self.frame.bags[arg1][arg2] then
                self:UpdateBagSlotLock(arg1, arg2)
            else
                RequestDebounced(self, "lockDebounce", "UpdateBagSlotLocks", arg1)
            end
            return
        end
        for _, b in ipairs(self.fBags) do self:UpdateBagSlotLocks(b) end
    end)
    self:RegisterEvent("BANKFRAME_OPENED", function() if self.frame then self.frame:Show() end end)
    self:RegisterEvent("BANKFRAME_CLOSED", function() if self.frame then self.frame:Hide() end end)
    self:RegisterEvent("PLAYERBANKSLOTS_CHANGED", function()
        -- 此事件只在主银行容器(-1)物品变动时触发（购买的银行袋走 BAG_UPDATE），
        -- 默认只重画了边框颜色，没有刷新图标/堆叠数，导致物品移走后图标残留。
        -- 这里主动请求一次内容刷新，让主银行走与购买银行袋完全相同的刷新链路。
        if not self.frame.bags[-1] then return end
        -- 窗口拖动/整理/换装期间跳过：这些状态结束时都会补刷（OnDragStop / 整理结束），
        -- 此时若叠加主银行 -1 的全量图标刷新，会与"隐藏按钮避免逐帧重绘"的拖动优化冲突，导致掉帧。
        if self.frame.isMoving or self.frame.isSorting or self.frame.isOutfitSwapping then return end
        -- 尾沿防抖：主银行内拖动/移动物品时该事件可能高频触发，直接每帧全量重绘 -1 的 24 个按钮会掉帧。
        -- 把连续事件合并成"停止 0.05s 后"的一次刷新：既保证最终状态及时刷出（对齐购买银行袋的即时感），
        -- 又不会在拖动过程中反复全量重绘。相比旧版 0.15s 前缘节流（会漏掉 0.15s 内的最后状态）更及时。
        if not self._bankSlotDebounce then
            self._bankSlotDebounce = CreateFrame("Frame")
            self._bankSlotDebounce:Hide()
            self._bankSlotDebounce.owner = self
            self._bankSlotDebounce.elapsed = 0
            self._bankSlotDebounce:SetScript("OnUpdate", function()
                this.elapsed = this.elapsed + arg1
                if this.elapsed >= 0.05 then
                    this.elapsed = 0
                    this:Hide()
                    local mod = this.owner
                    if not mod.frame.bags[-1] then return end
                    if mod.frame.isMoving or mod.frame.isSorting or mod.frame.isOutfitSwapping then return end
                    if not mod.frame.bags[-1].colorLocked then
                        for k, v in ipairs(mod.frame.bags[-1]) do mod:SetBorderColor(v) end
                    end
                    mod:RequestBagUpdate(-1)
                end
            end)
        end
        self._bankSlotDebounce.elapsed = 0
        self._bankSlotDebounce:Show()
    end)
    if CT_oldPurchaseSlot then PurchaseSlot = CT_oldPurchaseSlot end
    self:Hook("PurchaseSlot", function() self.hooks.PurchaseSlot.orig() self.bagPurchased = true end)
    self:Hook("CloseBankFrame", function() 
        if self.frame then self.frame:Hide() end
        self.hooks.CloseBankFrame.orig() 
    end)
    self:BuildFrame()
    
    -- 动态设置银行背包按钮的点击事件
    if self.frame and self.frame.bagFrame then
        -- 找到背包按钮，它通常在银行主框架上
        local bagButton = getglobal(self.frame:GetName() .. "BagButton")
        if bagButton then
            bagButton:SetScript("OnClick", function()
                local bagFrame = this:GetParent().bagFrame
                if bagFrame:IsVisible() then
                    this:SetNormalTexture("Interface\\AddOns\\OneBag\\media\\bags.BLP")
                    this:SetPushedTexture("Interface\\AddOns\\OneBag\\media\\bags.BLP")
                    bagFrame:Hide()
                    -- 侧边栏隐藏时，显示分类标签页
                    -- 检查全局开关 - 从 OneBag 数据库获取
                    local filterVisible = true
                    if OneBag and OneBag.db and OneBag.db.profile then
                        filterVisible = OneBag.db.profile.filterModulesVisible
                    end
                    if filterVisible then
                        if OneBankCategory then
                            OneBankCategory:UpdateButtons()
                        end
                        -- Quality模块不做处理
                    end
                else
                    this:SetNormalTexture("Interface\\AddOns\\OneBag\\media\\bags.BLP")
                    this:SetPushedTexture("Interface\\AddOns\\OneBag\\media\\bags.BLP")
                    bagFrame:Show()
                    -- 侧边栏显示时，隐藏分类标签页
                    if OneBankCategory then
                        OneBankCategory:Hide()
                    end
                    -- Quality模块不做处理
                end
            end)
        end
    end
end

function OneBank:GetDefaults()
    if not self.defaults then
        self.defaults = {
            cols = 12, scale = 1, alpha = 1,
            colors = {
                mouseover = {r = 0, g = .7, b = 1},
                ammo = {r = 1, g = 1, b = 0},
                soul = {r = .5, g = .5, b = 1}, 
                prof = {r = 1, g = 0, b = 1},
                bground = {r = 0, g = 0, b = 0, a = .45},
                glow = false, rarity = true,
            },
            show = {['*'] = true},
            strata = 3, locked = false, clamped = true, confirmCleanup = true, bagBreak = false,
        }
    end
    return self.defaults
end

function OneRing:OnInitialize()
    OneRingFrameName:ClearAllPoints()
    OneRingFrameName:SetPoint("TOPLEFT", "OneRingFrame", "TOPLEFT", 10, -15)
    OneRingFrameName:SetText(L["Keyring"])
    OneRingFrameConfigButton:Hide()
    OneRingFramepackupButton:Hide()
    OneRingFrameBagButton:Hide()
    OneRingFrameMoneyFrame:Hide()
    self.fBags = {-2}
    self.rBags = {-2}
    self.frame = OneRingFrame
    self.frame.handler = self
    self.frame.bags = {}
    self:RegisterDB("OneRingDB")
    self:RegisterDefaults('profile', OneRing:GetDefaults())
end

function OneRing:OnEnable()
    self:RegisterEvent("BAG_UPDATE", function() self:RequestBagUpdate(arg1) end)
    self:RegisterEvent("BAG_UPDATE_COOLDOWN", function()
        if _G.OneBag_SortInProgress then return end
        self:RequestBagUpdate(arg1)
    end)
    self:Hook("ToggleKeyRing", function() if self.frame:IsVisible() then self.frame:Hide() else self.frame:Show() end end)
end

function OneRing:OnCustomShow()
    if not OneBag.frame:IsVisible() then 
        this:ClearAllPoints() 
        this:SetPoint("CENTER", UIParent, "CENTER", 0, 0) 
    else 
        this:ClearAllPoints() 
        this:SetPoint("BOTTOMLEFT", OneBagFrame, "TOPLEFT", 0, 8) 
    end
end

function OneRing:OnCustomHide() end

function OneRing:GetDefaults()
    if not self.defaults then
        self.defaults = {
            cols = 4, scale = 1, alpha = 1,
            colors = {
                mouseover = {r = 0, g = .7, b = 1},
                ammo = {r = 1, g = 1, b = 0},
                soul = {r = .5, g = .5, b = 1}, 
                prof = {r = 1, g = 0, b = 1},
                bground = {r = 0, g = 0, b = 0, a = .45},
                glow = false, rarity = true,
            },
            show = {['*'] = true},
            strata = 3, locked = false, clamped = true, confirmCleanup = true, bagBreak = false,
        }
    end
    return self.defaults
end

BINDING_HEADER_ONEVIEW = "OneView"

function OneView:OnInitialize()
    local LV = AceLibrary and AceLibrary("AceLocale-2.1"):GetInstance("OneView", true) or setmetatable({}, {__index = function(self, key) return key end})
    if not LV["%s's Bank Bags"] then LV["%s's Bank Bags"] = "%s's Bank Bags" end
    if not LV["%s's Bags"] then LV["%s's Bags"] = "%s's Bags" end
    
    local baseArgs = OneCore:GetFreshOptionsTable(self)
    local customArgs = {
        ["0"] = {name = LV["Backpack"] or "Backpack", type = 'toggle', order = 5, desc = LV["Turns display of your backpack on and off."] or "Turns display of your backpack on and off.", get = function() return self.db.profile.show[0] end, set = function(v) self.db.profile.show[0] = v self:OrganizeFrame(true) end},
        ["1"] = {name = LV["First Bag"] or "First Bag", type = 'toggle', order = 6, desc = LV["Turns display of your first bag on and off."] or "Turns display of your first bag on and off.", get = function() return self.db.profile.show[1] end, set = function(v) self.db.profile.show[1] = v self:OrganizeFrame(true) end},
        ["2"] = {name = LV["Second Bag"] or "Second Bag", type = 'toggle', order = 7, desc = LV["Turns display of your second bag on and off."] or "Turns display of your second bag on and off.", get = function() return self.db.profile.show[2] end, set = function(v) self.db.profile.show[2] = v self:OrganizeFrame(true) end},
        ["3"] = {name = LV["Third Bag"] or "Third Bag", type = 'toggle', order = 8, desc = LV["Turns display of your third bag on and off."] or "Turns display of your third bag on and off.", get = function() return self.db.profile.show[3] end, set = function(v) self.db.profile.show[3] = v self:OrganizeFrame(true) end},
        ["4"] = {name = LV["Fourth Bag"] or "Fourth Bag", type = 'toggle', order = 9, desc = LV["Turns display of your fourth bag on and off."] or "Turns display of your fourth bag on and off.", get = function() return self.db.profile.show[4] end, set = function(v) self.db.profile.show[4] = v self:OrganizeFrame(true) end},
        -- 银行包（5-10）的提示用独立的 bank key：此前与普通包共用 key，而 locals.lua 里
        -- 同 key 的后定义（银行包版本）会覆盖前者，导致普通包的悬停提示也显示成"银行包"。
        ["5"] = {name = LV["First Bank Bag"] or "First Bank Bag", type = 'toggle', order = 10, desc = LV["Turns display of your first bank bag on and off."] or "Turns display of your first bank bag on and off.", get = function() return self.db.profile.show[5] end, set = function(v) self.db.profile.show[5] = v self:OrganizeFrame(true) end},
        ["6"] = {name = LV["Second Bank Bag"] or "Second Bank Bag", type = 'toggle', order = 11, desc = LV["Turns display of your second bank bag on and off."] or "Turns display of your second bank bag on and off.", get = function() return self.db.profile.show[6] end, set = function(v) self.db.profile.show[6] = v self:OrganizeFrame(true) end},
        ["7"] = {name = LV["Third Bank Bag"] or "Third Bank Bag", type = 'toggle', order = 12, desc = LV["Turns display of your third bank bag on and off."] or "Turns display of your third bank bag on and off.", get = function() return self.db.profile.show[7] end, set = function(v) self.db.profile.show[7] = v self:OrganizeFrame(true) end},
        ["8"] = {name = LV["Fourth Bank Bag"] or "Fourth Bank Bag", type = 'toggle', order = 13, desc = LV["Turns display of your fourth bank bag on and off."] or "Turns display of your fourth bank bag on and off.", get = function() return self.db.profile.show[8] end, set = function(v) self.db.profile.show[8] = v self:OrganizeFrame(true) end},
        ["9"] = {name = LV["Fifth Bank Bag"] or "Fifth Bank Bag", type = 'toggle', order = 14, desc = LV["Turns display of your fifth bank bag on and off."] or "Turns display of your fifth bank bag on and off.", get = function() return self.db.profile.show[9] end, set = function(v) self.db.profile.show[9] = v self:OrganizeFrame(true) end},
        ["10"] = {name = LV["Sixth Bank Bag"] or "Sixth Bank Bag", type = 'toggle', order = 15, desc = LV["Turns display of your sixth bank bag on and off."] or "Turns display of your sixth bank bag on and off.", get = function() return self.db.profile.show[10] end, set = function(v) self.db.profile.show[10] = v self:OrganizeFrame(true) end},
    }
    OneCore:CopyTable(customArgs, baseArgs.args.show.args)
    baseArgs.args.remember = {
        cmdName = LV["Remember"] or "Remember", guiName = LV["Remember Selection"] or "Remember Selection", type = 'toggle',
        desc = LV["Toggles wether to remember which was the last character you selected."] or "Toggles wether to remember which was the last character you selected.",
        get = function() return self.db.profile.remember end,
        set = function(v) 
            self.db.profile.remember = v 
            if v then
                self.db.account.faction = self.faction 
                self.db.account.characterId = self.charId 
            else
                self.db.account.faction = nil
                self.db.account.characterId = nil
            end
        end,
    }
    self:RegisterDB("OneViewDB")
    self:RegisterDefaults('profile', OneView:GetDefaults())
    self:RegisterChatCommand({"/ov", "/OneView"}, baseArgs, string.upper(self.title))
    self:RegisterChatCommand({"/ovs", "/ovshow"}, {type="execute", func= function() 
            if OneViewFrame:IsVisible() then OneViewFrame:Hide() else OneViewFrame:Show() end
        end})
    self.fBags = {-1, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10}
    self.frame = OneViewFrame
    self.frame.bags = {}
    self.frame.handler = self
    OneBag_SetupMoneyTooltip(OneViewFrameMoneyFrame)
    self.storage = AceLibrary("OneStorage-2.0")
    self.storage:RegisterDB(self, self.db)
    self:RegisterDewdrop(baseArgs)
    self.L = L
    self.LV = LV

    -- 创建搜索框并调整位置（向下移动）
    self:CreateSearchFrame()
-- 找到银行按钮并添加点击事件处理
        -- 找到银行按钮并添加点击事件处理
    local bankButton = getglobal("OneViewFrameBankButton")
    if bankButton then
        bankButton:SetScript("OnClick", function()
            local handler = this:GetParent().handler
            if handler.db.profile.show.bank then
                this:SetNormalTexture("Interface\\AddOns\\OneBag\\media\\bags.BLP")
                this:SetPushedTexture("Interface\\AddOns\\OneBag\\media\\bags.BLP")
                handler.db.profile.show.bank = false
                
                -- 银行隐藏时，隐藏分类和品质模块
                if OneViewCategory then
                    OneViewCategory:Hide()
                end
                if OneViewQuality then
                    OneViewQuality:Hide()
                end
            else
                this:SetNormalTexture("Interface\\AddOns\\OneBag\\media\\bags.BLP")
                this:SetPushedTexture("Interface\\AddOns\\OneBag\\media\\bags.BLP")
                handler.db.profile.show.bank = true
                
                -- 银行显示时，更新分类和品质模块
                -- 分类模块检查全局开关
                local filterVisible = true
                if OneBag and OneBag.db and OneBag.db.profile then
                    filterVisible = OneBag.db.profile.filterModulesVisible
                end
                
                if filterVisible then
                    if OneViewCategory then
                        OneViewCategory:UpdateButtons()
                    end
                else
                    -- 如果全局开关关闭，隐藏分类标签页
                    if OneViewCategory then
                        OneViewCategory:Hide()
                    end
                end
                
                -- 品质模块始终显示
                if OneViewQuality then
                    OneViewQuality:UpdateButtons()
                end
            end
            handler:OrganizeFrame()
        end)
    end
    
    -- 嵌入分类和品质模块
    OneViewCategory:Embed(self)
    OneViewQuality:Embed(self)
end

function OneView:CreateSearchFrame()
    if self.frame.searchFrame then return end
    
    local search = CreateFrame("Frame", self.frame:GetName() .. "SearchFrame", self.frame)
    
    -- 调整搜索框位置：变短并移动到右上角
    search:SetPoint("TOPLEFT", self.frame, "TOPLEFT", 120, -32)  -- 向右移动，从120开始
    search:SetPoint("TOPRIGHT", self.frame, "TOPRIGHT", -140, -15) -- 向左移动，距右边140像素
    
    search:SetHeight(24)
    search:SetBackdrop({
        bgFile = 'Interface\\Tooltips\\UI-Tooltip-Background',
        -- edgeFile = 'Interface\\Tooltips\\UI-Tooltip-Border',
        tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 5, right = 25, top = 5, bottom = 5 }
    })
    search:SetBackdropBorderColor(1, 1, 1, 1)
    search:SetBackdropColor(0, 0, 0, 0)
    search.text = search:CreateFontString(nil, "HIGH", "GameTooltipTextSmall")
    local font, size = search.text:GetFont()
    
    search.edit = CreateFrame("EditBox", nil, search)
    search.edit:SetMaxLetters(20)
    search.edit:SetPoint("LEFT", search, "LEFT", 8, 0)
    search.edit:SetPoint("RIGHT", search, "RIGHT", -30, 0)
    search.edit:SetHeight(20)
    search.edit:SetFont(font, size, "OUTLINE")
    search.edit:SetAutoFocus(false)
    search.edit:SetText(self.L["Search"] or "Search")  
    search.edit:SetTextColor(1,1,1,1)
    search.button = CreateFrame("Button", nil, search)
    search.button:SetWidth(20)
    search.button:SetHeight(20)
    search.button:SetPoint("RIGHT", search, "RIGHT", -5, 0)
    search.button:SetFrameLevel(search:GetFrameLevel() + 2)
    search.button:SetNormalTexture('Interface\\Buttons\\UI-GroupLoot-Pass-Up')
    search.button:SetPushedTexture('Interface\\Buttons\\UI-GroupLoot-Pass-Up')
    search.button:SetHighlightTexture('Interface\\Buttons\\UI-GroupLoot-Pass-Up')
    search.button:EnableMouse(true)
    search.button:RegisterForClicks("LeftButtonUp")
    search.button:Hide()
    self.frame.searchFrame = search
    
    local function resetSearch()
        search.edit:SetText(self.L["Search"] or "Search")   -- 使用self.L["Search"]
        self:ResetSearchFilter()
        search.button:Hide()
    end

    search.edit:SetScript("OnEditFocusGained", function()
        if this:GetText() == (self.L["Search"] or "Search") then   -- 使用self.L["Search"]
            this:SetText("")
        end
    end)

    search.edit:SetScript("OnEditFocusLost", function()
        if this:GetText() == "" then
            resetSearch()
        end
    end)

    search.edit:SetScript("OnTabPressed", function()
        this:ClearFocus()
        resetSearch()
    end)

    search.edit:SetScript("OnEscapePressed", function()
        this:ClearFocus()
        resetSearch()
    end)

    search.button:SetScript("OnClick", function()
        search.edit:ClearFocus()
        resetSearch()
    end)

    search.edit:SetScript("OnTextChanged", function()
        if this:GetText() == (self.L["Search"] or "Search") then   -- 使用self.L["Search"]
            resetSearch()
            return
        end
        
        if not search.button:IsVisible() then
            search.button:Show()
        end
        
        self:SearchFilter()
    end)
    
    return search
end

function OneView:OnEnable()
    self.storage:Initialize()
    if self.frame then self.frame:SetClampedToScreen(true) end
    self:BuildCharSelectOptions()
end

function OneView:BuildFrame()
    if not self.frame.bags[-1] then 
        self.frame.bags[-1] = CreateFrame("Frame", "OVBankBag", self.frame)
        self.frame.bags[-1]:SetID(-1)
        self.frame.bags[-1].size = 24
        for slot = 1, 24 do
            self.frame.bags[-1][slot] = CreateFrame("Button", self.frame.bags[-1]:GetName().."Item"..slot, self.frame.bags[-1], "OneViewItemButtonTemplate")
            self.frame.bags[-1][slot]:SetID(slot)
        end
    end
    for bag = 0, 10 do        
        local itemId, size, isAmmo, isSoul, isProf = self.storage:BagInfo(self.faction, self.charId, bag)
        for slot = 1, (tonumber(size) or 0) do
            if not self.frame.bags[bag] then 
                self.frame.bags[bag] = CreateFrame("Frame", tostring(self)..bag, self.frame)
                self.frame.bags[bag]:SetID(bag)
            end
            if not self.frame.bags[bag][slot] then
                self.frame.bags[bag][slot] = CreateFrame("Button", tostring(self)..bag.."Item"..slot, self.frame.bags[bag], "OneViewItemButtonTemplate")
                self.frame.bags[bag][slot]:SetID(slot)
            end
        end
        if self.frame.bags[bag] then
            local curBag = self.frame.bags[bag]
            curBag.itemId, curBag.size, curBag.isAmmo, curBag.isSoul, curBag.isProf = itemId, size or 0, isAmmo, isSoul, isProf
        end
    end
end

function OneView:OrganizeFrame(needs)
    local cols, curCol, curRow = self.db.profile.cols, 1, 1
    local lastslot
    self.bankSoulSlots, self.bankAmmoSlots, self.bankProfSlots, self.bankSlotCount, self.bankTotalCount = 0, 0, 0, 0, 0
    self.invSoulSlots, self.invAmmoSlots, self.invProfSlots, self.invSlotCount, self.invTotalCount = 0, 0, 0, 0, 0
    for bag = -1, 10 do 
        if self.frame.bags[bag] then for k2, v2 in ipairs(self.frame.bags[bag]) do v2:Hide() end end
        local curBag = getglobal("OneViewFrameBag" .. bag)
        if curBag and not self.db.profile.show.bank and bag > 4 then
            curBag:Hide()
        elseif curBag and not self.db.profile.show.inventory and bag < 5 and bag > 0 then
            curBag:Hide()
        elseif curBag then curBag:Show() end
    end
    for k, bag in {-1, 5, 6, 7, 8, 9, 10} do
        local curBag = self.frame.bags[bag]
        if curBag and curBag.size and curBag.size > 0 then
            if curBag.isAmmo then
                self.bankAmmoSlots = self.bankAmmoSlots + curBag.size
            elseif curBag.isSoul then
                self.bankSoulSlots = self.bankSoulSlots + curBag.size
            elseif curBag.isProf then
                self.bankProfSlots = self.bankProfSlots + curBag.size
            else
                self.bankSlotCount = self.bankSlotCount + curBag.size
            end
            if self.db.profile.show.bank then
                if self:ShouldShow(bag, curBag.isAmmo, curBag.isSoul, curBag.isProf) then
                    self.bankTotalCount = self.bankTotalCount + curBag.size
                    for slot = 1, curBag.size do
                        curBag[slot]:ClearAllPoints()
                        curBag[slot]:SetPoint("TOPLEFT", self.frame:GetName(), "TOPLEFT", self.leftBorder + (self.colWidth * (curCol - 1)) , 0 - self.topBorder - (self.rowHeight * curRow))
                        curBag[slot]:Show()                
                        if curCol == 1 then lastslot = curBag[slot] end
                        curCol = curCol + 1
                        if curCol > cols then curCol, curRow = 1, curRow + 1 end
                    end
                end
            else curRow = curRow + .1 end
        end
    end
    OneViewFrameBankInfo1:ClearAllPoints()
    if self.db.profile.show.bagslots and lastslot then
        OneViewFrameBag5:ClearAllPoints()
        OneViewFrameBag5:SetPoint("TOPLEFT", lastslot, "BOTTOMLEFT", 0, -10)
        OneViewFrameBankInfo1:SetPoint("TOPLEFT", OneViewFrameBag5, "BOTTOMLEFT", 0, -10)
        for i = 5, 10 do getglobal("OneViewFrameBag" .. i):Show() end
    elseif lastslot then
        for i = 5, 10 do getglobal("OneViewFrameBag" .. i):Hide() end
        curRow = curRow - 1
        OneViewFrameBankInfo1:SetPoint("TOPLEFT", lastslot, "BOTTOMLEFT", 0, -10)
    else
        for i = 5, 10 do getglobal("OneViewFrameBag" .. i):Hide() end
        curRow = curRow - 1
        OneViewFrameBankInfo1:SetPoint("TOPLEFT", OneViewFrameBankButton, "BOTTOMLEFT", 5, -10)
    end
    lastslot = nil
    curCol = 1
    curRow = curRow + (self.db.profile.show.bank and 3.5 or 2)
    for bag = 0, 4 do
        local curBag = self.frame.bags[bag]
        if curBag and curBag.size and curBag.size > 0 then
            if curBag.isAmmo then
                self.invAmmoSlots = self.invAmmoSlots + curBag.size
            elseif curBag.isSoul then
                self.invSoulSlots = self.invSoulSlots + curBag.size
            elseif curBag.isProf then
                self.invProfSlots = self.invProfSlots + curBag.size
            else
                self.invSlotCount = self.invSlotCount + curBag.size
            end
            if self.db.profile.show.inventory then
                if self:ShouldShow(bag, curBag.isAmmo, curBag.isSoul, curBag.isProf) then
                    self.invTotalCount = self.invTotalCount + curBag.size
                    for slot = 1, curBag.size do
                        curBag[slot]:ClearAllPoints()
                        curBag[slot]:SetPoint("TOPLEFT", self.frame:GetName(), "TOPLEFT", self.leftBorder + (self.colWidth * (curCol - 1)) , 0 - self.topBorder - (self.rowHeight * curRow))
                        curBag[slot]:Show()                
                        if curCol == 1 then lastslot = curBag[slot] end
                        curCol = curCol + 1
                        if curCol > cols then curCol, curRow = 1, curRow + 1 end
                    end
                end
                local invButton = getglobal(self.frame:GetName() .. "InventoryButton")
                invButton:ClearAllPoints()
                invButton:SetPoint("BOTTOMLEFT", self.frame.bags[0][1]:GetName(), "TOPLEFT", -5, 0)
            else
                local invButton = getglobal(self.frame:GetName() .. "InventoryButton")
                invButton:ClearAllPoints()
                invButton:SetPoint("BOTTOMLEFT", self.frame:GetName(), "BOTTOMLEFT", 3, 24)
            end
        end
    end
    OneViewFrameInventoryInfo1:ClearAllPoints()
    if self.db.profile.show.bagslots and lastslot then
        curRow = curRow + 1
        OneViewFrameBag1:ClearAllPoints()
        OneViewFrameBag1:SetPoint("TOPLEFT", lastslot, "BOTTOMLEFT", 0, -10)
        OneViewFrameInventoryInfo1:SetPoint("TOPLEFT", OneViewFrameBag1, "BOTTOMLEFT", 0, -5)
        for i = 1, 4 do getglobal("OneViewFrameBag" .. i):Show() end
    elseif lastslot then
        for i = 1, 4 do getglobal("OneViewFrameBag" .. i):Hide() end
        OneViewFrameInventoryInfo1:SetPoint("TOPLEFT", lastslot, "BOTTOMLEFT", 0, -5)
    else
        for i = 1, 4 do getglobal("OneViewFrameBag" .. i):Hide() end
        OneViewFrameInventoryInfo1:SetPoint("TOPLEFT", OneViewFrameInventoryButton, "BOTTOMLEFT", 5, -4)
    end
    if math.mod(self.invTotalCount, cols) ~= 0 then curRow = curRow + 1 end
    self.frame:SetHeight(curRow * self.rowHeight + self.bottomBorder + self.topBorder) 
    self.frame:SetWidth(cols * self.colWidth + self.leftBorder + self.rightBorder)
    OneViewFrameInventoryName:ClearAllPoints()
    OneViewFrameInventoryName:SetPoint("LEFT", OneViewFrameInventoryButton, "RIGHT", 5, 1)
    OneViewFrameBankName:ClearAllPoints()
    OneViewFrameBankName:SetPoint("LEFT", OneViewFrameBankButton, "RIGHT", 5, 1)
    local bankBagsText = self.LV and self.LV["%s's Bank Bags"] or self.L and self.L["%s's Bank Bags"] or "%s's Bank Bags"
    local bagsText = self.LV and self.LV["%s's Bags"] or self.L and self.L["%s's Bags"] or "%s's Bags"
    OneViewFrameBankName:SetText(format(bankBagsText, self.charId or ""))
    OneViewFrameInventoryName:SetText(format(bagsText, self.charId or ""))
end

function OneView:FillBags()
    for bag = -1, 10 do
        local curBag = self.frame.bags[bag]
        if curBag and curBag.size and curBag.size > 0 then
            for slot = 1, curBag.size do
                local itemId, qty = self.storage:SlotInfo(self.faction, self.charId, bag, slot)
                if itemId then
                    local itemName, itemLink, itemQuality, itemLevel, itemType, itemSubType, itemCount, itemEquipLoc, itemTexture = GetItemInfo(itemId)
                    getglobal(curBag[slot]:GetName() .. "IconTexture"):SetTexture(itemTexture)
                    getglobal(curBag[slot]:GetName() .. "IconTexture"):Show()
                    if qty > 1 then
                        getglobal(curBag[slot]:GetName() .. "Count"):SetText(qty)
                        getglobal(curBag[slot]:GetName() .. "Count"):Show()
                    else
                        getglobal(curBag[slot]:GetName() .. "Count"):SetText("")
                        getglobal(curBag[slot]:GetName() .. "Count"):Hide()
                    end
                    curBag[slot].itemId = itemId
                    curBag[slot].itemQuality = itemQuality
                    curBag[slot].qty = qty
                    
                    -- 为OneView添加任务标志
                    local isQuestItem = (itemType == "Quest" or itemType == "任务" or itemType == "Key" or itemType == "钥匙")
                    local questIcon = curBag[slot].QuestIcon
                    if isQuestItem then
                        if not questIcon then
                            questIcon = curBag[slot]:CreateTexture(nil, "OVERLAY")
                            questIcon:SetTexture("Interface\\AddOns\\OneBag\\media\\questicon")
                            questIcon:SetWidth(16)
                            questIcon:SetHeight(16)
                            questIcon:SetPoint("TOPLEFT", curBag[slot], "TOPLEFT", 2, -2)
                            questIcon:SetAlpha(0.9)
                            curBag[slot].QuestIcon = questIcon
                        end
                        questIcon:Show()
                    elseif questIcon then
                        questIcon:Hide()
                    end
                else
                    getglobal(curBag[slot]:GetName() .. "IconTexture"):Hide()
                    getglobal(curBag[slot]:GetName() .. "Count"):Hide()
                    curBag[slot].itemId = nil
                    curBag[slot].itemQuality = nil
                    curBag[slot].qty = nil
                    if curBag[slot].QuestIcon then
                        curBag[slot].QuestIcon:Hide()
                    end
                end
                self:SetBorderColor(curBag[slot])
            end
        end
        local bagSlot = getglobal("OneViewFrameBag" .. bag)
        if bagSlot then 
            local itemId = self.storage:BagInfo(self.faction, self.charId, bag)
            if itemId then 
                local itemName, itemLink, itemQuality, itemLevel, itemType, itemSubType, itemCount, itemEquipLoc, itemTexture = GetItemInfo(itemId)
                getglobal(bagSlot:GetName() .. "IconTexture"):SetTexture(itemTexture)
                getglobal(bagSlot:GetName() .. "IconTexture"):Show()
                bagSlot.itemId = itemId
            else
                getglobal(bagSlot:GetName() .. "IconTexture"):Hide()
                bagSlot.itemId = nil
            end
        end
    end
    MoneyFrame_Update(self.frame:GetName().."MoneyFrame", self.storage:GetMoney(self.faction, self.charId) or 0)
    self:DoBankSlotCounts()
    self:DoInventorySlotCounts()
    
    -- 应用分类和品质过滤
    if OneViewCategory then
        OneViewCategory:ApplyFilter()
    end
    if OneViewQuality then
        OneViewQuality:ApplyFilter()
    end
end

function OneView:SetBorderColor(slot)        
    local color = {r = 1, g = 1, b = 1}
    local bag = slot:GetParent()
    local special = false
    if bag.isAmmo then 
        color = self.db.profile.colors.ammo
        special = true
    elseif bag.isSoul then
        color = self.db.profile.colors.soul
        special = true
    elseif bag.isProf then
        color = self.db.profile.colors.prof
        special = true
    elseif self.db.profile.colors.rarity and slot.itemQuality then
        color = ITEM_QUALITY_COLORS[slot.itemQuality]
        if slot.itemQuality > 1 then special = true end
    end
    if special and self.db.profile.colors.glow then        
        slot:SetNormalTexture("Interface\\Buttons\\UI-ActionButton-Border")
        slot:GetNormalTexture():SetBlendMode("ADD")
        slot:GetNormalTexture():SetAlpha(.8)
        slot:GetNormalTexture():SetPoint("CENTER", slot:GetName(), "CENTER", 0, 1)
    elseif special then
        slot:SetNormalTexture("Interface\\AddOns\\OneBag\\media\\BagSlot2")
        slot:GetNormalTexture():SetBlendMode("BLEND")
        slot:GetNormalTexture():SetPoint("CENTER", slot:GetName(), "CENTER", 0, 0)
    else
        slot:SetNormalTexture("Interface\\AddOns\\OneBag\\media\\BagSlot")
        slot:GetNormalTexture():SetBlendMode("BLEND")
        slot:GetNormalTexture():SetPoint("CENTER", slot:GetName(), "CENTER", 0, 0)
    end
    slot:GetNormalTexture():SetVertexColor(color.r, color.g, color.b)
end

function OneView:DoBankSlotCounts()
    local soulStoneCount = 0
    local usedSlots, usedAmmoSlots, usedSoulSlots, usedProfSlots, ammoQuantity = 0, 0, 0, 0, 0 
    for k, bag in {-1, 5, 6, 7, 8, 9, 10} do
        if self.frame.bags[bag] then
            local tmp, qty = 0, 0
            for slot = 1, self.frame.bags[bag].size do
                if self.frame.bags[bag][slot].itemId then 
                    tmp = tmp + 1 
                    qty = qty + self.frame.bags[bag][slot].qty
                    -- 按物品 ID 统计灵魂石真实数量（乌龟服 1 格叠 3 个，且灵魂袋可放其它召唤恶魔物品）
                    if self.frame.bags[bag][slot].itemId == SOUL_STONE_ID then
                        soulStoneCount = soulStoneCount + (self.frame.bags[bag][slot].qty or 1)
                    end
                end
            end
            if self.frame.bags[bag].isAmmo then
                usedAmmoSlots = usedAmmoSlots + tmp
                ammoQuantity = ammoQuantity + qty
            elseif self.frame.bags[bag].isSoul then
                usedSoulSlots = usedSoulSlots + tmp
            elseif self.frame.bags[bag].isProf then
                usedProfSlots = usedProfSlots + tmp
            else
                usedSlots = usedSlots + tmp
            end
        end
    end
    local info = 1
    local name = self.frame:GetName() .. "BankInfo"    

getglobal(name .. info):SetText(format(L["%s/%s Slots"], usedSlots, self.bankSlotCount))
    info = info + 1
    for i = 2, 4 do getglobal(name .. i):SetText("") end
    if self.db.profile.show.counts then
        if self.bankAmmoSlots > 0 then
            getglobal(name .. info):SetText(format(L["%s/%s Ammo"], ammoQuantity, self.bankAmmoSlots * 200))
            info = info + 1
        end
        if self.bankSoulSlots > 0 or soulStoneCount > 0 then
            getglobal(name .. info):SetText(format(L["Soul Stones: %s"], soulStoneCount))
            info = info + 1
        end
        if self.bankProfSlots > 0 then
            getglobal(name .. info):SetText(format(L["%s/%s Profession Slots"], usedProfSlots, self.bankProfSlots))
            info = info + 1
        end
    end
end

function OneView:DoInventorySlotCounts()
    local soulStoneCount = 0
    local usedSlots, usedAmmoSlots, usedSoulSlots, usedProfSlots, ammoQuantity = 0, 0, 0, 0, 0 
    for bag = 0, 4 do
        if self.frame.bags[bag] then
            local tmp, qty = 0, 0
            for slot = 1, self.frame.bags[bag].size do
                if self.frame.bags[bag][slot].itemId then 
                    tmp = tmp + 1 
                    qty = qty + self.frame.bags[bag][slot].qty
                    -- 按物品 ID 统计灵魂石真实数量（乌龟服 1 格叠 3 个，且灵魂袋可放其它召唤恶魔物品）
                    if self.frame.bags[bag][slot].itemId == SOUL_STONE_ID then
                        soulStoneCount = soulStoneCount + (self.frame.bags[bag][slot].qty or 1)
                    end
                end
            end
            if self.frame.bags[bag].isAmmo then
                usedAmmoSlots = usedAmmoSlots + tmp
                ammoQuantity = ammoQuantity + qty
            elseif self.frame.bags[bag].isSoul then
                usedSoulSlots = usedSoulSlots + tmp
            elseif self.frame.bags[bag].isProf then
                usedProfSlots = usedProfSlots + tmp
            else
                usedSlots = usedSlots + tmp
            end
        end
    end
    local info = 1
    local name = self.frame:GetName() .. "InventoryInfo"    
    getglobal(name .. info):SetText(format(L["%s/%s Slots"], usedSlots, self.invSlotCount))
    info = info + 1
    for i = 2, 4 do getglobal(name .. i):SetText("") end
    if self.db.profile.show.counts then
        if self.invAmmoSlots > 0 then
            getglobal(name .. info):SetText(format(L["%s/%s Ammo"], ammoQuantity, self.invAmmoSlots * 200))
            info = info + 1
        end
        if self.invSoulSlots > 0 or soulStoneCount > 0 then
            getglobal(name .. info):SetText(format(L["Soul Stones: %s"], soulStoneCount))
            info = info + 1
        end
        if self.invProfSlots > 0 then
            getglobal(name .. info):SetText(format(L["%s/%s Profession Slots"], usedProfSlots, self.invProfSlots))
            info = info + 1
        end
    end
end

function OneView:BuildCharSelectOptions()
    local list = self.storage:GetCharListByServerId()
    local args = {type="group", args = {}}
    for serverId, v in pairs(list) do
        local _, _, server, faction = string.find(serverId, "(.+) . (.+)")

        local serverKey = string.gsub(server, "%s", "")

        local key = serverKey..faction
        args.args[key] = {name = serverId, type = 'group', desc = (self.LV and self.LV["Characters on "] or "Characters on ")..serverId, args = {}}
        
        for k, v2 in pairs(v) do
            local fact = faction
            local _, _, charName, charId = string.find(v2, "(.+) . (.+)")

        local charKey = string.gsub(charName, "%s", "")
            
            local func = function() self:LoadCharacter(fact, charId) end
            args.args[key].args[charKey] = {name = charName, type = 'execute', func = func, desc = charName}
        end
    end

    -- 单个删除子菜单：与离线银行按钮中键菜单共用构建逻辑
    if self.storage and self.storage.db and self.storage.db.account then
        local delArgs, delTotal = self:BuildCharDeleteArgs()
        if delTotal > 0 then
            args.args["oneviewDeleteChars"] = {name = "删除角色数据…", type = 'group', desc = "删除单个角色的离线银行数据", args = delArgs.args}
        end
    end

    self.dewdrop:Register(OneViewFrameCharSelectButton, 'children', args, 'point',
        function(parent)
            if parent:GetTop() < GetScreenHeight() / 2 then 
                return "BOTTOMLEFT", "TOPLEFT" 
            else 
                return "TOPLEFT", "BOTTOMLEFT" 
            end
        end, 
        'dontHook', true)
end

function OneView:CharSelect()
    if self.dewdrop:IsOpen(getglobal(self.frame:GetName() .. "CharSelectButton")) then
        self.dewdrop:Close()
    else
        self.dewdrop:Open(getglobal(self.frame:GetName() .. "CharSelectButton"), OneViewFrameCharSelectButton)
    end
end

function OneView:LoadCharacter(faction, characterId)
    faction = faction or self.db.account.faction or AceLibrary("AceDB-2.0").FACTION
    characterId = characterId or self.db.account.characterId or AceLibrary("AceDB-2.0").CHAR_ID
    if self.db.profile.remember then
        self.db.account.faction = faction
        self.db.account.characterId = characterId
    end
    self.faction = faction
    self.charId = characterId
    self:BuildFrame()
    self:OrganizeFrame()
    self:FillBags()
    
    -- 重置搜索框
    if self.frame.searchFrame then
        self.frame.searchFrame.edit:SetText(self.L["Search"] or "Search")
        self.frame.searchFrame.button:Hide()
        self:ResetSearchFilter()
    end
    
    -- 重置分类和品质过滤
    if OneViewCategory then
        OneViewCategory:SetActiveCategory()
    end
    if OneViewQuality then
        OneViewQuality:SetActiveQuality()
    end
    
    -- 重新应用显示逻辑（根据银行是否显示）
    local bankVisible = self.db.profile.show.bank
    
    if bankVisible then
        -- 分类模块检查全局开关
        local filterVisible = true
        if OneBag and OneBag.db and OneBag.db.profile then
            filterVisible = OneBag.db.profile.filterModulesVisible
        end
        
        if filterVisible then
            if OneViewCategory then
                OneViewCategory:UpdateButtons()
            end
        else
            if OneViewCategory then
                OneViewCategory:Hide()
            end
        end
        
        -- 品质模块始终显示
        if OneViewQuality then
            OneViewQuality:UpdateButtons()
        end
    else
        -- 如果银行部分不显示，隐藏分类和品质模块
        if OneViewCategory then
            OneViewCategory:Hide()
        end
        if OneViewQuality then
            OneViewQuality:Hide()
        end
    end
end

-- 清理所有账号的离线银行数据（银行/背包离线存档）
function OneView:ClearOtherOfflineData()
    if not self.storage or not self.storage.db or not self.storage.db.account then
        DEFAULT_CHAT_FRAME:AddMessage("|cFFFF0000[OneBag] 离线银行数据未就绪，无法清理！|r")
        return
    end
    -- 保留当前登录角色的数据，只清理其他角色的离线银行/背包存档
    local AceDB = AceLibrary("AceDB-2.0")
    local curFaction = AceDB.FACTION
    local curCharId = AceDB.CHAR_ID
    local acc = self.storage.db.account
    local cleared = 0
    for faction, chars in pairs(acc) do
        if type(chars) == "table" then
            for charId in pairs(chars) do
                if not (faction == curFaction and charId == curCharId) then
                    chars[charId] = nil
                    cleared = cleared + 1
                end
            end
            -- 该 faction 下已无其他角色则清掉空表（被保留的当前角色仍会留着）
            if not next(chars) then
                acc[faction] = nil
            end
        end
    end
    -- 若“记住的角色”指向已被删除的角色，则重置为当前角色
    if self.db and self.db.account and self.db.account.faction and self.db.account.characterId then
        if not (self.db.account.faction == curFaction and self.db.account.characterId == curCharId) then
            self.db.account.faction = curFaction
            self.db.account.characterId = curCharId
        end
    end
    DEFAULT_CHAT_FRAME:AddMessage("|cFF00FF00[OneBag] 已清理其他角色的离线银行数据（保留当前角色），共 " .. cleared .. " 个角色。|r")
    -- 无条件重建角色选择下拉注册，保证与中键删除菜单同步
    -- （中键菜单每次打开时重新注册，天然同步；角色下拉必须主动重建）
    if self.dewdrop and self.frame then
        local csBtn = getglobal(self.frame:GetName() .. "CharSelectButton")
        if csBtn then
            local wasOpen = self.dewdrop:IsOpen(csBtn)
            if wasOpen then self.dewdrop:Close() end
            pcall(self.BuildCharSelectOptions, self)
            if wasOpen then self.dewdrop:Open(csBtn, csBtn) end
        end
    end
    -- 若离线银行界面已打开，立即刷新（用 pcall 兜底，刷新失败也不影响已完成的清理）
    if OneViewFrame and OneViewFrame:IsVisible() then
        pcall(function()
            self:FillBags()
        end)
    end
end

-- 删除单个角色的离线银行数据（交互对齐自定义材料的单个删除）
-- faction/charId 与角色选择下拉（BuildCharSelectOptions）解析出的键一致，即 storage.db.account[faction][charId]
function OneView:DeleteOfflineCharacter(faction, charId, charName)
    if not self.storage or not self.storage.db or not self.storage.db.account then
        DEFAULT_CHAT_FRAME:AddMessage("|cFFFF0000[OneBag] 离线银行数据未就绪，无法删除！|r")
        return
    end
    local AceDB = AceLibrary("AceDB-2.0")
    -- 当前角色的数据由游戏实时写入存档，删了也会被重新生成，不允许在此删除
    if faction == AceDB.FACTION and charId == AceDB.CHAR_ID then
        DEFAULT_CHAT_FRAME:AddMessage("|cFFFF0000[OneBag] 当前角色的数据由登录时实时生成，不能在此删除。|r")
        return
    end
    local acc = self.storage.db.account
    if not (acc[faction] and acc[faction][charId]) then
        DEFAULT_CHAT_FRAME:AddMessage("|cFFFF0000[OneBag] 未找到该角色的离线数据。|r")
        return
    end
    acc[faction][charId] = nil
    if not next(acc[faction]) then acc[faction] = nil end
    -- “记住的角色”指向被删角色时，重置为当前角色
    if self.db and self.db.account and self.db.account.faction and self.db.account.characterId then
        if self.db.account.faction == faction and self.db.account.characterId == charId then
            self.db.account.faction = AceDB.FACTION
            self.db.account.characterId = AceDB.CHAR_ID
        end
    end
    DEFAULT_CHAT_FRAME:AddMessage("|cFF00FF00[OneBag] 已删除 " .. (charName or charId) .. " 的离线银行数据。|r")
    -- 两个删除入口的列表同步（dewdrop 菜单是静态构建的，必须重建）：
    -- 中键菜单开着 → 就地重建；角色下拉不管开没开着 → 一律重建注册（开着则关闭后重开）
    if self.dewdrop then
        if self._deleteMenuButton and self.dewdrop:IsOpen(self._deleteMenuButton) then
            self.dewdrop:Close()
            self:OpenCharDeleteMenu(self._deleteMenuButton)
        end
        if self.frame then
            local csBtn = getglobal(self.frame:GetName() .. "CharSelectButton")
            if csBtn then
                local wasOpen = self.dewdrop:IsOpen(csBtn)
                if wasOpen then self.dewdrop:Close() end
                self:BuildCharSelectOptions()
                if wasOpen then self.dewdrop:Open(csBtn, csBtn) end
            end
        end
    end
    -- 界面刷新：正在查看被删角色则切回当前角色
    if OneViewFrame and OneViewFrame:IsVisible() then
        pcall(function()
            if self.charId == charId then
                self:LoadCharacter(AceDB.FACTION, AceDB.CHAR_ID)
            end
            self:FillBags()
        end)
    end
end

-- 构建“单个删除”的角色列表（离线银行按钮中键菜单 与 角色选择下拉子菜单 共用）
-- 返回 args 表与可删角色总数；空列表时给出占位项
function OneView:BuildCharDeleteArgs()
    local AceDB = AceLibrary("AceDB-2.0")
    local args = {type="group", args = {}}
    local total = 0
    if self.storage and self.storage.GetCharListByServerId then
        local list = self.storage:GetCharListByServerId()
        for serverId, v in pairs(list) do
            local _, _, server, faction = string.find(serverId, "(.+) . (.+)")
            if server and faction then
                local serverKey = string.gsub(server, "%s", "")
                local key = serverKey..faction
                args.args[key] = {name = serverId, type = 'group', desc = serverId, args = {}}
                for k, v2 in pairs(v) do
                    local _, _, charName, charId = string.find(v2, "(.+) . (.+)")
                    if charName and charId then
                        local charKey = string.gsub(charName, "%s", "")
                        local isCurrent = (faction == AceDB.FACTION and charId == AceDB.CHAR_ID)
                        args.args[key].args[charKey] = {
                            name = isCurrent and (charName .. "（当前角色）") or charName,
                            type = 'execute',
                            desc = isCurrent and "当前角色的数据由登录时实时生成，不能删除" or ("删除 " .. charName .. " 的离线银行数据"),
                            func = function() self:DeleteOfflineCharacter(faction, charId, charName) end,
                        }
                        total = total + 1
                    end
                end
            end
        end
    end
    if total == 0 then
        args.args["none"] = {name = "（没有可删除的离线角色数据）", type = 'execute', func = function() end, desc = "没有可删除的离线角色数据"}
    end
    return args, total
end

-- 单个删除菜单：逐服务器/角色列出离线数据，点谁删谁（仿自定义材料的删除菜单）
function OneView:OpenCharDeleteMenu(button)
    if not self.dewdrop then return end
    if not self.storage or not self.storage.db or not self.storage.db.account then
        DEFAULT_CHAT_FRAME:AddMessage("|cFFFF0000[OneBag] 离线银行数据未就绪！|r")
        return
    end
    if self.dewdrop:IsOpen(button) then
        self.dewdrop:Close()
        return
    end
    -- 记住按钮引用：单删成功后就地重建菜单用
    self._deleteMenuButton = button
    local args, total = self:BuildCharDeleteArgs()
    if total == 0 then
        DEFAULT_CHAT_FRAME:AddMessage("[OneBag] 没有可删除的离线角色数据。")
        return
    end
    self.dewdrop:Register(button, 'children', args, 'point',
        function(parent)
            if parent:GetTop() < GetScreenHeight() / 2 then
                return "BOTTOMLEFT", "TOPLEFT"
            else
                return "TOPLEFT", "BOTTOMLEFT"
            end
        end,
        'dontHook', true)
    self.dewdrop:Open(button)
end

function OneView:LinkItem(itemId)
    local name, link, quality = GetItemInfo(itemId)
    if ChatFrameEditBox:IsShown() then
        ChatFrameEditBox:Insert(format("%s|H%s|h[%s]|h|r", ITEM_QUALITY_COLORS[quality].hex, link, name))
    end    
end

function OneView:OnCustomShow() 
    if self.db.profile.point then
        local point = self.db.profile.point
        this:ClearAllPoints()
        this:SetPoint("TOPLEFT", point.parent, "BOTTOMLEFT", point.left, point.top)
    end

    -- 确保搜索框显示
    if self.frame.searchFrame then
        self.frame.searchFrame:Show()
    end
    
    -- OneView没有bagFrame，但有bank按钮切换银行显示
    local bankVisible = self.db.profile.show.bank
    
    -- 分类模块的显示逻辑 - 只在银行显示时检查
    if bankVisible then
        -- 检查全局开关 - 从 OneBag 数据库获取
        local filterVisible = true
        if OneBag and OneBag.db and OneBag.db.profile then
            filterVisible = OneBag.db.profile.filterModulesVisible
        end
        
        if filterVisible then
            if OneViewCategory then
                OneViewCategory:UpdateButtons()
            end
        else
            -- 如果全局开关关闭，隐藏分类标签页
            if OneViewCategory then
                OneViewCategory:Hide()
            end
        end
    else
        -- 如果银行部分不显示，隐藏分类标签页
        if OneViewCategory then
            OneViewCategory:Hide()
        end
    end
    
    -- 品质模块的显示逻辑 - 始终显示（当银行显示时）
    if bankVisible then
        if OneViewQuality then
            OneViewQuality:UpdateButtons()
        end
    else
        -- 如果银行部分不显示，隐藏品质模块
        if OneViewQuality then
            OneViewQuality:Hide()
        end
    end
end

function OneView:OnCustomHide()
    -- 如果有搜索框，可以在隐藏时重置搜索
    if self.frame.searchFrame then
        self.frame.searchFrame.edit:SetText(self.L["Search"] or "Search")
        self.frame.searchFrame.button:Hide()
        self:ResetSearchFilter()
    end
    
    -- 隐藏分类和品质按钮
    if OneViewCategory then
        OneViewCategory:Hide()
    end
    if OneViewQuality then
        OneViewQuality:Hide()
    end
end

-- 在 OneView 模块中，需要重写搜索过滤函数，因为OneView使用的是离线数据：
function OneView:SearchFilter()
    local searchText = self.frame.searchFrame.edit:GetText()
    if not searchText or searchText == "" or searchText == (self.L["Search"] or "Search") then
        self:ResetSearchFilter()
        return
    end
    
    searchText = string.lower(searchText)
    
    for k, bag in self.fBags do
        if self.frame.bags[bag] then
            for slot = 1, self.frame.bags[bag].size do
                local item = self.frame.bags[bag][slot]
                if item and item:IsVisible() then
                    if item.itemId then
                        local itemName = GetItemInfo(item.itemId) or ""
                        -- 同时检查分类和品质过滤
                        local categoryMatch = true
                        local qualityMatch = true
                        
                        if OneViewCategory and OneViewCategory:GetActiveCategory() then
                            local category = OneViewCategory:GetItemCategory(item.itemId)
                            categoryMatch = (category == OneViewCategory:GetActiveCategory())
                        end
                        
                        if OneViewQuality and OneViewQuality:GetActiveQuality() then
                            local _, _, quality = GetItemInfo(item.itemId)
                            qualityMatch = (OneViewQuality:GetActiveQuality() == 1 and (quality == 0 or quality == 1)) or (quality == OneViewQuality:GetActiveQuality())
                        end
                        
                        if string.find(string.lower(itemName), searchText) and categoryMatch and qualityMatch then
                            item:SetAlpha(1)
                        else
                            item:SetAlpha(0.25)
                        end
                    else
                        item:SetAlpha(0.25)
                    end
                end
            end
        end
    end
end

function OneView:ResetSearchFilter()
    for k, bag in self.fBags do
        if self.frame.bags[bag] then
            for slot = 1, self.frame.bags[bag].size do
                local item = self.frame.bags[bag][slot]
                if item then
                    -- 应用分类和品质过滤
                    local categoryMatch = true
                    local qualityMatch = true
                    
                    if OneViewCategory and OneViewCategory:GetActiveCategory() then
                        local category = item.itemId and OneViewCategory:GetItemCategory(item.itemId) or "misc"
                        categoryMatch = (category == OneViewCategory:GetActiveCategory())
                    end
                    
                    if OneViewQuality and OneViewQuality:GetActiveQuality() then
                        local _, _, quality = item.itemId and GetItemInfo(item.itemId) or 0
                        qualityMatch = (OneViewQuality:GetActiveQuality() == 1 and (quality == 0 or quality == 1)) or (quality == OneViewQuality:GetActiveQuality())
                    end
                    
                    if categoryMatch and qualityMatch then
                        item:SetAlpha(1)
                    else
                        item:SetAlpha(0.25)
                    end
                end
            end
        end
    end
end

function OneView:GetDefaults()
    if not self.defaults then
        self.defaults = {
            cols = 12, scale = 1, alpha = 1,
            colors = {
                mouseover = {r = 0, g = .7, b = 1},
                ammo = {r = 1, g = 1, b = 0},
                soul = {r = .5, g = .5, b = 1}, 
                prof = {r = 1, g = 0, b = 1},
                bground = {r = 0, g = 0, b = 0, a = .45},
                glow = false, rarity = true,
            },
            show = {['*'] = true},
            strata = 3, locked = false, clamped = true, confirmCleanup = true, bagBreak = false,
            remember = true,  -- 是否记住最后选择的角色
        }
    end
    return self.defaults
end

-- 文件末尾添加使用说明
local function PrintHelp()
    DEFAULT_CHAT_FRAME:AddMessage("|cFF00FF00[OneBag] 分类过滤模块控制命令:|r")
    DEFAULT_CHAT_FRAME:AddMessage("|cFFFFFF00/obtogglefilters 或 /obtf - 切换过滤模块的显示/隐藏|r")
    DEFAULT_CHAT_FRAME:AddMessage("|cFFFFFF00在插件设置菜单中也可以找到此选项|r")
end

-- 注册帮助命令
SlashCmdList["ONEBAG_HELP"] = PrintHelp
SLASH_ONEBAG_HELP1 = "/obhelp"
SLASH_ONEBAG_HELP2 = "/onebaghelp"

--=============================================================================
-- 材料计数：命令行增删自定义物品（与菜单「材料计数 → 添加物品 ID」等价）
--   /obitem 17020      添加（也可用完整物品链接中的数字 ID）
--   /obitemdel 17020   移除
--=============================================================================
local function ExtractItemID(msg)
    if type(msg) ~= "string" then return nil end
    local id = tonumber(msg)
    if id then return id end
    local fromLink = string.match(msg, "item:(%d+)")
    if fromLink then return tonumber(fromLink) end
    return nil
end

SlashCmdList["ONEBAGITEM"] = function(msg)
    local id = ExtractItemID(msg)
    if not id then
        DEFAULT_CHAT_FRAME:AddMessage("|cffffd100[OneBag]|r 材料：用法 /obitem <物品ID>（可拖入物品），例：/obitem 17020")
        return
    end
    local res = OneCore_AddCustomReagent(id)
    if res == nil then
        DEFAULT_CHAT_FRAME:AddMessage("|cffff5555[OneBag]|r 材料：物品 ID 无效")
    elseif res == false then
        DEFAULT_CHAT_FRAME:AddMessage(string.format("|cffffd100[OneBag]|r 材料：物品 ID %d 已在列表中", id))
    else
        DEFAULT_CHAT_FRAME:AddMessage(string.format("|cff7fff7f[OneBag]|r 材料：已添加 %s (%d)", OneCore_GetReagentName(id), id))
    end
end
SLASH_ONEBAGITEM1 = "/obitem"
SLASH_ONEBAGITEM2 = "/onebagitem"

SlashCmdList["ONEBAGITEMDEL"] = function(msg)
    local id = ExtractItemID(msg)
    if not id then
        DEFAULT_CHAT_FRAME:AddMessage("|cffffd100[OneBag]|r 材料：用法 /obitemdel <物品ID>")
        return
    end
    OneCore_RemoveCustomReagent(id)
    DEFAULT_CHAT_FRAME:AddMessage(string.format("|cff7fff7f[OneBag]|r 材料：已移除物品 ID %d", id))
end
SLASH_ONEBAGITEMDEL1 = "/obitemdel"
SLASH_ONEBAGITEMDEL2 = "/onebagitemdel"
