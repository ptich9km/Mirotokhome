# Code glossary: Russian → English

Reference for translating **code comments only**. Game strings (UI, logs,
item/unit names) live in `assets/locale/ui.json` and in the `*_ru` data fields —
they are game content and are **not** translated by this migration.

## Rules

- Translate line-for-line: one source line → one target line, same line count.
- Keep comment markers and separators exactly: `#`, `##`, `# ---`, `# ===`,
  `## ----`, list numbers, indentation.
- Keep markers `TODO`, `FIXME`, `NOTE`, `HACK`, `XXX`, `WARNING`, `⚠`.
- Keep identifiers, paths, numbers, version strings and code examples unchanged.
- Keep Latin abbreviations as-is: HP, MP, XP, AI, NPC, AoE, VFX, SFX, UI, HUD,
  FPS, SIM, JSON, A*, MST, RLE, BFS, LOS.
- Prefer the table below; if a term is missing, follow the closest existing
  English identifier in the code and add it to this table.

## World and map

| Russian | English |
|---|---|
| мир | world |
| зона | zone |
| сектор | sector |
| биом | biome |
| карта | map |
| сид | seed |
| клетка | cell |
| тайл | tile |
| переход (биомов) | transition |
| проходимость | walkability |
| рельеф | relief |
| высоты | heights |
| препятствия | obstacles |
| спавн | spawn |
| точка спавна | spawn point |
| портал | portal |
| дорога | road |
| трава | grass |
| почва | soil |
| песок | sand |
| грязь | mud |
| горы | mountains |
| вода | water |
| берег | shore |
| город | city |
| здание | building |
| структура | structure |
| проп | prop |
| декор | decor |
| форпост | outpost |
| лагерь | camp |
| шатёр | tent |
| туман войны | fog of war |
| миникарта | minimap |
| маркер | marker |
| чанк | chunk |
| меш | mesh |
| слой | layer |

## Factions, units, world sim

| Russian | English |
|---|---|
| фракция | faction |
| репутация | reputation |
| Альянс Света | Light Alliance |
| Орды Огня | Fire Horde |
| Пожинатели | Reapers |
| Круг Друидов | Druid Circle |
| Серые | Greys |
| герой | hero |
| наёмник | mercenary |
| отряд | squad |
| враг | enemy |
| НПЦ (неигровой персонаж) | NPC |
| юнит | unit |
| набор (юнитов) | unit set |
| тир | tier |
| элита | elite |
| босс | boss |
| стражник, стража | guard |
| бирка (трофей) | tag (trophy) |
| стычка | skirmish |
| угроза | threat |
| журнал | journal |
| день мира | world day |
| лента мира | world feed |
| задание, квест | quest |
| награда | reward |
| диалог | dialogue |
| реплика (озвучка) | voice line |

## Combat and magic

| Russian | English |
|---|---|
| сфера | sphere |
| магия | magic |
| заклинание | spell |
| свиток | scroll |
| книга (заклинаний) | book |
| зелье | potion |
| трава (алхимия) | herb |
| урон | damage |
| урон по площади | area damage (AoE) |
| атака | attack |
| защита | defense |
| поглощение | absorption |
| сопротивление | resistance |
| промах | miss |
| попадание | hit |
| щит | shield |
| аура | aura |
| благословение | blessing |
| ускорение | haste |
| лечение | healing |
| кулдаун | cooldown |
| каст | cast |
| снаряд | projectile |
| область | area |
| телеграф | telegraph |
| очаг (огня) | source (ember) |
| яд | poison |
| метель | blizzard |
| стена огня | fire wall |
| сияние | radiance |
| телепорт | teleport |
| тактическая пауза | tactical pause |

## Items, crafting, UI

| Russian | English |
|---|---|
| предмет | item |
| инвентарь, склад | inventory |
| экипировка | equipment |
| снаряжение | gear |
| слиток | ingot |
| металл | metal |
| качество | quality |
| сломанный | broken |
| рецепт | recipe |
| чертёж | blueprint |
| мастерская | workshop |
| кузня | forge |
| ремесло | craft |
| навык | skill |
| умение | ability |
| панель | panel |
| вкладка | tab |
| кнопка | button |
| сетка | grid |
| ячейка | cell |
| строка (таблицы) | row |
| подсказка, тултип | tooltip |
| фокус | focus |
| настройки | settings |
| громкость | volume |
| шина (аудио) | bus |
| звук | sound / SFX |
| музыка | music |
| сейв, сохранение | save |
| слот | slot |
| автосейв | autosave |
| загрузка | loading |

## Art pipeline and tooling

| Russian | English |
|---|---|
| спрайт | sprite |
| кадр | frame |
| полоса (кадров) | strip |
| нарезка | slicing / cutout |
| контактный лист | contact sheet |
| preflight (проверка) | preflight |
| фигура | figure |
| холст | canvas |
| пивот | pivot |
| риг | rig |
| анимация | animation |
| фаза | phase |
| шейдер | shader |
| рендер | render |
| камера | camera |
| мод | mod |
| загрузчик модов | mod loader |
| манифест | manifest |
| правило (контента) | rule |
| ключ | key |
| значение | value |
| таблица | table |

## Do not translate

- Proper names: MIROTOKHOME, Allods, Allods II.
- Data keys, identifiers, file paths, `.alm`/`.json`/`.png` names.
- Russian strings inside code (`"..."`) — they are game text or test output.
