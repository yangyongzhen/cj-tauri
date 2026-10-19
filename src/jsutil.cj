package cjTauri

import std.collection.*

/**
 * 把文本包成 JS 双引号字符串字面量（核心共享层）
 *
 * ## 为什么单独放在这里，而不是留在 `arkweb_script.cj` 里
 *
 * 调用方 `arkWebLabelScript` 带 `@When[env == "ohos"]` 门禁，桌面 `cjpm test` 根本编不到它；
 * 而这段转义**失效是静默的**：生成的脚本当场语法错误，页面里 `__CJ_TAURI_LABEL__` 永远停在
 * 默认值 `main`，事件过滤失灵却没有一行报错（AGENTS §4 的同族坑：错得不响，查起来最贵）。
 * 放到不带门禁的共享层，桌面单测就能守住它；`public` 是为了跨包单测可直接构造。
 *
 * ## 转义口径
 *
 * 只转义两样：反斜杠与双引号。入参是窗口 label（应用给定的短标识，默认 `main`），
 * 不承载换行等控制字符——**这里不是通用 JSON 编码器**，真要处理控制字符再加分支，
 * 别顺手改成「全量转义」把调用方的语义带偏。
 */
public func jsStringLiteral(text: String): String {
    let bytes = text.toArray()
    let out = ArrayList<UInt8>(bytes.size + 2)
    out.add(0x22u8)
    for (b in bytes) {
        if (b == 0x5Cu8 || b == 0x22u8) {
            out.add(0x5Cu8)
        }
        out.add(b)
    }
    out.add(0x22u8)
    return String.fromUtf8(out.toArray())
}
