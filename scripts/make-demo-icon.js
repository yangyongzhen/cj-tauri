#!/usr/bin/env node
/*
 * make-demo-icon.js — 生成示例工程用的 .ico（32x32，32 位 BGRA + AND 掩码）
 *
 * 为什么不用现成的图片：仓库里不放设计资源，图标又必须是真 .ico 才能被
 * Win32 的 LoadImageW(LR_LOADFROMFILE) 认出来。与其提交一张来历不明的二进制，
 * 不如把生成过程一起提交 —— 想换图标改这里的颜色/形状再跑一次即可。
 *
 * 用法：
 *   node scripts/make-demo-icon.js examples/hello/icon.ico
 */
'use strict';
const fs = require('fs');
const path = require('path');

const SIZE = 32;
const out = process.argv[2] || 'examples/hello/icon.ico';

// 画一个圆环：外圈品牌蓝，内圈近黑，背景透明
function pixel(x, y) {
    const cx = (SIZE - 1) / 2;
    const cy = (SIZE - 1) / 2;
    const d = Math.sqrt((x - cx) ** 2 + (y - cy) ** 2);
    if (d > 15.5) {
        return [0, 0, 0, 0]; // 圆外：透明
    }
    if (d > 10.5) {
        return [0xC6, 0x78, 0x31, 0xFF]; // B G R A —— 品牌蓝 #3178C6
    }
    return [0x14, 0x0E, 0x0A, 0xFF]; // 深色内芯
}

function buildPixels() {
    // BMP 的像素是自下而上存的
    const px = Buffer.alloc(SIZE * SIZE * 4);
    let o = 0;
    for (let y = SIZE - 1; y >= 0; y--) {
        for (let x = 0; x < SIZE; x++) {
            const [b, g, r, a] = pixel(x, y);
            px[o++] = b;
            px[o++] = g;
            px[o++] = r;
            px[o++] = a;
        }
    }
    return px;
}

function buildAndMask() {
    // AND 掩码：1 = 透明。32 位图标会用 alpha，这一块全 0 也安全（不透明），
    // 但必须存在且按 4 字节对齐，否则 LoadImageW 会拒绝整个文件。
    const stride = SIZE / 8; // 32 位 → 每行 4 字节
    return Buffer.alloc(stride * SIZE, 0);
}

function build() {
    const pixels = buildPixels();
    const andMask = buildAndMask();

    const header = Buffer.alloc(40);
    header.writeUInt32LE(40, 0); // biSize
    header.writeInt32LE(SIZE, 4); // biWidth
    header.writeInt32LE(SIZE * 2, 8); // biHeight：ICO 里是「高度 x2」（含掩码）
    header.writeUInt16LE(1, 12); // biPlanes
    header.writeUInt16LE(32, 14); // biBitCount
    header.writeUInt32LE(0, 16); // biCompression = BI_RGB
    header.writeUInt32LE(pixels.length + andMask.length, 20); // biSizeImage

    const image = Buffer.concat([header, pixels, andMask]);

    const dir = Buffer.alloc(6);
    dir.writeUInt16LE(0, 0); // reserved
    dir.writeUInt16LE(1, 2); // type = icon
    dir.writeUInt16LE(1, 4); // count

    const entry = Buffer.alloc(16);
    entry.writeUInt8(SIZE, 0); // width
    entry.writeUInt8(SIZE, 1); // height
    entry.writeUInt8(0, 2); // palette
    entry.writeUInt8(0, 3); // reserved
    entry.writeUInt16LE(1, 4); // planes
    entry.writeUInt16LE(32, 6); // bit count
    entry.writeUInt32LE(image.length, 8); // bytes in resource
    entry.writeUInt32LE(6 + 16, 12); // offset

    return Buffer.concat([dir, entry, image]);
}

const buf = build();
fs.mkdirSync(path.dirname(out), { recursive: true });
fs.writeFileSync(out, buf);
console.log(`${out}: ${buf.length} bytes (${SIZE}x${SIZE}, 32bpp BGRA + AND mask)`);
