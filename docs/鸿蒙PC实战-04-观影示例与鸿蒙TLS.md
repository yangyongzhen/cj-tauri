# 观影示例搬上鸿蒙 PC：后台 http 全通，只有封面全灭

> `examples/movie` 的鸿蒙 PC 版（`examples/ohos/ohos-movie`）。同一台 MateBook Pro（HAD-W32 /
> HarmonyOS 7.0.0.107 / API 26 / aarch64，3120×2080 px）。
> 这篇只讲一个坑，因为它足够典型：**片单、搜索、详情、播放地址全都正常，只有封面一张都出不来**——
> 而那个「只有 https 全灭」的形状，我在 Windows 上已经踩过一次。

![仓颉观影在鸿蒙 PC 的列表页：封面全部出图](images/example-ohos-movie.jpg)

## 现象：接口都通，图全是首字色块

首轮装上去，列表页片名、评分、分区、演职员全对，一点不像没网。但每张封面的位置都是一个
「首字色块」——页面按设计在取图失败时回退成标题首字加渐变色，所以界面不白屏、也不报错，
只是**一张真实海报都没有**。

对比音乐示例就知道不是我写错了：那个示例的接口也是 http，歌单同样拉得到。

## 两条独立的事实，必须一起看

**第一条：页面不能直连封面。** 图源是豆瓣 / 百度图床的 **https**，按 `Referer` 放行、按 UA 判浏览器。
页面直连的失败形状很坑：**HTTP 200 + 0 字节**（不是 403），页面上就是「空图」，控制台一句报错都没有。
所以桌面版从一开始就是「页面把地址交给宿主命令 → 宿主带 `Referer` / UA 取回 → 以 `data:` URL 交还」，
落点是 `examples/movie/src/commands.cj` 的 `movie:image`。这条在鸿蒙上一模一样，没有例外。

**第二条：鸿蒙上仓颉运行时装不了 TLS。** 同一套 `stdx.net.http` + `TlsClientConfig()` 在设备上直接失败，
真机 hilog 是这两行：

```
W MUSL-LDSO: load libcrypto_openssl.z.so failed, namespace=moduleNs_default, errno=2
W MUSL-LDSO: load libssl_openssl.z.so failed, namespace=moduleNs_default, errno=2
```

运行时按名字去 dlopen OpenSSL 3，设备上没有这两个库。于是 `TlsClientConfig()` 这条路在鸿蒙上根本走不通。

把两条放在一起，症状就完全成立了：**后台接口是 http → 全部正常；封面是 https → 全部失败**。
这和 `AGENTS.md` 里记的 Windows 侧「便携包漏了 `libssl` / `libcrypto`，只有 https 全灭」是同一个形状，
只是这次不是打包漏文件，而是这个平台上根本没有那两个库。

## 修法：不是补 OpenSSL，是把取图换到系统网络栈

我第一反应是「那我把 OpenSSL 塞进 hap」。停一下——ABI、符号、命名空间，任何一处对不上就是再炸一次，
而且为一个取图功能往包里塞几十 MB 的运行库，代价明显不对。

正确的做法是问一句「这个平台自己的网络栈是什么」，答案是 `ohos.net.http`（NetworkKit）：
`createHttp()` + `HttpRequest.request`，TLS、证书链、系统代理全部交给操作系统，应用侧只管发请求。
落点是一个新文件 `ohos_movie_image.cj`，里面就一个命令 `OhosMovieImageCommand`。

关键是**前端契约一行没动**：

| 项 | 桌面版 | 鸿蒙版 |
| --- | --- | --- |
| 命令名 | `movie:image` | `movie:image`（同名） |
| 入参 | 图片地址 | 同 |
| 返回值 | `data:image/...;base64,...` | 同 |
| 白名单 / UA / 5 MB 上限 | `movielib` 里那份 | **复用同一份** |

为此我把 `examples/movie/src/api.cj` 里的三个符号改成了 `public`：安全判定（`imageSourceOf` 的白名单）
**只留一份**，两个平台调同一个函数。要是鸿蒙侧另抄一份白名单，迟早会出现「这边拦了、那边没拦」。

## 两个实现细节

**① `HttpRequest.request` 只有回调形态，没有同步版本。** 命令 handler 跑在框架的 worker 线程上
（不是 UI 线程），所以「发请求 → 有界轮询等回调 → 收结果」是安全的，冻不住界面。但仓颉的
lambda **不能捕获可变的局部变量**，所以结果得装在一个对象盒子里往回调里写：

```cangjie
class ResultBox {
    var body: Array<UInt8> = Array<UInt8>()
    var contentType: String = ""
    var done: Bool = false
}
let box = ResultBox()          // 捕获 box 本身（引用），不捕获可变局部变量
http.request(url, options) { err, resp =>
    box.body = collect(resp)   // 只写 box 的字段
    box.done = true
}
```

**② 响应体按字节取，base64 自己编。** `expectDataType: HttpDataType.ArrayBuffer`，拿回字节后自己编码
（框架侧没有 base64 编码器）；`Content-Type` 从 `resp.header` 里**大小写不敏感**地找——`getFirst` 那种
写在这里不成立。

## 真机判据：通道通了，个别图源如实失败

列表页 8 张可见封面里 **7 张是真实海报**，剩下 1 张（「野兽之心」）仍然是色块。这条我没有「修」——
hilog 写得很清楚：

```
CjMovie: image http=200 bytes=0 type=image/jpeg
```

是图源自己回 **HTTP 200 + 0 字节**（防盗链），不是我的通道有问题。所以我把它当成「预期内的失败」写进
README：**取不到的图源如实回错误、页面回退成色块，不白屏、也不假装成功**。

这条判断很重要：如果当时我「为了让 8 张全绿」去给那个图源加特例，就把一个真实存在的边界条件藏起来了。

## 与音乐示例一致的两条配置

- **`deviceTypes` 写 `2in1`**，并在 `entry/build-profile.json5` 里 `cangjieOptions.checkDeviceTypes = false`
  （插件默认只放行 `phone` / `tablet`，写 `2in1` 判 `01103012`）。否则窗口是竖屏兼容窗。
- **`ohos.permission.INTERNET`**。缺了它每次请求都死成
  `SocketException: Failed to create socket: Operation not permitted.`，页面显示「连不上后台接口」，
  看着像断网。`normal` 级，装了即生效。

窗口尺寸和音乐示例一样收口：**不动它，只打一行日志**。系统按桌面形态给的默认矩形（本机 `2090×1394`）
就是合适的大小；早期版本这里打的是按屏幕比例算出来的 `2683×1747`，那个口径已经撤了。

hilog 里该有的链（`CjMovie` tag）：

```
startTauriMovie begin
capability embedded bytes=246
page loaded bytes=63810
host registered after N polls label=main
page begin label=main
main window keeps system default 2090x1394 px at density 190% on screen 3120x2080
```

## 已知限制（如实记）

- **与 ohos-music 共用一个 `bundleName`**：装这个会顶掉那个，换 bundle 要重新自动签名（命令行做不了）。
- **没有退出入口**：`movie:*` 里没有 quit，关窗口由系统处理；停进程用 `hdc shell aa force-stop`。
- **个别封面取不到**：防盗链回 `200 + 0 字节`，页面回退色块。
- **单窗口、无原生对话框**：那两条能力的取证在 `examples/ohos-probe`。

## 一句总结

这次真正救命的不是「我懂 TLS」，而是**见过同一个失败形状**：只有 https 全灭、http 一切正常，
说明问题在证书/运行时那一层，而不是业务代码。找到平台的系统网络栈、把取图换过去、保持命令契约不变，
安全判定还留在唯一一处——这比往包里硬塞一个 OpenSSL 干净得多。
