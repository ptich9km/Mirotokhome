#!/usr/bin/env python3
"""Набор героя из полос Nano Banana (google/gemini-nano-banana-2.1), 4 панели.

Почему 4 панели, а не 8 (замер 14.10): 8 фигур по ~190px на 1536px физически
не помещаются — в промежутках удара было 15-72px ЧУЖОЙ руки, в промежутках
смерти до 234px. Четыре фигуры занимают по ~380px, зазоры выходят 50-285px.

Почему «сильный» порог (замер 14.10): полоса удара пришла с двумя рядами —
сверху полупрозрачные призрачные фигуры, снизу настоящие. Отличаются они
насыщенностью: у настоящих пиксели далеко от цвета фона (сталь/кожа/ткань),
у призраков размыты и к фону близки. Поэтому фигуры ищем по dist > 120,
а вырезку делаем заливкой от краёв по расстоянию до цвета углов.

Ряды: у полосы удара призраки и фигуры в одних колонках, поэтому сначала
режем изображение по горизонтали и берём полосу с максимумом «сильных»
пикселей.

Контракт набора: dirs=1 + зеркало, холст 64x64, низ контента y=62,
idle 1 + move 4 + attack 3 + dying 4 = 12 кадров.

Почему в ударе 3, а не 4 (замер 14.10): 4-я панель полосы удара совпала с
3-й — та же полная вытяжка, разницы в позе нет. Цикл замыкается сам:
стойка -> замах -> удар -> возврат в стойку (1-й кадр = последний).
"""
import argparse
import json
import sys
from collections import deque
from pathlib import Path

import numpy as np
from PIL import Image

from gen_hero_strip import components

REPO = Path(__file__).resolve().parent.parent
SRC = REPO / "import" / "Player"

# Полосы и наборы. Мужская ветка (nb5) — по умолчанию, женская (nb6)
# добавляется флагами, чтобы старая команда из журнала работала как раньше.
SETS = {
    "nb5": ("war_men", "war men"),
    "nb6": ("war_women", "war women"),
    # Путник (11.11): мирный НПЦ из события «спасти путника». Тот же контракт
    # 12 кадров, но кладётся не в hero/, а в npc/ (--dest npc).
    "tv1": ("traveler_m", "traveler men"),
    # Нежить (Пожинатели) и друиды (Круг Друидов), 20.10 — тот же контракт.
    "un1": ("undead_men", "undead men"),
    "dr1": ("druid_men", "druid men"),
    # Женские версии тех же рас, 20.10 — тот же контракт.
    "un2": ("undead_women", "undead women"),
    "dr2": ("druid_women", "druid women"),
    # Орки (15.10, игрок) — тот же контракт, другой персонаж. Мужской орк
    # oc1, женский oc2; полосы лежат рядом с человеческими по тому же --tag.
    "oc1": ("orc_men", "orc men"),
    "oc2": ("orc_women", "orc women"),
    # Маги и магички всех 4 рас, 21.10 — тот же контракт.
    "hm1": ("mage_human_men", "mage human men"),
    "hm2": ("mage_human_women", "mage human women"),
    "om1": ("mage_orc_men", "mage orc men"),
    "om2": ("mage_orc_women", "mage orc women"),
    "nm1": ("mage_undead_men", "mage undead men"),
    "nm2": ("mage_undead_women", "mage undead women"),
    "dm1": ("mage_druid_men", "mage druid men"),
    "dm2": ("mage_druid_women", "mage druid women"),
}

OUT_W, OUT_H, FEET_Y, TARGET_H = 64, 64, 62, 54
MAX_W = 60        # предел по ширине: та же полоса, что по вертикали (низ 62)
TOL = 45          # заливка фона от краёв
STRONG = 120      # порог «настоящей» фигуры против призрака
MIN_COL = 5       # колонка короче — не фигура
EDGE_MIN = 3      # поле от фигуры до края кадра; меньше — кадр срезан по нему
ROW_TOL = 50      # разброс линии стоп внутри одной строки панелей, px


def bg_ref(a):
    h, w, _ = a.shape
    corners = np.concatenate([
        a[:24, :24].reshape(-1, 3), a[:24, -24:].reshape(-1, 3),
        a[-24:, :24].reshape(-1, 3), a[-24:, -24:].reshape(-1, 3)])
    return np.median(corners, axis=0)


def cut_mask(a, ref, tol=TOL):
    h, w, _ = a.shape
    dist = np.sqrt(((a - ref) ** 2).sum(axis=2))
    dark_magenta = (a[..., 1] < a[..., 2] - 25) & ((a[..., 0] - a[..., 1]) > 60)
    near = (dist <= tol) | dark_magenta
    seen = np.zeros((h, w), dtype=bool)
    q = deque()
    for x in range(w):
        for y in (0, h - 1):
            if near[y, x] and not seen[y, x]:
                seen[y, x] = True
                q.append((y, x))
    for y in range(h):
        for x in (0, w - 1):
            if near[y, x] and not seen[y, x]:
                seen[y, x] = True
                q.append((y, x))
    while q:
        y, x = q.popleft()
        for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            ny, nx = y + dy, x + dx
            if 0 <= ny < h and 0 <= nx < w and near[ny, nx] and not seen[ny, nx]:
                seen[ny, nx] = True
                q.append((ny, nx))
    fg = ~seen
    fg &= ~near
    return fg.astype(np.float32)


def row_band(strong):
    """Горизонтальные полосы контента; берём ту, где больше «сильных» пикселей.

    Замер 14.10: модель на двух полос из четырёх вернула 8 фигур в ДВА ряда
    (у удара второй ряд дословно копия первого). Берём один ряд — 4 фигуры,
    вторая копия нам не нужна. Если полос больше двух, это уже не «лишний ряд»,
    а мусор, и такой кадр лучше забраковать loudly, чем молча взять верхний.
    """
    rows = strong.sum(axis=1)
    active = rows >= 5
    bands, start = [], -1
    for y, v in enumerate(active):
        if v and start < 0:
            start = y
        elif not v and start >= 0:
            bands.append((start, y - 1))
            start = -1
    if start >= 0:
        bands.append((start, len(active) - 1))
    if len(bands) > 2:
        print(f"    ВНИМАНИЕ: полос контента {len(bands)} — это не лишний ряд, "
              f"а мусор: {bands}")
    best, best_area = bands[0], -1
    for y0, y1 in bands:
        area = int(strong[y0:y1 + 1].sum())
        print(f"    полоса y={y0}..{y1} h={y1 - y0 + 1} сильных={area}")
        if area > best_area:
            best, best_area = (y0, y1), area
    if len(bands) > 1:
        print(f"    берём полосу с максимумом сильных: y={best[0]}..{best[1]}")
    return best


def label_keep_largest(alpha):
    m = alpha > 0.5
    h, w = m.shape
    lab = np.zeros((h, w), dtype=np.int32)
    cur = 0
    for y in range(h):
        row = m[y]
        for x in range(w):
            if not row[x] or lab[y, x]:
                continue
            cur += 1
            stack = [(y, x)]
            lab[y, x] = cur
            while stack:
                cy, cx = stack.pop()
                for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                    ny, nx = cy + dy, cx + dx
                    if 0 <= ny < h and 0 <= nx < w and m[ny, nx] and not lab[ny, nx]:
                        lab[ny, nx] = cur
                        stack.append((ny, nx))
    if cur <= 1:
        return alpha
    areas = np.bincount(lab.ravel(), minlength=cur + 1)
    areas[0] = 0
    keep = areas >= areas.max() * 0.25
    keep[0] = False
    out = alpha.copy()
    out[~keep[lab]] = 0.0
    return out


def rows_of(boxes, tol=ROW_TOL):
    """Группировка компонентов в строки по линии стоп.

    Нужна из-за полос, где модель кладёт панели не в один ряд, а в две строки
    или по диагонали. Компоненты при этом НЕ слипаются (метки эксклюзивны,
    общих пикселей нет) — расходится только прямоугольник, и сортировка
    «сверху вниз, слева направо» даёт вперемешку из обеих строк.

    Признак строки — общая ЛИНИЯ СТОП, а не вертикальное перекрытие: в падении
    верх фигуры уезжает вниз с каждой панелью, а низ остаётся на земле. На
    полосе смерти орк-женщины (16.10) низ четырёх панелей: 1682, 1674, 1670,
    1672 — разброс 12 px, то есть одна строка. По перекрытию четвёртая
    панель отваливалась в отдельную «строку» (её высота 219 против 791 у
    первой, и порог перекрытия рос вместе со строкой).
    """
    rows = []
    for b in sorted(boxes, key=lambda t: t[1]):
        best, best_d = None, None
        for r in rows:
            d = abs(b[1] - r["feet"])
            if d <= tol and (best_d is None or d < best_d):
                best, best_d = r, d
        if best is None:
            rows.append({"feet": b[1], "boxes": [b]})
        else:
            best["feet"] = (best["feet"] * len(best["boxes"]) + b[1]) // (len(best["boxes"]) + 1)
            best["boxes"].append(b)
    return rows


def head_feet_offset(alpha):
    """Смещение головы относительно стоп, в долях ширины фигуры.

    Знак читается как направление падения: положительный - голова впереди
    стоп (падает ВПЕРЁД), отрицательный - голова позади (падает НАЗАД).
    Нужен, чтобы ловить полосу, где первые панели падают в одну сторону, а
    последняя показывает падение в другую (замер 16.10 на полосе смерти
    орк-женщины: +0.029, +0.105, +0.235, и вдруг -0.151).
    """
    ys, xs = np.where(alpha > 0.5)
    if ys.size == 0:
        return 0.0
    y0, y1, x0 = int(ys.min()), int(ys.max()), int(xs.min())
    w = max(1, int(xs.max()) - x0)
    h = y1 - y0 + 1

    def cx(ra, rb):
        cols = np.where(alpha[ra:rb + 1] > 0.5)[1]
        return float(cols.mean() - x0) / w if cols.size else 0.0

    head = cx(y0, y0 + max(1, int(h * 0.15)))
    feet = cx(y1 - max(1, int(h * 0.25)), y1)
    return head - feet


def figures_of(path, expect):
    a = np.array(Image.open(path).convert("RGB")).astype(np.int32)
    ref = bg_ref(a)
    dist = np.sqrt(((a - ref) ** 2).sum(axis=2))
    strong = dist > STRONG
    y0, y1 = row_band(strong)
    alpha_full = cut_mask(a, ref)

    # Сперва связные компоненты: они считают фигуры напрямую. Колонночные
    # прогоны остаются запасным путём — на некоторых полосах соседние фигуры
    # не касаются и компонент выходит больше ожидаемого (шлейфы, осколки).
    boxes = components(alpha_full)
    print(f"    компонент-фигур: {len(boxes)} (ожидалось {expect})")
    if len(boxes) >= expect:
        chosen = boxes[:expect]
        if len(boxes) > expect:
            # 15.10/16.10: лишние компоненты отбрасывались МОЛЧА. На полосе
            # ходьбы орк-женщины их было 8 вместо 4 (два ряда по четыре) — в игру
            # уехал верхний ряд, нижний просто исчез, и полоса считалась годной.
            # Теперь это громкий ВНИМАНИЕ: либо модель разложила панели в две
            # строки, либо фигуры слиплись. Проверяется глазами по контактному
            # листу, а не догадкой инструмента.
            print(f"    ВНИМАНИЕ: компонентов {len(boxes)} больше ожидаемых {expect}")
            groups = sorted(rows_of(boxes), key=lambda r: min(b[0] for b in r["boxes"]))
            for gi, r in enumerate(groups, 1):
                ys_ = [b[0] for b in r["boxes"]]
                ye_ = [b[1] for b in r["boxes"]]
                print(f"      строка {gi}: фигур {len(r['boxes'])}, "
                      f"y={min(ys_)}..{max(ye_)}, стопы {min(ye_)}..{max(ye_)}")
            exact = [r for r in groups if len(r["boxes"]) == expect]
            if len(exact) == 1:
                # Ровно одна строка содержит нужное число панелей - берём её.
                # На полосе смерти орк-женщины (16.10) сверху лежали 3 панели,
                # снизу 4: сортировка отдавала 3 верхние и 1 нижнюю.
                chosen = sorted(exact[0]["boxes"], key=lambda b: b[2])
                print(f"      берём строку с {expect} панелями (остальные строки "
                      f"отброшены: {len(boxes) - expect} фигур)")
            else:
                chosen = boxes[:expect]
                print(f"      строк с ровно {expect} панелями: {len(exact)} — "
                      f"взять строку однозначно нельзя, берём первые {expect}")
                for extra in boxes[expect:]:
                    print(f"      отброшен {extra[3] - extra[2] + 1}x{extra[1] - extra[0] + 1} "
                          f"на y={extra[0]}..{extra[1]}")
        out = []
        h_img, w_img = a.shape[:2]
        for by0, by1, bx0, bx1 in chosen:
            sub = alpha_full[by0:by1 + 1, bx0:bx1 + 1]
            crop = a[by0:by1 + 1, bx0:bx1 + 1]
            # Фигура у края кадра = кадр срезан по нему (замер 15.10: у орка
            # панель 12 упиралась в левый край, у орк-женщины панели 1 и 4 — в
            # левый и правый). preflight на это не смотрит, поэтому здесь.
            pads = (bx0, by0, w_img - 1 - bx1, h_img - 1 - by1)
            if min(pads) < EDGE_MIN:
                print(f"      ВНИМАНИЕ: фигура у края кадра "
                      f"(поля L{pads[0]} T{pads[1]} R{pads[2]} B{pads[3]}) - кадр срезан")
            print(f"      {bx1 - bx0 + 1}x{by1 - by0 + 1}")
            out.append((crop, sub))
        return out
    print("    компонентов мало, перехожу на колонки")

    alpha = alpha_full[y0:y1 + 1]

    col = (alpha > 0.5).sum(axis=0)
    active = col >= MIN_COL
    runs, start = [], -1
    for x, v in enumerate(active):
        if v and start < 0:
            start = x
        elif not v and start >= 0:
            runs.append((start, x - 1))
            start = -1
    if start >= 0:
        runs.append((start, len(active) - 1))
    print(f"    фигур найдено: {len(runs)} (ожидалось {expect})")

    # Соприкасающиеся фигуры дают один широкий кусок (замер 14.10: в полосе
    # удара третий кусок 1322px против ~500 у остальных — это две фигуры,
    # кулаки коснулись). Делим такой кусок по минимуму профиля колонок.
    if runs:
        changed = True
        while changed:
            changed = False
            # Медиана пересчитывается НА КАЖДОМ проходе. Раньше она считалась
            # один раз до цикла, и это ломало дорез кусков из трёх фигур:
            # первый проход резал 1842px пополам, второй видел 1174px против
            # старой медианы 1197 и не резал их больше (женская полоса удара
            # 14.10: слиплись фигуры 2, 3 и 4 — процесс останавливался на 3).
            med = float(np.median([b - a0 for a0, b in runs]))
            out = []
            for x0, x1 in runs:
                if x1 - x0 > med * 1.5 and (x1 - x0) > 40:
                    prof = alpha[:, x0:x1 + 1].sum(axis=0).astype(float)
                    lo, hi = int(len(prof) * 0.25), int(len(prof) * 0.75)
                    cut = lo + int(np.argmin(prof[lo:hi]))
                    print(f"    дорез слипшегося куска x={x0}..{x1} на x={x0 + cut}")
                    out += [(x0, x0 + cut), (x0 + cut + 1, x1)]
                    changed = True
                else:
                    out.append((x0, x1))
            runs = out
        if len(runs) != expect:
            print(f"    после дореза фигур: {len(runs)} (ожидалось {expect})")

    out = []
    for x0, x1 in runs:
        sub = alpha[:, x0:x1 + 1]
        sub = label_keep_largest(sub)
        ys, xs = np.where(sub > 0.5)
        if ys.size == 0:
            out.append(None)
            continue
        ry0, ry1, rx0, rx1 = int(ys.min()), int(ys.max()), int(xs.min()), int(xs.max())
        full = alpha_full[y0 + ry0:y0 + ry1 + 1, x0 + rx0:x0 + rx1 + 1]
        crop = a[y0 + ry0:y0 + ry1 + 1, x0 + rx0:x0 + rx1 + 1]
        print(f"      w={rx1 - rx0 + 1} h={ry1 - ry0 + 1}")
        out.append((crop, full))
    return out


def fit(rgb, alpha, scale):
    h, w = alpha.shape
    nw, nh = max(1, int(round(w * scale))), max(1, int(round(h * scale)))
    a_src = (alpha * 255).astype(np.uint8)
    prem = (rgb.astype(np.float32) * alpha[:, :, None]).astype(np.uint8)
    a_s = np.asarray(Image.fromarray(a_src, "L").resize((nw, nh), Image.Resampling.BOX), np.float32) / 255
    p_s = np.asarray(Image.fromarray(prem, "RGB").resize((nw, nh), Image.Resampling.BOX), np.float32)
    rgb_s = np.clip(p_s / np.maximum(a_s, 1e-4)[:, :, None], 0, 255)
    a_s = np.where(a_s < 0.25, 0.0, np.minimum(1.0, a_s * 1.35))
    arr = np.dstack([rgb_s.round().astype(np.uint8), (a_s * 255).round().astype(np.uint8)])
    # Осколок соседней фигуры может возникнуть уже ПОСЛЕ уменьшения (в
    # источнике он касался руки, а на 64px отделился). Отбрасываем всё,
    # что меньше 15% главной компоненты — итоговой картинки, не источника.
    m = arr[:, :, 3] > 32
    lab = np.zeros(m.shape, np.int32)
    cur = 0
    h2, w2 = m.shape
    for y in range(h2):
        for x in range(w2):
            if not m[y, x] or lab[y, x]:
                continue
            cur += 1
            stack = [(y, x)]
            lab[y, x] = cur
            while stack:
                cy, cx = stack.pop()
                for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                    ny, nx = cy + dy, cx + dx
                    if 0 <= ny < h2 and 0 <= nx < w2 and m[ny, nx] and not lab[ny, nx]:
                        lab[ny, nx] = cur
                        stack.append((ny, nx))
    if cur > 1:
        areas = np.bincount(lab.ravel(), minlength=cur + 1)
        areas[0] = 0
        keep = areas >= areas.max() * 0.15
        keep[0] = False
        arr[~keep[lab], 3] = 0
        print(f"      убран осколок: {int(m.sum() - keep[lab].sum())} px")
    fr = Image.fromarray(arr, "RGBA")
    cell = Image.new("RGBA", (OUT_W, OUT_H), (0, 0, 0, 0))
    cell.paste(fr, ((OUT_W - nw) // 2, FEET_Y - nh), fr)
    return cell


DIR_DEADBAND = 0.03   # смещение меньше этого - шум, а не направление падения

# --- Флип-нормализация посоха (mage, 21.10) --------------------------------
# Промт не умеет зафиксировать руку: «LEFT hand» рисовало посох в правой,
# «right side of picture» — два посоха и 2 ряда. Модель выбирает руку сама,
# фаза к фазе. Лечение — измерение: посох = тонкая высокая вертикаль
# у края фигуры. Ищем колонку вне тела с максимумом заполнения по верхним
# 60% высоты; если посох оказался в «неправильной» стороне, кадр зеркалится.
# Нейтральный канон: посох держится СЛЕВА от зрителя (как в одобренных
# stand-полосах, 21.10).
MAGE_TAGS = {"hm1", "hm2", "om1", "om2", "nm1", "nm2", "dm1", "dm2"}


def _staff_side(rgb, alpha):
    """Вернуть сторону посоха: 'left'/'right'/'none'/'both'.

    Посох ищем в верхних 60% высоты фигуры как вертикальную палку:
    колонки, где alpha>0.5, группируем в отрезки, отрезок считаем палкой,
    если он узкий (<= 8% ширины фигуры), высокий (>= 40% высоты) и его
    заполнение почти сплошное (>= 0.6).
    """
    h, w = alpha.shape
    m = alpha > 0.5
    ys, _ = np.where(m)
    if ys.size == 0:
        return "none"
    top, bot = int(ys.min()), int(ys.max())
    band_top = top + int((bot - top) * 0.0)
    band_bot = top + int((bot - top) * 0.60)
    col = m[band_top:band_bot + 1, :].sum(axis=0)
    col_h = band_bot - band_top + 1
    active = col >= max(2, int(col_h * 0.35))
    runs, start = [], -1
    for x, v in enumerate(active):
        if v and start < 0:
            start = x
        elif not v and start >= 0:
            runs.append((start, x - 1))
            start = -1
    if start >= 0:
        runs.append((start, len(active) - 1))
    sticks = []
    for x0, x1 in runs:
        wd = x1 - x0 + 1
        fill = col[x0:x1 + 1].mean() / max(1, col_h)
        if wd <= max(3, int(w * 0.08)) and (x1 - x0 + 1) * fill >= col_h * 0.4 \
                and fill >= 0.6:
            sticks.append(((x0 + x1) / 2, wd))
    if not sticks:
        return "none"
    if len(sticks) >= 2 and sticks[0][0] < w * 0.3 and sticks[-1][0] > w * 0.7:
        return "both"
    center = sticks[0][0]
    if center < w * 0.45:
        return "left"
    if center > w * 0.55:
        return "right"
    return "none"


def _flip_staff_normalization(figs, tag):
    """Для mage-наборов: зеркалить фазы, где посох не в левой половине.

    Кадр с посохом «both» не лечится флипом — печатаем ВНИМАНИЕ, решение
    за игроком (перегенерация). Возвращает список фаз с пометкой флипа.
    """
    if tag not in MAGE_TAGS:
        return figs
    out = []
    for i, (rgb, al) in enumerate(figs):
        if rgb is None:
            out.append((rgb, al))
            continue
        side = _staff_side(rgb, al)
        if side == "right":
            print(f"    фаза {i + 1}: посох справа — зеркалю кадр")
            out.append((np.ascontiguousarray(rgb[:, ::-1]),
                        np.ascontiguousarray(al[:, ::-1])))
        elif side == "both":
            print(f"    ВНИМАНИЕ: фаза {i + 1}: посох в ОБОИХ руках — флип не "
                  f"лечит, нужна перегенерация полосы")
            out.append((rgb, al))
        else:
            out.append((rgb, al))
    return out


def _mirror_if_direction_breaks(figs, cell, k):
    """Отзеркалить последний кадр смерти, если он падает в другую сторону.

    Признак — измерение, а не догадка: `head_feet_offset` даёт смещение головы
    относительно стоп в долях ширины фигуры. Если первые панели падают в одну
    сторону, а последняя в другую, полоса противоречит сама себе; отражённый
    кадр продолжает падение. На принятом наборе orc_men правило молчит
    (+0.172, +0.070, +0.028 — все вперёд), на полосе орк-женщины срабатывает.
    """
    offs = [head_feet_offset(al) for _, al in figs]
    early = offs[:-1]
    pos = sum(1 for o in early if o > DIR_DEADBAND)
    neg = sum(1 for o in early if o < -DIR_DEADBAND)
    want = 1 if pos > neg else (-1 if neg > pos else 0)
    last = offs[-1]
    detail = " ".join(f"{o:+.3f}" for o in offs)
    if want and last * want < -DIR_DEADBAND:
        print(f"    ВНИМАНИЕ: панели {detail} — последняя противоречит падению, "
              f"зеркалю её")
        return cell.transpose(Image.FLIP_LEFT_RIGHT)
    print(f"    направление падения согласовано: {detail}")
    return cell


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tag", default="nb5", choices=sorted(SETS),
                    help="тег полос: nb5 — воин, nb6 — воительница")
    ap.add_argument("--only", default="", choices=("idle", "walk", "attack", "dying"),
                    help="перерезать только этот блок, остальные кадры не трогать")
    ap.add_argument("--strip", default="",
                    help="полоса для блока из --only (путь к PNG)")
    ap.add_argument("--pick", default="",
                    help="ручной выбор панелей 'строка:колонка', напр. '1:1,1:2,1:3,2:1'")
    ap.add_argument("--dry-run", action="store_true",
                    help="ничего не записывать: только сравнить, что изменилось бы "
                         "на диске. Наборы людей НЕ воспроизводятся из своих полос "
                         "текущим нарезчиком (они нарезаны версией до MAX_W), "
                         "поэтому слепой пересборкой можно затереть принятый игроком "
                         "арт. Проверяй этим перед любым запуском без --strip.")
    ap.add_argument("--dest", default="hero",
                    help="папка внутри assets/units: hero (по умолчанию), npc (путник)")
    args = ap.parse_args()

    out_folder, out_label = SETS[args.tag]
    out_dir = REPO / "assets" / "units" / args.dest / out_folder
    out_dir.mkdir(parents=True, exist_ok=True)

    blocks = []
    for name, fname, expect, take in [
        ("idle", f"hero_stand_{args.tag}.png", 4, 1),
        ("walk", f"hero_walk_{args.tag}.png", 4, 4),
        ("attack", f"hero_attack_{args.tag}.png", 4, 3),
        ("dying", f"hero_die_{args.tag}.png", 4, 4),
    ]:
        if args.only and name != args.only:
            continue
        # --strip перекрывает полосу этого блока: нужно, когда одна фаза
        # перегенерирована отдельно, а остальные три остаются из прошлой
        # сборки (15.10 ночь: у орка поменяли только смерть).
        src = Path(args.strip) if (args.only and name == args.only and args.strip) else SRC / fname
        print(f"{name}: {src.name}")
        figs = figures_of(src, expect)
        if args.pick:
            # Ручной выбор панелей «строка:колонка» (например, hm2 attack:
            # 1:1,1:2,1:3,2:1). Разбиваем лист на сетку expect ячеек, сколько
            # их фактичесски на изображении — по найденным компонентам/строкам.
            import re as _re
            # ячейка может нести суффикс 'm' — отзеркалить кадр по горизонтали
            # (игрок: «2:2 надо отзеркалить, упал не в ту сторону головой»)
            cells = []
            mirror = []
            for c in args.pick.split(","):
                c = c.strip().lower()
                m = c.endswith("m")
                r_, c_ = map(int, c.rstrip("m").split(":"))
                cells.append((r_, c_))
                mirror.append(m)
            if len(cells) != expect:
                print(f"FAIL: --pick содержит {len(cells)} ячеек, ожидается {expect}")
                return 1
            a_img = np.array(Image.open(src).convert("RGB")).astype(np.int32)
            all_boxes = components(cut_mask(a_img, bg_ref(a_img)))
            rows_ = sorted(rows_of(all_boxes), key=lambda r: min(b[0] for b in r["boxes"]))
            grid = {}
            for ri, r in enumerate(rows_, 1):
                for ci, b in enumerate(sorted(r["boxes"], key=lambda t: t[2]), 1):
                    grid[(ri, ci)] = b
            missing = [c for c in cells if c not in grid]
            if missing:
                print(f"FAIL: ячейки {missing} не найдены на листе")
                return 1
            figs = []
            for i, (r_, c_) in enumerate(cells):
                by0, by1, bx0, bx1 = grid[(r_, c_)]
                crop = a_img[by0:by1 + 1, bx0:bx1 + 1]
                if mirror[i]:
                    crop = crop[:, ::-1]
                sub = cut_mask(crop, bg_ref(a_img))
                figs.append((crop, sub))
            print(f"    --pick: взяты ячейки {args.pick}")
        if len(figs) != expect or any(f is None for f in figs):
            print(f"FAIL: {name} — фигур {len(figs)}, годных {sum(f is not None for f in figs)}")
            return 1
        if name != "dying":
            # Флип-нормализация посоха (mage, 21.10): фазу смерти не трогаем,
            # там фигура лежит и посох не читается.
            figs = _flip_staff_normalization(figs, args.tag)
        blocks.append((name, figs[:take]))

    # Номер первого кадра блока в общей нумерации 1..12. Считается по полной
    # раскладке, а не по позиции в blocks: при --only в blocks один блок,
    # а кадры должны попасть на свои места (dying -> 9..12), иначе
    # перезапись одной фазы сдвинула бы остальные.
    first = {"idle": 1, "walk": 2, "attack": 6, "dying": 9}

    frames = []
    for name, figs in blocks:
        # Масштаб блока — общий для всех его фаз, иначе фигура пульсирует
        # между кадрами. Ограничиваем по ОБЕИМ осям: 15.10 в блоке dying
        # орка самая высокая фигура стоящая (54 px), а самая широкая — лежащая
        # (63 px на холсте 64), и по высоте она не влезала: кадр выходил
        # срезанным по краям. Раньше считался только TARGET_H (15.10).
        max_h = max(al.shape[0] for _, al in figs)
        max_w = max(al.shape[1] for _, al in figs)
        scale = min(TARGET_H / max_h, MAX_W / max_w)
        print(f"{name}: max h={max_h} w={max_w} scale={scale:.4f}")
        for k, (rgb, al) in enumerate(figs):
            cell = fit(rgb, al, scale)
            # Последний кадр смерти обязан продолжать то же падение, что и
            # предыдущие. Модель это иногда ломает: полоса смерти орк-женщины
            # дала смещение головы относительно стоп +0.029, +0.105, +0.235
            # (падает ВПЕРЁД), а в последней панели -0.151 (падает НАЗАД).
            # Зеркалим последний кадр, когда он противоречит остальным.
            if name == "dying" and len(figs) >= 2 and k == len(figs) - 1:
                cell = _mirror_if_direction_breaks(figs, cell, k)
            frames.append((first[name] + k, cell))

    # Старые кадры от прошлых сборок (25 штук) удаляем: база объявит frames=13,
    # но лишние файлы остались бы в репозитории и импортировались движком.
    # При --only удалять нельзя — блок один, а кадры остальных фаз на диске
    # единственные и пришли из другой полосы.
    if not args.dry_run and not args.only:
        for old in sorted(out_dir.glob("sprites-*.png")):
            old.unlink()

    changed = []
    for idx, fr in frames:
        target = out_dir / f"sprites-{idx:03d}.png"
        if args.dry_run:
            if not target.exists():
                changed.append(f"sprites-{idx:03d}.png ОТСУТСТВУЕТ")
            else:
                import hashlib
                import io
                # Хэшировать надо ТО ЖЕ, что уйдёт на диск: файл PNG, а не сырые
                # пиксели. Сравнение bytes-файла с tobytes() всегда даёт «различие».
                buf = io.BytesIO()
                fr.save(buf, format="PNG")
                old = hashlib.sha256(target.read_bytes()).hexdigest()
                new = hashlib.sha256(buf.getvalue()).hexdigest()
                if old != new:
                    changed.append(f"sprites-{idx:03d}.png ИЗМЕНЯЕТСЯ")
            continue
        fr.save(target)

    if args.dry_run:
        if changed:
            print(f"DRY-RUN: изменились бы {len(changed)} кадров из {len(frames)}:")
            for line in changed:
                print(f"  {line}")
        else:
            print(f"DRY-RUN: все {len(frames)} кадров на диске совпали бы байт в байт")
        print("DRY-RUN: ничего не записано")
        return 1 if changed else 0

    print(f"записано кадров: {len(frames)}")

    # Контактный лист собирается с диска, по всем sprites-*.png, а не из
    # набора `frames`: при --only в frames только один блок, и лист из 4
    # картинок перезаписал бы полный обзор набора из 12 (15.10 ночь).
    on_disk = sorted(out_dir.glob("sprites-*.png"))
    cols = 4
    rows = (len(on_disk) + cols - 1) // cols
    sheet = np.zeros((rows * OUT_H, cols * OUT_W, 3), np.uint8)
    for i, path in enumerate(on_disk):
        arr = np.array(Image.open(path).convert("RGBA"))
        yy, xx = np.mgrid[0:OUT_H, 0:OUT_W]
        chk = np.where(((xx // 8) + (yy // 8)) % 2 == 0, 90, 60).astype(np.uint8)
        cell = np.dstack([chk, chk, chk])
        m = arr[:, :, 3] > 8
        cell[m] = arr[:, :, :3][m]
        r, c = divmod(i, cols)
        sheet[r * OUT_H:(r + 1) * OUT_H, c * OUT_W:(c + 1) * OUT_W] = cell
    Image.fromarray(sheet).resize((cols * OUT_W * 3, rows * OUT_H * 3), Image.NEAREST) \
        .save(out_dir / "_contact_sheet.png")

    entry = {
        # frames — ВСЕГО в наборе (idle1+move4+attack3+dying4 = 12), а не
        # число записанных в этом прогоне. При --only блок один, и раньше
        # сюда попадало 4 — набор в базе объявлял бы 4 кадра (15.10 ночь).
        "desc": f"Hero: {out_label}, 4-panel strips (stand — Gemini 3.1 Flash, "
                "walk/attack/die — mai-image-2.6-flash), three-quarter east "
                "view + mirror, idle1+move4+attack3+dying4",
        # Порядок ключей - как в остальных 11 наборах репозитория (folder,
        # frames, prefix). Нарезчик писал frames перед folder, и любая пересборка
        # набора давала ложный diff из одной перестановки строк.
        "folder": f"hero/{out_folder}",
        "frames": 12, "prefix": "sprites",
        "dirs": 1, "idle_phases": 1, "move": 4, "move_begin": 0,
        "attack": 3, "dying": 4, "decay": 0, "cast": 0, "idle": 0,
        "move_f": [], "move_t": [], "attack_f": [], "attack_t": [], "die_f": [], "dying_t": [],
        "w": OUT_W, "h": OUT_H, "cx": OUT_W // 2, "cy": FEET_Y,
        "tile": None, "projectile": -1, "palette": 0, "blocks": 4,
        "resist": {"fire": 10, "water": 10, "air": 10, "earth": 10, "astral": 10},
    }
    (out_dir / "_entry.json").write_text(json.dumps(entry, indent=1, ensure_ascii=False) + "\n", encoding="utf-8")
    print("обновлён _entry.json")
    return 0


if __name__ == "__main__":
    sys.exit(main())