# 用 npm 装的 cj-tauri 写第一个 Hello World

上周把 cj-tauri 2.1.0 发上了 npm（`npx cj-tauri` 就能跑），正好有个朋友问我「你这套东西从装到看见窗口到底几步」。我拿一台干净的思路从头走了一遍，中间踩了两个坑，顺手把 demo 和这篇文章都留在了仓库里（`examples/hello-world`）。这篇就是那次走通的记录。

前提只有一个：装好[仓颉 SDK](https://cangjie-lang.cn)（1.2.0，带 stdx），并且 `CANGJIE_STDX` 指到 stdx 的 `dynamic/stdx` 目录。Node 只是为了跑 npx，18 以上就行。

## 第一步：create

```bash
npx cj-tauri@2.1.0 create hello-world --template app
```

`--template app` 是缺省模板，页面内联、零 Node 依赖。命令跑完会打印一行很实在的提示：

```
提示: cjpm.toml 里的框架路径是本机绝对路径；换机器需重新执行 create 或手改这一处。
```

这个提示值得记住，后面会踩到它。

生成的工程长这样，一共六个文件：

```
hello-world/
├── cj-tauri.toml           # 应用清单：窗口、id、页面路径、能力目录都在这
├── cjpm.toml               # 业务包（static 库）
├── src/main.cj             # 业务代码：写命令的地方
├── assets/ui/index.html    # 前端页面
├── assets/capabilities/default.json   # 能力白名单
└── README.md
```

和 Tauri 的直觉对得上：清单、后端、前端、权限声明，四件东西。

## 第二步：把模板裁成真的 Hello World

模板 `main.cj` 有 101 行，里面塞了菜单、定时器这类演示代码——教学用很好，当「最小的例子」就太吵了。我把它裁到 35 行，只留一条 `greet` 命令：

```cangjie
public class GreetCommand <: CommandHandler {
    public init() {}

    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        let _ = cmd          // greet 用不到这两个参数，
        let _ = ipc          // 不显式弃用会吃编译警告（这个项目不许带警告交付）
        var name = "world"
        if (let Some(n) <- args.get("name")) {
            match (n.kind()) {
                case JsonKind.JsString => name = n.asString().getValue()
                case _ => ()
            }
        }
        return JsonString("Hello, ${name}! 来自仓颉后端")
    }
}

public func build(): AppSpec {
    return AppSpec()
        .window(WindowConfig("hello-world", 800, 560))
        .wire({ app =>
            app.register("greet", GreetCommand())
        })
}
```

`build()` 是整个装配点：窗口尺寸在这、命令注册在这。页面是 `assets/ui/index.html`，核心就一段——

```js
t.invoke('greet', { name: 'world' })
  .then(function (d) { el.textContent = d; })
```

`window.__CJ_TAURI__` 是框架在 document-start 注入的桥，`invoke` 返回 Promise。前端只碰这一个对象，不自己 postMessage。

**最容易漏的第三处**：写完命令还得去 `assets/capabilities/default.json` 放行。只写代码不写清单，前端拿到的是 `command not allowed`；只写清单不写代码，是 `command not registered`。这套「三处联动」是刻意的——能力清单是安全模型，默认最小权限，框架不替你放行。

裁完我把 `README.md` 里那份「模型可用」式的文案删了，改成加载即自动发一次 greet——窗口一亮就能看到结果，不用解释怎么点。

## 第三步：sync 派生骨架

```bash
npx cj-tauri@2.1.0 sync desktop
```

这一步会生成 `targets/desktop/`——一个 launcher 工程，调用你业务包的 `build()`。业务包本身是 static 库，编不出可执行文件；可执行的是这个骨架。`targets/` 是生成物，不要手改（`check` 会判漂移），所以我没把它提交进仓库。

这里撞上了第一个坑。

## 坑一：两个 cjTauri

sync 完直接在 `targets/desktop` 里 `cjpm build`，报了一个没见过的错：

```
Error: modules with name 'cjTauri' in dependency tree are conflicted.
  - /root/.npm/_npx/48ee8abd628928c0/node_modules/cj-tauri
  - /root/test/cj/cj-tauri
```

同一个模块名 `cjTauri`，两条路径：launcher 的 toml 里是 **npm 缓存里的框架**（create 是 npx 跑的，它把路径写死成了 npx 那份），而我的业务包 `cjpm.toml` 指向**仓库里的框架**（我手改成了仓库相对路径 `../..`）。cjpm 一看：模块冲突，拒绝编译。

解法很简单：把 `targets/desktop/cjpm.toml` 里所有 npx 缓存路径改成和业务包同一份框架。`link-option` 里的 `-L.../native` 也一起改（C 桥静态库在那）。

如果你全程只用 npm 版（不混仓库源码），就不会撞这个——create 写的路径自洽。我是要在仓库里沉淀这个示例才混了两种来源。

## 坑二：工作目录

编出 `targets/desktop/target/release/bin/main` 之后直接跑，秒退：

```
Exception: 资产未找到：ui/index.html（请检查注入的 AssetResolver 与清单 [assets] 配置）
```

日志前几行其实已经说了实话——「已从 assets/capabilities 加载 0 个 capability 清单」。`assets/` 是**按启动时的工作目录**相对读取的，我在 `targets/desktop` 里启动，它就去找 `targets/desktop/assets/`，当然没有。

回到项目根（`hello-world/`）再启动，一次通过。

## 第四步：跑起来

在项目根启动（桌面上直接跑，或者无显示环境套一层 `xvfb-run`）：

```bash
cd hello-world
targets/desktop/target/release/bin/main 2> app.log
```

桥的 stderr 日志就是验收凭证（`2>` 存下来 grep），我的那轮长这样：

```
[cj-tauri] 已从 assets/capabilities 加载 1 个 capability 清单
[cj-bridge] host created: 0x59647c460700
[cj-bridge] set window: title=hello-world size=800x560
[cj-bridge] init scripts injected: 1
[cj-bridge] js -> native (78 bytes)
```

`set window` 那行是窗口真的建出来了；`js -> native` 那行是页面加载时自动发的那次 greet——JS → 仓颉 → JS 的完整往返，从此日志看得见。桌面会话里跑的话，窗口中央已经是绿色的 `Hello, world! 来自仓颉后端`，输入框换个名字再点，返回跟着变。

## 这次跑下来的几点感受

**create 产物是「完整的骨架」，不是「最小的例子」**。菜单、定时器这些演示代码是给第一次接触的人铺路的，想要最小版本就得自己裁——但裁的过程恰好把「命令怎么注册、能力怎么放行、页面怎么调」这三件事过了一遍，比读文档记得牢。

**「三处联动」是理解这套框架的钥匙**。代码、注册、放行，漏任何一处都会失败，而且报错文案（`command not allowed` / `command not registered`）直接告诉你漏的是哪处——这是设计出来的可诊断性，不是运气。

**两个坑都有日志指向**。模块冲突直接列出两条路径让你二选一；资产找不到时第一行日志就暴露了「加载了 0 个 capability」。遇到问题先把 stderr 看完再动手，能省很多瞎猜。

demo 和这篇文章都在仓库里：[`examples/hello-world`](https://atomgit.com/qq8864/cj-tauri/tree/main/examples/hello-world)。想加能力，从 `examples/hello` 往上看；想理解插件和打包，文档在 `docs/` 下等着。
