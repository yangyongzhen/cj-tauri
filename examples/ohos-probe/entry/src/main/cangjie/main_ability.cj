package ohos_app_cangjie_entry

import kit.PerformanceAnalysisKit.Hilog
import kit.AbilityKit.Want
import kit.AbilityKit.UIAbility
import kit.AbilityKit.LaunchParam
import kit.AbilityKit.LaunchReason
import kit.ArkUI.WindowStage
import cjTauri.*

class MainAbility <: UIAbility {
    public init() {
        super()
        registerSelf()
    }

    public override func onCreate(want: Want, launchParam: LaunchParam): Unit {
        Hilog.info(1, "Cangjie", "MainAbility OnCreated.${want.abilityName}")
        Hilog.info(1, "Cangjie", "OS_PROBE=${OS_PROBE}")

        // 1) 沙箱目录要在 run() 之前给定：run(html) 把内联页面写成文件再以 file:// 加载
        //    （ArkWeb 的仓颉绑定没有 loadData，见 src/host_arkweb.cj 文件头）。
        ArkWebRuntime.configure("${this.context.filesDir}")

        // 2) run() 会阻塞到 quit()，只能在非 UI 线程上跑——UI 线程要留给 ArkUI 建树。
        let _ = spawn { startTauriProbe() }

        match (launchParam.launchReason) {
            case LaunchReason.StartAbility => Hilog.info(1, "Cangjie", "START_ABILITY")
            case _ => ()
        }
    }

    public override func onWindowStageCreate(windowStage: WindowStage): Unit {
        Hilog.info(1, "Cangjie", "MainAbility onWindowStageCreate.")
        // 等框架把宿主登记上再建树：组件的 build() 只有在该 label 有宿主、页面地址非空时才渲染
        // `Web`，而 ArkUI 的树是声明式的一次性求值——首帧空着就再也没有第二次机会。
        // **每个窗口各等一次**：只等默认窗口时，第二扇窗的组件读到的 pageUrl 还是空串，
        // 于是它永远不建 `Web`、`onPageBegin` 永不触发（与单窗口白屏是同一个死锁）。
        this.waitAndLogHost(DEFAULT_WINDOW_LABEL)
        this.waitAndLogHost(SECOND_WINDOW_LABEL)
        windowStage.loadContent("EntryView")
    }

    /**
     * 有界等待（3s）某个 label 的宿主登记完成，并把页面地址 / 预执行脚本条数打进 hilog
     *
     * 等不到就如实打一行后照常进页面（页面会自己报桥缺失）——不静默拖到超时。
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
            Hilog.info(1, "Cangjie", "host not registered in 3s: label=${label}")
            return
        }
        Hilog.info(1, "Cangjie", "host registered after ${polls} polls label=${label}")
        // 白屏定位：宿主把页面落盘后的 file:// 地址就是组件 build 时读到的地址。
        // 多窗口下两扇窗的地址必须不同（各有各的 cj-tauri-<label>.html），否则报告的是同一份页面。
        match (ArkWebRuntime.hostFor(label)) {
            case Some(h) =>
                Hilog.info(1, "Cangjie", "host pageUrl label=${label} url=\"${h.currentUrl()}\"")
                Hilog.info(1, "Cangjie", "host initScripts label=${label} count=${h.initScriptsSnapshot().size}")
            case None => Hilog.info(1, "Cangjie", "host missing at loadContent label=${label}")
        }
    }
}
