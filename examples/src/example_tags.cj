package audio4cj_examples

import audio4cj.facade.AudioFile

/* ============================================================================
 * 示例三：只读标签
 *
 * 【关键点：不需要容器可解码】
 *   `AudioFile.readTags()` 只解析元数据块，因此即使容器/编码**不受支持**
 *   （如 ogg/opus、mp4/aac），大多数标签依然读得出来。
 *   这对"媒体库扫盘"这类场景很有用 —— 不必为了读标签而实现解码。
 *
 * 【返回值可为 None】
 *   各字段是 `?String` / `?Int64`，未写入的标签就是 None。
 * ========================================================================== */
func exampleTags(path: String): Int64 {
    let tag = AudioFile.readTags(path)

    println("[tags] 标题  : ${tag.title ?? "(无)"}")
    println("[tags] 艺术家: ${tag.artist ?? "(无)"}")
    println("[tags] 专辑  : ${tag.album ?? "(无)"}")
    println("[tags] 年份  : ${tag.year ?? "(无)"}")
    println("[tags] 流派  : ${tag.genre ?? "(无)"}")

    // `?Int64` 这类非字符串字段需要模式匹配取值
    let track = match (tag.track) {
        case Some(t) => "${t}"
        case None => "(无)"
    }
    println("[tags] 音轨  : ${track}")

    let cover = match (tag.coverArt) {
        case Some(bytes) => "${bytes.size} 字节（${tag.coverMime ?? "类型未知"}）"
        case None => "无"
    }
    println("[tags] 封面  : ${cover}")

    // 未被上面具名字段覆盖的标签进入 extra
    if (tag.extra.size > 0) {
        println("[tags] 其他 ${tag.extra.size} 项：")
        for ((key, value) in tag.extra) {
            println("         ${key} = ${value}")
        }
    }
    0
}
