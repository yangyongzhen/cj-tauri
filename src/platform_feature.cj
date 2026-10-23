package cjTauri

/**
 * 平台特性位（RFC-002 §4.5）——业务判断"这个端有没有某设施"的唯一手段
 *
 * 命名约定（评审定稿）：**看到 PlatformFeature 只谈可用性，看到 Capability 只谈权限**。
 * - 平台特性 = 本枚举：这个端的系统设施有没有（托盘、文件选择器……）；
 * - 安全能力 = CapabilitySet（capability.cj）：哪条命令允许被前端调用。
 * 两者中文都容易被叫成"能力"，类型名必须分开，否则会退化回 os 分支。
 *
 * 治理规则（RFC §13.2 问题 4）：新增一个特性位，必须同时写清三端语义与缺省降级行为，
 * 否则业务会把它当成按 OS 名分支的马甲。
 */
public enum PlatformFeature {
    | Tray               // 托盘
    | MultiWindow        // 多窗口（桌面）/ 多任务（移动端）
    | FilePicker         // 系统文件选择器
    | ClipboardImage     // 剪贴板图片读写
    | SoftKeyboardInset  // 软键盘遮挡可感知（移动端）

    /** 枚举无内建 ==（1.2.0 实测），比较走模式匹配 */
    public static func same(a: PlatformFeature, b: PlatformFeature): Bool {
        match (a) {
            case Tray => match (b) { case Tray => true case _ => false }
            case MultiWindow => match (b) { case MultiWindow => true case _ => false }
            case FilePicker => match (b) { case FilePicker => true case _ => false }
            case ClipboardImage => match (b) { case ClipboardImage => true case _ => false }
            case SoftKeyboardInset => match (b) { case SoftKeyboardInset => true case _ => false }
        }
    }
}
