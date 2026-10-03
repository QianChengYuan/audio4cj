/* ============================================================================
 * build.cj —— cjpm 构建脚本（pre-build / pre-test 钩子）
 *
 * 【它现在做什么】
 *   确保 `libs/<平台>/libdrlibs.a` 存在：
 *       ① 已在 → 直接返回（仓库预置的产物，或上次构建留下的）
 *       ② 不在 → 用该平台的工具链现场编译
 *
 * 【为什么不再有 libs/current/ 中间层】
 *   早期版本把所有平台的 `[ffi.c]` 固定指向 `libs/current/`，再由本脚本
 *   "按平台把产物拷进去"。那个设计的前提是「`[ffi.c]` 无法按目标平台切换」
 *   —— **前提是错的**：cjpm 支持 `[target.<三元组>.ffi.c]`（2026-10-03 实测）。
 *   现在 cjpm.toml 直接写：
 *
 *       [target.x86_64-w64-mingw32.ffi.c]
 *         drlibs = { path = "./libs/windows_x86_64/" }
 *
 *   于是中间层、以及"拷贝产物"这一步都不再需要。
 *
 * 【为什么产物是静态库，而不是动态库】
 *   动态库要求**消费者运行期**也能加载到它（Windows 上还要操心 lib 前缀
 *   双副本这类规格问题）。改静态后 C 库直接进可执行文件，运行期不再有
 *   任何额外要求。代价可忽略：整个 dr_libs 封装静态进来约 225 KB（实测）。
 *
 * 【Windows 必须用 MinGW 口径的编译器（实测踩到）】
 *   cjc 在 Windows 上的链接器是 **MinGW 口径**（ld.lld -m i386pep + crt2.o +
 *   -lmingw32）。若用 clang 默认的 MSVC 目标编出的目标文件去静态链接，会报：
 *
 *       ld.lld: error: undefined symbol: __chkstk
 *       ld.lld: error: undefined symbol: _fltused
 *
 *   这两个都是 MSVC CRT 的符号，MinGW CRT 不提供。因此 Windows 走 **MinGW
 *   的 gcc + ar**。注意：编**动态库**时不存在这个问题（DLL 自带完整的 CRT
 *   依赖），所以这条约束是改成静态链接之后才暴露出来的。
 *
 * 【平台判定用 @When 而不是运行期探测】
 *   `os` / `arch` 是编译期条件，因此产物里**只存在当前平台那一份逻辑**，
 *   不存在"探测错了平台"这种运行期故障。代价是新增平台必须补齐分支 ——
 *   而漏补会在编译期直接报未定义标识符，不会静默走错命令。
 *
 * 【一个仍然存在的顺序约束（所有平台的**消费者侧**）】
 *   `cjpm check` 在配置解析阶段就校验 `[ffi.c]` 指向的库是否存在，而它
 *   **不触发构建脚本**，因此：
 *
 *       cjpm build     # 先由本脚本编出 libs/<平台>/libdrlibs.a
 *       cjpm check     # 此时才能通过
 *
 *   反过来会报：can not find the library 'drlibs' which is listed in
 *   'target.<三元组>.ffi.c' field
 *   （`cjpm build` 与 `cjpm test` 不受影响 —— 它们都会先跑各自的钩子。）
 *
 *   【为什么本仓库曾经"免疫"，而这个免疫在制品包里失效】
 *   本仓库的 libs/windows_x86_64/ 里**预置**了产物（二进制入库），所以在
 *   仓库内直接跑 check 是通的；但 cjpm **从不把二进制打进制品包**，
 *   于是消费者拿到的包里没有任何 libs/ —— 该平台豁免随之失效。
 *   结论：仓库内 check 通过 ≠ 包内 check 通过。
 *
 *   【为什么不能用"把产物也入库"这条捷径消除它】
 *   实测两条路都不通，故此处只如实记录：
 *     - 往包里放二进制 —— cjpm 一律跳过二进制，机制上不可能；
 *     - 改用 link-option 承担库引用 —— 实测它**不会传递到消费者的最终
 *       链接**（消费者链接报 undefined symbol），而 [ffi.c] 恰恰是唯一
 *       能把 C 库依赖传递给消费者的机制。
 *   因此消费者侧的正确用法是：先 `cjpm build`，再 `cjpm check`。
 * ========================================================================== */

import std.fs.*
import std.process.*
import std.env.*

// ---------------------------------------------------------------------------
// 平台相关
// ---------------------------------------------------------------------------

/// 该平台在 `libs/` 下的产物目录名（与 cjpm.toml 的 target 级 [ffi.c] 一致）。
@When[os == "Windows"]
let PLATFORM_DIR = "windows_x86_64"

@When[os == "Linux"]
let PLATFORM_DIR = "linux_x86_64"

@When[os == "macOS" && arch == "aarch64"]
let PLATFORM_DIR = "macos_aarch64"

@When[os == "macOS" && arch == "x86_64"]
let PLATFORM_DIR = "macos_x86_64"

/// dr_libs 薄封装的源码与头文件位置。
let WRAPPER_SRC = "third-party/drlibs_wrapper.c"
let DR_LIBS_INC = "third-party/dr_libs"

/// 静态库文件名。三平台统一用 `libdrlibs.a` —— 它是 MinGW/GNU 口径下
/// `-ldrlibs` 的默认查找名，实测在 Windows 上也能被 cjc 的 ld.lld 正确解析
/// （`.lib` 是 MSVC 口径的命名，对本项目没有必要）。
let LIB_NAME = "libdrlibs.a"

/// 编译中间产物（目标文件）的名字；保留在产物目录里，不额外删除 ——
/// 删除 API 的参数风格未核实，为一个中间文件去冒险不值得。
let OBJ_NAME = "drlibs.o"

/// 置为 `1` 时强制重新编译，忽略已有产物（排查构建问题时用）。
let FORCE_ENV = "AUDIO4CJ_FORCE_C_BUILD"

// ---------------------------------------------------------------------------
// 入口
// ---------------------------------------------------------------------------

main() {
    // 钩子名由 cjpm 作为首个参数传入；返回 0 表示成功，非 0 会中止构建。
    match (Process.current.arguments[0]) {
        case "pre-build" => ensureStaticLibrary()
        // `cjpm test` 同样要链接本模块，因此测试前也要准备产物
        case "pre-test" => ensureStaticLibrary()
        case _ => 0
    }
}

/// 确保 `libs/<平台>/libdrlibs.a` 就位。
func ensureStaticLibrary(): Int64 {
    let dir = Path("libs").join(PLATFORM_DIR)
    if (!exists(dir)) {
        Directory.create(dir, recursive: true)
    }

    let lib = dir.join(LIB_NAME)
    let forced = (getVariable(FORCE_ENV) ?? "") == "1"

    if (!forced && exists(lib)) {
        return 0
    }
    return compileStaticLibrary(dir)
}

/// 依次执行该平台的「编译 → 归档」命令，并确认静态库确实产出。
///
/// 分两步而不是一步：静态库必须由归档器生成，编译器本身没有"直接产出
/// 静态库"的选项。
func compileStaticLibrary(dir: Path): Int64 {
    for (argv in buildCommands(dir)) {
        let code = execute(argv[0], argv[1..])
        if (code != 0) {
            println("[build.cj] 错误: 命令失败（退出码 ${code}）")
            println("         ${joinArgv(argv)}")
            println(compilerAdvice())
            return code
        }
    }

    let lib = dir.join(LIB_NAME)
    if (!exists(lib)) {
        println("[build.cj] 错误: 命令均成功，但未产出 ${lib}")
        println(compilerAdvice())
        return 1
    }

    println("[build.cj] 已编译静态 C 库 -> ${lib}")
    0
}

/// 缺编译器 / 编译失败时给出的提示。
func compilerAdvice(): String {
    "  提示：\n"
    + "    Windows      需要 MinGW 的 gcc 与 ar（clang 默认的 MSVC 目标所编出的\n"
    + "                 目标文件无法被 cjc 的 MinGW 链接器静态链接，见本文件头）\n"
    + "    Linux / macOS 需要 clang 与 ar\n"
    + "    另一条路：把该平台的 ${LIB_NAME} 放入 libs/${PLATFORM_DIR}/ 后重新构建\n"
    + "    强制重编译：设 ${FORCE_ENV}=1"
}

// ---------------------------------------------------------------------------
// 各平台的命令序列
// ---------------------------------------------------------------------------

@When[os == "Windows"]
func buildCommands(dir: Path): Array<Array<String>> {
    let obj = "${dir}/${OBJ_NAME}"
    let lib = "${dir}/${LIB_NAME}"
    // 必须 MinGW 口径（见文件头）；-O2 与 -fstack-protector-all 为优化与安全加固
    [
        ["gcc", "-c", "-O2", "-fstack-protector-all",
         "-I", DR_LIBS_INC, WRAPPER_SRC, "-o", obj],
        ["ar", "rcs", lib, obj],
    ]
}

@When[os == "Linux"]
func buildCommands(dir: Path): Array<Array<String>> {
    let obj = "${dir}/${OBJ_NAME}"
    let lib = "${dir}/${LIB_NAME}"
    [
        ["clang", "-c", "-fPIC", "-O2", "-fstack-protector-all",
         "-I", DR_LIBS_INC, WRAPPER_SRC, "-o", obj],
        ["ar", "rcs", lib, obj],
    ]
}

@When[os == "macOS"]
func buildCommands(dir: Path): Array<Array<String>> {
    let obj = "${dir}/${OBJ_NAME}"
    let lib = "${dir}/${LIB_NAME}"
    // -mmacosx-version-min 必须给出，且与 cjc 的目标下限对齐：
    // CI 实测（2026-10-03）不加该选项时，链接器会警告目标文件的最低系统版本
    // 高于 cjc 的目标下限 ——
    //   ld64.lld: warning: libs/macos_aarch64/libdrlibs.a(drlibs.o) has version
    //              14.0.0, which is newer than target minimum of 12.0.0
    // 那意味着在 macOS 12/13 上可能无法运行，故显式对齐到 12.0。
    [
        ["clang", "-c", "-fPIC", "-O2", "-fstack-protector-all",
         "-mmacosx-version-min=12.0",
         "-I", DR_LIBS_INC, WRAPPER_SRC, "-o", obj],
        ["ar", "rcs", lib, obj],
    ]
}

// ---------------------------------------------------------------------------
// 工具
// ---------------------------------------------------------------------------

/// 把命令数组拼成一行便于阅读的错误信息。
func joinArgv(argv: Array<String>): String {
    var out = ""
    for (i in 0..argv.size) {
        if (i > 0) {
            out += " "
        }
        out += argv[i]
    }
    out
}
