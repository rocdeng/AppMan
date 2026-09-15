# AppMan Recipe Web 服务

这个服务提供一个简单网页，用于查询、生成和下载 AppMan 的 Update Recipe。

| 能力 | 行为 |
|---|---|
| 查询 | 使用 SQLite 索引按 Bundle ID、名称和官网定位 Recipe 文件路径 |
| 生成 | 未命中时调用统一的 Codex Recipe 抓取流程，研究官网并输出当前 `UpdateRecipe` JSON |
| 保存 | 新规则写入 `~/Library/Application Support/AppMan/update-recipes`，AppMan 可直接读取 |
| 下载 | 返回 `/recipes/<文件名>.json` 形式的直接文件地址，便于后续切换 CDN |

JSON 文件是必须保留的可分发产物，也是以后 CDN 发布的文件来源。SQLite 同时保存查询字段、Recipe 文件路径和 Recipe JSON 正文：查询直接从数据库返回 JSON；下载始终指向实际 JSON 文件；如果路径对应的本地文件缺失，服务会使用数据库中的 `recipe_json` 原子重建该文件。启动同步不会因为文件暂时缺失而删除数据库记录。

## 启动

```bash
Scripts/run_recipe_web_service.sh
```

然后访问 <http://127.0.0.1:8787>。

默认只监听本机。如需在可信内网提供服务：

```bash
Scripts/run_recipe_web_service.sh --host 0.0.0.0 --port 8787
```

生成新 Recipe 需要本机已登录 Codex CLI。服务使用只读沙箱和网页搜索，不允许生成过程直接修改仓库；结果通过服务校验后才写入 AppMan 用户 Recipe 目录。

## 接入其他内部抓取器

设置 `APPMAN_RECIPE_GENERATOR_COMMAND` 后，服务会把用户输入的 JSON 写入该命令的标准输入，并从标准输出读取 Recipe JSON：

```bash
APPMAN_RECIPE_GENERATOR_COMMAND="/path/to/internal-generator" Scripts/run_recipe_web_service.sh
```

以后修改内部抓取流程时，优先修改 `recipe-generation-prompt.md`，或让 Web 服务与其他入口共同配置同一个 `APPMAN_RECIPE_GENERATOR_COMMAND`，避免维护两套生成逻辑。

## 配置

| 环境变量 | 默认值 | 用途 |
|---|---|---|
| `APPMAN_RECIPE_BUILTIN_DIR` | `Resources/UpdateRecipes` | 内置 Recipe JSON 目录 |
| `APPMAN_RECIPE_DATA_DIR` | AppMan 用户 Recipe 目录 | 新生成 Recipe 的持久化目录 |
| `APPMAN_RECIPE_DATABASE_PATH` | AppMan 支持目录下的 `recipe-web-service.sqlite3` | SQLite 查询索引路径 |
| `APPMAN_RECIPE_GENERATOR_COMMAND` | Codex CLI 内部流程 | 替换为其他统一抓取器 |

## 验证

```bash
python3 -m unittest discover -s RecipeWebService/tests -v
```
