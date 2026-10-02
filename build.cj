/* ============================================================================
 * build.cj —— cjpm 构建脚本（pre-build / pre-test 钩子）
 *
 * 【要解决的问题】
 *   `[ffi.c]` 的路径在 cjpm.toml 里是**静态配置**，无法按目标平台切换。
 *   而本项目在每个平台需要的 C 库产物并不相同：
 *       Windows : drlibs.dll + libdrlibs.dll（双副本）+ libdrlibs.lib（导入库）
 *       Linux   : libdrlibs.so
 *       macOS   : libdrlibs.dylib
 *   于是这里采取「**固定目录 + 构建期装配**」方案：
 *       `[ffi.c]` 永远指向 `libs/current/`，由本脚本在构建前把该平台需要的
 *       产物放进去 —— 要么复用仓库里预置的产物，要么现场编译。
 *
 * 【平台判定用 @When 而不是运行期探测】
 *   `os` / `arch` 是编译期条件，因此编译产物里**只存在当前平台那一份逻辑**，
 *   不存在"探测错了平台"这种运行期故障。代价是新增平台时必须在下面补齐
 *   各分支 —— 而漏补会在编译期直接报未定义标识符，不会静默走错命令。
 *
 * 【为什么用 File.readFrom / File.writeTo 而不是 fs.copy】
 *   std.fs 的 `copy` 参数风格（哪些是命名参数）未核实，而 `File.readFrom` /
 *   `File.writeTo` 是明确的静态方法。产物只有几百 KB，整读整写没有压力 ——
 *   用最确定的 API 换"不会因参数风格写错而编译不过"。
 *
 * 【为什么直接编译到最终文件名，而不先写临时名】
 *   临时名方案的失败残留更让人困惑（装配目录里会留下 `_tmp_*`，还得再引入
 *   删除 API 去清理，而删除 API 的参数风格同样未核实）。
 *   直接写最终名的风险评估：编译中断可能留下半截文件，但 `allPresent` 要求
 *   **全部**产物齐备才会跳过编译，所以多产物平台（Windows）天然免疫；
 *   单产物平台若真被中断留下半截 `.so`，删掉 `libs/current/` 重建即可 ——
 *   该目录本就不进版本控制，是纯粹的构建产物。
 *
 * 【一个已知的顺序约束（CI 上实测踩到）】
 *   `cjpm check` 在**配置解析阶段**就校验 `[ffi.c]` 里的库是否存在，
 *   而它**不会触发构建脚本**。因此全新克隆后必须
 *
 *       cjpm build     # pre-build 钩子装配 libs/current/
 *       cjpm check     # 此时才能通过
 *
 *   反过来会报：can not find the library 'drlibs' which is listed in 'ffi.c'
 *   （`cjpm build` 与 `cjpm test` 不受影响 —— 它们都会先跑各自的钩子。）
 *
 *   这是"构建期装配"这一选型的代价，换来的是：
 *   **仓库不必提交任何平台二进制，永远从源码编译**。
 *   对比方案：把各平台产物直接入库可回避该约束，但会引入另一个风险 ——
 *   wrapper 改了而入库的库没重编，链接到的是一份陈旧实现（且很难察觉）。
 *   本项目 C 侧只有一个不依赖外部库的源文件、编译约一秒，故选择后者。
 * ========================================================================== */

import std.fs.*
import std.process.*
import std.env.*

// ---------------------------------------------------------------------------
// 平台相关
// ---------------------------------------------------------------------------

/// 该平台在 `libs/` 下的预置产物目录名（与仓库既有命名一致）。
@When[os == "Windows"]
let PLATFORM_DIR = "windows_x86_64"

@When[os == "Linux"]
let PLATFORM_DIR = "linux_x86_64"

@When[os == "macOS" && arch == "aarch64"]
let PLATFORM_DIR = "macos_aarch64"

@When[os == "macOS" && arch == "x86_64"]
let PLATFORM_DIR = "macos_x86_64"

/// `[ffi.c]` 指向的固定装配目录（须与 cjpm.toml 保持一致）。
let CURRENT_DIR = "libs/current"

/// dr_libs 薄封装的源码与头文件位置。
let WRAPPER_SRC = "third-party/drlibs_wrapper.c"
let DR_LIBS_INC = "third-party/dr_libs"

/// 置为 `1` 时强制重新编译，忽略已有产物（排查构建问题时用）。
let FORCE_ENV = "AUDIO4CJ_FORCE_C_BUILD"

/// 该平台需要的全部产物文件名。
@When[os == "Windows"]
func requiredArtifacts(): Array<String> {
    // 双副本是 Windows 的已知规格问题：编译期 cjpm 找带 lib 前缀的
    // libdrlibs.dll，运行期加载的是无前缀的 drlibs.dll。
    // `libdrlibs.lib` 是链接用的导入库。
    ["drlibs.dll", "libdrlibs.dll", "libdrlibs.lib"]
}

@When[os == "Linux"]
func requiredArtifacts(): Array<String> {
    ["libdrlibs.so"]
}

@When[os == "macOS"]
func requiredArtifacts(): Array<String> {
    ["libdrlibs.dylib"]
}

// ---------------------------------------------------------------------------
// 入口
// ---------------------------------------------------------------------------

main() {
    // 钩子名由 cjpm 作为首个参数传入；返回 0 表示成功，非 0 会中止构建。
    match (Process.current.arguments[0]) {
        case "pre-build" => prepareCLibrary()
        // `cjpm test` 同样要链接本模块，因此测试前也要准备产物
        case "pre-test" => prepareCLibrary()
        case _ => 0
    }
}

/// 确保 `libs/current/` 里有当前平台需要的 C 库产物。
func prepareCLibrary(): Int64 {
    let current = Path(CURRENT_DIR)

    // 固定目录随仓库交付（含 .gitkeep）；这里兜底创建，防止被误删
    if (!exists(current)) {
        Directory.create(current, recursive: true)
    }

    let need = requiredArtifacts()
    let forced = (getVariable(FORCE_ENV) ?? "") == "1"

    // 1) 装配目录里已齐备 —— 最常见路径（上次构建留下的）
    if (!forced && allPresent(current, need)) {
        return 0
    }

    // 2) 仓库预置了该平台的产物（当前只有 Windows）—— 复用，免装 C 编译器
    let prebuilt = Path("libs").join(PLATFORM_DIR)
    if (!forced && allPresent(prebuilt, need)) {
        for (name in need) {
            copyByIo(prebuilt.join(name), current.join(name))
        }
        println("[build.cj] 已复用 libs/${PLATFORM_DIR}/ 的预置 C 库产物 -> ${CURRENT_DIR}/")
        return 0
    }

    // 3) 现场编译
    return compileCLibrary()
}

/// 用当前平台的工具链编译 dr_libs 薄封装，产物直接落在装配目录。
func compileCLibrary(): Int64 {
    let argv = match (compileArgv()) {
        case Some(v) => v
        case None =>
            println("[build.cj] 错误: 未找到可用的 C 编译器。")
            println("  Linux / macOS : 需要 clang（或将其加入 PATH）")
            println("  Windows       : 需要 clang 或 clang-cl，"
                + "且需在 MSVC 开发者命令提示符中运行（否则找不到 CRT 头文件）")
            println("  另一条路：把该平台的产物放入 libs/${PLATFORM_DIR}/ 后重新构建")
            return 1
    }

    let code = execute(argv[0], argv[1..])
    if (code != 0) {
        println("[build.cj] 错误: 编译 C 库失败（退出码 ${code}）。")
        println("  提示：可设 AUDIO4CJ_FORCE_C_BUILD=1 强制重编译；")
        println("       或把该平台的产物放入 libs/${PLATFORM_DIR}/ 后重新构建；")
        println("       若怀疑留下了半截产物，删除 ${CURRENT_DIR}/ 后重试。")
        return code
    }

    return finalizeArtifacts()
}

// ---------------------------------------------------------------------------
// 各平台的编译命令与收尾
// ---------------------------------------------------------------------------

@When[os == "Windows"]
func compileArgv(): ?Array<String> {
    // Windows 上 clang 默认目标是 x86_64-pc-windows-msvc，走 lld-link，
    // 因此导入库要用 lld-link 的 `/implib:`，而非 GNU ld 的 `--out-implib`。
    Some([
        "clang",
        "-shared",
        "-O2",
        "-I", DR_LIBS_INC,
        WRAPPER_SRC,
        "-o", "${CURRENT_DIR}/drlibs.dll",
        "-Wl,/implib:${CURRENT_DIR}/libdrlibs.lib",
    ])
}

/// Windows 收尾：补一份**带 lib 前缀**的 DLL 副本（编译期查找规则）。
@When[os == "Windows"]
func finalizeArtifacts(): Int64 {
    copyByIo(Path("${CURRENT_DIR}/drlibs.dll"), Path("${CURRENT_DIR}/libdrlibs.dll"))
    println("[build.cj] 已编译 C 库到 ${CURRENT_DIR}/（Windows，含 lib 前缀双副本）")
    0
}

@When[os == "Linux"]
func compileArgv(): ?Array<String> {
    // -fPIC 是共享库必需；-fstack-protector-all 为安全加固（开发文档 §6.2）
    Some([
        "clang",
        "-shared",
        "-fPIC",
        "-fstack-protector-all",
        "-O2",
        "-I", DR_LIBS_INC,
        WRAPPER_SRC,
        "-o", "${CURRENT_DIR}/libdrlibs.so",
    ])
}

@When[os == "Linux"]
func finalizeArtifacts(): Int64 {
    println("[build.cj] 已编译 C 库到 ${CURRENT_DIR}/libdrlibs.so")
    0
}

@When[os == "macOS"]
func compileArgv(): ?Array<String> {
    Some([
        "clang",
        "-shared",
        "-fPIC",
        "-fstack-protector-all",
        "-O2",
        "-I", DR_LIBS_INC,
        WRAPPER_SRC,
        "-o", "${CURRENT_DIR}/libdrlibs.dylib",
    ])
}

@When[os == "macOS"]
func finalizeArtifacts(): Int64 {
    println("[build.cj] 已编译 C 库到 ${CURRENT_DIR}/libdrlibs.dylib")
    0
}

// ---------------------------------------------------------------------------
// 工具
// ---------------------------------------------------------------------------

/// `dir` 下是否齐备 `names` 里的全部文件。
func allPresent(dir: Path, names: Array<String>): Bool {
    for (name in names) {
        if (!exists(dir.join(name))) {
            return false
        }
    }
    true
}

/// 用「整读整写」复制文件（理由见文件头）。
func copyByIo(src: Path, dst: Path): Unit {
    File.writeTo(dst, File.readFrom(src))
}
