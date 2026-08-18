--[[
    RIVALS · Skin Changer / Unlocker
    ---------------------------------------------------------------------------
    從 Aetherea (loader.luau) 的 Unlocker 區塊移植出來的獨立腳本。
    UI 使用 UELinoriaLib (https://github.com/pandaeatdonuts-byte/UELinoriaLib)。

    做的事情：
      · Unlock  — 讓遊戲以為你擁有全部皮膚 / 包裝 / 吊飾 / 終結技 / 武器
      · Equip   — 攔截 EquipCosmetic remote，在本地套用外觀（含視覺 hook）

    全部都是客戶端假資料，伺服器那邊看不到，也不會存檔。
    ---------------------------------------------------------------------------
]]

--=============================================================================
-- 0. 前置檢查
--=============================================================================

local GAME_ID = 6035872082 -- RIVALS

if game.GameId ~= GAME_ID then
    warn(("[SkinChanger] 這不是 RIVALS（GameId = %s），已中止。"):format(tostring(game.GameId)))
    return
end

if not game:IsLoaded() then
    game.Loaded:Wait()
end

local genv = (getgenv and getgenv()) or _G

if genv.__RIVALS_SKINCHANGER then
    -- 已經有一份在跑，先把舊的收掉再重載
    pcall(function() genv.__RIVALS_SKINCHANGER.Unload() end)
end

-- 執行器能力偵測。沒有 __namecall hook 的話 Unlocker 還是能用，
-- 但 Equip（攔截 remote 在本地套外觀）就沒辦法運作。
local has_namecall = type(hookmetamethod) == "function" and type(getnamecallmethod) == "function"
local newcclosure = newcclosure or function(f) return f end
local cloneref = cloneref or function(o) return o end

--=============================================================================
-- 1. 載入 UI 函式庫（UELinoriaLib）
--=============================================================================

-- 依序嘗試。自己的 repo 擺第一，上游擺備援：
-- 上游哪天被刪掉腳本還是開得起來，自己的 repo 掛了也還有救。
local UI_REPOS = {
    "https://raw.githubusercontent.com/smallhuang100/skinchanger/main/lib/",
    "https://raw.githubusercontent.com/pandaeatdonuts-byte/UELinoriaLib/main/",
}

local UI_LOCAL_FOLDER = "RivalsSkinChanger/lib/" -- 執行器 workspace 底下

local function TryChunk(source, path)
    if type(source) ~= "string" or #source == 0 then return nil end

    local chunk = loadstring(source, "@" .. path)
    if not chunk then return nil end

    local ok, result = pcall(chunk)
    if ok and result then return result end

    return nil
end

local function LoadUIModule(path)
    -- 本地優先：把 lib/ 丟進 <executor>/workspace/RivalsSkinChanger/lib/ 就不用連網
    if type(isfile) == "function" and type(readfile) == "function" then
        local local_path = UI_LOCAL_FOLDER .. path
        local ok, exists = pcall(isfile, local_path)
        if ok and exists then
            local ok2, source = pcall(readfile, local_path)
            if ok2 then
                local result = TryChunk(source, path)
                if result then return result end
                warn("[SkinChanger] 本地 " .. path .. " 載入失敗，改用遠端。")
            end
        end
    end

    local last_error = "沒有可用的來源"

    for _, base in ipairs(UI_REPOS) do
        -- 加隨機參數繞過 raw.githubusercontent 的快取
        local url = base .. path .. "?r=" .. tostring(math.random(1, 1e9))
        local ok, source = pcall(game.HttpGet, game, url)

        if ok then
            local result = TryChunk(source, path)
            if result then return result end
            last_error = ("%s 抓得到但內容壞掉（可能被截斷）"):format(base)
        else
            last_error = tostring(source)
        end
    end

    error(("[SkinChanger] 載入 %s 失敗：%s"):format(path, last_error), 0)
end

local Library      = LoadUIModule("Library.lua")
local ThemeManager = LoadUIModule("addons/ThemeManager.lua")
local SaveManager  = LoadUIModule("addons/SaveManager.lua")

--=============================================================================
-- 2. 服務與遊戲模組
--=============================================================================

local function GetService(name)
    return cloneref(game:GetService(name))
end

local services = {
    Players           = GetService("Players"),
    ReplicatedStorage = GetService("ReplicatedStorage"),
    RunService        = GetService("RunService"),
}

local LocalPlayer = services.Players.LocalPlayer

local function Require(instance)
    if not instance then return nil end
    local ok, result = pcall(require, instance)
    return ok and result or nil
end

local RSModules   = services.ReplicatedStorage:WaitForChild("Modules", 30)
local PlayerScrpt = LocalPlayer:WaitForChild("PlayerScripts", 30)

assert(RSModules and PlayerScrpt, "[SkinChanger] 找不到遊戲模組資料夾，遊戲可能更新了。")

local Controllers = PlayerScrpt:WaitForChild("Controllers", 30)
local PSModules   = PlayerScrpt:WaitForChild("Modules", 30)

local modules = {
    CosmeticLibrary      = Require(RSModules:WaitForChild("CosmeticLibrary", 20)),
    ItemLibrary          = Require(RSModules:WaitForChild("ItemLibrary", 20)),
    EnumLibrary          = Require(RSModules:WaitForChild("EnumLibrary", 20)),
    ShopLibrary          = Require(RSModules:WaitForChild("ShopLibrary", 20)),
    ReplicatedClass      = Require(RSModules:FindFirstChild("ReplicatedClass")),
    PlayerDataController = Require(Controllers:WaitForChild("PlayerDataController", 20)),
}

assert(modules.CosmeticLibrary and modules.CosmeticLibrary.Cosmetics,
    "[SkinChanger] CosmeticLibrary 載入失敗。")
assert(modules.PlayerDataController, "[SkinChanger] PlayerDataController 載入失敗。")

-- FighterController 是延遲建立的，不能直接 WaitForChild 卡住整個腳本
task.spawn(function()
    local fc = Controllers:WaitForChild("FighterController", 60)
    if fc then
        modules.FighterController = Require(fc)
    end
end)

-- 資料要等 CurrentData 出現才讀得到，否則初始快照會是 nil
do
    local deadline = os.clock() + 30
    while not modules.PlayerDataController.CurrentData and os.clock() < deadline do
        task.wait(0.1)
    end
end

--=============================================================================
-- 3. 狀態
--=============================================================================

local function SafeGet(key, fallback)
    local ok, value = pcall(function()
        return modules.PlayerDataController:Get(key)
    end)
    if ok and value ~= nil then return value end
    return fallback
end

local state = {
    -- 假資料本體
    fake_owned        = SafeGet("CosmeticInventory", {}),
    fake_weapon_owned = {}, -- 不要用真實清單當預設值，否則之後解鎖的武器查不到會 nil 崩潰
    favorites         = SafeGet("FavoritedCosmetics", {}),

    -- fake_owned 直接就是遊戲那份背包表（Get 回傳的是本體不是複本），
    -- 所以要另外記住「哪些是我們自己塞進去的」，Lock / 卸載時才不會
    -- 把玩家真正擁有的外觀一起砍掉。
    injected          = {},
    equipped          = {},
    placed_object_map = {},

    -- 執行期暫存
    constructing_weapon = nil,
    viewing_profile     = nil,
    last_used_weapon    = nil,

    -- 設定
    intercept_equip = true,  -- 攔截 EquipCosmetic，在本地套外觀
    unloaded        = false,

    unlocker = {
        type    = "Skin",
        rarity  = "Common",
        weapon  = "",
        cosmetic = "",
    },

    equip = {
        type           = "Skin",
        weapon         = "",
        cosmetic       = "",
        inverted       = false,
        favorites_only = false,
    },
}

local caches = {
    objectid_to_weapon = {},
}

local COSMETIC_TYPES = { "Skin", "Wrap", "Charm", "Finisher" }
local COSMETIC_RARITIES = { "Common", "Rare", "Legendary", "Mythical", "Unique", "Unobtainable" }

genv.__RIVALS_SKINCHANGER = {
    State = state,
    Unload = function() end, -- 之後由 Library:OnUnload 覆寫
}

--=============================================================================
-- 4. Unlocker 核心 · 擁有判定 hook
--=============================================================================

local originals = {}

-- CosmeticLibrary 有五個不同簽章的「是否擁有」查詢，全部都要蓋掉，
-- 只要名字在 fake_owned 裡就無條件回 true。
do
    local CL = modules.CosmeticLibrary

    local function WrapOwns(method_name, name_arg_index)
        local original = CL[method_name]
        if type(original) ~= "function" then return end

        originals[method_name] = original

        CL[method_name] = function(...)
            if not state.unloaded then
                local name = (select(name_arg_index, ...))
                if name ~= nil and state.fake_owned[name] then
                    return true
                end
            end
            return original(...)
        end
    end

    WrapOwns("OwnsCosmeticNormally", 3)
    WrapOwns("OwnsCosmeticUniversally", 3)
    WrapOwns("OwnsCosmeticForSomething", 3)
    WrapOwns("OwnsCosmeticForWeapon", 3)
    WrapOwns("OwnsCosmetic", 3) -- (self, inventory, name, weapon)
end

--=============================================================================
-- 5. Unlocker 核心 · 背包資料 hook
--=============================================================================

-- 把偽裝武器清單「疊加」在真實清單上面，而不是整份取代掉真實清單，
-- 這樣沒被偽裝到的武器一律照真實資料走，不會用到過時的假資料。
local function MergeWeaponInventory(real, fake)
    if type(fake) ~= "table" or #fake == 0 then
        return real
    end

    local merged = {}
    local overridden = {}

    for _, weapon in ipairs(fake) do
        table.insert(merged, weapon)
        if type(weapon) == "table" and weapon.Name then
            overridden[weapon.Name] = true
        end
    end

    if type(real) == "table" then
        for _, weapon in pairs(real) do
            if not (type(weapon) == "table" and weapon.Name and overridden[weapon.Name]) then
                table.insert(merged, weapon)
            end
        end
    end

    return merged
end

local function OverrideDataKey(key, data)
    if key == "CosmeticInventory" then
        return state.fake_owned or data
    elseif key == "WeaponInventory" or key == "FreeWeaponUnlockCheck" then
        return MergeWeaponInventory(data, state.fake_weapon_owned)
    elseif key == "FavoritedCosmetics" then
        return state.favorites or data
    end
    return data
end

do
    local PDC = modules.PlayerDataController

    originals.Get = PDC.Get
    PDC.Get = function(self, ...)
        local data = originals.Get(self, ...)
        if state.unloaded then return data end
        return OverrideDataKey((select(1, ...)), data)
    end

    originals.GetWeaponData = PDC.GetWeaponData
    PDC.GetWeaponData = function(self, ...)
        local weapon_name = (select(1, ...))
        local original_data, index = originals.GetWeaponData(self, ...)

        if state.unloaded then return original_data, index end

        local fake_owned = false
        for _, weapon in ipairs(state.fake_weapon_owned) do
            if weapon.Name == weapon_name then
                fake_owned = true
                break
            end
        end

        -- 假武器：遊戲本來查不到任何資料，這裡憑空生一份出來
        if fake_owned and not original_data then
            local fake_data = {
                Name = weapon_name,
                Level = 1,
                XP = 0,
                IsFavorited = false,
                Skin = nil,
            }

            local equipped = state.equipped[weapon_name]
            if equipped then
                for cos_type, cos_data in pairs(equipped) do
                    if type(cos_data) == "table"
                        and (cos_data.Name == "NONE_COSMETIC" or cos_data.Name == "None") then
                        fake_data[cos_type] = nil
                    else
                        fake_data[cos_type] = cos_data
                    end
                end
            end

            return fake_data, index
        end

        -- 真武器：把本地裝備的外觀塞進真實資料裡
        local equipped = original_data and state.equipped[weapon_name]
        if equipped then
            for cos_type, cos_data in pairs(equipped) do
                if type(cos_data) == "table"
                    and (cos_data.Name == "NONE_COSMETIC" or cos_data.Name == "None") then
                    original_data[cos_type] = nil
                else
                    original_data[cos_type] = cos_data
                end
            end
        end

        return original_data, index
    end
end

-- PlayerDataController.CurrentData 是另一個物件，有自己的 :Get，也要補一份
local function PatchCurrentDataGet(current_data)
    if not current_data
        or type(current_data.Get) ~= "function"
        or current_data.__skinchanger_patched then
        return
    end

    local old_get = current_data.Get
    current_data.Get = function(self, ...)
        local data = old_get(self, ...)
        if state.unloaded then return data end
        return OverrideDataKey((select(1, ...)), data)
    end

    current_data.__skinchanger_patched = true
end

task.spawn(function()
    while not modules.PlayerDataController.CurrentData do
        task.wait(0.1)
    end
    PatchCurrentDataGet(modules.PlayerDataController.CurrentData)
end)

--=============================================================================
-- 6. 外觀資料 · Clone / Resolve
--=============================================================================

local function CloneCosmetic(name, cosmetic_type, options)
    if not modules.CosmeticLibrary or not modules.CosmeticLibrary.Cosmetics then return nil end

    local base = modules.CosmeticLibrary.Cosmetics[name]
    if not base then return nil end

    local data = table.clone(base)
    data.Name = name
    data.Type = data.Type or cosmetic_type
    data.Seed = math.random(1, 1000000)

    if modules.EnumLibrary then
        pcall(function()
            local enum_id = modules.EnumLibrary:ToEnum(name)
            if enum_id then
                data.Enum, data.ObjectID = enum_id, enum_id
            end
        end)
    end

    if options then
        if options.inverted then data.Inverted = true end
        if options.favorites_only then data.OnlyUseFavorites = true end
    end

    return data
end

local function GetRandomCosmetic(cosmetic_type, weapon_name, is_inverted, only_use_favorites)
    local available = {}
    local inventory = modules.PlayerDataController:Get("CosmeticInventory")

    for cosmetic_name, cosmetic_data in pairs(modules.CosmeticLibrary.Cosmetics) do
        if cosmetic_data.Type == cosmetic_type
            and modules.CosmeticLibrary:OwnsCosmetic(inventory, cosmetic_name, weapon_name)
            and (cosmetic_type ~= "Skin" or cosmetic_data.ItemName == weapon_name) then
            table.insert(available, cosmetic_name)
        end
    end

    if #available == 0 then return nil end

    return CloneCosmetic(available[math.random(#available)], cosmetic_type, {
        inverted = is_inverted,
        favorites_only = only_use_favorites,
    })
end

local function ResolveCosmetic(weapon_name, cosmetic_type)
    local slot = state.equipped[weapon_name]
    local equipped = slot and slot[cosmetic_type]

    if not equipped then return nil end
    if equipped.Name == "None" or equipped.Name == "NONE_COSMETIC" then return nil end

    if equipped.Name == "Random" or equipped.Name == "RANDOM_COSMETIC" then
        return GetRandomCosmetic(
            cosmetic_type,
            weapon_name,
            equipped.Inverted,
            equipped.OnlyUseFavorites
        )
    end

    return equipped
end

--=============================================================================
-- 7. Remote 攔截 · EquipCosmetic / FavoriteCosmetic / UseItem
--=============================================================================

local function RebuildObjectIDMap()
    if not modules.FighterController then return end
    pcall(function()
        local fighter = modules.FighterController:GetFighter(LocalPlayer)
        if not fighter or not fighter.Items then return end
        for _, item in pairs(fighter.Items) do
            local ok, oid = pcall(function() return item:Get("ObjectID") end)
            if ok and oid ~= nil then
                caches.objectid_to_weapon[tostring(oid)] = item.Name
            end
        end
    end)
end

task.spawn(function()
    while not state.unloaded do
        RebuildObjectIDMap()
        task.wait(5)
    end
end)

-- 記住玩家最後開火的武器，終結技要靠這個判斷該播哪一個
local function HandleUseItem(args)
    if not modules.FighterController then return end

    local oid_str = args[1] ~= nil and tostring(args[1]) or nil
    if not oid_str then return end

    local cached = caches.objectid_to_weapon[oid_str]
    if cached then
        state.last_used_weapon = cached
        return
    end

    task.spawn(function()
        pcall(function()
            local fighter = modules.FighterController:GetFighter(LocalPlayer)
            if not fighter or not fighter.Items then return end
            for _, item in pairs(fighter.Items) do
                local ok, oid = pcall(function() return item:Get("ObjectID") end)
                if ok and oid ~= nil and tostring(oid) == oid_str then
                    state.last_used_weapon = item.Name
                    caches.objectid_to_weapon[oid_str] = item.Name
                    break
                end
            end
        end)
    end)
end

-- 裝備請求不往伺服器送，改記在本地，再由下面那串視覺 hook 畫出來
local function HandleEquip(args)
    local weapon_name   = args[1]
    local cosmetic_type = args[2]
    local cosmetic_name = args[3]
    local options       = args[4] or {}

    if typeof(weapon_name) ~= "string" or typeof(cosmetic_type) ~= "string" then return end

    state.equipped[weapon_name] = state.equipped[weapon_name] or {}

    if not cosmetic_name or cosmetic_name == "" or cosmetic_name == "None" or cosmetic_name == "NONE_COSMETIC" then
        state.equipped[weapon_name][cosmetic_type] = { Name = "NONE_COSMETIC" }

    elseif cosmetic_name == "Random" or cosmetic_name == "RANDOM_COSMETIC" then
        state.equipped[weapon_name][cosmetic_type] = {
            Name             = cosmetic_name,
            Type             = cosmetic_type,
            Inverted         = options.IsInverted,
            OnlyUseFavorites = options.OnlyUseFavorites,
            Seed             = math.random(1, 1000000),
        }

    else
        local cloned = CloneCosmetic(cosmetic_name, cosmetic_type, {
            inverted       = options.IsInverted,
            favorites_only = options.OnlyUseFavorites,
        })
        if cloned then
            state.equipped[weapon_name][cosmetic_type] = cloned
        end
    end

    -- 讓遊戲自己的背包 UI 重新讀一次（會走到我們 hook 過的 Get）
    task.spawn(function()
        task.wait(0.1)
        pcall(function()
            local cd = modules.PlayerDataController.CurrentData
            if cd then cd:Replicate("WeaponInventory") end
        end)
    end)
end

local function HandleFavorite(args)
    local weapon_name   = args[1]
    local cosmetic_name = args[2]
    local favorited     = args[3]

    if typeof(weapon_name) ~= "string" then return end

    state.favorites[weapon_name] = state.favorites[weapon_name] or {}
    state.favorites[weapon_name][cosmetic_name] = favorited or nil
end

if has_namecall then
    local original_namecall
    original_namecall = hookmetamethod(game, "__namecall", newcclosure(function(self, ...)
        if state.unloaded then
            return original_namecall(self, ...)
        end

        if getnamecallmethod() == "FireServer" then
            local ok, remote_name = pcall(function() return self.Name end)

            if ok then
                if remote_name == "UseItem" then
                    HandleUseItem({ ... })

                elseif remote_name == "EquipCosmetic" and state.intercept_equip then
                    HandleEquip({ ... })
                    return -- 吃掉，不往伺服器送

                elseif remote_name == "FavoriteCosmetic" and state.intercept_equip then
                    HandleFavorite({ ... })
                    return
                end
            end
        end

        return original_namecall(self, ...)
    end))

    originals.namecall = original_namecall
else
    warn("[SkinChanger] 執行器沒有 hookmetamethod / getnamecallmethod，Equip 功能停用（Unlock 仍可用）。")
end

--=============================================================================
-- 8. 查詢輔助
--=============================================================================

local function GetCosmeticsByRarity(rarity)
    local results = {}
    for name, cosmetic in pairs(modules.CosmeticLibrary.Cosmetics) do
        if cosmetic.Rarity == rarity then
            table.insert(results, name)
        end
    end
    return results
end

local function GetCosmeticsByType(type_name)
    local results = {}
    for name, cosmetic in pairs(modules.CosmeticLibrary.Cosmetics) do
        if cosmetic.Type == type_name then
            table.insert(results, name)
        end
    end
    return results
end

local function GetSpecificCosmetic(type_name, cos_name, weapon_name)
    for name, cosmetic in pairs(modules.CosmeticLibrary.Cosmetics) do
        if name == cos_name and cosmetic.Type == type_name then
            -- 皮膚綁定特定武器，其他類型（包裝 / 吊飾 / 終結技）是通用的
            if type_name ~= "Skin" or cosmetic.ItemName == weapon_name then
                return name
            end
        end
    end
    return nil
end

local function GetAllCosmeticsOfWeapon(weapon_name)
    local results = {}
    for name, cosmetic in pairs(modules.CosmeticLibrary.Cosmetics) do
        if cosmetic.Type == "Skin" then
            if cosmetic.ItemName == weapon_name then
                table.insert(results, name)
            end
        else
            table.insert(results, name)
        end
    end
    return results
end

local function GetAllCosmetics()
    local results = {}
    for name in pairs(modules.CosmeticLibrary.Cosmetics) do
        table.insert(results, name)
    end
    return results
end

local function GetOwnedWeaponNames()
    local owned = {}
    local inventory = originals.Get(modules.PlayerDataController, "WeaponInventory")
    if type(inventory) == "table" then
        for _, weapon_data in pairs(inventory) do
            if type(weapon_data) == "table" and weapon_data.Name then
                owned[weapon_data.Name] = true
            end
        end
    end
    return owned
end

local function GetAllWeaponNames()
    local list = {}
    local seen = {}

    local ok, ownables = pcall(function()
        return modules.ShopLibrary:GetReleasedOwnableWeapons()
    end)
    if ok and type(ownables) == "table" then
        for _, name in pairs(ownables) do
            if type(name) == "string" and not seen[name] then
                seen[name] = true
                table.insert(list, name)
            end
        end
    end

    if modules.ItemLibrary and type(modules.ItemLibrary.Items) == "table" then
        for name in pairs(modules.ItemLibrary.Items) do
            if type(name) == "string" and not seen[name] then
                seen[name] = true
                table.insert(list, name)
            end
        end
    end

    table.sort(list)
    return list
end

--=============================================================================
-- 9. Unlock / Lock 動作
--=============================================================================

local function SetOwned(list, owned)
    local count = 0

    for _, cosmetic in ipairs(list) do
        if not cosmetic:find("MISSING_") then
            if owned then
                -- 本來就有的不要動，這樣之後 Lock 才知道哪些是假的
                if not state.fake_owned[cosmetic] then
                    state.fake_owned[cosmetic] = true
                    state.injected[cosmetic] = true
                    count += 1
                end
            elseif state.injected[cosmetic] then
                state.fake_owned[cosmetic] = nil
                state.injected[cosmetic] = nil
                count += 1
            end
        end
    end

    return count
end

local function UnlockRarity(rarity, owned)
    return SetOwned(GetCosmeticsByRarity(rarity), owned)
end

local function UnlockType(type_name, owned)
    return SetOwned(GetCosmeticsByType(type_name), owned)
end

local function UnlockAllForWeapon(weapon_name, owned)
    if weapon_name == "" then return 0 end
    return SetOwned(GetAllCosmeticsOfWeapon(weapon_name), owned)
end

local function UnlockAllCosmetics(owned)
    return SetOwned(GetAllCosmetics(), owned)
end

local function UnlockSpecific(type_name, cosmetic_name, weapon_name, owned)
    if cosmetic_name == "" then return false end

    local cosmetic = GetSpecificCosmetic(type_name, cosmetic_name, weapon_name)
    if not cosmetic or cosmetic:find("MISSING_") then return false end

    -- 回傳「有沒有找到」以及「狀態有沒有真的改變」
    return true, SetOwned({ cosmetic }, owned) > 0
end

local function UnlockWeapon(weapon_name)
    if weapon_name == "" then return false end

    for _, weapon in ipairs(state.fake_weapon_owned) do
        if weapon.Name == weapon_name then return false end
    end

    if GetOwnedWeaponNames()[weapon_name] then return false end

    table.insert(state.fake_weapon_owned, {
        Name = weapon_name,
        Level = 1,
        XP = 0,
        IsFavorited = false,
        Skin = nil,
    })
    return true
end

local function LockWeapon(weapon_name)
    for i, weapon in ipairs(state.fake_weapon_owned) do
        if weapon.Name == weapon_name then
            table.remove(state.fake_weapon_owned, i)
            return true
        end
    end
    return false
end

local function UnlockAllWeapons()
    local owned = GetOwnedWeaponNames()
    local count = 0

    for _, weapon_name in ipairs(GetAllWeaponNames()) do
        if not owned[weapon_name] then
            if UnlockWeapon(weapon_name) then count += 1 end
        end
    end

    return count
end

local function LockAllWeapons()
    local count = #state.fake_weapon_owned
    table.clear(state.fake_weapon_owned)
    return count
end

--=============================================================================
-- 10. Equip 動作
--=============================================================================

local function GetEquipRemote()
    local remotes = services.ReplicatedStorage:FindFirstChild("Remotes")
    local data = remotes and remotes:FindFirstChild("Data")
    return data and data:FindFirstChild("EquipCosmetic")
end

-- 走遊戲原本的 remote，上面的 __namecall hook 會把它接住轉成本地裝備。
-- 這樣不管是這個 UI 按的，還是你在遊戲自己的背包點的，走的都是同一條路。
local function EquipApply(weapon_name, cosmetic_type, cosmetic_name, is_inverted, favorites_only)
    if typeof(weapon_name) ~= "string" or weapon_name == "" then
        return false, "沒有選武器"
    end

    local remote = GetEquipRemote()
    if not remote then
        return false, "找不到 EquipCosmetic remote"
    end

    local name_to_send = (cosmetic_name ~= nil and cosmetic_name ~= "") and cosmetic_name or nil

    local options = {}
    if cosmetic_type == "Wrap" then
        options.IsInverted = is_inverted or nil
    end
    if favorites_only then
        options.OnlyUseFavorites = true
    end

    remote:FireServer(weapon_name, cosmetic_type, name_to_send, options)
    return true
end

local function EquipApplyAll(cosmetic_type, cosmetic_name, is_inverted, favorites_only)
    -- 皮膚是綁武器的，套到全部武器沒有意義
    if cosmetic_type == "Skin" then
        return false, "皮膚綁定單一武器，不能套用到全部"
    end

    if not modules.ItemLibrary or type(modules.ItemLibrary.Items) ~= "table" then
        return false, "ItemLibrary 不可用"
    end

    local count = 0
    for weapon_name, weapon_data in pairs(modules.ItemLibrary.Items) do
        if typeof(weapon_name) == "string" and weapon_name ~= "" and type(weapon_data) == "table" then
            -- 終結技只有能擊殺的武器才有
            if not (cosmetic_type == "Finisher" and not weapon_data.CanEliminate) then
                if EquipApply(weapon_name, cosmetic_type, cosmetic_name, is_inverted, favorites_only) then
                    count += 1
                end
            end
        end
    end

    return true, count
end

--=============================================================================
-- 11. 視覺套用 hook
--    上面存進 state.equipped 的東西，靠下面這幾個 hook 才會真的畫出來
--=============================================================================

-- 背包 / 商店裡的武器預覽圖
do
    local IL = modules.ItemLibrary
    if IL and type(IL.GetViewModelImageFromWeaponData) == "function" then
        originals.GetViewModelImage = IL.GetViewModelImageFromWeaponData

        IL.GetViewModelImageFromWeaponData = function(self, weapon_data, high_res)
            if state.unloaded or not weapon_data then
                return originals.GetViewModelImage(self, weapon_data, high_res)
            end

            local weapon_name = weapon_data.Name
            local skin = state.equipped[weapon_name] and ResolveCosmetic(weapon_name, "Skin")

            if skin then
                local matches_equipped = weapon_data.Skin == skin
                local viewing_self = state.viewing_profile == LocalPlayer

                if matches_equipped or viewing_self then
                    local skin_info = self.ViewModels and self.ViewModels[skin.Name]
                    if skin_info then
                        return skin_info[high_res and "ImageHighResolution" or "Image"] or skin_info.Image
                    end
                end
            end

            return originals.GetViewModelImage(self, weapon_data, high_res)
        end
    end
end

task.spawn(function()
    task.wait(3)

    -- 第一人稱手上那把槍的皮膚
    pcall(function()
        local client_item_path = PSModules.ClientReplicatedClasses.ClientFighter.ClientItem
        local ClientItem = require(client_item_path)
        if not ClientItem._CreateViewModel then return end

        local orig = ClientItem._CreateViewModel
        ClientItem._CreateViewModel = function(self, viewmodel_ref)
            local weapon_name = self.Name
            local weapon_player = self.ClientFighter and self.ClientFighter.Player

            state.constructing_weapon = (weapon_player == LocalPlayer) and weapon_name or nil

            local skin = (not state.unloaded)
                and weapon_player == LocalPlayer
                and state.equipped[weapon_name]
                and ResolveCosmetic(weapon_name, "Skin")

            if skin and viewmodel_ref then
                pcall(function()
                    local data_key = self:ToEnum("Data")
                    local skin_key = self:ToEnum("Skin")
                    local name_key = self:ToEnum("Name")

                    if viewmodel_ref[data_key] then
                        viewmodel_ref[data_key][skin_key] = skin
                        viewmodel_ref[data_key][name_key] = skin.Name
                    elseif viewmodel_ref.Data then
                        viewmodel_ref.Data.Skin = skin
                        viewmodel_ref.Data.Name = skin.Name
                    end
                end)
            end

            local result = orig(self, viewmodel_ref)
            state.constructing_weapon = nil
            return result
        end
    end)

    -- 包裝 (Wrap) 與吊飾 (Charm)
    pcall(function()
        local vm_module = PSModules.ClientReplicatedClasses.ClientFighter.ClientItem
            :FindFirstChild("ClientViewModel")
        if not vm_module then return end

        local ClientViewModel = require(vm_module)

        if ClientViewModel.GetWrap then
            local orig = ClientViewModel.GetWrap
            ClientViewModel.GetWrap = function(self)
                if not state.unloaded then
                    local item = self.ClientItem
                    local weapon_name = item and item.Name
                    local weapon_player = item and item.ClientFighter and item.ClientFighter.Player

                    if weapon_name and weapon_player == LocalPlayer and state.equipped[weapon_name] then
                        local wrap = ResolveCosmetic(weapon_name, "Wrap")
                        if wrap then return wrap end
                    end
                end
                return orig(self)
            end
        end

        local orig_new = ClientViewModel.new
        ClientViewModel.new = function(replicated_data, client_item)
            local weapon_player = client_item.ClientFighter and client_item.ClientFighter.Player
            local weapon_name = state.constructing_weapon or client_item.Name

            local mine = (not state.unloaded)
                and weapon_player == LocalPlayer
                and state.equipped[weapon_name] ~= nil

            if mine then
                pcall(function()
                    local ReplicatedClass = modules.ReplicatedClass
                        or require(services.ReplicatedStorage.Modules.ReplicatedClass)
                    local data_key = ReplicatedClass:ToEnum("Data")
                    replicated_data[data_key] = replicated_data[data_key] or {}

                    for _, cos_type in ipairs({ "Skin", "Wrap", "Charm" }) do
                        local resolved = ResolveCosmetic(weapon_name, cos_type)
                        if resolved then
                            replicated_data[data_key][ReplicatedClass:ToEnum(cos_type)] = resolved
                        end
                    end
                end)
            end

            local result = orig_new(replicated_data, client_item)

            -- 記下 ObjectID → 武器名，丟出去的物件（例如手榴彈）之後要靠這個查包裝
            pcall(function()
                if not mine then return end

                local object_id
                pcall(function()
                    local ReplicatedClass = modules.ReplicatedClass
                        or require(services.ReplicatedStorage.Modules.ReplicatedClass)
                    local data_key = ReplicatedClass:ToEnum("Data")
                    local obj_key = ReplicatedClass:ToEnum("ObjectID")
                    if replicated_data[data_key] then
                        object_id = replicated_data[data_key][obj_key]
                    end
                end)

                if object_id == nil then
                    pcall(function() object_id = result:Get("ObjectID") or result.ObjectID end)
                end

                if object_id then
                    state.placed_object_map[object_id] = weapon_name
                end
            end)

            if mine and ResolveCosmetic(weapon_name, "Wrap") and result._UpdateWrap then
                task.spawn(function()
                    result:_UpdateWrap()
                    task.wait(0.1)
                    if not result._destroyed then result:_UpdateWrap() end
                end)
            end

            return result
        end
    end)

    -- 看自己的個人檔案時也要顯示假皮膚
    pcall(function()
        local ViewProfile = require(PSModules.Pages.ViewProfile)
        if not ViewProfile or not ViewProfile.Fetch then return end

        local orig = ViewProfile.Fetch
        ViewProfile.Fetch = function(self, target_player)
            state.viewing_profile = target_player
            return orig(self, target_player)
        end
    end)

    -- 終結技 (Finisher)
    pcall(function()
        local ClientEntity = require(PSModules.ClientReplicatedClasses.ClientEntity)
        if not ClientEntity or not ClientEntity.ReplicateFromServer then return end

        local orig = ClientEntity.ReplicateFromServer

        local function DecodeKillerArg(value)
            if value == nil then return nil end

            if typeof(value) == "Instance" then
                return value:IsA("Player") and value.Name or nil
            end

            if type(value) == "number" then
                return value == LocalPlayer.UserId and LocalPlayer.Name or nil
            end

            if type(value) == "string" then
                return value
            end

            if type(value) == "userdata" and modules.EnumLibrary and modules.EnumLibrary.FromEnum then
                local ok, decoded = pcall(function() return modules.EnumLibrary:FromEnum(value) end)
                if ok and decoded ~= nil then return tostring(decoded) end
            end

            return tostring(value)
        end

        local function IsLocalPlayerKiller(args)
            local decoded = DecodeKillerArg(args[3])
            return decoded ~= nil and decoded:lower() == LocalPlayer.Name:lower()
        end

        local function ResolveFinisherWeapon()
            local primary = state.last_used_weapon
            if primary and state.equipped[primary] and ResolveCosmetic(primary, "Finisher") then
                return primary
            end

            for weapon_name in pairs(state.equipped) do
                if ResolveCosmetic(weapon_name, "Finisher") then
                    return weapon_name
                end
            end

            return nil
        end

        local function ResolveFinisherEnum(finisher_data)
            if not finisher_data then return nil end
            if finisher_data.Enum ~= nil then return finisher_data.Enum end

            if modules.EnumLibrary and modules.EnumLibrary.ToEnum then
                local ok, result = pcall(function()
                    return modules.EnumLibrary:ToEnum(finisher_data.Name)
                end)
                if ok and result ~= nil then
                    finisher_data.Enum = result
                    return result
                end
            end

            if finisher_data.ObjectID ~= nil then
                finisher_data.Enum = finisher_data.ObjectID
                return finisher_data.ObjectID
            end

            return nil
        end

        ClientEntity.ReplicateFromServer = function(self, action, ...)
            if state.unloaded or action ~= "FinisherEffect" then
                return orig(self, action, ...)
            end

            local args = { ... }

            if not IsLocalPlayerKiller(args) then
                return orig(self, action, ...)
            end

            local weapon_name = ResolveFinisherWeapon()
            if not weapon_name then
                return orig(self, action, ...)
            end

            local finisher_data = ResolveCosmetic(weapon_name, "Finisher")
            local finisher_enum = ResolveFinisherEnum(finisher_data)
            if finisher_enum == nil then
                return orig(self, action, ...)
            end

            if not self:IsRendered() then return end

            local ok, decoded = pcall(function() return self:FromEnum(finisher_enum) end)
            if not ok or decoded == nil then
                decoded = finisher_data.Name
            end
            if decoded == nil then
                return orig(self, action, ...)
            end

            pcall(function()
                self:_PlayFinisher(decoded, args[2], args[3], args[4])
            end)
        end
    end)

    -- 已經丟到地上的東西（手榴彈之類）的包裝
    pcall(function()
        if not modules.FighterController or not modules.FighterController.GetWrap then return end

        local orig = modules.FighterController.GetWrap
        modules.FighterController.GetWrap = function(self, object_id)
            local result = orig(self, object_id)
            if result or state.unloaded then return result end

            if object_id then
                local weapon_name = state.placed_object_map[object_id]
                if weapon_name and state.equipped[weapon_name] then
                    return ResolveCosmetic(weapon_name, "Wrap")
                end
            end

            return nil
        end
    end)

    -- 彈跳板皮膚
    pcall(function()
        local JumpPads = require(PSModules.GameComponents.JumpPads)
        if not JumpPads or not JumpPads.CreateJumpPadVisual then return end

        local orig = JumpPads.CreateJumpPadVisual
        JumpPads.CreateJumpPadVisual = function(self, name, size)
            if not state.unloaded and state.equipped["Jump Pad"] then
                pcall(function()
                    local skin = ResolveCosmetic("Jump Pad", "Skin")
                    if skin and skin.Name then
                        name = skin.Name
                    end
                end)
            end
            return orig(self, name, size)
        end
    end)
end)

--=============================================================================
-- 12. 清單建構（給下拉選單用）
--=============================================================================

-- 遊戲裡的外觀有好幾千個，全部塞進下拉選單會直接卡死，
-- 所以一律先用「類型 + 武器 + 關鍵字」篩過，再截斷到這個上限。
local MAX_DROPDOWN_ENTRIES = 150

local function BuildCosmeticValues(type_name, weapon_name, filter, include_special)
    local matches = {}
    filter = string.lower(filter or "")

    for name, cosmetic in pairs(modules.CosmeticLibrary.Cosmetics) do
        if cosmetic.Type == type_name and not name:find("MISSING_") then
            local weapon_ok = (type_name ~= "Skin")
                or weapon_name == ""
                or weapon_name == nil
                or cosmetic.ItemName == weapon_name

            if weapon_ok and (filter == "" or string.find(string.lower(name), filter, 1, true)) then
                table.insert(matches, name)
            end
        end
    end

    table.sort(matches)

    local values = {}
    if include_special then
        table.insert(values, "None")
        table.insert(values, "Random")
    end

    for i = 1, math.min(#matches, MAX_DROPDOWN_ENTRIES) do
        table.insert(values, matches[i])
    end

    return values, #matches
end

local weapon_values = GetAllWeaponNames()
if #weapon_values == 0 then
    weapon_values = { "Assault Rifle" }
end

--=============================================================================
-- 13. 語言 (i18n)
--
--    做法：函式庫裡每一個文字元件最後都會走到 Library:CreateLabel / Library:Create，
--    所以在建 UI 之前先把這兩個函式包起來，把「元件 + 當初寫進去的字串」記下來。
--    切語言時就照著這份清單原地改 .Text，不用重建整個 UI，狀態也不會掉。
--=============================================================================

local LANG_FILE = "RivalsSkinChanger/lang.txt"

local i18n = {
    lang = "zh",
    tracked = {},  -- { inst, prop, key, last }
    buttons = {},  -- Button 物件另外記，DoubleClick 會用 Button.Text 還原文字
    capture = false,
}

-- 先宣告，實際的函式在 UI 建完之後才指定（要等 InfoLabel 之類的元件都存在）。
-- 因為是同一個 local 變數，下面的按鈕 callback 現在就能直接參照它。
local SetLanguage

-- 每一列是 { 中文, English }。兩個方向都會註冊進查表，
-- 所以不管原始碼裡寫的是中文（我們自己的 UI）還是英文（SaveManager /
-- ThemeManager 那些 addon），查得到就換得掉。
local TRANSLATION_PAIRS = {
    -- 分頁
    { "解鎖",         "Unlocker" },
    { "裝備",         "Equip" },
    { "設定",         "Settings" },

    -- 群組標題
    { "一鍵解鎖",     "Quick Unlock" },
    { "批次解鎖",     "Batch Unlock" },
    { "指定項目",     "Specific" },
    { "狀態",         "Status" },
    { "裝備外觀",     "Equip Cosmetic" },
    { "目前本地裝備", "Local Loadout" },
    { "選單",         "Menu" },
    { "說明",         "About" },
    { "作者",         "Credits" },

    -- 按鈕
    { "解鎖全部（外觀 + 武器）",     "Unlock Everything" },
    { "全部鎖回去",                  "Lock Everything" },
    { "解鎖全部外觀",                "Unlock All Cosmetics" },
    { "鎖回全部外觀",                "Lock All Cosmetics" },
    { "解鎖全部武器",                "Unlock All Weapons" },
    { "鎖回全部武器",                "Lock All Weapons" },
    { "解鎖此類型全部",              "Unlock All of Type" },
    { "鎖回此類型",                  "Lock All of Type" },
    { "解鎖此稀有度全部",            "Unlock Selected Rarity" },
    { "鎖回此稀有度",                "Lock Selected Rarity" },
    { "解鎖選取的外觀",              "Unlock Selected" },
    { "鎖回",                        "Lock" },
    { "解鎖這把武器",                "Unlock This Weapon" },
    { "鎖回這把武器",                "Lock This Weapon" },
    { "解鎖這把武器的所有外觀",      "Unlock All for Weapon" },
    { "套用",                        "Apply" },
    { "套用到所有武器",              "Apply to All Weapons" },
    { "卸下這把武器的這個欄位",      "Unequip This Slot" },
    { "全部清空",                    "Clear All" },
    { "卸載腳本",                    "Unload Script" },

    -- 開關
    { "腳本載入時自動全解鎖",   "Auto unlock on load" },
    { "攔截裝備請求（本地套用）", "Intercept equip (client-side)" },
    { "包裝反轉 (Inverted)",     "Inverted wrap" },
    { "Random 只從最愛裡挑",     "Random uses favorites only" },
    { "顯示浮水印",              "Show watermark" },

    -- 下拉選單 / 輸入框
    { "類型",           "Type" },
    { "稀有度",         "Rarity" },
    { "武器",           "Weapon" },
    { "搜尋",           "Search" },
    { "外觀",           "Cosmetic" },
    { "開關選單",       "Menu toggle" },
    { "選單快捷鍵",     "Menu keybind" },
    { "關鍵字後按 Enter", "keyword, then Enter" },

    -- 提示 (tooltip)
    { "全皮膚、全包裝、全吊飾、全終結技，外加所有可擁有的武器",
      "Every skin, wrap, charm and finisher, plus all ownable weapons" },
    { "只會移除本腳本加上去的，你真正擁有的東西不會被動到（要點兩下）",
      "Only removes what this script added; real ownership is untouched (double-click)" },
    { "配合 Settings 分頁的 autoload 設定檔，下次執行就會自動解鎖",
      "Pair with an autoload config so the next run unlocks by itself" },
    { "皮膚會依這把武器過濾；包裝 / 吊飾 / 終結技是通用的",
      "Skins are filtered by this weapon; wraps / charms / finishers are universal" },
    { "關掉的話裝備會照常送去伺服器，沒真的擁有就會被打回來",
      "Turn off and equips go to the server, which rejects anything you don't own" },
    { "None = 卸下，Random = 每次生成隨機挑一個",
      "None = unequip, Random = re-rolls every time the weapon spawns" },
    { "還原所有 hook 並關閉 UI（要點兩下）",
      "Restore every hook and close the UI (double-click)" },

    -- 說明文字
    { "解鎖與裝備都只存在你自己的客戶端，伺服器看不到，也不會存檔。\n重新進遊戲要再跑一次腳本。\n\n外觀沒出現的話：切換一次武器讓 ViewModel 重建。",
      "Unlocks and equips exist only on your client. The server never sees them and nothing is saved.\nRe-run the script after rejoining.\n\nCosmetic not showing? Switch weapons once to rebuild the ViewModel." },

    -- 動態文字
    { "讀取中...",   "Loading..." },
    { "（空）",      "(empty)" },
    { "清單：--",    "List: --" },
    { "清單：%d 個", "List: %d" },
    { "清單：顯示 %d / 符合 %d（用搜尋縮小範圍）",
      "List: showing %d of %d (use search to narrow)" },
    { "...還有 %d 把", "...and %d more" },
    { "本腳本解鎖：%d 個外觀 · %d 把武器\n背包外觀總數：%d\n本地裝備：%d 把武器\nEquip 攔截：%s",
      "Unlocked by script: %d cosmetics, %d weapons\nCosmetics in inventory: %d\nLocal loadout: %d weapons\nEquip intercept: %s" },
    { "開啟", "on" },
    { "關閉", "off" },

    -- 通知
    { "解鎖完成：%d 個外觀、%d 把武器", "Unlocked %d cosmetics and %d weapons" },
    { "已移除：%d 個外觀、%d 把武器",   "Removed %d cosmetics and %d weapons" },
    { "自動解鎖：%d 個外觀、%d 把武器", "Auto-unlocked %d cosmetics and %d weapons" },
    { "解鎖了 %d 個外觀",  "Unlocked %d cosmetics" },
    { "移除了 %d 個外觀",  "Removed %d cosmetics" },
    { "解鎖了 %d 把武器",  "Unlocked %d weapons" },
    { "移除了 %d 把武器",  "Removed %d weapons" },
    { "%s：解鎖 %d 個",    "%s: unlocked %d" },
    { "%s：移除 %d 個",    "%s: removed %d" },
    { "%s：解鎖 %d 個外觀", "%s: unlocked %d cosmetics" },
    { "%s：移除 %d 個外觀", "%s: removed %d cosmetics" },
    { "找不到這個外觀",     "No such cosmetic" },
    { "已解鎖 %s",          "Unlocked %s" },
    { "已移除 %s",          "Removed %s" },
    { "你本來就有 %s",      "You already own %s" },
    { "這個不是假的，沒有動它", "That one is real, left untouched" },
    { "你本來就有這把，或名稱無效", "You already own it, or the name is invalid" },
    { "這把不是假的",       "That weapon is real, left untouched" },
    { "已套用到 %s",        "Applied to %s" },
    { "已套用到 %d 把武器", "Applied to %d weapons" },
    { "%s 的 %s 已卸下",    "Unequipped %s on %s" },
    { "失敗：%s",           "Failed: %s" },
    { "沒有選武器",         "No weapon selected" },
    { "找不到 EquipCosmetic remote", "EquipCosmetic remote not found" },
    { "ItemLibrary 不可用",  "ItemLibrary unavailable" },
    { "皮膚綁定單一武器，不能套用到全部",
      "Skins are bound to one weapon and cannot be applied to all" },
    { "本地裝備已清空，重生一次就會恢復原樣",
      "Local loadout cleared; respawn to see the originals" },
    { "Rivals Skin Changer 載入完成 · 按 End 開關選單",
      "Rivals Skin Changer loaded - press End to toggle the menu" },

    -- SaveManager / ThemeManager（原始碼是英文，這裡補中文）
    { "設定檔",         "Configuration" },
    { "設定檔名稱",     "Config name" },
    { "設定檔清單",     "Config list" },
    { "建立設定檔",     "Create config" },
    { "覆蓋設定檔",     "Overwrite config" },
    { "載入設定檔",     "Load config" },
    { "重新整理清單",   "Refresh list" },
    { "設為自動載入",   "Set as autoload" },
    { "主題",           "Themes" },
    { "背景色",         "Background color" },
    { "主色",           "Main color" },
    { "強調色",         "Accent color" },
    { "外框色",         "Outline color" },
    { "文字色",         "Font color" },
    { "主題清單",       "Theme list" },
    { "設為預設",       "Set as default" },
    { "自訂主題名稱",   "Custom theme name" },
    { "自訂主題",       "Custom themes" },
    { "儲存主題",       "Save theme" },
}

local TR = {}
for _, pair in ipairs(TRANSLATION_PAIRS) do
    local entry = { zh = pair[1], en = pair[2] }
    TR[pair[1]] = entry
    TR[pair[2]] = entry
end

-- 查不到就原字回傳，所以遊戲資料（武器名、外觀名）不會被亂翻
local function T(source)
    local entry = TR[source]
    if not entry then return source end
    return entry[i18n.lang] or source
end

-- 建 UI 期間攔截文字元件的建立，把它們記下來。
-- 呼叫端傳進來的已經是 T() 翻好的字串（這樣函式庫算文字寬度才會算對），
-- 這裡只負責登記；因為查表是雙向的，記中文或英文都查得回同一筆。
do
    local orig_create_label = Library.CreateLabel
    Library.CreateLabel = function(self, properties, is_hud)
        local inst = orig_create_label(self, properties, is_hud)

        if i18n.capture and type(properties) == "table" and type(properties.Text) == "string" then
            table.insert(i18n.tracked, {
                inst = inst,
                prop = "Text",
                key  = properties.Text,
                last = properties.Text,
            })
        end

        return inst
    end

    local orig_create = Library.Create
    Library.Create = function(self, class, properties)
        local inst = orig_create(self, class, properties)

        if i18n.capture and type(properties) == "table"
            and type(properties.PlaceholderText) == "string"
            and properties.PlaceholderText ~= "" then

            table.insert(i18n.tracked, {
                inst = inst,
                prop = "PlaceholderText",
                key  = properties.PlaceholderText,
                last = properties.PlaceholderText,
            })
        end

        return inst
    end

    -- 提示框的大小是照文字算出來的，換語言後要重算，所以要認得出哪些是提示框
    local orig_tooltip = Library.AddToolTip
    Library.AddToolTip = function(self, info, hover)
        local before = #i18n.tracked
        local result = orig_tooltip(self, info, hover)

        for i = before + 1, #i18n.tracked do
            i18n.tracked[i].tooltip = true
        end

        return result
    end
end

-- 建立按鈕並登記。DoubleClick 還原文字時讀的是 Button.Text，那個欄位也要換。
local function AddBtn(target, options)
    local button = target:AddButton(options)
    table.insert(i18n.buttons, { button = button, key = options.Text })
    return button
end

local function ReadSavedLanguage()
    if type(isfile) ~= "function" or type(readfile) ~= "function" then return nil end

    local ok, exists = pcall(isfile, LANG_FILE)
    if not ok or not exists then return nil end

    local ok2, content = pcall(readfile, LANG_FILE)
    if not ok2 or type(content) ~= "string" then return nil end

    content = content:gsub("%s", "")
    return (content == "en" or content == "zh") and content or nil
end

local function SaveLanguage()
    if type(writefile) ~= "function" then return end

    pcall(function()
        if type(makefolder) == "function" and type(isfolder) == "function"
            and not isfolder("RivalsSkinChanger") then
            makefolder("RivalsSkinChanger")
        end
        writefile(LANG_FILE, i18n.lang)
    end)
end

i18n.lang = ReadSavedLanguage() or "zh"
i18n.capture = true

--=============================================================================
-- 14. UI
--=============================================================================

local INFO_SOURCE = "解鎖與裝備都只存在你自己的客戶端，伺服器看不到，也不會存檔。\n重新進遊戲要再跑一次腳本。\n\n外觀沒出現的話：切換一次武器讓 ViewModel 重建。"
local STATUS_SOURCE = "本腳本解鎖：%d 個外觀 · %d 把武器\n背包外觀總數：%d\n本地裝備：%d 把武器\nEquip 攔截：%s"
local CREDITS_TEXT = "asphy¢ 、your dad:smallhuang\n\nEEZ rebuild"

local Window = Library:CreateWindow({
    Title = "Rivals · Skin Changer",
    Center = true,
    AutoShow = true,
    TabPadding = 8,
    MenuFadeTime = 0.2,
    Resizable = true,
    Size = UDim2.fromOffset(620, 620),
})

-- 分頁按鈕的寬度是照文字算的，換語言要連按鈕框一起 resize，
-- 所以包一層記下「這個 label 的 parent 是哪個分頁按鈕」。
do
    local orig_add_tab = Window.AddTab
    Window.AddTab = function(self, name)
        local before = #i18n.tracked
        local tab = orig_add_tab(self, name)

        for i = before + 1, #i18n.tracked do
            i18n.tracked[i].tab_button = true
        end

        return tab
    end
end

local Tabs = {
    Unlocker = Window:AddTab(T("Unlocker")),
    Equip    = Window:AddTab(T("Equip")),
    Settings = Window:AddTab(T("Settings")),
}

--------------------------------------------------------------------------- 一鍵
local QuickBox = Tabs.Unlocker:AddLeftGroupbox(T("一鍵解鎖"))

AddBtn(AddBtn(QuickBox, {
    Text = T("解鎖全部（外觀 + 武器）"),
    Tooltip = T("全皮膚、全包裝、全吊飾、全終結技，外加所有可擁有的武器"),
    Func = function()
        local cosmetics = UnlockAllCosmetics(true)
        local weapons = UnlockAllWeapons()
        Library:Notify(T("解鎖完成：%d 個外觀、%d 把武器"):format(cosmetics, weapons), 5)
    end,
}), {
    Text = T("全部鎖回去"),
    DoubleClick = true,
    Tooltip = T("只會移除本腳本加上去的，你真正擁有的東西不會被動到（要點兩下）"),
    Func = function()
        local cosmetics = UnlockAllCosmetics(false)
        local weapons = LockAllWeapons()
        Library:Notify(T("已移除：%d 個外觀、%d 把武器"):format(cosmetics, weapons), 5)
    end,
})

QuickBox:AddDivider()

AddBtn(AddBtn(QuickBox, {
    Text = T("解鎖全部外觀"),
    Func = function()
        Library:Notify(T("解鎖了 %d 個外觀"):format(UnlockAllCosmetics(true)), 5)
    end,
}), {
    Text = T("鎖回全部外觀"),
    DoubleClick = true,
    Func = function()
        Library:Notify(T("移除了 %d 個外觀"):format(UnlockAllCosmetics(false)), 5)
    end,
})

AddBtn(AddBtn(QuickBox, {
    Text = T("解鎖全部武器"),
    Func = function()
        Library:Notify(T("解鎖了 %d 把武器"):format(UnlockAllWeapons()), 5)
    end,
}), {
    Text = T("鎖回全部武器"),
    DoubleClick = true,
    Func = function()
        Library:Notify(T("移除了 %d 把武器"):format(LockAllWeapons()), 5)
    end,
})

QuickBox:AddDivider()

QuickBox:AddToggle("AutoUnlock", {
    Text = T("腳本載入時自動全解鎖"),
    Default = false,
    Tooltip = T("配合 Settings 分頁的 autoload 設定檔，下次執行就會自動解鎖"),
})

--------------------------------------------------------------- 依類型 / 稀有度
local BatchBox = Tabs.Unlocker:AddLeftGroupbox(T("批次解鎖"))

BatchBox:AddDropdown("UnlockTypeSel", {
    Text = T("類型"),
    Values = COSMETIC_TYPES,
    Default = 1,
})

AddBtn(AddBtn(BatchBox, {
    Text = T("解鎖此類型全部"),
    Func = function()
        local n = UnlockType(state.unlocker.type, true)
        Library:Notify(T("%s：解鎖 %d 個"):format(state.unlocker.type, n), 5)
    end,
}), {
    Text = T("鎖回此類型"),
    DoubleClick = true,
    Func = function()
        local n = UnlockType(state.unlocker.type, false)
        Library:Notify(T("%s：移除 %d 個"):format(state.unlocker.type, n), 5)
    end,
})

BatchBox:AddDropdown("UnlockRaritySel", {
    Text = T("稀有度"),
    Values = COSMETIC_RARITIES,
    Default = 1,
})

AddBtn(AddBtn(BatchBox, {
    Text = T("解鎖此稀有度全部"),
    Func = function()
        local n = UnlockRarity(state.unlocker.rarity, true)
        Library:Notify(T("%s：解鎖 %d 個"):format(state.unlocker.rarity, n), 5)
    end,
}), {
    Text = T("鎖回此稀有度"),
    DoubleClick = true,
    Func = function()
        local n = UnlockRarity(state.unlocker.rarity, false)
        Library:Notify(T("%s：移除 %d 個"):format(state.unlocker.rarity, n), 5)
    end,
})

--------------------------------------------------------------------- 指定項目
local SpecificBox = Tabs.Unlocker:AddRightGroupbox(T("指定項目"))

SpecificBox:AddDropdown("SpecWeapon", {
    Text = T("武器"),
    Values = weapon_values,
    Default = 1,
    Tooltip = T("皮膚會依這把武器過濾；包裝 / 吊飾 / 終結技是通用的"),
})

SpecificBox:AddInput("SpecSearch", {
    Text = T("搜尋"),
    Default = "",
    Finished = true, -- 每打一個字就重建 150 個按鈕會卡，改成按 Enter 才套用
    Placeholder = T("關鍵字後按 Enter"),
})

SpecificBox:AddDropdown("SpecCosmetic", {
    Text = T("外觀"),
    Values = { "" },
    Default = 1,
})

local SpecCountLabel = SpecificBox:AddLabel(T("清單：--"))

AddBtn(AddBtn(SpecificBox, {
    Text = T("解鎖選取的外觀"),
    Func = function()
        local found, changed = UnlockSpecific(
            state.unlocker.type, state.unlocker.cosmetic, state.unlocker.weapon, true)

        if not found then
            Library:Notify(T("找不到這個外觀"), 5)
        elseif changed then
            Library:Notify(T("已解鎖 %s"):format(state.unlocker.cosmetic), 5)
        else
            Library:Notify(T("你本來就有 %s"):format(state.unlocker.cosmetic), 5)
        end
    end,
}), {
    Text = T("鎖回"),
    Func = function()
        local found, changed = UnlockSpecific(
            state.unlocker.type, state.unlocker.cosmetic, state.unlocker.weapon, false)

        if not found then
            Library:Notify(T("找不到這個外觀"), 5)
        elseif changed then
            Library:Notify(T("已移除 %s"):format(state.unlocker.cosmetic), 5)
        else
            Library:Notify(T("這個不是假的，沒有動它"), 5)
        end
    end,
})

SpecificBox:AddDivider()

AddBtn(AddBtn(SpecificBox, {
    Text = T("解鎖這把武器"),
    Func = function()
        local ok = UnlockWeapon(state.unlocker.weapon)
        Library:Notify(ok and T("已解鎖 %s"):format(state.unlocker.weapon)
            or T("你本來就有這把，或名稱無效"), 5)
    end,
}), {
    Text = T("鎖回這把武器"),
    Func = function()
        local ok = LockWeapon(state.unlocker.weapon)
        Library:Notify(ok and T("已移除 %s"):format(state.unlocker.weapon)
            or T("這把不是假的"), 5)
    end,
})

AddBtn(AddBtn(SpecificBox, {
    Text = T("解鎖這把武器的所有外觀"),
    Func = function()
        local n = UnlockAllForWeapon(state.unlocker.weapon, true)
        Library:Notify(T("%s：解鎖 %d 個外觀"):format(state.unlocker.weapon, n), 5)
    end,
}), {
    Text = T("鎖回"),
    DoubleClick = true,
    Func = function()
        local n = UnlockAllForWeapon(state.unlocker.weapon, false)
        Library:Notify(T("%s：移除 %d 個外觀"):format(state.unlocker.weapon, n), 5)
    end,
})

------------------------------------------------------------------------- 狀態
local StatusBox = Tabs.Unlocker:AddRightGroupbox(T("狀態"))
local StatusLabel = StatusBox:AddLabel(T("讀取中..."), true)

--------------------------------------------------------------------- Equip 分頁
local EquipBox = Tabs.Equip:AddLeftGroupbox(T("裝備外觀"))

EquipBox:AddToggle("InterceptEquip", {
    Text = T("攔截裝備請求（本地套用）"),
    Default = true,
    Tooltip = T("關掉的話裝備會照常送去伺服器，沒真的擁有就會被打回來"),
})

EquipBox:AddDropdown("EquipTypeSel", {
    Text = T("類型"),
    Values = COSMETIC_TYPES,
    Default = 1,
})

EquipBox:AddDropdown("EquipWeapon", {
    Text = T("武器"),
    Values = weapon_values,
    Default = 1,
})

EquipBox:AddInput("EquipSearch", {
    Text = T("搜尋"),
    Default = "",
    Finished = true,
    Placeholder = T("關鍵字後按 Enter"),
})

EquipBox:AddDropdown("EquipCosmetic", {
    Text = T("外觀"),
    Values = { "None", "Random" },
    Default = 1,
    Tooltip = T("None = 卸下，Random = 每次生成隨機挑一個"),
})

local EquipCountLabel = EquipBox:AddLabel(T("清單：--"))

EquipBox:AddToggle("EquipInverted", {
    Text = T("包裝反轉 (Inverted)"),
    Default = false,
})

EquipBox:AddToggle("EquipFavoritesOnly", {
    Text = T("Random 只從最愛裡挑"),
    Default = false,
})

AddBtn(AddBtn(EquipBox, {
    Text = T("套用"),
    Func = function()
        local ok, err = EquipApply(
            state.equip.weapon,
            state.equip.type,
            state.equip.cosmetic,
            state.equip.inverted,
            state.equip.favorites_only
        )
        Library:Notify(ok and T("已套用到 %s"):format(state.equip.weapon)
            or T("失敗：%s"):format(tostring(err)), 5)
    end,
}), {
    Text = T("套用到所有武器"),
    Func = function()
        local ok, result = EquipApplyAll(
            state.equip.type,
            state.equip.cosmetic,
            state.equip.inverted,
            state.equip.favorites_only
        )
        Library:Notify(ok and T("已套用到 %d 把武器"):format(result)
            or T("失敗：%s"):format(tostring(result)), 5)
    end,
})

AddBtn(EquipBox, {
    Text = T("卸下這把武器的這個欄位"),
    Func = function()
        EquipApply(state.equip.weapon, state.equip.type, "None", false, false)
        Library:Notify(T("%s 的 %s 已卸下"):format(state.equip.weapon, state.equip.type), 5)
    end,
})

local EquippedBox = Tabs.Equip:AddRightGroupbox(T("目前本地裝備"))
local EquippedLabel = EquippedBox:AddLabel(T("（空）"), true)

AddBtn(EquippedBox, {
    Text = T("全部清空"),
    DoubleClick = true,
    Func = function()
        table.clear(state.equipped)
        Library:Notify(T("本地裝備已清空，重生一次就會恢復原樣"), 5)
    end,
})

--=============================================================================
-- 15. 清單刷新
--=============================================================================

local function ApplyDropdownValues(dropdown, values, fallback)
    if #values == 0 then
        values = { fallback }
    end

    dropdown:SetValues(values)

    if not table.find(values, dropdown.Value) then
        dropdown:SetValue(values[1])
    end

    dropdown:Display()
end

local function RefreshSpecCosmetics()
    local values, total = BuildCosmeticValues(
        state.unlocker.type,
        state.unlocker.weapon,
        state.unlocker.search,
        false
    )

    local shown = #values
    ApplyDropdownValues(Options.SpecCosmetic, values, "")

    SpecCountLabel:SetText(total > shown
        and T("清單：顯示 %d / 符合 %d（用搜尋縮小範圍）"):format(shown, total)
        or T("清單：%d 個"):format(total))
end

local function RefreshEquipCosmetics()
    local values, total = BuildCosmeticValues(
        state.equip.type,
        state.equip.weapon,
        state.equip.search,
        true -- 多塞 None / Random 兩個特殊選項
    )

    local shown = #values - 2
    ApplyDropdownValues(Options.EquipCosmetic, values, "None")

    EquipCountLabel:SetText(total > shown
        and T("清單：顯示 %d / 符合 %d（用搜尋縮小範圍）"):format(shown, total)
        or T("清單：%d 個"):format(total))
end

--=============================================================================
-- 16. UI 事件接線
--=============================================================================

state.unlocker.search = ""
state.equip.search = ""

Options.SpecWeapon:OnChanged(function()
    state.unlocker.weapon = Options.SpecWeapon.Value or ""
    RefreshSpecCosmetics()
end)

Options.SpecSearch:OnChanged(function()
    state.unlocker.search = Options.SpecSearch.Value or ""
    RefreshSpecCosmetics()
end)

Options.SpecCosmetic:OnChanged(function()
    state.unlocker.cosmetic = Options.SpecCosmetic.Value or ""
end)

Options.UnlockTypeSel:OnChanged(function()
    state.unlocker.type = Options.UnlockTypeSel.Value or "Skin"
    RefreshSpecCosmetics()
end)

Options.UnlockRaritySel:OnChanged(function()
    state.unlocker.rarity = Options.UnlockRaritySel.Value or "Common"
end)

Toggles.AutoUnlock:OnChanged(function()
    if Toggles.AutoUnlock.Value then
        local cosmetics = UnlockAllCosmetics(true)
        local weapons = UnlockAllWeapons()
        if cosmetics > 0 or weapons > 0 then
            Library:Notify(T("自動解鎖：%d 個外觀、%d 把武器"):format(cosmetics, weapons), 5)
        end
    end
end)

Toggles.InterceptEquip:OnChanged(function()
    state.intercept_equip = Toggles.InterceptEquip.Value
end)

Options.EquipWeapon:OnChanged(function()
    state.equip.weapon = Options.EquipWeapon.Value or ""
    RefreshEquipCosmetics()
end)

Options.EquipSearch:OnChanged(function()
    state.equip.search = Options.EquipSearch.Value or ""
    RefreshEquipCosmetics()
end)

Options.EquipCosmetic:OnChanged(function()
    state.equip.cosmetic = Options.EquipCosmetic.Value or ""
end)

Options.EquipTypeSel:OnChanged(function()
    state.equip.type = Options.EquipTypeSel.Value or "Skin"
    RefreshEquipCosmetics()
end)

Toggles.EquipInverted:OnChanged(function()
    state.equip.inverted = Toggles.EquipInverted.Value
end)

Toggles.EquipFavoritesOnly:OnChanged(function()
    state.equip.favorites_only = Toggles.EquipFavoritesOnly.Value
end)

--=============================================================================
-- 17. 狀態面板
--=============================================================================

local function CountKeys(t)
    local n = 0
    for _ in pairs(t) do n += 1 end
    return n
end

local function DescribeEquipped()
    local lines = {}

    for weapon_name, slots in pairs(state.equipped) do
        local parts = {}
        for cos_type, cos_data in pairs(slots) do
            if type(cos_data) == "table" and cos_data.Name and cos_data.Name ~= "NONE_COSMETIC" then
                table.insert(parts, ("%s=%s"):format(cos_type, cos_data.Name))
            end
        end
        if #parts > 0 then
            table.insert(lines, ("· %s → %s"):format(weapon_name, table.concat(parts, ", ")))
        end
    end

    table.sort(lines)

    if #lines == 0 then
        return T("（空）")
    end

    if #lines > 12 then
        local trimmed = table.move(lines, 1, 12, 1, {})
        table.insert(trimmed, T("...還有 %d 把"):format(#lines - 12))
        lines = trimmed
    end

    return table.concat(lines, "\n")
end

task.spawn(function()
    while not state.unloaded and not Library.Unloaded do
        pcall(function()
            StatusLabel:SetText(T(STATUS_SOURCE):format(
                CountKeys(state.injected),
                #state.fake_weapon_owned,
                CountKeys(state.fake_owned),
                CountKeys(state.equipped),
                state.intercept_equip and T("開啟") or T("關閉")
            ))

            EquippedLabel:SetText(DescribeEquipped())
        end)

        task.wait(1)
    end
end)

--=============================================================================
-- 18. Settings 分頁
--=============================================================================

local MenuBox = Tabs.Settings:AddLeftGroupbox(T("選單"))

local LanguageButton = MenuBox:AddButton({
    Text = "語言 / Language：中文",
    Func = function()
        SetLanguage(i18n.lang == "zh" and "en" or "zh")
    end,
})

MenuBox:AddDivider()

AddBtn(MenuBox, {
    Text = T("卸載腳本"),
    DoubleClick = true,
    Tooltip = T("還原所有 hook 並關閉 UI（要點兩下）"),
    Func = function()
        Library:Unload()
    end,
})

MenuBox:AddLabel(T("開關選單")):AddKeyPicker("MenuKeybind", {
    Default = "End",
    NoUI = true,
    Text = T("選單快捷鍵"),
})

Library.ToggleKeybind = Options.MenuKeybind

MenuBox:AddToggle("ShowWatermark", {
    Text = T("顯示浮水印"),
    Default = true,
})

Toggles.ShowWatermark:OnChanged(function()
    Library:SetWatermarkVisibility(Toggles.ShowWatermark.Value)
end)

Library:SetWatermark("Rivals · Skin Changer")

local InfoBox = Tabs.Settings:AddRightGroupbox(T("說明"))
local InfoLabel = InfoBox:AddLabel(T(INFO_SOURCE), true)

--=============================================================================
-- 19. 語言切換
--=============================================================================

function SetLanguage(lang)
    if lang ~= "zh" and lang ~= "en" then return end
    if i18n.lang == lang then return end

    i18n.lang = lang

    -- 一般靜態文字（標籤 / 按鈕 / 提示 / 佔位字），照建立時記下的清單原地改字
    for _, item in ipairs(i18n.tracked) do
        if item.inst and item.inst.Parent then
            local translated = T(item.key)
            item.last = translated
            item.inst[item.prop] = translated

            if item.tooltip then
                -- 提示框大小是照文字寬度算的，換字後要重算
                local x, y = Library:GetTextBounds(translated, Library.Font, 14)
                local tooltip_frame = item.inst.Parent
                if tooltip_frame then
                    tooltip_frame.Size = UDim2.fromOffset(x + 5, y + 4)
                end
            elseif item.tab_button then
                -- 分頁按鈕的寬度也是照文字算的
                local x = Library:GetTextBounds(translated, Library.Font, 16)
                local tab_frame = item.inst.Parent
                if tab_frame then
                    tab_frame.Size = UDim2.new(0, x + 8 + 4, 1, 0)
                end
            end
        end
    end

    for _, item in ipairs(i18n.buttons) do
        local translated = T(item.key)
        item.button.Text = translated
        if item.button.Label then
            item.button.Label.Text = translated
        end
    end

    -- 這幾個是動態內容（含 %d/%s，或被背景迴圈持續覆寫），
    -- 不能只靠上面那份清單，語言切換當下要手動重算一次
    pcall(function() InfoLabel:SetText(T(INFO_SOURCE)) end)
    pcall(RefreshSpecCosmetics)
    pcall(RefreshEquipCosmetics)
    pcall(function()
        StatusLabel:SetText(T(STATUS_SOURCE):format(
            CountKeys(state.injected),
            #state.fake_weapon_owned,
            CountKeys(state.fake_owned),
            CountKeys(state.equipped),
            state.intercept_equip and T("開啟") or T("關閉")
        ))
        EquippedLabel:SetText(DescribeEquipped())
    end)

    LanguageButton.Text = "語言 / Language：" .. (lang == "zh" and "中文" or "English")
    if LanguageButton.Label then
        LanguageButton.Label.Text = LanguageButton.Text
    end

    SaveLanguage()

    Library:Notify(lang == "zh" and "已切換為中文" or "Switched to English", 3)
end

-- UI 是照 i18n.lang 當下的語言建出來的（預設中文，或讀到存檔的語言），
-- 這裡不用再呼叫一次 SetLanguage，上面建 UI 時已經是對的語言了。

--=============================================================================
-- 20. 還原 hook
--=============================================================================

local unloading = false

local function TeardownHooks()
    pcall(function()
        local CL = modules.CosmeticLibrary
        for _, name in ipairs({
            "OwnsCosmeticNormally",
            "OwnsCosmeticUniversally",
            "OwnsCosmeticForSomething",
            "OwnsCosmeticForWeapon",
            "OwnsCosmetic",
        }) do
            if originals[name] then
                CL[name] = originals[name]
            end
        end
    end)

    pcall(function()
        if originals.Get then modules.PlayerDataController.Get = originals.Get end
        if originals.GetWeaponData then modules.PlayerDataController.GetWeaponData = originals.GetWeaponData end
    end)

    pcall(function()
        if originals.GetViewModelImage then
            modules.ItemLibrary.GetViewModelImageFromWeaponData = originals.GetViewModelImage
        end
    end)

    -- 只清掉自己塞進去的，玩家真正擁有的東西留著
    pcall(function()
        for name in pairs(state.injected) do
            state.fake_owned[name] = nil
        end
        table.clear(state.injected)
        table.clear(state.fake_weapon_owned)
        table.clear(state.equipped)
        table.clear(state.placed_object_map)
    end)
end

local function Unload()
    if unloading then return end
    unloading = true

    state.unloaded = true
    TeardownHooks()

    if genv.__RIVALS_SKINCHANGER then
        genv.__RIVALS_SKINCHANGER = nil
    end

    if not Library.Unloaded then
        Library.Unloaded = true
        pcall(function() Library:Unload() end)
    end
end

genv.__RIVALS_SKINCHANGER.Unload = Unload

Library:OnUnload(function()
    Library.Unloaded = true
    Unload()
end)

--=============================================================================
-- 21. 設定檔 / 主題
--=============================================================================

ThemeManager:SetLibrary(Library)
SaveManager:SetLibrary(Library)

SaveManager:IgnoreThemeSettings()
SaveManager:SetIgnoreIndexes({ "MenuKeybind", "SpecSearch", "EquipSearch", "SpecCosmetic", "EquipCosmetic" })

ThemeManager:SetFolder("RivalsSkinChanger")
SaveManager:SetFolder("RivalsSkinChanger/configs")

SaveManager:BuildConfigSection(Tabs.Settings)
ThemeManager:ApplyToTab(Tabs.Settings)

-- 擺在 Configuration 下面那塊空位，剛好卡進右下角
local CreditsBox = Tabs.Settings:AddRightGroupbox(T("作者"))
CreditsBox:AddLabel(CREDITS_TEXT, true)

pcall(function() SaveManager:LoadAutoloadConfig() end)

Library:Notify(T("Rivals Skin Changer 載入完成 · 按 End 開關選單"), 6)
