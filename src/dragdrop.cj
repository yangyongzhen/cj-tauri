package cjTauri

/**
 * 拖放策略（RFC-002 §5 的 v1 落地）：框架只负责「把拖进来的文件路径交出去」，
 * 动作由页面决定（监听 `dragdrop:files` 事件，事件需在能力清单 events 里声明）。
 *
 * 策略必须在 `start()` / `startUrl()` 之前通过 `TauriApp.setDragDrop(...)` 定稿——
 * Linux 侧要在建 view 时决定挂不挂 drag dest；不设置 = 不注册（默认关，现有应用零改动）。
 */
public class DragDropPolicy {
    /** 关掉则平台层不注册 drop target（默认关） */
    public let enabled: Bool

    /** 接受文件路径（v1 唯一载荷；text 载荷留给后续版本，先不设开关） */
    public let files: Bool

    public init(enabled: Bool, files: Bool) {
        this.enabled = enabled
        this.files = files
    }

    /** 便捷构造：开文件拖入（v1 最常用形态） */
    public static func filesEnabled(): DragDropPolicy {
        return DragDropPolicy(true, true)
    }
}
