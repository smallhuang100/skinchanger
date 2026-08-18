--[[
    Rivals · Skin Changer — 一行式載入器

    用法：把 REPO_BASE 換成你自己的 GitHub raw 網址，然後在執行器貼這整份，
    或直接貼下面那一行 loadstring。
]]

local REPO_BASE = "https://raw.githubusercontent.com/YOUR_USERNAME/YOUR_REPO/main/"

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
    等 repo 建好之後，平常只要貼這一行就好：

    loadstring(game:HttpGet("https://raw.githubusercontent.com/YOUR_USERNAME/YOUR_REPO/main/SkinChanger.luau"))()
]]
