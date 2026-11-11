# Оформление страницы игры на itch.io под тему Mirotokhome

Два уровня, и первый почти всегда достаточен:

1. **Встроенный редактор темы** — Edit game → **Theme**. Цвета, шрифт, радиус,
   тень, фоновая картинка. Доступен всем, ничего просить не надо.
2. **Custom CSS** — только по заявке в поддержку (`itch.io/support`), на аккаунт
   вручную выдают доступ. Без доступа поля CSS в редакторе просто нет.

Правило itch из справки: сначала убедись, что задача не решается встроенным
редактором, и только потом проси CSS. Ниже — и то, и другое.

## Готовые картинки для темы (11.11)

Сгенерированы из ассетов проекта, бесплатно: `tests/gen_itch_theme_art.py`
(`--check` проверяет размеры и бесшовность).

| Файл | Куда | Размер |
|---|---|---|
| `docs/publish/theme/bg-tile.png` | Edit Theme → Images → **Background** | 512×512, бесшовная (соседние копии стыкуются без шва), палитра `BG_DEEP`/`PANEL_EDGE` с мягкой диагональной фактурой |
| `docs/publish/theme/favicon-32.png` | Edit game → Metadata → Promo images → **Favicon** | 32×32, сделан из `assets/ui/icon.png` |
| `docs/publish/theme/social-1200x630.png` | Metadata → Promo images → **Social Media Image** | 1200×630, заголовок Philosopher + подзаголовок PT Sans на затемнённом кадре боя |

Почему фон — плитка, а не скриншот: itch **повторяет** фоновую картинку, и
повторённый кадр игры читается как баг. Плитка бесшовная по построению (только
периодические синусоиды и штриховка с периодом, делящим 512), сквозь неё
спокойно читается текст, а `BG2 Alpha` ~0.92 не даёт фактуре лезть под буквы.

Промо-карточка собрана зеркалом левой половины кадра боя: так убраны лог чата в
углу и вертикальный шов террейна справа. **Отдельный долг (не про itch):** в
`01_world.png` и `05_combat.png` видны обрывы террейна — синие блоки воды с
жёсткой кромкой и вертикальная линия шва. Это реальный визуальный дефект
BlendMesh, его стоит разобрать отдельной задачей; в промо-материалы он попадать
не должен.

## Палитра из игры (`scripts/ui_theme.gd`)

Значения сняты из кода, а не придуманы: это те же цвета, что видит игрок в HUD.

| Поле itch | Значение | Что это в игре |
|---|---|---|
| Page background | `#0C0A09` | `BG_DEEP` — тёмный фон сцены |
| Panel background | `#120E0B` | `PANEL_BG` — тело панелей; включи прозрачность панели, чтобы сквозь неё шла фоновая картинка |
| Text | `#F5E3B8` | `TEXT` — тёплый светлый текст |
| Link / accent | `#FFC44D` | `ACCENT` — золото, заголовки и фокус |
| Border | `#7A4A1E` | `PANEL_EDGE` — рамка панелей |
| Button background | `#7A4A1E` | рамка панели (кнопка читается как «бронза») |
| Button text | `#F5E3B8` | текст по кнопке |
| Button shadow | `#4A2C12` | тень кнопки, производная от `PANEL_EDGE` |
| Corner radius | `6` | `RADIUS_PANEL` |
| Font | из списка itch (сейчас Lato) | Philosopher в списке нет — см. ниже |

Второстепенные цвета, если пригодятся: `TEXT_MUTED #A08D72`, `ACCENT_DIM #CA8C3D`,
`SLOT_BG #141114`, `SLOT_EDGE #945C29`, `DANGER #C4553A`, `SUCCESS #7FA650`.

## Шрифт

В игре два шрифта: **Philosopher** (заголовки, `FONT_DISPLAY`) и **PT Sans**
(текст, `FONT_BODY`). Встроенный редактор itch даёт свой список шрифтов, и
Philosopher туда не входит. Варианты:

- **Бесплатно и сразу:** оставить шрифт itch, а «характер» передать цветом и
  скриншотами — этого хватает, чтобы страница читалась как игра.
- **Точно как в игре:** только через Custom CSS, и шрифт нужно положить на HTTPS
  (itch не отдаёт локальные файлы). Файл `assets/fonts/Philosopher-Bold.ttf`
  можно вшить в CSS в base64 — он маленький, но лицензия OFL требует держать
  рядом текст лицензии (`assets/fonts/OFL-Philosopher.txt`).

## Что ещё делает страницу «своей» (важнее цветов)

- **Cover image** уже есть (630×500). Он же — карточка в ленте itch, проверяй
  читаемость в широком кропе 508×254.
- **Banner** (необязателен): если загрузить, название игры с заголовка страницы
  исчезает — баннер должен сам содержать логотип.
- **Screenshots**: 5 штук 1280×800 + 4 gif уже стоят; порядок = важность:
  первым — мир/карта, вторым — бой, дальше пауза и кузня.
- **Видео-трейлер**: пустой блок `video_embed` на странице; YouTube-ссылка
  оживляет страницу сильнее любых цветов.
- Описание уже переписано под 0.2.0 и содержит новые механики.

## Custom CSS (если доступ выдадут)

Правила из справки itch: всё внутри `#wrapper`, пользоваться переменными темы
`--itchio_*`, не переделывать саму страницу, проверять разлогиненным и на мобиле.
Классы контента должны начинаться с `custom-`.

```css
/* Mirotokhome page theme. Scope: only the game page content. */
#wrapper {
  --itchio_link_color: #ffc44d;
  --itchio_button_color: #7a4a1e;
  --itchio_button_fg_color: #f5e3b8;
  --itchio_border_color: #7a4a1e;
  --itchio_border_radius: 6px;
  background-color: #0c0a09;
  background-image: url("https://example.com/mirotokhome/backdrop.jpg");
  background-size: cover;
  background-position: center top;
  background-attachment: fixed;
}

/* Description: a panel like the in-game UI, warm border, readable width. */
#wrapper .formatted_description {
  background: rgba(18, 14, 11, 0.92);
  border: 1px solid #7a4a1e;
  border-radius: 6px;
  padding: 18px 22px;
  color: #f5e3b8;
}

/* Section headings inside the description (the ALL-CAPS lines). */
#wrapper .formatted_description strong,
#wrapper .formatted_description b {
  color: #ffc44d;
  letter-spacing: 0.04em;
}

/* Screenshot column: same panel treatment, no childish rounded cards. */
#wrapper .right_col img.screenshot {
  border: 1px solid #7a4a1e;
  border-radius: 4px;
}

/* Keep the developer's own divider lines quiet instead of heavy white rules. */
#wrapper .formatted_description hr {
  background-color: #7a4a1e;
  height: 1px;
  border: 0;
}
```

Что **не** делать: не прятать футер itch и кнопку скачивания, не убирать
комментарии/Community, не ставить фон, на котором не читается текст
(`#F5E3B8` на светлой картинке исчезает — либо затемняй фото, либо ставь
панель под текст).

## Порядок действий

1. Edit game → **Theme**: вбить цвета и радиус, включить прозрачность панели.
2. Открыть страницу разлогиненным, проверить на телефоне.
3. Если чего-то не хватает (свои шрифты, узоры, рамки) — заявка на CSS в
   `itch.io/support`: что именно нужно, что встроенный редактор не даёт, что
   правила из справки соблюдаешь.
