# reminicare-key-api

這個 Worker 把服務的 Token 發給 iPad App。每台 iPad 只要填一次這個 Worker 的 Token，就不必再手動填其他 Token。

- **只發 Key，不轉送請求**：App 拿到 Key 後，照樣自己連成大、語音 Worker、Cloudflare 生圖 Worker。
- **發哪些**：只發 `NCKU_STT_TOKEN`、`NCKU_TTS_TOKEN`、`SPEECH_WORKER_TOKEN`、`CLOUDFLARE_IMAGE_APP_TOKEN`，而且只發有設定值的。App 端也只收這四個名稱。語言模型和 OpenAI 生圖的 Key 不經過這裡，在 App 手動填。
- **紀錄**：不記錄任何 Key 的值，console 只記筆數。

## 部署

```sh
cd key-worker
pnpm install
npx wrangler secret put APP_TOKEN                   # 新產生的長隨機字串，App 的「Key Worker Token」填這個
npx wrangler secret put NCKU_STT_TOKEN              # 以下四個依需要設定，沒設的不會發
npx wrangler secret put NCKU_TTS_TOKEN
npx wrangler secret put SPEECH_WORKER_TOKEN         # 與 speech-worker 的 APP_TOKEN 相同
npx wrangler secret put CLOUDFLARE_IMAGE_APP_TOKEN  # 與生圖 Worker 的 APP_API_TOKEN 相同
pnpm run deploy
```

App 端：在設定頁打開「從 Key Worker 取得 Key」，填 Worker 網址（預設 `https://reminicare-key-api.hding49.workers.dev`）和 Token，按「立即取得」，再按「儲存並套用」。之後每次開 App 都會自動重新取得，並覆蓋手動填的值。Worker 連不上時，沿用 iPad 上已存的值。

## 端點

| 端點 | 說明 |
|---|---|
| `GET /health` | 回 `{"ok":true}`，不需驗證 |
| `GET /v1/keys` | 需要 `Authorization: Bearer <APP_TOKEN>`，回 `{"keys":{"名稱":"值",…}}`，附 `Cache-Control: no-store`。每個 IP 每分鐘最多 10 次 |

錯誤：`unauthorized`（401，Token 錯）、`rate_limited`（429）、`misconfigured`（500，沒設 `APP_TOKEN`）。

## 外流時

App Token 外流，代表發出去的 Key 也外流了。處理方式：
1. 換掉這個 Worker 的 `APP_TOKEN`，再到各台 iPad 填新的 Token。
2. 更換被發出去的 Token：
   - 語音 Worker、生圖 Worker 的 Token 自己換，換完要同步更新本 Worker 的 secret。
   - 成大的 Token 要請實驗室換。

測試：`pnpm test`（本機可跑）。
