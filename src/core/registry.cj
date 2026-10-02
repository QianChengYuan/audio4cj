package audio4cj.core

import std.collection.*

/* ============================================================================
 * 泛型注册表 —— 开发文档 §3.2（registry.cj）与 §5「扩展机制」
 *
 * 设计意图：让「新增格式 = 实现一个接口 + 注册」成为可能，
 *           新增格式不牵动上层代码，这是本项目能否长期维护的分水岭。
 *
 * 用途：
 *   Registry<FormatReaderFactory>  —— 注册各容器的 demuxer 工厂
 *   Registry<DecoderFactory>       —— 注册各编码的解码器工厂
 *
 * 注意：本类型**非线程安全**（HashMap 本身非线程安全）。
 *       注册动作应集中在初始化阶段完成，运行期只读；多线程读取场景
 *       需由调用方保证初始化先行（详见开发文档 §4.7 并发契约）。
 * ========================================================================== */

/// 泛型注册表：字符串键 -> 实现对象。
public class Registry<T> {
    private let _items: HashMap<String, T> = HashMap<String, T>()

    public init() {}

    /// 注册实现。同键重复注册时后者覆盖前者。
    public func register(key: String, value: T): Unit {
        _items[key] = value
    }

    /// 按键查找实现；不存在返回 None（不代表错误，见 §4.1 铁律 1）。
    public func get(key: String): ?T {
        _items.get(key)
    }

    /// 键是否存在。
    public func contains(key: String): Bool {
        _items.contains(key)
    }

    /// 已注册条目数。
    public prop size: Int64 {
        get() {
            _items.size
        }
    }

    /// 全部已注册的键（顺序不保证）。
    public func keys(): Array<String> {
        let result = ArrayList<String>()
        for (k in _items.keys()) {
            result.add(k)
        }
        result.toArray()
    }

    /// 清空注册表（主要用于测试隔离）。
    public func clear(): Unit {
        _items.clear()
    }
}
