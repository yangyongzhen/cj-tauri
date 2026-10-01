# {{PROJECT_NAME}}

基于 [cj-tauri]({{FRAMEWORK_ROOT}})（仓颉版 Tauri）的应用：**仓颉后端 + 系统 WebView 前端**，
通过 `window.__CJ_TAURI__` 做 invoke/listen 双向 IPC，并由 capability 清单做最小权限管控。

## 目录结构

```
{{PROJECT_NAME}}/
├── cjpm.toml              # 应用构建配置（依赖 cj-tauri 框架）
├── src/main.cj            # 仓颉入口：命令注册 + 能力挂载 + 启动
├── ui/index.html          # 前端页面（任意 Web 技术栈）
└── capabilities/default.json  # 能力白名单（命令 / 事件）
```

## 运行

```bash
# 开发：构建 C 桥 + 编译 + 启动窗口
cj-tauri dev

# 仅构建 / 仅运行
cj-tauri build
cj-tauri run
```

不带 CLI 时手动运行：

```bash
cjpm build
# 需要把「框架 native 目录 + stdx 目录 + 仓颉运行时目录」加入动态库搜索路径后，
# 在项目根目录（capabilities/ 与 ui/ 是相对路径读取）启动：
#   Linux:   LD_LIBRARY_PATH=<native>:<stdx>:<cangjie runtime/lib> ./target/release/bin/main
#   Windows: set PATH=<native>;<native>\webview2;<stdx>;<cangjie>\runtime\lib\windows_x86_64_cjnative;%PATH%
#            target\release\bin\main.exe
```

## 加一个命令

1. 在 `src/main.cj` 实现 `CommandHandler`：

```cangjie
public class PingCommand <: CommandHandler {
    public init() {}
    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        return JsonString("pong")
    }
}
```

2. 注册：`.register("ping", PingCommand())`
3. 在 `capabilities/default.json` 的 `commands` 里声明 `"ping"`（**不声明会被拒绝**）
4. 前端调用：`window.__CJ_TAURI__.invoke('ping').then(...)`

## 后端推事件

```cangjie
var payload = JsonObject()
payload.put("n", JsonInt(1))
ipc.emit("tick", payload)     // 需在 capabilities 的 events 中声明 "tick"
```

```js
window.__CJ_TAURI__.listen('tick', function (payload) { console.log(payload.n); });
```

## 文档

框架完整文档：`{{FRAMEWORK_ROOT}}/README.md` 与 `{{FRAMEWORK_ROOT}}/docs/使用文档.md`
