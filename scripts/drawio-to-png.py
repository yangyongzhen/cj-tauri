#!/usr/bin/env python3
"""把 docs/diagrams 里的 drawio 图元按真实坐标渲染成 PNG（不依赖 drawio CLI）。

本机没有 drawio / rsvg / cairosvg，只有 python + Pillow，所以这里自己做一层最小渲染：
只覆盖本仓图里实际用到的形状（swimlane 泳道、圆角矩形、菱形、纯文本、正交连线 + 箭头）。

用法：
  python scripts/drawio-to-png.py docs/diagrams/cj-tauri-multiplatform-arch.drawio docs/images
不写第二个参数时输出到 docs/images。图为 2 倍分辨率（README 里缩放显示仍清晰）。

改图请改 drawio，然后重跑本脚本——不要直接改 PNG。
"""

import sys
import xml.etree.ElementTree as ET
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

SCALE = 2                 # 输出倍率
BG = "#F8FAFC"            # 画布底色（与 drawio 的 background 一致）
FONT_REG = "C:/Windows/Fonts/msyh.ttc"      # 微软雅黑（图里声明了 Microsoft YaHei）
FONT_BOLD = "C:/Windows/Fonts/msyhbd.ttc"
SHADOW = (15, 23, 42, 40)


def parse_style(raw):
    """drawio 的 style 串是 a=1;b=2;键单独出现的也当成开关。"""
    out = {}
    if not raw:
        return out
    for part in raw.split(";"):
        part = part.strip()
        if not part:
            continue
        if "=" in part:
            k, v = part.split("=", 1)
            out[k.strip()] = v.strip()
        else:
            out[part] = "1"
    return out


def color_of(value, fallback=None):
    if not value or value == "none":
        return fallback
    return value if value.startswith("#") else fallback


class Cell:
    __slots__ = ("cid", "value", "style", "x", "y", "w", "h", "parent", "vertex", "edge", "source", "target")

    def __init__(self, node):
        self.cid = node.get("id")
        self.value = node.get("value") or ""
        self.style = parse_style(node.get("style"))
        self.parent = node.get("parent")
        self.vertex = node.get("vertex") == "1"
        self.edge = node.get("edge") == "1"
        self.source = node.get("source")
        self.target = node.get("target")
        self.x = self.y = self.w = self.h = 0.0
        geo = node.find("mxGeometry")
        if geo is not None:
            self.x = float(geo.get("x", 0) or 0)
            self.y = float(geo.get("y", 0) or 0)
            self.w = float(geo.get("width", 0) or 0)
            self.h = float(geo.get("height", 0) or 0)


def load_diagram(path, name):
    """取指定 diagram 的 cell 列表，并把相对坐标累加成绝对坐标。"""
    root = ET.parse(path).getroot()
    for diagram in root.findall("diagram"):
        if diagram.get("name") != name and diagram.get("id") != name:
            continue
        model = diagram.find("mxGraphModel")
        cells = {}
        order = []
        for node in model.find("root").findall("mxCell"):
            cell = Cell(node)
            cells[cell.cid] = cell
            order.append(cell)
        # 子图元坐标相对父图元，逐层累加（泳道标题带也算在父坐标里）
        for cell in order:
            if cell.vertex:
                parent = cells.get(cell.parent)
                while parent is not None and parent.cid not in ("0", "1"):
                    cell.x += parent.x
                    cell.y += parent.y
                    parent = cells.get(parent.parent)
        page_w = int(model.get("pageWidth", 1200))
        page_h = int(model.get("pageHeight", 850))
        return cells, order, page_w, page_h
    raise SystemExit("diagram not found: %s" % name)


def font_for(size, bold=False):
    return ImageFont.truetype(FONT_BOLD if bold else FONT_REG, size)


def wrap(draw, text, font, max_w):
    """按像素宽度折行（中文逐字符、英文尽量不在单词中间断）。"""
    lines = []
    for raw_line in text.split("\n"):
        if not raw_line:
            lines.append("")
            continue
        cur = ""
        for ch in raw_line:
            trial = cur + ch
            if draw.textlength(trial, font=font) <= max_w or not cur:
                cur = trial
            else:
                lines.append(cur)
                cur = ch
        lines.append(cur)
    return lines


def draw_text_block(draw, cell, font, fill, align, pad):
    """在 cell 的框里居中画多行文本。"""
    text = cell.value
    if not text:
        return
    lines = wrap(draw, text, font, max(10, cell.w - pad * 2))
    line_h = font.size + 6
    total = line_h * len(lines)
    top = cell.y + (cell.h - total) / 2
    for i, line in enumerate(lines):
        tw = draw.textlength(line, font=font)
        if align == "left":
            tx = cell.x + pad
        else:
            tx = cell.x + (cell.w - tw) / 2
        draw.text((tx, top + i * line_h), line, font=font, fill=fill)


def anchor(cell, frac_x=None, frac_y=None, toward=None):
    """取连线端点：显式给了 exit/entry 比例就用它，否则按「朝对方的那条边」取中点。"""
    if frac_x is not None and frac_y is not None:
        return (cell.x + cell.w * frac_x, cell.y + cell.h * frac_y)
    cx, cy = cell.x + cell.w / 2, cell.y + cell.h / 2
    if toward is None:
        return (cx, cy)
    tx, ty = toward
    dx, dy = tx - cx, ty - cy
    if abs(dy) >= abs(dx):
        return (cx, cell.y + cell.h) if dy > 0 else (cx, cell.y)
    return (cell.x + cell.w, cy) if dx > 0 else (cell.x, cy)


def route(p1, p2):
    """正交折线：主方向走中线，避免直线斜穿别的框。"""
    (x1, y1), (x2, y2) = p1, p2
    if abs(x1 - x2) < 2 or abs(y1 - y2) < 2:
        return [p1, p2]
    if abs(y2 - y1) >= abs(x2 - x1):
        mid = (y1 + y2) / 2
        return [p1, (x1, mid), (x2, mid), p2]
    mid = (x1 + x2) / 2
    return [p1, (mid, y1), (mid, y2), p2]


def arrow_head(draw, p_from, p_to, color, size):
    (x1, y1), (x2, y2) = p_from, p_to
    dx, dy = x2 - x1, y2 - y1
    dist = (dx * dx + dy * dy) ** 0.5 or 1
    ux, uy = dx / dist, dy / dist
    bx, by = x2 - ux * size, y2 - uy * size
    px, py = -uy * size * 0.42, ux * size * 0.42
    draw.polygon([(x2, y2), (bx + px, by + py), (bx - px, by - py)], fill=color)


def render(src, diagram_name, out_path, scale=SCALE):
    cells, order, page_w, page_h = load_diagram(src, diagram_name)
    # 画布按内容与声明页面的较大者，四周留 20px 边距
    max_x = max((c.x + c.w for c in order if c.vertex), default=0)
    max_y = max((c.y + c.h for c in order if c.vertex), default=0)
    width = int(max(page_w, max_x) + 20) * scale
    height = int(max(page_h, max_y) + 20) * scale

    img = Image.new("RGB", (width, height), BG)
    draw = ImageDraw.Draw(img, "RGBA")

    def S(v):
        return v * scale

    # 先画泳道（底），再画普通图元，最后画连线与文字
    swim = [c for c in order if c.vertex and c.style.get("swimlane")]
    plain = [c for c in order if c.vertex and not c.style.get("swimlane") and not c.style.get("text")]
    texts = [c for c in order if c.vertex and c.style.get("text")]

    for c in swim:
        stroke = color_of(c.style.get("strokeColor"), "#94A3B8")
        x, y, w, h = S(c.x), S(c.y), S(c.w), S(c.h)
        dash = c.style.get("dashed") == "1"
        if dash:
            # PIL 没有虚线矩形，靠短线段拼
            step = S(8)
            for t in range(int(x), int(x + w), step * 2):
                draw.line([(t, y), (min(t + step, x + w), y)], fill=stroke, width=S(2))
                draw.line([(t, y + h), (min(t + step, x + w), y + h)], fill=stroke, width=S(2))
            for t in range(int(y), int(y + h), step * 2):
                draw.line([(x, t), (x, min(t + step, y + h))], fill=stroke, width=S(2))
                draw.line([(x + w, t), (x + w, min(t + step, y + h))], fill=stroke, width=S(2))
        else:
            draw.rectangle([x, y, x + w, y + h], outline=stroke, width=S(2))
        fsize = int(float(c.style.get("fontSize", 15)) * scale)
        f = font_for(fsize, c.style.get("fontStyle") == "1")
        title = c.value
        if title:
            band = fsize + S(10)
            draw.rectangle([x, y, x + w, y + band], fill=BG)
            tw = draw.textlength(title, font=f)
            draw.text((x + (w - tw) / 2, y + S(4)), title, font=f,
                      fill=color_of(c.style.get("fontColor"), "#2D3748"))

    for c in plain + texts:
        fill_style = c.style
        is_text = "text" in fill_style and not fill_style.get("fillColor")
        fsize = int(float(fill_style.get("fontSize", 15)) * scale)
        f = font_for(fsize, fill_style.get("fontStyle") == "1")
        fcolor = color_of(fill_style.get("fontColor"), "#1F2937")
        x, y, w, h = S(c.x), S(c.y), S(c.w), S(c.h)
        if not is_text:
            fill = color_of(fill_style.get("fillColor"))
            stroke = color_of(fill_style.get("strokeColor"))
            if fill_style.get("rhombus") is not None or "rhombus" in fill_style:
                pts = [(x + w / 2, y), (x + w, y + h / 2), (x + w / 2, y + h), (x, y + h / 2)]
                if fill_style.get("shadow") == "1":
                    draw.polygon([(px + S(2), py + S(3)) for px, py in pts], fill=SHADOW)
                draw.polygon(pts, fill=fill, outline=stroke)
            else:
                radius = S(10) if fill_style.get("rounded") == "1" else 0
                box = [x, y, x + w, y + h]
                if fill_style.get("shadow") == "1":
                    draw.rounded_rectangle([x + S(2), y + S(3), x + w + S(2), y + h + S(3)],
                                           radius=radius, fill=SHADOW)
                draw.rounded_rectangle(box, radius=radius, fill=fill, outline=stroke,
                                       width=S(1) if stroke else 0)
        align = fill_style.get("align", "center")
        draw_text_block(draw, _Shift(c, x, y, w, h), f, fcolor, align, S(8))

    for c in order:
        if not c.edge:
            continue
        src_cell, dst_cell = cells.get(c.source), cells.get(c.target)
        if not src_cell or not dst_cell:
            continue
        sc = (src_cell.x + src_cell.w / 2, src_cell.y + src_cell.h / 2)
        tc = (dst_cell.x + dst_cell.w / 2, dst_cell.y + dst_cell.h / 2)
        ep = c.style
        p1 = anchor(src_cell,
                    float(ep["exitX"]) if "exitX" in ep else None,
                    float(ep["exitY"]) if "exitY" in ep else None,
                    toward=tc)
        p2 = anchor(dst_cell,
                    float(ep["entryX"]) if "entryX" in ep else None,
                    float(ep["entryY"]) if "entryY" in ep else None,
                    toward=sc)
        pts = [(S(px), S(py)) for px, py in route(p1, p2)]
        color = color_of(ep.get("strokeColor"), "#94A3B8")
        width_px = S(float(ep.get("strokeWidth", 1)))
        if ep.get("dashed") == "1":
            for a, b in zip(pts, pts[1:]):
                seg = ((b[0] - a[0]) ** 2 + (b[1] - a[1]) ** 2) ** 0.5
                if not seg:
                    continue
                n = max(1, int(seg / S(8)))
                for i in range(0, n, 2):
                    t0, t1 = i / n, min((i + 1) / n, 1)
                    draw.line([(a[0] + (b[0] - a[0]) * t0, a[1] + (b[1] - a[1]) * t0),
                               (a[0] + (b[0] - a[0]) * t1, a[1] + (b[1] - a[1]) * t1)],
                              fill=color, width=int(max(1, width_px)))
        else:
            draw.line(pts, fill=color, width=int(max(1, width_px)), joint="curve")
        arrow_head(draw, pts[-2], pts[-1], color, S(9))
        label = c.value
        if label:
            fsize = int(float(ep.get("fontSize", 15)) * scale)
            f = font_for(fsize, False)
            # 标签贴着**这条线自己**的最长线段放：优先横线段（横线上方/下方，按走向分开），
            # 没有够长的横段才用竖段（放右侧）。这样同一水平高度上的多条连线不会把标签叠在一起
            flat = [(a, b) for a, b in zip(pts, pts[1:])
                    if abs(b[0] - a[0]) >= abs(b[1] - a[1]) and abs(b[0] - a[0]) >= 20 * scale]
            if flat:
                seg = max(flat, key=lambda ab: abs(ab[1][0] - ab[0][0]))
            else:
                seg = max(zip(pts, pts[1:]),
                          key=lambda ab: (ab[1][0] - ab[0][0]) ** 2 + (ab[1][1] - ab[0][1]) ** 2)
            (ax, ay), (bx, by) = seg
            tw = draw.textlength(label, font=f)
            th = fsize + S(4)
            if abs(bx - ax) >= abs(by - ay):
                mx, my = (ax + bx) / 2, (ay + by) / 2
                # 向下的线标签压在线下，向上的线标签放在线上
                down = p2[1] >= p1[1]
                my = my + th / 2 + S(3) if down else my - th / 2 - S(3)
                box = [mx - tw / 2 - S(3), my - th / 2, mx + tw / 2 + S(3), my + th / 2]
                tpos = (mx - tw / 2, my - th / 2 + S(2))
            else:
                mx, my = (ax + bx) / 2, (ay + by) / 2
                mx = mx + tw / 2 + S(6)
                box = [mx - tw / 2 - S(3), my - th / 2, mx + tw / 2 + S(3), my + th / 2]
                tpos = (mx - tw / 2, my - th / 2 + S(2))
            draw.rectangle(box, fill=BG)
            draw.text(tpos, label, font=f, fill=color_of(ep.get("fontColor"), "#64748B"))

    out = Path(out_path)
    out.parent.mkdir(parents=True, exist_ok=True)
    img.save(out, optimize=True)
    print("wrote %s  (%dx%d, %.1f KB)" % (out, width, height, out.stat().st_size / 1024))


class _Shift:
    """把绝对坐标的框交给 draw_text_block（它按 cell.x/y/w/h 排版）。"""

    def __init__(self, cell, x, y, w, h):
        self.value = cell.value
        self.x, self.y, self.w, self.h = x, y, w, h


def main(argv):
    if len(argv) < 2:
        raise SystemExit(__doc__)
    src = Path(argv[1])
    out_dir = Path(argv[2]) if len(argv) > 2 else Path("docs/images")
    for name, stem in (("overall-arch", "architecture-multiplatform"),
                       ("sync-flow", "architecture-sync-flow"),
                       ("runtime-bridge", "architecture-runtime-bridge")):
        render(str(src), name, str(out_dir / (stem + ".png")))


if __name__ == "__main__":
    main(sys.argv)
