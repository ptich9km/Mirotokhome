#!/usr/bin/env python3
"""Генерация полосы анимации + ПРЕДПОЛЁТНАЯ проверка сырого PNG.

КОНВЕЙЕР (повторяемый, 4 шага):
  1. ПРАВИМ ПРОМТ, а не режем картинку. Проверка ниже меряет толщину фигуры,
     и модель обязана выдать её сама.
  2. Генерируем ОДНУ полосу, обычно `stand` — самая дешёвая проверка ракурса
     и телосложения, ~$0.06. Не все четыре полосы вслепую: покрытие ~$0.24.
  3. Смотрим превью и СРАЗУ гоняем preflight по тому же файлу:
       python tests/gen_hero_strip.py stand --check import/Player/hero_stand_nb5.png --panels 4
     Префлайт печатает толщину по каждой фигуре. Норма >= 0.36, городские NPC
     дают 0.48-0.59. Если ниже — ракурс или телосложение не те, правь промт.
  4. Только когда полоса прошла, генерируем остальные и собираем набор:
       python tests/extract_hero_nb.py

  Модель и цена: google/gemini-nano-banana-2.1, ~$0.054-0.061 за 1536x1024.
  Seedream дешевле, но теряет персонажа между вызовами; Flux блокируется
  модерацией. Подробности замеров — в AGENTS.md, журнал от 14.10.

Проблема, из-за которой полосы не резались (14.10): seedream рисует мягкую
тень ПОД фигурами, тень идёт полосой через весь кадр и склеивает соседей в
одну компоненту — вырезка физически не может их разделить. Плюс фигуры жмутся
друг к другу. Поэтому:
  - промт запрещает тень, пол и линию пола ЖЁСТКО;
  - после генерации кадр проверяется замером ПРОВЕРКА ИДЁТ ДО ПОКАЗА ЧЕЛОВЕКУ:
    тень под фигурами, число фигур, зазоры, линия ног, однотонность фона,
    ТОЛЩИНА ФИГУРЫ.

Запуск:
  python tests/gen_hero_strip.py stand --panels 4
  python tests/gen_hero_strip.py stand --check import/Player/hero_stand_v1.png --panels 4
"""
import argparse
import re
import sys
from collections import deque
from pathlib import Path

import numpy as np
from PIL import Image

REPO = Path(__file__).resolve().parent.parent
OUT_DIR = REPO / "import" / "Player"
# Поле от фигуры до края кадра, px. Меньше — кадр срезан по краю при нарезке.
EDGE_MIN = 3
MODEL = "google/gemini-nano-banana-2.1"
SIZE = "1536x1024"

CHARACTER = """ONE single character repeated in every panel: a broad-shouldered, sturdy adult
human warrior, light skin, short brown hair, short trimmed brown beard, no cape,
no helmet. He wears a rounded polished silver steel breastplate, small silver
shoulder pads, an olive-green knee-length tunic, a wide brown leather belt, brown
leather gauntlets, dark grey trousers and brown leather knee-high boots."""

# Женщина-войн. Снаряжение и палитра РОВНО мужские — набор должен читаться как
# та же армия, а не другой game (урок 14.10: «стиль не совпадает» оказалось
# ложной жалобой, но единый стиль всё равно дешевле проверять). Отличия только
# очевидные: длинные волосы, никакой бороды, женское телосложение.
#
# Толщина. Женская фигура по умолчанию выходит уже мужской, а норма preflight
# одна и та же (>= 0.36) — иначе она станет новой «жердью». Поэтому ширина
# задана явно и теми же словами, что и у мужчины, плюс отдельно запрещена
# слишком худая талия: у боина с мечом замеры были 0.48-0.59.
CHARACTER_F = """ONE single character repeated in every panel: a broad-shouldered, sturdy adult
human warrior WOMAN, light skin, long brown hair hanging loose over her shoulders
and down her back, no beard, no cape, no helmet. She wears the same rounded
polished silver steel breastplate, small silver shoulder pads, an olive-green
knee-length tunic, a wide brown leather belt, brown leather gauntlets, dark grey
trousers and brown leather knee-high boots."""

# Ракурс. Замер 14.10: «SIDE VIEW facing RIGHT» дал силуэт 0.24 ширины к высоте —
# фигура вчетверо ниже, чем широка, «жердь». Это не ошибка размера: профиль по
# определению самый узкий ракурс, видно только бок, оба плеча не читаются.
# Городские NPC дают 0.48-0.59, потому что развёрнуты к камере. Просим три
# четверти: оба плеча видны, но лицо, грудь и носки всё ещё смотрят вправо —
# иначе зеркало влево/вправо перестанет читаться в бою.
VIEW = ("THREE-QUARTER VIEW: the whole body is turned about 30 degrees towards the "
        "viewer, so BOTH shoulders, BOTH arms and the full width of the chest are "
        "visible, and the figure looks broad across its silhouette. He still clearly "
        "reads as facing RIGHT: the face, the chest and the toes point to the right "
        "and NOT towards the viewer.")

VIEW_F = ("THREE-QUARTER VIEW: the whole body is turned about 30 degrees towards the "
          "viewer, so BOTH shoulders, BOTH arms and the full width of the chest are "
          "visible, and the figure looks broad across its silhouette. She still "
          "clearly reads as facing RIGHT: the face, the chest and the toes point to "
          "the right and NOT towards the viewer.")

# Телосложение. Отдельным блоком, потому что слово «lean» в описании персонажа
# модель понимает буквально и рисует именно жердь — это была первая причина
# тонкой фигуры, ракурс её только усиливал.
PROPORTIONS = """BODY PROPORTIONS - this matters as much as the pose, the figure must NOT be a stick:
- broad-shouldered and solid, thick torso, sturdy heavy-set build
- the SHOULDERS are the widest part of his silhouette, clearly broader than his hips
- because both arms are visible from this angle, the body outline is roughly one
  third as wide as the figure is tall
- thick thighs and calves, solid boots, the torso is a filled shape with no gaps
- do NOT draw him slim, lean, thin, gaunt, lanky or stick-like"""

PROPORTIONS_F = """BODY PROPORTIONS - this matters as much as the pose, the figure must NOT be a stick:
- broad-shouldered and solid, thick torso, sturdy athletic build
- the SHOULDERS are the widest part of her silhouette, clearly broader than her hips
- the hips are NOT narrow: a slim waist under the breastplate, but the hip and
  thigh area stays as wide as the male figure's, this is an armoured soldier
- because both arms are visible from this angle, the body outline is roughly one
  third as wide as the figure is tall
- thick thighs and calves, solid boots, the torso is a filled shape with no gaps
- do NOT draw her slim, skinny, thin, gaunt, lanky, scrawny or stick-like"""

# --- Орк (15.10, игрок) -------------------------------------------------------
# Живёт по тому же контракту, что и человек: те же блоки, те же 4 фазы. Отличие
# в трёх вещах — кожа, клыки и снаряжение. Ракурс общий (VIEW): он про человека,
# а не про вид, и менять его для орка незачем.
CHARACTER_O = """ONE single character repeated in every panel: a broad-shouldered, sturdy adult
orc warrior, tall and heavily built, rough olive-green skin, a heavy brow ridge, deep
set glowing amber eyes, a broad flat nose, large curved white tusks coming up from
the lower jaw, thick black hair tied into a short rough tail, a scar across one
cheek. He wears a heavy dark iron chest plate riveted over a wide leather bandolier,
thick iron shoulder plates, a dark brown leather tunic and skirt, a wide brown
leather belt, brown leather bracers, dark brown trousers and heavy brown leather
boots."""

# Женский орк. Отдельный текст, а не femaleize() мужского: замена
# местоимений не даёт ни одной женской черты, и модель спокойно нарисовала
# мужчину (15.10) — та же стойка, тот же кирас, те же плечи. У человека
# женский вариант тоже отдельный блок CHARACTER_F, здесь ровно так же.
CHARACTER_O_F = """ONE single character repeated in every panel: a tall, powerfully built
adult orc warrior WOMAN, rough olive-green skin, a high cheekbone line, glowing
amber eyes without the heavy male brow ridge, a slightly upturned broad nose, and
large curved white tusks coming up from her lower jaw. Her long dark brown hair
falls in TWO long thick braids down past her shoulders, and she has a small
swept-back ponytail. She wears a fitted dark iron breastplate with a V-shaped
neckline that shows her collarbones and neck, strapped over a dark brown leather
tunic laced down the front, thin iron shoulder caps rather than heavy pauldrons,
a narrow belt low on her hips, brown leather bracers, dark trousers tucked into
brown leather boots."""
# отдельные блоки означали бы вторую копию правил, которая со временем разъедется
# с первой. Исключение — пропорции: у орка оба пола коренастые, поэтому
# женские «стройные бёдра» из PROPORTIONS_F здесь не применяются.
# --- Нежить-воин, Пожинатели (20.10, игрок) ----------------------------------
# Тот же контракт, что человек/орк: PROPORTIONS и VIEW общие (про телосложение
# и ракурс, не про вид). Уточнение игрока 20.10: в промте обязательно слово
# «sprite sheet», мелкие детали, ремни-полосы-ленты запрещены — они мельчат
# на 64px холсте и рвут силуэт при вырезке.
CHARACTER_U = """ONE single character repeated in every panel of this SPRITE SHEET for a 2D
video game: a tall, powerfully built UNDEAD SKELETON WARRIOR of the Harvesters
faction, thick heavy bones, bare bone-white skull with deep dark eye sockets and
a faint green glow deep in the eyes, exposed bone-white ribcage, spine, arms and
legs, no flesh, no hair, no rotting tissue, no exposed organs. THE ARMS AND LEGS
ARE BARE BONES: thin straight white twin bones (radius and ulna, tibia and fibula)
with round bone joints, like a Halloween skeleton, NOT muscular, NOT fleshy, NO
muscle mass, NO skin on the limbs. He wears a battered
dark rusted iron chest plate worn over the ribcage, heavy dark rusted iron
compact small shoulder plates that sit close to the body and are NOT wider than
the shoulders themselves, a plain black leather belt, plain dark iron bracers,
dark grey cloth wrappings on the shins and plain blackened iron boots. NO straps,
NO belts crossing the chest, NO hanging cloth, NO ribbons, NO small details.
SIZE: draw the skeleton figure SMALL and COMPACT, at most 15 percent of the image
width, with very wide empty background margins on both sides of every figure."""

# --- Друид-воин, Круг Друидов (20.10, игрок) ----------------------------------
# Человекоподобный воин друидов. Рога и капюшон намеренно запрещены: торчащие
# элементы срезаются краем кадра и ломают линию ног при нарезке.
PROPORTIONS_U = """BODY PROPORTIONS - this matters as much as the pose, the figure must NOT be a stick:
- tall and powerfully built SKELETON: broad bony shoulder blades and pelvis make the
  silhouette wide, the ribcage is a big filled bony barrel with no gaps
- the SHOULDERS are the widest part of the silhouette, clearly broader than the hips
- the limbs are BARE THIN BONES, not muscular: thin straight twin bones with round
  joints, but they are drawn long and heavy enough to read at small size
- because both arms are visible from this angle, the body outline is roughly one
  third as wide as the figure is tall
- do NOT draw him slim, weak, skinny, gaunt, lanky or stick-like"""

# --- Нежить-воительница, Пожинатели (20.10) -----------------------------------
# НЕ скелет: у скелета пол не читается, и женский набор стал бы копией un1.
# Канон — портрет выбора героя necro_f_war: бледная мёртвая женщина с тёмными
# волосами. Броня та же, что у un1 (ржавая кираса Пожинателей), чтобы набор
# читался той же армией. Юбка короткая рваная (до колена): длинная юбка
# портрета в walk/attack прячет ноги, шаг и удар не читаются.
CHARACTER_U_F = """ONE single character repeated in every panel of this SPRITE SHEET for a 2D
video game: a sturdy adult UNDEAD WOMAN warrior of the Harvesters faction, pale
grey-white dead skin, long straight black hair falling loose down her back, dark
sunken eyes with a faint green glow deep in them, a calm dead face. The body is
whole and feminine, NOT a skeleton: no bare bones, no skull, no ribcage, no
rotting tissue, no wounds, no exposed organs. She wears a battered dark rusted
iron chest plate, heavy dark rusted iron compact small shoulder plates that sit
close to the body and are NOT wider than the shoulders themselves, a plain black
leather belt, plain dark iron bracers, a short tattered dark grey cloth kilt down
to the knees over dark grey cloth wrappings on the shins, and plain blackened
iron boots. NO straps, NO belts crossing the chest, NO hanging cloth, NO ribbons,
NO small details.
SIZE: draw the figure SMALL and COMPACT, at most 15 percent of the image
width, with very wide empty background margins on both sides of every figure."""

CHARACTER_D = """ONE single character repeated in every panel of this SPRITE SHEET for a 2D
video game: a broad-shouldered, sturdy adult human DRUID WARRIOR of the Circle
of Druids faction, tanned weathered skin, long thick grey-brown hair and a full
grey-brown beard, no hood, no cape, no helmet, no antlers. He wears a bark-brown
hardened leather chest plate overlaid with large smooth green leaves and plain
wooden plates, a thick woven rope belt, fur-lined green shoulder wraps, plain
brown leather bracers, dark green trousers and rough brown leather boots. NO
straps, NO hanging vines or ribbons, NO small twigs, beads or tiny details."""

# --- Друидка-воин, Круг Друидов (20.10) ---------------------------------------
# Тот же контракт «та же армия»: снаряжение РОВНО мужское dr1 (дублёная кожа,
# листья, верёвочный пояс, штаны, сапоги), отличия — тело и длинные волосы.
# Длинное платье с портрета druid_f_war не годится: в walk/attack не видны ноги.
# Волосы — как на портрете, рыжие.
CHARACTER_D_F = """ONE single character repeated in every panel of this SPRITE SHEET for a 2D
video game: a broad-shouldered, sturdy adult human DRUID WARRIOR WOMAN of the
Circle of Druids faction, tanned weathered skin, long thick auburn-red hair
falling loose over her shoulders and down her back, no beard, no hood, no cape,
no helmet, no antlers. She wears the same bark-brown hardened leather chest plate
overlaid with large smooth green leaves and plain wooden plates, a thick woven
rope belt, fur-lined green shoulder wraps, plain brown leather bracers, dark
green trousers and rough brown leather boots. NO straps, NO hanging vines or
ribbons, NO small twigs, beads or tiny details."""

PROPORTIONS_O = """BODY PROPORTIONS - this matters as much as the pose, the figure must NOT be a stick:
- tall and powerfully built, thick heavy torso, huge shoulders and back
- the SHOULDERS are the widest part of his silhouette, clearly broader than his hips
- long heavy arms with thick forearms, large square hands
- thick thighs and calves, solid boots, the torso is a filled shape with no gaps
- do NOT draw him slim, lean, thin, gaunt, lanky or stick-like"""

# --- Маги всех 4 рас (21.10, игрок) -------------------------------------------
# Урок 21.10 (~300 руб): свои формулировки уводили модель в реализм. Правило:
# блок персонажа = воинский ДОСЛОВНО до блока одежды, меняется ТОЛЬКО одежда —
# одна длинная мантия до земли (ноги скрыты, «не так будет видно косяки
# с ногами»), минимум мелких деталей. Пропорции — воинские алиасы.
# ЗАПОМНИ: боевые полосы всегда --panels 4 (дефолт 8 кладёт «2 ряда по 6»,
# инцидент hm1); генерация — только с одобрения игрока, по 1 попытке.
# Полная памятка: .kodik/memories/hero-strip-generation-standard.md.

def _mage_robe(color):
    return (f"ONE single full-length plain {color} MAGE ROBE instead of armor, "
            "hanging loose ALL THE WAY DOWN TO THE GROUND, the hem resting on the "
            "floor: the legs are COMPLETELY HIDDEN under the hem, no trousers and "
            "no boots visible. Simple wide sleeves, plain sturdy cloth. NO armor "
            "plates, NO belts, NO straps, NO ribbons, NO hanging cloth, NO small "
            "details. A simple plain wooden staff, ONE staff only.")

CHARACTER_M = CHARACTER.split("He wears")[0] + "He wears " + _mage_robe("deep blue")
CHARACTER_M_F = CHARACTER_F.split("She wears")[0] + "She wears " + _mage_robe("deep blue")
CHARACTER_OM = CHARACTER_O.split("He wears")[0] + "He wears " + _mage_robe("deep red")
CHARACTER_OM_F = CHARACTER_O_F.split("She wears")[0] + "She wears " + _mage_robe("deep red")
CHARACTER_UM = CHARACTER_U.split("He wears")[0] + "He wears " + _mage_robe("violet")
CHARACTER_UM_F = CHARACTER_U_F.split("She wears")[0] + "She wears " + _mage_robe("violet")
CHARACTER_DM = CHARACTER_D.split("He wears")[0] + "He wears " + _mage_robe("moss-green")
CHARACTER_DM_F = CHARACTER_D_F.split("She wears")[0] + "She wears " + _mage_robe("moss-green")

# Путник (11.11): мирный НПЦ, которого спасают. Тело по контракту воина (жердь
# валит preflight), но снаряжение гражданское и руки пустые. Блок attack
# генерируется только потому, что контракт геройских наборов — 12 кадров
# (1+4+3+4) и ломать его ради одной фазы нельзя; путник не атакует никогда.
CHARACTER_T = """ONE single character repeated in every panel: a sturdy adult human
traveller, weathered tanned skin, short brown hair, short brown beard, no helmet,
no cape over the head. He wears a coarse brown wool tunic reaching to the middle of
his calves, a plain grey travelling cloak thrown back over his shoulders and
hanging OPEN and WIDE from his shoulders (it is NOT wrapped around the body and
does NOT hide the arms), a wide
brown leather belt with a small pouch, a canvas satchel hanging on a strap across
his chest, dark grey trousers and worn brown leather knee-high boots.
He holds NO weapon, NO staff and NO shield: both hands are EMPTY."""

# Пропорции магов: воинская база, но вычеркнуты строки про бёдра/сапоги —
# они конфликтуют с «ноги скрыты под мантией»: модель переливает массу в
# торс (жирный + грудь) и занижает рост (лилипут). Диагноз по om1, 21.10.
_BASE_STRIPS = ("thick thighs and calves, solid boots, ",
                "thick thighs and calves, solid boots\n")

def _mage_props(base: str) -> str:
    s = base
    for strip in _BASE_STRIPS:
        s = s.replace(strip, "")
    s += ("- the figure is TALL: the robe hangs straight down from the shoulders "
          "and the total height reads as a tall warrior, NOT a short squat figure\n"
          "- the chest stays flat under the robe, no breast bulge, no fat torso\n"
          "- do NOT draw the figure fat, chubby, bloated or top-heavy")
    return s

PROPORTIONS_M = _mage_props(PROPORTIONS)
PROPORTIONS_M_F = _mage_props(PROPORTIONS_F)

ANIMS = {
    "walk": """WALKING CYCLE, 8 panels left to right in one horizontal row.
The legs alternate between a WIDE stride and a NARROW passing pose:
panels 1 and 5 are the wide stride with the legs far apart,
panels 3 and 7 are the narrow passing pose with the feet almost touching.
All 8 panels are DIFFERENT leg positions of one calm walking step.
He is drawn walking, torso upright, arms swinging
gently and kept close to the body. He does not run and does not lunge.""",

    "stand": """IDLE STANCE, 8 panels left to right in one horizontal row. He stands still,
feet hip width, arms relaxed at his sides, only a subtle breathing difference
between panels.""",

    "attack": """FIST PUNCH, 8 panels left to right in one horizontal row.
Panel 1 guard stance with both fists up, panel 2 right fist cocked back,
panel 3 driving forward, panel 4 arm fully extended straight ahead,
panel 5 still extended, panel 6 retracting, panel 7 guard returning,
panel 8 guard stance, feet planted, no weapon.""",

    "die": """DEATH BY A BLOW TO THE CHEST, 8 panels left to right in one horizontal row.
Panel 1 standing upright with both arms flung wide open to the sides,
panel 2 sinking down with knees bent and arms still wide,
panel 3 sitting on the ground leaning back on his hands,
panel 4 falling backwards, panel 5 lying on his back on the ground,
panels 6, 7, 8 lying flat on his back face up, still. He NEVER lies face down.
""",
}

LAYOUT4 = """PURPOSE, read this first: you are drawing ONE SPRITESHEET STRIP FOR A 2D VIDEO
GAME. Every panel is a SEPARATE ANIMATION FRAME of the same figure, the game
will cut this image apart and play the panels one after another as an animation.
So the panels must be like frames on a film strip: each panel is ONE whole
complete figure in ONE clean pose, standing on its own, with nothing of the
neighbouring panels bleeding into it.

NEVER smear, merge or blend the phases. BANNED between and inside the panels:
ghosting, double images, motion blur, a semi-transparent second figure, a pose
trailing off into the next panel, or two panels sharing a limb. If two poses
share a shape, the NEXT panel must still show a full separate figure.

COUNT IS LAW: draw EXACTLY 4 figures in the whole image. Never 5, never 7.
Do not draw the same sequence twice, do not repeat a panel, and do not add an
extra panel at the end to finish the motion. When the fourth figure is drawn,
STOP. There is NO second row and NO second strip: the whole area below the
figures stays empty background. (Measured 16.10: a strip was answered with
SEVEN figures in two rows - a three-step fall on top and a four-step fall
below - which cannot be cut into a 4-frame animation at all.)

SIZE IS LAW TOO - DO THE ARITHMETIC BEFORE YOU DRAW:
All four figures have to stand next to each other in ONE row, so each one may
take at most ONE QUARTER of the image width. Keep every figure at most 22
percent of the image WIDTH and at most 60 percent of the image HEIGHT.
If the creature is naturally WIDER than it is tall - a spectre, a cloud, a
smoke column, anything spreading sideways - you must draw it MUCH smaller, so
that four of them still fit side by side. A figure drawn too wide does not
overlap its neighbours in a row: the model then spills it into a second row,
which the game cannot cut apart.

LAYOUT RULES:
- exactly 4 separate figures in a single horizontal row, evenly spaced
- one horizontal row only, all four on ONE ground line, none above another
- empty gaps of pure background between the figures, at least 80 pixels from
  the right edge of one figure to the left edge of the next one; nothing of any
  kind may pass through those gaps
- every figure the same size, full body, nothing cropped
- EVERY figure keeps a strip of clear empty background on ALL FOUR sides -
  above it, below it, left of it, right of it - at least 30 pixels on each
  side. NOTHING may touch or cross the border of the image. A figure that runs
  into the edge of the picture will be cut in half by the game, so this is a
  hard error, not a style choice.

ABSOLUTELY NO GROUND SHADOW, no cast shadow, no dark blur under the feet, no
floor, no ground plane, no horizontal line, no surface, no reflection. The area
under and around every figure must be the same flat background as the rest of
the image.

Background: one single flat vivid magenta (255, 0, 255), perfectly uniform.
EXCLUDE: text, letters, numbers, captions, grid lines, borders, weapons,
scenery, signature, watermark, duplicate figures."""

# 4 панели: 8 фигур на 1536px физически не помещаются — фигуры ~190px шириной
# наезжают друг на друга, и резать полосу нечем (замер 14.10: в промежутках
# удара 15-72px чужой руки, в промежутках смерти до 234px).
ANIMS4 = {
    "stand": """AN IDLE STANCE, 4 panels left to right in one row.
Panel 1: standing still, feet about hip width apart, both arms hanging relaxed
at his sides, shoulders level, calm neutral face.
Panels 2, 3 and 4: the exact same standing pose with only a tiny breathing
difference in the rise of his chest. He does not move his feet at all.
""",

    "die": """A FALL TO THE GROUND, 4 panels left to right in one row.
Panel 1: standing upright, both arms flung wide open to the sides.
Panel 2: his knees buckle, he drops downwards, the torso already tilted, one hand
reaching for the ground.
Panel 3: he has fallen over onto the ground, the body turned down onto its side,
torso already low and nearly horizontal, one arm stretched out.
Panel 4: LYING ON THE GROUND ON HIS BACK, face and chest pointing up, but the body
is drawn TILTED AND COMPACT: knees slightly bent, arms relaxed on the ground, the
whole fallen figure fits inside its own quarter of the image width. Do NOT draw
the fallen body stretched out horizontally across a wide area.
He NEVER lies face down.
BANNED in panels 3 and 4: sitting upright, squatting, kneeling upright, resting on
the hands behind the back, legs dangling down, a compact round shape. A SEATED
figure is WRONG - he has to end up lying on the ground.
SPACING: all four figures stay in their own equal quarters of the image width, so
wide bands of empty background remain between every pair of neighbouring panels,
including between panel 3 and panel 4.""",

    "attack": """A FIST PUNCH, 4 panels left to right in one row.
Panel 1: guard stance, both fists up in front of his chest.
Panel 2: right fist cocked back beside his shoulder.
Panel 3: right arm driving forward, fist half way out, elbow stays close to the body.
Panel 4: right arm fully extended straight AHEAD at shoulder height, fist closed;
the extended arm stays within the width of his own shoulders, it does NOT reach
sideways into the next panel and does NOT touch or overlap the neighbouring figure.
Feet planted, no weapon. """,

    "walk": """A WALKING CYCLE, 4 panels left to right in one row, calm even walking pace.
Panel 1 CONTACT: the front heel just touched the ground, the back leg is stretched
far behind, legs at their widest apart, body upright, spine perfectly straight.
Panel 2 DOWN: his weight rolls onto the front leg, the back leg is still stretched
behind pushing off. This is ONLY the small natural dip of a normal walking step:
the front knee bends very slightly, the body drops just a few pixels lower than in
panel 1. His legs stay STRAIGHT and nearly extended, the SPINE STAYS PERFECTLY
UPRIGHT and straight - he does NOT crouch, does NOT bend forward at the waist,
does NOT squat, does NOT kneel, does NOT bend his knees deeply and is NOT running.
The figure in panel 2 is the SAME SIZE as in all other panels.
Panel 3 PASSING: the back foot swings forward and steps right up beside the front
foot, the legs are TOGETHER, feet almost touching, his body at its highest and
tallest, spine straight. This panel is the NARROWEST of the four - the two legs
almost overlap each other and the whole silhouette is slim, clearly narrower than
panel 1.
Panel 4 PUSH OFF: he rises onto the toes of the back foot, the back leg trailing
at an angle, the front leg starting to reach forward, body rising. The legs are
only slightly apart here, a normal stride width.
The 4 panels must show 4 clearly different leg positions, each about a quarter of
a step apart.
BANNED in panels 3 and 4: legs spread very wide apart, a deep side lunge, a horse
stance, a wide straddle, a squat. Panels 3 and 4 are the NARROW panels; only panel
1 and 2 show the legs wide apart.
SPACING: all four figures stay in their own equal quarters of the image width, so
wide bands of empty background remain between every pair of neighbouring panels.""",
}

# 21.10: mage attack — the only weapon is a staff, so the attack is a simple
# staff raise/lower, nothing else. Player correction: the staff is NOT cocked
# back behind the head and NOT swung overhead — just lifted up and lowered.
ANIMS4_MAGE = {
    "attack": """A SLOW STAFF LIFT: raising the staff straight up in FRONT of the
body and then lowering it back down, 4 panels left to right in one row.
Panel 1: standing still, the staff held vertically at the side, one hand gripping
it at waist height, staff tip pointing up.
Panel 2: the same single hand has lifted the staff a little way up, the staff now
held vertically in front of the body at about chest height. The OTHER hand is
NOT holding a second staff - there is only ONE staff in the whole image and it
is gripped by ONLY ONE hand in every panel. The body posture in this panel is
exactly the same upright relaxed stance as in panel 1 - the spine is NOT
stretched, NOT elongated, NOT straightened upward, the figure does NOT grow
taller, legs stay bent and relaxed the same way.
Panel 3: the hand has lifted the staff straight up in front of the body, the arm
extended upward but still IN FRONT of the figure, the staff vertical beside the
shoulder, NOT behind the head, NOT cocked back, NOT swung sideways.
Panel 4: the hand has lowered the staff back down to the starting position at the
side, exactly like panel 1.
This is ONLY a calm vertical lift-and-lower motion of one arm holding the staff.
Nothing else moves: feet stay planted in the same place, body stays upright, no
punch, no throw, no lunge, no swing, no spin. The staff is NOT thrown or dropped.
The staff is NEVER held behind the head or behind the back.
SAME HAND IS LAW: the staff is held in the SAME single hand in ALL FOUR panels.
The hand NEVER switches, NEVER swaps from left to right or right to left between
panels. One hand holds the staff from the first panel to the last.
SPACING: all four figures stay in their own equal quarters of the image width, so
wide bands of empty background remain between every pair of neighbouring panels.
The raised arm and staff stay within the width of the figure's own shoulders and
do NOT touch or overlap the neighbouring figure. All four figures stand on ONE
ground line in ONE horizontal row.""",
}

LAYOUT = """PURPOSE, read this first: you are drawing ONE SPRITESHEET STRIP FOR A 2D VIDEO
GAME. Every panel is a SEPARATE ANIMATION FRAME of the same character, the game
will cut this image apart and play the panels one after another as an animation.
So the panels must be like frames on a film strip: each panel is ONE whole
complete character in ONE clean pose, standing on its own, with nothing of the
neighbouring panels bleeding into it.

NEVER smear, merge or blend the phases. BANNED between and inside the panels:
ghosting, double images, motion blur, a semi-transparent second figure, a pose
trailing off into the next panel, or two panels sharing a limb. If two poses
share a shape, the NEXT panel must still show a full separate figure.

LAYOUT RULES, these matter more than the drawing:
- exactly 8 separate figures in a single horizontal row, evenly spaced
- each figure is SMALL: at most 22 percent of the image WIDTH and at most 60
  percent of the image HEIGHT, so that 8 figures really fit into one row
- HUGE empty gaps of pure background between the figures, at least 60 pixels of
  completely empty background between the right edge of one figure and the left
  edge of the next one; nothing of any kind may pass through those gaps
- every figure the same size, feet on the same horizontal line, full body from
  head to boots inside its own space, nothing cropped
- TWO ROWS IS A HARD ERROR: all 8 figures stand on ONE single horizontal line
- EVERY figure keeps a strip of clear empty background on ALL FOUR sides -
  above the head, below the boots, left of the arm, right of the arm - at least
  30 pixels on each side. NOTHING may touch or cross the border of the image.
  A figure that runs into the edge of the picture will be cut in half by the
  game, so this is a hard error, not a style choice.

ABSOLUTELY NO GROUND SHADOW, no cast shadow, no dark blur under the boots, no
floor, no ground plane, no horizontal line, no surface, no reflection. The area
under and around every figure must be the same flat background as the rest of
the image.

Background: one single flat vivid magenta (255, 0, 255), perfectly uniform.
EXCLUDE: text, letters, numbers, captions, grid lines, borders, weapons,
scenery, signature, watermark, duplicate figures."""


def normalize_bg(path, tol=60):
    """Перекраска фона в точную мадженту (21.10, mai-image-2.6-flash).

    mai-image рисует отличный согласованный лист, но фон отдаёт розовым
    (не чистая 255,0,255) — preflight его не распознаёт. Flood-fill от
    краёв по цветовой близости к доминирующему цвету фона -> точная
    маджента. Осознанный детерминированный preprocessing, прецедент —
    LANCZOS/BICUBIC в gen_loot_icons_derived.py. Затрагивает только
    связанный с краями фон: фигуры и зазоры внутри не трогаются.
    """
    from collections import deque
    a = np.array(Image.open(path).convert("RGB"))
    h, w = a.shape[:2]
    # доминирующий цвет: мода по 4 угловым пятнам 40x40
    corners = np.concatenate([a[:40, :40].reshape(-1, 3), a[:40, -40:].reshape(-1, 3),
                              a[-40:, :40].reshape(-1, 3), a[-40:, -40:].reshape(-1, 3)])
    bg = np.median(corners, axis=0)
    diff = np.abs(a.astype(np.int32) - bg.astype(np.int32)).max(axis=2)
    mask = diff <= tol
    seen = np.zeros((h, w), bool)
    dq = deque()
    for x in range(w):
        for y in (0, h - 1):
            if mask[y, x] and not seen[y, x]:
                seen[y, x] = True
                dq.append((y, x))
    for y in range(h):
        for x in (0, w - 1):
            if mask[y, x] and not seen[y, x]:
                seen[y, x] = True
                dq.append((y, x))
    while dq:
        y, x = dq.popleft()
        for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            ny, nx = y + dy, x + dx
            if 0 <= ny < h and 0 <= nx < w and mask[ny, nx] and not seen[ny, nx]:
                seen[ny, nx] = True
                dq.append((ny, nx))
    a[seen] = (255, 0, 255)
    Image.fromarray(a).save(path)
    return int(seen.sum())


def magenta_mask(a):
    # Чистая мажента (255,0,255): каналы R и B РАВНЫ, поэтому условие вида
    # r-b > 8 её не берёт (ошибка 14.10: «фон 1%» на заведомо мажентной
    # картинке). Признак фона — низкий зелёный канал при высоких R и B.
    r, g, b = a[..., 0], a[..., 1], a[..., 2]
    return (g < 110) & (r > 140) & (b > 140) & ((r - g) > 50)


def components(alpha, keep_ratio=0.18):
    """Связные компоненты всей фигуры целиком — так персонаж считается напрямую.

    Колонночные прогоны не работают: у соседних фигур хвост/рука/крыло
    соприкасаются, прогоны сливаются, и порог «шире медианы» не срабатывает
    никогда — медиана тоже посчитана по слипшимся кускам. Замер 15.10: полоса
    ходьбы орка дала ОДИН прогон шириной 2490px на четыре фигуры.
    """
    m = alpha > 0.35
    h, w = m.shape
    lab = np.zeros((h, w), np.int32)
    cur = 0
    for y in range(h):
        for x in range(w):
            if not m[y, x] or lab[y, x]:
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
    if cur == 0:
        return []
    areas = np.bincount(lab.ravel(), minlength=cur + 1)
    areas[0] = 0
    boxes = []
    for i in range(1, cur + 1):
        if areas[i] < areas.max() * keep_ratio:
            continue
        ys, xs = np.where(lab == i)
        boxes.append((int(ys.min()), int(ys.max()), int(xs.min()), int(xs.max())))
    boxes.sort(key=lambda b: (b[0], b[2]))
    return boxes


def preflight(path, expect=8, min_gap=60, feet_tol=14, min_ratio=0.36,
              edge_min_min=EDGE_MIN, torso=False, min_figure_h=0):
    """Проверка СЫРОГО png. Возвращает (ok, строки отчёта).

    min_figure_h: прогоны ниже этой высоты не считаются фигурами. Мелкие
    полосы (трава, мелкие предметы) приходят с пылью в 1-8 px, и раньше
    каждая пылинка ломала счёт «фигур: 6 вместо 4» (травы 11.11). У героя
    порог 0 — поведение прежнее.
    """
    a = np.array(Image.open(path).convert("RGB")).astype(np.int32)
    bgm = magenta_mask(a)
    fg = ~bgm
    h, w = fg.shape
    rep = []

    # 1. однотонность фона: разброс ВНУТРИ каждого канала по фоновым пикселям.
    # Раньше брался максимум канала по всем пикселям — у магенты (255,0,255)
    # это всегда даёт большое sd, даже когда фон идеально ровный (ошибка 14.10).
    bg_pixels = a[bgm]
    if bg_pixels.size:
        per_ch = bg_pixels.std(axis=0)
        bg_spread = int(per_ch.max())
    else:
        per_ch = np.zeros(3)
        bg_spread = 999
    rep.append(f"фон: {bgm.mean() * 100:.0f}% кадра, разброс внутри канала sd={bg_spread}")
    ok_bg = bg_pixels.size > 0 and bg_spread < 26

    # 2. фигуры: связные колонки с зазором
    cols = fg.sum(axis=0)
    active = cols >= 3
    runs, start = [], -1
    for x, v in enumerate(active):
        if v and start < 0:
            start = x
        elif not v and start >= 0:
            runs.append((start, x - 1))
            start = -1
    if start >= 0:
        runs.append((start, w - 1))
    dropped = 0
    if min_figure_h > 0:
        kept = []
        for x0, x1 in runs:
            ys, _ = np.where(fg[:, x0:x1 + 1])
            if ys.size and int(ys.max() - ys.min() + 1) >= min_figure_h:
                kept.append((x0, x1))
        dropped = len(runs) - len(kept)
        runs = kept
    gaps = [runs[i + 1][0] - runs[i][1] - 1 for i in range(len(runs) - 1)]
    rep.append(f"фигур: {len(runs)}, зазоры: {gaps if gaps else '-'}"
               + (f", пятен-мусора отброшено {dropped}" if min_figure_h else ""))
    ok_figs = len(runs) == expect
    ok_gaps = (not gaps) or min(gaps) >= min_gap

    # 3. тень под фигурами: тёмные пиксели ПОД нижним краем фигуры
    shadow_max = 0
    for x0, x1 in runs:
        ys, _ = np.where(fg[:, x0:x1 + 1])
        if ys.size == 0:
            continue
        feet = int(ys.max())
        band = a[feet + 3:feet + 26, x0:x1 + 1]
        if band.size == 0:
            continue
        dark = (band[:, :, 0] < 140) & (band[:, :, 1] < 110)
        frac = float(dark.sum()) / max(1, dark.size)
        shadow_max = max(shadow_max, frac)
    rep.append(f"тень под фигурами: худшая полоса {shadow_max * 100:.0f}% тёмных пикселей")
    ok_shadow = shadow_max < 0.06

    # 4. линия ног
    feet_y = []
    for x0, x1 in runs:
        ys, _ = np.where(fg[:, x0:x1 + 1])
        if ys.size:
            feet_y.append(int(ys.max()))
    spread = (max(feet_y) - min(feet_y)) if feet_y else 999
    rep.append(f"линия ног: разброс {spread}px по {len(feet_y)} фигурам")
    ok_feet = spread <= feet_tol

    # 4b. КРАЙ КАДРА. Фигура, упирающаяся в край, будет срезана по нему при
    # нарезке — это проходило зелёным дважды: у орка 12-й кадр упирался в
    # левый край, у орк-женщины в полосе смерти панели 1 и 4 стояли вплотную
    # к левому и правому краю (поля L=0 и R=0). Ни одна из шести проверок
    # выше на это не смотрит: зазоры меряются МЕЖДУ фигурами, а не до края.
    pads = []
    for x0, x1 in runs:
        ys, _ = np.where(fg[:, x0:x1 + 1])
        if ys.size == 0:
            continue
        pads.append((x0, int(ys.min()), w - 1 - x1, h - 1 - int(ys.max())))
    edge_min = min(min(p) for p in pads) if pads else 0
    rep.append(f"поле до края кадра: худшее {edge_min}px (норма >= {edge_min_min})")
    ok_edge = bool(pads) and edge_min >= edge_min_min

    # 5. ТОЛЩИНА ФИГУРЫ. Этой проверки не было 14.10, и это ровно тот класс,
    # что уже ловил проект дважды: метрика, которая не измеряет главное.
    # Полоса пришла с отношением ширины к высоте 0.24 — фигура в 4 раза
    # ниже, чем широка, «жердь». Проверка зазоров и тени её не видели: фигура
    # была корректной, просто неверного телосложения. Городские NPC дают
    # 0.48-0.59 (замер tests/hero_size_probe.gd), поэтому 0.36 - нижняя
    # граница нормы, а не произвольное число.
    ratios = []
    for x0, x1 in runs:
        sub = fg[:, x0:x1 + 1]
        ys, xs = np.where(sub)
        if ys.size == 0:
            continue
        if torso:
            # Mage-режим: мантия к подолу сужается, полная метрика занижена
            # и даёт ложную «жердь» (потеряно при откате, восстановлено
            # 21.10). Меряем корпус — верхние 55% высоты фигуры.
            top = int(ys.min())
            cut = top + int((ys.max() - top) * 0.55)
            band = sub[:cut + 1, :]
            tys, txs = np.where(band)
            if tys.size:
                ys, xs = tys, txs
        cw = int(xs.max() - xs.min() + 1)
        ch = int(ys.max() - ys.min() + 1) if not torso else int(
            (ys.max() - ys.min() + 1) / 0.55)
        ratios.append((cw, ch, cw / max(1, ch)))
    worst = min((r[2] for r in ratios), default=0.0)
    detail = " ".join(f"{r[2]:.2f}" for r in ratios) if ratios else "-"
    rep.append(f"толщина: ширина/высота по фигурам {detail} (худшая {worst:.2f}, "
               f"норма >= {min_ratio:.2f})")
    ok_ratio = bool(ratios) and worst >= min_ratio

    ok = ok_bg and ok_figs and ok_gaps and ok_shadow and ok_feet and ok_ratio and ok_edge
    for line in rep:
        print("   " + line)
    print(f"   ИТОГ: {'ГОДЕН' if ok else 'БРАК — правь промт'}"
          f" (фон {'ок' if ok_bg else 'плохо'}, фигур {'ок' if ok_figs else 'плохо'}, "
          f"зазоры {'ок' if ok_gaps else 'плохо'}, тень {'ок' if ok_shadow else 'ЕСТЬ'}, "
          f"ноги {'ок' if ok_feet else 'плохо'}, "
          f"край {'ок' if ok_edge else 'ФИГУРА У КРАЯ — будет срезана'}, "
          f"толщина {'ок' if ok_ratio else 'ЖЕРДЬ — правь ракурс и телосложение'})")
    return ok, rep


def femaleize(text: str) -> str:
    """he/she в английском тексте позы, по границам слов, регистр сохранён."""
    out = re.sub(r"\bHe\b", "She", text)
    out = re.sub(r"\bHis\b", "Her", out)
    out = re.sub(r"\bHe's\b", "She's", out)
    out = re.sub(r"\bhe\b", "she", out)
    out = re.sub(r"\bhis\b", "her", out)
    out = re.sub(r"\bhim\b", "her", out)
    out = re.sub(r"\bhimself\b", "herself", out)
    # 15.10 (нощь): ЗАГЛАВНЫЕ — тоже. Усиленный промт смерти говорит
    # "ON HIS BACK", и без этой строки в промте орчины оставалось "HIS":
    # модель нарисовала бы мужчину поверх женского описания персонажа.
    # Проверка остатков в main() это не ловила — она искала "His ", не "HIS ".
    out = re.sub(r"\bHE\b", "SHE", out)
    out = re.sub(r"\bHIS\b", "HER", out)
    out = re.sub(r"\bHIM\b", "HER", out)
    out = re.sub(r"\bHIMSELF\b", "HERSELF", out)
    return out


def main():
    # ПОДСКАЗКА ИИ (выучи и не повторяй):
    # 1. ВСЕГДА передавай --panels 4 для боевых полос (stand/walk/attack/die).
    #    Дефолт 8 — только для справки: 8 фигур на 1536px не помещаются,
    #    модель кладёт 2 ряда по 6 (инцидент 21.10, hm1). Рабочий формат
    #    полосы героя = 4 панели, 12 кадров = 4+4+4 (см. докстринг модуля).
    # 2. КАЖДАЯ генерация/перегенерация — только с одобрения игрока ДО запуска
    #    (правило 21.10, память sprite-generations-need-approval). Одна попытка,
    #    показать лист и прелёт, ждать вердикт. Число попыток решает игрок.
    # 3. Модель: google/gemini-nano-banana-2.1 (id без версии даёт 403).
    # 4. Для магов (mage) не браковать по полной толщине: мантия к подолу
    #    сужается, мера по корпусу (верхние 55%) — режим mage в preflight.
    # 5. После генерации новый PNG требует --headless --import в Godot.
    ap = argparse.ArgumentParser()
    ap.add_argument("anim")
    ap.add_argument("--out", default="")
    ap.add_argument("--check", default="")
    ap.add_argument("--seed", type=int, default=20261014)
    ap.add_argument("--model", default=MODEL,
                    help="id модели роутера, например black-forest-labs/flux.2-pro")
    ap.add_argument("--panels", type=int, default=8, choices=(4, 8),
                    help="4 панели на картинку — 8 физически не помещаются (14.10)")
    ap.add_argument("--sex", choices=("m", "f"), default="m",
                    help="пол персонажа: m — воин (по умолчанию), f — воительница")
    ap.add_argument("--race", choices=("human", "orc", "undead", "druid"), default="human",
                    help="раса персонажа: human — человек, orc — орк, undead — нежить "
                         "(Пожинатели), druid — друид (Круг Друидов)")
    ap.add_argument("--tag", default="",
                    help="суффикс имени файла, например nb6. По умолчанию — "
                         "тег выбранного пола")
    ap.add_argument("--class", dest="hero_class",
                    choices=("warrior", "mage", "traveler"),
                    default="warrior",
                    help="класс героя: mage — мантия до земли (21.10), traveler — "
                         "мирный путник в гражданской одежде без оружия (11.11)")
    args = ap.parse_args()

    # Норма толщины зависит от пола. Калибровка 20.10 по ОДОБРЕННЫМ игроком
    # наборам: мужчины 0.39–0.48 (dr1 0.39, un1 0.48), женщины 0.32–0.34
    # (nb6 0.32, oc2 0.34, un2 0.33). Порог 0.36 откалиброван по мужчинам
    # и браковал годных женщин («ЖЕРДЬ» на каждой женской полосе), поэтому
    # для женщин порог 0.30 — ниже одобренной вилки, но выше настоящей жерди
    # (~0.24, замер 14.10).
    min_ratio = 0.30 if args.sex == "f" else 0.36

    # Порог зазора 4-панельного листа: 28. Калибровка 21.10: одобренная
    # игроком nb6 walk имеет худший зазор 36, а порог 40 браковал её же
    # вилку (mai-image даёт 29–37 при годной нарезке).
    gap4 = 28
    mage = args.hero_class == "mage"
    if args.check:
        ok, _ = preflight(args.check, expect=args.panels,
                          min_gap=gap4 if args.panels == 4 else 60,
                          min_ratio=min_ratio, torso=mage)
        return 0 if ok else 1

    if args.anim not in (ANIMS4 if args.panels == 4 else ANIMS):
        print(f"неизвестно: {args.anim}")
        return 1
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    from gen_image_kodik import load_key, gen_once

    table = ANIMS4 if args.panels == 4 else ANIMS
    layout = LAYOUT4 if args.panels == 4 else LAYOUT
    # Раса задаёт базу, пол — надстройку. Для человека есть отдельный женский
    # блок (у неё другая анатомия), для орка женщина получается из мужского
    # текста через femaleize: у орка оба пола коренастые, отдельные пропорции
    # означали бы вторую копию правил.
    if args.race == "orc":
        character, proportions, view = CHARACTER_O, PROPORTIONS_O, VIEW
        if args.sex == "f":
            character = femaleize(character)
            # Изначально здесь стояло femaleize(CHARACTER_O) — замена
            # местоимений. Вышло: та же стойка, тот же кирас, те же плечи, то
            # есть мужчина (15.10). Женский пол теперь задан явно.
            character = CHARACTER_O_F
            proportions = PROPORTIONS_F
    elif args.race == "undead":
        # PROPORTIONS_U вместо общего: «толстый торс» человеческих пропорций
        # модель понесла на руки (20.10: у walk нежити выросли мышцы). У скелета
        # ширина даётся лопатками/тазом, а конечности — голые кости.
        if args.sex == "f":
            # 20.10: воительница — бледная мёртвая женщина (портрет necro_f_war),
            # а не скелет; пропорции и ракурс — женские боевые.
            character, proportions, view = CHARACTER_U_F, PROPORTIONS_F, VIEW_F
        else:
            character, proportions, view = CHARACTER_U, PROPORTIONS_U, VIEW
    elif args.race == "druid":
        if args.sex == "f":
            # 20.10: друидка в снаряжении dr1 («та же армия»), не в платье.
            character, proportions, view = CHARACTER_D_F, PROPORTIONS_F, VIEW_F
        else:
            character, proportions, view = CHARACTER_D, PROPORTIONS, VIEW
    else:
        character, proportions, view = CHARACTER, PROPORTIONS, VIEW
        if args.sex == "f":
            character, proportions, view = CHARACTER_F, PROPORTIONS_F, VIEW_F
    if args.hero_class == "mage":
        # 21.10: класс маг — воинские блоки дословно, меняется только одежда
        # (мантия до земли). Пропорции — воинские алиасы.
        mage_map = {"human": (CHARACTER_M, CHARACTER_M_F, PROPORTIONS_M, PROPORTIONS_M_F),
                    "orc": (CHARACTER_OM, CHARACTER_OM_F, PROPORTIONS_M, PROPORTIONS_M_F),
                    "undead": (CHARACTER_UM, CHARACTER_UM_F, PROPORTIONS_M, PROPORTIONS_M_F),
                    "druid": (CHARACTER_DM, CHARACTER_DM_F, PROPORTIONS_M, PROPORTIONS_M_F)}
        cm, cf, pm, pf = mage_map[args.race]
        if args.sex == "f":
            character, proportions, view = cf, pf, VIEW_F
        else:
            character, proportions, view = cm, pm, VIEW
    elif args.hero_class == "traveler":
        # Rescued NPC (11.11): the sturdy body contract of the warrior, civilian
        # clothes and empty hands. The race branch above only matters for the
        # default tag here -- the traveler is a map NPC, and the race variety in
        # town comes from the palette-swapped city heads.
        character = femaleize(CHARACTER_T) if args.sex == "f" else CHARACTER_T
        proportions = PROPORTIONS_F if args.sex == "f" else PROPORTIONS
        view = VIEW_F if args.sex == "f" else VIEW
    # Местоимения в тексте поз — английские, и оставленные «He/his» модель
    # рисует мужчину поверх женского описания персонажа. Замена по границам
    # слов, регистр сохраняется, чтобы «He does NOT crouch» не стало «She
    # does not». Проверяется, что после замены не осталось мужских форм.
    # Mage attack uses a dedicated staff raise/lower pose (player request,
    # 21.10): the generic punch animation makes no sense with a robe and staff.
    pose = ANIMS4_MAGE.get(args.anim, table[args.anim]) if args.hero_class == "mage" else table[args.anim]
    if args.sex == "f":
        pose = femaleize(pose)
        # Проверка по ГРАНИЦАМ СЛОВ, а не по подстроке. Подстрока давала
        # ложные срабатывания: "his " находится внутри "This panel is", а
        # "HE " — внутри "THE GROUND" (15.10 ночь, из-за этого генерация
        # орк-женщины падала, а не рисовала).
        male = re.search(r"\b(?:he|his|him|himself)\b", pose, re.IGNORECASE)
        if male:
            raise ValueError(f"в позе '{args.anim}' осталось мужское "
                             f"местоимение: {male.group(0)!r}")
    # Порядок блоков значим: характер -> телосложение -> ракурс -> поза ->
    # раскладка. Телосложение и ракурс стоят ДО описания позы, потому что
    # «SIDE VIEW» в конце промта перебивал «lean» в начале: узкий ракурс
    # побеждал при слове «broad» (замер 14.10: 0.24 ширины к высоте).
    prompt = (f"{character}\n\n{proportions}\n\n{view}\n\n{pose}\n\n{layout}")
    default_tag = {"human": {"m": "nb5", "f": "nb6"},
                   "orc": {"m": "oc1", "f": "oc2"},
                   "undead": {"m": "un1", "f": "un2"},
                   "druid": {"m": "dr1", "f": "dr2"}}[args.race][args.sex]
    if args.hero_class == "mage":
        default_tag = {"human": {"m": "hm1", "f": "hm2"},
                       "orc": {"m": "om1", "f": "om2"},
                       "undead": {"m": "nm1", "f": "nm2"},
                       "druid": {"m": "dm1", "f": "dm2"}}[args.race][args.sex]
    if args.hero_class == "traveler":
        default_tag = "tv1" if args.sex == "m" else "tv2"
    tag = args.tag or default_tag
    out = Path(args.out) if args.out else OUT_DIR / f"hero_{args.anim}_{tag}.png"
    gen_once(load_key(), args.model, prompt, out, SIZE, args.seed, 1, None)
    # mai-image (и другие) могут отдать фон «почти маджента» — нормализуем
    # до точной, иначе preflight не распознает фон.
    n = normalize_bg(out)
    print(f"нормализация фона: {n} пикселей перекрашено")
    print("предполётная проверка:")
    ok, _ = preflight(str(out), expect=args.panels,
                      min_gap=gap4 if args.panels == 4 else 60,
                      min_ratio=min_ratio, torso=mage)
    return 0 if ok else 2


if __name__ == "__main__":
    sys.exit(main())