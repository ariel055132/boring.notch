# Boring Notch：外接螢幕隱藏瀏海與滑鼠展開 — 對話摘要

- 日期：2026-10-05
- 專案：`boring.notch`
- 狀態：已完成原始碼修改，待使用者建置與實機測試。
- 本文件為本次對話的整理摘要，並非逐字紀錄。

## 1. 使用者需求

使用者先要求確認以下行為是否可行：

> 如果目前螢幕是 MacBook，啟動 Boring Notch 時顯示瀏海；如果目前螢幕是外接螢幕，啟動時不要顯示瀏海，但把滑鼠放到中間時，仍然能使用目前設定的四個頁面。

本次將「中間」理解為**螢幕頂部中央**。確認可行後，使用者指示：

> 進行程式修改，測試我自己做就可以了。

最後要求將本次對話匯總成 Markdown，產生本文件。

## 2. 可行性確認與決策

確認現有程式已具備收合／展開狀態、滑鼠停留開啟、透明感應區，以及依螢幕 UUID 管理視窗的機制。四個分頁可以沿用，不需要重新實作。

螢幕類型採用 macOS 的 [`CGDisplayIsBuiltin`](https://developer.apple.com/documentation/coregraphics/cgdisplayisbuiltin%28_%3A%29) 判斷。這與「有沒有實體瀏海」是不同條件，因此沒有實體瀏海的 MacBook 內建螢幕也維持原本行為。

採用的方式是在外接螢幕收合時隱藏視覺內容，保留頂部中央約 **10 pt 高的透明滑鼠感應區**。視窗仍存在，滑鼠、拖放與快捷鍵可以沿用既有展開流程。

## 3. 修改後的預期行為

| 情境 | 行為 |
|---|---|
| MacBook 內建螢幕 | 維持原本瀏海外觀與互動，仍遵循既有全螢幕設定。 |
| 外接螢幕啟動／收合 | 隱藏瀏海，只留下透明感應區。 |
| 滑鼠停留在外接螢幕頂部中央 | 依既有 hover 設定展開面板，可切換 Home、Shelf、Weather、AI Usage。 |
| 滑鼠離開展開面板 | 依既有收合規則收合，再次隱藏。分享或電池 popover 等保持展開的條件仍有效。 |
| 外接螢幕收合時收到提示 | 黑底、頂部黑線、陰影、chin 延伸區，以及音樂／電池／HUD 提示均不顯示；隱藏的提示狀態不阻擋 hover 展開。 |

**既有設定仍然生效：** Preferred display、Show on all displays、Open notch on hover、hover 延遲，以及 Shelf／分頁顯示設定均沿用原設定。這次沒有改成滑鼠移到任意一台連接中的螢幕，就自動把面板搬到該螢幕；只在原設定建立視窗的螢幕套用上述行為。

## 4. 實際修改位置

| 檔案 | 修改內容 |
|---|---|
| [NSScreen+UUID.swift](boringNotch/extensions/NSScreen+UUID.swift) | 新增 `isBuiltInDisplay`，使用 `CGDisplayIsBuiltin` 辨識內建螢幕。 |
| [BoringViewModel.swift](boringNotch/models/BoringViewModel.swift) | 新增 `isOnExternalDisplay` 與 `isClosedNotchHidden`，依各視窗的 UUID 判斷隱藏政策；與全螢幕 `hideOnClosed` 分開，避免被全螢幕更新覆寫；外接收合時停用 chin 延伸區。 |
| [ContentView.swift](boringNotch/ContentView.swift) | 外接收合時以透明內容取代瀏海內容，保留 10 pt 感應區並移除黑底、頂線與陰影；調整兩處 hover 條件，使不可見的 `sneakPeek` 不阻擋展開；展開後沿用四頁；外接螢幕略過歡迎動畫。 |
| [boringNotchApp.swift](boringNotch/boringNotchApp.swift) | 啟動統一先經 `adjustWindowPosition` 選定螢幕；建立視窗時先設定 UUID／尺寸，定位後才顯示，以避免首次渲染時閃出瀏海。 |
| [OnboardingView.swift](boringNotch/components/Onboarding/OnboardingView.swift) | 首次設定完成時清除 `helloAnimationRunning`，避免外接螢幕略過動畫後，切回內建螢幕時播放殘留的歡迎動畫。 |
| [CODEBASE_MAP.md](CODEBASE_MAP.md) | 補上外接螢幕隱藏／hover 展開的定位索引、行為說明與驗證狀態。 |

## 5. 檢閱中處理的問題

1. 原本單螢幕啟動流程先建立並顯示視窗，之後才指定螢幕 UUID；已調整為先確定目標螢幕再顯示。
2. 僅縮小瀏海高度仍可能留下頂部黑線、陰影或提示內容；已將外接收合狀態的視覺內容一起隱藏。
3. 原本 hover 會被 `sneakPeek.show` 阻擋；已讓外接隱藏狀態下的兩處判斷都能通過。
4. 外接螢幕略過歡迎動畫後，動畫完成回呼不會執行；已在首次設定完成時清除狀態。

## 6. 驗證與交付狀態

- 已完成程式碼檢閱與 `git diff --check`，未發現差異格式問題。
- 依使用者要求，**未執行編譯、自動化測試或實機 UI 測試**。上述行為為本次修改的預期結果，尚未經執行驗證。
- 未重新啟動或替換已安裝的 App；使用者需自行建置及執行修改後的版本。
- 尚未建立 commit 或 push。

使用者後續可重點確認：外接螢幕啟動時無瀏海、頂部中央可展開四頁、移開後隱藏、內建螢幕維持原行為，以及螢幕拔插／切換和音樂或 HUD 提示期間的 hover 操作。
