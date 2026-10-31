# AirPods 電量規劃

- 版本：**r3**，2026-11-01。
- 狀態：**已依使用者最新介面調整要求完成並安裝**。沿用先前已核准及安裝的 AirPods 功能；本次將摘要移至頁面上方、Settings 左側，改為接近 Mac 電量的圖示與百分比樣式。
- 功能分支：`codex/airpods-battery-indicator`。
- 類別圖：[device-battery-class-diagram.mmd](device-battery-class-diagram.mmd)。
- 程式碼基準：`0395c81` 加本次功能變更；已查閱 `CODEBASE_MAP.md` 與相關實際程式碼。

## 顯示位置與使用方式

**展開 notch 後，AirPods 電量顯示於上方標頭、Settings 齒輪的左側。** Home、Shelf、Weather、AI Usage 共用；底部不再另外佔一列。

```text
┌──────────────────────────────────────────────────────────┐
│ 分頁按鈕       實體 notch 區       AirPods 圖示 40% ⚙ Mac電量 │
│ 原有分頁內容                                               │
└──────────────────────────────────────────────────────────┘
```

- 使用 AirPods 圖示與百分比，不在標頭放完整裝置名稱；字級與點擊縮放樣式沿用 Mac 電量形式。
- 上方百分比取有資料的左右耳較低值，避免平均數掩蓋低電量；只有整體電量時使用整體值。充電盒不參與摘要計算。
- 點擊仍顯示左右耳、充電盒、裝置名稱與資料時間；多組 AirPods 在詳細面板切換。標頭優先呈現已連線的一組。
- 缺值顯示 `—`；舊讀值淡化並加小時鐘標記，合法 `0%` 保留。沒有裝置時點擊可開資訊／重新整理面板。
- 移除原底部 32 pt 摘要，展開尺寸恢復 640 × 190 pt。設定開關只影響指示器與背景工作，不再調整視窗大小。
- 設定仍為「Show AirPods batteries」，預設開啟。AirPods 需連到 Mac 且藍牙保持開啟；不用開藍牙選單查看。
- 本功能只讀 AirPods，不包含 iPhone、配對或區域網路查詢。

## 核心責任與資料流

1. `AppDelegate` 啟停全 App 唯一的 `DeviceBatteryManager`，處理睡眠／喚醒與設定變更；所有視窗共用資料。
2. MainActor `DeviceBatteryManager` 管排程、請求合併、部件快取與過期狀態。
3. `XPCHelperClient` 透過既有 XPC 連線傳送 Codable request／result；兩份 protocol 同步加入 fetch／cancel，取消以 UUID 對應本次工作。
4. `BoringNotchXPCHelper` 呼叫 `DeviceBatteryProbe` actor，合併共用工作；取消個別請求不影響其他使用者或 XPC 功能。
5. `AirPodsBatteryReader` 透過 `DeviceBatteryProcess` 非同步執行系統 `/usr/sbin/system_profiler SPBluetoothDataType -json`，辨識已知 Apple AirPods 產品 ID 與已連線裝置的電量欄位。
6. `BoringHeader` 內的 `DeviceBatteryIndicator`／`DeviceBatteryPopover` 呈現 snapshot；每個視窗的 `BoringViewModel` 管理 popover 狀態與自動收合。

| 型別／區域 | 新增或修改位置 |
|---|---|
| 模型、request／result、狀態 enum | 新增 [DeviceBatteryModels.swift](../boringNotch/models/DeviceBatteryModels.swift)，兩個 target 共用；`DeviceKind` 僅包含 `airPods` |
| 排程與記憶體快取 | 新增 [DeviceBatteryManager.swift](../boringNotch/managers/DeviceBatteryManager.swift) |
| 摘要與詳細面板 | 改為 [DeviceBatteryIndicator.swift](../boringNotch/components/Battery/DeviceBatteryIndicator.swift)、[DeviceBatteryPopover.swift](../boringNotch/components/Battery/DeviceBatteryPopover.swift) |
| Helper 查詢／程序 | 新增 [DeviceBatteryProbe.swift](../BoringNotchXPCHelper/DeviceBatteryProbe.swift)、[AirPodsBatteryReader.swift](../BoringNotchXPCHelper/AirPodsBatteryReader.swift)、[DeviceBatteryProcess.swift](../BoringNotchXPCHelper/DeviceBatteryProcess.swift) |
| XPC 接線 | 修改 [client](../boringNotch/XPCHelperClient/XPCHelperClient.swift)、[App protocol](../boringNotch/XPCHelperClient/BoringNotchXPCHelperProtocol.swift)、[helper protocol](../BoringNotchXPCHelper/BoringNotchXPCHelperProtocol.swift)、[helper](../BoringNotchXPCHelper/BoringNotchXPCHelper.swift) |
| 顯示位置與生命週期 | 修改 [BoringHeader.swift](../boringNotch/components/Notch/BoringHeader.swift)、[ContentView.swift](../boringNotch/ContentView.swift)、[BoringViewModel.swift](../boringNotch/models/BoringViewModel.swift)、[AppDelegate](../boringNotch/boringNotchApp.swift) |
| 設定、尺寸、建置 | 修改 [SettingsView.swift](../boringNotch/components/Settings/SettingsView.swift)、[Constants.swift](../boringNotch/models/Constants.swift)、[matters.swift](../boringNotch/sizing/matters.swift)、[project.pbxproj](../boringNotch.xcodeproj/project.pbxproj)；保留藍牙 usage description，移除本功能的區域網路 usage description |

既有 `BatteryActivityManager`、`BatteryStatusViewModel`、`BoringBatteryView` 仍只處理 Mac 電池。`showDeviceBatteries` 切換指示器與背景更新；移除前版專用的動態尺寸更新。

## 資料與生命週期保證

- 百分比只接受 0–100，缺值不推測。左右耳與盒子分開保存；盒子缺值不能沿用耳機的最新時間。
- 系統回報是快取，未提供裝置真正採樣時間：`sourceUpdatedAt = nil`、`provenance = systemCache`；畫面區分最後查詢時間與未知的裝置更新時間。
- 沒有明確充電資料時使用 `unknown`，不由電量變化推測充電中。斷線或失敗立即標舊，10 分鐘後顯示 `—`；重啟不載入舊快取。
- 啟用立即查詢，正常每 60 秒一次；失敗退避至最多 300 秒，手動重試至少間隔 15 秒。
- Helper 程序期限 12 秒、輸出上限 1 MiB；取消／逾時終止並回收子程序。App XPC 等待另有 18 秒期限，不重設共用連線。
- 睡眠／退出／停用停止排程與工作；generation token 阻止晚到結果重新填入已停用的畫面。
- 不搶連線、不切換音訊、不加入低電量通知；耳機連到其他裝置、離線或盒蓋關閉時，可能沒有新讀值。

## 驗收與驗證紀錄

### r3 上方指示器

- Swift 6 Debug／已簽署 Release 建置成功；36 項 reader／process 與 24 項 manager 檢查通過，新增較低耳摘要、排除盒子、整體讀值與缺值驗證。
- 實際 `BoringHeader` 渲染確認 AirPods／Mac 電量並排、鏡頭與 Settings／分頁全開時保留中間 185 pt notch 空間；未知讀值及詳細面板顯示正常。
- r3 Mermaid 已解析並渲染：`/private/tmp/boring-notch-device-battery-r3.svg`；23 個計劃連結與 `git diff --check` 通過。
- 已備份並替換 `/Applications/Boring Notch.app`；新舊簽署 designated requirement 相同，安裝後 App／helper 雜湊與 Release 一致。
- 實際 App 驗證：AirPods 按鈕位於 Settings 左側，顯示 34%；點擊面板顯示左耳 34%、右耳 35%、充電盒 80%。底部摘要已移除、展開恢復原高度。這些數值為當次系統回報。
- r3 安裝前備份：`/Users/adrianli/Library/Application Support/BoringNotch/Backups/Boring Notch-before-AirPods-header-20261101-002703.zip`。

### r2 已完成的資料讀取與安裝驗證

- 資料／程序：[DeviceBatteryProbeChecks.swift](../Tests/DeviceBatteryProbeChecks.swift)，涵蓋 AirPods 識別、左右耳／盒子、有效 0%、格式錯誤、快取期限、輸出上限、硬逾時及子程序回收。
- 排程：[DeviceBatteryRegressionChecks.swift](../Tests/DeviceBatteryRegressionChecks.swift)，涵蓋共用請求、更新／重試門檻、部件獨立過期、停用取消與晚到回覆。
- XPC：[XPCRegressionChecks.swift](../Tests/XPCRegressionChecks.swift)，使用真實 anonymous XPC 檢查編解碼、取消、晚到回覆與共用連線。
- 執行方式：`bash scripts/check-device-batteries.sh /path/to/Build/Products/Debug`、`bash scripts/check-concurrency.sh /path/to/Build/Products/Debug`。
- r2 驗證：Swift 6 Debug／已簽署 Release 建置成功；Release deep／strict signature 驗證成功。兩種產物均未包含 iPhone 工具或 runtime。
- 自動檢查：32 項 reader／process、24 項 manager、71 項並行／月曆／XPC、52 項音量回呼檢查通過。另通過 `git diff --check`、plist lint、shell 語法檢查與 22 個計劃內連結檢查。
- 實機：已簽署且啟用 sandbox 的測試 App → 本次 Release 正式 XPC helper → 系統報告，成功讀到 1 組 AirPods，當次左耳 42%、右耳 42%、充電盒 80%；未開啟藍牙選單。這是當次系統回報，不代表現在仍為相同百分比。
- UI：以實際 SwiftUI 元件渲染 576／496 pt 摘要、AirPods 詳細、資訊與舊資料面板；已目視檢查主要排版與文字。
- Mermaid：使用既有 `mmdc` 成功解析／渲染 r2，產物為 `/private/tmp/boring-notch-device-battery-r2.svg`。
- 交付：2026-11-01 依使用者要求替換 `/Applications/Boring Notch.app` 並重新啟動；App／helper 與原版 designated requirement 一致，簽署及安裝檔雜湊驗證通過。
- 安裝後 UI 驗證：實際展開 Home 分頁，底部已顯示 AirPods 左耳 40%、右耳 41%；App 與 helper 均持續執行。
- 舊版備份：`/Users/adrianli/Library/Application Support/BoringNotch/Backups/Boring Notch-before-AirPods-20261101-001452.zip`。
- 邊界：尚未在 macOS 14／Intel、所有 AirPods 型號與完整多螢幕滑鼠互動情境實機驗證。
