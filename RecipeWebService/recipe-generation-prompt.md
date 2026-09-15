你正在执行 AppMan 现有的内部 Recipe 抓取流程。请为下面的 macOS App 研究并生成一个可直接被当前项目读取的 UpdateRecipe JSON。

用户输入：

```json
{{REQUEST_JSON}}
```

执行要求：

1. 先阅读当前仓库的 `Sources/AppManCore/UpdateRecipe.swift`，以代码中的实际字段、提取方式、版本比较和安装包选择逻辑为准；再抽样阅读 `Resources/UpdateRecipes/*.json`，沿用现有格式。这一步保证内部流程以后变化时，Web 服务会读取最新实现。
2. 使用网页搜索和官网公开信息核实来源。用户给了官网时，只允许使用该官网、该官网明确链接的官方发布源，或 App 自带更新配置能够证明的官方仓库；不要把第三方下载站当作官网。
3. 优先使用稳定、机器可读的官方 API、Sparkle feed 或发布页。`checks` 中的正则必须含真实存在的版本捕获组。
4. `download` 只选择 macOS 的 DMG、PKG 或 ZIP。存在多架构包时，规则应允许 AppMan 当前的架构选择逻辑选出正确包；不要选 Windows、Linux、源码包或校验文件。
5. 必须保留用户提供的 App 名称和 Bundle ID；官网 host 写入 `match.officialHost`。未提供 Bundle ID 时可以为 null，但不要猜造。
6. 在提交结果前，实际访问检查 URL，确认版本正则能命中；如果声明下载规则，也要确认它能提取到受支持的安装包 URL。若找不到可信稳定下载规则，将 `download` 设为 null；若连稳定版本入口也找不到，允许 `checks` 为空。
7. `recipePrompt` 用中文简要记录来源、选择规则和需要注意的限制。
8. 最终只返回符合输出 Schema 的单个 JSON 对象，不要附加 Markdown 或说明文字。
