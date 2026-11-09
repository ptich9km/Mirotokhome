# Аудио: источники и лицензии

Дата первой сборки: 23.10.2026. Собирается `tests/gen_audio_db.py` в
`assets/audio/sfx/{ui,combat,magic}/` + индекс `assets/audio/sound_db.json`.
Реплики — `tests/gen_voice_silero.py` (Silero v5_ru, локально) по
`assets/audio/voice_lines.json`; старый путь `tests/gen_voice_kodik.py`
(KodikRouter) оставлен для рабочего ПК.

Правило: в репозиторий попадают только файлы из этого списка. Скачанные
архивы лежат в `import/audio_src/` (в `.gitignore`) и в git не идут.

## CC0 (public domain, без обязательной атрибуции)

| Пак | Автор | Лицензия | URL |
|---|---|---|---|
| Interface Sounds | Kenney | CC0 1.0 | https://kenney.nl/assets/interface-sounds |
| UI Audio | Kenney | CC0 1.0 | https://kenney.nl/assets/ui-audio |
| Impact Sounds | Kenney | CC0 1.0 | https://kenney.nl/assets/impact-sounds |
| RPG Audio | Kenney | CC0 1.0 | https://kenney.nl/assets/rpg-audio |
| RPG Sound Pack | artisticdude | CC0 1.0 | https://opengameart.org/content/rpg-sound-pack |
| 80 CC0 RPG SFX | rubberduck | CC0 1.0 | https://opengameart.org/content/80-cc0-rpg-sfx |
| Swishes | qubodup | CC0 1.0 | https://opengameart.org/content/swishes-sound-pack |
| Magic Spell SFX | JaggedStone | CC0 1.0 | https://opengameart.org/content/magic-spell-sfx |
| Earth Element Magic Spell | qubodup | CC0 1.0 | https://opengameart.org/content/earth-element-magic-spell |
| Cure Magic | Someoneman | CC0 1.0 | https://opengameart.org/content/cure-magic |
| Teleport Spell | Ogrebane | CC0 1.0 | https://opengameart.org/content/teleport-spell |
| Spell sounds | Augmentality | CC0 1.0 | https://opengameart.org/content/spell-sounds |
| 40 CC0 water / splash / slime | rubberduck | CC0 1.0 | https://opengameart.org/content/40-cc0-water-splash-slime-sfx |
| 10 Impact / Shield Blocks | StarNinjas | CC0 1.0 | https://opengameart.org/content/10-impactshield-blocks |
| Fire Crackling | AntumDeluge | CC0 1.0 | https://opengameart.org/content/fire-crackling |

CC0 означает, что атрибуция не требуется. Она всё равно указана здесь —
это честнее и помогает, если лицензия автора когда-нибудь окажется спорной.

## Музыка

8 треков (~3 минуты каждый) предоставлены игроком 23.10.2026 и сконвертированы
`tests/gen_music_ogg.py` в OGG q4 (`assets/audio/music/`, 21.4 МБ вместо 280 МБ WAV).
WAV-мастера — `import/audio_src/music/` (gitignore).

| Файл | Место в плейлисте |
|---|---|
| `menu_main.ogg` | 1 — старт игры, тема меню |
| `town_rest_1.ogg` | 2 |
| `town_rest_2.ogg` | 3 |
| `ancient_1.ogg` | 4 |
| `ancient_2.ogg` | 5 |
| `explore_1.ogg` | 6 |
| `explore_2.ogg` | 7 |
| `combat_1.ogg` | 8 — затем снова 1 |

Очередь идёт по кругу на весь сеанс (`scripts/music_db.gd`), независимо от сцены.

**TODO:** указать здесь сервис генерации и его условия использования, когда
игрок подтвердит название. Пока треки считаются созданными для проекта.

## Синтезированные файлы

`combat/bow_*.wav` — собраны скриптом из двух CC0-сэмплов (свист `Swishes` +
щелчок `wood-small` из RPG Sound Pack). Отдельной лицензии не требуют.

## Реплики

68 файлов в `assets/audio/sfx/voice/` (52 ключа `voice.*`) синтезированы локально
на **Silero v5_ru** (`tests/gen_voice_silero.py`, 10.11.2026): пять голосов —
`aidar`, `baya`, `kseniya`, `xenia`, `eugene`. Режиссура (голос, темп, тон,
пресет фактуры) — в `assets/audio/voice_lines.json`, пресеты — в
`tests/voice_fx.py`. Голоса распределены по расам города: люди, орки, нежить,
друиды; у героини `baya`, у героя `aidar`.

Раньше (23.10–10.11) те же реплики шли через KodikRouter (ElevenLabs v3, голоса
`george` и `bella`); записи сохранены вне репозитория в
`C:\Work\ComfyUI\_music_album\voice_kodik_backup\`. Причина замены — американский
акцент у неродных русскому языку голосов.

**Лицензия модели:** Silero v5_ru — CC BY-NC 4.0 (некоммерческое использование).
Файлы озвучки созданы для проекта; для коммерческого запуска голоса нужно
перегенерировать (см. `THIRD-PARTY.md`, раздел «Звук»).

## Что удалено

Весь звук из Allods / Rage of Mages II удалён 23.10.2026: 445 `.wav`,
`sound_index.json` (192 записи), `sfx.reg`. Копия лежит вне репозитория в
`C:\Temp\opencode\allods_audio_backup\`. Числовые ID (`SoundDB.play(1)`)
больше не поддерживаются — только именованные ключи.

## Чего сознательно не берём

| Источник | Почему |
|---|---|
| Sonniss GDC bundles | 9–48 ГБ на год, лицензия запрещает использование для обучения ИИ |
| ZapSplat | обязательная атрибуция на бесплатном тарифе, только mp3 |
| Pixabay | лицензия отзываемая, не CC0 |
| p0ss Spell Sounds Starter Pack | CC-BY-SA / GPL — вирусная лицензия для игры |
| CC-BY и CC-BY-SA паки | требуют кредитов/совместимой лицензии; берём только если не хватит CC0 |
