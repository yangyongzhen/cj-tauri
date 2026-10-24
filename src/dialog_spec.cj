package cjTauri

/**
 * 消息框的「形状」：由 kind 归一而来，呈现层只认这三态
 *
 * ## 为什么单独抽一层
 *
 * `kind` 是页面可控的字符串（`dialog:message` 的入参），而「单键还是双键」直接决定呈现层的
 * 按钮布局与回填语义。桌面两平台的原生对话框与鸿蒙的应用侧 overlay 必须给出**同一个**判定，
 * 否则同一个 kind 在两处表现不同。原先这段判定写在 `host_arkweb.cj` 里，而那个文件带
 * `@When[env == "ohos"]` 门禁——桌面上根本无法编译，也就没有单测覆盖。
 *
 * 这里只放「语义」，不放任何呈现：按钮文案、配色、布局一律由应用侧决定（框架不猜文案）。
 */
public enum DialogShape {
    /**
     * 单键（确定）：弹出即成立，回填恒为 true
     *
     * `info` / `warning` / `error` 都归这里——它们的区别只体现在呈现的图标与配色，
     * 语义上没有第二个选择。
     */
    | Message

    /** 双键（确定 / 取消）：取消回填 false */
    | Confirm

    /**
     * 带文本输入：输入内容随回填一起交回
     *
     * 当前没有命令产生这个形状（桌面原生对话框没有 prompt 等价物，框架不造平台分叉的 API），
     * 先把它留在协议里：宿主与呈现层按形状分派，将来开放时不必再改一次接口形状。
     */
    | Prompt
}

/** 认得的 kind；其余一律按 info 处理（页面写错一个字母不该让对话框不弹） */
let DIALOG_KINDS: Array<String> = ["info", "warning", "error", "confirm", "prompt"]

/**
 * kind 归一：去首尾空白、转小写，认不出的回落 `info`
 *
 * 回落而不是报错是有意的：`kind` 只影响呈现，写错了还让命令失败等于把「外观问题」升级成
 * 「功能不可用」。归一的收益是**下游只可能见到这五个词之一**，不用各自再判一次。
 */
public func normalizeDialogKind(kind: String): String {
    let trimmed = kind.trimAscii()
    if (trimmed.size == 0) {
        return "info"
    }
    let lowered = trimmed.toAsciiLower()
    for (candidate in DIALOG_KINDS) {
        if (candidate == lowered) {
            return candidate
        }
    }
    return "info"
}

/**
 * kind → 形状（内部先归一，所以入参可以是任意字符串）
 *
 * 呈现层据此决定按钮个数与是否需要输入框；宿主据此决定回填值是布尔还是「布尔 + 文本」。
 */
public func dialogShapeOf(kind: String): DialogShape {
    match (normalizeDialogKind(kind)) {
        case "confirm" => return DialogShape.Confirm
        case "prompt" => return DialogShape.Prompt
        case _ => return DialogShape.Message
    }
}

/** 形状是否要「确定 / 取消」两键（`Prompt` 也要两键：输入完要么交回、要么放弃） */
public func dialogShapeIsTwoKey(shape: DialogShape): Bool {
    match (shape) {
        case DialogShape.Confirm => return true
        case DialogShape.Prompt => return true
        case DialogShape.Message => return false
    }
}
