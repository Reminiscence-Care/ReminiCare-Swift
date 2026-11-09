# reminicare-speech-api

這個 Worker 替 iPad App 轉送雅婷語音辨識（STT）與語音合成（TTS）。設定頁語音服務選「雅婷（經 ReminiCare Worker）」時使用，這也是預設值。

- **辨識**：App 只用一般 HTTPS 送出錄音。連雅婷 WebSocket 的是 Worker，所以學校或公司網路擋 WebSocket 時，辨識還是能用。
- **Key**：雅婷 Key 只放在 Worker 的 secret。App 端只填 `APP_TOKEN`，這是可隨時更換的共用密碼。
- **紀錄**：不記錄錄音或文字，console 只有代碼、大小、時間。

## 端點

所有端點都需要 `Authorization: Bearer <APP_TOKEN>`，只有 `/health` 例外。每個 IP 每分鐘最多 20 次。

| 端點 | 說明 |
|---|---|
| `GET /health` | 回 `{"ok":true}`，不需驗證，網路檢測用 |
| `GET /v1/check` | 只向雅婷取一次 token，確認 Worker 的 Key 和額度，不送音訊 |
| `POST /v1/transcribe` | Body 是 16 kHz mono 16-bit little-endian PCM（不含 WAV 標頭），最多 10 分鐘。回 `{"text","sentences"}` |
| `POST /v1/speeches` | Body 是 `{"text","language":"taiwanese"\|"mandarin"}`，最多 1,000 字。回 `{"audioContent": base64 PCM}` |

辨識按即時速度送音訊，每 62.5 ms 送 2,000 bytes。回應時間大約等於錄音長度再加幾秒。

錯誤只回固定代碼，不轉傳雅婷的回應內容：

| 代碼 | HTTP | 意思 |
|---|---|---|
| `unauthorized` | 401 | App Token 錯誤 |
| `rate_limited` | 429 | 太頻繁 |
| `quota` | 402 | 雅婷額度用完或方案到期 |
| `upstream_auth` | 502 | Worker 的雅婷 Key 無效 |
| `upstream_rate_limit` | 429 | 雅婷限流 |
| `upstream_error` | 502 | 雅婷伺服器錯誤 |
| `upstream_invalid` | 502 | 雅婷回應格式不符 |
| `upstream_unreachable` | 502 | Worker 連不上雅婷 |
| `upstream_timeout` | 504 | 雅婷取 token 或連線就緒逾時 |
| `upstream_closed` | 502 | 辨識途中連線被關，附 `partial` |
| `timeout` | 504 | 送完音訊後等不到結果，附 `partial` |
| `invalid_audio` | 400 | 音訊格式錯誤 |
| `too_large` | 413 | 音訊太大 |
| `misconfigured` | 500 | Worker 沒設 secret |

## 部署（使用者操作）

```sh
cd speech-worker
pnpm install
pnpm exec wrangler login
pnpm exec wrangler secret put YATING_API_KEY   # 雅婷 Key
pnpm exec wrangler secret put APP_TOKEN        # 自訂一串長隨機字，App 設定頁填同一個值
pnpm run deploy
```

部署完的網址如果不是 `https://reminicare-speech-api.hding49.workers.dev`，到 App 設定頁的「語音 Worker 網址」修改。

要更換 App Token，就重新執行 `wrangler secret put APP_TOKEN`，再到每台 iPad 的設定頁更新。

Workers 免費方案每個請求的 CPU 上限是 10 ms。等待網路的時間不算在內，轉送本身用的 CPU 很少。如果 Cloudflare 後台出現 `exceededCpu`，就要改用付費方案。

## 開發

```sh
pnpm test    # vitest，雅婷 API 與 WebSocket 以 fake 取代
pnpm check   # tsc
```
