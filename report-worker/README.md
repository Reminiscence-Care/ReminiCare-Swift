# reminicare-report-api

接收 iPad App「Log → 回報問題」送出的回報，在私人 GitHub repo 開一個 Issue（標籤 `app-report`），執行紀錄另以留言附上（每則最多 60,000 字）。

- App 端不持有任何 GitHub 憑證；Token 只存在這個 Worker 的 secret。
- 端點 `POST /v1/reports` 不需驗證，所以用三道限制降低濫用的影響：每個 IP 每分鐘 3 次、Body 上限 512 KiB、Token 只能讀寫一個 repo 的 Issues。最壞情況是被灌垃圾 Issue。
- **錄音**：回報送出後，App 依序把最近的錄音（最多 5 段、每段 8 MB 以內的 WAV）送到 `POST /v1/reports/<reportId>/audio/<0-4>`。Worker 把檔案 commit 到回報 repo 的 `audio/<reportId>/<n>.wav`，並在 Issue 留言附上連結。reportId 是 App 產生的隨機 UUID，必須在 `REPORT_IDS` 查得到對應的 Issue 才收，所以外人無法上傳；這條路由不經每分鐘 3 次的限流。沒有設定 `REPORT_IDS` 時回 `audioUnavailable`(503)。
- 回應：`201 {"issue": 12, "logComplete": true}`；錯誤只回固定代碼 `invalid`(400)、`tooLarge`(413)、`rateLimited`(429)、`upstream`(502)，不轉傳 GitHub 的錯誤內容。

## 第一次部署（使用者操作）

1. 在 GitHub 建立**私人** repo，例如 `Reminiscence-Care/ReminiCare-reports`，並新增標籤 `app-report`。回報含長輩說的話，絕對不要用公開 repo。
2. 建立 fine-grained personal access token：Repository access 只選上面那個 repo，Permissions 只給 **Issues: Read and write** 和 **Contents: Read and write**（存錄音用）。
3. 部署：
   ```sh
   cd report-worker
   pnpm install
   pnpm exec wrangler login
   pnpm exec wrangler secret put GITHUB_TOKEN   # 貼上第 2 步的 token
   pnpm exec wrangler secret put REPORT_REPO    # 例如 Reminiscence-Care/ReminiCare-reports
   pnpm run deploy
   ```
4. 部署完的網址若不是 `https://reminicare-report-api.hding49.workers.dev`，改 `ConfigKey.defaultErrorReportURL`，或在 App 設定頁「錯誤回報網址」填入。
5. 建立 `REPORT_IDS`（附錄音必須要有，也能防止重送時開出重複 Issue）：`pnpm exec wrangler kv namespace create REPORT_IDS`，把 id 填進 `wrangler.jsonc` 的 `kv_namespaces` 後重新部署。

### 從舊版升級成可附錄音

1. GitHub → Settings → Developer settings → Fine-grained tokens，編輯原本的 token，加上 **Contents: Read and write**（repo 範圍不變）。token 值不變，不用重設 secret。
2. 還沒建立 `REPORT_IDS` 的話，照上面第 5 步建立。
3. `pnpm run deploy`。

錄音是長輩的聲音，問題處理完請刪掉 `audio/` 下對應的檔案（git 歷史也會留著，必要時整個 repo 重建）。

## 開發

```sh
pnpm test    # vitest，GitHub API 以 mock 取代
pnpm check   # tsc
```
