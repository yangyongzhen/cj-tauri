package cjTauri

import std.collection.*
import cjTauri.platform.*

/**
 * 应用装配声明（批次 3，RFC-002 §4.1）：`build()` 的返回类型
 *
 * 业务只描述「应用是什么」——页面 / 窗口 / 插件 / 资产 / 命令装配点——
 * 不描述「在哪跑」：`launch(spec)` 在框架侧按目标分派（§4.2），
 * 平台知识只存在于 L0（§5）。
 *
 * 批次 3-PR1 落地形态（§4.1 的补记）：
 * - 命令装配点是 `wire` 闭包：拿到装配中的 TauriApp 后 `register`
 *   （业务命令多需要 app 自身，如 `music:quit`）。§4.4 的编译期命令表
 *   （generated registry）是批次 3 的后续 PR，届时 `wire` 收敛为类型化字段；
 * - 构造器链：RFC §4.1「示意写法；落地用构造器链」。
 */
public class AppSpec {
    /** 应用标识（与清单 [app] id 一致；生成器填入，手写装配建议补上） */
    public var appId: String = ""
    public var name: String = ""

    /** 页面来源：只有一种表达（§4.3） */
    public var pageSource: PageSource = PageSource.Asset("ui/index.html")
    /** 默认窗口配置 */
    public var windowConfig: WindowConfig = WindowConfig()
    /** 插件清单：jsShim 与命令由框架在 run 前统一注册 */
    public var plugins: ArrayList<Plugin> = ArrayList<Plugin>()
    /** 资产解析器：None = TauriApp 按 cwd 相对路径读盘（与批次 1 行为一致） */
    public var assetResolver: Option<AssetResolver> = None
    /** 能力清单目录：显式挂载 = 框架不自动扫描（目录缺失时安静返回 0，不报错） */
    public var capabilitiesDir: String = ""
    /** 命令装配点：拿到装配中的 TauriApp 后 register（字段名带 Fn：仓颉字段与方法同命名空间，不能与构造器 wire() 重名） */
    public var wireFn: Option<(TauriApp) -> Unit> = None

    public init() {}

    public func page(source: PageSource): AppSpec {
        this.pageSource = source
        return this
    }

    public func window(config: WindowConfig): AppSpec {
        this.windowConfig = config
        return this
    }

    public func plugin(p: Plugin): AppSpec {
        this.plugins.add(p)
        return this
    }

    public func assets(resolver: AssetResolver): AppSpec {
        this.assetResolver = Some(resolver)
        return this
    }

    public func capabilities(dir: String): AppSpec {
        this.capabilitiesDir = dir
        return this
    }

    public func wire(f: (TauriApp) -> Unit): AppSpec {
        this.wireFn = Some(f)
        return this
    }
}
