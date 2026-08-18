# Rivals · Skin Changer / Unlocker

從 Aetherea 主腳本（`upload/loader.luau`）的 Unlocker 區塊移植出來的獨立腳本，
UI 改用 [UELinoriaLib](https://github.com/pandaeatdonuts-byte/UELinoriaLib)。

只鎖 RIVALS（`GameId = 6035872082`），跑在別的遊戲會直接靜默退出。

---

## 檔案

| 檔案 | 用途 |
|---|---|
| `SkinChanger.luau` | 主腳本，1800 行，自帶 UI，直接執行就能用 |
| `loader.lua` | 一行式載入器範本（要填自己的 GitHub raw 網址） |
| `lib/Library.lua` | UELinoriaLib 本體（離線備份用） |
| `lib/addons/` | SaveManager（設定檔）、ThemeManager（主題） |
| `lib/Example.lua` | 原作者的 UI 範例，改 UI 時可以參考 |

### 執行方式

**A. 直接貼整份** — 把 `SkinChanger.luau` 全文貼進執行器跑。
UI 函式庫會自動從 GitHub 抓。

**B. 從 GitHub 載入** — 把 `SkinChanger.luau` 丟上 repo，然後：

```bash
loadstring(game:HttpGet("https://raw.githubusercontent.com/YOUR_USERNAME/YOUR_REPO/main/SkinChanger.luau"))()
```

**C. 完全離線** — 把 `lib/` 整個複製到執行器的
`workspace/RivalsSkinChanger/lib/`，腳本會優先讀本地檔案，抓不到才連網。

---

## Unlocker 的原理

全部都是**客戶端假資料**，沒有任何一個封包送去伺服器。以下是原腳本對應的位置：

### 1. 「你擁有這個外觀」的判定（`loader.luau` 6249–6282）

`CosmeticLibrary` 有五個簽章不同的擁有查詢，全部 hook 掉，
名字只要在 `fake_owned` 表裡就直接 `return true`：

```
OwnsCosmeticNormally / OwnsCosmeticUniversally
OwnsCosmeticForSomething / OwnsCosmeticForWeapon / OwnsCosmetic
```

### 2. 背包資料（`loader.luau` 6320–6470）

Hook `PlayerDataController.Get`，把這幾個 key 換成假資料：

| key | 換成 |
|---|---|
| `CosmeticInventory` | `fake_owned` |
| `WeaponInventory` / `FreeWeaponUnlockCheck` | 真實清單 **疊加** 假武器 |
| `FavoritedCosmetics` | `favorites` |

武器一定要用「疊加」不能整份取代 — 原作註解就寫了，
用過時的快照會讓遊戲查不到某把武器而 `nil.Status` 崩潰。

`PlayerDataController.CurrentData` 是另一個物件、有自己的 `:Get`，要另外補一份
（原腳本的 `PatchCurrentDataGet`）。

### 3. 解鎖武器（`loader.luau` 7116–7153）

往 `fake_weapon_owned` 塞 `{ Name, Level = 1, XP = 0 }`，
再 hook `GetWeaponData` 幫這些憑空生出來的武器補資料。
武器清單來自 `ShopLibrary:GetReleasedOwnableWeapons()`。

### 4. 裝備（`loader.luau` 6576–6650 + 6657–6960）

`EquipCosmetic` remote 在 `__namecall` 被**攔截丟掉**，不往伺服器送，
改存進 `state.equipped`，然後由一整串視覺 hook 在本地畫出來：

| Hook | 負責 |
|---|---|
| `ItemLibrary.GetViewModelImageFromWeaponData` | 背包 / 商店的預覽圖 |
| `ClientItem._CreateViewModel` | 第一人稱手上那把槍的皮膚 |
| `ClientViewModel.new` / `.GetWrap` | 包裝 (Wrap) 與吊飾 (Charm) |
| `ClientEntity.ReplicateFromServer` | 終結技 (Finisher) |
| `FighterController.GetWrap` | 丟到地上的物件的包裝 |
| `JumpPads.CreateJumpPadVisual` | 彈跳板皮膚 |

所以你在遊戲**自己的背包**點裝備，走的也是同一條路 — 一樣會被接住並套用。

---

## UI

### Unlocker 分頁

- **一鍵解鎖** — `解鎖全部（外觀 + 武器）` 就是全皮膚 / 全包裝 / 全吊飾 /
  全終結技 + 全武器。旁邊的「鎖回去」要點兩下。
- **批次解鎖** — 依類型（Skin / Wrap / Charm / Finisher）或稀有度批次處理。
- **指定項目** — 選武器 → 打關鍵字按 Enter → 從下拉選單挑，
  可以單獨解鎖某個外觀、某把武器、或某把武器的全部外觀。
- **狀態** — 顯示本腳本目前塞了多少假資料。

### Equip 分頁

選類型 + 武器 + 外觀後按「套用」。
`None` = 卸下，`Random` = 每次生成隨機挑一個（可限定只從最愛裡挑）。
包裝可以開 `Inverted`。非皮膚類型可以「套用到所有武器」。

`攔截裝備請求` 關掉的話，裝備會照常送去伺服器 —
沒真的擁有就會被打回來，但真正擁有的東西可以正常存檔。

### Settings 分頁

卸載、選單快捷鍵（預設 `End`）、浮水印、設定檔（SaveManager）、主題（ThemeManager）。

把 `腳本載入時自動全解鎖` 打開後存成 autoload 設定檔，下次執行就會自動解鎖。

---

## 跟原版的差異

移植時修掉 / 改掉的幾個地方：

1. **Lock 不會誤刪真資料**。原版的 `LockAll()` 是把整份清單設 `nil`，
   會連你真正擁有的外觀一起從客戶端背包裡砍掉。這版另外用 `state.injected`
   記住「哪些是自己塞進去的」，Lock 和卸載只動這些。
2. **`LockAllWeapons()` 原版的雙層迴圈是壞的**（一邊 `pairs` 一邊 `table.remove`），
   這版直接 `table.clear`。
3. **下拉選單取代手打武器 / 外觀名稱**。原版是 `CreateInput` 要你自己打
   `"10B Visits"` 這種字串，這版改成可搜尋的下拉選單。
   遊戲裡外觀有好幾千個，全塞進選單會卡死，所以先用
   「類型 + 武器 + 關鍵字」過濾，再截斷到 150 筆。
4. **能重複執行**。再跑一次會先把舊的那份收乾淨（還原 hook、關掉 UI）。
5. **沒有 `hookmetamethod` 的執行器也能跑** — Unlock 照常，Equip 停用並警告。

---

## 注意事項

- 解鎖與裝備**只存在你自己的客戶端**，伺服器看不到、不會存檔，
  其他玩家也看不到。重進遊戲要再跑一次。
- 外觀套用後沒出現的話，切換一次武器讓 ViewModel 重建。
- `攔截裝備請求` 開著的時候，你在遊戲背包做的任何裝備 / 收藏動作
  都不會真的存進帳號。想正常玩就把它關掉。
