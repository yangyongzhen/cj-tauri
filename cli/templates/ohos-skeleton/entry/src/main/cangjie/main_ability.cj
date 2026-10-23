package ohos_app_cangjie_entry

import kit.PerformanceAnalysisKit.Hilog
import kit.AbilityKit.Want
import kit.AbilityKit.UIAbility
import kit.AbilityKit.LaunchParam
import kit.AbilityKit.LaunchReason
import kit.ArkUI.WindowStage
import ohos.display.getDefaultDisplaySync
import ohos.resource_manager.*
import cjTauri.*

/*
 * {{PROJECT_NAME}} 的 UIAbility
 *
 * 鸿蒙应用没有「自己起进程跑一个 main」这回事：窗口属于 ArkUI、页面由 ArkWeb 组件承载。
 * 所以桌面的 `main()` 在这里被拆成三段：
 * ① 把沙箱目录告诉框架（`run(html)` 要把页面落到沙箱再以 file:// 加载）；
 * ② 在**非 UI 线程**上装配并跑框架应用（`run()` 阻塞到 quit()，UI 线程要留给 ArkUI 建树）；
 * ③ 等框架把默认窗口的宿主登记好，再 `loadContent`。
 *
 * 页面与能力清单都是 hap 里的 `resources/rawfile/` 真文件，运行期读成字符串：
 *   rawfile/index.html        ← 就是桌面工程的 ui/index.html（改了重建即可）
 *   rawfile/capabilities.json ← 就是桌面的 capabilities 目录下那份 default.json
 * 好处是 DevEco 里直接点 Build 也能编过（不需要先跑一次生成脚本）。
 */
class MainAbility <: UIAbility {
    public init() {
        super()
        registerSelf()
    }

    public override func onCreate(want: Want, launchParam: LaunchParam): Unit {
        Hilog.info(1, "CjTauri", "MainAbility OnCreated.${want.abilityName}")

        // 1) 沙箱目录要在 run() 之前给定：run(html) 把页面写成文件再以 file:// 加载
        //    （ArkWeb 的仓颉绑定没有 loadData）。
        let filesDir = "${this.context.filesDir}"
        ArkWebRuntime.configure(filesDir)

        // 2) 页面与能力清单：从 hap 的 rawfile 读（读不到就是构建期没打进去，如实报一行）
        let pageHtml = this.readRawText("index.html")
        let capsJson = this.readRawText("capabilities.json")
        if (pageHtml.size == 0) {
            Hilog.info(1, "CjTauri", "rawfile/index.html 读不到，页面将只显示一句提示")
        }

        // 3) run() 会阻塞到 quit()，只能在非 UI 线程上跑——UI 线程要留给 ArkUI 建树。
        let _ = spawn { startTauriApp("{{APP_LABEL}}", pageHtml, capsJson) }

        match (launchParam.launchReason) {
            case LaunchReason.StartAbility => Hilog.info(1, "CjTauri", "START_ABILITY")
            case _ => ()
        }
    }

    public override func onWindowStageCreate(windowStage: WindowStage): Unit {
        Hilog.info(1, "CjTauri", "MainAbility onWindowStageCreate.")
        this.logDefaultWindowRect(windowStage)
        // 等框架把宿主登记上再建树：组件的 build() 只有在该 label 有宿主、页面地址非空时
        // 才渲染 `Web`。等不到也照常 loadContent——页面会自己报桥缺失，比静默白屏好排查。
        this.waitAndLogHost(DEFAULT_WINDOW_LABEL)
        windowStage.loadContent("EntryView")
    }

    /**
     * 读 hap 里的 rawfile（路径相对 `resources/rawfile/`）
     *
     * 读失败返回空串并把原因打进 hilog：调用方按「空 = 没有」降级，不让异常冒到生命周期里
     * （生命周期里抛异常，应用直接退，页面上看到的是「点了图标没反应」）。
     */
    private func readRawText(path: String): String {
        try {
            let bytes = this.context.resourceManager.getRawFileContent(path)
            Hilog.info(1, "CjTauri", "rawfile ${path} bytes=${bytes.size}")
            return String.fromUtf8(bytes)
        } catch (e: Exception) {
            Hilog.info(1, "CjTauri", "rawfile ${path} 读取失败: ${e}")
            return ""
        }
    }

    /**
     * 不干预窗口尺寸：**鸿蒙 PC 上系统给的默认窗口就是答案**
     *
     * 早先这里自己 `resize()` 定尺寸（先按屏幕比例 86%×84% = 2683×1747、后按逻辑 1000×700 vp），
     * 两版都是在跟平台的默认窗口抢方向盘：实测系统本来就按桌面形态给一扇约 2/3 屏宽的窗
     * （3120×2080 的屏上初始矩形 `[515 281 2090 1394]`，即 2090×1394 px ≈ 1100×734 vp），
     * 而紧接着的 resize 把它改成 1900×1330——屏上看到的是「先弹一个尺寸、随即变成另一个」，
     * 观感就是窗口莫名跳一下。所以模板**默认不碰窗口尺寸**，只读取矩形打一行日志作凭证；
     * 应用真需要固定尺寸时自己调 `windowStage.getMainWindow().resize()`。
     * 前提是 `entry/build-profile.json5` 的 `deviceTypes` 写成 `2in1` 且
     * `cangjieOptions.checkDeviceTypes=false` 放行——写成 phone/tablet 时系统按手机应用塞进
     * 竖屏兼容窗（约 600 宽），那种情况才需要自己定尺寸。
     */
    private func logDefaultWindowRect(windowStage: WindowStage): Unit {
        try {
            let screen = getDefaultDisplaySync()
            let screenW = Int64(screen.width)
            let screenH = Int64(screen.height)
            // `densityPixels` 是 **Float32**（.cj.d 里看着像 Float64），先化成整数百分比再参与运算。
            let densityRaw = screen.densityPixels
            let densityPct = Int64(densityRaw * 100.0)
            let mainWin = windowStage.getMainWindow()
            let r = mainWin.getWindowProperties().windowRect
            Hilog.info(1, "CjTauri", "main window keeps system default ${r.width}x${r.height} px at density ${densityPct}% on screen ${screenW}x${screenH}, rect=[${r.left} ${r.top} ${r.width} ${r.height}]")
        } catch (e: Exception) {
            Hilog.info(1, "CjTauri", "main window geometry read failed: ${e}")
        }
    }

    /**
     * 有界等待（3s）默认窗口的宿主登记完成，并把页面地址 / 预执行脚本条数打进 hilog
     *
     * 白屏定位用：宿主把页面落盘后的 file:// 地址必须非空，否则组件拿不到 src。
     */
    private func waitAndLogHost(label: String): Unit {
        var polls = 0
        while (polls < 300) {
            match (ArkWebRuntime.hostFor(label)) {
                case Some(_) => break
                case None => ()
            }
            sleep(Duration.millisecond * 10)
            polls += 1
        }
        if (polls >= 300) {
            Hilog.info(1, "CjTauri", "host not registered in 3s: label=${label}")
            return
        }
        Hilog.info(1, "CjTauri", "host registered after ${polls} polls label=${label}")
        match (ArkWebRuntime.hostFor(label)) {
            case Some(h) =>
                Hilog.info(1, "CjTauri", "host pageUrl label=${label} url=\"${h.currentUrl()}\"")
                Hilog.info(1, "CjTauri", "host initScripts label=${label} count=${h.initScriptsSnapshot().size}")
            case None => Hilog.info(1, "CjTauri", "host missing at loadContent label=${label}")
        }
    }
}
