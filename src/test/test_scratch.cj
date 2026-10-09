/**
 * 测试临时产物的统一落点。
 *
 * 各用例「就地构造素材」时会写出一批 `a4cj_*` 音频（CRC 变体、SEEKTABLE 变体、
 * 损坏样本、标签样本……）。它们原先直接写在**当前工作目录**（仓库根）：虽然
 * `.gitignore` 用 `/a4cj_*` 忽略掉了、不会污染提交，但仓库根仍会堆二十多个文件 ——
 * 既碍眼，也容易被误当成源码。
 *
 * 现在统一写到 [TEST_TMP_DIR]：
 *   · 仓库根目录保持干净（用例自己给的文件名不变，只是多了一层目录）；
 *   · 该目录在 `target/` 之下，本就被 `.gitignore` 忽略，且随 `cjpm clean` 一并清除；
 *   · `target/` 不随制品包分发，故消费者侧不会因此多出任何东西。
 */
package audio4cj.test

import std.fs.*

/// 测试临时产物目录（相对当前工作目录，即 cjpm 运行测试时的模块根）。
let TEST_TMP_DIR: String = "target/test-tmp"

/// 把用例给的临时文件名落到 [TEST_TMP_DIR] 下并返回完整路径；目录不存在时先创建。
func testTmpPath(name: String): String {
    let dir = Path(TEST_TMP_DIR)
    if (!exists(dir)) {
        Directory.create(dir, recursive: true)
    }
    dir.join(name).toString()
}
