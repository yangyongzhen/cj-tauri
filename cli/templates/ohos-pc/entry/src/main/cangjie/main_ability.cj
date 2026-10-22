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
        this.applyDesktopWindowSize(windowStage)
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
     * 把主窗设成「桌面应用」的默认量级并居中
     *
     * **按逻辑尺寸定，不按屏幕比例定**：桌面应用的默认窗口应当是「与屏幕大小无关的一扇窗」，
     * 换分辨率 / 换缩放都不该变成另一副样子。所以取 1000×700 vp（≈ 框架 `WindowConfig`
     * 默认的 900×640 那一档），再用屏幕密度 `densityPixels` 折算成像素——
     * **`resize()` 收的是像素，不是 vp**（实测：传 1440×900 后窗口矩形就是 `[515 281 1440 900]`，
     * 而屏幕是 3120×2080 px——只占屏宽 46%）。
     * 折算后按屏幕 82% 封顶：小屏上不超出可用区域（还要留标题栏与任务栏），
     * 到底被夹没夹看日志里 `want` 与 `cap` 两段。想改默认大小就改 `targetWVP` / `targetHVP`。
     */
    private func applyDesktopWindowSize(windowStage: WindowStage): Unit {
        try {
            let targetWVP: Int64 = 1000
            let targetHVP: Int64 = 700
            let screen = getDefaultDisplaySync()
            let screenW = Int64(screen.width)
            let screenH = Int64(screen.height)
            // 密度读不到就按 1:1 折算：宁可窗口偏小，也不凭空放大到屏外。
            // 注意 `densityPixels` 是 **Float32**（d.ts 里看着像 Float64），直接和 Float64 相乘编不过，
            // 所以先化成整数百分比（2 倍密度 → 200），后面全程整数运算。
            let densityRaw = screen.densityPixels
            var densityPct = Int64(densityRaw * 100.0)
            if (densityPct <= 0) {
                densityPct = 100
            }
            let wantW = targetWVP * densityPct / 100
            let wantH = targetHVP * densityPct / 100
            let capW = screenW * 82 / 100
            let capH = screenH * 82 / 100
            var pxW = wantW
            var pxH = wantH
            if (pxW > capW) {
                pxW = capW
            }
            if (pxH > capH) {
                pxH = capH
            }
            let w = UInt32(pxW)
            let h = UInt32(pxH)
            let mainWin = windowStage.getMainWindow()
            mainWin.resize(w, h)
            mainWin.moveWindowTo(Int32((screenW - Int64(w)) / 2), Int32((screenH - Int64(h)) / 2))
            // 事后查询复核：resize 不抛异常不代表尺寸生效（「我调过了」不算凭证）。
            // 但不能紧跟着就读——平台回填窗口矩形是异步的，立刻读到的是过渡值
            // （实测 2026-10-22：请求 2683x1747，紧跟读到 [515 281 2090 1394]，而屏上窗口确实是 2683x1747）。
            // 有界轮询到与请求一致为止；等不到就如实报最后读到的那个值。
            var r = mainWin.getWindowProperties().windowRect
            var polls = 0
            while (polls < 30 && (r.width != w || r.height != h)) {
                sleep(Duration.millisecond * 10)
                r = mainWin.getWindowProperties().windowRect
                polls += 1
            }
            Hilog.info(1, "CjTauri", "main window sized ${w}x${h} px = ${targetWVP}x${targetHVP} vp at density ${densityPct}% (want ${wantW}x${wantH} cap ${capW}x${capH}) on screen ${screenW}x${screenH}, rect=[${r.left} ${r.top} ${r.width} ${r.height}] after ${polls} polls")
        } catch (e: Exception) {
            Hilog.info(1, "CjTauri", "main window sizing failed: ${e}")
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
