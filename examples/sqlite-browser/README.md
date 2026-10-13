# SQLite 浏览器（examples/sqlite-browser）

用 cj-tauri 写的 SQLite 浏览 / 调试工具：**左边库对象 / 右上数据网格 / 右下 SQL 调试台**。
零 Node、零前端库、页面里**一次 `fetch` 都没有**——库文件的每一字节都由**仓颉侧**读取。

它是本仓第一个「FFI 直连第三方原生库」的样板，也是几件框架能力的活样板：

| 展示的东西 | 落在哪 |
| --- | --- |
| **仓颉 `foreign func` 直连系统库**（不走 C 桥） | `src/plugins/sqlite_ffi.cj`：`sqlite3_open_v2` / `prepare_v2` / `step` / `column_*` / `set_authorizer` |
| 命名权限集（v1.1）能顶住 7 条命令 | 清单里一行 `"permissions": ["sqlite:default"]`；只读应用换成 `"sqlite:readonly"` 就没了解释器 |
| **命令放行 ≠ 路径放行** | 清单 `scopes.sqlite` 只放行 `$CWD` 与 `$TEMP` 的下级路径；`/etc/hostname` 当场被拒 |
| **只读是内核级的** | 浏览类命令走 `SQLITE_OPEN_READONLY`，写语句的拒绝原文来自 sqlite（`attempt to write a readonly database`） |
| **护栏按语句拒** | `ATTACH` / `DETACH` / `load_extension()` 由 authorizer 拒（路径 scope 管不住 SQL 里写死的另一个文件） |
| 数据回投的边界如实上报 | 页上限 500 行、单元格 65536 字节，超出**带标记**而不是静默丢（`limitClamped` / `truncated` / `bytes`） |
| 列类型映射到界面 | `int` / `float` / `text` / `blob` / `null` 各有独立颜色与形状（BLOB 只报字节数） |

> 为什么不像别的宿主能力那样进 C 桥（`cj_bridge_*`）：C 桥存在的理由是**收拢平台差异**，
> 而 SQLite 三平台同一套 C API、没有平台分支，再包一层只是多一份要维护的转发代码。
> 代价是「链接谁」从「桥提供」变成「消费方各自提供」——见 `docs/设计决策记录.md` D-018。

## 快速跑通

```bash
# 1) 先构建 C 桥（Linux；Windows 用 native\build_win.bat）
bash native/build_linux.sh

# 2) 一键跑（脚本会造夹具库 + 跑完整 E2E 取证，无显示器时自动进 Xvfb）
bash examples/sqlite-browser/run.sh
```

想自己在窗口里点，就手工三步：

```bash
# ① 造一个夹具库（纯 python3 标准库，零第三方依赖）
python3 examples/sqlite-browser/fixture.py --out examples/sqlite-browser/data/fixture.db

# ② 启动（路径参数经环境变量给宿主，页面读不到进程环境）
cd examples/sqlite-browser
CJ_SQLITE_FIXTURE="$PWD/data/fixture.db" cjpm build
./target/release/bin/main
```

也可以不开夹具库：直接把 `ui/` 与 `capabilities/` 拷到某处启动，在顶栏填任意库文件路径点「打开」，
或用 SQL 调试台的「执行（可写）」新建一个空库（`exec` 是唯一走 `SQLITE_OPEN_READWRITE | CREATE` 的命令）。

启动时的环境变量（都是**给宿主**的）：

| 变量 | 作用 | 缺省 |
| --- | --- | --- |
| `CJ_SQLITE_FIXTURE` | 启动时自动打开的库（绝对路径最省事；相对路径按应用工作目录解析） | 空（不自动打开，等你在顶栏填） |
| `CJ_SQLITE_SELFCHECK` | 置 `1` 时页面自动跑一轮自检（36 条） | 关 |

`data/` 目录由脚本 / `fixture.py` 保证存在（`fixture.py` 会自己建目录）：**插件面里没有 mkdir**，
建目录属于应用装配期的事，不该由一个「页面能调到的命令」持有。

## 界面与操作

**顶栏** · 库文件路径 + 「打开」/「重读」。路径可以写相对路径，页面上显示的是**规范化后**的绝对路径
（规范化与白名单判定都在共享层 `src/scope.cj`，页面不做第二份判定）。

**左栏 · 库对象** · 表与视图清单（表给行数，**视图行数如实报 `-1`**——它没有独立行存储，不拿 0 冒充），
点一条即切换右上网格。

**右上 · 数据网格** · 表头可点排序（升 / 降切换），底部「上一页 / 下一页」按 50 行翻页，
页头那行元信息是「共 N 行 · 显示 a-b · 按 X 升序」；「结构」按钮把建表原文与索引注释填进调试台。
单元格**按类型上色**，超长文本显示前 65536 字节并挂一个「截断 …」徽标。

**右下 · SQL 调试台** · 两个按钮刻意分开：

- **「运行」**走只读连接（`sqlite:query`）——写语句会被 sqlite 自己拒掉，这是**故意让你看得见**那条拒绝原文；
- **「执行（可写）」**走 `sqlite:exec`——写语句在这里生效，回投「影响 N 行 · last_insert_rowid=…」。

`Ctrl+Enter` 等同「运行」。只预编译**第一条**语句：调试台里写多条时，是页面再发一次，不是一次跑完。

## 命令与回投契约

七条命令都在 `sqlite` 插件里（`src/plugins/plugin_sqlite.cj`），每条都是**短连接**：
开库 → 装护栏 → 干活 → 关库。没有连接池、没有会话保持——一次命令一个连接，进程退出即无残留。

| 命令 | 入参 | 回投要点 |
| --- | --- | --- |
| `sqlite:env` | — | `selfCheck` / `fixture` / `cwd` / `pageMax` / `cellTextLimit` |
| `sqlite:info` | `path` | `sqliteVersion` / `fileBytes` / `pageSize` / `tableCount` / `readonly` / `attachBlocked` |
| `sqlite:tables` | `path` | `tables[{name,kind,rows,columns}]` / `truncated` |
| `sqlite:schema` | `path` `table` | `columns[{name,declType,notNull,pk,default}]` / `indexes[{name,unique,origin}]` / `rowCount` / `sql` |
| `sqlite:page` | `path` `table` `offset` `limit` `orderBy` `desc` | `columns` / `rows` / `total` / `limit` / `limitClamped` |
| `sqlite:query` | `path` `sql` | `columns` / `rows` / `rowCount` / `truncated` / `limit` |
| `sqlite:exec` | `path` `sql` | `changes` / `lastInsertRowid` |

每一格是一个对象，形状随类型变（界面据此上色）：

| 类型 | 回的字段 |
| --- | --- |
| `int` / `float` | `type` + `value` |
| `text` | `type` + `value`；超 `cellTextLimit` 时另给 `bytes` 与 `truncated=true` |
| `blob` | `type` + `bytes`（**不回投字节本体**：把非法 UTF-8 塞进 IPC 只会让页面乱码或炸掉） |
| `null` | 只有 `type`（`value` 不出现，界面显示斜体 `NULL`） |

`table` 与 `orderBy` 都要过**列 / 表名白名单**（取自 `sqlite_master` 与 `PRAGMA table_info`），
页面给的字符串不会被拼进 SQL——拼的是校验通过的那份名字。

## 护栏与路径 scope

`capabilities/default.json` 全文：

```json
{
  "identifier": "default",
  "windows": ["main"],
  "commands": ["report", "system:version"],
  "permissions": ["sqlite:default"],
  "scopes": { "sqlite": { "allow": ["$CWD/**", "$TEMP/**"], "deny": [] } },
  "events": []
}
```

四件容易混的事，这个示例各演示一半：

- **集声明 ≠ 放行**：插件提供 `sqlite:readonly`（info/tables/schema/page/query/env）与 `sqlite:default`
  （再加 `exec`）两个命名集，但**清单不引用就不生效**。这里引了 `sqlite:default`，
  所以 7 条命令全通；想要一个「只能看」的应用，把这一行换成 `sqlite:readonly` 就够。
- **命令放行 ≠ 参数放行**：能不能碰**某个路径**由 `scopes.sqlite` 说了算，判定只在共享层。
- **只读是内核级的**：`sqlite:query` 用 `SQLITE_OPEN_READONLY` 打开，写语句被拒的原文来自 sqlite；
  `sqlite:exec` 才给 `READWRITE | CREATE`（所以它能新建空库）。
- **护栏按语句判**：路径 scope 只管得住本命令收到的那个路径，管不住 SQL 里写死的另一个路径，
  所以 `ATTACH` / `DETACH` / `load_extension()` 由 authorizer 当场拒（另外还显式关掉了扩展加载）。

三处拒绝的形状（这也是 E2E 取证的锚点）：

```
[cj-tauri] scope denied (sqlite): /etc/hostname -> /etc/hostname
[cj-tauri] sqlite denied: attach/detach is not allowed (code=24)
[cj-tauri] command rejected (sqlite:query): sqlite: step failed: attempt to write a readonly database (rc=8)
```

回给前端的文案是业务错误（`sqlite: path is outside the authorized scope` / `… plugin guard …`），
**桥侧那几行 stderr 是给取证用的**——页面看不到，你不 grep 就看不见。

## 夹具对端（`fixture.py`）

纯 python3 标准库（`sqlite3` / `argparse` / `tempfile`），三个模式：

| 用法 | 作用 |
| --- | --- |
| `--out <路径>` | 生成夹具库（**先删再建**，保证形状可复现） |
| `--selftest` | 自证夹具生成器：造到临时文件再逐条断言 **12 项**，退出码即结论 |
| `--verify <库>` | **进程外核对**：以 `mode=ro` 只读打开同一个库，确认页面经 `exec` 写的那一行在不在 |

夹具形状（页面自检的期望值就写在这上面）：

```
artists(id, name, country)                        3 行：阿炳/中国、Bob Dylan/US、中岛美雪/JP
albums(id, artist_id, title, year, rating, cover)  5 行：第 1 行 cover 是 4 字节 BLOB；第 3 行 rating 为 NULL
notes(id, body)                                   1 行：body 80000 字节（超过 65536 的单元格上限，必定走截断分支）
v_album_titles                                    一个视图（不计入 tableCount，行数报 -1）
```

夹具里特意留了两个「区分得开」的坑：升序首位（`Bob Dylan`，BINARY 序最小）与 rowid 首位（`阿炳`）
**必须是不同的值**，否则页面那条「排序生效」的断言证明不了任何事（`--selftest` 里专门有一条
`artists.order.distinguishable` 守着它）。

## 自检（无人值守取证）

`CJ_SQLITE_SELFCHECK=1` 时页面自动跑 **36 条**断言，每条经 `report` 回投成
`[frontend] [sqlite-selfcheck] PASS|FAIL <名字> <细节>`，最后一行是聚合
`[frontend] [sqlite-selfcheck] summary pass=36 fail=0`。

| 组 | 断言（共 36 条） |
| --- | --- |
| 启动参数 | 自检开关已生效、夹具路径已交到页面 |
| 库信息 | 链接的是三平台同一套 sqlite（主版本 3）、表数**不把视图算进去**、`page_size`、ATTACH 已被封 |
| 对象清单 | 3 表 + 1 视图、逐表行数、视图 `kind` 与**行数 -1** |
| 结构 | 列数、主键识别、建表原文已回投 |
| 分页 | 总数、单元格类型、**中文逐字一致**、页长夹紧到 500 且带标记、排序升序首末位 |
| 类型映射 | `NULL` / `BLOB` 各有独立类型，BLOB 报 4 字节 |
| 截断 | `notes.body` 标 `truncated` 且长度就是 65536 |
| 调试台 | 只读查询结果与值、**只读写被内核拒**、ATTACH 被 authorizer 拒 |
| 写路径 | `exec` 影响 1 行、写后查得到（4 行） |
| 拒绝 | 路径越界被 scope 拒、不存在的表被拒、不存在的库被拒 |

**看证据有一个坑**：`report` 是异步命令（命令按 worker 并发分发），所以**明细行的先后不保证**、
聚合行也不是「最后一行」；判据只能是**计数一致**——`pass` 等于 PASS 明细条数、`fail` 等于 0。

## 实机 E2E

```bash
bash scripts/e2e/test-linux-sqlite-browser.sh     # 无 DISPLAY 时自动进 Xvfb
```

入口做的事：构建（缺产物时）→ 夹具生成器自检（12 项）→ **重建**夹具库 → 带自检开关启动 →
等聚合行 → 收尾 → **进程外核对**（`--verify`）→ 把对端日志并入同一份证据日志 → 取证。

证据：`dist/e2e-evidence/linux-linux-sqlite-browser.json`（+ 同名 `.log` / `~-fixture.log` /
`~.verify.log`），当前 **49/49 断言通过**。除 36 条页内自检逐条 + 桥侧 / 对端侧断言，脚本还直接判三件
**外部对账**与四条负向证据：

| 对账 | 判据 |
| --- | --- |
| 自检计数 | 聚合行 `pass=36 fail=0`，且日志里 0 条 FAIL 行 |
| 夹具自检 | `SELFTEST PASS` 恰好 12 条 |
| **进程外核对** | 另一个进程只读打开同一文件，`VERIFY ok artists.count=4` + `inserted.row id=4 name=自检写入 country=ZZ` + `VERIFY summary pass` |

负向证据：**无** `command not allowed` / `not registered` 误报（说明命名权限集展开正确）、
`scope denied (sqlite)` 恰好 **1 次**、authorizer 只拦了 **1 次**（其余语句照常执行）、
被拒的 sqlite 命令都在桥侧留了原因（只读写 / ATTACH / 未知表 / 不存在的库）。

## 平台状态（如实）

| 平台 | 状态 |
| --- | --- |
| Linux（WebKitGTK） | **已实机跑通**：E2E 49/49，页内自检 36/0；链接发行版 `libsqlite3.so`（本机 3.45.1） |
| Windows（WebView2） | **未落地**：mingw 侧要自带 `sqlite3.dll` 并把它加进打包器清单，本轮没验证过（D-018 第 8 条） |

## 已知边界

- **一次一条语句**：只预编译第一条；多条请分次发（`sqlite3_prepare_v2` 就是这个语义）
- **短连接 + `busy_timeout` 3000 ms**：不做连接池 / 会话保持；库被别的进程长期写会报忙，不会无限等
- **不做表结构编辑 / 导入导出 / 图表**：这一版是「看数据 + 调试 SQL」，建表改表请用 `exec` 写 DDL
- **不做加密库（SQLCipher）/ 多库同开 / 虚拟表**：链接的是系统 sqlite3，能力就是它的能力
- **不做虚拟滚动**：一页最多 500 行，靠翻页而不是靠 DOM 里塞十万行
- **视图行数只能是 -1**：SQLite 没有「视图行数」这东西；要看成 `SELECT COUNT(*)` 自己跑
- **BLOB 看不到内容**：只回投字节数（要内容请把 `hex(封面)` 之类写进 SELECT）

## 目录结构

```
examples/sqlite-browser/
├── cjpm.toml               # 示例工程（依赖框架包 + stdx，linux 链接多一个 -lsqlite3）
├── capabilities/default.json
├── src/main.cj             # 装配：SqlitePlugin + report（很薄——能力都在插件里）
├── ui/index.html           # 全部界面（含 36 条页内自检），**独立文件**便于 node --check
├── fixture.py              # 夹具库生成器 + 进程外核对器（python3 标准库，自带 12 项自检）
├── run.sh                  # 一键转发到 scripts/e2e/test-linux-sqlite-browser.sh
└── data/                   # 工作区：fixture.db（由脚本 / fixture.py 生成，不入库）
```

两件「为什么这么写」：

- 页面**不内联**进仓颉三引号字符串：AGENTS §4 有一条实测坑——三引号字符串会先被仓颉处理反斜杠转义，
  内联进去等于让整段 `<script>` 静默语法错误（页面一行都不执行，stderr 毫无提示）。
  独立文件还顺带能被 `node --check` 静态验语法。
- 插件**不放在示例里**：SQLite 的能力面（任意库文件的任意 SQL）比「这个示例要什么」大得多，
  做成插件后别的应用引一行权限集就能用（D-018 第 1 条）。示例自己只保留了 `report` 这一条。
