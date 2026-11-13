#!/usr/bin/env node
/**
 * cj-tauri npm 包启动器（跨平台：Windows / Linux，Git Bash 亦可）
 *
 * 职责：把「仓颉环境自检 + 平台差异 + CLI 本体的构建与缓存 + 退出码传递」收进一个入口，
 * 让 npm 安装后的用法与仓库内一致：
 *
 *     npx cj-tauri create myapp
 *     npx cj-tauri dev
 *
 * 与仓库内 cli/cj-tauri.sh、cli/cj-tauri.bat 的关系：那两个是**开发用**启动器（假定在仓库里跑），
 * 本文件是**发布用**入口（在任意目录跑）。PATH / LD_LIBRARY_PATH 的拼装规则与它们保持一致，
 * 改动其中一处请三处一起改。
 *
 * CLI 可执行文件的解析顺序（对应「优先预编译、缺失回落源码构建」的打包策略）：
 *   1. 包内预编译 <pkg>/prebuilt/<平台-架构>/cj-tauri[.exe] —— 打 tarball 时若本机有产物就带上
 *   2. 本机缓存   <缓存>/<版本>/<平台-架构>/cj-tauri[.exe] —— 首次构建后复用
 *   3. 源码构建   把 <pkg>/cli 拷到缓存目录再 `cjpm build`；不往安装目录写产物，
 *                 因为全局安装的包目录可能是只读的
 *
 * 仓颉 SDK（cjc + cjpm + stdx）是硬前置：应用的**后端**就是仓颉代码，没 SDK 连编译都做不了。
 * 缺 SDK 时这里给出可操作的提示，而不是让 cjpm 报 "command not found"。
 */
'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');

const PKG_ROOT = path.resolve(__dirname, '..');
const PKG = JSON.parse(fs.readFileSync(path.join(PKG_ROOT, 'package.json'), 'utf8'));
const VERSION = PKG.version;
const IS_WIN = process.platform === 'win32';
const PLATFORM_KEY = `${process.platform}-${process.arch}`;
const CLI_FILE = IS_WIN ? 'cj-tauri.exe' : 'cj-tauri';
/** 构建产物在 cjpm 的默认输出位置，包内 CLI 与本机构建时同名 */
const BUILT_CLI_FILE = IS_WIN ? 'main.exe' : 'main';

/** 诊断输出走 stderr：与仓库内启动器一致，不污染子命令的 stdout（stdout 要能被脚本消费） */
function note(msg) {
  process.stderr.write(`[cj-tauri] ${msg}\n`);
}

/** 只有带上 CJ_TAURI_VERBOSE=1 才打印「用了哪份 CLI」这类细节（默认安静，排障时可开） */
function verbose(msg) {
  if (process.env.CJ_TAURI_VERBOSE) note(msg);
}

/** 取第一个存在的路径 */
function firstExisting(candidates) {
  for (const p of candidates) {
    if (p && fs.existsSync(p)) {
      return p;
    }
  }
  return null;
}

/**
 * 解析仓颉 SDK 根目录：CANGJIE_HOME 优先，其次按平台探常见安装位置。
 * 与 cli/src/resolve.cj 的取向一致（那边还能从 PATH 里的 cjc 反推，这里只做静态探测）。
 */
function resolveCangjieHome() {
  const env = process.env.CANGJIE_HOME;
  if (env && !fs.existsSync(env)) {
    note(`告警: CANGJIE_HOME=${env} 目录不存在，继续按默认路径探测`);
  }
  const defaults = IS_WIN
    ? ['D:\\Program Files (x86)\\Cangjie', 'C:\\Cangjie']
    : ['/opt/cangjie/cangjie', path.join(os.homedir(), 'cangjie')];
  return firstExisting([env, ...defaults]);
}

/**
 * 本平台运行时库目录。
 * SDK 里可能同时装了多个平台的运行时（linux* 与 windows* 并存），必须按宿主平台挑，
 * 挑错会变成「找不到 libcangjie-runtime.so / 找不到 DLL」。
 * （macOS 与鸿蒙尚未实机验证，这里只做前缀匹配，不额外发明平台标识。）
 */
function resolveRuntimeDir(home) {
  const base = path.join(home, 'runtime', 'lib');
  if (!fs.existsSync(base)) {
    return null;
  }
  const prefix = IS_WIN ? 'windows' : (process.platform === 'darwin' ? 'darwin' : 'linux');
  const hit = fs.readdirSync(base).find((n) => n.toLowerCase().startsWith(prefix));
  return hit ? path.join(base, hit) : null;
}

/** 找 cjpm：SDK 的 tools/bin 优先，其次 PATH（与两个开发启动器的顺序一致） */
function resolveCjpm(home) {
  const exe = IS_WIN ? 'cjpm.exe' : 'cjpm';
  const inSdk = path.join(home, 'tools', 'bin', exe);
  if (fs.existsSync(inSdk)) {
    return inSdk;
  }
  for (const dir of (process.env.PATH || '').split(path.delimiter)) {
    if (!dir) {
      continue;
    }
    const p = path.join(dir, exe);
    if (fs.existsSync(p)) {
      return p;
    }
  }
  return null;
}

/**
 * 解析 stdx 动态库目录（${CANGJIE_STDX} 要的值）。
 * cli/cjpm.toml 的两个 target 段都写 `path-option = ["${CANGJIE_STDX}"]`，cjpm 按进程环境变量
 * 展开它——PowerShell / cmd 里没设这个变量时展开成空串，报的是
 * `root package 'cli' imports package 'stdx.encoding.json' ... not added as a dependency`
 * （看着像 toml 漏配，其实是变量没落地），首次构建当场就死。这里按顺序探测：
 *   1. 用户已设的 CANGJIE_STDX（存在才用，指错了会拿到假的「已配置」）；
 *   2. ~/.cangjie/stdx/<包>/dynamic/stdx（CI / 教程的落位）；
 *   3. SDK 根的兄弟目录 cangjie-stdx-<版本>/<三元组>/dynamic/stdx（解压在 SDK 旁边的习惯）。
 * 要求目录里有 stdx.* 的库文件，防止指到 stdx 包根（那是「create 成功、build 才炸」的另一种指错）；
 * 自动探测的候选还必须匹配**宿主平台**（包名含 windows/linux、不含 ohos）——
 * 机器上可能同时躺着给鸿蒙交叉编译用的 cangjie-stdx-ohos-aarch64 包，它里面没有
 * 宿主目标的库文件，链上去就是 `lld: error: unable to find library -lstdx.encoding.json`
 * （2026-11-12 Windows 实测）。用户显式设置的 CANGJIE_STDX 仍然优先（那是他自己的选择），
 * 但若路径里带 ohos 会打一行警告。 */
function resolveStdx(home) {
  const looksRight = (p) => {
    try {
      // 必须能找到实际要链的库（libstdx.encoding.json.*）：指到「包根」而不是
      // <三元组>/dynamic/stdx 时，变量展开成功但cjpm 找不到库，报的是和「变量为空」
      // 一模一样的 imports package ... not added as a dependency（2026-11-13 实测，
      // 用户把 CANGJIE_STDX 设成 D:\cangjie-stdx 包根就复现了）——所以按库文件判，
      // 不能按「有 stdx.* 开头的文件」判（真实库都是 libstdx.* 命名）。
      return fs.readdirSync(p).some((n) => n.startsWith('libstdx.encoding.json.'));
    } catch (e) {
      return false;
    }
  };
  // 宿主平台关键词：自动探测的包名必须含它且不含 ohos（交叉编译包不能当宿主 stdx 用）
  const platKey = IS_WIN ? 'windows' : (process.platform === 'darwin' ? 'darwin' : 'linux');
  const hostUsable = (pkgName) => pkgName.includes(platKey) && !pkgName.includes('ohos');
  // stdx 里实际被引用的那一层按平台分叉：Windows 上编本机可执行文件吃**静态库**
  // （cjpm 的 bin-dependencies 要 .a），实测要指 static\stdx（2026-11-13 用户实测，
  // 指 dynamic 报 imports package ... not added as a dependency）；Linux 指 dynamic/stdx。
  const stdxLayer = IS_WIN ? 'static' : 'dynamic';

  const candidates = [];
  if (process.env.CANGJIE_STDX && fs.existsSync(process.env.CANGJIE_STDX)) {
    if (process.env.CANGJIE_STDX.includes('ohos')) {
      note('告警: CANGJIE_STDX 指向 ohos 包（给鸿蒙交叉编译用），主机构建用不了，请改指宿主平台的 stdx');
    }
    candidates.push(process.env.CANGJIE_STDX);
  }
  const cjStdxBase = path.join(os.homedir(), '.cangjie', 'stdx');
  try {
    for (const pkg of fs.readdirSync(cjStdxBase)) {
      if (hostUsable(pkg)) {
        // 两种落位都收：CI / 教程把包直接解成 <包>/<层>/stdx，Windows 的 zip 则是
        // <包>/<三元组>/<层>/stdx（zip 无顶层目录）。looksRight 会把不存在的滤掉。
        const triple = IS_WIN ? 'windows_x86_64_cjnative' : (process.platform === 'darwin' ? 'darwin_x86_64_cjnative' : 'linux_x86_64_cjnative');
        candidates.push(path.join(cjStdxBase, pkg, stdxLayer, 'stdx'));
        candidates.push(path.join(cjStdxBase, pkg, triple, stdxLayer, 'stdx'));
      }
    }
  } catch (e) {
    // 目录不存在 = 没按这个布局装过，忽略
  }
  const sdkParent = path.dirname(home);
  try {
    for (const pkg of fs.readdirSync(sdkParent)) {
      if (!pkg.startsWith('cangjie-stdx-')) {
        continue;
      }
      const triple = IS_WIN ? 'windows_x86_64_cjnative' : (process.platform === 'darwin' ? 'darwin_x86_64_cjnative' : 'linux_x86_64_cjnative');
      if (hostUsable(pkg)) {
        candidates.push(path.join(sdkParent, pkg, triple, stdxLayer, 'stdx'));
      }
    }
  } catch (e) {
    // 同上
  }
  return candidates.find(looksRight) || null;
}

/** CANGJIE_STDX 解析不到时的提示：给下载入口与 setx 落法，别让 cjpm 的报错背锅 */
function printMissingStdxHint() {
  const lines = [
    '错误: 没找到 stdx 扩展标准库（CANGJIE_STDX 未设置，常见安装位置也没探测到）。',
    'CLI 与生成的工程都 import stdx.encoding.json，cjpm.toml 按 ${CANGJIE_STDX} 引用它，',
    '这个变量没进进程时 cjpm 报「imports package stdx... not added as a dependency」，极易误判成 toml 漏配。',
    '请下载 stdx（与 SDK 版本配套，1.2.0 ↔ 1.2.0.1，混配会「编译全过、真机启动即崩」）：',
    '  https://atomgit.com/Cangjie/cangjie_stdx/releases（匿名可下）',
    IS_WIN
      ? '解压后把 CANGJIE_STDX 指到 <解压目录>\\windows_x86_64_cjnative\\static\\stdx（静态库目录，'
      : '解压后把 CANGJIE_STDX 指到 <解压目录>/linux_x86_64_cjnative/dynamic/stdx（动态库目录，不是包根），',
    IS_WIN
      ? 'Windows 编本机可执行吃的是静态库，不是包根、也不是 dynamic\\stdx）；'
      : '解压后把 CANGJIE_STDX 指到 <解压目录>/linux_x86_64_cjnative/dynamic/stdx（动态库目录，不是包根），',
    IS_WIN
      ? '并 setx CANGJIE_STDX <路径> 持久化（重开终端生效）；然后重跑本命令。'
      : '并 export CANGJIE_STDX=<路径> 持久化（写进 ~/.bashrc / ~/.zshrc）；然后重跑本命令。',
    '详见: https://atomgit.com/qq8864/cj-tauri/blob/main/docs/使用文档.md',
  ];
  for (const line of lines) {
    note(line);
  }
}

/**
 * 拼装子进程环境。
 *   PATH           = 运行时库目录 + bin + tools/bin + tools/lib + ~/.cjpm/bin + 原 PATH
 *   LD_LIBRARY_PATH = 运行时库目录 + third_party/llvm/lib（仅非 Windows）
 * Linux 上动态库不走 PATH，少了 LD_LIBRARY_PATH，CLI 会直接因 libcangjie-runtime.so 起不来。
 * CJ_TAURI_ROOT 指向包根（包就是一棵「框架根」：含 cjpm.toml 与 cli/templates），
 * CLI 靠它定位模板与框架源码；用户已显式设置时不覆盖。
 */
function buildEnv(home, runtimeDir) {
  const env = Object.assign({}, process.env);
  const parts = [];
  if (runtimeDir) {
    parts.push(runtimeDir);
  }
  parts.push(path.join(home, 'bin'), path.join(home, 'tools', 'bin'), path.join(home, 'tools', 'lib'));
  parts.push(path.join(os.homedir(), '.cjpm', 'bin'));
  env.PATH = parts.join(path.delimiter) + path.delimiter + (env.PATH || '');

  if (!IS_WIN) {
    const ld = [];
    if (runtimeDir) {
      ld.push(runtimeDir);
    }
    ld.push(path.join(home, 'third_party', 'llvm', 'lib'));
    if (env.LD_LIBRARY_PATH) {
      ld.push(env.LD_LIBRARY_PATH);
    }
    env.LD_LIBRARY_PATH = ld.join(':');
  }

  if (!env.CJ_TAURI_ROOT) {
    env.CJ_TAURI_ROOT = PKG_ROOT;
  }

  // ${CANGJIE_STDX} 是 cjpm.toml 里的字面引用，cjpm 按进程环境变量展开：
  // 这里解析到了就补进 env（用户已设且有效时不覆盖），CLI 自己 spawn cjpm 时会继承下去，
  // 生成工程之后的 cj-tauri build / run 同样受益。
  const stdx = resolveStdx(home);
  if (stdx) {
    if (stdx !== process.env.CANGJIE_STDX) {
      verbose(`CANGJIE_STDX 未设置或无效，探测到: ${stdx}`);
    }
    env.CANGJIE_STDX = stdx;
  } else if (!process.env.CANGJIE_STDX) {
    verbose('CANGJIE_STDX 未设置且未探测到（首次构建 CLI 时会失败，含安装提示）');
  }
  return env;
}

/** 缓存根：Linux/macOS 走 XDG 惯例，Windows 走 LOCALAPPDATA */
function cacheRoot() {
  if (IS_WIN) {
    const base = process.env.LOCALAPPDATA || path.join(os.homedir(), 'AppData', 'Local');
    return path.join(base, 'cj-tauri');
  }
  const base = process.env.XDG_CACHE_HOME || path.join(os.homedir(), '.cache');
  return path.join(base, 'cj-tauri');
}

/** 缺 SDK 时的提示：给可操作的下一步，而不是把 cjpm 的 not found 甩给用户 */
function printMissingSdkHint(reason) {
  const lines = [
    `错误: 找不到仓颉 SDK（cjc / cjpm）${reason}`,
    'cj-tauri 要把应用后端编译成仓颉可执行文件，所以必须先装仓颉 SDK（含 stdx）。',
    '请安装 SDK 1.2.0 以上版本，然后把 CANGJIE_HOME 指向 SDK 根目录：',
    IS_WIN
      ? '  Windows: set CANGJIE_HOME=D:\\Program Files (x86)\\Cangjie'
      : '  Linux  : export CANGJIE_HOME=/opt/cangjie/cangjie',
    '安装说明: https://atomgit.com/qq8864/cj-tauri/blob/main/docs/使用文档.md',
    '设好后自检: cj-tauri info',
    'Cangjie SDK not found (cjc/cjpm). Set CANGJIE_HOME to your SDK root, then run: cj-tauri info',
  ];
  for (const line of lines) {
    note(line);
  }
}

/** 包内预编译二进制（打包机有 CLI 产物时才会存在） */
function prebuiltCliPath() {
  return path.join(PKG_ROOT, 'prebuilt', PLATFORM_KEY, CLI_FILE);
}

/** 本机缓存里的 CLI（源码构建后的产物落在这里，供后续复用） */
function cachedCliPath() {
  return path.join(cacheRoot(), VERSION, PLATFORM_KEY, CLI_FILE);
}

/** 递归拷贝，跳过产物目录（target 里有几 MB 编译中间物，且不该带进缓存） */
function copyDir(from, to, skipNames) {
  fs.mkdirSync(to, { recursive: true });
  for (const entry of fs.readdirSync(from, { withFileTypes: true })) {
    if (skipNames.includes(entry.name)) {
      continue;
    }
    const src = path.join(from, entry.name);
    const dst = path.join(to, entry.name);
    if (entry.isDirectory()) {
      copyDir(src, dst, skipNames);
    } else {
      fs.copyFileSync(src, dst);
    }
  }
}

/**
 * 用本机 cjpm 构建 CLI 本体，产物落缓存。
 * 刻意把源码拷到缓存目录再构建：`cjpm build` 会写 target/，
 * 而全局安装的包目录可能是只读的（系统 node_modules 尤其如此）。
 */
function buildCli(env, cjpm) {
  // 硬前置：cli/cjpm.toml 的 path-option 是 ${CANGJIE_STDX}，变量为空时 cjpm 把它读成
  // 「stdx 没声明成依赖」。提前拦下并给安装提示，比甩一段 cjpm 报错给人强。
  if (!env.CANGJIE_STDX) {
    note('错误: 构建需要 stdx 扩展标准库，但没有找到可用的 CANGJIE_STDX。');
    printMissingStdxHint();
    return null;
  }
  const buildDir = path.join(cacheRoot(), VERSION, 'build', 'cli');
  note(`首次运行：正在构建 CLI 本体（${cjpm} build）...`);
  fs.rmSync(buildDir, { recursive: true, force: true });
  copyDir(path.join(PKG_ROOT, 'cli'), buildDir, ['target']);

  const r = spawnSync(cjpm, ['build'], { cwd: buildDir, env, stdio: 'inherit' });
  const produced = path.join(buildDir, 'target', 'release', 'bin', BUILT_CLI_FILE);
  if (r.status !== 0 || !fs.existsSync(produced)) {
    note(`错误: CLI 本体构建失败（cjpm 退出码 ${r.status === null ? 'null' : r.status}）`);
    note(`      可手动重试: cd "${buildDir}" && cjpm build`);
    return null;
  }

  const dst = cachedCliPath();
  fs.mkdirSync(path.dirname(dst), { recursive: true });
  fs.copyFileSync(produced, dst);
  if (!IS_WIN) {
    fs.chmodSync(dst, 0o755);
  }
  note(`CLI 本体已缓存: ${dst}`);
  return dst;
}

/** 解析要执行的 CLI：预编译 → 缓存 → 现场构建 */
function resolveCli(env, cjpm) {
  const prebuilt = prebuiltCliPath();
  if (fs.existsSync(prebuilt)) {
    verbose(`使用包内预编译 CLI: ${prebuilt}`);
    return prebuilt;
  }
  const cached = cachedCliPath();
  if (fs.existsSync(cached)) {
    verbose(`使用缓存 CLI: ${cached}`);
    return cached;
  }
  return buildCli(env, cjpm);
}

function main() {
  const argv = process.argv.slice(2);
  const home = resolveCangjieHome();
  const cjpm = home ? resolveCjpm(home) : null;

  if (!home || !cjpm) {
    // --version 不需要 SDK：版本直接读 package.json（与 CLI 的 cliVersion() 同源，
    // scripts/check-version.sh 会校验两者一致），让没装 SDK 的人也能查版本号。
    if (['--version', '-V', '-v'].includes(argv[0])) {
      process.stdout.write(`cj-tauri ${VERSION}\n`);
      return 0;
    }
    printMissingSdkHint(home ? '（SDK 里没有 tools/bin/cjpm）' : '（CANGJIE_HOME 未设置或指向的目录不存在）');
    return 1;
  }

  const runtimeDir = resolveRuntimeDir(home);
  if (!runtimeDir) {
    note(`告警: 在 ${path.join(home, 'runtime', 'lib')} 下没找到本平台运行时库目录`);
  }
  const env = buildEnv(home, runtimeDir);
  const cli = resolveCli(env, cjpm);
  if (!cli) {
    return 1;
  }

  // stdio 全继承：CLI 的进度（含 dev 的桥/构建日志）与窗口输出直达终端。
  // 不 detach，Ctrl-C 时终端把 SIGINT 发给**整个前台进程组**，本进程与 CLI 同时收到：
  // CLI 自己会收掉 dev server 与子进程，这里只需如实回传状态码。
  const r = spawnSync(cli, argv, { stdio: 'inherit', env });
  if (r.error) {
    note(`错误: 启动 CLI 失败: ${r.error.message}`);
    return 1;
  }
  if (r.signal) {
    // 按 shell 惯例回 128+n，让脚本能区分「被打断」与「正常失败」
    return 128 + (os.constants.signals[r.signal] || 0);
  }
  return r.status === null ? 1 : r.status;
}

// 用 exitCode 而不是 process.exit()：后者可能截断还没 flush 的 stdout 缓冲
process.exitCode = main();
