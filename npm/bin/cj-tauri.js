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
