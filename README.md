# ReminiCare Swift

ReminiCare Flutter App 的 iPadOS 原生重寫版（SwiftUI，iPadOS 17 以上）。
Flutter 版在 `../ReminiCare-AI-APP`，本專案不修改它。

## 結構

- `ReminiCare/`：App 本體（SwiftUI 畫面），只支援 iPad。
- `ReminiCareKit/`：不含畫面的邏輯（Swift Package），可在 Mac 上直接測試。
  - `Config`：設定（金鑰存 Keychain，其他存 UserDefaults）與驗證
  - `AI`：OpenAI 相容 LLM、回憶問題、姓名擷取
  - `Image`：Cloudflare Worker／OpenAI 相容生圖
  - `Speech`：雅婷與成大 STT／TTS、台語備援、語音快取、WAV
  - `Audio`：錄音（靜音偵測、按停止後多錄 0.8 秒）、播放
  - `Session`：對話流程 `LifeSession`、回憶紀錄
- `Config/Info.plist`：成大服務走 HTTP，需要網路例外。

## 開發

```sh
open ReminiCare.xcodeproj           # Xcode 執行 ReminiCare scheme
cd ReminiCareKit && swift test      # 邏輯測試
```

Bundle ID `xyz.jessyu.reminicare.ipad`，可與 Flutter 版同時安裝比對。
Debug 版可加啟動參數 `-skipConfigCheck`，不填金鑰也能進入對話畫面檢查版面。

## 與 Flutter 版的差異

- 只做 iPadOS；Android、macOS、Web、Windows、Linux 不再支援。
- 沒有移植：Debug「固定測試流程」與測試音檔清單、未使用的喚醒詞設定、舊版 SharedPreferences 回憶搬移。
- 設定與回憶紀錄不會從 Flutter 版自動帶過來，需要重新輸入金鑰。
