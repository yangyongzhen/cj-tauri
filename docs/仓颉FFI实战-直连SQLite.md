# 仓颉 FFI 实战：不写一行 C，直连系统 libsqlite3

> 本文是 cj-tauri（仓颉版 Tauri，[AtomGit](https://atomgit.com/qq8864/cj-tauri) ｜ [QQ 技术交流群 92381027]）开发手记系列的第二篇。所有代码都来自仓内 `examples/sqlite-browser` 与 `src/plugins/sqlite/`，可直接对照阅读。

## 要解决什么问题

给 cj-tauri 加 SQLite 能力时，摆在面前有两条路：

- **走 C 桥**：像串口、对话框那样，在 `native/` 的 C 桥里包一层 `cj_bridge_*` 导出，仓颉侧经 FFI 调 C 桥；
- **直连**：仓颉的 `foreign func` 直接声明 sqlite3 的 C API，让链接器去解析系统里的 `libsqlite3.so`。

我们选了直连。理由说出来很朴素：sqlite3 的 C API 本来就是**稳定 ABI**（几十年没变过签名），中间再包一层 C 桥只会多一份要维护的胶水、多一处要同步的构建脚本，换来的只有「和别的插件形式统一」。统一有统一的价值，但在「对方已经是稳定 C API」这件事面前，胶水的维护成本是纯亏的。

这也是仓内第一个**不经 C 桥**的插件。下面的经验全部来自把它做出来的过程。

## 一、`foreign func` 的最小形状

仓颉声明外部 C 函数不需要任何头文件转换工具，手写即可：

```cangjie
foreign func sqlite3_open_v2(filename: CString, ppDb: CPointer<CPointer<Unit>>,
    flags: Int32, zVfs: CString): Int32
foreign func sqlite3_prepare_v2(db: CPointer<Unit>, sql: CString, nByte: Int32,
    ppStmt: CPointer<CPointer<Unit>>, pzTail: CPointer<CString>): Int32
foreign func sqlite3_step(stmt: CPointer<Unit>): Int32
```

三个类型覆盖了 sqlite3 全部 API 的形状：

- `CString`——字符串（sqlite3 所有文本进出都是它）；
- `CPointer<T>`——指针；`CPointer<CPointer<Unit>>` 就是 `void**`（`sqlite3_open_v2` 的出参 db 句柄）；
- 数值类型一一对应（`Int32` / `Int64` / `Float64`）。

调用点全部包在 `unsafe` 块里——这是编译器强制的，`foreign func` 不允许在安全上下文直接调：

```cangjie
let rc = unsafe { sqlite3_open_v2(cPath, ppDb, SQLITE_OPEN_READONLY, cPointerNull) }
```

`cPointerNull` 对应 C 的 `NULL`。没有引用计数、没有自动释放——FFI 边界之外，内存纪律就是 C 的纪律。

## 二、字符串是第一个坑：CString 与 String 的转换

`String` 传进 C 需要先变成 `CString`，取回来的 `CString` 要变回 `String`。两个方向我们各踩过一次：

**进方向**：sqlite3 要的路径必须以 `\0` 结尾。仓颉的 `String` 不带终止符，要用标准库做一次拷贝终止。我们把这一步封成一个私有辅助，所有进 C 的字符串都过它，不在调用点散着手写。

**出方向**：`sqlite3_column_text` 返回的 `CString` 由 sqlite3 持有，**在下一步 step 之前就会失效**。所以取值的姿势必须是「当行取、当行转、立刻交还给仓颉的 String 世界」，绝不能把 `CString` 存下来跨语句使用。转换后字符串的生命期归仓颉 GC 管，从此与 sqlite3 无关。

另一个容易忽略的点：sqlite3 返回的字节是 UTF-8，中文列名/中文数据经这一进一出不会乱码——但**前提是你别在中间做编码转换**。我们的单元格里存的就是原始 UTF-8 字节，前端展示前才统一转 `String`。

## 三、安全护栏：authorizer 是 sqlite3 自带的，不用自己造

插件命令是页面可控的（SQL 文本来自输入框），所以「只读连接」必须是内核级的，不能靠「页面上只给只读按钮」这种 UI 级承诺。sqlite3 的 `sqlite3_set_authorizer` 正好是干这个的：

```cangjie
// 授权动作码：只列我们要拒的三类
foreign func sqlite3_set_authorizer(db: CPointer<Unit>, xAuth: CFunc<(CPointer<Unit>, Int32,
    CString, CString, CString, CString) -> Int32>, pArg: CPointer<Unit>): Int32
```

回调是**仓颉函数直接当 C 函数指针传**（`CFunc<...>`），在回调里对三类动作返回 `SQLITE_DENY`：

- `SQLITE_ATTACH` / `SQLITE_DETACH`——防止挂到别的库文件上绕开 scope；
- `SQLITE_LOAD_EXTENSION`——防扩展加载（之外还先 `sqlite3_enable_load_extension(db, 0)` 关掉，**双保险**）。

实测证据（`examples/sqlite-browser` 的 E2E，49 条断言）：页面上跑 `ATTACH DATABASE ...` 得到的错误文本就是 sqlite3 内核报的 `not authorized`——不是我们前端拼的提示，这一层是真的。

同样的思路用在了第二道护栏上：标识符白名单。表名/列名在拼进 SQL 前过一遍白名单校验，引号逃逸这类手段进不来。

## 四、链接：插件子包是粒度，链接选项跟着插件走

仓颉的链接粒度是「包 = 静态库」。sqlite 插件单独一个子包（`cjTauri.plugins.sqlite`），意味着：

- **不用 sqlite 的应用**根本不会把这个包链进去，也就不需要系统装 `libsqlite3`——`link-option` 写在插件自己的目录说明里，由消费方（示例的 `cjpm.toml`）按需加 `-lsqlite3`；
- **用 sqlite 的应用**链接失败时，第一反应应该是「系统有没有 libsqlite3 开发文件」（Linux 上是 `libsqlite3-dev` / `sqlite-devel`），而不是怀疑仓颉代码。

Windows 侧我们不随包分发 `sqlite3.dll`（官方预编译 zip 是 public domain），链接用的导入库是拿 `llvm-dlltool` 从 `sqlite3.def` 现做的。这里有个通用的坑：**「按名字 LoadLibrary」的库不在 PE 导入表里**，打包工具靠解析导入表收依赖时会把它们漏掉——分发前要用 `objdump -p` 人工核对一遍导入表。

## 五、成果与自检

最终形态：`sqlite-browser` 示例（库对象树 / 分页网格 / SQL 调试台），插件层三个公开命令（库信息 / 浏览 / 只读查询 / 可写执行），安全三层（路径 scope + authorizer + 标识符白名单）。E2E 49 条断言全绿，其中最有分量的一条是**进程外复查**：另一个独立进程用 sqlite3 自己的视角只读打开库文件，核对页面写入的行真的落了盘——不拿应用的自说自话当凭证。

示例截图：

![SQLite 数据库浏览器](https://ghfast.top/https://raw.githubusercontent.com/yangyongzhen/cj-tauri/main/docs/images/example-sqlite-browser.png)

## 收尾：什么时候该直连，什么时候该走 C 桥

把我们这次的判断标准交给读者：

- **对方是稳定 C ABI 的系统库**（sqlite3、zlib、openssl 这类）→ 直连，`foreign func` 手写声明就那几行，别包胶水；
- **对方是平台 API、需要按平台分支**（GTK / Win32 / WebView2）→ 走 C 桥，把平台差异关进 `native/platforms/<平台>/`，仓颉侧只见一份接口；
- **对方需要事件循环或线程模型**（GUI、异步 IO）→ 必须走 C 桥，线程边界在 C 里管，仓颉轻量线程的协程栈过不了 JSC 这类栈边界校验。

一句话：**FFI 的边界画在「稳定 ABI」上，C 桥的边界画在「平台差异」上**。两个边界重合时（sqlite 恰好是），选省胶水的那个。

---

*仓库：[AtomGit](https://atomgit.com/qq8864/cj-tauri) ｜ [GitHub](https://github.com/yangyongzhen/cj-tauri)（MIT）· 技术交流群（QQ）：92381027*
