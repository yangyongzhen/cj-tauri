package ohos_app_cangjie_entry

import kit.PerformanceAnalysisKit.Hilog
import kit.AbilityKit.Want
import kit.AbilityKit.UIAbility
import kit.AbilityKit.LaunchParam
import kit.AbilityKit.LaunchReason
import kit.ArkUI.WindowStage
import ohos.display.getDefaultDisplaySync
import cjTauri.*

/*
 * 鸿蒙侧的 UIAbility（examples/ohos/ohos-movie）
 *
 * 与桌面示例的关系：`examples/movie` 的 `main()` 在鸿蒙上不成立——鸿蒙应用没有「自己起进程跑
 * 一个 main」这回事，窗口属于 ArkUI，页面由 ArkWeb 组件承载。所以这里只做三件事：
 * ① 把沙箱目录告诉框架（`run(html)` 要把内联页面落到沙箱再以 file:// 加载）；
 * ② 在**非 UI 线程**上装配并跑框架应用（`run()` 阻塞到 quit，UI 线程要留给 ArkUI 建树）；
 * ③ 等框架把默认窗口的宿主登记好，再 `loadContent`（组件的 `build()` 是一次性求值，
 *    pageUrl 为空就永远不建 `Web`——白屏死锁，见 AGENTS §4 与 build 顺序的注释）。
 */
class MainAbility <: UIAbility {
    public init() {
        super()
        registerSelf()
    }

    public override func onCreate(want: Want, launchParam: LaunchParam): Unit {
        Hilog.info(1, "CjMovie", "MainAbility OnCreated.${want.abilityName}")

        // 1) 沙箱目录要在 run() 之前给定：run(html) 把内联页面写成文件再以 file:// 加载
        //    （ArkWeb 的仓颉绑定没有 loadData，见 src/host_arkweb.cj 文件头）。
        //    movie 没有本地存储要落盘，所以这里只需给页面一处可写目录。
        let filesDir = "${this.context.filesDir}"
        ArkWebRuntime.configure(filesDir)

        // 2) run() 会阻塞到 quit()，只能在非 UI 线程上跑——UI 线程要留给 ArkUI 建树。
        let _ = spawn { startTauriMovie() }

        match (launchParam.launchReason) {
            case LaunchReason.StartAbility => Hilog.info(1, "CjMovie", "START_ABILITY")
            case _ => ()
        }
    }

    public override func onWindowStageCreate(windowStage: WindowStage): Unit {
        Hilog.info(1, "CjMovie", "MainAbility onWindowStageCreate.")
        this.logDefaultWindowRect(windowStage)
        // 等框架把宿主登记上再建树：组件的 build() 只有在该 label 有宿主、页面地址非空时才渲染
        // `Web`。等不到也照常 loadContent——页面会自己报桥缺失，比静默白屏好排查。
        this.waitAndLogHost(DEFAULT_WINDOW_LABEL)
        windowStage.loadContent("EntryView")
    }

    /**
     * 不干预窗口尺寸：**直接用系统弹出来时给的那个矩形**
     *
     * 这里原先自己 `resize()` 定尺寸（先按屏幕比例 86%×84% = 2683×1747、后按逻辑 1000×700 vp），
     * 两版都在跟平台的默认窗口抢方向盘。实测系统本来就按桌面形态给一扇约 2/3 屏宽的窗：
     * 3120×2080 的屏上初始矩形 `[515 281 2090 1394]`（2090×1394 px ≈ 1100×734 vp），
     * 而我们的 resize 紧接着把它改成 1900×1330——于是屏上看到的是「先弹一个尺寸、随即变成另一个」。
     * 用户裁定按系统弹出时的尺寸来（2026-10-22），所以这里只**读取并记录**，不再 resize / moveWindowTo。
     * 前提是 `deviceTypes: 2in1` + `entry/build-profile.json5` 的 `cangjieOptions.checkDeviceTypes=false`
     * ——写成 phone/tablet 时系统按手机应用塞进竖屏兼容窗（约 600 宽），那时才需要自己定尺寸。
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
            Hilog.info(1, "CjMovie", "main window keeps system default ${r.width}x${r.height} px at density ${densityPct}% on screen ${screenW}x${screenH}, rect=[${r.left} ${r.top} ${r.width} ${r.height}]")
        } catch (e: Exception) {
            Hilog.info(1, "CjMovie", "main window geometry read failed: ${e}")
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
            Hilog.info(1, "CjMovie", "host not registered in 3s: label=${label}")
            return
        }
        Hilog.info(1, "CjMovie", "host registered after ${polls} polls label=${label}")
        match (ArkWebRuntime.hostFor(label)) {
            case Some(h) =>
                Hilog.info(1, "CjMovie", "host pageUrl label=${label} url=\"${h.currentUrl()}\"")
                Hilog.info(1, "CjMovie", "host initScripts label=${label} count=${h.initScriptsSnapshot().size}")
            case None => Hilog.info(1, "CjMovie", "host missing at loadContent label=${label}")
        }
    }
}
