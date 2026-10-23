# music-next（仓颉爱音乐 · 新形态）

`examples/music`（仓颉爱音乐）按 RFC-002 多端单业务代码架构的**新形态**迁移：
一份业务代码，`cj-tauri sync` 按清单派生各目标端骨架，各编各的产物。

## 与 examples/music（旧形态）的差异

| | examples/music（旧形态） | examples/music-next（本工程） |
|---|---|---|
| 工程形态 | 自己就是可执行 cjpm 工程（带 webkitgtk link-option） | 业务 static 包 + `cj-tauri.toml` 清单 + `targets/` 骨架 |
| 入口 | `src/main.cj` 的 `main()` | 骨架 launcher（`targets/*/src/main.cj`）调 `build()` |
| 页面 | `PageSource.Inline`（PACKED_UI_B64 / 读盘双路） | 清单 `[assets] page`，launcher 从 `assets/ui/index.html` 读盘 |
| 能力清单 | 项目根 `capabilities/` | `assets/capabilities/`（清单 `[capabilities] dir`） |
| 加平台 | 手工复制源码 + sed 改包名（build-hap.sh） | `cj-tauri sync desktop / ohos` |
| 单文件打包 | 支持（PACKED_* 打包脚本） | **未迁移**（批次 4 资产模型任务，RFC §6） |

业务命令层（`api.cj` / `commands.cj` / `cover.cj` / `lrc.cj`）与前端
（`assets/ui/index.html`）是**逐字节拷贝**自旧工程的，行为预期完全一致。

## 结构

```
music-next/
├── cj-tauri.toml            # 应用清单（单一真相）：id / package / windows / page / capabilities
├── cjpm.toml                # 业务 static 包（output-type = "static"）
├── src/                     # 业务代码（唯一真相，骨架以 path 依赖引用）
│   ├── main.cj              #   build(): AppSpec —— 业务装配点（零平台知识）
│   ├── api.cj               #   后台音乐接口（stdx.net.http）
│   ├── commands.cj          #   命令层（music:* / fav:* / report）
│   ├── cover.cj             #   封面
│   └── lrc.cj               #   歌词
└── assets/                  # 资产根（launcher 按清单相对它取页面与能力）
    ├── ui/index.html        #   前端页面
    └── capabilities/        #   能力白名单
        └── default.json
```

`targets/` 目录由 `cj-tauri sync` 生成（勿手改，`cj-tauri check` 会判漂移），
不进版本库（.gitignore 已覆盖）。

## 用法（桌面 Linux）

```bash
export CANGJIE_STDX=<stdx>/dynamic/stdx      # 与框架口径一致
cd examples/music-next
cj-tauri sync            # 派生 targets/desktop（+ targets/ohos）
cj-tauri build           # 桌面构建（编 targets/desktop 骨架，连带编业务 static 包）
cj-tauri run             # 运行（需要 X 显示环境；应用以项目根为工作目录）
cj-tauri check           # 三方比对（能力声明 × 插件自描述 × 无头导出）+ 骨架漂移检测
```

后台接口默认指向内网演示服务，可用环境变量 `CJ_MUSIC_API` 覆盖。
收藏文件 `music-library.local.json` 在运行后生成于工程根，不进库。

## 鸿蒙端

```bash
cj-tauri sync ohos       # 派生 targets/ohos（ohos-skeleton 模板 + 4 渲染器 + rawfile 注入）
cd targets/ohos && bash build-hap.sh
```

注意两点：

- 清单 `id`（`com.example.music_next`）与 `examples/ohos` 两个工程复用的调试签名
  包名（`com.yang.testcj`）**不同**——首次构建要在 DevEco 里对本包名重新「自动签名」
  一次（命令行做不了），之后 build-hap.sh 才能出可安装 hap。
- 能力位现状与 ohos-music 相同：鸿蒙端 `dialog:message` 是原生弹窗，
  clipboard / notification 能力位报 0 如实失败（P-1 桩策略）。

## 验收口径

新形态端到端验收（一份代码 → 桌面 main + 鸿蒙 hap）以本工程为基准：
旧 `examples/music` 保留为行为对照基线，music-next 验证通过前两者并存。
