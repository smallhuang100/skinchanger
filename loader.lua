--[[
    Rivals · Skin Changer — 一行式載入器

    在執行器貼這整份，或直接貼最下面那一行 loadstring 就好。
]]

local REPO_BASE = "https://raw.githubusercontent.com/smallhuang100/skinchanger/main/"

local url = REPO_BASE .. "SkinChanger.luau?r=" .. tostring(math.random(1, 1e9))

local ok, source = pcall(game.HttpGet, game, url)
if not ok then
    return warn("[SkinChanger] 下載失敗：" .. tostring(source))
end

local chunk, err = loadstring(source, "@SkinChanger")
if not chunk then
    return warn("[SkinChanger] 編譯失敗：" .. tostring(err))
end

chunk()

--[[
    平常只要貼這一行：

    loadstring(game:HttpGet("https://raw.githubusercontent.com/smallhuang100/skinchanger/main/SkinChanger.luau"))()
]]
