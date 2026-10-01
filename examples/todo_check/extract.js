// 从《前端入门教程》里抽出 cangjie 代码块，重新生成 examples/todo_check 的源码。
// 用途：用真实 SDK 编译教程里的示例代码，确保读者照抄能过；教程改动后重跑本脚本即可刷新。
// 生成物（src/main.cj、src/extra_checks.cj、ui/index.html、capabilities/default.json）已随仓提交，
// 好让这个示例可以直接 cjpm build；它们不是手写文件——改教程后请重跑本脚本，而不是手改生成物。
// 用法：在仓库根目录执行 node examples/todo_check/extract.js docs/前端入门教程.md

const fs = require('fs');

const docPath = process.argv[2] || 'docs/前端入门教程.md';
const lines = fs.readFileSync(docPath, 'utf8').split(/\r?\n/);

const blocks = [];
let cur = null;
for (const line of lines) {
  if (line.startsWith('```')) {
    if (cur === null) {
      cur = { lang: line.slice(3).trim(), body: [] };
    } else {
      blocks.push(cur);
      cur = null;
    }
    continue;
  }
  if (cur !== null) {
    cur.body.push(line);
  }
}
if (cur !== null) {
  throw new Error('文档里有未闭合的代码围栏');
}

function pick(lang, marker) {
  const hit = blocks.find(function (b) {
    return b.lang === lang && b.body.join('\n').includes(marker);
  });
  if (!hit) {
    throw new Error('找不到代码块: ' + lang + ' / ' + marker);
  }
  return hit.body.join('\n');
}

// §9 的完整后端：整块就是一份 main.cj，只改包名
const mainCj = pick('cangjie', 'package myapp').replace('package myapp', 'package todo_check');
fs.writeFileSync('examples/todo_check/src/main.cj', mainCj + '\n');

// §4 / §5 / §7 的片段（类名与 §9 不冲突，同包编译即可校验）
const header = [
  'package todo_check',
  '',
  'import cjTauri.*',
  '',
  'import stdx.encoding.json.*',
  ''
];
const parts = [header.join('\n')];
for (const marker of ['class AddCommand', 'class TimerCommand', 'class ReportCommand']) {
  parts.push(pick('cangjie', marker));
}
fs.writeFileSync('examples/todo_check/src/extra_checks.cj', parts.join('\n\n') + '\n');

// §9.3 的前端页面（文档里唯一的 html 块）与 §9.2 的能力清单（含 todo:changed 的 json 块）
fs.mkdirSync('examples/todo_check/ui', { recursive: true });
fs.mkdirSync('examples/todo_check/capabilities', { recursive: true });
fs.writeFileSync('examples/todo_check/ui/index.html', pick('html', '<!DOCTYPE html>') + '\n');
fs.writeFileSync('examples/todo_check/capabilities/default.json', pick('json', 'todo:changed') + '\n');

console.log('blocks=' + blocks.length + ' -> src/main.cj + src/extra_checks.cj 已生成');
