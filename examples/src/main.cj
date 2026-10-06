package audio4cj_examples

/* ============================================================================
 * 示例分发器
 *
 * 用法：
 *     cjpm run -- <音频文件> [示例名]
 *
 * 示例名缺省为 `stream` —— 按 M6 的要求，**示例默认展示流式用法**。
 * ========================================================================== */
main(args: Array<String>): Int64 {
    if (args.size < 1) {
        usage()
        return 2
    }

    let path = args[0]
    let name = if (args.size >= 2) {
        args[1]
    } else {
        "stream"
    }

    match (name) {
        case "stream" => exampleStream(path)
        case "async" => exampleAsync(path)
        case "tags" => exampleTags(path)
        case "info" => exampleInfo(path)
        case "verify" => exampleVerify(path)
        case _ =>
            println("未知示例：${name}")
            usage()
            2
    }
}

func usage(): Unit {
    println("用法：cjpm run -- <音频文件> [示例名]")
    println("")
    println("示例（缺省 stream）：")
    println("  stream  流式消费（FrameStream，同步拉取）—— 主 API")
    println("  async   后台解码 + 有界队列背压（AsyncFrameStream）")
    println("  tags    只读标签（不要求容器可解码）")
    println("  info    容器/编码识别与基本信息")
    println("  verify  端到端验证：声明帧数 vs 实际解出帧数 + 一行结论（不通过时返回码 1）")
}
