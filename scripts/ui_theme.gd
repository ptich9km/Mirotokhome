class_name UiTheme
extends RefCounted
## Единая дизайн-система Mirotokhome: палитра, шкала кеглей, шкала отступов, шрифты.
##
## Единственный источник правды по оформлению. До этого файла каждая панель
## задавала свои цвета инлайном, из-за чего оформление расползлось: алхимия была
## зелёной, главное меню — на дефолтной теме движка (в `main_menu.gd` строка
## `theme = theme` затеняла свойство `Control.theme`, и тема выбрасывалась).
##
## Правило: панель НЕ пишет `Color(...)` и кегль числами. Она берёт роль отсюда
## (`UiTheme.PANEL_EDGE`) и ступень шкалы (`UiTheme.FONT_TITLE`). Сторож на это —
## `tests/ui_design_system_smoke.gd`.

# === Палитра ===
## Тёплый тёмный металл и золото. Раньше эти значения были размазаны по девяти
## панелям; здесь они названы один раз.

const BG_DEEP := Color(0.047, 0.039, 0.035)          ## самый тёмный фон, под всем
const PANEL_BG := Color(0.071, 0.055, 0.043, 1.0)    ## непрозрачное тело панели
const PANEL_EDGE := Color(0.478, 0.290, 0.118)       ## рамка панели
const PANEL_INNER := Color(0.141, 0.102, 0.071)      ## утопленные вложенные блоки

const ACCENT := Color(1.0, 0.769, 0.302)             ## золото: заголовки, фокус
const ACCENT_DIM := Color(0.792, 0.549, 0.239)       ## золото приглушённое
const TEXT := Color(0.961, 0.890, 0.722)             ## основной текст
const TEXT_MUTED := Color(0.627, 0.553, 0.447)       ## подписи, подвал
const TEXT_OFF := Color(0.400, 0.353, 0.302)         ## неактивно

const SLOT_BG := Color(0.078, 0.067, 0.078, 0.98)    ## ячейка инвентаря/полки
const SLOT_EDGE := Color(0.580, 0.361, 0.161, 0.96)   ## рамка ячейки

const DANGER := Color(0.769, 0.333, 0.227)           ## «Нет», удаление слота
const SUCCESS := Color(0.498, 0.651, 0.314)          ## «Да», подтверждение

## Затемнение под модальным окном. Не раньше 0.45 — иначе панель «плавает».
const SCRIM := Color(0.0, 0.0, 0.0, 0.45)
## Fully opaque black: the game-over backdrop, where the world is already gone.
const VOID := Color(0.0, 0.0, 0.0, 1.0)
## Прозрачный stylebox (рамка фокуса без заливки).
const TRANSPARENT := Color(0.0, 0.0, 0.0, 0.0)

# === Шкала кеглей ===
## Шесть ступеней вместо ~20 разных значений, которые были размазаны по панелям.

const FONT_MICRO := 12      ## сноски, счётчики
const FONT_BODY := 14       ## обычный текст, кнопки
const FONT_SUBHEAD := 16    ## подзаголовки, сумма золота
const FONT_SECTION := 20    ## заголовок секции
const FONT_TITLE := 28      ## заголовок панели
const FONT_SCREEN := 44     ## название игры

# === Шкала отступов ===

const SPACE_1 := 4
const SPACE_2 := 8
const SPACE_3 := 12
const SPACE_4 := 16
const SPACE_5 := 24
const SPACE_6 := 32

## Отступ панели от края экрана. За этим полем виден живой мир — требование
## игрока: панель непрозрачная и занимает большую часть пространства, но по краям
## видно игру.
const SCREEN_INSET := 32

# === Форма ===

const RADIUS_SLOT := 4
const RADIUS_PANEL := 6
const RADIUS_FRAME := 8

const BORDER_HAIRLINE := 1
const BORDER_NORMAL := 2
const BORDER_FOCUS := 3

# === Шрифты ===
## Оба с полной кириллицей (подмножества `cyrillic, cyrillic-ext` в METADATA.pb).
## До этого в проекте не было ни одного шрифтового файла — везде стоял дефолт
## Godot. Проверка наличия глифов — в `ui_design_system_smoke.gd`.

const FONT_BODY_FILE := "res://assets/fonts/PT_Sans-Web-Regular.ttf"
const FONT_BODY_BOLD_FILE := "res://assets/fonts/PT_Sans-Web-Bold.ttf"
const FONT_DISPLAY_FILE := "res://assets/fonts/Philosopher-Regular.ttf"
const FONT_DISPLAY_BOLD_FILE := "res://assets/fonts/Philosopher-Bold.ttf"

## Проверяемые строки: обе должны содержать весь русский алфавит.
const CYRILLIC_PROBE := "АБВГДЕЁЖЗИЙКЛМНОПРСТУФХЦЧШЩЪЫЬЭЮЯабвгдеёжзийклмнопрстуфхцчшщъыьэюя"


static func body_font() -> FontFile:
	return load(FONT_BODY_FILE) as FontFile


static func body_font_bold() -> FontFile:
	return load(FONT_BODY_BOLD_FILE) as FontFile


## Антиква для заголовков. Намеренно только для крупных кеглей: на 12–14 px
## Philosopher читается хуже PT Sans.
static func display_font() -> FontFile:
	return load(FONT_DISPLAY_FILE) as FontFile


static func display_font_bold() -> FontFile:
	return load(FONT_DISPLAY_BOLD_FILE) as FontFile


## Все четыре файла существуют. Нужен тесту, чтобы удалённый шрифт не уронил
## меню в рантайме.
static func font_files_exist() -> bool:
	for p in [FONT_BODY_FILE, FONT_BODY_BOLD_FILE,
			FONT_DISPLAY_FILE, FONT_DISPLAY_BOLD_FILE]:
		if not ResourceLoader.exists(p):
			return false
	return true


# === Проектная тема ===
## Тема по умолчанию для всего проекта: шрифт, кегль, кнопки, полосы прокрутки.
## Подключена через `project.godot` → `gui/theme/custom` (внешний .tres), а этот
## метод даёт тот же набор для панелей, которые собирают тему в коде.
##
## Стили тут намеренно сдержанные: панель должна выглядеть как панель, а
## собственные вариации (`UiKit.add_button` и т.п.) — как её содержимое.

static func app_theme() -> Theme:
	var theme := Theme.new()
	if font_files_exist():
		theme.default_font = body_font()
	theme.default_font_size = FONT_BODY
	theme.set_color("font_color", "Label", TEXT)
	theme.set_color("font_color", "Button", TEXT)
	theme.set_color("font_hover_color", "Button", Color(1.0, 0.922, 0.620))
	theme.set_color("font_pressed_color", "Button", Color(1.0, 0.976, 0.859))
	theme.set_color("font_focus_color", "Button", ACCENT)
	theme.set_color("font_disabled_color", "Button", TEXT_OFF)
	UiKit.apply_scrollbar(theme, RADIUS_SLOT, SPACE_1)
	return theme


## Заголовок панели антиквой указанного кегля.
static func add_display_label(theme: Theme, name: StringName, size: int,
		color: Color = ACCENT) -> void:
	UiKit.add_label(theme, name, color, size)
	if font_files_exist():
		theme.set_font(name, name, display_font())
		theme.set_font_size(name, name, size)