local _G, _M = getfenv(0), {}
setfenv(1, setmetatable(_M, {__index=_G}))

CreateFrame('GameTooltip', 'SortBagsTooltip', nil, 'GameTooltipTemplate')

local function IsPlayingOnTurtleWoW()
	return TargetHPText ~= nil and TargetHPPercText ~= nil
end

local function IsSuperWoWLoaded()
	return SetAutoloot ~= nil
end

local function GetContainerItemCount(container, position)
	local _, countOrCharges = GetContainerItemInfo(container, position)
	local count = countOrCharges
	if IsSuperWoWLoaded() and countOrCharges < 0 then
		count = 1
	end
	return count
end

-- 整理锁定（参考 Guda 的 slot-lock）：被 Alt+右键锁定的物品（按物品名称，与 ItemLock 一致）视为固定岛屿，
-- 整理时既不搬出、也不接受别的物品搬入。数据来自 OneBag 的 OneBag_IsSortLockedSlot。
local function IsSortLockedItem(container, position)
	if OneBag_IsSortLockedSlot then
		return OneBag_IsSortLockedSlot(container, position)
	end
	return false
end

-- GetItemInfo 结果缓存统一在 OneBag.lua 的 OneCore.itemInfoCache / OneCore.GetItemInfoCached 上，
-- 此处直接复用，避免两份缓存漂移与重复占内存（见 OneBag.lua）。

-- 整理状态/确认参数：必须在对话框定义之前声明，供 OnAccept 闭包正确捕获（否则 OnAccept 读到的是全局 nil）
local REVERSE
local SORT_TYPE
local confirmType, confirmReverse

-- 确认对话框（使用格式化字符串）
StaticPopupDialogs["SORT_BAGS_CONFIRM"] = {
	text = "确认整理%s？",
	button1 = "确认",
	button2 = "取消",
	OnAccept = function()
		Start(confirmType, confirmReverse)
	end,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
	preferredIndex = 3,
}

function _G.Clean_Up(containers, reverse)
	if containers ~= 'bags' and containers ~= 'bank' then
		error()
	end
	-- 注意：这里【绝不】设置 SORT_TYPE / REVERSE / CONTAINERS 全局，避免改写正在进行的整理上下文。
	-- 这些状态只在 Start() 真正开始某次整理时，按本次请求设置（见下方 Start）。
	if OneBag and OneBag.db and OneBag.db.profile and OneBag.db.profile.confirmCleanup then
		confirmType, confirmReverse = containers, reverse
		local typeText = (containers == "bags") and "背包" or "银行"
		StaticPopup_Show("SORT_BAGS_CONFIRM", typeText)
	else
		Start(containers, reverse)
	end
end

function _G.SortBags()
	Clean_Up("bags", _G.SortBagsRightToLeft)
end

function _G.SortBankBags()
	Clean_Up("bank", _G.SortBagsRightToLeft)
end

function _G.GetSortBagsRightToLeft(enabled)
	return SortBagsRightToLeft
end

function _G.SetSortBagsRightToLeft(enabled)
	_G.SortBagsRightToLeft = enabled and 1 or nil
end

local function set(...)
	local t = {}
	for i = 1, arg.n do
		t[arg[i]] = true
	end
	return t
end

local function union(...)
	local t = {}
	for i = 1, arg.n do
		for k in arg[i] do
			t[k] = true
		end
	end
	return t
end

local ITEM_TYPES = {GetAuctionItemClasses()}

local MOUNT = set(
	5864, 5872, 5873, 18785, 18786, 18787, 18244, 19030, 13328, 13329,
	2411, 2414, 5655, 5656, 18778, 18776, 18777, 18241, 12353, 12354,
	8629, 8631, 8632, 18766, 18767, 18902, 18242, 13086, 19902, 12302, 12303, 8628, 12326,
	8563, 8595, 13321, 13322, 18772, 18773, 18774, 18243, 13326, 13327,
	15277, 15290, 18793, 18794, 18795, 18247, 15292, 15293,
	1132, 5665, 5668, 18796, 18797, 18798, 18245, 12330, 12351,
	8588, 8591, 8592, 18788, 18789, 18790, 18246, 19872, 8586, 13317,
	13331, 13332, 13333, 13334, 18791, 18248, 13335,
	21218, 21321, 21323, 21324, 21176
)

local SPECIAL = set(5462, 9173, 17056, 17696, 17117, 13347, 13289, 11511, 41915, 61000)

local KEY = set(9240, 17191, 13544, 12324, 16309, 12384, 20402)

local TOOL = set(6218, 6339, 11130, 11145, 16207, 5060, 7005, 12709, 19727, 5956, 2901, 6219, 10498, 9149, 15846, 6256, 6365, 6366, 6367, 55155, 41326, 41327, 41328, 12225, 19022, 19970)

local ENCHANTING_REAGENT = set(
	10940, 11083, 11137, 11176, 16204,
	10938, 10939, 10998, 11082, 11134, 11135, 11174, 11175, 16202, 16203,
	10978, 11084, 11138, 11139, 11177, 11178, 14343, 14344,
	20725
)

local HERBS = set(765, 785, 2447, 2449, 2450, 2452, 2453, 3355, 3356, 3357, 3358, 3369, 3818, 3819, 3820, 3821, 4625, 8153, 8831, 8836, 8838, 8839, 8845, 8846, 13463, 13464, 13465, 13466, 13467, 13468)

local SEEDS = set(17034, 17035, 17036, 17037, 17038)

local CLASSES = {
	{
		containers = {2101, 5439, 7278, 11362, 3573, 3605, 7371, 8217, 2662, 19319, 18714, 61549},
		items = set(2512, 2515, 3030, 3464, 9399, 11285, 12654, 18042, 19316, 42198, 42199,42200,42201),
	},
	{
		containers = {2102, 5441, 7279, 11363, 3574, 3604, 7372, 8218, 2663, 19320},
		items = set(2516, 2519, 3033, 3465, 4960, 5568, 8067, 8068, 8069, 10512, 10513, 11284, 11630, 13377, 15997, 19317),
	},
	{
		containers = {22243, 22244, 21340, 21341, 21342},
		items = set(6265, 6990, 16583, 5565),
	},
	{
		containers = {22246, 22248, 22249},
		items = union(ENCHANTING_REAGENT, set(6218, 6339, 11130, 11145, 16207)),
	},
	{
		containers = {22250, 22251, 22252},
		items = union(HERBS, SEEDS),
	},
}

-- 整理节奏优化（参考 SUCC-bag 的 movedSlots 锁定等待 + Guda 的乌龟服节奏）：
-- 每轮开跑前等上一轮搬动的槽位真正解锁（最多 lockWait 秒防死等）。
-- 旧版用固定 moveCooldown 时间等待，慢服（乌龟）锁定可持续 2-3 秒，固定间隔等不够，
-- 收尾重绘会赶上锁定窗口 → 锁定槽贴图为空 → 图标定格消失。
local MOVE_BUDGET = 3            -- 常规节奏：每轮搬移件数
local MOVE_BUDGET_TURTLE = 8     -- 乌龟服：轮间隔放慢后提高每轮预算保持吞吐（对齐 Guda 一轮全搬）
local SORT_INTERVAL = 0.05       -- 常规默认轮间隔（秒）
local TURTLE_SORT_INTERVAL = 1.2 -- 乌龟服默认轮间隔：对齐 Guda 的 SE_DEFAULT_DELAY，也是本插件
                                 -- 早期 defaultDelay 的乌龟保护值（后被 sortInterval 特性覆盖成死代码，
                                 -- 0.05s 的激进节奏正是"收尾撞锁定窗口 → 卡灰"的根因）
local TURTLE_MIN_INTERVAL = 0.5  -- 乌龟服下限：再快就会反复撞 2-3s 的服务器锁定窗口
local _moveBudget = 0
local lastMoveTime = 0 -- 最近一次成功搬移的时间（无进展看门狗用）
local movedSlots = {} -- 本轮成功搬动的槽位 {bag=,slot=}，供锁定等待判定
local lockWaitDeadline = 0 -- 锁定等待的安全超时（防死等）

-- 整理速度设置（参考 SUCC-bag 的 resetime 滑条 + Guda 的乌龟服节奏）：
-- 每轮搬移的间隔秒数，存 OneBag.db.profile.sortInterval（跟随存档持久化）。
-- 常规默认 0.05（最快）；乌龟服默认 1.2、下限 0.5（锁定可达 2-3 秒，节奏太快必然撞锁）。
-- 每轮实时读取，滑条调整立即生效。
local function GetSortInterval()
	local turtle = IsPlayingOnTurtleWoW()
	local v = OneBag and OneBag.db and OneBag.db.profile and OneBag.db.profile.sortInterval
	if type(v) ~= 'number' or v ~= v then
		v = turtle and TURTLE_SORT_INTERVAL or SORT_INTERVAL
	end
	if turtle and v < TURTLE_MIN_INTERVAL then v = TURTLE_MIN_INTERVAL end
	if v < 0.05 then v = 0.05 end
	if v > 1.5 then v = 1.5 end
	return v
end
_G.OneBag_SortInProgress = false

local model, itemStacks, itemClasses, itemSortKeys, sourcesByItem

-- 按物品聚合的"可作为搬运源"槽位桶：sourcesByItem[itemKey] = { [slot] = true, ... }。
-- 整理过程中由 Move() 实时维护，使 Sort/Stack 无需 O(n) 全量扫描即可取源，整体从 O(n^2) 降到接近 O(n)。
local function BucketAdd(item, slot)
	if item and slot then
		local t = sourcesByItem[item]
		if not t then t = {}; sourcesByItem[item] = t end
		t[slot] = true
	end
end
local function BucketRemove(item, slot)
	if item and slot and sourcesByItem[item] then
		sourcesByItem[item][slot] = nil
	end
end

do
    local f = CreateFrame("Frame", "Clean_UpFrame", UIParent)
    f:Hide()

    local timeout
    local sortFrame = nil
    local sortQueue = {}  -- FIFO 队列：整理进行中再点另一个框排队，依次执行，两个框都不丢整理

    local function GetSortFrame(type)
        if type == 'bank' and _G.OneBank and _G.OneBank.frame then
            return _G.OneBank.frame
        elseif _G.OneBag and _G.OneBag.frame then
            return _G.OneBag.frame
        end
        return nil
    end

    -- 延迟补刷帧：整理结束后的"立即刷新"可能赶上最后一次搬移的服务器锁定窗口
    -- （槽位 locked 尚未清除，本客户端锁定槽可能连贴图都报告为空），
    -- 此时重绘会把按钮定格成灰色/无图标；之后内容不再变化、没有新的 BAG_UPDATE 来纠正。
    -- 策略：宽限期（6s）内等解锁不重绘；超过宽限期仍锁定则降为 0.5s 一次的强制重绘
    -- （锁定一个恢复一个），直到全部解锁后做最后一次去灰+重绘再收工（Hide，不空转）。
    -- 这样无论服务器何时解锁，图标都会被恢复，不存在"定格后永远丢图标"。
    local repaintFrame = CreateFrame("Frame", "OneBagSortRepaintFrame", UIParent)
    repaintFrame:Hide()
    repaintFrame:SetScript('OnUpdate', function()
        if GetTime() < this.nextCheck then return end
        this.nextCheck = GetTime() + 0.1
        -- 已有新的整理在跑/在队列中：它收尾时会重新安排补刷，这里只等待
        if _G.OneBag_SortInProgress then return end
        -- 扫描本次整理容器：是否仍有服务器锁定的槽位
        local anyLocked = false
        for _, c in ipairs(this.containers) do
            for s = 1, GetContainerNumSlots(c) do
                local _, _, locked = GetContainerItemInfo(c, s)
                if locked then anyLocked = true break end
            end
            if anyLocked then break end
        end
        if anyLocked and GetTime() < this.deadline then
            return -- 宽限期内等服务器解锁，不重绘
        end
        -- 全部解锁：去灰 + 完整重绘一次即收工。旧版缺这条 Hide，补刷帧会永久以 10Hz
        -- 全量扫描+重绘（白耗性能，还会持续打断其它刷新逻辑）。
        if not anyLocked then this:Hide() end
        for _, mod in ipairs({_G.OneBag, _G.OneBank}) do
            if mod and mod.frame and mod.fBags then
                -- 无论是否仍锁定，逐包：先去灰，再用轻量刷新（UpdateBagSlots）同步图标。
                -- UpdateBagSlots 现已对"锁定+空纹理"保留上一帧图标（不刷空），所以即使仍
                -- 有锁定也不会把按钮定格成空白；已解锁的槽位则立即恢复，锁定槽随解锁逐步恢复。
                for _, b in ipairs(mod.fBags) do
                    pcall(OneBag_SortResyncLockVisuals, mod.frame, b)
                    pcall(mod.UpdateBagSlots, mod, b)
                end
                if not anyLocked then
                    -- 全部解锁：完整重绘一次（染色/边框）+ 计数收尾
                    for _, b in ipairs(mod.fBags) do
                        pcall(mod.UpdateBag, mod, b, true)
                    end
                    pcall(mod.DoSlotCounts, mod)
                end
            end
        end
        if anyLocked then
            -- 仍有锁定：不要把空贴图定格到按钮上，只去灰后继续等解锁。
            -- 扫描间隔保持 0.1s，但只在 deadline 过期后进入此分支；每 0.5s 提示一次。
            -- 陈旧锁兜底：卖店等操作可能留下永不清除的锁标志（真实锁最多 2-3 秒），
            -- 若锁定持续超过宽限期，强制重绘几轮后收工，不让本帧永久空转。
            -- （着色侧 OneBag_SetSlotShade 对连续 5 秒以上的锁按陈旧锁处理，强制重绘
            --   阶段读到的"锁定"已按解锁视觉涂色，收工不会留下灰格。）
            this.forceCount = (this.forceCount or 0) + 1
            if this.forceCount >= 5 then
                this:Hide()
                return
            end
            if GetTime() > (this.forceNext or 0) then
                this.forceNext = GetTime() + 0.5
                if not this.warned then
                    this.warned = true
                    DEFAULT_CHAT_FRAME:AddMessage("|cFFFFCC00[OneBag] 部分槽位仍在服务器锁定中，图标将在解锁后自动恢复；若长时间不恢复请尝试重新登录|r")
                end
            end
            this:Show()
        end
    end)

    -- 整理安全收尾：恢复按钮交互（isSorting 解除 + 鼠标可用）、清掉卡在光标的物品、
    -- 关闭整理循环、立即完整重绘一次；若背包/银行先后点击产生排队请求，则立即接着跑。
    local function FinishSort()
        _G.OneBag_SortInProgress = false
        if CursorHasItem() then ClearCursor() end
        OneBag_SortShowButtons(sortFrame)
        f:Hide()
        -- 安排延迟补刷：等服务器锁定清除后再完整重绘一次
        repaintFrame.containers = (SORT_TYPE == 'bank') and {-1, 5, 6, 7, 8, 9, 10} or {0, 1, 2, 3, 4}
        -- 宽限 6 秒（对齐 SUCC-bag）：乌龟服锁定可持续两三秒，原来 2 秒的窗口
        -- 会在仍锁定状态下重绘，锁定槽贴图为空 → 图标定格消失（"卡住的物品没图标"）。
        repaintFrame.deadline = GetTime() + 6
        repaintFrame.nextCheck = GetTime() + 0.2 -- 先给服务器 0.2s 解锁时间
        repaintFrame.warned = nil   -- 锁定提示每次整理只提示一次
        repaintFrame.forceNext = nil
        repaintFrame.forceCount = nil -- 陈旧锁强制重绘轮数计数每次整理重置
        repaintFrame:Show()
        if table.getn(sortQueue) > 0 then
            local p = table.remove(sortQueue, 1)
            Start(p.type, p.reverse)
        end
    end

    function Start(type, reverse)
        -- 关键修复：不再用 `type or SORT_TYPE` / `reverse or REVERSE` 回退。
        -- 所有调用方（Clean_Up / 确认框 OnAccept / 队列）都会显式传参；
        -- 旧写法会让上一次整理的 REVERSE 残留，导致右击(reverse=1)之后左击(reverse=nil)
        -- 被污染成 reverse=1，表现为“左右键整理结果一样 / 整理像没反应”。
        SORT_TYPE = type
        REVERSE = reverse
        if f:IsShown() then
            -- 已在整理中：排队，绝不覆盖已有请求（避免先点的框被后点的覆盖而“丢失”整理，
            -- 这正是“背包/银行同时整理只整理了一个”的根因）。队列按点击顺序依次执行。
            table.insert(sortQueue, {type = type, reverse = reverse})
            return
        end
        local containers = (type == 'bank') and {-1, 5, 6, 7, 8, 9, 10} or {0, 1, 2, 3, 4}
        lastMoveTime = GetTime() -- 看门狗起点
        movedSlots = {} -- 重置锁定等待列表，避免上一次整理残留拖延本轮首搬
        lockWaitDeadline = 0
        -- pcall 保护：Initialize 内报错（如物品信息未就绪）不能让整理半路挂掉
        local okInit, errInit = pcall(Initialize, containers)
        if not okInit then
            DEFAULT_CHAT_FRAME:AddMessage("|cFFFF0000[OneBag] 整理初始化失败，已取消: " .. tostring(errInit) .. "|r")
            return
        end
        local totalSlots = 0
        for _, c in ipairs(containers) do totalSlots = totalSlots + GetContainerNumSlots(c) end
        -- 超时随整理速度自适应：慢速档（大间隔）下整理本来就更久，不能沿用快速档的 30 秒下限
        local interval = GetSortInterval()
        timeout = GetTime() + max(30, totalSlots / MOVE_BUDGET * (interval + 0.15) * 2 + 10)
        sortFrame = GetSortFrame(type)
        _G.OneBag_SortInProgress = true
        OneBag_SortHideButtons(sortFrame)
        f:Show()
    end

    local delay = 0
    f:SetScript('OnUpdate', function()
        -- pcall 保护：整理循环内任何报错（如物品信息未缓存导致 nil 比较）都必须安全收尾，
        -- 否则按钮停留在"鼠标禁用"状态、isSorting 卡住，表现为整包不能点击、内容不再刷新。
        local ok, err = pcall(function()
            delay = delay - arg1
            if delay <= 0 then
                local interval = GetSortInterval() -- 整理速度设置（每轮间隔，实时读取）
                delay = interval
                -- 光标持物/上轮槽位仍锁定：跳过本轮（下方锁定等待），避免重复搬移 / 物品被吞
                if GetTime() > timeout then
                    FinishSort()
                    return
                end
                -- 无进展看门狗：连续一段时间没有任何成功搬移（存在锁死槽位/光标卡物品等），
                -- 提前收尾，避免整理空转到超时（期间按钮一直禁用、内容停更）。
                -- 阈值随整理速度放大（对齐 SUCC-bag）：慢速档下两轮间隔本来就大，3 秒固定值会误杀
                if GetTime() - lastMoveTime > max(3, interval * 4) then
                    FinishSort()
                    return
                end
                -- 光标仍持物：跳过本轮，等服务器锁定清除，避免重复搬移 / 物品被吞
                if CursorHasItem() then return end
                -- 锁定等待（对齐 SUCC-bag）：上一轮搬动的槽位未全部解锁前不发起新一轮，
                -- 最多等 1.2 秒兜底防死等；快服几乎零空等，慢服按需等。
                -- 旧版用固定 moveCooldown=interval*3，慢服锁定 2-3 秒时远等不够，
                -- 后续搬移与收尾重绘都会赶上锁定窗口 → 锁定槽贴图为空 → 图标定格消失。
                if table.getn(movedSlots) > 0 then
                    if GetTime() < lockWaitDeadline then
                        for _, s in pairs(movedSlots) do
                            local _, _, locked = GetContainerItemInfo(s.bag, s.slot)
                            if locked then return end
                        end
                    end
                    movedSlots = {}
                end
                -- 乌龟服节奏放慢后按 Guda 的"一轮全搬"提高预算，保持整体吞吐
                _moveBudget = IsPlayingOnTurtleWoW() and MOVE_BUDGET_TURTLE or MOVE_BUDGET
                local complete = Sort()
                if complete then
                    FinishSort()
                    return
                end
                Stack()
            end
        end)
        if not ok then
            DEFAULT_CHAT_FRAME:AddMessage("|cFFFF0000[OneBag] 整理循环出错，已安全终止: " .. tostring(err) .. "|r")
            FinishSort()
        end
    end)
end

do
	local function key(table, value)
		for k, v in pairs(table) do
			if v == value then
				return k
			end
		end
	end

	-- 排序键索引缓存（整理初始化要为成百上千个物品算键，不能每个物品都重建一次
	-- 子类表再做线性查找）：同类物品共享同一份索引表，整个会话只算一次。
	local typeKeyCache = {}
	local subTypeKeyCache = {}
	local invTypeKeyCache = {}

	function ItemTypeKey(itemClass)
		local v = typeKeyCache[itemClass]
		if v == nil then
			v = key(ITEM_TYPES, itemClass) or 0
			typeKeyCache[itemClass] = v
		end
		return v
	end

	function ItemSubTypeKey(itemClass, itemSubClass)
		local byType = subTypeKeyCache[itemClass]
		if not byType then
			byType = {}
			local list = {GetAuctionItemSubClasses(ItemTypeKey(itemClass))}
			for k, v in pairs(list) do
				if not byType[v] then byType[v] = k end
			end
			subTypeKeyCache[itemClass] = byType
		end
		return byType[itemSubClass] or 0
	end

	function ItemInvTypeKey(itemClass, itemSubClass, itemSlot)
		local subKey = ItemSubTypeKey(itemClass, itemSubClass)
		local cacheKey = (itemClass or '') .. '#' .. subKey
		local byType = invTypeKeyCache[cacheKey]
		if not byType then
			byType = {}
			local list = {GetAuctionInvTypes(ItemTypeKey(itemClass), subKey)}
			for k, v in pairs(list) do
				if not byType[v] then byType[v] = k end
			end
			invTypeKeyCache[cacheKey] = byType
		end
		return byType[itemSlot] or 0
	end
end

function LT(a, b)
	local i = 1
	while true do
		if a[i] and b[i] and a[i] ~= b[i] then
			return a[i] < b[i]
		elseif not a[i] and b[i] then
			return true
		elseif not b[i] then
			return false
		end
		i = i + 1
	end
end

function Move(src, dst)
    if _moveBudget <= 0 then return false end
    -- 整理锁定：锁定的源/目标格一律不搬动（参考 Guda 的 slot-lock）
    if src.locked or dst.locked then return false end
    local texture, _, srcLocked = GetContainerItemInfo(src.container, src.position)
    local _, _, dstLocked = GetContainerItemInfo(dst.container, dst.position)
    
	if texture and not srcLocked and not dstLocked then
		ClearCursor()
       	PickupContainerItem(src.container, src.position)
       	PickupContainerItem(dst.container, dst.position)
		-- 不采用 SUCC-bag 的"第二次 Pickup 后 CursorHasItem 即失败"判断：
		-- 在 Turtle/SuperWoW 客户端，交换两个不同物品后光标通常仍持物（目标格物品），
		-- 该检查会把正常交换误判为失败，然后把目标格物品塞回源格，造成模型/实际失步，
		-- 反而显著增加卡灰与图标丢失。恢复老版本 OneBag 的直接搬移语义，靠锁定等待
		-- + 延迟补刷来兜底慢服锁定。
		-- 登记本轮搬动槽位（供下一轮锁定等待判定）并刷新预算/看门狗。
		-- 等待上限 3.0s：乌龟服锁定实测可持续 2-3 秒，旧值 2.0s 会在锁定未清除时
		-- 提前放行下一轮，反复撞锁定窗口（收尾重绘撞上即卡灰）。
		_moveBudget = _moveBudget - 1
		lastMoveTime = GetTime()
		lockWaitDeadline = GetTime() + 3.0
		tinsert(movedSlots, {bag = src.container, slot = src.position})
		tinsert(movedSlots, {bag = dst.container, slot = dst.position})

		local oldSrcItem = src.item
		local oldDstItem = dst.item
		if oldSrcItem == oldDstItem then
			local count = min(src.count, itemStacks[dst.item] - dst.count)
			src.count = src.count - count
			dst.count = dst.count + count
			if src.count == 0 then
				src.item = nil
			end
		else
			src.item, dst.item = oldDstItem, oldSrcItem
			src.count, dst.count = dst.count, src.count
		end

		-- 维护按物品聚合的源桶：源/目标物品变化后，从旧桶移除、加入新桶，
		-- 保证下一轮 Sort/Stack 取源时桶与实际槽位内容一致（无脏数据）。
		if oldSrcItem ~= src.item then
			BucketRemove(oldSrcItem, src)
			if src.item then BucketAdd(src.item, src) end
		end
		if oldDstItem ~= dst.item then
			BucketRemove(oldDstItem, dst)
			if dst.item then BucketAdd(dst.item, dst) end
		end

		return true
    end
end

local tooltipInfoCache = {}
function TooltipInfo(itemID, container, position)
	if itemID and tooltipInfoCache[itemID] then
		local cached = tooltipInfoCache[itemID]
		return cached[1], cached[2], cached[3], cached[4], cached[5]
	end

	local chargesPattern = '^' .. gsub(gsub(ITEM_SPELL_CHARGES_P1, '%%d', '(%%d+)'), '%%%d+%$d', '(%%d+)') .. '$'

	SortBagsTooltip:SetOwner(UIParent, 'ANCHOR_NONE')
	SortBagsTooltip:ClearLines()

	if container == BANK_CONTAINER then
		SortBagsTooltip:SetInventoryItem('player', BankButtonIDToInvSlotID(position))
	else
		SortBagsTooltip:SetBagItem(container, position)
	end

	local charges, usable, soulbound, quest, conjured
	for i = 1, SortBagsTooltip:NumLines() do
		local text = getglobal('SortBagsTooltipTextLeft' .. i):GetText()

		local _, _, chargeString = strfind(text, chargesPattern)
		if chargeString then
			charges = tonumber(chargeString)
		elseif strfind(text, '^' .. ITEM_SPELL_TRIGGER_ONUSE) then
			usable = true
		elseif text == ITEM_SOULBOUND then
			soulbound = true
		elseif text == ITEM_BIND_QUEST then
			quest = true
		elseif text == ITEM_CONJURED then
			conjured = true
		end
	end

	local result = {charges or 1, usable, soulbound, quest, conjured}
	if itemID then
		tooltipInfoCache[itemID] = result
	end
	return result[1], result[2], result[3], result[4], result[5]
end

function Sort()
	local complete = true
	
	for _, dst in ipairs(model) do
		-- 本轮搬移预算用尽：立即收手，剩下的下一轮再排（否则会继续 O(n²) 空转，
		-- 每个 dst 都要扫一遍全 model 找源、再建表排序，纯浪费 → 整理时掉帧的主因之一）
		if _moveBudget <= 0 then return false end
		if dst.targetItem and (dst.item ~= dst.targetItem or dst.count < dst.targetCount) then
			complete = false

			local sources, rank = {}, {}

			-- 直接从"目标物品"的源桶取候选，避免 O(n) 全量扫描，整体降到接近 O(n)
			local bucket = sourcesByItem[dst.targetItem]
			if bucket then
				for src in pairs(bucket) do
					if src.item == dst.targetItem
						and src ~= dst
						and not src.locked
						and not (dst.item and src.class and src.class ~= itemClasses[dst.item])
						and not (src.targetItem and src.item == src.targetItem and src.count <= src.targetCount)
					then
						rank[src] = abs(src.count - dst.targetCount + (dst.item == dst.targetItem and dst.count or 0))
						tinsert(sources, src)
					end
				end
			end

			sort(sources, function(a, b) return rank[a] < rank[b] end)

			for _, src in ipairs(sources) do
				if Move(src, dst) then
					break
				end
			end
		end
	end
	
	return complete
end

function Stack()
	for _, src in ipairs(model) do
		-- 预算用尽立即停止：Stack 是 O(n²) 全量配对扫描，预算耗尽后继续跑
		-- 只是空转（Move 会立刻返回 false），白占每帧时间
		if _moveBudget <= 0 then return end
		if src.item and not src.locked and src.count < itemStacks[src.item] and src.item ~= src.targetItem then
			-- 只在本物品源桶里找可堆叠目标，避免 O(n) 全量扫描
			local bucket = sourcesByItem[src.item]
			if bucket then
				for dst in pairs(bucket) do
					if _moveBudget <= 0 then return end
					if dst ~= src and not dst.locked and dst.item and dst.item == src.item and dst.count < itemStacks[dst.item] and dst.item ~= dst.targetItem then
						Move(src, dst)
					end
				end
			end
		end
	end
end

do
	local counts

	local function insert(t, v)
		if REVERSE then
			tinsert(t, v)
		else
			tinsert(t, 1, v)
		end
	end

	local function assign(slot, item)
		if counts[item] > 0 then
			local count
			if REVERSE and mod(counts[item], itemStacks[item]) ~= 0 then
				count = mod(counts[item], itemStacks[item])
			else
				count = min(counts[item], itemStacks[item])
			end
			slot.targetItem = item
			slot.targetCount = count
			counts[item] = counts[item] - count
			return true
		end
	end

	function Initialize(containers)
		model, counts, itemStacks, itemClasses, itemSortKeys, sourcesByItem = {}, {}, {}, {}, {}, {}

		for _, container in ipairs(containers) do
			local class = ContainerClass(container)
			for position = 1, GetContainerNumSlots(container) do
				local slot = {container=container, position=position, class=class}
				local item = Item(container, position)
				local _, _, srvLocked = GetContainerItemInfo(container, position)
				-- 整理锁定 或 服务器锁定（含上一次整理残留/锁死的"灰格"）一律视为固定岛屿：
				-- 不搬出、不搬入、不参与目标分配。否则模型目标永远无法满足，
				-- Sort() 永远不返回 complete，按钮会保持隐藏直到超时（表现为全包无图标）。
				slot.locked = (item and IsSortLockedItem(container, position)) or srvLocked or nil
				if item then
					slot.item = item
					slot.count = GetContainerItemCount(container, position)
					-- 整理锁定：被锁定的物品不计入可移动库存，既不会被搬到别处，
					-- 其占用格也不会被当作可接收目标（参考 Guda 的 slot-lock）。
				if not slot.locked then
					counts[item] = (counts[item] or 0) + slot.count
					BucketAdd(item, slot)
				end
				end
				insert(model, slot)
			end
		end

		local free = {}
		for item, count in pairs(counts) do
			local stacks = ceil(count / itemStacks[item])
			free[item] = stacks
			if itemClasses[item] then
				free[itemClasses[item]] = (free[itemClasses[item]] or 0) + stacks
			end
		end
		for _, slot in ipairs(model) do
			-- 锁定的格子仍物理占一个位置，故其 class 容量需照常扣除，保证其它格子分配正确
			if slot.class and free[slot.class] then
				free[slot.class] = free[slot.class] - 1
			end
		end

		local items = {}
		for item in pairs(counts) do
			tinsert(items, item)
		end
		sort(items, function(a, b) return LT(itemSortKeys[a], itemSortKeys[b]) end)

		for _, slot in ipairs(model) do
			if slot.locked then
				-- 锁定格子不分配目标，保持原位
			elseif slot.class then
				for _, item in ipairs(items) do
					if itemClasses[item] == slot.class and assign(slot, item) then
						break
					end
				end
			else
				for _, item in ipairs(items) do
					if (not itemClasses[item] or free[itemClasses[item]] > 0) and assign(slot, item) then
						if itemClasses[item] then
							free[itemClasses[item]] = free[itemClasses[item]] - 1
						end
						break
					end
				end
			end
		end
	end
end

function ContainerClass(container)
	if container ~= 0 and container ~= BANK_CONTAINER then
		local name = GetBagName(container)
		if name then		
			for class, info in ipairs(CLASSES) do
				for _, itemID in info.containers do
					if name == OneCore.GetItemInfoCached(itemID) then
						return class
					end
				end	
			end
		end
	end
end

function Item(container, position)
	local link = GetContainerItemLink(container, position)
	if link then
		local _, _, itemID, enchantID, suffixID, uniqueID = strfind(link, 'item:(%d+):(%d*):(%d*):(%d*)')
		itemID = tonumber(itemID)
		local _, _, quality, _, type, subType, stack, invType = OneCore.GetItemInfoCached(itemID)
		-- 物品信息偶发未就绪（GetItemInfo 返回 nil）：给默认值兜底，
		-- 避免 quality/stack 为 nil 时比较或除法报错导致整理中断
		if not quality then quality = 0 end
		if not stack then stack = 20 end
		local charges, usable, soulbound, quest, conjured = TooltipInfo(itemID, container, position)
		
		local sortKey = {}
		
		if itemID == 6948 then
			tinsert(sortKey, 1)
		elseif MOUNT[itemID] then
			tinsert(sortKey, 2)
		elseif SPECIAL[itemID] then
			tinsert(sortKey, 3)
		elseif KEY[itemID] then
			tinsert(sortKey, 4)
		elseif TOOL[itemID] then
			tinsert(sortKey, 5)
		elseif itemID == 6265 then
			tinsert(sortKey, 14)
		elseif conjured then
			tinsert(sortKey, 15)
		elseif soulbound then
			tinsert(sortKey, 6)
		elseif ENCHANTING_REAGENT[itemID] then
			tinsert(sortKey, 7)
		elseif type == ITEM_TYPES[9] then
			tinsert(sortKey, 8)
		elseif quest then
			tinsert(sortKey, 10)
		elseif usable and type ~= ITEM_TYPES[1] and type ~= ITEM_TYPES[2] and type ~= ITEM_TYPES[8] or type == ITEM_TYPES[4] then
			tinsert(sortKey, 9)
		elseif quality > 1 then
			tinsert(sortKey, 11)
		elseif quality == 1 then
			tinsert(sortKey, 12)
		elseif quality == 0 then
			tinsert(sortKey, 13)
		end
		
		tinsert(sortKey, ItemTypeKey(type))
		tinsert(sortKey, ItemInvTypeKey(type, subType, invType))
		tinsert(sortKey, ItemSubTypeKey(type, subType))
		tinsert(sortKey, -quality)
		tinsert(sortKey, itemID)
		tinsert(sortKey, (REVERSE and 1 or -1) * charges)
		tinsert(sortKey, suffixID)
		tinsert(sortKey, enchantID)
		tinsert(sortKey, uniqueID)

		local key = format('%s:%s:%s:%s:%s:%s', itemID, enchantID, suffixID, uniqueID, charges, (soulbound and 1 or 0))

		itemStacks[key] = stack
		itemSortKeys[key] = sortKey

		for class, info in ipairs(CLASSES) do
			if info.items[itemID] then
				itemClasses[key] = class
				break
			end
		end

		return key
	end
end