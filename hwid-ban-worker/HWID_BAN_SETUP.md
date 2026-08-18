# HWID 封鎖系統 · 手把手

全程滑鼠點一點，不用裝任何東西、不用信用卡（跟你之前架 Aetherea relay 用的
是同一種 Cloudflare Worker，如果你已經有 Cloudflare 帳號，直接沿用就好，
**不用重新註冊**）。

---

## 這套系統在做什麼

```
你的腳本開始執行
      │
      ├─ 1. 掃描目前環境有沒有被 hook 過的痕跡（AntiHook.luau 那套邏輯）
      │
      ├─ 2. 打 GET /check?hwid=xxx 問 Worker：這個裝置被封鎖了嗎？
      │        └─ 被封鎖 → 印警告、腳本直接停止，後面什麼都不會執行
      │
      └─ 3. 如果第 1 步掃到痕跡 → 打 POST /report 把這個 hwid 記進封鎖名單
               → 印警告、腳本停止
```

`HWID_BANS` 是一個 Cloudflare **Workers KV**（key-value 儲存），
key 是 hwid，value 是 `{reason, at}` 這種 JSON。Worker 本身只是個
薄薄一層 API，真正的名單存在 KV 裡。

---

## 步驟 1：建立 Worker

1. 登入 [dash.cloudflare.com](https://dash.cloudflare.com)
2. 左側選單 `Workers & Pages` → `Create` → `Create Worker`
3. 名字取一個好認的，例如 `skinchanger-hwid`
   （這個名字會變成網址的一部分：`skinchanger-hwid.你的帳號.workers.dev`）
4. 先點 `Deploy` 部署一次預設的 Hello World（等一下再換成真正的程式碼）

---

## 步驟 2：建立 KV Namespace

1. 左側選單 `Workers & Pages` → 上面分頁點 `KV`
2. `Create a namespace`
3. Namespace name 填 `HWID_BANS`（名字隨便取都行，等一下綁定的時候自己選得到就好）
4. `Add`

---

## 步驟 3：把 KV 綁到 Worker 上

1. 回到 `Workers & Pages`，點進剛剛建的 `skinchanger-hwid`
2. 上面分頁點 `Settings` → 左側 `Variables`（有些版面是 `Bindings`）
3. 找到 `KV Namespace Bindings`，點 `Add binding`
4. **Variable name** 一定要填 `HWID_BANS`（要跟 `worker.js` 裡的
   `env.HWID_BANS` 完全一樣，這是程式碼裡讀取這個綁定的名字）
5. **KV Namespace** 選你剛剛建的那個
6. `Save`

> ⚠️ 這個 Variable name 打錯的話，Worker 執行到 `env.HWID_BANS.get(...)`
> 會直接噴錯，`/check` 永遠回傳 500。如果之後測試發現 500，先回來檢查這裡。

---

## 步驟 4：貼上程式碼

1. 回到 Worker 頁面，點 `Edit code`（或 `Deployments` → 程式碼編輯器）
2. 把畫面裡原本的範例程式碼全部刪掉
3. 打開這個資料夾裡的 `worker.js`，全選複製，貼進去
   > 裡面的 `BAN_SECRET` 我已經幫你隨機產生好了一組，跟 `SkinChanger.luau`
   > 裡 `REPORT_SECRET` 的值完全一樣，**兩邊不用再改**，除非你想自己換一組
   > （換的話兩邊要改成同一組新字串）。
4. 右上角 `Deploy`（或 `Save and Deploy`）

---

## 步驟 5：測試

部署完，Worker 網址長這樣：

```
https://skinchanger-hwid.你的帳號.workers.dev
```

瀏覽器貼上打開：

```
https://skinchanger-hwid.你的帳號.workers.dev/check?hwid=test123
```

應該看到：

```json
{"banned":false}
```

看到這個 = KV 綁定跟 Worker 都正常了。

---

## 步驟 6：把網址填進腳本

把 `你的帳號` 換成實際的網址告訴我，我幫你把 `SkinChanger.luau` 裡的：

```lua
local LICENSE_API = "https://REPLACE_ME.workers.dev"
local LICENSE_GATE_ENABLED = false
```

改成你的網址，並且把 `LICENSE_GATE_ENABLED` 設回 `true`（現在故意設
`false`，是為了讓你在還沒部署好 Worker 之前腳本照樣能跑，不會被空的
`LICENSE_API` 卡住）。

> 也可以自己改：`SkinChanger.luau` 裡搜尋 `REPLACE_ME.workers.dev`，
> 把整段網址換成你自己的，然後把 `LICENSE_GATE_ENABLED` 那行的
> `false` 改成 `true`。

---

## 步驟 7：先跑 dry-run，別急著正式啟用封鎖

`SkinChanger.luau` 裡還有一個開關：

```lua
local ANTIHOOK_DRY_RUN = true
```

**強烈建議先保持 `true` 一陣子。** `iscclosure` 這招在少數執行器上可能誤判
（某些原生功能本來就是用 Lua 實作的，不是被 hook 才變成 Lua closure）。
`dry-run` 模式下，就算掃到痕跡也只會印警告、不會真的呼叫 `/report`、
不會封鎖任何人。

拿你自己平常用的執行器實際跑幾次，確認 console 沒有噴出不該有的警告
（`[SkinChanger] (dry-run，尚未封鎖) 偵測到疑似 hook 痕跡：...`），
確認乾淨了才把 `ANTIHOOK_DRY_RUN` 改成 `false` 正式啟用。

---

## 管理指令（查名單 / 解除誤判封鎖）

這幾個要用 `curl`（Windows 內建的 PowerShell 也有 `curl` 別名，
直接在終端機貼就能跑，記得把網址跟 hwid 換成實際的）。

### 查看目前所有被封鎖的 hwid

```bash
curl "https://skinchanger-hwid.你的帳號.workers.dev/list?secret=a07e18c7510588f04dea5774077d7d434bdcc864c3a1f1e4"
```

### 手動解除某個 hwid 的封鎖（誤判復原）

```bash
curl -X POST "https://skinchanger-hwid.你的帳號.workers.dev/unban" ^
  -H "Content-Type: application/json" ^
  -d "{\"hwid\":\"要解除的hwid\",\"secret\":\"a07e18c7510588f04dea5774077d7d434bdcc864c3a1f1e4\"}"
```

> 上面用的是 Windows `^` 換行符號（PowerShell 底下用反引號 `` ` ``），
> 懶得處理換行的話整行貼成一行也可以。

### 手動封鎖某個 hwid（不透過腳本自動觸發，直接手動加）

```bash
curl -X POST "https://skinchanger-hwid.你的帳號.workers.dev/report" ^
  -H "Content-Type: application/json" ^
  -d "{\"hwid\":\"要封鎖的hwid\",\"secret\":\"a07e18c7510588f04dea5774077d7d434bdcc864c3a1f1e4\",\"reason\":\"手動封鎖\"}"
```

---

## 老實話 · 這套系統的真實極限

1. **擋不住「執行器本身」在你的程式碼開始跑之前動手腳。**
   那個時間點你的程式碼根本還沒開始執行，物理上沒辦法防，這是整個
   外掛圈的共同限制，任何人跟你講他做得到「完全防 hook」都是在唬爛。

2. **`REPORT_SECRET` 是內嵌在客戶端腳本裡的。** 如果有人把整份腳本
   反混淆、完整分析過一遍，這組密鑰本來就會跟著曝光。這組密鑰的作用是
   擋「不相干、沒在跑你腳本的人」亂呼叫 `/report`、`/unban`、`/list`
   洗你的 KV，**不是**用來擋「已經在分析你腳本的人」。

3. **HWID 不是真正綁定實體硬體。** 多數執行器的 `gethwid()` 是它自己
   產生的識別碼，清執行器快取、重灌可能會變；退而求其次用的 Roblox
   `RbxAnalyticsService:GetClientId()` 也是類似性質。這套系統防的是
   「隨手復用同一個環境的人」，不是「有心換新識別碼的人」。

4. **`iscclosure` 有誤判風險。** 這就是為什麼一定要有 `/unban` 端點、
   一定要先跑過 `ANTIHOOK_DRY_RUN = true` 再正式啟用。

這套系統的真實定位是**縱深防禦裡的一層**——跟你已經在用的 Prometheus
混淆、GitHub 私密託管搭配起來，拉高盜源碼跟濫用的成本，逼退大部分
懶得花力氣的人，但擋不住真的下定決心要拆解的人。抱著這個心態去用，
不要指望它是絕對防護。
