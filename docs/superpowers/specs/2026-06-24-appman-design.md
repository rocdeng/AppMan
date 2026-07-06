# AppMan 第一版设计

日期：2026-06-24

## 目标

AppMan 是一个 macOS 原生 App 管理器，用来管理用户安装的应用。第一版聚焦三个能力：

| 能力 | 第一版目标 |
|---|---|
| 卸载 App | 支持卸载普通用户安装的 `.app`，默认移动到废纸篓或 AppMan 隔离区 |
| 清理残留 | 扫描高置信残留文件，删除前预览，第一版只移动到可恢复隔离区 |
| 检查和执行更新 | 按安装渠道检查更新；自动更新先覆盖可验证渠道，手动安装 App 走官网确认库 |

第一版不追求“强力一键清理”。所有高风险操作必须可预览、可恢复、可解释。

## 平台和技术路线

| 项 | 决策 |
|---|---|
| 平台 | macOS |
| 产品形态 | 原生桌面 App |
| UI | SwiftUI |
| 系统能力 | Swift、FileManager、Bundle/Info.plist 解析、代码签名信息读取 |
| 命令集成 | Homebrew Cask 通过 `brew`；Mac App Store 通过 Apple lookup API 检查并跳转 App Store |
| 本地数据 | 第一版当前使用 JSON 文件保存扫描缓存、偏好设置、忽略检查列表、手动更新网址和更新规则；后续需要复杂查询时再迁移 SQLite |
| 支持目录 | `~/Library/Application Support/AppMan/` |
| 隔离区 | 后续卸载恢复能力使用 `~/Library/Application Support/AppMan/Quarantine/` |

## App 扫描

AppMan 第一版扫描以下目录：

| 路径 | 说明 |
|---|---|
| `/Applications` | 系统级应用目录 |
| `~/Applications` | 用户级应用目录 |

每个 `.app` 读取并展示：

| 字段 | 来源 |
|---|---|
| App 名称 | Bundle 名称或文件名 |
| App 图标 | `.app` bundle 图标或系统默认图标 |
| Bundle ID | `Info.plist` |
| 版本号 | `CFBundleShortVersionString`、`CFBundleVersion` |
| 路径 | 文件系统 |
| 大小 | 文件系统统计 |
| 签名信息 | 代码签名、Team ID、开发者名称 |
| 最近打开时间 | 系统元数据，读取不到时显示未知 |
| 安装渠道 | 渠道识别模块 |

主列表第一版展示列：

| 列 | 展示规则 |
|---|---|
| App 名称 | 名称前显示 App 图标 |
| 来源 | 使用短标签：`MAS`、`BREW`、`SELF` |
| 当前版本 | 优先显示 `CFBundleShortVersionString`，有 build 时显示为 `短版本 (build)` |
| 最新版本 | 显示检查结果；有更新时显示最新版本，未检查显示“未检查”，无法判断时显示“无法检测” |

扫描结果必须缓存。启动时优先加载缓存，避免每次都完整扫描；用户点击“扫描”时刷新缓存。检查更新前会轻量刷新当前列表中 App 的版本元数据，避免 App 已被外部更新后仍显示旧版本。

## 安装渠道识别

| 渠道 | 第一版识别方式 | 第一版更新能力 |
|---|---|---|
| Homebrew Cask | 对比 `brew list --cask --json=v2` 中的 token、artifact app 名和 Bundle 信息 | 支持检查和执行更新 |
| Mac App Store | 收据、Bundle 元数据、Spotlight 中的 Adam ID | 支持检查更新；执行更新时跳转 Mac App Store |
| Sparkle | 读取 App 内 Sparkle feed 配置 | 支持按 appcast 检查；执行更新时打开更新地址 |
| 手动安装 | 不属于以上渠道时标记为手动/未知 | 走官网确认库、手动输入网址或 recipe 规则 |

如果渠道证据不足，界面必须显示“未知/手动”，不伪装成已确认渠道。

## 卸载流程

| 步骤 | 行为 |
|---|---|
| 选择 App | 用户在 App 详情页或列表选择卸载 |
| 预检 | 检查是否系统保护 App、是否正在运行、是否需要管理员权限 |
| 展示影响 | 显示 App 路径、大小、残留候选数量、预计释放空间 |
| 执行卸载 | 将 `.app` 移入废纸篓或 AppMan 隔离区 |
| 记录索引 | 保存原路径、Bundle ID、签名信息、卸载时间 |

安全边界：

| 边界 | 规则 |
|---|---|
| 系统 App | 第一版不提供卸载入口 |
| 静默提权 | 不做；需要权限时走系统授权 |
| 永久删除 | 第一版不默认执行 |
| 正在运行的 App | 先提示用户退出，不强杀 |

## 残留清理

第一版只扫描高置信用户目录：

| 目录 | 匹配依据 |
|---|---|
| `~/Library/Application Support` | App 名、Bundle ID、开发者名 |
| `~/Library/Preferences` | Bundle ID，如 `com.vendor.app.plist` |
| `~/Library/Caches` | Bundle ID、App 名 |
| `~/Library/Logs` | Bundle ID、App 名 |
| `~/Library/Containers` | Bundle ID |
| `~/Library/Group Containers` | Team ID、Bundle ID 相关信息 |

候选残留必须展示：

| 字段 | 说明 |
|---|---|
| 原路径 | 待处理文件或目录 |
| 大小 | 预计释放空间 |
| 匹配理由 | 例如 Bundle ID 精确匹配、App 名匹配 |
| 置信度 | 高、中、低 |
| 默认勾选状态 | 只有高置信候选默认勾选 |

清理策略：

| 项 | 规则 |
|---|---|
| 第一阶段 | 移动到 AppMan 隔离区 |
| 恢复 | 按原路径恢复 |
| 清空 | 用户二次确认后永久删除隔离区项目 |
| 低置信候选 | 默认不勾选，只提示人工判断 |

## 官网确认库

手动安装 App 的更新不能自动信任搜索结果。第一版采用“自动搜索候选 + 用户确认”的流程。

| 步骤 | 行为 |
|---|---|
| 生成候选 | 根据 App 名、Bundle ID 搜索官网；默认使用 Google，用户在设置中配置 TinyFish API Key 后优先使用 TinyFish |
| 展示入口 | 最新版本列显示蓝色“待确认”，点击后弹出确认官网 / 检查更新网址窗口，预填搜索到的候选地址 |
| 用户确认 | 用户确认这是官网或更新检查页后才写入本地记录 |
| 手动兜底 | 如果没有搜索到候选，最新版本列显示蓝色“需手动输入”，点击后输入检查更新网址 |
| 后续检查 | 已保存网址后直接检查；如果命中内置或用户 recipe，则按 recipe 检查 |
| 异常降级 | 域名变化、签名不匹配、下载来源变化时要求重新确认 |

信任记录字段：

| 字段 | 用途 |
|---|---|
| `id` | 同一 Bundle ID 有多个本地副本时按 App 路径派生 ID 区分 |
| `app_name` | 展示用 |
| `bundle_id` | 绑定 App 身份；后续优先按 Bundle ID 复用记录 |
| `update_url` | 用户确认或手动输入的官网 / 下载页 / 更新检查页 |
| `confirmed_at` | 确认时间 |

如果没有确认网址、没有手动网址、也没有可匹配 recipe，检查结果显示“待确认”或“需手动输入”，不能频繁弹窗打断用户。只有用户已确认 / 手动输入的网址无法解析版本时，才显示“无法检测”。

## 手动安装 App 更新规则

为了覆盖不同 App 官网结构，第一版支持可配置的 JSON recipe。recipe 是“预发布规则”或用户规则，用于描述如何匹配 App、访问哪个页面、以及如何提取版本号。

| 字段 | 说明 |
|---|---|
| `id` | 规则唯一 ID，通常用 Bundle ID 或稳定 slug |
| `name` | 展示和排序用名称 |
| `recipePrompt` | 给 AI / Codex 阅读的规则说明，记录官网判断、页面结构和注意事项 |
| `match.bundleIdentifier` | 按 Bundle ID 匹配 |
| `match.appName` | 按 App 名匹配 |
| `match.officialHost` | 已确认官网 host 匹配 |
| `checks[].url` | 需要抓取的网页或接口 |
| `checks[].extract` | 版本提取规则，当前支持 `regex` 和 `linkRegex` |
| `updatePageURL` | 更新页；当无法解析安装包 URL 时作为点击最新版本号的兜底跳转目标 |
| `download` | 安装包下载规则；能稳定下载时写明固定 URL 或 `sourceURL + pattern + urlGroup`，不能确认时显式写 `null` |

规则来源：

| 来源 | 路径 |
|---|---|
| 内置预发布规则 | `Resources/UpdateRecipes/*.json` |
| 用户自定义规则 | `~/Library/Application Support/AppMan/update-recipes/*.json` |

当前内置规则可以先覆盖本机已扫描到的一批 `SELF` App。后续如果某个 App 无法检测，Codex 可以分析官网后补充 recipe。

内置 recipe 必须声明 `download` 字段。`download: null` 表示已经研究过但暂时没有可信安装包下载规则，不等同于漏填。

已补充专用公开规则的 App 包括 Android Studio、Google Chrome、Microsoft Edge、QQ、Tencent Lemon、WeChat 和 Warp。其中 Warp 当前只能检测 GitHub release 版本，未发现稳定安装包直链，点击更新时走官网兜底。

如果内置 recipe 仅用于记录“已研究但暂无稳定检测方式”，其 `checks` 可以为空；这类 App 检查后显示“需手动输入”，点击后会预填 `updatePageURL` 作为用户确认 / 修改的兜底网址。

## 手动安装 App Detector

当 `SELF` App 没有命中 recipe，但用户已经确认或手动输入了更新网址时，App 使用 detector 链尝试识别最新版本和安装包链接。Detector 是可扩展的小模块，按顺序尝试，命中后短路，便于后续加入更多官网策略。

| Detector | 触发条件 | 行为 |
|---|---|---|
| GitHub Release Detector | 确认网址是 `github.com/<owner>/<repo>` 或 release/download 链接 | 调用 GitHub latest release API，读取 tag 作为最新版本，并优先选择 macOS `.dmg/.pkg/.zip` asset |
| Sparkle Feed Detector | 确认网址是 appcast XML 或网页实际返回 Sparkle/RSS appcast | 解析 `sparkle:shortVersionString` / `sparkle:version`，并读取 enclosure 安装包 URL |
| JSON API Detector | 确认网址返回 JSON API | 从常见 `version` / `latestVersion` 字段提取版本，并从 `downloadUrl` 等字段提取安装包 URL |
| Redirect Download Detector | 确认网址是固定“latest download”链接 | 解析最终跳转到的 `.dmg/.pkg/.zip` URL，并从文件名提取版本 |
| Generic Web Page Detector | 其他普通网页 | 抓取 HTML，用通用规则提取版本号，并从页面里寻找 `.dmg/.pkg/.zip` 安装包链接 |

默认执行顺序是 GitHub、Sparkle、JSON API、重定向下载、通用网页。Detector 只处理“用户已确认网址”的情况，不自动信任搜索结果。搜索得到的候选仍需用户点击“待确认”后才进入 detector 流程。

## 更新检查和执行

| 渠道 | 检查 | 执行更新 |
|---|---|---|
| Homebrew Cask | `brew outdated --cask` | `brew upgrade --cask <token>` |
| Mac App Store | Apple lookup API，优先 Bundle ID，必要时 Adam ID | 打开 `macappstore://` 对应 App 页面 |
| Sparkle | 读取 appcast feed，取最高版本 | 打开更新地址，不强行替代 App 内更新器 |
| 手动安装 | recipe、已确认网址、Google/TinyFish 候选、手动输入网址；检测最新版本时同时尝试解析 `.dmg`、`.pkg`、`.zip` 安装包链接 | 点击最新版本号时直接下载最新安装包到 `~/Downloads/AppMan/`；下载完成后自动打开安装包，由 macOS 处理 dmg 挂载、压缩包解压或 pkg 安装器打开 |

检查更新并发限制为 3，避免一次性对大量手动 App 发起过多网络请求。

工具栏更新按钮是带下拉菜单的分裂按钮：

| 操作 | 行为 |
|---|---|
| 直接点击检查更新 | 只检查当前选中的 App |
| 下拉“检查所有更新” | 检查当前列表所有未忽略 App |
| 下拉“更新所有” | 对所有有更新的 App 执行对应渠道动作 |

用户可以在 App 列表右键选择“忽略更新检查”。被忽略 App 的最新版本列显示“已忽略”，不会参与检查；设置页中展示忽略列表，并提供删除按钮恢复检查。

手动安装 App 的下载行为：

| 场景 | 行为 |
|---|---|
| recipe 或已确认网页能解析出安装包链接 | 检查结果会把更新地址标记为“安装包直链”；最新版本号可点击，点击后下载到 `~/Downloads/AppMan/` 并自动打开；如果同名安装包已存在，则直接在 Finder 中定位已有文件 |
| 只有版本号，没有安装包链接 | 直接打开官网 / 更新页 |
| 下载目标文件已存在 | 自动追加序号，避免覆盖已有文件 |
| 安装包类型 | 第一版只支持 `.dmg`、`.pkg`、`.zip` |
| 下载进度 | 下载过程中进度浮层显示总大小、已下载大小和百分比；按 `Esc` 取消当前下载，取消后不弹错误框，只显示顶部轻提示“已取消下载” |

客户端点击最新版本号时不只看 URL 后缀，还会读取检查结果里的“安装包直链”标记；因此类似 `https://update.code.visualstudio.com/latest/darwin-arm64/stable` 这种无扩展名但由 recipe 明确给出的下载端点，也会执行下载而不是当成网页打开。

手动安装 App 的下载校验：

| 校验 | 规则 |
|---|---|
| 域名 | 必须来自确认过的官网或确认过的下载域名 |
| Bundle ID | 新包应与原 App 一致 |
| Team ID | 新包应与原 App 一致 |
| 签名状态 | 必须已签名且可验证 |
| 不匹配 | 阻止自动更新，要求人工确认 |

## UI 结构

| 区域 | 内容 |
|---|---|
| 顶部标签 | “应用程序”和“设置”两个标签；后续增加清理入口 |
| 顶部工具栏 | App 信息、检查更新分裂按钮、卸载、标签切换、搜索框 |
| App 列表 | 表格列为 App 名称、来源、当前版本、最新版本 |
| 搜索 | 工具栏右侧搜索框过滤 App；当前放得下时直接展开，后续空间不足时可收起 |
| App 信息对话框 | 点击 info 后显示选中 App 的基本信息 |
| 卸载清理窗口 | 展示 App 本体及关联文件候选，执行时移动到废纸篓 |
| 官网确认面板 | 点击“待确认”或“需手动输入”后输入 / 确认检查更新网址 |
| 设置页 | 启动自动检查更新、TinyFish API Key、忽略更新检查列表 |
| 隔离区视图 | 后续展示已隔离项目、原路径、恢复、清空 |

窗口外观采用自定义紧凑工具栏，但必须保留系统红绿灯行为：关闭、最小化、最大化都可点击，鼠标悬停时显示与系统一致的图标反馈，位置对齐 Activity Monitor 风格。

第一版不做后台常驻监控；设置中提供“启动 App 时自动检查更新”，默认关闭。开启后在启动加载完 App 列表后自动检查更新。

## 数据模型

| 文件 | 作用 |
|---|---|
| `apps-cache.json` | 扫描缓存，包含 App 基本信息、来源、更新状态和更新地址 |
| `preferences.json` | 偏好设置，包括启动自动检查更新和 TinyFish API Key |
| `ignored-updates.json` | 忽略更新检查列表 |
| `self-update-sources.json` | 用户确认或手动输入的手动 App 更新网址 |
| `update-recipes/*.json` | 用户自定义更新规则 |
| `Resources/UpdateRecipes/*.json` | App 内置预发布更新规则 |

## 错误处理

| 场景 | 行为 |
|---|---|
| `brew` 不存在 | 显示 Homebrew 不可用，跳过 Cask 更新 |
| Mac App Store lookup 找不到 App | 显示暂不支持或检查失败，不伪造更新结果 |
| App 正在运行 | 提示退出后重试 |
| 权限不足 | 触发系统授权或提示手动处理 |
| 官网候选待确认 | 最新版本列显示“待确认”，等待用户点击确认 |
| 官网候选为空，或内置 recipe 暂无稳定检查规则 | 最新版本列显示“需手动输入”，等待用户提供网址；如果已有 `updatePageURL`，弹窗预填该网址 |
| 已确认网页无法解析版本 | 显示“无法检测” |
| 下载包签名不匹配 | 阻止自动更新，展示差异 |
| 残留恢复失败 | 保留隔离区记录，提示具体失败路径 |

## 验收标准

| 编号 | 标准 |
|---|---|
| 1 | 能扫描 `/Applications` 和 `~/Applications` 并列出 App 基本信息 |
| 2 | 能识别至少 Homebrew Cask、Mac App Store、手动安装三类渠道 |
| 3 | 能缓存扫描结果，重启后优先展示缓存，手动扫描时刷新 |
| 4 | 能检查 Homebrew Cask 更新，并对可更新 App 执行 `brew update` + `brew upgrade --cask <token>` |
| 5 | 能通过 Apple lookup API 检查 Mac App Store 更新，并点击版本跳转对应 App Store 页面 |
| 6 | 能读取 Sparkle appcast 并判断最新版本 |
| 7 | 能卸载一个测试 App 及高置信关联文件到废纸篓 |
| 8 | 能为手动安装 App 生成官网候选，显示“待确认”而不是自动保存 |
| 9 | 用户确认官网或手动输入网址后能保存记录并检查更新 |
| 10 | 能通过 recipe 检查 AppCleaner 这类手动安装 App 的最新版本 |
| 11 | 能右键忽略某个 App 的更新检查，并在设置页删除忽略项 |
| 12 | 设置中能保存 TinyFish API Key；未设置时默认使用 Google |
| 13 | 设置中能保存“启动 App 时自动检查更新”，默认关闭 |
| 14 | 签名或域名不匹配时不会自动下载和安装更新 |

## 非目标

| 非目标 | 说明 |
|---|---|
| 后台常驻自动监控 | 第一版不做；只支持可选的启动后自动检查 |
| 一键永久删除 | 第一版不做 |
| 系统 App 卸载 | 第一版不做 |
| 自动信任搜索结果 | 第一版不做 |
| 自动安装手动 App | 第一版不做；只下载最新安装包，不自动挂载、解压、替换或安装 |
| 覆盖所有私有更新器 | 第一版只做可解释的渠道和确认过的官网 |

## 待实现顺序

| 阶段 | 内容 | 验证 |
|---|---|---|
| 1 | 项目骨架、App 扫描、JSON 缓存 | 扫描结果可展示且可缓存 |
| 2 | 渠道识别：Homebrew、MAS、手动 | 渠道标签正确 |
| 3 | 主界面表格、工具栏、搜索、设置页 | App 列表可筛选，工具栏操作清晰 |
| 4 | Homebrew/MAS/Sparkle 更新 | 可检查并跳转或执行 |
| 5 | 官网候选、TinyFish/Google、确认库 | 可确认并保存官网 |
| 6 | 手动 App recipe 更新检查 | 已确认官网或内置 recipe 可检查更新 |
| 7 | 忽略更新检查列表 | 右键忽略、设置页删除 |
| 8 | 卸载和残留清理 | 测试 App 可卸载，高置信残留可处理 |
