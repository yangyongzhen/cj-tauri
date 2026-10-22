package ohos_app_cangjie_entry

import kit.PerformanceAnalysisKit.Hilog
import kit.AbilityKit.Want
import kit.AbilityKit.UIAbility
import kit.AbilityKit.LaunchParam
import kit.AbilityKit.LaunchReason
import kit.ArkUI.WindowStage
import cjTauri.*

/*
 * 鸿蒙侧的 UIAbility（examples/ohos/ohos-music）
 *
 * 与桌面示例的关系：`examples/music` 的 `main()` 在鸿蒙上不成立——鸿蒙应用没有「自己起进程跑
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
        Hilog.info(1, "CjMusic", "MainAbility OnCreated.${want.abilityName}")

        // 1) 沙箱目录要在 run() 之前给定：run(html) 把内联页面写成文件再以 file:// 加载
        //    （ArkWeb 的仓颉绑定没有 loadData，见 src/host_arkweb.cj 文件头）。
        let filesDir = "${this.context.filesDir}"
        ArkWebRuntime.configure(filesDir)
        // 2) 收藏库（music-library.local.json）在设备上只能写沙箱：桌面的相对路径 cwd 在鸿蒙上没有意义。
        configureMusicRuntime(filesDir)

        // 3) run() 会阻塞到 quit()，只能在非 UI 线程上跑——UI 线程要留给 ArkUI 建树。
        let _ = spawn { startTauriMusic() }

        match (launchParam.launchReason) {
            case LaunchReason.StartAbility => Hilog.info(1, "CjMusic", "START_ABILITY")
            case _ => ()
        }
    }

    public override func onWindowStageCreate(windowStage: WindowStage): Unit {
        Hilog.info(1, "CjMusic", "MainAbility onWindowStageCreate.")
        // 鸿蒙 PC 上默认给的是手机形态的窄窗（实测约 600 宽），歌单 + 播放器挤成一列。
        // 在建树之前把主窗放大到桌面尺寸；拿不到窗口或系统拒绝时如实记一行，
        // 不让它挡住后面的 loadContent（页面按容器自适应，窄窗也能用）。
        try {
            windowStage.getMainWindow().resize(1440, 900)
            Hilog.info(1, "CjMusic", "main window resized to 1440x900")
        } catch (e: Exception) {
            Hilog.info(1, "CjMusic", "main window resize failed: ${e}")
        }
        // 等框架把宿主登记上再建树：组件的 build() 只有在该 label 有宿主、页面地址非空时才渲染
        // `Web`。等不到也照常 loadContent——页面会自己报桥缺失，比静默白屏好排查。
        this.waitAndLogHost(DEFAULT_WINDOW_LABEL)
        windowStage.loadContent("EntryView")
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
            Hilog.info(1, "CjMusic", "host not registered in 3s: label=${label}")
            return
        }
        Hilog.info(1, "CjMusic", "host registered after ${polls} polls label=${label}")
        match (ArkWebRuntime.hostFor(label)) {
            case Some(h) =>
                Hilog.info(1, "CjMusic", "host pageUrl label=${label} url=\"${h.currentUrl()}\"")
                Hilog.info(1, "CjMusic", "host initScripts label=${label} count=${h.initScriptsSnapshot().size}")
            case None => Hilog.info(1, "CjMusic", "host missing at loadContent label=${label}")
        }
    }
}
