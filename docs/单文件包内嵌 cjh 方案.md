# 单文件包内嵌 cjh：可行性与落法（提案）

- **状态**：提案，**未实现**（2026-10-16）。本文只回答「能不能、要动哪里、判据是什么」，不含代码改动。
- **目标**：`examples/ai-chat` 的 Windows 单文件产物**自带 cjh**——目标机器不装仓颉 SDK、不装 cjh，
  双击一个 exe 就能聊起来（首次仍要在 cjh 里配一次服务商）。
- **结论**：能。但要接受一个诚实的形态——**「一个 exe + 首次运行释放几个文件」**，
  而不是「一个文件什么都不落盘」。原因不在 cjh 的代码，而在仓颉运行时的 TLS 加载器
  **按名字 `dlopen` openssl**，静态链接吃不掉它。这与本仓 `WebView2Loader.dll` 是同一类问题，
  解决办法也同一套（内嵌字节 → 首次释放 → 按绝对路径用）。

## 一、现状（本机实测 / 源码可查，不含推测）

| 事实 | 证据（可复核） |
|---|---|
| cjh 的 **Linux** 产物已自足：17 080 696 字节，`ldd` 只列 `libstdc++ / libm / libc / libgcc / vdso / ld` —— 仓颉运行时与 stdx 都不在里面 | `/root/test/cj/cjh/target/release/bin/cjh`；`cjpm.toml` 第 9 行 `compile-option = "--static --static-std"`、第 22 行 stdx 指 `static/stdx` |
| cjh 的 **Windows** 构建仍是「exe + 若干 DLL」：`winbuild.sh` 自陈产物依赖 `libboundscheck` + `libcangjie-runtime`，外加 openssl 一对（`libcangjie-dynamicLoader-opensslFFI.a` 运行时 dlopen，**须同目录**） | `cjh/scripts/winbuild.sh` 头部注释与其中的 link-option 替换（Linux 专属 `-rpath` → `-lcrypt32 -lws2_32`） |
| 本机**没有** Windows cjh 产物，交叉构建还要 `CJH_WINDOWS_STDX` 指向 windows 静态 stdx 包 | `ls /root/test/cj/cjh/target/x86_64-pc-windows-gnu/`（不存在） |
| 单文件打包器只做 Windows，且是**应用层**打包：内嵌资产 = base64 进生成的 `src/packed_assets.cj` | `scripts/pack-win-single.sh` 第 38–41 行（平台守卫）、196–209 行（生成内嵌资源） |
| **二进制**内嵌已有先例：`WebView2Loader.dll` 的字节经 `od` 生成 C 头、`-DCJ_EMBED_WEBVIEW2_LOADER` 编进桥，首次运行释放到 `%TEMP%\cj-tauri-loader\` 再 `LoadLibraryW`（幂等：比大小） | `scripts/pack-win-single.sh` 第 99–108 行；`native/platforms/windows/bridge_win.c` |
| 单文件产物的自检口径：导入表不许出现 `libcangjie-runtime.dll / libcjtbridge.dll / WebView2Loader.dll / libboundscheck.dll`，子系统必须是 GUI(2) | `scripts/pack-win-single.sh` 第 278–295 行 |
| **单文件脚本对 openssl 一对没有任何处理**（`grep -c` = 0），目录式便携包有 | `scripts/pack-win.sh` 第 145–173 行显式收集 `libssl-3-x64.dll` / `libcrypto-3-x64.dll`；`docs/分发形态实测.md` §5 已把它列为「还没验」 |
| ai-chat **还没接单文件三件套**：`src/` 只有 `main.cj` + `cjh_host.cj`，**缺** `packed_assets.cj` / `packed_resources.cj`；也没有 `dist-single/` | `ls examples/ai-chat/`；`docs/分发形态实测.md` 的 8 份单文件产物里没有 ai-chat |
| ai-chat 找 cjh 现在有三条分支：8765 上已有活的就复用 → 否则按 `CJ_AICHAT_CJH` 指的可执行文件 `launch(bin, ["web","--port",port,"--bind","127.0.0.1"])` → 没配就如实报「聊天/工具区不可用」；健康轮询 10s；只给自己拉起的那份收尾 | `examples/ai-chat/src/cjh_host.cj` 第 112 / 124-127 / 133 / 139-154 / 161 行 |
| cjh 运行期写自己的数据目录 `~/.cjh`（本机 44 MB，配置 + 会话） | `du -sh /root/.cjh` |
| cjh 仓**没有**许可证文件（`ls /root/test/cj/cjh/LICENSE*` 无结果） | 见 §七 —— 这决定「能不能把它的二进制随包分发」 |

## 二、两个平台的形态不一样，不能混着说

| | Windows | Linux |
|---|---|---|
| cjh 本身的依赖 | 静态化之后仍差 **openssl 一对 DLL**（按名加载） | 已自足（`ldd` 只有系统库），https 走**系统** openssl |
| 内嵌到宿主产物的干净程度 | 需要「首次释放 exe + 2 个 DLL 到同一目录」 | 可直接追加成真单二进制 |
| 宿主产物自身的额外前提 | 系统级 WebView2 运行时 | 系统 WebKitGTK / GTK |
| 结论 | 「一个 exe + 释放 3 个文件」 | **能做成不带随行文件的单二进制**，但省下的只是「少带一个 cjh」（WebKitGTK 仍在系统里） |

## 三、三种落法

| 方案 | 做法 | 代价 / 收益 |
|---|---|---|
| **A（推荐）内嵌字节 + 首次释放** | 把 `cjh.exe` 与两个 openssl DLL 编进宿主 exe，首次运行释放到 `%TEMP%\cj-tauri-bin\`（幂等：比大小），再以该绝对路径 spawn | 与 `WebView2Loader` 完全同招，风险最低、代码最少；代价是首次运行要写盘、体积 +17 MB 量级 |
| B 尾部载荷 + offset | cjh 字节**原样** append 到 PE 末尾，在尾部记 offset/长度，运行期从自身文件读出来释放 | 省掉 base64 的 33% 膨胀，但要自己维护「产物 + 载荷」的封装与自读逻辑（改动面比 A 大） |
| C 不做单文件 | 退回目录式便携包（`scripts/pack-win.sh`），cjh 与 DLL 平铺在目录里 | 改动最小、最不容易出错，但交付物是 zip 而不是「一个 exe」 |

**不要走「base64 进 `packed_assets.cj`」这条**：17 MB 的文件会变成 23 MB 的字符串字面量，
让仓颉编译器去编它，构建时间与内存都不划算。要么 C 侧字节数组（A），要么原样尾部载荷（B）。

## 四、必须解决的坑

1. **Windows 侧 cjh 要补静态链接**：现在只有 `--static --static-std`，要么补 `--static-libs`
   （把 `libcangjie-runtime` / `libboundscheck` 吃进去，本仓打包器就是这么干的），要么承认它们要随包。
   **待实测**——不敢先写结论。
2. **openssl 一对必须释放到 cjh.exe 同目录**：它按名字找，不在导入表里，漏了的症状是
   「窗口照起、`http://` 照通，**只有 https 全灭**」（`TlsException: Can not load openssl library or function …`，
   AGENTS §4 有完整形状）。cjh 调 LLM 必然走 https，所以这条不是可选项。
3. **释放失败要留 stderr 一行**：`WebView2Loader` 第一版只有一句 `failed to unpack …` 就毫无线索，
   新的一步失败必须把「哪一步、什么错」打出来。
4. **端口与生命周期**：8765 上可能已有用户自己的 cjh。现有「复用优先」语义要保留，
   但「内嵌实例」与「用户实例」谁是首选，得定一个口径（见 §八）。
5. **首次配置仍在 cjh 侧**：内嵌只省掉「装 cjh」，省不掉「配服务商」。`~/.cjh` 在新机器上是空的。

## 五、体积估算（粗算，最终以实测为准）

- 现有单文件产物 4.7–9.8 MB（`docs/分发形态实测.md` 一表）。
- cjh 按 Linux 的 17 MB 同量级估：走方案 A 后宿主 exe 大约 **22–27 MB**；
  若 cjh 在 Windows 侧还能 strip，会明显掉一截（cjh 当前产物是否已 strip 未确认）。
- 走方案 B 比 A 少约 5–6 MB（省掉 base64 膨胀）。

## 六、交付与验收判据

1. `objdump -p <exe>` 的导入表里**仍然只有系统 DLL**（cjh 的静态构建也要过这一条）。
2. **纯系统环境**（没装 SDK、PATH 里没有任何仓颉/openssl 目录）双击：窗口起、日志有 cjh 端点注入行、
   `/api/health` 通、发一条消息能回。
3. 释放**幂等**：第二次启动不再重写（比大小），日志里能看见「已存在，跳过」。
4. `cjh.exe` 与 `libssl-3-x64.dll` / `libcrypto-3-x64.dll` 同目录；单独删掉那一对再跑一轮，
   失败必须是**可解释的一行**（而不是静默空回复）。
5. 体积、sha256 进 `docs/分发形态实测.md` 的表（由 `scripts/dist-report.sh` 现场量，不手抄）。

## 七、许可证与登记（先决条件）

`AGENTS.md` §5 规定「引入第三方代码或资源时，必须登记其来源与许可证」。**cjh 仓里没有找到许可证文件**，
所以在把它的二进制随 ai-chat 的包分发之前，必须先：

1. 给 cjh 仓确定并放一份许可证；
2. 在本仓 `AGENTS.md` §5 的第三方清单与 `README.OpenSource.md` 里登记（名称、来源、版本/提交、许可证）；
3. 顺带确认内嵌的 openssl DLL 的来源与许可证（Windows 上那一对是随包分发的，Linux 侧由系统包提供，两边口径不同）。

## 八、未决问题（需要拍板）

1. **内嵌抽取逻辑放哪层**：`packed_resources.cj` 那套已经跨示例复用，单文件的「抽二进制再执行」
   也该跟它同层（框架侧，做成人人可用的能力），还是先只做在 ai-chat 里？倾向框架侧——否则第二个要用它的示例会复制一遍。
2. **内嵌 cjh 与用户已有 cjh 的优先级**：复用别人的实例（现状）优先，还是内嵌实例优先？
3. **要不要连 Linux 一起做**：Linux 侧更干净（cjh 已自足、openssl 走系统），收益是「少带一个 cjh」。
4. **要不要顺手补掉单文件包今天的 https 空档**（`docs/分发形态实测.md` §5 那条）——它与本方案是同一件事的两个入口。

## 九、落地步骤（真开工时的顺序）

1. 【Windows 机器】cjh 补静态构建，产出可内嵌的 `cjh.exe`；量体积、`objdump -p` 看导入表、
   确认「只差 openssl 一对」还是「还差运行时 DLL」。
2. ai-chat 接单文件三件套（`packed_assets.cj` 空存根 + `packed_resources.cj`）——**先让 ai-chat 能出不带 cjh 的单文件包**，
   把打包链路本身跑通（与 cjh 无关的第一步）。
3. 打包器加内嵌项：按方案 A 或 B 把 `cjh.exe` + 两个 openssl DLL 打进产物，并写进释放清单。
4. ai-chat 加「内嵌优先」分支：释放到 `%TEMP%\cj-tauri-bin\`（幂等）→ 用该路径 spawn（`cjh_host.cj` 加第四条分支）。
5. 真机验收（§六五条判据）+ 同步 `CHANGELOG.md`、`docs/使用文档.md` 的「单文件打包」一节、
   `docs/分发形态实测.md` 的体积表与 §5 那条「还没验」。
