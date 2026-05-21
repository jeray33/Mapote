# Mapote 编辑器改造规划：WKWebView + Tiptap + JSON + 原生薄外壳

## 1. 决策结论

Mapote 编辑器主线收敛到 **WKWebView + Tiptap + JSON + 原生薄外壳**。

核心原则：

1. **一个编辑器内核**：Tiptap / ProseMirror 是唯一编辑器内核。
2. **一个文档源**：以 Tiptap JSON 作为编辑器主状态；Markdown 只作为导出、兼容和派生数据。
3. **一个交互状态机**：默认、编辑、多选、拖拽状态都由 Web 编辑器内部管理。
4. **原生薄外壳**：SwiftUI 负责系统能力和业务服务，不接管 selection、drag target、selectedIds、@ 弹窗坐标和 undo 栈。

## 2. 目标架构

```diagram
╭──────────────────────────────────────╮
│ SwiftUI / iOS 原生层                  │
│                                      │
│ 负责：                                │
│ - 页面容器                            │
│ - Note 加载 / 保存                    │
│ - 图片选择器                          │
│ - 地点搜索 API                        │
│ - 地点详情 Sheet                      │
│ - 键盘 safe area                      │
│ - 原生 toolbar 容器，可选              │
│                                      │
│ 不负责：                              │
│ - 光标 / selection                    │
│ - block 拖拽                          │
│ - 多选 selectedIds                    │
│ - drop target 计算                    │
│ - @ 弹窗坐标                          │
│ - undo / redo transaction             │
╰──────────────────┬───────────────────╯
                   │ WK bridge
                   ▼
╭──────────────────────────────────────╮
│ WKWebView                             │
│                                      │
│ Tiptap Editor                         │
│                                      │
│ 负责：                                │
│ - JSON 文档模型                       │
│ - 文本输入 / 粘贴 / 中文输入法          │
│ - 光标 / selection                    │
│ - 默认 / 编辑 / 多选 / 拖拽状态机       │
│ - 单块拖拽                            │
│ - 连续多选拖拽                        │
│ - @ 地点弹窗                          │
│ - place chip                          │
│ - image block                         │
│ - toolbar command 执行                │
│ - undo / redo                         │
╰──────────────────────────────────────╯
```

## 3. 编辑器模式

Web 内部维护统一状态：

```ts
type EditorMode =
  | { type: "display" }
  | { type: "editing"; blockId: string }
  | { type: "multiSelect"; anchorId: string; selectedIds: string[] }
  | {
      type: "dragging";
      fromMode: "display" | "editing" | "multiSelect";
      blockIds: string[];
    };
```

### 3.1 默认模式 display

- 不显示光标。
- 不触发文本选择。
- 点击 block：进入编辑模式。
- 长按 block：拖动单个 block。
- 左滑 / 右滑 block：进入多选模式。
- 点击地点 chip：通知 Swift 打开地点详情。

### 3.2 编辑模式 editing

- 当前文档可编辑，有光标和文本选择。
- toolbar 命令作用于 Tiptap selection。
- @ 地点检测只在编辑模式生效。
- 触发拖拽或多选前先 blur / clear selection，再切换模式。

### 3.3 多选模式 multiSelect

- 文本不可编辑、不可选择、无光标。
- swipe block 进入多选，当前 block 为 anchor。
- 点击另一个 block：选择 anchor 到 target 的连续区间。
- 点击空白：退出多选，回到 display。
- 长按已选 block：拖动整个连续选区。
- 长按未选 block：退出多选，只拖动该 block，drop 后回 display。

### 3.4 拖拽模式 dragging

- Web 计算 block rects 和 drop target。
- 拖拽过程中显示 ghost / drop indicator。
- drop 时一次 ProseMirror transaction 完成 reorder。
- 单块拖拽、多选拖拽都必须是单个 undo step。
- Swift 不参与 drop target 计算。

## 4. BlockNote / Tiptap / NativeEditor 取舍

### BlockNote

- 停止作为主线扩展。
- 短期保留用于回退和参考。
- 不继续在 BlockNote 上实现强自定义拖拽、多选和模式状态机。
- Tiptap 达到功能对齐后删除 BlockNote 依赖和旧代码。

### Tiptap

- 作为新的主编辑器内核。
- 负责 schema、selection、history、transaction、toolbar command、拖拽、多选、@ 地点和 place chip。
- 比 BlockNote 更可控，比纯原生编辑器成本更低。

### NativeEditor

- 冻结，不作为主线继续投入。
- 短期保留作为状态机和交互规则参考。
- Tiptap 稳定后删除 NativeEditor 相关 Swift 文件和 feature flag。

## 5. Bridge 边界

### Swift -> Web

```ts
setContent({ json?, blocks?, markdown, places, locked, tuning })
setLocked(locked)
applyCommand({ type, level? })
insertImage({ url, caption? })
insertPlace(place)
placeSearchResults({ requestId, results })
flushContent({ requestId })
```

### Web -> Swift

```ts
ready()
contentChanged({ revision, blocks, json?, markdown, isDirty, mention? })
modeChanged({ mode, selectedCount })
focusChanged({ focused })
requestPlaceSearch({ requestId, query })
placeTapped({ placeId })
requestImagePicker()
contentFlushed({ requestId })
error({ message })
```

边界规则：

- Swift 不保存 selection 细节。
- Swift 不保存 selectedIds，最多知道 selectedCount。
- Swift 不计算 block 几何和 drop target。
- Swift 不计算 @ 弹窗坐标；最终由 Web 根据 caret coords 渲染。
- 当前稳定优先版本中 Web 每次 Tiptap 内容变更都立即发送 canonical JSON `contentChanged`，并附带独立的 content revision；Swift 只用 content revision 给文档快照排序，不能用 toolbar / focus / mode 等 UI 消息的全局 seq 丢弃内容快照。
- Swift 收到 canonical JSON 后立即持久化；Swift 不用 native debounce 或 `onDisappear` shadow state 兜底编辑内容。
- Swift -> Web 的 `setContent` 只用于初始化 / 外部模型变更重灌；Web 正在聚焦编辑时不能用 Swift shadow state 反向重灌内容。JSON blocks 同步比较必须使用稳定语义签名，不能用 raw `Data` 字节比较。
- 销毁 WKWebView 前的模式切换 / 返回必须走 `flushContent -> contentChanged -> contentFlushed` 握手，等待最终 JSON 过桥后再移除编辑器。
- Web 拖拽能力暂停禁用；后续若恢复，拖拽完成后仍需发送最终 contentChanged。

## 6. 执行步骤

### Phase 0：架构冻结与决策确认

目标：停止扩大混合编辑器复杂度。

执行：

1. 确认 Tiptap 为编辑器主线。
2. 冻结 NativeEditor，不再新增编辑器能力。
3. 冻结 BlockNote，不再继续在其上 hack 多选拖拽。
4. 保留旧实现作为回退，不立即删除。
5. 明确后续新功能只进入 Tiptap 主线。

验收：

- 新编辑器功能只进入 Tiptap。
- Swift / Web 职责边界明确。

### Phase 1：Tiptap JSON 编辑器骨架

目标：建立可运行的 Tiptap WKWebView 编辑器，支持 JSON 读写。

执行：

1. 引入 Tiptap 依赖。
2. 定义基础 schema：paragraph、heading、list、task、image、divider、placeRef。
3. 实现 `setContent`、`setLocked`、`applyCommand`、`insertImage`、`insertPlace`。
4. 保存顶层 block array 到 `note.blocks`，保留 markdown 双写。
5. 支持旧 Markdown fallback。

验收：

- 空文档可编辑。
- 普通文本可输入、保存、重新打开恢复。
- bold / heading / list / undo / redo 基础可用。
- 图片和地点节点可插入。

### Phase 2：Web 内部状态机

目标：display / editing / multiSelect / dragging 模式统一。

执行：

1. 新增 Web 内 mode controller。
2. 所有 tap、long press、swipe、blank tap、drag 生命周期通过 mode controller。
3. 根据 mode 控制 editable、selection、caret、hit testing。
4. mode 变化通过 bridge 通知 Swift。

验收：

- 默认模式无光标、无文本选择。
- 编辑模式有光标和文本选择。
- 多选模式无光标、无文本选择。
- 点击空白退出多选，再次点击才进入编辑。

### Phase 3：单块拖拽

> **当前状态：暂停 / 代码禁用。**
>
> 2026-05-19 决定以稳定写作为优先，暂停 whole-block 长按拖拽。原因是长按拖拽与 WKWebView 文本编辑、iOS 文本选择、正文滚动、SwiftUI sheet detent / 背景交互存在高频手势冲突。代码中保留状态机与 helper，但通过 `ENABLE_BLOCK_DRAG = false` 禁用入口。后续若恢复，应改为显式拖拽把手或独立“整理模式”，不要恢复整块长按触发。

目标：50 次单块拖拽无乱序。

执行：

1. Web 捕获 display/editing 下的 long press drag。
2. editing 触发拖拽前 blur 并清 selection。
3. Web 测量 block rects，计算 drop target。
4. drop 时一次 transaction 完成 reorder。
5. drop 后回 display，并发送 contentChanged。

验收：

- 文首、文末、向上、向下拖拽正确。
- undo 一次恢复。
- 滚动位置不明显跳动。

### Phase 4：连续多选与多选拖拽

> **当前状态：暂停 / 代码禁用。**
>
> 2026-05-19 决定暂停横滑进入多选与多选拖拽。原因是横滑 / 长按选区拖拽与垂直滚动、sheet 拖动、文本选择和输入法编辑冲突，导致编辑器核心写作体验不稳定。代码中保留 `multiSelect` 类型和 helper，但通过 `ENABLE_CONTIGUOUS_MULTI_SELECT = false` 禁用入口。后续若恢复，应放入显式整理模式或通过 checkbox / menu 选择，而不是正文区域横滑。

目标：20 次多选拖拽无错位。

执行：

1. swipe 进入 multiSelect，保存 anchor。
2. 点击目标 block 选择连续区间。
3. 长按已选 block 拖动 selectedIds。
4. 长按未选 block 退出多选，只拖动该 block。
5. 多选 drop 使用一次 transaction。

验收：

- 连续选择范围正确。
- 多选跨文本 / 图片 / 地点 / 列表正确。
- 批量移动一次 undo 恢复。

### Phase 5：@ 地点弹窗

目标：弹窗跟随输入点，不遮挡输入行。

执行：

1. Tiptap plugin 检测 @ query。
2. Web 使用 caret coords 定位 dropdown。
3. Web 请求 Swift 搜索地点。
4. Swift 返回结果，Web 渲染 dropdown。
5. 选择地点后插入 placeRef。

验收：

- @ 空 query 显示笔记已有地点。
- query 搜索远程地点。
- 弹窗跟随光标并避让键盘 / 输入行。

### Phase 6：Toolbar 与文本样式

目标：toolbar 连点稳定，样式命令可靠。

执行：

1. Swift toolbar 只发送 command。
2. Web 串行执行 command。
3. Web 回传 toolbar active state。
4. 中文输入法 composing 期间谨慎执行命令。

验收：

- bold/list/heading 连点状态正确。
- undo/redo 稳定。
- toolbar 不造成光标跳动。

### Phase 7：保存、撤销与滚动位置收口

目标：核心状态稳定。

执行：

1. contentChanged 携带独立 content revision；稳定优先版本立即发送 canonical JSON。
2. 拖拽完成立即发送最终 contentChanged。
3. 拖拽和多选拖拽成为单个 undo step。
4. drop 前后保持 scrollTop。

验收：

- 输入不丢字。
- 拖拽后重开顺序正确。
- undo/redo 正确。
- 滚动位置无明显跳变。

### Phase 8：边界回归与清理

目标：达到可作为唯一主线的稳定性。

回归场景：

- [ ] 空文档。
- [ ] 超长文档。
- [ ] 图片 / 地点 / 列表混排。
- [ ] 中文输入法联想。
- [ ] 粘贴大段文本。
- [ ] 单块拖拽 50 次。
- [ ] 多选拖拽 20 次。
- [ ] 快速 toolbar 连点。
- [ ] App 退后台 / 回前台。

清理：

- [x] 删除 BlockNote 依赖和旧 editor 代码。
- [x] 删除 NativeEditor 相关 Swift 文件。
- [x] 删除 NativeEditor feature flag。
- [x] 删除旧 bridge 方法和多余 fallback。

## 7. 里程碑

1. **M1：Tiptap 可编辑** — JSON 加载、输入、保存、恢复。
2. **M2：核心模式稳定** — display / editing 切换正确；multiSelect / dragging 保留为暂停能力。
3. **M3：单块拖拽稳定** — 暂停，后续改为显式拖拽把手或整理模式。
4. **M4：连续多选拖拽稳定** — 暂停，后续改为显式整理模式。
5. **M5：@ 地点与 toolbar 可用** — 地点插入和样式命令稳定。
6. **M6：回归与清理** — 旧 BlockNote / NativeEditor 可删除。

## 8. 当前执行状态

- [x] 生成并落地规划文档。
- [x] Phase 1：Tiptap 编辑器骨架。
- [x] Phase 2：Web 内部模式状态机。
- [ ] Phase 3：单块拖拽。**暂停 / 代码禁用**，入口由 `ENABLE_BLOCK_DRAG = false` 关闭，避免长按与编辑、滚动、sheet 手势冲突。
- [ ] Phase 4：连续多选拖拽。**暂停 / 代码禁用**，入口由 `ENABLE_CONTIGUOUS_MULTI_SELECT = false` 关闭，避免横滑 / 长按选区与核心编辑冲突。
- [x] Phase 5：@ 地点弹窗。
  - [x] Web 内渲染 @ 菜单，空 query 使用笔记已有地点。
  - [x] query 通过 `requestPlaceSearch` 请求 Swift 远程搜索，`placeSearchResults` 回填。
  - [x] 选择候选后由 Web 立即插入 `placeRef`，Swift 只补齐 / 持久化地点元数据。
  - [x] 菜单使用 caret / visual viewport 计算位置，靠近键盘或底部时上翻。
- [x] Phase 6：Toolbar 与文本样式。
  - [x] Swift toolbar 只发送 command。
  - [x] Web 侧串行执行 command，并在 IME composition 期间延后执行。
  - [x] Web 回传 toolbar active state，Swift toolbar 同步高亮。
- [x] Phase 7：保存 / undo / scroll 收口。
  - [x] 输入内容由 Web 在每次 Tiptap update 后立即发送 canonical JSON，优先消除返回 / 切后台前 debounce 未触发造成的丢字窗口。
  - [x] Web `contentChanged` 使用独立 content revision；Swift 只对 content revision 做顺序保护，避免 toolbar / focus / mode 消息推进全局 seq 后误丢内容快照。
  - [x] Swift 收到 canonical JSON 后立即保存，并在 `NoteStore.updateBlocks` 跳过完全相同的 blocks / markdown，避免无效写入。
  - [x] 删除 `EditModeView.onDisappear` 的本地 shadow state 写回，避免在 contentChanged 被延迟 / 丢弃时用旧 `editorBlocks` 覆盖 Tiptap 源数据。
  - [x] `WKTextView.updateUIView` 使用稳定 JSON 签名比较 blocks，并且 Web 聚焦编辑时不执行 Swift -> Web `setContent`，避免 SwiftUI 刷新期间用旧模型覆盖正在编辑的 Tiptap 文档。
  - [x] 切换列表 / 返回笔记列表前执行 Web flush 握手，Web 发送最终 `contentChanged` 后再回 `contentFlushed`，Swift 收到确认后才销毁编辑器。
  - [x] blur / pagehide / visibility hidden 时 Web 主动 flush 当前 JSON。
  - [x] 单块和多选拖拽能力保留为暂停代码路径；当前稳定版本不触发 drag/drop transaction。
- [ ] Phase 8：边界回归与旧代码清理。
  - [x] Web typecheck：`npx tsc --noEmit`。
  - [x] Web build：`npm run build`，并生成 `Mapote/editor.html`。
  - [x] iOS CLI build：`xcodebuild -scheme Mapote -project Mapote.xcodeproj -destination 'generic/platform=iOS Simulator' build -quiet`。
  - [x] iOS Simulator build：iPhone 17 Pro / iOS 26.2。
  - [x] iOS Simulator smoke launch：安装并启动 `innervision.Mapote` 成功。
  - [x] 删除 BlockNote 依赖：`@blocknote/*`、`@dragdroptouch/drag-drop-touch`。
  - [x] 删除旧 BlockNote Web 组件：`divider.tsx`、`placeInline.tsx`、`ambient.d.ts`。
  - [x] 删除 NativeEditor Swift 实现目录。
  - [x] 删除 NativeEditor feature flag。
  - [x] 删除旧 bridge geometry / moveBlock 声明。
  - [x] 清理 Swift / TypeScript 中旧编辑器引用。
  - [x] 容器手势边界：editing 不再冻结 sheet detent，三段 sheet 拖拽条保持可用；multiSelect / dragging 暂停禁用，Swift 不参与 drop target 计算。
  - [ ] 实机 / 模拟器手动回归：空文档。
  - [ ] 实机 / 模拟器手动回归：超长文档。
  - [ ] 实机 / 模拟器手动回归：图片 / 地点 / 列表混排。
  - [ ] 实机 / 模拟器手动回归：中文输入法联想。
  - [ ] 实机 / 模拟器手动回归：粘贴大段文本。
  - [x] 实机 / 模拟器手动回归：单块拖拽 50 次。当前版本已暂停禁用，不纳入核心回归。
  - [x] 实机 / 模拟器手动回归：多选拖拽 20 次。当前版本已暂停禁用，不纳入核心回归。
  - [ ] 实机 / 模拟器手动回归：快速 toolbar 连点。
  - [ ] 实机 / 模拟器手动回归：App 退后台 / 回前台。
