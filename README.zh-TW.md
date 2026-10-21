[English](./README.md) | 繁體中文

# 讓 Claude Code 呼叫 Antigravity CLI (`agy`)：不裝第三方 MCP 的做法

> **非官方教學。** 內容依 2026-10-20 Google Antigravity 官方文件與跨平台實機測試整理，指令與旗標日後可能變動，請以官方文件為準。本文與 Google、Anthropic 無隸屬關係。

## 這份教學要解決什麼問題

你同時有 Claude 訂閱（Claude Code）與 Google AI Pro 訂閱（Antigravity）。想讓 Claude Code 當「主管」，把**量大但規格明確**的粗活（批次修改、寫單元測試、全 repo 搜尋、code review）外包給 Antigravity，用掉 Google 那邊的額度，省下 Claude 的額度。

### 為什麼不用第三方 MCP？

- 社群專案多為個人維護，星數少、少有人審查程式碼。
- 常見的 `npx -y` 安裝方式每次啟動都會抓取遠端最新版，存在供應鏈風險。
- 為了讓無頭模式（headless mode）順利跑完，不少專案預設加上 `--dangerously-skip-permissions`，等於放行代理的所有工具呼叫。

Google 官方 CLI 本身就支援無頭模式，Claude Code 可以直接用 Bash 呼叫 `agy -p`。**少一層別人的程式碼，而且每次呼叫你都看得到。**

```text
你 ──> Claude Code ──(Bash)──> agy -p "任務" --output-format json ──> Antigravity 代理
        │ 規劃、判斷、驗收                                  │ 讀檔、改檔、執行「白名單內」的指令
        └──────────── 讀回 JSON 結果，再檢查變更    ◀──┘
```

---

## 快速開始（一鍵自動設定）

在你的**專案根目錄**執行設定腳本，即可自動完成：**檢查並安裝 `agy`、以無 BOM 的 UTF-8 格式安全合併 `settings.json` 權限白名單、將當前目錄加入信任區、以及無損附加 `CLAUDE.md`（給 Claude Code）與 `AGENTS.md`（給 OpenAI Codex CLI、OpenCode、Grok、Cursor、Windsurf、Cline、GitHub Copilot）動態外包規則**。若只想產生單一檔案，可加上 `--claude-only` 或 `--agents-only` 參數（或設定環境變數 `AGY_BRIDGE_TARGETS=CLAUDE.md` / `AGENTS.md`）。

### 一分鐘看懂：哪些是全域、哪些跟專案走？

| | 位置 | 頻率 |
| --- | --- | --- |
| 登入 `agy`（步驟 2） | 你的電腦（快取的登入憑證） | **只需一次** |
| 允許／禁止規則與信任資料夾 | 全域一份：`~/.gemini/antigravity-cli/settings.json`（Windows：`C:\Users\<你>\.gemini\antigravity-cli\settings.json`）。每個你設定過的專案會把自己的資料夾加進去，原有的項目會保留。 | 每個專案 |
| 給上層 AI 的委派規則 | **該專案根目錄**的 `CLAUDE.md`（Claude Code 專用）與 `AGENTS.md`（Codex CLI、OpenCode/Grok、Cursor、Windsurf、Cline、Copilot 等通用標準）。 | 每個專案 |

所以每個新專案：`cd` 到專案根目錄，執行一次 setup 腳本（步驟 1）即可。步驟 2、3 只要做一次。沒跑過 setup 的專案沒有委派規則，`agy` 也不被允許在那裡寫檔。

### 步驟 1：執行自動設定腳本

#### 方式 A：遠端一鍵執行（固定在 `v1.3.0` 版，完全不需預先修改系統執行權限）

**macOS / Linux / WSL：**

```bash
curl -fsSL https://raw.githubusercontent.com/chen941008/claude-code-antigravity-bridge/v1.3.0/setup.sh | bash
```

**Windows (PowerShell)：**

```powershell
irm https://raw.githubusercontent.com/chen941008/claude-code-antigravity-bridge/v1.3.0/setup.ps1 | iex
```

> [!CAUTION]
> 把遠端腳本直接 pipe 給 shell 執行，等於用你的權限跑別人的程式碼。本教學的初衷就是避開未經審查的程式碼，建議先閱讀腳本內容（或改用方式 B）。另外 `setup.sh` 需要 `python3` 來合併 `settings.json`。

上面的網址指向固定標籤 `v1.3.0`，而不是會一直變動的 `main` 分支，所以你執行的程式碼不會在背後被改掉。若想再確認下載到的內容，可以比對 SHA-256（可防止傳輸過程被竄改；如果你連這個 repo 本身都不信任，請直接閱讀腳本原始碼）：

| 檔案 | SHA-256（`v1.3.0`） |
| --- | --- |
| `setup.sh` | `b8100ee6073ddb1df1c3b3e434096a54aa526eda1b76152092c3512a02a332e8` |
| `setup.ps1` | `43a9b5cfef519a0480acde37524b1c540364068c0fe440dac6b39ba8c6f885b4` |

```bash
# macOS / Linux / WSL
curl -fsSLO https://raw.githubusercontent.com/chen941008/claude-code-antigravity-bridge/v1.3.0/setup.sh
sha256sum setup.sh        # macOS 用：shasum -a 256 setup.sh
bash setup.sh
```

```powershell
# Windows (PowerShell)
irm https://raw.githubusercontent.com/chen941008/claude-code-antigravity-bridge/v1.3.0/setup.ps1 -OutFile setup.ps1
(Get-FileHash .\setup.ps1 -Algorithm SHA256).Hash
powershell -ExecutionPolicy Bypass -File .\setup.ps1
```

> [!NOTE]
> 腳本內建的安全檢查：在家目錄或磁碟機／檔案系統根目錄會直接拒絕執行（因為目前所在目錄會變成 `agy` 的可寫工作區）；在非 git 資料夾會先詢問確認（非互動環境可設 `AGY_BRIDGE_FORCE=1` 略過）；遇到無法解析的 `settings.json` 絕不覆寫，會先備份成 `settings.json.bak-<時間戳>` 再中止。

#### 方式 B：下載腳本至本地執行（免設定 `chmod` 與 `Set-ExecutionPolicy` 的寫法）

若你是將腳本儲存於本地執行，直接呼叫直譯器即可繞過預設的執行權限攔截：

**macOS / Linux / WSL：**

```bash
bash setup.sh
```

**Windows (PowerShell)：**

```powershell
powershell -ExecutionPolicy Bypass -File .\setup.ps1
```

> [!NOTE]
>
> - 安裝過程中，Google 官方安裝程式可能會印出 `ERROR: logging before google.Init...`，這是官方程式內部的 Go 語言除錯日誌，並非安裝失敗；只要看到 `installed/placed successfully` 即代表安裝成功。
> - Windows 原生環境與 WSL 的執行檔與憑證互不相通，請在兩個環境中分別執行對應腳本。詳見 [跨平台與排錯指南](./docs/TROUBLESHOOTING.zh-TW.md)。

### 步驟 2：首次互動登入（只需執行一次）

無頭模式使用的是本機已快取的登入憑證，請先手動啟動一次（Windows 初次安裝若提示找不到 `agy`，請先重啟終端機視窗以載入新 PATH；使用 VS Code 內建終端機時，需完全關閉並重開 VS Code，只重開終端機分頁不會重新載入 PATH）：

```bash
agy
```

1. 出現服務條款（Terms of Service）畫面時，預設已勾選 `[x]`，直接按 **`Enter`** 繼續。
2. 於瀏覽器登入具有 Google AI Pro 訂閱的 Google 帳號。
3. （推薦）輸入 `/model` 將預設模型設為 `Gemini 3.8 Flash (Low)` 或 `Medium`。日常粗活（Tier 1）會自動沿用此預設模型以節省額度。
4. **關鍵步驟：** 完成後務必輸入 `/exit` 退回一般系統終端機。

> [!WARNING]
> 千萬不要留在 `agy` 的 `>` 互動對話框內貼上步驟 3 的無頭測試指令！如果在對話框內貼上 `agy -p ...`，AI 代理會誤以為你在問問題，並在背景執行 `agy --help` 後向你解釋該指令的用法，而不會輸出純 JSON。請務必先輸入 `/exit` 退回系統 Shell（如 `$`、`%` 或 `PS >`）。

### 步驟 3：測試無頭模式與實戰

在一般終端機測試 JSON 輸出：

```bash
agy -p "用一句話解釋 git status" --output-format json
```

確認回傳包含 `"status": "SUCCESS"` 後，啟動 `claude` 即可開始外包任務：

```text
> 幫 src/api/ 底下所有模組補上單元測試，這種批次的事情請依據 CLAUDE.md 外包給 agy。
```

### 步驟 4（選用）：檢查安裝結果

在專案根目錄執行自我檢查。它不會呼叫任何模型，所以不耗額度。會確認 `agy` 已在 PATH、`settings.json` 格式正確且包含這個專案的規則、`CLAUDE.md` 與 `AGENTS.md` 皆為最新的規則區塊，並列出你的額度分組：

```bash
# macOS / Linux / WSL（repo 內的 scripts/ 資料夾；或從與 setup.sh 同一個 tag 下載 verify.sh）
bash scripts/verify.sh
```

```powershell
# Windows
powershell -ExecutionPolicy Bypass -File .\scripts\verify.ps1
```

每一行是 `PASS`、`WARN` 或 `FAIL`；結束代碼等於 `FAIL` 的行數。若有異常，回報問題時請附上輸出。同一支腳本每次 push 後也會在 CI 的 Ubuntu、macOS 與 Windows（PowerShell 5.1 與 7）上執行。

### 跨平台／跨 Agent 怎麼用（Claude Code、Codex CLI、OpenCode/Grok、Cursor）、怎麼移除

在跑過 setup 的專案裡啟動 `claude`、`codex`、`opencode` 或其他支援 `AGENTS.md` 的 AI 工具。Claude Code 會讀 `CLAUDE.md`；而 OpenAI Codex CLI、OpenCode（常接 Grok / DeepSeek 等）、Cursor、Windsurf、Cline、Copilot 則會自動讀 `AGENTS.md`。批次工作（改很多檔、補單元測試、全專案搜尋、code review）很適合外包；架構決策與小改動則留給上層 AI 自己處理。這是引導而不是保證：想確保的話，直接說「這個請依據 CLAUDE.md / AGENTS.md 外包給 agy」。預設 `agy` 只能執行 `ls`、`git status` 這類唯讀指令，要放行更多請看下方「如何新增 CLI 技能」教學。

> [!IMPORTANT]
> **跨 AI 平台（Codex / Grok / OpenCode / Windows）細微差異與避坑重點（已內建於 `v5` 規則）：**
> 1. **OpenAI Codex CLI 的預設沙盒攔截（Seatbelt / Landlock）**：Codex CLI 預設在 `workspace-write` 沙盒中執行指令，**預設斷網且禁止寫入 `$HOME/.gemini/antigravity-cli`**，會導致 `agy` 無法連線或寫入 session/token。`v5` 規則已明確指示 Codex 在呼叫 `agy` 時必須請求跳出沙盒（`sandbox_permissions: "require_escalated"`）；當 Codex 跳出權限詢問時請點選允許。
> 2. **防止 `agy` 讀到 `AGENTS.md` 自我遞迴（Self-Recursion）**：因為 `agy` 也是在同一個專案目錄下執行，若它自己讀到 `AGENTS.md` / `CLAUDE.md` 可能會誤以為自己也要去呼叫 `agy`。本專案透過雙重防護避免遞迴：`settings.json` 白名單不放行 `command(agy)`，且 `v5` 規則開頭明定若執行者本身就是 `agy` 則忽略該區塊。
> 3. **Windows PowerShell vs Bash 引號與跳脫字元差異**：在 Windows 上，Codex CLI 與 Cursor 預設常呼叫 PowerShell，而 Claude Code 預設呼叫 Git Bash。`v5` 規則第 2 點強制要求多行或含引號／特殊字元的複雜指令一律先寫入 `TASK.md` 再交由 `agy` 讀取，徹底避開跨 Shell 的引號跳脫問題。

要從某個專案移除：刪掉該專案 `CLAUDE.md` 與 `AGENTS.md` 裡 `<!-- agy-bridge:start ... -->` 到 `<!-- agy-bridge:end -->` 之間的區塊，再從全域 `settings.json` 的 `permissions.allow`（那條 `write_file(...)`）與 `trustedWorkspaces` 刪掉該專案資料夾。目前沒有自動解除安裝。

若 `scripts/verify.*` 或 setup 腳本警告 `CLAUDE.md` 有舊版、沒有標記的區塊，請看 [Q5](#q5-我之前跑過舊版設定腳本要怎麼更新到新版規則)：把舊區塊手動刪掉一次，再重新執行 setup。

---

## 架構最佳實踐：外掛「技能 (Skills)」該裝在哪？

在這套「主管（Claude）與外包（agy）」的分工架構下，請依據技能的性質決定安裝位置：

1. **API / 伺服器級技能（MCP Servers） -> 裝給 Claude Code**
   - **範例**：GitHub MCP（讀取 PR 與 Issue）、Jira（查詢需求票）、PostgreSQL（查詢資料庫綱要）、Slack。
   - **原因**：Claude 是大腦與專案經理。它負責透過 MCP 安全地讀取外部 API 資訊，消化後將純文字規格寫入本地的 `TASK.md`，再交由 `agy` 改扣。這樣 `agy` 完全不需要接觸你的資料庫帳密或外部 Token，資安與架構最乾淨。
2. **系統級 CLI 工具技能 -> 裝在作業系統，並加進 `agy` 白名單**
   - **範例**：`jq`（解析 JSON）、`ripgrep`（`rg` 極速搜尋）、`cargo` / `go` / `pytest` / `cmake`（編譯與測試工具）。
   - **原因**：這些是給外包人員幹活用的本地工具。只要安裝在系統上，並寫入 `settings.json` 白名單，`agy` 在無頭模式下就能毫無阻礙地呼叫它們。

### 教學：如何將 CLI 技能加入 `agy` 白名單？

在無頭模式（`agy -p`）下，`agy` 無法跳出互動視窗詢問權限：

- **檔案讀取**：允許。**檔案寫入**即使在 `trustedWorkspaces` 內，也需要 `write_file(...)` 白名單規則（實測結果）。設定腳本會加入一條僅限你專案目錄的規則；`write_file(*)` 會連專案外的路徑也放行，請避免使用。
- **Shell 外部指令**：預設為 `Ask`，在無頭模式下會被**「軟拒絕」**（結束碼雖為 0，但指令會被跳過不執行，並於 `stderr` 輸出警告）。

Claude Code **無法**幫你繞過 `agy` 的內部權限限制。若你想賦予 `agy` 使用 `rg` (ripgrep)、`jq` 或 `cargo test` 等技能，請手動將它們加入 `~/.gemini/antigravity-cli/settings.json`（Windows 為 `$HOME\.gemini\antigravity-cli\settings.json`）的 `permissions.allow` 清單中（優先順序為 **Deny > Ask > Allow**）：

> **預設只放行唯讀指令。** `setup.sh` / `setup.ps1` 只放行列目錄（`ls`；Windows 為 `dir` / `Get-ChildItem`）、`git status/diff/log`，以及專案目錄內的檔案寫入。會執行專案程式碼的指令（`pytest`、`make`、`npm`）或能讀檔案內容的指令（`cat`、`rg`、`jq`）需自行加入，因為 `deny` 裡的 `read_file(.env)` 擋不住 `command(cat .env)`。請只在信任的專案加入。

```json
{
  "colorScheme": "tokyo night",
  "model": "Gemini 3.8 Flash (Medium)",
  "permissions": {
    "allow": [
      "write_file(/path/to/your/project/)",
      "command(ls)",
      "command(git status)",
      "command(git diff)",
      "command(git log)",
      "command(pytest)",
      "command(make)",
      "command(cargo test)",
      "command(jq)",
      "command(rg)",
      "command(regex:npm run (build|lint|test))"
    ],
    "deny": [
      "command(rm -rf)",
      "command(sudo)",
      "command(git push --force)",
      "command(git push -f)",
      "write_file(.git/)",
      "read_file(.env)"
    ]
  },
  "trustedWorkspaces": ["/Users/你的帳號/專案路徑"]
}
```

_規則是以指令「前綴」比對：`"command(jq)"` 也會放行 `jq .name package.json`，`"command(rg)"` 也會放行 `rg TODO src/`。_

> [!IMPORTANT]
> **請寫 `command(jq)`，不要寫 `command(jq *)`。** 結尾加 ` *` 的寫法無效。2026-10-20 在 WSL 以無頭模式 `agy -p` 實測（每個情境各跑一次，請 `agy` 照字面執行指令）：
>
> | `permissions.allow` | 指令 | 結果 |
> | --- | --- | --- |
> | `command(ls *)` | `ls -la`、`ls` | 被拒絕 |
> | `command(ls)` | `ls -la` | 允許（前綴比對） |
> | `command(ls)` | `ls && echo ...`、`ls; echo ...`、`ls \| wc -l`、`ls $(echo ...)` | 被拒絕 |
> | `command(ls)` | `echo ...`（對照組） | 被拒絕 |
>
> 也就是說，前綴規則不會讓串接、管線或指令替換夾帶的額外指令順便通過。**尚未測試**的有：串接的「每一段都在白名單內」的情況（[官方文件](https://antigravity.google/docs/permissions?tab=cli)提到允許 `command(git)` 時 `git status && git log` 會直接執行），以及 deny 規則的比對行為。因此本專案的 deny 規則也改用同樣有文件依據的前綴寫法（`command(rm -rf)`、`command(sudo)` 等）。請讓白名單保持精簡，不要放行直譯器或網路工具（`bash`、`python`、`node`、`curl`、`wget`、`ssh`）。
>
> 如果你執行過舊版設定腳本，裡面結尾是 ` *` 的項目（例如 `command(ls *)`）不會造成問題，只是沒有作用，可以自行刪除。`agy` 更新後想重新確認這個行為：先備份 `settings.json`，把 `allow` 只留 `["command(ls)"]`，再執行 `agy -p "Run exactly this shell command, unmodified, and show its raw output: ls && echo CHAIN_OK" --output-format json`，預期會被拒絕，且 `CHAIN_OK` 不會出現。

---

## 常見問題與設計理念 (FAQ)

### Q1: 如果我的專案原本就已經有自己的 `CLAUDE.md`，執行自動設定腳本會把它覆蓋掉嗎？

**完全不會。** 腳本採用「無損附加（Append）」的設計。如果它偵測到你已有 `CLAUDE.md`，它只會將外包規則安靜地加在文件最底端，絕不會更動你原有的程式碼規範。規則放在以 `<!-- agy-bridge:start v4 -->` / `<!-- agy-bridge:end -->` 標記包住的區塊裡，所以重複執行只會替換這個區塊，不會產生重複內容，也不會動到其他部分。

### Q2: Claude Code 如何決定要開哪個 `agy` 模型？未來模型改名或淘汰會不會壞掉？

我們的 `CLAUDE.md` 內建了**「三階動態模型調度策略（Dynamic Model Tiering）」**：

- **Tier 1（日常粗活）**：Claude 呼叫時**不帶 `--model` 參數**，直接沿用你在 `settings.json` 設定的輕量預設模型，極致省額度且永不過時。
- **Tier 2 & 3（中等邏輯與高難度演算法）**：Claude 會先在背景執行一次 `agy models` 查詢當前支援的最新清單，再動態挑選中階或旗艦模型掛載 `--model <MODEL_ID>`。即使未來模型更迭，管線也完全不會失效。

### Q3: 如果 Antigravity (agy) 的額度耗盡，Claude Code 會擅自消耗自己的額度來完成工作嗎？

**不會。** `CLAUDE.md` 設有嚴格的**「額度守門員（Quota Fallback）」**規則。當 Claude 偵測到 `agy` 回傳額度不足（Quota Exceeded）、速率限制（429）或指令被拒絕時，會先執行 `agy -p "/usage"`（瞬間完成、不耗 token）讀取額度分組。每個分組會列出共用額度的模型，並有 5 小時與每週兩個額度，所以 Claude 能確切知道撞到哪一種額度、何時重置。分組一律從 `agy` 讀取、不寫死，Google 調整分組後仍然適用。若失敗的那次執行沒有改動任何檔案，Claude 會改用仍有額度的分組中同等級的模型重試一次。所有分組都耗盡時，被明令**禁止**擅自接手批次工作：它會立即停下來，回報每個分組的額度與重置時間，並詢問你的決定（要等待額度重置，還是授權消耗 Claude 自身額度繼續）。

### Q4: 遇到了 macOS 跳出「資料取用已封鎖」或 Windows 出現 `\ufeff` 報錯怎麼辦？

請參閱我們的跨平台避坑手冊：**[docs/TROUBLESHOOTING.zh-TW.md](./docs/TROUBLESHOOTING.zh-TW.md)**。

### Q5: 我之前跑過舊版設定腳本，要怎麼更新到新版規則？

**`v1.1.0` 之前**的版本寫入的規則沒有標記，腳本會保持原樣並顯示警告（舊規則例如「`git status` 必須乾淨，必要時先 commit」，這會擋住唯讀任務）。只需要手動遷移一次：

1. 在你的 `CLAUDE.md` 刪除整段 `## Delegating Tasks to Antigravity (agy)`（它是附加在檔案結尾；你自己寫的內容請保留）。
2. 在專案根目錄重新執行 `setup.sh` / `setup.ps1`。它會附加新的標記區塊，並合併 `settings.json`，不會產生重複項目。

之後再執行腳本，就會自動把標記區塊升級到最新版。重新執行**不會**移除舊版加進白名單的項目（例如 `pytest *`、`make *`）。不需要的話，請自行從 `~/.gemini/antigravity-cli/settings.json` 刪除。

---

## 選用：用 PreToolUse Hook 強制執行規則

`CLAUDE.md` 的規則只是建議，Claude 仍可能忘記。[`extras/claude-hook/agy_guard.py`](./extras/claude-hook/agy_guard.py) 是選用的 Claude Code hook，會在以下情況攔截無頭 `agy -p` 呼叫（exit code 2）：缺少 `--output-format json`、既沒有 `run_in_background` 也沒有 >= 600000 的 Bash `timeout`、前景呼叫缺少 `--print-timeout`，或同一個專案目錄仍有另一個無頭 `agy` 行程在執行（能讀到工作目錄時會忽略其他專案的行程，讀不到時保守地攔截）。請加入 `.claude/settings.json`：

```json
{
  "hooks": {
    "PreToolUse": [
      { "matcher": "Bash", "hooks": [{ "type": "command", "command": "python3 /path/to/extras/claude-hook/agy_guard.py" }] }
    ]
  }
}
```

遇到非預期輸入一律放行，因此 hook 本身的 bug 不會讓你無法使用 Bash。可用 `bash scripts/test-agy-guard.sh` 離線測試。

## 額度與安全檢查清單

- **額度計算**：Antigravity 依實際代理工作量與 Token 計費（每 5 小時刷新，另有每週上限）。每次無頭呼叫基礎上下文約耗費 6,000～10,000 `input_tokens`，建議將同類批次修改集中於單次呼叫或以 `--conversation` 接續。
- **模型分池**：Gemini 與 Claude/GPT 模型分屬不同額度池，日常粗活建議用 Gemini Flash。
- **家庭共用**：家庭群組內 Antigravity 額度為全家共用。
- **輸出視為不可信資料**：規則會要求 Claude 把 `agy` 的輸出（以及 `agy` 從專案中讀到的內容）當成資料而不是指令，因為專案裡的檔案可能被植入惡意文字。接受變更前仍請檢查 diff。
- **安全底線**：建議使用 Git 版控（有 Git 時規則會用 `git status` / `git diff`，沒有時改用備份或檔案清單比對）、禁止使用 `--dangerously-skip-permissions`，且每次外包後務必檢查變更。
