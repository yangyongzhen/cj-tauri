package cjTauri

import std.collection.ArrayList
import cjTauri.platform.*

/**
 * 宿主提供者注册表（RFC-002 §5.1）——取代单槽 setHostFactory 的多宿主入口
 *
 * 为什么是"优先级"而不是布尔匹配：同一 os 下会有多个宿主——鸿蒙 ArkWeb 与
 * ARM64 Linux 桌面的 os 都报 Linux，Android 与 Linux 同理；整数优先级让
 * 「专用实现压过通用实现」成为数据而不是 if 顺序。
 *
 * 与 setHostFactory 的关系：后者是单槽特例，批次 1 接入装配层时由本注册表
 * 统一接管；在此之前两者并存、互不影响（批次 0 不改现有装配，见 RFC §12）。
 */
public interface HostProvider {
    /** 0 = 不匹配；>0 越大越优先 */
    func priority(target: TargetInfo): Int64
    /** 一个 label 一个宿主实例（多窗口事件按 label 路由，见 host.cj HostRoute） */
    func create(label: String, target: TargetInfo): WebViewHost
}

private var HOST_PROVIDERS: ArrayList<HostProvider> = ArrayList<HostProvider>()

/** 注册宿主提供者：**必须在构造 TauriApp() 之前**（宿主在字段初始化时就创建，
 *  与 setHostFactory 同一约束）；幂等性由调用方保证，重复注册按优先级取胜者。
 *  返回注册下标（测试反注册用） */
public func registerHost(provider: HostProvider): Int64 {
    let idx = HOST_PROVIDERS.size
    HOST_PROVIDERS.add(provider)
    return idx
}

/** 已注册数量（自检 / 测试用） */
public func hostProviderCount(): Int64 {
    return HOST_PROVIDERS.size
}

/**
 * 反注册（测试用）：全局注册表是进程级的，用例注册的探针宿主不清走会污染后续用例
 * （优先级平局 / 抢占都取决于注册先后）。业务侧没有场景该调它。
 * 接口引用没有可用的相等比较（`!=` 与 `equal` 都不提供），所以按注册下标定位。
 */
public func unregisterHost(index: Int64): Unit {
    if (index >= 0 && index < HOST_PROVIDERS.size) {
        // remove 收区间（start 含、end 不含）：单元素 = index..index+1
        HOST_PROVIDERS.remove(index..index + 1)
    }
}

/**
 * 按 TargetInfo 选出优先级最高的宿主并创建
 *
 * 框架内部装配用（批次 1 的 createHost 会走这里）；没有匹配者返回 None，
 * 由调用方给出可照做的错误——与 host_factory.cj「不静默回落」同一约定。
 */
public func pickHost(label: String, target: TargetInfo): Option<WebViewHost> {
    var best: Option<HostProvider> = None
    var bestPriority: Int64 = 0
    for (p in HOST_PROVIDERS) {
        let pr = p.priority(target)
        if (pr > bestPriority) {
            bestPriority = pr
            best = Some(p)
        }
    }
    match (best) {
        case Some(p) => return Some(p.create(label, target))
        case None => return None
    }
}

/**
 * 装配层的宿主解析（批次 1 接线，RFC §5.4）：注册表优先，内置实现兜底
 *
 * app.cj 的 TauriApp 构造与 addWindow 都走这里；原有 @When 门禁的 createHost
 * 三分支原样保留为兜底（桌面 WebKit/WebView2、鸿蒙 ArkWeb），既有行为不变。
 * 注册表的优先级 > 0 才参与，因此「应用显式注册」永远压过内置默认。
 * （public：装配层与测试子包 cjTauri.tests 都要引用；业务侧正常不会直接调用。）
 */
public func resolveHost(label: String): WebViewHost {
    let target = Platform.guessTarget()
    match (pickHost(label, target)) {
        case Some(h) => return h
        case None => return createHost(label)
    }
}
