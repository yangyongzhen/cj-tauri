# cookie-export · cspub 凭证助手

把「F12 里手抄 Cookie」这件事变成一次登录 + 一次点击：窗口里打开平台登录页，登录完点「已登录，提取 Cookie」，
工具从**原生 cookie store** 里读全量 Cookie，逐字段校验 cspub 是否够用，然后一次性写成 cspub 能直接读的文件。

这是 [cj-tauri](../../README.md) 的示例工程，同时是 [cspub](https://atomgit.com/qq8864/cspub) 的配套工具。

## 为什么不用 `document.cookie`

决定性的字段大多是 **httpOnly**：知乎的 `z_c0`、掘金的 `sessionid`、CSDN 的 `UserToken`。
JS 侧 `document.cookie` 读不到它们，抄出来的文件「看着有内容」，一发文就是 401——比读不出来更难查。

所以这里走原生 CookieManager：
`libcjtbridge.so` 导出 `cj_bridge_get_cookies` → Linux 调 `webkit_cookie_manager_get_all_cookies`，
Windows 调 `ICoreWebView2_2::get_CookieManager` → 拿到的是全量快照，含 httpOnly。

内嵌登录视图与主窗口共享同一个 WebKit context / WebView2 environment，所以在登录视图里登录后的会话，
主窗口这条读取通路能直接看到——不需要回传通道，也不需要往别人的页面里注入桥。

## 支持平台与必需字段

字段清单来自真实读取点，不是猜的：前 5 家对着 cspub 源码逐条核对，后 4 家为待支持平台，
字段来自 2026-11 的接口实测 + 可用实现核对（详见 cspub `docs/多平台发文调研.md`）。

| 平台 | 标识 | 必需字段 | 消费方 / 依据 |
| --- | --- | --- | --- |
| CSDN | `csdn` | `UserToken`、`UserName`、`UserNick` | 签名需 `UserToken`，身份读 `UserName`/`UserNick` |
| 知乎 | `zhihu` | `z_c0`、`XSRF-TOKEN` | `src/zhihu.cj` |
| 掘金 | `juejin` | `sessionid` | `src/juejin.cj` |
| 开源中国 | `oschina` | `oscid` | `src/oschina.cj` |
| 百家号 | `baijiahao` | `BDUSS` | `src/main.cj` |
| 腾讯云开发者社区 | `tencent` | `skey`、`qcommunity_session` | `addArticle` 纯 Cookie 鉴权，无请求签名 |
| 今日头条 | `toutiao` | `sessionid`、`csrftoken` | `mp/agw/article/publish`；`csrftoken` 要回写 `X-CSRFToken` |
| 小红书 | `xiaohongshu` | `web_session`、`a1` | `a1` 是设备指纹，签名取它前/后 16 字节做 AES key/iv |
| 语雀 | `yuque` | `_yuque_session`、`yuque_ctoken` | `yuque_ctoken` 作 `x-csrf-token` 头 |

CSDN 导出的是**整串 Cookie**（cspub 侧对 CSDN 用的是完整 Cookie 头），其余平台导出各自平台域下的整串。
缺失的必需字段会在卡片上标红，不会让你拿着一个「能导出但发不了文」的文件走。

**为什么没有 SegmentFault / 51CTO**：这两家的发文 token 不是固定 cookie，而是当场从页面 HTML 里刮
（SegmentFault 刮 `/write` 的 `serverData.Token`，51CTO 刮 `<meta name="csrf-token">`）。
没有可靠的「必需字段名」就不硬编一个——字段判错比不判更误导人。等发文端定下实现再补。

## 构建

```bash
# 1. 原生桥（仓库根执行；产物是 native/libcjtbridge.so，被框架和应用共用）
bash native/build_linux.sh

# 2. 本工程
cd examples/cookie-export
export CANGJIE_HOME=/opt/cangjie-1.2.0/cangjie
export PATH=$CANGJIE_HOME/bin:$CANGJIE_HOME/tools/bin:$PATH
# stdx 的 cjo 在 static/stdx 下（dynamic/stdx 只有 .so，编不过）
export CANGJIE_STDX=/root/.cangjie/stdx/cangjie-stdx-linux-x64-1.2.0.1/linux_x86_64_cjnative/static/stdx
cjpm build
```

运行（GUI，需要显示）：

```bash
export LD_LIBRARY_PATH=$CANGJIE_HOME/runtime/lib/linux_x86_64_cjnative:$CANGJIE_HOME/third_party/llvm/lib:/root/.cangjie/stdx/cangjie-stdx-linux-x64-1.2.0.1/dynamic/stdx:$(git rev-parse --show-toplevel)/native
./target/release/bin/main
```

无显示环境（CI/服务器）用虚拟屏跑：

```bash
Xvfb :120 -screen 0 1280x900x24 -nolisten tcp &
DISPLAY=:120 ./target/release/bin/main
```

## 用法

1. 卡片上点「登录」，窗口内嵌出该平台登录页（扫码/密码都行，凭据不经过本工具）。
2. 登录完成后点面板左下「已登录，提取 Cookie」（或关闭面板后在卡片上点「提取」）。
3. 卡片显示已提取的字段状态：绿色=齐了，黄色=缺必需字段，灰色=还没有 cookie。
4. 点「导出」写盘；可一次导出多个平台（每个平台卡片各自导出，写到同一份 config.json）。

导出位置（自己家目录，**不进仓库、不外传**）：

| 产物 | 内容 | 权限 |
| --- | --- | --- |
| `~/.cspub/config.json` | 合并写，保留文件里其它平台的键 | 600 |
| `~/.cspub/cookie_<平台>` | 该平台的整串 Cookie（便于 `CSPUB_*_COOKIE` 或手工粘贴） | 600 |

`config.json` 是**合并写**：文件里已有的键（别的平台、AtomGit token、博客园配置）原样保留，
只覆盖本次导出的平台对应字段。

## 和 cspub 的对接

导出的键名与 cspub `loadConfigString` 的调用点逐字对应：

| 平台 | config.json 键 | 环境变量（优先级更高） |
| --- | --- | --- |
| CSDN | `csdnCookie` | `CSPUB_CSDN_COOKIE` |
| 知乎 | `zhihuCookie` | `CSPUB_ZHIHU_COOKIE` |
| 掘金 | `juejinCookie` | `CSPUB_JUEJIN_COOKIE` |
| 开源中国 | `oschinaCookie` | `CSPUB_OSCHINA_COOKIE` |
| 百家号 | `baijiahaoCookie` | `CSPUB_BAIJIAHAO_COOKIE` |
| 腾讯云开发者社区 | `tencentCookie` | `CSPUB_TENCENT_COOKIE` |
| 今日头条 | `toutiaoCookie` | `CSPUB_TOUTIAO_COOKIE` |
| 小红书 | `xiaohongshuCookie` | `CSPUB_XIAOHONGSHU_COOKIE` |
| 语雀 | `yuqueCookie` | `CSPUB_YUQUE_COOKIE` |

> 后四家的 config 键已在本工具落盘、并被合并写的保留清单接纳，但 cspub 发文端尚未实现对应平台
> （见 cspub `docs/多平台发文调研.md` 的推荐顺序）。先导出不会浪费：发文端补上即直接可用。

导出后直接：

```bash
cspub publish 文章.md --platform csdn
cspub publish 文章.md --platform zhihu
```

- 凭证只落本地文件，工具本身不联网、不上传（登录页是平台自己的页面，流量与浏览器一致）。
- `baijiahaoAppId`/`baijiahaoAppToken`、`cnblogsBlogId`/`cnblogsUsername`/`cnblogsToken` 这些**不是 cookie**，
  本工具不碰；合并写会原样保留它们在 config.json 里的值。
- 博客园走的是 MetaWeblog 令牌，不是登录 Cookie，所以 9 个 Cookie 平台里没有它（工具不提供它，属于设计而非缺漏）。

## 实机验证记录（Linux / WebKitGTK 2.52.3 / Xvfb）

| 环节 | 证据 |
| --- | --- |
| 界面渲染 | 9 张平台卡、字段 chip、登录/提取/导出按钮全部正常（2026-11 扩到 9 家后复验） |
| 新增登录口 | 腾讯云卡片点「登录」→ 内嵌载入 `https://cloud.tencent.com/login`，扫码/邮箱/QQ/子用户等登录方式完整渲染 |
| cookie 读取通路 | 日志 `get_cookies: filter=(all) -> 34 bytes`（空 store 时的合法空返回） |
| 内嵌登录视图 | 卡片点「登录」后窗口内载入 `https://passport.csdn.net/login`（CSDN 登录页完整渲染） |
| 共享 cookie store | 登录页加载后同一次提取返回 `3537 bytes`——内嵌视图写入的 cookie 被主窗口通路读到 |
| 状态语义 | 无 cookie 显示灰色「未提取」，缺字段显示黄色告警，不再误报「读取失败」 |
| 运行期告警 | `g_object_unref: assertion 'G_IS_OBJECT' failed` 已归零（修的是框架既有的 `on_js_done`） |

复现验证（无显示环境）：

```bash
Xvfb :120 -screen 0 1280x900x24 -nolisten tcp &
DISPLAY=:120 ./target/release/bin/main &
# 键盘可达：Tab 聚焦按钮、Return 触发（Xvfb 下合成的鼠标点击 WebKit 不接收）
xdotool search --name 'Cookie' | head -1 | xargs -I{} xdotool windowfocus {}
xdotool key --clearmodifiers Tab; xdotool key --clearmodifiers Return
```

## 测试

`src/cookie_store_test.cj` 覆盖导出链路里「出错也不报错、只会静默毁数据」的那几块：桥回包解析、
域过滤、Cookie 头拼接、必需字段判定，以及**合并写 config.json 不会抹掉别的平台凭证**。

```bash
cjpm test
# 注意：测试二进制同样要能加载 libcjtbridge.so，LD_LIBRARY_PATH 里要带仓库的 native/ 目录
export LD_LIBRARY_PATH=...:/root/test/cj/cj-tauri/native
```

样例 JSON 直接抄 C 桥的真实回包形状（`{"ok":true,"cookies":[…]}`），不另造格式——
桥改了字段，这些用例先红，而不是等到发文 401。

## 已知限制

- **Windows 侧运行未验证**：`native/platforms/windows/bridge_win.c` 里的 WebView2 cookie 读取已按
  `ICoreWebView2_2::get_CookieManager` 的官方签名实现，并过了 mingw `-fsyntax-only` 语法检查，
  但没有 Windows 机器实测过。「编译通过 ≠ 跑通」，首次在 Windows 上使用请先用一个平台验证。
- Cookie 有效性有时效：导出的是导出那一刻的会话，平台侧退出登录/换密码/风控会让它失效，重新登录再导一次即可。
- 平台可能改字段：字段清单是「当前 cspub 读取点」的镜像，cspub 若改了读取字段，这里要同步（`src/platforms.cj`）。
- 内嵌登录视图**不注入桥**（沿用 ai-chat 的安全边界）：外部页面拿不到任何宿主能力，只能显示。

## 代码结构

| 文件 | 职责 |
| --- | --- |
| `src/platforms.cj` | 9 个平台的定义表：标识、登录页、cookie 域名过滤、必需字段 |
| `src/cookie_store.cj` | 解析 cookie JSON、按平台拼整串、写 config.json 与文本文件（含 600 权限） |
| `src/cookie_cmd.cj` | 命令层：`cookie:platforms` / `cookie:probe` / `cookie:export` |
| `src/login_view.cj` | 内嵌登录视图的显示/隐藏/关闭与页面 URL 回显 |
| `src/main.cj` | 插件装配与命令注册 |
| `assets/ui/index.html` | 前端：平台卡片、状态徽标、字段 chip、导出与提示 |
| `capabilities/app.json` | 能力白名单（命令三处联动的第二处） |

改命令记得三处一起改：`main.cj` 的 `app.register` + `capabilities/app.json` 的 `commands` + 页面里的 `invoke`。
漏了第二处不会编译报错，而是前端调用被拒（表现为卡片空白）。

