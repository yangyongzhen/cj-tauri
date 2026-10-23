package cjTauri.platform

import std.fs.*

/**
 * 目录型资产解析器（RFC §6.2）：桌面开发期 / 发布读盘路径的默认实现
 *
 * root 为资产根（清单 [assets] root），逻辑名按 <root>/<name> 相对寻址。
 * 沙箱端实现（鸿蒙 rawfile / 内嵌常量）在各自适配层，批次 3 随清单派生接入。
 */
public class DirectoryAssetResolver <: AssetResolver {
    private let root: String

    public init(root: String) {
        this.root = root
    }

    public func readText(name: String): Option<String> {
        try {
            return Some(String.fromUtf8(File.readFrom(root + "/" + name)))
        } catch (e: Exception) {
            return None
        }
    }

    /** 以「能否读到」为准（批次 2 只服务文本资产；图标等二进制走各端资源目录，不进常量表） */
    public func exists(name: String): Bool {
        match (readText(name)) {
            case Some(_) => return true
            case None => return false
        }
    }
}
