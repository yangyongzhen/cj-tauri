package ohos_app_cangjie_entry

import kit.AbilityKit.AbilityStage
import kit.PerformanceAnalysisKit.Hilog

/*
 * AbilityStage：模块级入口（module.json5 的 srcEntry 指向它）
 *
 * 只打一行 hilog。鸿蒙侧排查的第一句话是「AbilityStage 有没有被创建」——
 * 应用启动即崩（比如框架包初始化链坏了）时，hilog 里连这一行都没有，
 * 而 CANGJIE-RUNTIME 的行照常在，很容易被误读成「生命周期卡死」。
 */
class MyAbilityStage <: AbilityStage {
    public override func onCreate(): Unit {
        Hilog.info(1, "CjTauri", "MyAbilityStage onCreated.")
    }
}
