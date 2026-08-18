--[[
    AntiHook.luau · 執行前環境完整性檢查
    ---------------------------------------------------------------------------
    ⚠️ 先講清楚這份東西做得到什麼、做不到什麼：

    userland 的 Luau 程式碼終究是跑在執行器（executor）給的沙盒裡。如果有人想在
    「你的腳本開始執行之前」對執行環境動手腳，你的程式碼那個時間點根本還沒開始
    跑，沒有任何辦法可以阻止——這是整個外掛圈的共同物理限制，不是這份模組做得
    不夠好。

    這份模組做得到的是：**盡量把「已經動過手腳」的痕跡找出來**，越早跑（在你
    自己也開始 hook 任何東西之前）越準，抓到就配合 HWID 封鎖形成嚇阻、拉高
    盜源碼的成本。這是縱深防禦（obfuscation + 這份偵測 + 伺服器端封鎖）的其中
    一層，不是銀彈，請不要對它有「絕對防護」的期待。

    偵測手法：

    1. iscclosure 檢查（主力手法）
       執行器原生函式在沒被動過手腳的狀況下都是 C closure（用 iscclosure()
       測會回 true）。如果有第三方工具把 hookfunction / hookmetamethod /
       game 的 __namecall 等元方法從 C closure 換成 Lua closure，iscclosure()
       就抓得到。這是執行器圈公認的手法，UNC（Unified Naming Convention）
       測試套件本身也是用同一招在驗證執行器有沒有被動手腳。

    2. 已知「傾印工具」特徵掃描（輔助手法，需要你自己維護）
       檢查 getgenv() 底下有沒有已知傾印/爬源碼工具留下的全域變數旗標。
       下面清單只是範例，工具一直在變，抓不到新工具是預期中的事，不是 bug。
       想維持有效性，你要自己持續更新這份清單。

    3. 環境健全性檢查（低價值，純粹兜底）
       確認 debug 函式庫這種基本東西還在、型別正常。

    用法：

        local AntiHook = require(...) -- 或 loadstring(source)()
        local result = AntiHook.Scan()

        if not result.ok then
            -- result.reasons 是一份字串陣列，描述抓到了什麼
        end

    這份檔案本身沒有任何副作用（不會自己 return / kick / 呼叫任何網路請求），
    純粹只是掃描回報。要不要因為掃到痕跡就中止腳本、要不要通報伺服器封鎖，
    是呼叫端（SkinChanger.luau）的決定。SkinChanger.luau 裡面內嵌了一份幾乎
    一模一樣的邏輯（維持單檔可直接貼上執行），這份檔案是給你單獨檢視、
    也方便之後移植到其他腳本用。
    ---------------------------------------------------------------------------
]]

local AntiHook = {}

-- 這幾個是「被 hook 之後最有價值」的目標：拿到 hookfunction/hookmetamethod
-- 的人可以攔截任何東西；拿到 request 的人可以看到你所有的網路請求（含這份
-- 反 hook 模組自己要打的授權 API）；拿到 loadstring 的人可以在你的腳本被
-- 編譯前先看過原始碼。
local function CandidateGlobals()
    return {
        hookfunction       = hookfunction,
        hookmetamethod     = hookmetamethod,
        getrawmetatable    = getrawmetatable,
        setrawmetatable    = setrawmetatable,
        newcclosure        = newcclosure,
        checkcaller        = checkcaller,
        getnamecallmethod  = getnamecallmethod,
        loadstring         = loadstring,
        request            = (type(request) == "function" and request)
            or (type(http) == "table" and http.request),
        -- 注意：require 故意沒放進來。實測過 Real 執行器 + RIVALS 這個組合，
        -- 乾淨環境下 iscclosure(require) 本來就回傳 false（require 天生是
        -- Lua 實作，不是 C closure），放進來只會製造保證會觸發的假警報。
        -- 這是實測結果，不是猜測——想加回來之前，先在你自己的環境測過
        -- 乾淨基準值，不要直接信任何清單。
    }
end

-- 已知傾印/爬源碼工具在 getgenv() 留下的旗標。
-- ⚠️ 這只是範例，不保證涵蓋任何真實存在的工具，抓不到新工具是正常的。
-- 之後發現新的傾印工具特徵，自己加進這份清單就好，不用改其他地方。
local KNOWN_DUMPER_MARKERS = {
    "__DUMPER__",
    "___dump___",
    "SourceGrabber",
    "ScriptDumper",
}

--[[
    已知盲區 —— 這段不是理論推測，是實際拿 Real 執行器（連 RIVALS 這個
    遊戲一起測）跑出來的結果，測法是：

        local orig = loadstring
        hookfunction(loadstring, function(code, chunkname) return orig(code, chunkname) end)
        print(iscclosure(loadstring)) --> true（實測結果，不是假設）

        local orig2
        orig2 = hookmetamethod(game, "__namecall", function(self, ...) return orig2(self, ...) end)
        print(iscclosure(getrawmetatable(game).__namecall)) --> true（實測結果）

    兩個都印出 true。也就是說：Real 上用 hookfunction 或 hookmetamethod
    掛的 hook，iscclosure() 完全看不出來——不管掛的是 loadstring、
    __namecall、還是任何其他函式。這代表下面這整套 CheckCClosures 邏輯，
    對任何用「正規」方式（hookfunction / hookmetamethod）做的 hook 都是
    瞎的，只抓得到直接裸露覆蓋全域變數（不透過 hookfunction，例如
    `checkcaller = function(...) end`）這種懶得包裝的粗糙手法——這種
    確實測得出來，但任何有基本水準的 hook 工具都不會這樣寫，正是因為
    hookfunction 存在的意義就是拿來閃這種檢查的。

    debug.getinfo(loadstring).what 也試過，一樣回報 "C"，看不穿偽裝。

    結論：這份掃描對「認真做的 hook」沒有實際防護力，只對外行的粗糙手法
    有效。真正該花力氣的地方是把要發布的腳本用 Prometheus 之類的工具
    混淆過再上架——那個是無論 hook 偵不偵測得到都有效的防線，這份執行期
    檢查頂多算多一層嚇阻，不要當成主力防護在依賴。
]]
local function CheckCClosures(reasons)
    if type(iscclosure) ~= "function" then
        -- 這個執行器沒給 iscclosure，這項檢查直接跳過（不算失敗，只是做不了）
        return
    end

    for name, fn in pairs(CandidateGlobals()) do
        if type(fn) == "function" then
            local ok, is_native = pcall(iscclosure, fn)
            if ok and is_native == false then
                table.insert(reasons, ("全域函式 '%s' 已經不是原生 C 函式，疑似被 hook"):format(name))
            end
        end
    end

    -- game 的 __namecall / __index / __newindex 是最常被動手腳的地方
    -- （攔截 remote 呼叫、攔截屬性存取）。注意：這項檢查一定要在
    -- SkinChanger.luau 自己去 hook __namecall 之前跑，不然會把自己的
    -- hook 也算進去，變成自己抓自己。
    local ok, mt = pcall(getrawmetatable, game)
    if ok and type(mt) == "table" then
        for _, key in ipairs({ "__namecall", "__index", "__newindex" }) do
            local meta_fn = mt[key]
            if type(meta_fn) == "function" then
                local ok2, is_native = pcall(iscclosure, meta_fn)
                if ok2 and is_native == false then
                    table.insert(reasons, ("game 的 %s 元方法已經被換掉"):format(key))
                end
            end
        end
    end
end

local function CheckDumperMarkers(reasons)
    local ok, env = pcall(getgenv)
    if not ok or type(env) ~= "table" then return end

    for _, marker in ipairs(KNOWN_DUMPER_MARKERS) do
        if env[marker] ~= nil then
            table.insert(reasons, "偵測到已知傾印工具旗標：" .. marker)
        end
    end
end

local function CheckEnvironmentSanity(reasons)
    if type(debug) ~= "table" or type(debug.getinfo) ~= "function" then
        table.insert(reasons, "debug 函式庫不完整或被移除")
    end

    if type(pcall) ~= "function" or type(type) ~= "function" then
        table.insert(reasons, "基礎函式（pcall / type）不正常，環境可能已被大幅竄改")
    end
end

--- 掃描目前執行環境，回傳 { ok = boolean, reasons = {string, ...} }
function AntiHook.Scan()
    local reasons = {}

    CheckCClosures(reasons)
    CheckDumperMarkers(reasons)
    CheckEnvironmentSanity(reasons)

    return {
        ok = (#reasons == 0),
        reasons = reasons,
    }
end

return AntiHook
