# iOS 应用完整技术交接文档

> 本文档旨在让 AI 根据此文档用 Swift/SwiftUI 完整复刻此旅行路线笔记 Web 应用。
> 文档涵盖所有数据模型、业务逻辑、UI 交互、API 集成细节，无任何遗漏。

---

## 目录

1. [应用概述](#1-应用概述)
2. [数据模型](#2-数据模型)
3. [数据持久化](#3-数据持久化)
4. [Markdown 格式规范](#4-markdown-格式规范)
5. [页面与导航](#5-页面与导航)
6. [首页笔记列表](#6-首页笔记列表)
7. [编辑模式](#7-编辑模式)
8. [列表模式](#8-列表模式)
9. [地图模式](#9-地图模式)
10. [地图引擎抽象层](#10-地图引擎抽象层)
11. [AI 功能 — 文字识别导入](#11-ai-功能--文字识别导入)
12. [AI 功能 — 旅行助手聊天](#12-ai-功能--旅行助手聊天)
13. [API 缓存层](#13-api-缓存层)
14. [地点分类系统](#14-地点分类系统)
15. [UI 设计规范](#15-ui-设计规范)
16. [iOS 迁移建议](#16-ios-迁移建议)

---

## 1. 应用概述

**一句话描述**：一款旅行路线笔记应用，用户可以在富文本笔记中通过 `@` 搜索插入地图地点标签，自动获取地点详情（照片、地址、营业时间），并在列表模式查看排序路线、在地图模式可视化全部地点。

**核心功能**：
- 富文本笔记编辑（Markdown + 自定义地点标签语法）
- `@` 提及搜索 → 调用 Google Maps / 高德地图 API 搜索地点 → 插入为可交互芯片
- 三种查看模式：编辑（Edit）、列表（List）、地图（Map）
- AI 批量识别文本中的地点并转换为标签
- AI 旅行助手聊天（推荐行程 + 一键添加地点到笔记）
- 双地图引擎支持（Google Maps / 高德地图），自动回退
- 全部数据存储在 localStorage（无后端）

---

## 2. 数据模型

### 2.1 PlaceCategory 枚举

```swift
enum PlaceCategory: String, Codable, CaseIterable {
    case food       // 美食餐饮
    case lodging    // 住宿酒店
    case attraction // 景点古迹
    case shopping   // 购物商场
    case transit    // 交通枢纽
    case nature     // 自然户外
    case services   // 生活服务
    case other      // 其他
}
```

每个分类的配置：

| 分类 | 中文标签 | 颜色 HEX | 图标 (Lucide) | Emoji |
|------|---------|----------|--------------|-------|
| food | 美食餐饮 | #ef4444 | UtensilsCrossed | 🍽️ |
| lodging | 住宿酒店 | #8b5cf6 | Bed | 🏨 |
| attraction | 景点古迹 | #f59e0b | Landmark | 🏛️ |
| shopping | 购物商场 | #ec4899 | ShoppingBag | 🛍️ |
| transit | 交通枢纽 | #6366f1 | TrainFront | 🚉 |
| nature | 自然户外 | #22c55e | TreePine | 🌲 |
| services | 生活服务 | #64748b | Building2 | 🏢 |
| other | 其他 | #2563eb | MapPin | 📍 |

### 2.2 分类关键词映射

以下关键词用于根据 Google Maps 返回的 `types` 数组自动分类地点：

```
food: restaurant, cafe, bakery, bar, food, meal_delivery, meal_takeaway, night_club
lodging: lodging, hotel, motel, resort
attraction: tourist_attraction, museum, church, art_gallery, amusement_park, zoo, aquarium, stadium, casino, movie_theater, bowling_alley, spa, temple, shrine, historic, monument
shopping: shopping_mall, store, market, supermarket, clothing_store, shoe_store, jewelry_store, book_store, electronics_store, department_store, convenience_store, furniture_store, home_goods_store, pet_store
transit: train_station, bus_station, airport, subway_station, transit_station, taxi_stand, light_rail_station
nature: park, natural_feature, campground, rv_park, garden, beach
services: hospital, pharmacy, bank, post_office, police, fire_station, embassy, city_hall, courthouse, library, school, university, gym, laundry, car_repair, gas_station, parking, atm
other: (默认，当无匹配时)
```

**分类算法**：遍历地点的 `types` 数组，按上述顺序（food → services）检查是否有包含（`includes`）匹配的关键词，首个匹配即为分类。无匹配则为 `other`。

### 2.3 Place 结构

```swift
struct Place: Identifiable, Codable {
    let id: String          // UUID
    var name: String
    var address: String
    var lat: Double
    var lng: Double
    var note: String        // 用户自定义备注
    var image: String?      // 首张图片 URL
    var images: [String]?   // 最多 5 张图片 URL
    var placeId: String?    // Google Maps Place ID 或高德 POI ID
    var suggestedDuration: String? // AI 建议游玩时长，如 "1-2小时"
    var description: String?       // 地点简介 (editorial_summary)
    var openingHours: [String]?    // 每周营业时间文字数组 (7项)
    var category: PlaceCategory?
    var types: [String]?           // 原始地图 API 返回的类型数组
}
```

### 2.4 RouteInfo 结构

```swift
struct RouteInfo: Codable {
    var distance: String       // 如 "3.2 km"、"800 m"
    var duration: String       // 如 "15分钟"、"1小时30分"
    var travelMode: TravelMode
}

enum TravelMode: String, Codable {
    case DRIVING, WALKING, BICYCLING, TRANSIT
}
```

### 2.5 Note 结构

```swift
struct Note: Identifiable, Codable {
    let id: String              // UUID
    var title: String
    var markdown: String        // 包含地点标签的自定义 Markdown
    var places: [Place]         // 地点数据存储（通过 id 查找）
    var routeInfos: [String: RouteInfo]  // key = "placeId1-placeId2"
    var createdAt: TimeInterval // Date.now() 毫秒时间戳
    var updatedAt: TimeInterval
}
```

### 2.6 ViewMode 枚举

```swift
enum ViewMode: String {
    case edit, list, map
}
```

---

## 3. 数据持久化

### 3.1 存储方式

- **笔记数据**：localStorage key = `"place-notes"`，值为 `Note[]` 的 JSON 字符串
- **地图设置**：localStorage key = `"map-settings"`，存储地图主题、POI 开关等
- **地图引擎选择**：localStorage key = `"map-engine-type"`，值为 `"google"` 或 `"amap"`
- **AI 聊天历史**：localStorage key = `"ai_chat_{noteId}"`，值为 `ChatMessage[]` JSON
- **API 缓存**：sessionStorage，key 前缀 `"api-cache:"`

### 3.2 iOS 建议

用 SwiftData 或 CoreData 替代 localStorage。API 缓存可用 NSCache（内存）+ UserDefaults（持久）。

### 3.3 数据迁移逻辑

旧版数据有 `blocks` 字段（块编辑器格式），需迁移为 `markdown` 字段：
```
遍历 blocks：
  block.type === 'text' → 追加 block.content + "\n\n"
  block.type === 'place' → 查找 place 数据，生成 "::place[名称]{#placeId}\n\n"
```

---

## 4. Markdown 格式规范

### 4.1 自定义语法

地点标签格式：`::place[地点名]{#placeId}`

正则匹配：`/::place\[([^\]]*)\]\{#([^}]+)\}/g`

示例：
```
# Day 1: 东京经典
::place[东京塔]{#abc-123}
从东京塔出发，步行约15分钟可到达增上寺
::place[增上寺]{#def-456}
```

### 4.2 标准 Markdown 支持

- `# H1`、`## H2`、`### H3`（标题）
- `**粗体**`
- `- 无序列表`
- `1. 有序列表`
- `- [x] 已完成任务`、`- [ ] 未完成任务`（任务列表）

### 4.3 H1 分段规则

`# 标题` 用于将笔记分段（如 Day 1、Day 2）。列表模式和地图模式会解析 H1 标题，将地点按段落分组显示为标签页。

**分段解析算法** (`getPlacesBySection`)：
1. 按行扫描 markdown
2. 遇到 `# xxx` 行，将之前的内容作为一个段落
3. 段落内提取 `::place[...]{#...}` 标签
4. 如果没有任何 H1 标题，返回空数组（调用方直接展示所有地点）

### 4.4 地点间文字提取为备注

`extractPlaceNotes` 函数提取两个地点标签之间的文字作为备注：
- 从 markdown 中按顺序匹配 `::place` 标签
- 两个标签之间的文字（去除标题行后）作为前一个地点的备注
- 最后一个标签后的文字作为该地点的备注
- 用于列表模式中显示在地点卡片下方

### 4.5 有序地点提取

`getOrderedPlaces` 函数按 markdown 中出现顺序返回地点数组：
- 用正则按顺序匹配所有 `::place[...]{#id}`
- 通过 id 查找 note.places 中的数据
- 去重后返回

**关键原则**：`note.places` 数组存储地点数据，`note.markdown` 中的标签顺序决定显示顺序。拖拽排序仅修改 `note.places` 数组，**绝不修改 markdown 字符串**。

---

## 5. 页面与导航

```
┌─────────────────────┐
│     首页笔记列表       │ ← NoteList 组件
│  点击笔记卡片进入编辑   │
└─────────┬───────────┘
          ↓
┌─────────────────────┐
│     笔记编辑器         │ ← NoteEditor 组件
│  顶部：← 返回 + 模式切换 │
│  ┌─────┬─────┬─────┐ │
│  │NOTE │LIST │ MAP │ │ ← 三模式标签页
│  └─────┴─────┴─────┘ │
│  主体内容区域          │
│  右下角：AI 浮动按钮    │
└─────────────────────┘
```

- 纯客户端 SPA，只有两个"页面"状态
- 无 URL 路由变化（首页 → 编辑器通过 React state 切换）

---

## 6. 首页笔记列表

### 6.1 布局

- 顶部固定栏：左侧 MapPin 图标 + "地点笔记" 标题，右侧 "+ 新建" 按钮
- 顶栏有 `backdrop-blur` 毛玻璃效果
- 下方笔记卡片列表，垂直排列，间距 12px

### 6.2 笔记卡片

每张卡片内容：
- **左侧**：地点图片堆叠（最多 3 张，60×60px，每张偏移 5px 的堆叠效果）
- **右侧上**：笔记标题（粗体）+ 地点数量
- **右侧下**：前 4 个地点名称的标签（圆角胶囊）+ 超出数量提示
- **右上角**：删除按钮（两步确认）

### 6.3 两步删除确认

1. 第一次点击删除图标 → 图标变为红色 "删除" 文字按钮
2. 再次点击 → 执行删除
3. 点击卡片其他区域或页面空白处 → 取消删除状态

### 6.4 创建笔记

点击 "+ 新建" → 立即创建标题为 "未命名笔记" 的笔记 → 直接进入编辑模式

---

## 7. 编辑模式 (EditMode)

### 7.1 整体布局

```
┌──────────────────────────────┐
│ [标题输入框]  [✨] [📥] [🔒]  │  ← 标题行 + 操作按钮
├──────────────────────────────┤
│                              │
│    Tiptap 富文本编辑器         │
│    地点显示为彩色芯片标签       │
│                              │
└──────────────────────────────┘
```

### 7.2 操作按钮

从左到右：
1. **✨ 一键转换**：将笔记中的纯文字地名用 AI 识别后转为地点标签
2. **📥 导入地点**：打开导入对话框，粘贴文字批量识别
3. **🔒/🔓 锁定/解锁**：锁定后编辑器只读，点击地点标签弹出详情卡片

### 7.3 Tiptap 富文本编辑器

**扩展配置**：
- StarterKit（标题 1-3 级、粗体、列表等）
- TaskList + TaskItem（任务列表）
- PlaceChipExtension（自定义地点芯片节点）
- Placeholder（空内容时显示提示文字："记录你的路线，输入 @ 搜索并插入地点"）

**PlaceChipExtension（自定义 Tiptap Node）**：
- 类型：`inline`、`atom`（不可编辑内容）、`draggable`（可拖拽）
- 属性：`placeId`、`placeName`、`raw`（原始 markdown 标签）、`category`
- 渲染：圆角胶囊，背景色为分类颜色（18% 不透明度），文字为分类颜色，左侧有分类图标
- 支持拖拽排序

### 7.4 @ 提及搜索流程

```
用户输入 "@" → 检测触发条件 → 显示搜索下拉
  ↓
用户继续输入查询词 → 300ms 防抖 → 调用 engine.textSearch(query, {locationBias, radius: 50000})
  ↓
显示搜索结果列表（最多 5 个，每个显示名称 + 地址）
  ↓
用户点击结果 → 删除 "@query" 文字 → 插入 PlaceChip 节点 + 空格
  ↓
调用 onAddPlace(place, '') 将地点数据添加到 note.places
```

**触发条件**：
- 从当前光标位置向前扫描最多 50 个字符
- 找到最后一个 `@` 字符
- `@` 前面的字符不能是字母、数字或中文（防止误触发）
- 查询词中不包含换行

**位置偏置**：如果笔记中已有地点，使用所有地点坐标的平均值作为搜索中心，半径 50km

### 7.5 工具栏

**桌面端**：BubbleMenu（选中文字时浮现）
- 按钮：@ 插入地点 | 粗体 | H1 | H2 | H3 | 无序列表 | 有序列表 | 任务列表 | 分隔线 | 撤销 | 重做

**移动端**：键盘上方固定工具栏
- 使用 `window.visualViewport` API 跟踪键盘高度
- 工具栏固定在可视视口底部（键盘上方）
- 按钮同桌面端，但尺寸更大（40×40px 触摸区域）
- 仅在编辑器获取焦点时显示
- 横向可滚动

### 7.6 地点详情弹窗（锁定模式）

在锁定模式下点击地点芯片 → 弹出底部详情卡片：
- 地点图片
- 地点名称 + 地址
- 备注文字
- 评分（星星）
- 营业状态（营业中 / 已关闭）
- 可展开的完整营业时间
- "导航到此地点" 按钮（打开 Google Maps / 高德导航 URL）

在编辑模式下点击地点芯片 → 弹出相同卡片但底部为 "删除此地点" 按钮

### 7.7 Markdown 序列化/反序列化

**markdownToTiptap**（Markdown → Tiptap JSON）：
- 按行解析：`# ` → heading level 1, `## ` → 2, `### ` → 3
- `- [x] ` / `- [ ] ` → taskList/taskItem
- `- ` → bulletList
- `数字. ` → orderedList
- 其他 → paragraph
- 行内解析：`::place[name]{#id}` → placeChip 节点, `**text**` → bold mark

**tiptapToMarkdown**（Tiptap JSON → Markdown）：
- heading → `# ` / `## ` / `### `
- bulletList → `- `
- orderedList → `1. `, `2. ` ...
- taskList → `- [x] ` / `- [ ] `
- placeChip → 使用 `raw` 属性值（即 `::place[name]{#id}`）
- bold mark → `**text**`

### 7.8 外部更新同步

- 维护 `lastExternalMd` ref，当外部 markdown 变化时同步到编辑器
- 使用 `suppressUpdateRef` 防止同步导致的循环更新

---

## 8. 列表模式 (ListView)

### 8.1 整体布局

```
┌──────────────────────────────┐
│ [Day 1] [Day 2] [Day 3] [智能排序] │  ← 分段标签页（仅有 H1 时显示）
├──────────────────────────────┤
│ ┌──────────────────────────┐ │
│ │ 🏛️ 东京塔     ☰ ↕      │ │  ← 可拖拽地点卡片
│ │ 📍 Tokyo Tower           │ │
│ │ ⏰ Monday: 9:00-23:00    │ │
│ │ 建议 1-2小时             │ │
│ └──────────────────────────┘ │
│     │ 🚗 3.2km · 15分钟     │  ← 路线信息（可点击切换交通方式）
│ ┌──────────────────────────┐ │
│ │ 🍽️ 一兰拉面   ☰ ↕      │ │
│ └──────────────────────────┘ │
│                              │
│ 总路程 12.5 km · 总耗时 45分钟│  ← 路程汇总
└──────────────────────────────┘
```

### 8.2 地点卡片内容

- 左侧：地点图片（64×64px 圆角方形）
- 右侧：
  - 行1：分类图标（圆形背景）+ 地点名称 + 展开/收起箭头 + 拖拽手柄
  - 行2：今日营业时间 + AI 建议游玩时长
  - 行3：上下文备注（从 markdown 中提取的地点间文字）

### 8.3 展开详情

点击展开箭头显示：
- 完整地址
- 地点简介
- 完整营业时间（每天一行）
- 备注编辑（点击 → Textarea → 保存/取消）

### 8.4 路线信息

**懒加载机制**：
- 路线不是一次全部请求
- 仅当某张卡片被展开时，才请求该卡片与相邻卡片之间的路线
- 具体逻辑：遍历地点对，如果 `expandedIds` 包含当前地点或下一个地点，且该路线 key 未被请求过，则触发请求

**首次请求**：同时请求 DRIVING、WALKING、TRANSIT 三种模式，选择耗时最短的作为默认

**交通方式循环切换**：点击交通图标 → DRIVING → WALKING → BICYCLING → TRANSIT → DRIVING...

**路线 key 格式**：`"placeId1-placeId2"`

### 8.5 拖拽排序

使用 dnd-kit 库实现：
- 传感器：PointerSensor（桌面拖拽，最小距离 8px）、TouchSensor（移动端，延迟 200ms）
- 排序后调用 `onReorderPlaces` 更新 `note.places` 数组
- 拖拽后清除已请求路线的缓存，重新懒加载

### 8.6 智能排序（最近邻算法）

当地点数 ≥ 3 时显示 "智能排序" 按钮：
1. 以第一个地点为起点
2. 每次从剩余地点中选择距离最近的
3. 使用 Haversine 公式计算距离
4. 排序后清除所有路线信息
5. 如果有分段，仅对当前标签页的地点排序，其他分段不变

### 8.7 AI 建议游玩时长

进入列表模式时自动请求：
- 筛选没有 `suggestedDuration` 的地点
- 将地点名称列表发送给 Gemini API
- Prompt："对以下地点给出建议游玩时长，返回JSON对象格式如 {"地点名": "1-2小时"}"
- 返回结果更新到各地点的 `suggestedDuration` 字段

### 8.8 总路程汇总

底部显示当前分段的总距离和总耗时：
- 解析每段路线的 distance（支持 km、m、mi 单位）
- 解析 duration（支持 hour/小时/hr 和 min/分钟/分）
- 格式："总路程 12.5 km · 总耗时 1小时30分"

---

## 9. 地图模式 (MapView)

### 9.1 双引擎渲染

根据当前地图引擎选择渲染不同组件：
- Google Maps → `GoogleMapContent`（使用 `@vis.gl/react-google-maps`）
- 高德地图 → `AmapContent`（使用原生 AMap JS SDK）

### 9.2 Google Maps 内容

**地图配置**：
- 禁用默认 UI（`disableDefaultUI`）
- 手势处理：`greedy`（单指即可拖拽）
- 默认中心：第一个地点坐标，或东京 (35.68, 139.76)

**自定义标记 (OverlayMarker)**：
- 使用 `google.maps.OverlayView` 实现（不依赖 mapId）
- 创建 React Root 渲染自定义 DOM
- 标记内容：圆角胶囊，分类颜色背景，白色数字编号 + 截断地点名（最多 4 字符）
- 选中时 `scale(1.2)`

**路线渲染**：
- 使用 `google.maps.DirectionsRenderer`（实际导航路线）
- 回退：如果 DirectionsService 失败，绘制直线 Polyline
- 路线颜色：`#2563eb`，不透明度 0.7，线宽 4

**连线渲染**：
- 地点间虚线（不走道路），颜色 `#2563eb`，不透明度 0.4，线宽 2

**POI 点击添加**：
- 监听 `map.click` 事件，检查 `event.placeId`
- 如果有 placeId，调用 `engine.getPlaceDetails` 获取详情
- 弹出 `MapPlaceCard` 预览卡片，用户可点击 "加入笔记"

### 9.3 地图主题

5 种预设主题（Google Maps JSON Styles）：

| 主题 | 中文名 | 特点 |
|------|--------|------|
| default | 默认 | 无自定义样式 |
| minimal | 简洁浅色 | 降低饱和度，柔和道路，浅蓝水域 |
| dark | 暗色高级 | 深色背景，金色标注 |
| retro | 复古暖色 | 米色背景，暖色调道路 |
| night | 午夜蓝 | 深蓝背景，青色标注 |

### 9.4 地图设置面板

右下角齿轮按钮打开下拉菜单：

1. **地图引擎切换**（仅双 API Key 时显示）：Google / 高德 切换按钮
2. **地图主题**：5 种主题单选
3. **路线与连线**：
   - 显示导航路线（开/关）
   - 显示地点连线（开/关）
4. **标记**：
   - 显示编号（开/关）
   - 显示名称（开/关）
   - 标记聚合（开/关，当前仅 UI 开关，未实际实现聚合）
5. **图层与标注**：
   - POI 分类：8 种 POI 独立开关 + 全部开启/关闭
   - 交通标注（开/关）
   - 道路标注（开/关）
   - 水域标注（开/关）

所有设置持久化到 localStorage `"map-settings"`。

### 9.5 分段标签页

与列表模式相同的 H1 分段标签页（"全部" + 各 Day），切换后仅显示对应分段的标记。

### 9.6 地点详情卡片 (MapPlaceCard)

底部弹出卡片：
- **图片轮播**：左右箭头切换，底部圆点指示器
- **信息行**：编号（分类颜色圆形）+ 名称 + 分类标签
- **地址**
- **简介**
- **评分 + 建议时长**
- **今日营业时间**
- **操作按钮**："导航" + "加入笔记"（POI 预览模式）

### 9.7 高德地图实现差异

- 使用原生 `AMap.Map` 构造器
- 标记使用 `AMap.Marker` + 自定义 DOM `content`
- 连线使用 `AMap.Polyline`
- 坐标需要 WGS-84 → GCJ-02 转换
- 没有 DirectionsRenderer，只画连线

### 9.8 Fit Bounds

- Google Maps：`map.fitBounds(bounds, padding)`
- 高德：`map.setBounds(new AMap.Bounds(...))`
- 单个地点时设置 zoom = 15

---

## 10. 地图引擎抽象层

### 10.1 MapEngine 接口

```swift
protocol MapEngine {
    var type: MapEngineType { get } // google | amap
    func loadScript() async throws
    func isLoaded() -> Bool
    func textSearch(query: String, options: SearchOptions?) async -> [MapPlace]
    func findPlace(query: String, options: SearchOptions?) async -> MapPlace?
    func getPlaceDetails(placeId: String, fields: [String]?) async -> MapPlace?
    func getDirections(from: LatLng, to: LatLng, mode: TravelMode) async -> MapDirectionsResult?
}
```

### 10.2 MapPlace 结构

```swift
struct MapPlace {
    var name: String
    var address: String
    var lat: Double
    var lng: Double
    var placeId: String?
    var photoUrl: String?
    var photoUrls: [String]?
    var types: [String]?
    var rating: Double?
    var openingHours: [String]?
    var editorialSummary: String?
    var reviews: [PlaceReview]?
    var openNow: Bool?
}
```

### 10.3 SearchOptions

```swift
struct SearchOptions {
    var locationBias: LatLng?  // 搜索中心点
    var radius: Int?           // 搜索半径（米），默认 50000
    var city: String?          // 高德专用，限制搜索城市
}
```

### 10.4 GoogleEngine 实现要点

- `textSearch`：使用 PlacesService.textSearch，支持 locationBias
- `findPlace`：调用 textSearch 取第一个结果，再调 getPlaceDetails 获取完整信息
- `getPlaceDetails`：请求字段包含 name, formatted_address, geometry, photos, opening_hours, editorial_summary, rating, reviews, types
- 如果没有 editorialSummary，使用最高评分 review 的前 80 字符
- 照片 URL：`photo.getUrl({maxWidth: 400})` 首张，`photo.getUrl({maxWidth: 600})` 前 5 张
- `getDirections`：使用 DirectionsService，返回 leg.distance.text、leg.duration.text、leg.duration.value

### 10.5 AmapEngine 实现要点

- 使用 `AMap.PlaceSearch`、`AMap.Driving`、`AMap.Walking`、`AMap.Transfer`
- 所有输入坐标需 WGS-84 → GCJ-02 转换
- 所有输出坐标需 GCJ-02 → WGS-84 转换
- BICYCLING 模式回退到 WALKING
- 距离格式化：≥1000m 显示 km，否则显示 m
- 时间格式化：≥3600s 显示 "X小时Y分"，否则显示 "X分钟"

### 10.6 坐标转换 (WGS-84 ↔ GCJ-02)

```
常量：
  A = 6378245.0（半长轴）
  EE = 0.00669342162296594323（偏心率平方）

outOfChina(lng, lat)：lng < 72.004 || lng > 137.8347 || lat < 0.8293 || lat > 55.8271

WGS-84 → GCJ-02：
  如果 outOfChina → 直接返回
  否则用 transformLat/transformLng + 椭球体校正公式转换

GCJ-02 → WGS-84：
  迭代法（5 次），逐步逼近真实坐标
```

完整算法见源码 `coordTransform.ts`（约 50 行），建议直接移植。

### 10.7 MapProvider 加载逻辑

1. 检测默认引擎：localStorage → Google（优先）→ 高德
2. 加载对应引擎脚本
3. 加载失败 → 自动尝试另一个引擎（回退）
4. 全部失败 → 显示错误提示："需要配置地图 API Key"

---

## 11. AI 功能 — 文字识别导入

### 11.1 入口

两个入口：
1. **标题栏 ✨ 按钮**：将当前笔记中的纯文字自动转换为地点标签
2. **📥 导入对话框**：粘贴外部文字，识别后选择性导入

### 11.2 Gemini API 调用

**端点**：`https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent`

**API Key**：环境变量 `VITE_GEMINI_API_KEY`

**请求参数**：
```json
{
  "contents": [{"parts": [{"text": "prompt内容"}]}],
  "generationConfig": {
    "response_mime_type": "application/json",
    "temperature": 0
  }
}
```

### 11.3 提取 Prompt（完整原文）

```
你是一个地点提取专家。从以下文本中提取所有**具体的、可以在地图上定位的场所**。

提取目标（要提取的）：
- 景点、公园、寺庙、博物馆、纪念馆
- 餐厅、咖啡馆、酒吧、小吃店、面包店
- 酒店、民宿、旅馆
- 商场、商店、市场、超市
- 车站、机场、码头、地铁站
- 学校、医院、体育场馆
- 具体的街道或路名（如"南锣鼓巷""花见小路"）
- 具体的建筑物或地标（如"东京塔""故宫"）

排除目标（不要提取的）：
- 国家名：中国、日本、美国、韩国等
- 省份/州名：山西省、广东省、北海道、加州等
- 城市名：北京、上海、东京、纽约、巴黎等（除非它是具体景点的一部分，如"北京站""东京塔"）
- 区/县名：涩谷区、朝阳区、浦东新区等
- 泛指区域：市中心、老城区、郊区、城里等
- 方位描述：附近、旁边、对面、前面等

提取技巧：
1. 从口语化表述中提取：如"去了趟西单大悦城" → 提取"西单大悦城"
2. 从动词短语中提取：如"在星巴克喝了杯咖啡" → 提取"星巴克"
3. 保留分店信息：如"一兰拉面 新宿店"保持完整
4. 缩写要展开或保留原文：如"环球影城""USJ" → 提取"环球影城"，aliases中加"USJ"
5. 即使只提到一次也要提取
6. 如果地点名有中文和外语两种写法，用aliases提供另一种
7. 给每个结果补充 kind：
   - specific_place：可在地图上定位到具体 POI / 景点 / 街道 / 站点
   - broad_area：国家、省、市、区、泛区域
8. 如果你不确定是具体地点还是宽泛区域，优先标记为 broad_area

返回JSON格式：
{
  "region": "推断的城市或地区名（用于辅助搜索）",
  "places": [
    { "name": "地点名", "searchQuery": "地点名 城市", "aliases": ["别名1", "English Name"], "kind": "specific_place" }
  ]
}
```

### 11.4 broad_area 过滤逻辑

`filterBroadNames` 函数在 AI 返回结果后进一步过滤：
1. 名称长度 ≤ 1 → 排除
2. AI 标记为 `broad_area` → 排除
3. 名称在通用地理词集合中（市中心、老城区等）→ 排除
4. 名称以特定地点后缀结尾（站、塔、寺、馆、山等 30+ 后缀）→ 保留
5. searchQuery 比 name 长度多 1 以上 → 保留（说明添加了城市限定）
6. 名称匹配行政区后缀（国、省、市、区等）→ 排除
7. 其他情况：kind === 'specific_place' 则保留

### 11.5 搜索与回退策略

对每个 AI 提取的地点：
1. 使用 `searchQuery` + `{locationBias, radius: 50000, city}` 搜索
2. 失败 → 尝试每个 `alias`
3. 仍失败 → 去除 locationBias 重试 `searchQuery`
4. 首个成功找到的地点坐标成为后续搜索的 locationBias（锚点漂移）

### 11.6 一键转换逻辑（标题栏 ✨）

1. 提取 markdown 中去除所有 `::place[...]{#...}` 后的纯文字
2. 调用 `extractPlacesWithAI` → `filterBroadNames`
3. 遍历结果，检查该地名是否已被标记
4. 在 markdown 中找到地名文字位置，原地替换为 `::place[name]{#id}` 标签
5. 如果 API 返回的地名是非中日韩字符，但原始文字是中日韩，则保留原始名称

### 11.7 导入对话框流程

1. **输入步骤**：用户粘贴文字 → 点击 "智能识别地点"
2. **结果步骤**：显示识别到的地点列表，每个带复选框
   - 找到的地点：显示名称 + 地址
   - 未找到的：显示灰色 "未找到匹配地点"
   - 支持全选/取消全选
3. 点击 "加入笔记 (N)" → 将选中地点批量添加

---

## 12. AI 功能 — 旅行助手聊天

### 12.1 入口

右下角固定圆形按钮（56px），主题色背景，MessageCircle 图标
点击后从底部滑出 Sheet，占屏幕 70% 高度

### 12.2 聊天面板布局

```
┌──────────────────────────────┐
│ 🗺️ AI 旅行助手                │ ← 头部
│    帮你推荐目的地和规划行程     │
├──────────────────────────────┤
│                              │
│  用户消息（右对齐，主题色背景） │
│                              │
│  AI 消息（左对齐，灰色背景）   │
│   [Day 1: 经典巴黎]  [全部添加]│
│   ┌─[图片] 埃菲尔铁塔  [+]──┐│
│   │ 巴黎标志性建筑          ││
│   │ 建议傍晚前往看夜景      ││
│   └─────────────────────────┘│
│                              │
├──────────────────────────────┤
│ [输入框: 想去哪里旅行？]  [发送]│
└──────────────────────────────┘
```

### 12.3 System Prompt（完整原文）

```
你是一个专业的旅行规划助手。用户会向你询问旅行目的地推荐、行程规划等问题。

回复规则：
1. 用中文回复，语气友好专业
2. 回复结构必须严格按照以下格式：

一句简短的开头语

**Day 1: 主题**
一段该天的简短开头语

```json:places
[{"name":"地点中文名","searchQuery":"Place Name City","reason":"一句话推荐理由","tips":"建议游玩时间、交通方式等实用建议"}]
```

**Day 2: 主题**
一段该天的简短开头语

```json:places
[...]
```

一句简短的结尾祝福语

3. searchQuery 必须是英文或当地语言的准确地名+城市名，方便 Google Maps 搜索
4. 每天推荐 3-6 个具体地点
5. 不要推荐过于宽泛的区域名（如"东京"、"巴黎"），要推荐具体的景点、餐厅、街区等
6. reason 是一句话推荐理由，tips 是游玩时间、交通方式等实用建议
7. 不要加其他无关内容，只回答行程相关的内容
8. 如果用户只问单个地点推荐（不是行程），用 **推荐地点** 作为标题，同样使用 json:places 格式
```

### 12.4 流式回复

**API 端点**：`https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:streamGenerateContent?alt=sse`

**请求体**：
```json
{
  "contents": [系统消息 + 对话历史],
  "generationConfig": {
    "temperature": 0.8,
    "maxOutputTokens": 4096
  }
}
```

**SSE 解析**：
- 逐行读取，筛选 `data: ` 前缀行
- 解析 JSON 提取 `candidates[0].content.parts[0].text`
- 增量拼接到 `fullContent`
- 流结束后解析 `parsePlaceBlocks(fullContent)` 提取地点分组

### 12.5 回复解析 (parsePlaceBlocks)

1. 正则匹配所有 `**Day N: xxx**` 标题 → 提取 day headers
2. 正则匹配所有 `` ```json:places\n...\n``` `` 代码块 → 解析 JSON 为 `AIPlace[]`
3. 按 day header 的位置范围分配 place blocks
4. 提取 day intro（标题与首个 place block 之间的文字）
5. 如果没有 Day 标题，将所有地点归为 "推荐地点" 组

### 12.6 交织渲染 (buildSegments)

将 AI 原始回复拆分为交织的文字段和地点卡片段：
1. 用正则 `` /```json:places\s*\n[\s\S]*?```/g `` 找到所有代码块位置
2. 代码块前的文字 → `text` 段
3. 代码块 → `places` 段
4. 最后剩余文字 → `text` 段
5. 文字段用 ReactMarkdown 渲染，地点段渲染为卡片列表

### 12.7 地点缩略图

`PlaceThumbnail` 组件：
- 使用 `engine.findPlace(searchQuery)` 获取地点信息
- 提取 `photoUrl` 显示为 40×40px 圆角缩略图
- 使用内存缓存 `thumbnailCache`（Map 对象）避免重复请求
- 加载中显示旋转图标，无图片显示图片占位图标

### 12.8 添加单个地点

1. 调用 `findPlaceWithOptions(searchQuery)` 获取完整地点数据
2. 如果 API 返回英文名但 AI 提供了中文名 → 使用中文名
3. 将 reason + tips 合并为 `place.note`
4. 生成插入文本：`::place[name]{#id}\nreason。tips`
5. 调用 `onAddPlace(place, insertText)` 插入笔记
6. 标记为已添加（按钮变为 ✓）

### 12.9 添加整天行程

1. 生成 markdown：`\n# Day 1: 主题\n`
2. 添加 dayIntro 文字
3. 遍历该天所有地点：
   - 查询地点详情
   - 生成 `\n::place[name]{#id}\n`
   - 添加 reason/tips 文字
4. 调用 `onAddItinerary(markdown, places)` 批量添加
5. `onAddItinerary` 实现：将 markdown 追加到 note.markdown，将 places 追加到 note.places

### 12.10 对话持久化

- 保存：每次消息列表变化时（非流式中），存储到 `localStorage["ai_chat_{noteId}"]`
- 加载：打开面板时，通过 noteId 加载历史
- 格式：`ChatMessage[]`（`{role: 'user'|'assistant', content: string}`）
- 加载后重新解析每条 assistant 消息的 `placeGroups`

### 12.11 上下文感知

- 将当前笔记中已有地点名称列表作为 noteContext 传给 AI
- System prompt 追加："用户当前笔记中已有以下地点：{names}，请避免重复推荐"

### 12.12 快捷提问

空消息列表时显示快捷提问按钮：
- "推荐东京三天行程"
- "巴黎有哪些必去的地方"
- "帮我规划京都一日游"
点击后填入输入框

---

## 13. API 缓存层

### 13.1 双层缓存

| 层 | 存储 | TTL | 说明 |
|----|------|-----|------|
| 内存 | JavaScript Map 对象 | 30 分钟 | 应用运行期间有效 |
| 持久 | sessionStorage | 24 小时 | 浏览器标签页关闭前有效 |

### 13.2 缓存读取顺序

1. 检查内存缓存（Map）→ 命中且未过期 → 返回
2. 检查 sessionStorage → 命中且未过期 → 同步到内存缓存 → 返回
3. 未命中 → 调用 API → 写入两层缓存

### 13.3 缓存 Key 格式

- **Place Details**：`pd:{placeId}`
- **Directions**：`dir:{fromLat5d},{fromLng5d}-{toLat5d},{toLng5d}:{mode}`
  - 坐标精确到 5 位小数（约 1 米精度），增加命中率
- **sessionStorage 前缀**：`api-cache:`

### 13.4 iOS 建议

- 内存缓存 → NSCache
- 持久缓存 → FileManager 或 UserDefaults（注意大小限制）

---

## 14. 地点分类系统

（详见 2.1 和 2.2 节）

### 14.1 视觉一致性规则

所有使用分类颜色的地方必须保持一致：
- **编辑器芯片**：背景色 `color + '18'`（约 9% 不透明度），文字色 `color`
- **列表模式卡片**：圆形图标背景色 `color + '20'`（约 12% 不透明度），图标色 `color`
- **地图标记**：背景色 `color`（实色），白色文字
- **地图卡片分类标签**：背景色 `color + '20'`，文字色 `color`

### 14.2 分类图标

使用 Lucide React 图标库（iOS 可用 SF Symbols 对应）：

| 分类 | Lucide 图标 | SF Symbol 建议 |
|------|------------|----------------|
| food | UtensilsCrossed | fork.knife |
| lodging | Bed | bed.double |
| attraction | Landmark | building.columns |
| shopping | ShoppingBag | bag |
| transit | TrainFront | tram |
| nature | TreePine | leaf |
| services | Building2 | building.2 |
| other | MapPin | mappin |

---

## 15. UI 设计规范

### 15.1 颜色体系 (HSL)

**浅色模式**：
```
--background: 40 20% 98%     (暖白)
--foreground: 220 20% 12%    (深灰)
--primary: 210 60% 45%       (蓝色)
--secondary: 40 30% 94%      (米色)
--muted: 40 15% 94%          (浅灰)
--accent: 25 80% 55%         (橙色)
--destructive: 0 72% 51%     (红色)
--border: 220 15% 90%
```

**深色模式**：
```
--background: 220 20% 8%
--foreground: 40 15% 92%
--primary: 210 55% 55%
--secondary: 220 15% 18%
--muted: 220 15% 18%
--accent: 25 75% 50%
--destructive: 0 62.8% 30.6%
--border: 220 15% 20%
```

### 15.2 字体

```
主字体：Noto Sans SC（中文优先）
西文辅助：Space Grotesk
回退：system-ui, sans-serif
```

### 15.3 圆角

```
--radius: 0.75rem (12px)
lg: 12px
md: 10px
sm: 8px
```

### 15.4 移动端适配

- **Safe Area**：顶部使用 `env(safe-area-inset-top)` 填充
- **底部 Safe Area**：浮动按钮底部 `calc(env(safe-area-inset-bottom) + 24px)`
- **Visual Viewport**：编辑器工具栏使用 `window.visualViewport` 跟踪键盘高度
- **最大宽度**：内容区域 `max-w-lg`（512px）
- **触摸优化**：按钮最小 40×40px，拖拽延迟 200ms

### 15.5 动画

- 卡片按下：`active:scale-[0.98]`
- 地图详情卡片：`animate-in slide-in-from-bottom-4`
- AI 浮动按钮：`hover:scale-105 active:scale-95`
- Sheet：从底部滑入
- 加载：`animate-spin`（Loader2 图标）

### 15.6 组件库

使用 shadcn/ui 组件（基于 Radix UI）：
- Button、Input、Textarea、Card
- Sheet（底部弹出面板）
- Dialog（模态对话框）
- Tabs（标签页）
- DropdownMenu（下拉菜单 + 子菜单）
- ScrollArea（自定义滚动区域）
- Checkbox、Badge、Separator

---

## 16. iOS 迁移建议

### 16.1 技术栈映射

| Web 技术 | iOS 建议 |
|---------|---------|
| React + Vite | SwiftUI |
| Tiptap (ProseMirror) | UITextView + NSAttributedString 或自定义 SwiftUI 编辑器 |
| @vis.gl/react-google-maps | MapKit 或 Google Maps iOS SDK |
| 高德 JS SDK | 高德 iOS SDK |
| shadcn/ui | SwiftUI 原生组件 |
| localStorage | SwiftData / CoreData / UserDefaults |
| sessionStorage | NSCache + FileManager |
| Gemini API (fetch) | URLSession |
| dnd-kit | iOS 原生拖拽 (onDrag/onDrop 或 UIKit) |
| react-markdown | SwiftUI AttributedString 或第三方 Markdown 渲染 |
| framer-motion | SwiftUI .animation / .transition |

### 16.2 编辑器方案

建议方案：使用 `UITextView` + `NSTextAttachment` 实现地点芯片：
- 自定义 `NSTextAttachment` 子类渲染芯片 UI
- `@` 输入检测使用 `UITextViewDelegate.textViewDidChange`
- 搜索下拉使用 SwiftUI `.popover` 或自定义浮层
- Markdown 解析/序列化逻辑可直接移植

### 16.3 地图方案

- 国内建议用高德 iOS SDK（支持 GCJ-02）
- 海外用 MapKit（原生支持 + 免费）或 Google Maps iOS SDK
- OverlayMarker → MKAnnotationView 自定义视图
- 路线渲染 → MKPolyline / MKDirections

### 16.4 AI 集成

- Gemini API → 直接用 URLSession 调用 REST API
- 或使用 Google 官方 `GoogleGenerativeAI` Swift SDK
- 流式解析 SSE 可使用 `URLSession` + `AsyncSequence`

### 16.5 特色 iOS 功能建议

- **iCloud 同步**：替代 localStorage，多设备共享笔记
- **Widget**：锁屏/桌面小组件显示最近行程
- **Apple Maps 集成**：使用 MapKit 的 MKLocalSearch
- **离线地图**：iOS 16+ MapKit 支持离线地图
- **Shortcuts**：快捷指令支持 "创建旅行笔记"
- **ShareSheet**：从其他 App 分享文字到本应用自动提取地点

---

> **文档完毕。** 以上内容完整涵盖了 Web 应用的所有功能、数据模型、业务逻辑、UI 交互和 API 集成细节。根据此文档可以用 Swift/SwiftUI 完整复刻 iOS 版本。
