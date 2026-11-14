package ionic_components

import cjTauri.*

/**
 * 业务装配点（RFC-002 §4.1）：骨架的 launcher（targets/ 下各目标的 src）调用它取 AppSpec。
 *
 * 本示例是**纯前端组件陈列**——后端不注册任何业务命令，`AppSpec` 上连 `.wire()` 都不用挂
 * （wireFn 可选，框架内置的 system:version 仍会自动注册，About 页用它证明桥通）。
 * 窗口给宽一点（组件 gallery 需要横向空间；尺寸与清单 [[windows]] 一致，launcher 会再按清单覆盖）。
 */
public func build(): AppSpec {
    let spec = AppSpec()
        .window(WindowConfig("Ionic Gallery · cj-tauri", 1000, 720))
    spec.name = "Ionic Gallery · cj-tauri"
    return spec
}
