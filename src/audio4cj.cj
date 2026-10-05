package audio4cj

/* ============================================================================
 * 根包
 *
 * 【为什么必须存在这个文件（实测发现）】
 * cjpm 的源包扫描规则要求"所有父包（直到根包）也须为有效源包"，
 * 即每个上级目录都必须直接包含至少一个 .cj 文件。
 * 若 src/ 目录下没有 .cj 文件，cjpm 会输出：
 *
 *     Warning: there is no '.cj' file in directory '...\src',
 *              and its subdirectories will not be scanned as source code
 *
 * 此时 src/core/、src/pcm/ 等**全部子包都会被忽略**，构建产物为空。
 * 因此 src/ 根必须保留本文件。
 *
 * 【关于聚合导出（实测未通过）】
 * 曾尝试在此处用 `public import audio4cj.core.*` 做聚合导出，
 * 使调用方可以只写 `import audio4cj.*`。但当前编译器不接受该写法：
 *
 *     error: expected declaration, found keyword 'import'
 *
 * 故 M1 暂不做聚合导出，使用方需显式导入各包，例如：
 *
 *     import audio4cj.facade.AudioFile
 *     import audio4cj.meta.Tag
 *     import audio4cj.pcm.AudioBuffer
 *     import audio4cj.core.Audio4CjException
 *
 * （另注：技能文档 cangjie-package 描述 public import 可"重新导出"，
 *   但本次实测未通过，已记入开发文档 §12.4，后续版本可再验证。）
 * ========================================================================== */

/// 库版本号。**必须与 cjpm.toml 的 version 一致** —— 两者不等会让使用者困惑
/// （中心仓按 cjpm.toml 入库，而 API 另报一个号）。
///
/// 显式标注类型：cjlint 的 G.DCL.02 要求公开变量声明类型，而非依赖类型推断
/// ——公开 API 的类型应当写在签名里，让使用者不必回看初始化表达式。
public let AUDIO4CJ_VERSION: String = "0.1.1"
