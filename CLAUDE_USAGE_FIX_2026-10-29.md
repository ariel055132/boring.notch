# Claude Usage：登入資料更新後反覆要求 Connect 的修復

- 日期：2026-10-29（Asia/Taipei）
- 分支：`codex/fix-claude-usage-token-rotation`
- 修改基準：`1a8f761`，延續既有固定簽章與背景互動控制修復。
- 交付：修正程式碼、回歸測試、說明文件及可直接使用的 macOS App。

## 問題與原因

Claude 用量頁原先能正常更新，但過一段時間又回到 **Connect Claude Code**，即使已在 Keychain 選過「永遠允許」。

這次確認安裝版仍使用同一固定簽章，helper 也仍在 Keychain 的一般信任清單。真正失效的是另一層 **partition ACL**：本機 Claude Code 2.1.308 透過 `/usr/bin/security add-generic-password -U` 更新 token 時，macOS 會保留一般授權、重建 partition ACL。更新後只剩 `apple-tool:`，自簽 helper 因此被拒絕。

實機 securityd 紀錄出現 `ACL partition mismatch`；隔離假憑證測試也重現「普通信任清單不變，但原生讀取回傳 `-25293`」。先前固定簽章的修復沒有被覆蓋，而是未涵蓋這個憑證輪替情況。

Apple 實作參考：[ItemImpl::updateSSGroup](https://github.com/apple-oss-distributions/Security/blob/main/OSX/libsecurity_keychain/lib/Item.cpp)、[partition 身分分類](https://github.com/apple-oss-distributions/Security/blob/main/securityd/src/clientid.cpp)。

## 調整內容

| 範圍 | 修改與結果 |
|---|---|
| 憑證讀取 | 保留原生非互動讀取；只有 `.permissionRequired` 才嘗試系統工具備援，登入不存在或其他錯誤不隨意切換讀取方式。 |
| 背景授權檢查 | 只讀 metadata，確認唯一 Claude credential、實際 account／keychain 路徑、鑰匙圈已解鎖且可讀、`/usr/bin/security` 已在 decrypt 信任清單、沒有強制提示條件，且 partition 包含精確的 `apple-tool:`。 |
| 系統工具備援 | 固定執行 `/usr/bin/security find-generic-password`，不經 shell。背景檢查失敗就不啟動；只有明確 Connect 可請求新授權。 |
| 憑證資料邊界 | 原始資料只經匿名 pipe 進入 helper 記憶體；stderr 丟棄，不將 token 寫檔、寫 log 或傳入主 App。限制輸出大小，並處理程序 exit、EOF、逾時及取消。 |
| 並行控制 | 原生讀取與 metadata 查詢共用互動開關／鎖；成功或失敗都恢復原本狀態。憑證讀取改為 async，等待子程序時不阻塞 Swift concurrency 執行緒。 |
| 提示文字 | 改為提示解鎖 login keychain，或 Connect 允許系統工具讀取；移除「永遠允許就能永久自動更新」的保證。 |
| 更新方式 | 保留每五分鐘獨立查詢、HTTP 冷卻、限流退避、帳號指紋與快取期限。OAuth token 的續期仍由 Claude Code 管理。 |

主要程式碼：

- [ClaudeUsageProbe.swift](BoringNotchXPCHelper/ClaudeUsageProbe.swift)：原生讀取、共用互動保護與 async 接線。
- [ClaudeUsageSecurityPreflight.swift](BoringNotchXPCHelper/ClaudeUsageSecurityPreflight.swift)：metadata 查詢及嚴格授權條件。
- [ClaudeUsageSecurityCommand.swift](BoringNotchXPCHelper/ClaudeUsageSecurityCommand.swift)：備援選擇、固定子程序與資料生命週期。
- [ClaudeUsageModels.swift](boringNotch/models/ClaudeUsageModels.swift)：權限提示與互動語意說明。

## 驗證

| 項目 | 結果 |
|---|---|
| Xcode Debug／Release | 通過；Release 沿用原本固定簽署身分。僅保留既有 AppIntents metadata 提示。 |
| Claude native／parser／HTTP | 103 項通過。 |
| Metadata preflight | 46 項通過，涵蓋鎖定、缺授權、錯誤路徑、錯誤 partition、破損資料及不唯一 partition ACL。 |
| 子程序／備援流程 | 58 項通過，涵蓋超量輸出、非零 exit、EOF 順序、秘密不外洩、逾時、取消、強制清理及禁止未授權背景啟動。 |
| Manager／cache | 34 項通過；Claude 總計 **241 項**。 |
| 並行／XPC、音訊 listener | 分別 66 項、52 項通過。 |
| 隔離 Keychain 輪替 | 成功重現 partition 重設，舊讀取失敗，系統工具能讀到更新後的假資料；鎖定／解鎖及完整清理通過。 |
| 真實安裝版 | 00:54:54 與下一次五分鐘排程 00:59:54 均收到 HTTP 200；觀察期間沒有 Keychain prompt，無須再次 Connect。 |

離線檢查（先建置 Debug）：

```sh
bash scripts/check-claude-usage.sh /path/to/DerivedData/Build/Products/Debug
bash scripts/check-concurrency.sh /path/to/DerivedData/Build/Products/Debug
```

真實 macOS Keychain 整合檢查採明確 opt-in：

```sh
python3 scripts/check-claude-keychain-rotation.py --run
```

整合測試只在 `~/Library/Keychains` 建立 UUID 專用臨時鑰匙圈與假資料，測完清除自己的項目及檔案；不操作真實 Claude 或 login credential。`/tmp` 新建的鑰匙圈不會啟用相同的 partition 保護，不能替代此測試。

## 已知限制

`security` CLI 沒有禁止互動的旗標。前置檢查與實際讀取並非原子操作：如果外部程序在兩者之間鎖定 Keychain 或修改授權，仍可能出現系統提示。因此這次修復不宣稱「絕不彈窗」。一般可信程式路徑檢查也不等於完整的 stored signing requirement 驗證。

修復處理的是 token 輪替後的 Keychain 存取失效，沒有自行更新 refresh token，也沒有更動 Claude Code 設定或真實 credential ACL。若 Claude Code 登入本身過期，仍需由 Claude Code 更新登入。

## App 交付與舊版清理

- 可直接使用的 App：`/Applications/Boring Notch.app`。
- 最新安裝包：`~/Downloads/Boring Notch - Claude Usage Fix 2026-10-29.zip`；解壓即為 `Boring Notch.app`。
- 版本沿用 `2.7.3`／build `271`；本次以包裝日期及下列 helper SHA-256 識別修正版。
- Helper SHA-256：`de578dda664eb499ca686e3d02a2fa13b16e814163b10bae45111bc7a8cfb997`。
- ZIP SHA-256：`a948d8c6dcea319f797f31a7eaf1214b3b5feff706b27710aafe7a4e7c82d10c`；大小 8,684,321 bytes，解壓簽章與主程式／helper 內容核對通過。
- App 使用本機固定簽章，適用於這台 Mac；不是經 Apple 公證的公開發行包。App、ZIP、憑證與個人簽署設定不納入 Git 提交。
- 已將修正前的暫存備份及 10/12 的舊 Xcode App 產物移到垃圾桶。最新版安裝包、現用 App 與本次建置產物保留。

包裝與舊版清理結果於交付時記錄在 [APP_PACKAGING_NOTES.md](APP_PACKAGING_NOTES.md#9-修正分支安裝包與舊版清理)。架構與後續修改入口見 [CODEBASE_MAP.md 第 17 節](CODEBASE_MAP.md#17-claude-訂閱用量2026-10-12)。
