package cjTauri.tests

import cjTauri.*
import std.unittest.*
import std.unittest.testmacro.*

/*
 * 对话框「形状」判定的单元测试（共享层 `src/dialog_spec.cj`）。
 *
 * 这些判定由桌面原生对话框与鸿蒙应用侧 overlay 共用，所以放这里测——原先把判定写在
 * `host_arkweb.cj` 里，那个文件带 `@When[env == "ohos"]` 门禁，桌面 `cjpm test` 编不到，
 * 等于这段语义一直没有回归网。
 *
 * `@Test` 只能修饰**顶层函数**（写成 class 方法会报 `@Test modified function is not top level`）。
 */

/** 形状的可读名（enum 没派生 Equatable，断言走字符串比，绕开 `@Expect` 对 enum 的推断限制） */
func dialogShapeName(shape: DialogShape): String {
    match (shape) {
        case DialogShape.Message => return "message"
        case DialogShape.Confirm => return "confirm"
        case DialogShape.Prompt => return "prompt"
    }
}

@Test
func dialogKindEmptyFallsBackToInfo() {
    @Expect(normalizeDialogKind("") == "info")
    @Expect(normalizeDialogKind("   ") == "info")
}

@Test
func dialogKindTrimsAndLowers() {
    @Expect(normalizeDialogKind("  WARNING ") == "warning")
    @Expect(normalizeDialogKind("Confirm") == "confirm")
    @Expect(normalizeDialogKind("ERROR") == "error")
}

@Test
func dialogKindKeepsKnownValues() {
    @Expect(normalizeDialogKind("info") == "info")
    @Expect(normalizeDialogKind("prompt") == "prompt")
}

/* 页面把 kind 写错（打错字、传了个不存在的词）时回落 info：只影响外观，不该让对话框不弹 */
@Test
func dialogKindUnknownFallsBackToInfo() {
    @Expect(normalizeDialogKind("fatal") == "info")
    @Expect(normalizeDialogKind("警告") == "info")
}

@Test
func dialogShapeOfSingleKeyKinds() {
    @Expect(dialogShapeName(dialogShapeOf("info")) == "message")
    @Expect(dialogShapeName(dialogShapeOf("warning")) == "message")
    @Expect(dialogShapeName(dialogShapeOf("error")) == "message")
    @Expect(dialogShapeName(dialogShapeOf("")) == "message")
}

@Test
func dialogShapeOfTwoKeyKinds() {
    @Expect(dialogShapeName(dialogShapeOf("confirm")) == "confirm")
    @Expect(dialogShapeName(dialogShapeOf("PROMPT")) == "prompt")
}

/* 两键判定的口径：Confirm 与 Prompt 都要「确定 / 取消」，Message 只有一个确定键 */
@Test
func dialogShapeTwoKeyMatchesShape() {
    @Expect(dialogShapeIsTwoKey(dialogShapeOf("confirm")))
    @Expect(dialogShapeIsTwoKey(dialogShapeOf("prompt")))
    @Expect(!dialogShapeIsTwoKey(dialogShapeOf("info")))
    @Expect(!dialogShapeIsTwoKey(dialogShapeOf("fatal")))
}
