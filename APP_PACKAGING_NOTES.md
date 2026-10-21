# Boring Notch 本機打包與啟動問題紀錄

整理日期：2026-10-04（Asia/Taipei）。

本文件整理這次將專案安裝為獨立 macOS App 的對話、診斷與實際處理結果，並非逐字稿。驗證結果代表當次操作狀態。

## 1. 原始需求

使用者詢問：

> 幫我看一下要怎麼才能夠把這個 project 打包成 Application，目前每一次都要 build and run 才有相關程式出現。

檢查後確認，Xcode 每次建置就會產生完整的 `Boring Notch.app`，不必每次透過 Xcode 執行。將可正常獨立啟動的 App 複製到 `/Applications`，即可從 Finder 開啟。

| 位置／版本 | 用途 |
| --- | --- |
| Debug 建置資料夾 | 開發與除錯使用的 App |
| Release 建置資料夾 | 日常使用建議採用的建置版本 |
| `/Applications/Boring Notch.app` | 安裝後實際啟動的副本，不是第三種建置組態 |

自用只需要完整的 `.app`。`.dmg` 是方便分享與安裝的封裝，不是獨立啟動的必要條件。專案已有 `Configuration/dmg/create_dmg.sh`，本次未製作 DMG。

最初提供的操作方式：

1. 在 Xcode 的 **Product → Scheme → Edit Scheme → Run → Info**，將 **Build Configuration** 設為 **Release**。
2. 按 `⌘B` 建置。
3. 在左側 **Products** 找到 `Boring Notch.app`，使用 **Show in Finder** 找到產物。
4. 結束舊版 App，將新 App 複製到「應用程式」。

這個初步建議漏了檢查獨立啟動時的簽章限制；後續診斷與修正如下。

## 2. 問題：應用程式裡的 App 開啟後沒有反應

使用者回報：

> 目前 release , debug , application 均有一個 Boring Notch.app，但我啟動 application 的卻沒反應，是正常的嗎？

Boring Notch 主要顯示在瀏海與選單列，沒有跳出一般主視窗本身不代表故障。但本次有明確的啟動崩潰紀錄，並非正常背景執行，也不是三份同名 App 造成的問題。

診斷紀錄：

```text
~/Library/Logs/DiagnosticReports/Boring Notch-2026-10-04-135349.ips
```

2026-10-04 13:53:49 的紀錄指出，崩潰程式來自：

```text
/Applications/Boring Notch.app/Contents/MacOS/Boring Notch
```

關鍵錯誤：

```text
Library not loaded: @rpath/Sparkle.framework/Versions/B/Sparkle
code signature ... not valid for use in process
mapping process and mapped file (non-platform) have different Team IDs
```

### 實際原因

`Sparkle.framework` 是自動更新套件。雖然錯誤分類顯示 `Library missing`，檔案實際存在；macOS 是因為簽章驗證拒絕載入它。

檢查發現：

- 主 App 與 Sparkle 使用 ad-hoc 簽章，`TeamIdentifier` 都是 `not set`。
- 專案 Debug 與 Release 都設定 `ENABLE_HARDENED_RUNTIME = YES`。
- 原本沒有 `com.apple.security.cs.disable-library-validation` 權限。
- App 在載入 Sparkle 時就終止，尚未進入正常介面流程。

即使 `codesign --verify --deep --strict` 通過，也只代表簽章結構驗證通過，不能單獨證明執行時的函式庫載入政策允許啟動。本次因此也做了實際啟動測試。

## 3. 實際修正

使用者表示找不到 **Signing & Capabilities**，並授權直接處理。

修改檔案：[boringNotch/boringNotch.entitlements](boringNotch/boringNotch.entitlements)。

加入以下內容：

```xml
<!-- Allow embedded frameworks when the app is signed ad hoc for local use. -->
<key>com.apple.security.cs.disable-library-validation</key>
<true/>
```

這相當於在 Xcode 的 **Signing & Capabilities → Hardened Runtime → Runtime Exceptions** 勾選 **Disable Library Validation**，保留 Hardened Runtime，放寬其函式庫簽章驗證限制。

此修改位於 Debug 與 Release 共用的 entitlements 檔案，因此兩種組態之後重新建置都會套用；它不是只作用於某一份已安裝 App 的臨時修改。

這次目的是讓本機 ad-hoc 簽署版本可獨立執行。正式發佈時，應重新評估是否需要保留這個例外，並優先使用相同開發團隊的適當簽章處理 App 與內含套件。

參考：[Apple — Disable Library Validation Entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.cs.disable-library-validation)。

## 4. 重新建置與安裝

本次在專案根目錄執行以下 Release 建置命令；其中快取與套件路徑是當時這台電腦的路徑，換機時需調整：

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild \
  -project boringNotch.xcodeproj \
  -scheme boringNotch \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/boring-notch-swift6-build \
  -clonedSourcePackagesDirPath /Users/adrianli/Library/Developer/Xcode/DerivedData/boringNotch-gkjxymzqfwilkwdxpsxyhoaplgpd/SourcePackages \
  -disableAutomaticPackageResolution \
  -skipPackageUpdates \
  build > /tmp/boring-notch-local-app-build.log 2>&1
```

第一次執行因沙盒禁止寫入 Xcode／Swift 套件快取而失敗；取得沙盒外執行授權後，重新建置成功。此次保留程式碼簽署，沒有使用 `CODE_SIGNING_ALLOWED=NO`。

產物位置：

```text
/tmp/boring-notch-swift6-build/Build/Products/Release/Boring Notch.app
```

安裝前確認簽章與權限：

```bash
codesign --verify --deep --strict \
  '/tmp/boring-notch-swift6-build/Build/Products/Release/Boring Notch.app'

codesign -d --entitlements - \
  '/tmp/boring-notch-swift6-build/Build/Products/Release/Boring Notch.app'
```

原本規劃先備份 `/Applications` 裡的舊版，但執行備份時，舊 App 已不在原位置，命令因此停止，沒有完成備份。對話中沒有確認舊版消失的原因。

確認原位置不存在後，取得授權安裝新版，執行：

```bash
ditto \
  '/tmp/boring-notch-swift6-build/Build/Products/Release/Boring Notch.app' \
  '/Applications/Boring Notch.app'

codesign --verify --deep --strict '/Applications/Boring Notch.app'
open '/Applications/Boring Notch.app'
```

## 5. 驗證結果

| 檢查項目 | 當次結果 |
| --- | --- |
| Entitlements plist 語法 | `plutil -lint` 通過 |
| Release 建置 | `BUILD SUCCEEDED` |
| 建置產物與安裝副本的簽章 | `codesign --verify --deep --strict` 通過 |
| 修正權限 | 在產物簽章中確認 `disable-library-validation = true` |
| 獨立啟動 | 從 `/Applications/Boring Notch.app` 啟動成功 |
| 程序存活 | 啟動約 5 秒後確認程序仍在執行，當時 PID 為 `15861` |
| 崩潰紀錄 | 檢查時沒有新增 Boring Notch 崩潰紀錄 |
| 修改格式 | `git diff --check` 通過 |

驗證範圍為建置、簽章與短時間獨立啟動；沒有在這次操作中逐一測試所有功能或長時間穩定性。沒有進行正式發佈、公證或 DMG 製作。

## 6. 後續使用方式

- 直接從「應用程式」開啟 **Boring Notch**，不必開 Xcode。
- App 主要出現在瀏海與選單列，不會跳出一般主視窗。
- 如需登入時啟動，可在 App 設定開啟 **Launch at login**；本次未代為變更此選項。
- 修改程式碼後，重新建置 Release，再結束舊版並替換 `/Applications/Boring Notch.app`；已安裝副本不會因 Xcode 建置自動更新。
- `/tmp` 下的產物與日誌是暫存檔，不應當作永久備份；修正本身已保存在專案的 entitlements 檔案。

## 7. 本機固定簽署身分與 Claude Keychain 授權

2026-10-22 新增可攜的本機簽署設定。ad-hoc 簽章的 designated requirement 綁定特定版本；重新編譯 XPC helper 後，Keychain 可能無法將新版視為已授權的同一個程式。固定憑證與程式識別碼可讓授權跨版本延續。[Apple TN3127](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements)

Project 的 Debug／Release 共用 [Configuration/LocalBuild.xcconfig](Configuration/LocalBuild.xcconfig)，預設保留 `-` ad-hoc 簽署與 `Automatic`。此檔案最後會選擇性載入同資料夾的 `LocalSigning.xcconfig`；後者已加入 `.gitignore`，不會將個人簽署設定帶到其他電腦。App 與 XPC helper 的兩種組態都使用同一組變數。

有可用的固定 code-signing identity 時，在 `Configuration/LocalSigning.xcconfig` 設定：

```xcconfig
BORING_NOTCH_CODE_SIGN_IDENTITY = 憑證的40位SHA1指紋
BORING_NOTCH_CODE_SIGN_STYLE = Manual
```

指紋可由 `security find-identity -p codesigning` 取得；填入實際憑證指紋，並保留對應的私鑰供後續建置使用。此設定檔只記錄簽署身分選擇，不存放私鑰或 Claude credentials，也不更改 Keychain ACL、信任設定或 entitlements。正式 Apple 簽署身分仍須依其條件設定相應的 Development Team。

本機自用可使用 [scripts/setup-local-signing.py](scripts/setup-local-signing.py) 建立或沿用專用簽署身分。腳本會先以不同測試程式驗證同一簽署身分產生相容的 designated requirement，成功後才寫入上述設定；不將私鑰或憑證內容寫入 repository。

重新建置與安裝時須保留簽署，不使用 `CODE_SIGNING_ALLOWED=NO`。第一次從 ad-hoc 切換成固定簽章後，仍需在 Claude 用量頁按 Connect，於系統提示選擇「永遠允許」。之後每次建置使用同一身分，背景更新沿用該授權；背景讀取仍禁止顯示授權視窗。若 Claude Code 登出後重建 credential 項目、使用者移除授權或更換簽署身分，仍可能需要再次 Connect。

後續本機更新應保留 `Configuration/LocalSigning.xcconfig` 與 login Keychain 內的同一簽署身分，照原有 Debug／Release 建置流程執行即可；不需每次重建憑證。重新安裝前，確認 App／helper 仍由原憑證簽署，避免移除本機設定後回退為 ad-hoc。

建置完成後可檢查實際 helper 的 designated requirement，確認以憑證身分識別，而非只有 `cdhash`，再驗證整包簽章：

```bash
codesign -d -r- '/path/to/Boring Notch.app/Contents/XPCServices/BoringNotchXPCHelper.xpc'
codesign --verify --deep --strict '/path/to/Boring Notch.app'
```

2026-10-22 本機驗證：已在 login Keychain 建立並重用 `Boring Notch Local Signing`，沒有修改系統信任設定。setup 使用兩個內容不同的暫存程式確認相同 designated requirement 與不同 CDHash，並驗證重跑沿用原身分。私鑰以不可匯出、僅授權 `/usr/bin/codesign` 的方式匯入；暫存私鑰隨即移除，repo 只保存建置入口。

Debug／Release 建置、Claude 135 項、Codex 88 項、並行 66 項及音訊 listener 52 項檢查全部通過。正式 App 與 helper 均以固定憑證簽署，整包 `codesign --verify --deep --strict` 通過。00:24 已安裝並重新啟動 `/Applications/Boring Notch.app`，當次 App PID 為 `47712`、helper PID 為 `47727`；前版保留為 Downloads 的 `Boring Notch before persistent signing 2026-10-22.app`。

2026-10-22 00:25:00.731（Asia/Taipei）的 `securityd` 紀錄確認使用者已對安裝版 helper 選擇 `always allow`。隨後 00:25:00.750 的非互動讀取紀錄為 LAContext `1000 = 1`，00:25:01.405 收到 HTTP 200，確認授權後首次 Claude 用量查詢成功。

00:28:28 完成授權後重啟，App PID 由 `47712` 變為 `47870`，helper PID 由 `47727` 變為 `47882`。新 helper 在 00:28:27.977 執行非互動啟動身分確認（LAContext `1000 = 1`）；00:30:02.408 原本的五分鐘背景輪詢再次非互動讀取，00:30:03.076 收到 HTTP 200。從此次重啟到該次輪詢完成，系統紀錄沒有 Keychain prompt、再次授權或存取拒絕事件，已完成重啟與五分鐘定時背景更新驗證；此結果不代表已驗證長時間運作、睡眠喚醒或 credential 項目重建。

本次建置、測試與安裝紀錄位於 `/tmp/boring-notch-persistent-signing/`。午夜後原 `/tmp` 套件 checkout 檔案不完整，已逐一核對 12 組 `Package.resolved` revision，改用 Xcode 既有且 revision 相同的 SourcePackages；未更新依賴版本。
