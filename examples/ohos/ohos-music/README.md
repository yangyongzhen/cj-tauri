# ohos-music · 仓颉爱音乐（鸿蒙 PC）

`examples/music` 那套「歌单 + 播放器 + 歌词」在**鸿蒙 PC**（实测 HUAWEI MateBook Pro HAD-W32 /
HarmonyOS 7.0.0.107 / API 26 / aarch64）上的落地：同一份前端页面、同一份仓颉命令层，
换掉的是宿主侧——桌面用 WebView2 / WebKitGTK，这里用 ArkWeb 组件。

首轮实机结论（2026-10-22）：页面渲染正常、热门歌曲与后台歌单加载出来、播放进度在走
（《西湖雨又风》00:17 / 03:42），窗口是**桌面形态**（可以拉宽、三栏铺开）。

## 目录与「谁是源」

```
examples/ohos/ohos-music/
├── build-hap.sh                 构建入口：同步业务层 + 内嵌页面 + 编 hap
├── build-profile.json5          签名（复用 com.yang.testcj 调试证书）
├── entry/
│   ├── cjpm.toml                只依赖框架源码（path = ../../../..）+ 工程根的 stdx 联接
│   ├── build-profile.json5      cangjieOptions.path + checkDeviceTypes=false（见下）
│   └── src/main/
│       ├── module.json5         deviceTypes: 2in1 + ohos.permission.INTERNET
│       ├── resources/           rawfile 目录（页面不走这里，见下）
│       └── cangjie/
│           ├── main_ability.cj  UIAbility：沙箱路径、非 UI 线程跑框架、等宿主登记再建树
│           ├── index.cj         ArkWeb 宿主组件（单窗口）
│           ├── music_host.cj    装配：store 插件 + music:* 命令 + 内嵌能力清单 + run(html)
│           └── musiclib/        **生成物（不入库）**：examples/music/src 的副本 + 内嵌资源
└── cjpm.toml（无）/  ui/（无）   页面与能力清单都在 musiclib 里内嵌着
```

**业务代码只有一份，在 `examples/music/`**。`build-hap.sh` 每次构建会把
`examples/music/src/*.cj`（去掉 `main.cj`）复制到 `musiclib/`，只改包声明一行
（`package music_app` → `package ohos_app_cangjie_entry.musiclib`），并把
`ui/index.html` 与 `capabilities/default.json` 以 base64 编成 `musiclib/ohos_assets.cj`。
所以：改业务逻辑去改 `examples/music`，改完重跑 `bash build-hap.sh`（`--no-sync` 可跳过同步）。

为什么不在 `entry/cjpm.toml` 里直接 `music = { path = "../../../../music" }`：music 的模块是
`output-type = "executable"`、自带 `main()`，把它当依赖编进动态模块是没验证过的形态；生成物这条路
与探针工程已跑通的构建链完全一致（entry 只依赖 `cjTauri`）。

## 两点「不这么写就不对」的配置

1. **`deviceTypes` 必须写 `2in1`**（`entry/src/main/module.json5`）。只写 `phone` / `tablet` 时
   系统把它当手机应用，窗口是**竖屏兼容窗**（实测约 600 宽，歌单与播放器挤成一列）。
   仓颉构建插件默认把 `deviceTypes` 限制成 `phone` / `tablet`（写 `2in1` 直接判 `01103012`），
   放行开关在 `entry/build-profile.json5`：`cangjieOptions.checkDeviceTypes = false`
   （插件源码 `cangjie-pre-build.js` 的 `checkCangjieDeviceTypes`）。
2. **`ohos.permission.INTERNET`**（同文件 `requestPermissions`）。缺了它每次请求都死成
   `SocketException: Failed to create socket: Operation not permitted.`，
   页面上显示的是「歌单拉取失败：连不上后台接口」——看着像断网。
   这条权限是 `normal` 级，安装即生效，不需要弹窗授权。

## 构建与运行

```bash
export CANGJIE_STDX_OHOS=/d/cangjie-stdx-ohos/linux_ohos_aarch64_cjnative/dynamic/stdx
export DEVECO_WIN='D:\oh\DevEcoStudio'      # DevEco 安装根，不在默认位置才需要
bash examples/ohos/ohos-music/build-hap.sh  # 产物：entry/build/default/outputs/default/entry-default-signed.hap

HDC=/d/oh/DevEcoStudio/sdk/default/openharmony/toolchains/hdc.exe
"$HDC" -t <serial> install -r entry/build/default/outputs/default/entry-default-signed.hap
"$HDC" -t <serial> shell aa force-stop com.yang.testcj      # 换包后先停旧实例
"$HDC" -t <serial> shell aa start -a EntryAbility -b com.yang.testcj
```

取证（两条都要）：

```bash
"$HDC" -t <serial> shell hilog > /tmp/music-hilog.txt        # 先起流，再 aa start
"$HDC" -t <serial> shell snapshot_display -f /data/local/tmp/x.jpeg
MSYS_NO_PATHCONV=1 "$HDC" -t <serial> file recv /data/local/tmp/x.jpeg x.jpeg   # 远端绝对路径不加这个会被 MSYS 改写
```

hilog 里应有的行（`CjMusic` tag）：

```
MainAbility OnCreated.<ability>
host registered after N polls label=main
host pageUrl label=main url="file:///data/storage/el2/base/haps/entry/files/cj-tauri-main.html"
page begin label=main    /    page end label=main
main window resized to 1440x900
```

`aa start` 需要**屏幕已解锁**（开发者模式下无法自动解锁），锁屏时表现为启动失败 / 抓到锁屏画面。

## 已知限制（如实记）

- **`music:quit` 在设备上不退出进程**：它只置框架的退出意图，鸿蒙侧的进程生命周期归系统管，
  页面侧表现为「已经退出」。要真退出用 `aa force-stop` 或关闭窗口。
- **`music:config` / `fav:*` 落沙箱**：`<filesDir>/music-library.local.json`（桌面版是项目根的
  相对路径）。卸载即清。
- **窗口尺寸**：`onWindowStageCreate` 里 `getMainWindow().resize(1440, 900)`，系统按自身窗口缩放
  折算（实测物理 2156×1324 ≈ 逻辑 1078×662），用户可自己拉伸。
- **多窗口 / 原生对话框不在本工程**：一扇窗、无 overlay；那两条能力的取证留在
  `examples/ohos-probe`（AGENTS §4 的「鸿蒙侧弹窗只能声明式」）。
