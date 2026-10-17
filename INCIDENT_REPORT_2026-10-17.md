# Boring Notch 音訊通知造成程式崩潰事故報告

事故確認日期：2026-10-17，時區 Asia/Taipei。

交付日期：2026-10-18。程式修正、重新安裝與測試在 10 月 17 日完成，跨日完成分支推送與文件交付。

Boring Notch 在接收音量、靜音或預設音訊輸出裝置通知時，可能因 Swift 6 的 actor 隔離檢查而終止。六份本機崩潰報告均指向 `VolumeManager.setupAudioListener()`。修正將四處 CoreAudio listener 的派送佇列指定為主佇列，讓系統進入 Swift 回呼時就符合 `MainActor` 的要求。

## 使用者遇到的情況與影響

使用者回報 App 有時自行關閉，需要重新啟動「應用程式」中的 Boring Notch。這些紀錄顯示整個主程序崩潰，會中斷瀏海介面及其背景更新。開啟登入時啟動或補授權，無法修正這個回呼隔離錯誤。

紀錄所指的執行檔為 `/Applications/Boring Notch.app/Contents/MacOS/Boring Notch`，版本 `2.7.3`、build `271`。最新事故執行檔 UUID 為 `FB1FD644-B7D5-3CB2-87C6-6A4E2CA92908`，與診斷時已安裝的 App 一致。

## 崩潰證據

來源為 `~/Library/Logs/DiagnosticReports/` 中六份 `Boring Notch-*.ips`。下表使用報告內的 `captureTime`；檔名時間可能較晚，因為系統在崩潰後才寫入報告。

| 崩潰時間 UTC+8 | 報告檔名 | 崩潰位置 |
|---|---|---|
| 2026-10-12 23:21:06 | `Boring Notch-2026-10-12-232138.ips` | `VolumeManager.setupAudioListener()` |
| 2026-10-13 00:08:42 | `Boring Notch-2026-10-13-000845.ips` | 同上 |
| 2026-10-13 23:57:49 | `Boring Notch-2026-10-13-235752.ips` | 同上 |
| 2026-10-17 17:16:56 | `Boring Notch-2026-10-17-171658.ips` | 同上 |
| 2026-10-17 22:22:40 | `Boring Notch-2026-10-17-222244.ips` | 同上 |
| 2026-10-17 23:07:52 | `Boring Notch-2026-10-17-230755.ips` | 同上 |

六份報告具有相同的關鍵特徵：

- 異常：`EXC_BREAKPOINT`／`SIGTRAP`。
- 終止原因：`Trace/BPT trap: 5`。
- 崩潰佇列：`com.apple.root.default-qos`。
- 呼叫堆疊經過 `_dispatch_assert_queue_fail`、`_swift_task_checkIsolatedSwift`、`VolumeManager.setupAudioListener()` 的 closure，以及 CoreAudio 的 `HALPropertyListener::Call`。

報告指出音訊通知回呼的位置，但沒有記錄使用者當時的具體硬體操作。調整音量、靜音、切換輸出裝置屬於相關通知的觸發範圍；不能據此斷言每次事故都是插拔耳機造成。

## 根本原因

2026-10-03 的 `06a8061`（`Customize calendar, music, weather, and Swift 6 Support`）將 `VolumeManager` 標記為 `@MainActor`，並在 CoreAudio listener block 裡加入 `Task { @MainActor ... }`。

原本的 listener 註冊仍傳入 `nil` dispatch queue。依 CoreAudio 介面規則，queue 為 `NULL` 時，系統可以直接在通知來源執行緒呼叫 block。建立於 `@MainActor` 環境的 block 帶有 actor 隔離要求；Swift 6 在 C／Swift 橋接回呼入口檢查當前執行環境。當 CoreAudio 從背景佇列進入這個 block，就會先觸發隔離檢查並終止，尚未執行到內部的 `Task`。

```text
CoreAudio 背景通知
  → 呼叫在 MainActor 環境建立的 Swift block
  → block 入口的執行期隔離檢查失敗
  → SIGTRAP，主 App 終止
  → block 內的 Task 尚未執行
```

這是先前 Swift 6 遷移留下的回呼邊界問題。目前這六份報告的崩潰堆疊沒有指向 Claude／Codex 用量功能。

先前建置及回歸檢查沒有涵蓋 CoreAudio 從 C 端背景執行緒呼叫 Swift block 的情境，所以即使編譯與其他功能測試通過，仍未攔截這個執行期錯誤。

參考：[Apple CoreAudio listener API](https://developer.apple.com/documentation/coreaudio/audioobjectaddpropertylistenerblock(_:_:_:_:))、[Swift 6 遷移與動態隔離](https://www.swift.org/migration/documentation/swift-6-concurrency-migration-guide/incrementaladoption/)。本機 SDK 的 `AudioHardware.h` 也明確描述 `NULL` queue 的直接呼叫行為。

## 修正方式

修改 [VolumeManager.swift](boringNotch/managers/VolumeManager.swift) 的 `setupAudioListener()`，將以下四處 `AudioObjectAddPropertyListenerBlock` 的 queue 由 `nil` 改為 `.main`：

1. 預設音訊輸出裝置變更。
2. 主音量變更。
3. 個別聲道音量變更，涵蓋沒有主音量 property 的裝置。
4. 靜音狀態變更。

```swift
AudioObjectAddPropertyListenerBlock(deviceID, &masterAddr, .main) { [weak self] _, _ in
    Task { @MainActor [weak self] in self?.fetchCurrentVolume() }
}
```

修正讓 CoreAudio 先把通知排到主佇列，Swift block 入口與後續 UI 狀態更新都符合既有的 `MainActor` 限制。保留原有讀取、發布與音量控制邏輯，以及 Swift 6 的並行檢查。

## 回歸測試與驗證

新增 [VolumeListenerRegressionChecks.swift](Tests/VolumeListenerRegressionChecks.swift)、[C fixture](Tests/Fixtures/VolumeListenerFixture.c) 與 [執行腳本](scripts/check-volume-listeners.sh)，並接入既有的 [check-concurrency.sh](scripts/check-concurrency.sh)。

測試直接編譯正式 `VolumeManager.swift`，保留 CoreAudio 的 C 宣告與 block 橋接；只有測試執行檔連結到模擬的 C 函式，不會更動真實硬體或系統音量。通知由背景佇列送出，並依正式程式註冊的 queue 執行回呼。純 Swift 的函式替身會略過這個橋接檢查，因此不足以驗證本次事故。

| 驗證項目 | 結果 |
|---|---|
| 舊版來源負向對照 | 重現 `SIGTRAP`，shell 結束碼 133；堆疊同樣指向 `_dispatch_assert_queue_fail` 與 `VolumeManager.setupAudioListener()` |
| 修正後 `-Onone` | 主音量 12 項、左右聲道 fallback 14 項通過 |
| 修正後 `-O` | 主音量 12 項、左右聲道 fallback 14 項通過 |
| 合計 | 52 項音訊回呼檢查通過 |
| 完整 Debug／Release | 均 `BUILD SUCCEEDED`；無 Swift／linker 警告，保留既有 AppIntents metadata 略過提示 |
| 既有並行／月曆／XPC 等回歸 | 66 項通過 |
| 天氣回歸 | 66 項通過 |
| Codex 用量 | probe 43 項、manager／history 45 項通過 |
| Claude 用量 | parser／transport 53 項、manager／cache 34 項通過；另確認 XPC helper 的 `JoinExistingSession` 設定 |
| 自動檢查總計 | 359 項通過（52 + 66 + 66 + 43 + 45 + 53 + 34） |
| Release 簽章與安裝副本 | `codesign --verify --deep --strict` 通過；已安裝執行檔 SHA-256 與建置產物一致 |
| 啟動檢查 | 23:54 安裝並重新啟動，23:58 確認主 App／helper 仍在執行，沒有新增主 App 崩潰報告 |
| 檔案格式 | `git diff --check`、兩個測試腳本的 `bash -n` 通過 |

測試包含音量更新、靜音／取消靜音、預設輸出裝置切換後讀取新裝置的值，以及更新對外發布狀態和時間戳。測試不涵蓋真實藍牙／USB 裝置切換及長時間連續運行。

本次工具鏈為 Xcode `27.1 (27A9275)`、Apple Swift `6.4`；事故報告的系統版本為 macOS `27.0.1 (26A434)`，架構 arm64。主 App 保持 Swift 6 language mode。

完整 App 建置使用 `boringNotch.xcodeproj`／`boringNotch` scheme、`platform=macOS,arch=arm64`、鎖定的 `Package.resolved`；Debug 使用 `CODE_SIGNING_ALLOWED=NO`，Release 保留本機 ad-hoc 簽署。針對實際 Debug module 執行 `check-concurrency.sh`、`check-weather.sh`、`check-codex-usage.sh`、`check-claude-usage.sh`；沒有更新套件鎖定版本。

重跑音訊檢查：

```bash
bash scripts/check-volume-listeners.sh
```

負向對照可使用 `VOLUME_MANAGER_SOURCE=/path/to/old/VolumeManager.swift` 指定舊來源。舊版預期造成獨立測試程序崩潰，不能用正在執行的主 App 進行此測試。

## 分支與交付

先執行 `git fetch origin` 確認：`codex/next-feature` 為 `34d88ab`，`main`／`origin/main` 為 `64b5459`，沒有 `master`。功能分支包含 main 全部內容並多出七個 commit；先前 `8f9b524` 是把 upstream/main 合入功能分支，並非把功能合回 main。

依使用者同意的流程，從 `codex/next-feature` 建立 `codex/fix-audio-listener-crash`。修正提交為 `60a77e1`（`Fix MainActor crashes in CoreAudio volume callbacks`），文件另行提交。驗證後以 fast-forward 將整個修復分支納入自己的 `main`，保留原先七個 commit 及本次修正的完整歷史；原作者的 `upstream` 不變。

更新後的分支用途與同步流程見 [FORK_SYNC_GUIDE.md](FORK_SYNC_GUIDE.md)。`main` 作為個人化版本基準，後續功能從它另開分支。

本機 main 已由 `64b5459` fast-forward 至包含修正與文件的 `4678aab`。命令列 push 因沒有可用的 HTTPS 認證而失敗，改用已登入的 GitHub Desktop 成功推送到 `ariel055132/boring.notch`；沒有變更帳號憑證或強制推送。後續文件補充同樣保存於 main。

2026-10-17 23:54 已替換 `/Applications/Boring Notch.app`。舊版完整保留在 `~/Downloads/Boring Notch before audio fix 2026-10-17.app`；必要時先結束新版，再用該備份取代應用程式副本。回復舊版也會回到本次已確認的音訊崩潰風險。

已安裝新版的識別資料：

- 執行檔 UUID：`DF0AED38-004C-305D-95B9-EC62D9F7BE19`。
- 執行檔 SHA-256：`f3718e61b1e0ffed2647e343891c65a3255c9faea63bebf5ddf8a523a260cf0e`。
- 版本號仍為 `2.7.3 (271)`；辨識此次本機修正應使用提交、UUID 或雜湊，不能只看版本號。

## 追加確認：Helper 的鑰匙圈密碼提示

安裝後，使用者另詢問 `BoringNotchXPCHelper` 偶爾要求密碼，並確認提示要存取的是 `Claude Code-credentials`。來源是既有 Claude 用量功能的 Keychain 讀取，與主 App 的 CoreAudio 崩潰不同。

比對備份與新版 helper，兩者都使用本機 ad-hoc 簽章，指定需求以各自的 `cdhash` 辨識：舊版為 `9ef399fc6dee93343ee6be002f9289c33de1f50f`，新版為 `2a50b7f61efc3345ac292f3ca6b780832c081c23`。此識別變化可解釋更新後再次要求授權；不能單憑它解釋所有過往的重複提示。

依 [Apple 鑰匙圈說明](https://support.apple.com/zh-tw/guide/keychain-access/kyca1243/mac)，單次允許只適用於當次讀取；使用者若信任該功能並希望持續授權，可自行在系統提示選擇「永遠允許」。[Apple 的簽章需求說明](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements)指出 ad-hoc 指定需求綁定特定程式版本，因此之後重新建置仍可能重新授權。

目前 [ClaudeUsageManager](boringNotch/managers/ClaudeUsageManager.swift) 每五分鐘檢查用量；背景請求的 `allowKeychainPrompt` 預設為 `false`，只有手動 `connect()` 設為 `true`。[ClaudeUsageKeychain.read](BoringNotchXPCHelper/ClaudeUsageProbe.swift) 用 `LAContext.interactionNotAllowed` 表達背景讀取不允許互動的意圖。本次沒有修改 Keychain ACL、簽章策略或該讀取流程，也沒有重現「同一版本已永遠允許卻仍持續彈窗」；若該情形存在，需要另行追查。

## 後續觀察

此次已用負向對照確認原缺陷，並通過修正後回歸與短時間實機啟動；尚不能把幾分鐘的觀察視為長時間穩定性保證。後續若仍自行關閉，應比對新報告的執行檔 UUID 與崩潰堆疊，確認是否為同一版本及同一原因。

本次對話另存於 [CONVERSATION_LOG_2026-10-17.md](CONVERSATION_LOG_2026-10-17.md)。
