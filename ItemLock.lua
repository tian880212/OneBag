ItemLock = AceLibrary("AceAddon-2.0"):new("AceEvent-2.0", "AceHook-2.1", "AceConsole-2.0")

ItemLock.ProtectedItems = {}
ItemLock.lastUpdateCount = 0
ItemLock.isDisenchanting = false
ItemLock.disenchantItemID = nil
ItemLock.justUnlockedAll = false

ItemLock.Config = {
    enableSellProtection = true,
    enableDeleteProtection = true,
    enableDisenchantProtection = true,
    showWarningMessages = true,
    playWarningSound = true
}

function ItemLock:OnInitialize()
    self:InitializeDB()
    self:RegisterSlashCommands()
    DEFAULT_CHAT_FRAME:AddMessage("|cFF00FF00ItemLock 2.0 已加载!|r 输入 /itemlock 查看命令")
    self:RegisterEvent("ADDON_LOADED")
    self:RegisterEvent("PLAYER_LOGIN")
    self:RegisterEvent("UI_ERROR_MESSAGE")
end

function ItemLock:OnEnable()
    self.cursorItemID = nil
    self.cursorItemLink = nil
    self:HookFunctions()
end

function ItemLock:PLAYER_LOGIN()
    self:InitializeDB()
    self:UpdateProtectedItems()
    self:HookFunctions()
    -- 兜底：若 Outfitter 比 ItemLock 更早加载且之后无其它 ADDON_LOADED 事件，
    -- ADDON_LOADED 分支可能没机会执行，登录时再补挂一次（内部有防重复护栏）
    self:HookOutfitter()
end

function ItemLock:HookFunctions()
    if not self.hooks.UseContainerItem then
        self:Hook("UseContainerItem", true)
    end
    
    if not self.hooks.PickupContainerItem then
        self:Hook("PickupContainerItem", true)
    end
    
    if not self.hooks.PickupInventoryItem then
        self:Hook("PickupInventoryItem", true)
    end
    
    if not self.hooks.DeleteCursorItem then
        self:Hook("DeleteCursorItem", true)
    end
    
    if not self.hooks.CastSpell then
        self:Hook("CastSpell", true)
    end
    
    if not self.hooks.UseAction then
        self:Hook("UseAction", true)
    end
    
    if not self.hooks.CastSpellByName then
        self:Hook("CastSpellByName", true)
    end
    
    if not Original_MerchantItemButton_OnClick then
        Original_MerchantItemButton_OnClick = MerchantItemButton_OnClick
        MerchantItemButton_OnClick = function(button, ignoreShift)
            ItemLock:MerchantItemButton_OnClick(button, ignoreShift)
        end
    end
    
    if not Original_ContainerFrameItemButton_OnClick then
        Original_ContainerFrameItemButton_OnClick = ContainerFrameItemButton_OnClick
        ContainerFrameItemButton_OnClick = function(button, ignoreShift)
            ItemLock:ContainerFrameItemButton_OnClick(button, ignoreShift)
        end
    end
    
    if not Original_CastingBarFrame_OnEvent then
        Original_CastingBarFrame_OnEvent = CastingBarFrame_OnEvent
        CastingBarFrame_OnEvent = function(event)
            ItemLock:CastingBarFrame_OnEvent(event)
        end
    end
end

function ItemLock:UI_ERROR_MESSAGE()
    local errorMessage = arg1
    if errorMessage == ERR_NO_ITEMS_WHILE_CASTING then
        if self.isDisenchanting and self.disenchantItemID then
            if self.ProtectedItems[self.disenchantItemID] then
                self:ShowWarning("无法分解受保护的物品!")
                self:CancelDisenchant()
            end
        end
    end
end

function ItemLock:CancelDisenchant()
    SpellStopCasting()
    self.isDisenchanting = false
    self.disenchantItemID = nil
end

function ItemLock:IsDisenchantSpell(spellID, spellName)
    if spellName then
        if string.find(string.lower(spellName), "分解") then
            return true
        end
        if string.find(string.lower(spellName), "disenchant") then
            return true
        end
    end
    
    if spellID and (spellID == 13262 or spellID == 13261 or spellID == 13260 or spellID == 13259) then
        return true
    end
    
    return false
end

function ItemLock:CastSpell(...)
    -- 用变参透传：SuperWoW 给 CastSpell 扩展的目标参数（如分解到指定单位）若只写死两个参数会被吞掉，
    -- 导致“分解到目标”等带额外参数的施法静默失败。全部参数原样转发给原函数。
    local spellID, spellbookTabNum = unpack(arg)
    local spellName = GetSpellName(spellID, spellbookTabNum)
    if self:IsDisenchantSpell(spellID, spellName) then
        self.isDisenchanting = true
        self.disenchantItemID = nil
    end
    self.hooks.CastSpell(unpack(arg))
end

function ItemLock:CastSpellByName(spellName, onSelf)
    if self:IsDisenchantSpell(nil, spellName) then
        self.isDisenchanting = true
        self.disenchantItemID = nil
    end
    self.hooks.CastSpellByName(spellName, onSelf)
end

function ItemLock:UseAction(slot, checkCursor, onSelf)
    self.hooks.UseAction(slot, checkCursor, onSelf)
end

function ItemLock:CastingBarFrame_OnEvent(event)
    if event == "SPELLCAST_START" then
        local spellName = arg1
        if self:IsDisenchantSpell(nil, spellName) then
            self.isDisenchanting = true
        end
    elseif event == "SPELLCAST_STOP" then
        self.isDisenchanting = false
        self.disenchantItemID = nil
    elseif event == "SPELLCAST_INTERRUPTED" or event == "SPELLCAST_FAILED" then
        self.isDisenchanting = false
        self.disenchantItemID = nil
    end
    
    if Original_CastingBarFrame_OnEvent then
        Original_CastingBarFrame_OnEvent(event)
    end
end

function ItemLock:ADDON_LOADED(addonName)
    if addonName == "ItemLock" then
        self:InitializeDB()
    elseif IsAddOnLoaded("ItemRack") or IsAddOnLoaded("Outfitter") then
        self:UpdateProtectedItems()
        
        if ItemRack and ItemRack.SaveSet then
            self:Hook(ItemRack, "SaveSet", "UpdateProtectedItems", true)
        end
        if ItemRack and ItemRack.DeleteSet then
            self:Hook(ItemRack, "DeleteSet", "UpdateProtectedItems", true)
        end
        
        if IsAddOnLoaded("Outfitter") then
            self:HookOutfitter()
            self:RegisterEvent("PLAYER_REGEN_ENABLED")
            self:RegisterEvent("ZONE_CHANGED_NEW_AREA")
        end
    end
end

-- Outfitter 套装变更后立即刷新保护列表（编辑套装不用等脱战/切区）
-- 覆盖四类变更：
--   新增套装(AddOutfit)、删除套装(DeleteOutfit)、
--   编辑后分类移动(UpdateOutfitCategory，Outfitter 用它在 Complete/Partial 间搬套装)、
--   "更新套装"(UpdateOutfit，右键菜单→从当前穿着覆盖 Items，不走上面任何函数，单独补挂)
function ItemLock:HookOutfitter()
    if self.outfitterHooked or not IsAddOnLoaded("Outfitter") then return end

    local hookedCount = 0
    local function wrapAndWatch(funcName)
        if type(getglobal(funcName)) ~= "function" then return end
        local orig = getglobal(funcName)
        setglobal(funcName, function(...)
            orig(unpack(arg))
            ItemLock:UpdateProtectedItems()
        end)
        hookedCount = hookedCount + 1
    end

    wrapAndWatch("Outfitter_UpdateOutfitCategory")
    wrapAndWatch("Outfitter_AddOutfit")
    wrapAndWatch("Outfitter_DeleteOutfit")
    wrapAndWatch("Outfitter_UpdateOutfit")

    if hookedCount > 0 then
        self.outfitterHooked = true
        DEFAULT_CHAT_FRAME:AddMessage("|cFF00FF00ItemLock: 已挂钩 Outfitter 套装变更（" .. hookedCount .. " 个函数），编辑套装后保护立即生效|r")
    end
end

function ItemLock:PLAYER_REGEN_ENABLED()
    self:UpdateProtectedItems()
end

function ItemLock:ZONE_CHANGED_NEW_AREA()
    self:UpdateProtectedItems()
end

function ItemLock:InitializeDB()
    local playerKey = self:GetPlayerKey()
    
    if not ItemLockDB then ItemLockDB = {} end
    if not ItemLockConfig then ItemLockConfig = {} end
    
    if not ItemLockDB[playerKey] then
        ItemLockDB[playerKey] = { lockedItems = {} }
    end
    
    if not ItemLockConfig[playerKey] then
        ItemLockConfig[playerKey] = {
            enableSellProtection = true,
            enableDeleteProtection = true,
            enableDisenchantProtection = true,
            showWarningMessages = true,
            playWarningSound = true
        }
    end
    
    for k, v in pairs(ItemLockConfig[playerKey]) do
        self.Config[k] = v
    end
end

function ItemLock:GetPlayerKey()
    return UnitName("player") .. "-" .. GetRealmName()
end

function ItemLock:GetPlayerDB()
    return ItemLockDB[self:GetPlayerKey()]
end

function ItemLock:GetPlayerConfig()
    return ItemLockConfig[self:GetPlayerKey()]
end

function ItemLock:SaveConfig()
    local config = self:GetPlayerConfig()
    if config then
        for k, v in pairs(self.Config) do
            config[k] = v
        end
    end
end

function ItemLock:ExtractItemName(itemLink)
    return itemLink and string.match(itemLink, "%[(.-)%]")
end

function ItemLock:ShowWarning(message)
    if self.Config.showWarningMessages then
        UIErrorsFrame:AddMessage(message, 1.0, 0.1, 0.1, 1.0, 5)
        DEFAULT_CHAT_FRAME:AddMessage("|cFFFF0000ItemLock:|r " .. message)
    end
    if self.Config.playWarningSound then
        PlaySound("RaidWarning")
    end
end

function ItemLock:UpdateProtectedItems(forceUpdate)
    -- 如果forceUpdate为false，并且我们刚刚执行了一键解锁，可以跳过重新计算
    if not forceUpdate and self.justUnlockedAll then
        self.justUnlockedAll = false
        DEFAULT_CHAT_FRAME:AddMessage("|cFF00FF00ItemLock: 已跳过重新计算自动保护物品|r")
        return
    end
    
    local success, errorMsg = pcall(function()
        local oldCount = 0
        for _ in pairs(self.ProtectedItems) do
            oldCount = oldCount + 1
        end
        
        self.ProtectedItems = {}
        
        local count = 0
        local setCount = 0
        -- 记录每个受保护物品的来源（套装名等），拦截提示与 /itemlock list 会显示
        local sources = {}
        local function addSource(itemID, srcName)
            if not sources[itemID] then sources[itemID] = {} end
            sources[itemID][srcName] = true
        end
        
        if IsAddOnLoaded("ItemRack") then
            local userData = Rack_User or ItemRack_Users
            
            if userData then
                local user = UnitName("player") .. " of " .. GetCVar("realmName")
                
                if userData[user] and userData[user].Sets then
                    for setName, setData in pairs(userData[user].Sets) do
                        if not string.find(setName, "^ItemRack%-") and not string.find(setName, "^Rack%-") then
                            setCount = setCount + 1
                            
                            for slot = 0, 19 do
                                local itemData = setData[slot]
                                if itemData and type(itemData) == "table" then
                                    local itemID = itemData.id
                                    
                                    if itemID and itemID ~= 0 then
                                        if type(itemID) == "string" then
                                            local _, _, extractedID = string.find(itemID, "^(%d+)")
                                            itemID = tonumber(extractedID)
                                        end
                                        
                                        if itemID and itemID > 0 then
                                            if not self.ProtectedItems[itemID] then
                                                count = count + 1
                                            end
                                            self.ProtectedItems[itemID] = true
                                            addSource(itemID, "ItemRack:" .. setName)
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
        
        if IsAddOnLoaded("Outfitter") and gOutfitter_Settings and gOutfitter_Settings.Outfits then
            for cat, outfits in pairs(gOutfitter_Settings.Outfits) do
                -- 只保护"完整套装"（Complete 分类）：Partial/Accessory/Special 不参与自动保护
                if cat == "Complete" and table.getn(outfits) > 0 then
                    for _, outfit in ipairs(outfits) do
                        if outfit.Items then
                            local hasItems = false
                            
                            for slot, item in pairs(outfit.Items) do
                                local itemID = tonumber(item.Code)
                                
                                if itemID and itemID > 0 then
                                    hasItems = true
                                    if not self.ProtectedItems[itemID] then
                                        count = count + 1
                                    end
                                    self.ProtectedItems[itemID] = true
                                    addSource(itemID, outfit.Name or "未命名套装")
                                end
                            end
                            
                            if hasItems then
                                setCount = setCount + 1
                            end
                        end
                    end
                end
            end
        end
        
        local db = self:GetPlayerDB()
        if db and db.lockedItems then
            -- 性能优化：一次性扫描背包构建 名称→ID 映射，避免对每个锁定物品重复遍历所有背包格子
            local nameToId = {}
            for bag = 0, 4 do
                for slot = 1, GetContainerNumSlots(bag) do
                    local link = GetContainerItemLink(bag, slot)
                    if link then
                        local name = self:ExtractItemName(link)
                        if name then
                            local _, _, itemID = string.find(link, "item:(%d+)")
                            nameToId[name] = tonumber(itemID)
                        end
                    end
                end
            end
            for itemName, locked in pairs(db.lockedItems) do
                if locked then
                    local itemID = nameToId[itemName]
                    if itemID then
                        if not self.ProtectedItems[itemID] then
                            count = count + 1
                        end
                        self.ProtectedItems[itemID] = true
                        addSource(itemID, "手动锁定")
                    end
                end
            end
        end

        -- 把来源写回 ProtectedItems（值从 true 变为来源描述串，真值语义不变）
        for itemID, srcSet in pairs(sources) do
            local parts = {}
            for n in pairs(srcSet) do
                table.insert(parts, n)
            end
            self.ProtectedItems[itemID] = table.concat(parts, "、")
        end
        
        if count ~= oldCount then
            DEFAULT_CHAT_FRAME:AddMessage("|cFF00FF00ItemLock: 已保护 " .. count .. " 个物品|r")
            self.lastUpdateCount = count
        end
    end)
    
    if not success then
        DEFAULT_CHAT_FRAME:AddMessage("|cFFFF0000ItemLock: 更新保护缓存时出错 - " .. tostring(errorMsg) .. "|r")
    end
end

function ItemLock:GetItemIDByName(itemName)
    if not itemName or itemName == "" then return nil end
    
    for bag = 0, 4 do
        for slot = 1, GetContainerNumSlots(bag) do
            local itemLink = GetContainerItemLink(bag, slot)
            if itemLink then
                local name = self:ExtractItemName(itemLink)
                if name == itemName then
                    local _, _, itemID = string.find(itemLink, "item:(%d+)")
                    return tonumber(itemID)
                end
            end
        end
    end
    
    return nil
end

function ItemLock:GetItemNameByID(itemID)
    if not itemID then return nil end
    
    for bag = 0, 4 do
        for slot = 1, GetContainerNumSlots(bag) do
            local itemLink = GetContainerItemLink(bag, slot)
            if itemLink then
                local _, _, currentID = string.find(itemLink, "item:(%d+)")
                if tonumber(currentID) == itemID then
                    return self:ExtractItemName(itemLink)
                end
            end
        end
    end
    
    return nil
end

function ItemLock:IsItemLocked(itemLink, itemName)
    if itemName then
        local db = self:GetPlayerDB()
        if db and db.lockedItems[itemName] then
            return true, "手动锁定"
        end
    end

    if itemLink then
        local _, _, itemID = string.find(itemLink, "item:(%d+)")
        itemID = tonumber(itemID)
        if itemID and self.ProtectedItems[itemID] then
            -- 第二返回值为保护来源（套装名等），供拦截提示显示
            return true, self.ProtectedItems[itemID]
        end
    end

    return false
end

function ItemLock:UseContainerItem(bag, slot, onSelf, reagentBankOpen)
    if MerchantFrame:IsVisible() and self.Config.enableSellProtection then
        local itemLink = GetContainerItemLink(bag, slot)
        if itemLink then
            local itemName = self:ExtractItemName(itemLink)
            local locked, source = self:IsItemLocked(itemLink, itemName)
            if locked then
                self:ShowWarning("无法出售受保护的物品: " .. itemName .. "（" .. (source or "未知来源") .. "）")
                return
            end
        end
    end

    if self.isDisenchanting and self.Config.enableDisenchantProtection then
        local itemLink = GetContainerItemLink(bag, slot)
        if itemLink then
            local itemName = self:ExtractItemName(itemLink)
            local locked, source = self:IsItemLocked(itemLink, itemName)
            if locked then
                self:ShowWarning("无法分解受保护的物品: " .. itemName .. "（" .. (source or "未知来源") .. "）")
                self:CancelDisenchant()
                return
            end
        end
    end
    
    self.hooks.UseContainerItem(bag, slot, onSelf, reagentBankOpen)
end

function ItemLock:PickupContainerItem(bag, slot)
    local itemLink = GetContainerItemLink(bag, slot)
    if itemLink then
        local _, _, itemID = string.find(itemLink, "item:(%d+)")
        self.cursorItemID = tonumber(itemID)
        self.cursorItemLink = itemLink
    else
        self.cursorItemID = nil
        self.cursorItemLink = nil
    end
    
    self.hooks.PickupContainerItem(bag, slot)
end

function ItemLock:PickupInventoryItem(slot)
    local itemLink = GetInventoryItemLink("player", slot)
    if itemLink then
        local _, _, itemID = string.find(itemLink, "item:(%d+)")
        self.cursorItemID = tonumber(itemID)
        self.cursorItemLink = itemLink
    else
        self.cursorItemID = nil
        self.cursorItemLink = nil
    end
    
    self.hooks.PickupInventoryItem(slot)
end

function ItemLock:DeleteCursorItem()
    if self.Config.enableDeleteProtection and self.cursorItemID and self.ProtectedItems[self.cursorItemID] then
        self:ShowWarning("无法摧毁受保护的物品!（" .. tostring(self.ProtectedItems[self.cursorItemID]) .. "）")
        self.cursorItemID = nil
        self.cursorItemLink = nil
        return
    end
    
    self.hooks.DeleteCursorItem()
    self.cursorItemID = nil
    self.cursorItemLink = nil
end

function ItemLock:MerchantItemButton_OnClick(button, ignoreShift)
    if CursorHasItem() and MerchantFrame.selectedTab == 1 then
        local itemName, itemID = self:GetCursorItemName()
        -- 同时覆盖“手动锁定”(按名，db.lockedItems) 与“套装自动保护”(按 ID，ProtectedItems)
        local source = nil
        if (itemName and self:IsItemLocked(nil, itemName)) or (itemID and self.ProtectedItems[itemID]) then
            if itemID then source = self.ProtectedItems[itemID] end
            self:ShowWarning("无法出售被锁定的物品: " .. (itemName or ("ID:" .. itemID)) .. "（" .. tostring(source or "手动锁定") .. "）")
            ClearCursor()
            return
        end
    end

    Original_MerchantItemButton_OnClick(button, ignoreShift)
end

function ItemLock:GetCursorItemName()
    -- 标准 1.12 客户端可用 GetCursorInfo 直接取光标物品；本客户端（乌龟服/SuperWoW 构建）
    -- 该全局为 nil，故优先用标准 API，缺失时回退到 Pickup* hook 记录的 self.cursorItemLink。
    if type(GetCursorInfo) == "function" then
        -- 1.12: GetCursorInfo() 对物品返回 "item", itemID, itemLink
        local cursorType, itemID, itemLink = GetCursorInfo()
        if cursorType == "item" and itemLink then
            local _, _, id = string.find(itemLink, "item:(%d+)")
            return self:ExtractItemName(itemLink), tonumber(id)
        end
        return nil
    end
    -- 回退：用 PickupContainerItem/PickupInventoryItem hook 记录的链接（拖到商人出售时即为光标物品）
    if self.cursorItemLink then
        local _, _, itemID = string.find(self.cursorItemLink, "item:(%d+)")
        return self:ExtractItemName(self.cursorItemLink), tonumber(itemID)
    end
    return nil
end

function ItemLock:ContainerFrameItemButton_OnClick(button, ignoreShift)
    local arg1 = arg1 or "LeftButton"
    
    if self.isDisenchanting and self.Config.enableDisenchantProtection then
        local itemLink = GetContainerItemLink(this:GetParent():GetID(), this:GetID())
        if itemLink then
            local locked, source = self:IsItemLocked(itemLink)
            if locked then
                self:ShowWarning("无法分解受保护的物品: " .. self:ExtractItemName(itemLink) .. "（" .. (source or "未知来源") .. "）")
                self:CancelDisenchant()
                return
            end
        end
    end
    
    if arg1 == "RightButton" and MerchantFrame:IsVisible() then
        local itemLink = GetContainerItemLink(this:GetParent():GetID(), this:GetID())
        if itemLink then
            local locked, source = self:IsItemLocked(itemLink)
            if locked then
                self:ShowWarning("无法出售被锁定的物品: " .. self:ExtractItemName(itemLink) .. "（" .. (source or "未知来源") .. "）")
                return
            end
        end
    end
    
    Original_ContainerFrameItemButton_OnClick(button, ignoreShift)
end

function ItemLock:RegisterSlashCommands()
    SLASH_ITEMLOCK1, SLASH_ITEMLOCK2 = "/itemlock", "/ilock"
    SlashCmdList["ITEMLOCK"] = function(msg)
        self:HandleCommand(msg)
    end
end

function ItemLock:HandleCommand(msg)
    local command, arg = string.match(msg, "^(%S+)%s*(.*)$")
    command = string.lower(command or msg)
    
    if command == "list" then
        self:ListLockedItems()
    elseif command == "status" then
        self:ShowStatus()
    elseif command == "add" then
        self:AddItem(arg)
    elseif command == "remove" then
        self:RemoveItem(arg)
    elseif command == "sell" then
        self:ToggleSellProtection(arg)
    elseif command == "delete" then
        self:ToggleDeleteProtection(arg)
    elseif command == "disenchant" or command == "de" then
        self:ToggleDisenchantProtection(arg)
    elseif command == "lockthis" then
        self:LockCurrentItem()
    elseif command == "addfromitemrack" then
        self:AddFromItemRack()
    elseif command == "addfromoutfitter" then
        self:AddFromOutfitter()
    elseif command == "update" or command == "refresh" then
        self:UpdateProtectedItems()
    elseif command == "unlockall" then
        self:UnlockAllItems()
    elseif command == "unlockallforce" or command == "unlockallcomplete" then
        self:UnlockAllItemsComplete()
    else
        self:ShowHelp()
    end
end

function ItemLock:ShowHelp()
    local commands = {
        "list - 显示所有锁定的物品",
        "status - 显示状态",
        "add [名称] - 新增手动锁定物品",
        "remove [名称] - 移除手动锁定物品",
        "sell on/off - 出售保护开关",
        "delete on/off - 摧毁保护开关",
        "disenchant on/off - 分解保护开关",
        "lockthis - 锁定鼠标物品",
        "addfromitemrack - 从ItemRack导入物品",
        "addfromoutfitter - 从Outfitter导入物品",
        "update - 更新保护缓存",
        "unlockall - 解锁所有物品（包括套装保护）",
        "unlockallforce - 强制解锁所有物品（无确认框）"
    }
    
    DEFAULT_CHAT_FRAME:AddMessage("|cFF00FF00ItemLock 2.0 命令:|r")
    for _, cmd in ipairs(commands) do
        DEFAULT_CHAT_FRAME:AddMessage("  /itemlock " .. cmd)
    end
end

function ItemLock:LockCurrentItem()
    local itemName = GameTooltipTextLeft1:GetText()
    local itemLink = GetMouseFocus() and GetMouseFocus():GetName() and GetContainerItemLink(GetMouseFocus():GetParent():GetID(), GetMouseFocus():GetID())
    
    if itemLink then
        itemName = self:ExtractItemName(itemLink)
    end
    
    if itemName and itemName ~= "" then
        self:AddItem(itemName)
    else
        DEFAULT_CHAT_FRAME:AddMessage("|cFFFF0000错误: 请将鼠标悬停在物品上|r")
    end
end

function ItemLock:ListLockedItems()
    DEFAULT_CHAT_FRAME:AddMessage("|cFF00FF00所有锁定的物品:|r")
    
    local db = self:GetPlayerDB()
    local manualCount = 0
    local autoCount = 0
    
    if db and db.lockedItems then
        DEFAULT_CHAT_FRAME:AddMessage("|cFF00FF00手动锁定的物品:|r")
        for itemName, locked in pairs(db.lockedItems) do
            if locked then
                DEFAULT_CHAT_FRAME:AddMessage("  " .. itemName)
                manualCount = manualCount + 1
            end
        end
    end
    
    if manualCount == 0 then
        DEFAULT_CHAT_FRAME:AddMessage("  没有手动锁定的物品")
    else
        DEFAULT_CHAT_FRAME:AddMessage("  手动锁定总计: " .. manualCount .. " 个物品")
    end
    
    DEFAULT_CHAT_FRAME:AddMessage("|cFF00FF00从套装自动保护的物品:|r")
    for itemID, source in pairs(self.ProtectedItems) do
        if source then
            local itemName = self:GetItemNameByID(itemID)
            if itemName then
                DEFAULT_CHAT_FRAME:AddMessage("  " .. itemName .. " (ID:" .. itemID .. ") — " .. tostring(source))
                autoCount = autoCount + 1
            end
        end
    end
    
    if autoCount == 0 then
        DEFAULT_CHAT_FRAME:AddMessage("  没有从套装自动保护的物品")
    else
        DEFAULT_CHAT_FRAME:AddMessage("  套装保护总计: " .. autoCount .. " 个物品")
    end
    
    DEFAULT_CHAT_FRAME:AddMessage("|cFF00FF00保护物品总数: " .. self.lastUpdateCount .. "|r")
end

function ItemLock:ShowStatus()
    local status = {
        "出售保护: " .. (self.Config.enableSellProtection and "|cFF00FF00启用|r" or "|cFFFF0000禁用|r"),
        "摧毁保护: " .. (self.Config.enableDeleteProtection and "|cFF00FF00启用|r" or "|cFFFF0000禁用|r"),
        "分解保护: " .. (self.Config.enableDisenchantProtection and "|cFF00FF00启用|r" or "|cFFFF0000禁用|r"),
        "警告信息: " .. (self.Config.showWarningMessages and "|cFF00FF00启用|r" or "|cFFFF0000禁用|r"),
        "警告音效: " .. (self.Config.playWarningSound and "|cFF00FF00启用|r" or "|cFFFF0000禁用|r")
    }
    
    DEFAULT_CHAT_FRAME:AddMessage("|cFF00FF00ItemLock 状态:|r")
    for _, line in ipairs(status) do
        DEFAULT_CHAT_FRAME:AddMessage("  " .. line)
    end
end

function ItemLock:AddItem(itemName)
    if not itemName or itemName == "" then
        DEFAULT_CHAT_FRAME:AddMessage("|cFFFF0000错误: 请输入物品名称|r")
        return
    end
    
    local db = self:GetPlayerDB()
    if db then
        db.lockedItems[itemName] = true
        DEFAULT_CHAT_FRAME:AddMessage("|cFF00FF00已锁定: |r" .. itemName)
        self:UpdateProtectedItems()
    end
end

function ItemLock:RemoveItem(itemName)
    if not itemName or itemName == "" then
        DEFAULT_CHAT_FRAME:AddMessage("|cFFFF0000错误: 请输入物品名称|r")
        return
    end
    
    local db = self:GetPlayerDB()
    if db and db.lockedItems[itemName] then
        db.lockedItems[itemName] = nil
        DEFAULT_CHAT_FRAME:AddMessage("|cFF00FF00已解锁: |r" .. itemName)
        self:UpdateProtectedItems()
    else
        DEFAULT_CHAT_FRAME:AddMessage("|cFFFF0000错误: 未找到物品 |r" .. itemName)
    end
end

function ItemLock:ToggleSellProtection(arg)
    if arg == "on" then
        self.Config.enableSellProtection = true
        DEFAULT_CHAT_FRAME:AddMessage("|cFF00FF00出售保护已启用|r")
    elseif arg == "off" then
        self.Config.enableSellProtection = false
        DEFAULT_CHAT_FRAME:AddMessage("|cFFFF0000出售保护已禁用|r")
    else
        DEFAULT_CHAT_FRAME:AddMessage("|cFFFF0000用法: /itemlock sell on/off|r")
    end
    self:SaveConfig()
end

function ItemLock:ToggleDeleteProtection(arg)
    if arg == "on" then
        self.Config.enableDeleteProtection = true
        DEFAULT_CHAT_FRAME:AddMessage("|cFF00FF00摧毁保护已启用|r")
    elseif arg == "off" then
        self.Config.enableDeleteProtection = false
        DEFAULT_CHAT_FRAME:AddMessage("|cFFFF0000摧毁保护已禁用|r")
    else
        DEFAULT_CHAT_FRAME:AddMessage("|cFFFF0000用法: /itemlock delete on/off|r")
    end
    self:SaveConfig()
end

function ItemLock:ToggleDisenchantProtection(arg)
    if arg == "on" then
        self.Config.enableDisenchantProtection = true
        DEFAULT_CHAT_FRAME:AddMessage("|cFF00FF00分解保护已启用|r")
    elseif arg == "off" then
        self.Config.enableDisenchantProtection = false
        DEFAULT_CHAT_FRAME:AddMessage("|cFFFF0000分解保护已禁用|r")
    else
        DEFAULT_CHAT_FRAME:AddMessage("|cFFFF0000用法: /itemlock disenchant on/off|r")
    end
    self:SaveConfig()
end

function ItemLock:AddFromItemRack()
    local playerKey = self:GetPlayerKey()
    local itemRackPlayerKey = UnitName("player") .. " of " .. GetRealmName()
    
    if not Rack_User or not Rack_User[itemRackPlayerKey] then
        DEFAULT_CHAT_FRAME:AddMessage("|cFFFF0000错误: 未找到ItemRack数据，请确保已加载ItemRack插件|r")
        return
    end
    
    local itemRackData = Rack_User[itemRackPlayerKey]
    if not itemRackData.Sets then
        DEFAULT_CHAT_FRAME:AddMessage("|cFFFF0000错误: 未找到ItemRack套装数据|r")
        return
    end
    
    local db = self:GetPlayerDB()
    if not db then return end
    
    local importedCount, skippedCount = 0, 0
    
    for setName, setData in pairs(itemRackData.Sets) do
        if not string.find(setName, "^Rack%-") then
            for slotIndex, itemData in pairs(setData) do
                if type(slotIndex) == "number" and itemData and itemData.name and itemData.name ~= "(empty)" then
                    local itemName = itemData.name
                    if not db.lockedItems[itemName] then
                        db.lockedItems[itemName] = true
                        importedCount = importedCount + 1
                    else
                        skippedCount = skippedCount + 1
                    end
                end
            end
        end
    end
    
    DEFAULT_CHAT_FRAME:AddMessage("|cFF00FF00ItemRack导入完成! 新增 " .. importedCount .. " 个物品，跳过 " .. skippedCount .. " 个已存在的物品|r")
    self:UpdateProtectedItems()
end

function ItemLock:AddFromOutfitter()
    if not gOutfitter_Settings or not gOutfitter_Settings.Outfits then
        DEFAULT_CHAT_FRAME:AddMessage("|cFFFF0000错误: 未找到Outfitter数据，请确保已加载Outfitter插件|r")
        return
    end
    
    local db = self:GetPlayerDB()
    if not db then return end
    
    local importedCount, skippedCount = 0, 0
    
    for categoryName, outfits in pairs(gOutfitter_Settings.Outfits) do
        for outfitIndex, outfit in pairs(outfits) do
            if outfit.Items then
                for slotName, itemData in pairs(outfit.Items) do
                    if itemData and itemData.Name and itemData.Name ~= "" then
                        local itemName = itemData.Name
                        if not db.lockedItems[itemName] then
                            db.lockedItems[itemName] = true
                            importedCount = importedCount + 1
                        else
                            skippedCount = skippedCount + 1
                        end
                    end
                end
            end
        end
    end
    
    DEFAULT_CHAT_FRAME:AddMessage("|cFF00FF00Outfitter导入完成! 新增 " .. importedCount .. " 个物品，跳过 " .. skippedCount .. " 个已存在的物品|r")
    self:UpdateProtectedItems()
end

function ItemLock:UnlockAllItems()
    local db = self:GetPlayerDB()
    if not db then
        DEFAULT_CHAT_FRAME:AddMessage("|cFFFF0000ItemLock: 数据库未初始化|r")
        return
    end
    
    -- 统计解锁的物品数量
    local manualCount = 0
    local autoCount = 0
    
    -- 解锁手动锁定的物品
    if db.lockedItems then
        for itemName, _ in pairs(db.lockedItems) do
            manualCount = manualCount + 1
        end
        db.lockedItems = {}
    end
    
    -- 解锁自动保护的物品（从套装导入的）
    -- 我们需要清除ProtectedItems表中的所有条目
    for itemID, _ in pairs(self.ProtectedItems) do
        autoCount = autoCount + 1
    end
    self.ProtectedItems = {}
    
    -- 如果ItemRack或Outfitter已加载，我们也需要清除它们的缓存
    if IsAddOnLoaded("ItemRack") then
        self:ClearItemRackCache()
    end
    
    if IsAddOnLoaded("Outfitter") then
        self:ClearOutfitterCache()
    end
    
    local totalCount = manualCount + autoCount
    
    if totalCount == 0 then
        DEFAULT_CHAT_FRAME:AddMessage("|cFFFF0000ItemLock: 没有锁定的物品|r")
        return
    end
    
    -- 确认对话框
    StaticPopupDialogs["ITEMLOCK_UNLOCK_ALL"] = {
        text = "确定要解锁所有 " .. totalCount .. " 个锁定的物品吗？\n\n这包括:\n" .. 
               "  • " .. manualCount .. " 个手动锁定的物品\n" ..
               "  • " .. autoCount .. " 个从套装自动保护的物品\n\n" ..
               "注意: 这只是从ItemLock保护中移除，\n不会影响ItemRack/Outfitter中的套装设置。",
        button1 = "确定解锁",
        button2 = "取消",
        OnAccept = function()
            -- 清空手动锁定物品（已经在上面做了）
            -- 清空自动保护物品（已经在上面做了）
            
            -- 设置标志，防止UpdateProtectedItems重新计算
            self.justUnlockedAll = true
            
            -- 更新保护缓存
            self:UpdateProtectedItems()
            
            -- 显示提示
            DEFAULT_CHAT_FRAME:AddMessage("|cFF00FF00ItemLock: 已解锁所有 " .. totalCount .. " 个物品|r")
            DEFAULT_CHAT_FRAME:AddMessage("|cFF00FF00  • 手动锁定的物品: " .. manualCount .. " 个|r")
            DEFAULT_CHAT_FRAME:AddMessage("|cFF00FF00  • 套装保护的物品: " .. autoCount .. " 个|r")
            UIErrorsFrame:AddMessage("已解锁所有物品", 0.0, 1.0, 0.0, 1.0, 5)
            
            -- 刷新背包界面
            self:RefreshBagFrames()
        end,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
        preferredIndex = 3,
    }
    
    StaticPopup_Show("ITEMLOCK_UNLOCK_ALL")
end

function ItemLock:UnlockAllItemsComplete()
    local db = self:GetPlayerDB()
    if not db then return end
    
    -- 解锁手动锁定的物品
    local manualCount = 0
    if db.lockedItems then
        for itemName, _ in pairs(db.lockedItems) do
            manualCount = manualCount + 1
        end
        db.lockedItems = {}
    end
    
    -- 解锁自动保护的物品
    local autoCount = 0
    for itemID, _ in pairs(self.ProtectedItems) do
        autoCount = autoCount + 1
    end
    self.ProtectedItems = {}
    
    -- 清空ItemRack缓存（如果已加载）
    if IsAddOnLoaded("ItemRack") then
        self:ClearItemRackCache()
    end
    
    -- 清空Outfitter缓存（如果已加载）
    if IsAddOnLoaded("Outfitter") then
        self:ClearOutfitterCache()
    end
    
    -- 设置标志，防止UpdateProtectedItems重新计算
    self.justUnlockedAll = true
    
    -- 更新保护缓存
    self:UpdateProtectedItems()
    
    local totalCount = manualCount + autoCount
    
    if totalCount > 0 then
        DEFAULT_CHAT_FRAME:AddMessage("|cFF00FF00ItemLock: 已完全解锁所有 " .. totalCount .. " 个物品|r")
        DEFAULT_CHAT_FRAME:AddMessage("|cFF00FF00  • 手动锁定的物品: " .. manualCount .. " 个|r")
        DEFAULT_CHAT_FRAME:AddMessage("|cFF00FF00  • 套装保护的物品: " .. autoCount .. " 个|r")
        
        -- 刷新背包界面
        self:RefreshBagFrames()
    else
        DEFAULT_CHAT_FRAME:AddMessage("|cFFFF0000ItemLock: 没有锁定的物品|r")
    end
end

function ItemLock:ClearItemRackCache()
    if not IsAddOnLoaded("ItemRack") then return end
    
    -- 尝试清除ItemRack相关缓存
    if ItemRack and ItemRack.UpdateSets then
        -- 尝试触发ItemRack更新，让它重新计算
        ItemRack.UpdateSets()
    end
    
    -- 清除Rack_User中的套装数据（可选）
    if Rack_User then
        local user = UnitName("player") .. " of " .. GetCVar("realmName")
        if Rack_User[user] and Rack_User[user].Sets then
            -- 我们不删除套装数据，只是标记需要重新计算
            -- 实际上，ItemRack会在下次登录时重新计算
        end
    end
end

function ItemLock:ClearOutfitterCache()
    if not IsAddOnLoaded("Outfitter") then return end
    
    -- 清除gOutfitter_Settings中的缓存数据
    if gOutfitter_Settings and gOutfitter_Settings.Outfits then
        -- 我们不清除实际的套装数据，只是让Outfitter重新计算
        -- Outfitter会在下次需要时重新计算
    end
end

function ItemLock:RefreshBagFrames()
    -- 刷新背包界面（如果OneBag已加载）
    if OneBag and OneBag.UpdateLockedItems then
        for bag = 0, 4 do
            OneBag:UpdateLockedItems(bag)
        end
    end
    
    -- 刷新银行界面（如果OneBank已加载）
    if OneBank and OneBank.UpdateLockedItems then
        for bag = -1, 10 do
            OneBank:UpdateLockedItems(bag)
        end
    end
    
    -- 尝试刷新所有可见的容器框架
    for i = 1, NUM_CONTAINER_FRAMES do
        local frame = getglobal("ContainerFrame" .. i)
        if frame and frame:IsVisible() then
            -- 优先用 OneBag 的安全版刷新（若已加载），避免整理后重绘触发 tooltip 闪烁
            if OneBag_SafeContainerFrame_Update then
                OneBag_SafeContainerFrame_Update(frame)
            else
                ContainerFrame_Update(frame)
            end
        end
    end
end