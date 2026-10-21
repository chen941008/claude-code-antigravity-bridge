[English](./TROUBLESHOOTING.md) | 繁體中文

# 實戰避坑與跨平台指南（macOS / Windows / WSL）

## Windows 原生環境（PowerShell）常見問題

### 1. 啟動時報錯 `settings file is malformed: invalid character '\ufeff' looking for beginning of value`

- **原因**：Windows 內建的 PowerShell 5.1 在使用 `Set-Content -Encoding UTF8` 或特定編輯器存檔時，預設會在檔案開頭寫入隱藏的 BOM 標記（`\ufeff`），導致 `agy` 的設定檔解析器報錯。
- **解法**：本專案最新版的 `setup.ps1` 已改用無 BOM 的 `.NET` 底層寫入方式（`[System.Text.UTF8Encoding]::new($false)`）。若你先前因手動編輯遇到此錯誤，請在報錯畫面選擇 **Exit and fix manually**，並在 PowerShell 執行以下指令拔除 BOM：
  ```powershell
  $Path = "$HOME\.gemini\antigravity-cli\settings.json"
  $Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($Path, (Get-Content $Path -Raw), $Utf8NoBom)
  ```

### 2. 執行腳本時跳出紅字 `因為這個系統上已停用指令碼執行，所以無法載入 ... setup.ps1 (UnauthorizedAccess)`

- **原因**：Windows PowerShell 預設的執行原則（Execution Policy）會攔截本地的 `.ps1` 腳本。
- **解法**：
  - **方法一（遠端一鍵執行）**：使用 `irm ... | iex` 直接在記憶體內執行，完全不受本地檔案執行原則限制。
  - **方法二（單次繞過）**：執行本地檔案時改打 `powershell -ExecutionPolicy Bypass -File .\setup.ps1`。
  - **方法三（永久解鎖當前使用者）**：執行 `Set-ExecutionPolicy RemoteSigned -Scope CurrentUser` 並輸入 `Y`。

### 3. 安裝完出現 `Warning: ...\AppData\Local\agy\bin is not present in your active Environment PATH`

- **原因**：安裝程式已將 `agy` 寫入系統環境變數，但當前開啟的終端機視窗不會自動重新載入新的系統 PATH。
- **解法**：將目前的 PowerShell 視窗**完全關閉並重開**，再輸入 `agy` 即可。使用 VS Code 內建終端機時，需**關閉並重開整個 VS Code**，只開新的終端機分頁仍會沿用舊的 PATH。若只想在目前視窗暫時解決，可執行：`$env:Path = "$env:LOCALAPPDATA\agy\bin;$env:Path"`。

### 4. 安裝時印出一堆 `ERROR: logging before google.Init: I1020 ... installer.go`

- **原因**：這是 Google 官方安裝程式（以 Go 語言編寫）在初始化日誌模組前印出的內部資訊（`I1020` 代表 Info 等級），並非發生錯誤。
- **解法**：直接忽略即可。只要最後出現 `installed/placed successfully` 即代表安裝成功。

---

## macOS 常見問題

### 1. 跳出「資料取用已封鎖：『終端機』嘗試從其他 App 取用你的資料」

- **原因**：當 `agy` 連動瀏覽器進行帳號授權，或專案位於 `Documents`（文件）目錄下時，會觸發 macOS 的隱私權保護（TCC）攔截。
- **解法**：點擊通知上的「**管理**」按鈕（或前往 **系統設定 > 隱私權與安全性 > 檔案與檔案夾 > 終端機**），將 **「Google Chrome」** 與 **「文件」** 的開關打開，並重啟終端機。

### 2. 卡在 Terms of Service 條款畫面不知道怎麼繼續

- 首次輸入 `agy` 時，預設已勾選 `> [x] Yes, I agree...`，直接按鍵盤 **`Enter`** 即可進入下一步。若看不見底部提示，請將終端機視窗拉高。

---

## WSL 與跨平台共通問題

### 1. 貼上 `agy -p` 測試指令，AI 卻自己跑了 `agy --help` 並回答「你目前已經在互動式對話中」

- **狀況**：畫面沒有直接輸出純 JSON，而是出現 `Thought for ...s`、`Ran (agy --help)`，接著 AI 開始向你教學怎麼使用 `-p` 參數。
- **原因**：你還留在 `agy` 的互動式聊天介面中（左下角有 `>` 提示字元），把系統指令當成聊天訊息丟給 AI 了。
- **解法**：先輸入 `/exit`（或按兩次 `Ctrl+D`）退回系統 Shell（看到 `$`、`%` 或 `PS >`），再執行 `agy -p "..." --output-format json`。

### 2. 同時使用 Windows 原生與 WSL，需要分別安裝嗎？

**是的，必須分別安裝，且兩邊都要各自跑一次 `agy` 登入。**

| 項目             | Windows 原生（PowerShell）                    | WSL（Linux 環境）                         |
| ---------------- | --------------------------------------------- | ----------------------------------------- |
| **自動配置腳本** | `setup.ps1`                                   | `setup.sh`                                |
| **執行檔位置**   | `%LOCALAPPDATA%\agy\bin\agy.exe`              | `~/.local/bin/agy`                        |
| **設定檔路徑**   | `$HOME\.gemini\antigravity-cli\settings.json` | `~/.gemini/antigravity-cli/settings.json` |

> [!IMPORTANT]
> 切勿跨環境互叫（例如在 WSL 裡呼叫 Windows 的 `agy.exe`）。跨系統呼叫會導致路徑格式（`/mnt/c` vs `C:\`）錯亂、I/O 讀寫速度極慢，以及 Git 換行符號（CRLF vs LF）衝突。**程式碼放在哪個環境，就在哪個環境安裝與執行。**

---

## 設定腳本訊息說明

### 1. `[ERROR] Refusing to run in '...'`

目前所在目錄會變成 `agy` 的信任且可寫工作區，所以腳本會拒絕在家目錄或磁碟機／檔案系統根目錄執行。請先 `cd` 到你的專案根目錄再執行。

### 2. `'...' is not a git repository` / `No terminal to confirm`

沒有 git 就無法用 diff 檢查 `agy` 改了什麼，所以腳本會先詢問。以 pipe 方式執行（`curl | bash`）時，詢問會從終端機讀取輸入；若完全沒有終端機（CI、部分 IDE 主控台），請在確認這真的是你的專案根目錄後，設定 `AGY_BRIDGE_FORCE=1`（PowerShell 為 `$env:AGY_BRIDGE_FORCE='1'`）。

### 3. `Could not parse existing settings.json` / `settings.json.bak-<時間戳>`

腳本絕不會覆寫無法解析的 `settings.json`（例如有尾逗號或註解）。它會在旁邊存一份 `settings.json.bak-<時間戳>`，原檔保持不動並中止。修好 JSON 後再執行即可；用不到的 `.bak` 備份可自行刪除。

### 4. `CLAUDE.md has an older, unmarked Antigravity section`

`v1.1.0` 之前的版本寫入的規則沒有標記，腳本無法確定它到哪裡結束，所以不會自行處理。請手動刪除一次 `## Delegating Tasks to Antigravity (agy)` 段落後重新執行，之後的升級就會自動完成。

## 常見問題（權限、Skills、額度與模型調度）

| 狀況 / 問題                                                                                 | 原因與處理                                                                                                                                                                                                                                                                                                                                                                                          |
| ------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **JSON 的 `status` 是 `SUCCESS`，但 `response` 是空字串** | 有工具呼叫（常見是 `ls`）被「軟拒絕」。請查看 JSON 內的 `denied_actions: RunCommand`，以及 `stderr` 的 `no output produced — a tool required the "command" permission`。請執行 `bash scripts/allow.sh "<指令>"`（或 Windows `.\scripts\allow.ps1 "<指令>"`) 將該指令加入 `permissions.allow`，並確認專案目錄已列在 `trustedWorkspaces`。不要把空結果當成成功。 |
| **`stderr` 顯示工具需要 `write_file` 權限，且沒有任何檔案被建立** | 只靠 `trustedWorkspaces` 不足以允許寫檔。請在專案根目錄重新執行 `setup.sh` / `setup.ps1`，或手動在 `permissions.allow` 加入 `write_file(/專案/絕對路徑/)`。請避免 `write_file(*)`，它會連專案外的路徑也放行。 |
| **`agy` 時常詢問權限，或裝了 CLI 技能（如 `jq`、`rg`、`cargo`）在無頭模式下被跳過不執行？** | **Claude 無法幫你點擊 `agy` 的權限同意。** 在無頭模式（`agy -p`）下，未列入白名單的外部指令預設為 `Ask`，會直接被「軟拒絕」（結束碼為 0，但跳過不執行並記錄於 `stderr`）。請執行 `bash scripts/allow.sh "<指令>"`（macOS / Linux / WSL）或 `.\scripts\allow.ps1 "<指令>"`（Windows）將專案常用的測試或 CLI 工具安全加入白名單（會自動驗證安全性、避免 BOM 與重複）；亦可手動在 `~/.gemini/antigravity-cli/settings.json` 的 `permissions.allow` 清單加入（結尾不要加 `*`，規則本身即前綴比對；JSON 不可寫 `//` 註解）。 |
| **外掛「技能 (Skills)」該裝在 Claude 還是 `agy`？**                                         | **API / MCP 伺服器技能**（如 GitHub、Jira、資料庫）請裝在 **Claude Code**，由主管讀取規格並寫成 `TASK.md`；**系統級 CLI 工具**（如 `rg`、`jq`、測試框架）請裝在作業系統並加入 `agy` 的 `permissions.allow` 白名單，讓外包人員在無頭模式下順暢呼叫。                                                                                                                                                 |
| **專案原本就有 `CLAUDE.md`，執行腳本會把它覆蓋掉嗎？**                                      | **不會。** `setup.sh` 與 `setup.ps1` 皆採用「無損附加（Append）」並具備防重複檢查，只會將外包規則加在檔案最末端，完整保留你原有的專案規範。                                                                                                                                                                                                                                                         |
| **如果 `agy` 額度耗盡，Claude Code 會擅自接手並燒光自己的額度嗎？**                         | **不會。** `CLAUDE.md` 內建「額度守門員（Error & Quota Fallback）」規則。若 `agy` 回傳 `Quota Exceeded` 或 `429`，Claude 被嚴格禁止自動接手批次任務，會讀取 `agy -p "/usage"` 判斷哪個額度分組耗盡（5 小時或每週）與重置時間，並改用仍有額度的分組中同等級的模型重試一次；只有所有分組都耗盡才會停機，回報每個分組的額度與重置時間，由你決定要等待重置或授權使用 Claude 額度。                                                                                                                                                                               |
| **Claude Code 額度到上限了怎麼辦？**                                                        | 直接在終端機輸入 `agy` 進入互動模式。輸入 `/model` 可切換為 `gemini-4-argon-high`、`claude-sonnet-5-5-high` 或 `claude-opus-5-5-high`，直接用 Google AI Pro 額度繼續開發。                                                                                                                                                                                                                          |
| `authentication required`                                                                   | 尚未完成首次互動登入或憑證過期。請在終端機執行 `agy` 完成登入後再 `/exit`。                                                                                                                                                                                                                                                                                                                         |
| **模型名稱錯誤或未來模型淘汰怎麼辦？**                                                      | 無頭模式若帶入錯誤模型代號會直接失敗。本專案的 `CLAUDE.md` / `AGENTS.md` 採用「三階動態模型調度」：日常粗活不帶 `--model` 參數（直接沿用 `settings.json` 預設值）；高難度任務則要求先執行 `agy models` 查看左欄最新代號再動態調用，確保未來模型更迭時管線永不失效。                                                                                                                                       |
| **使用 OpenAI Codex CLI 呼叫 `agy` 時連線失敗或無法寫入 `~/.gemini/antigravity-cli`？**     | Codex CLI 預設在斷網的 `workspace-write` 沙盒內執行指令。`v6` 規則已指示 Codex 呼叫 `agy` 時請求 `sandbox_permissions: "require_escalated"`；當 Codex 詢問是否允許跳出沙盒執行 `agy` 時請選擇允許。 |
