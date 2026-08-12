# P-FS-06 · Портал: кнопка скачивания PDF-этикеток ячеек

**Статус:** готово (ветка `p-fs-06-portal-cell-labels-download`); ⚠ визуал/клиентский E2E — за пользователем.
**Фаза:** P-FastStart (волна 1a). ТЗ — [`docs/p-faststart-1.md`](p-faststart-1.md).

## Задача

На вкладке «Ячейки» веб-портала — кнопка «Скачать этикетки (PDF)», дёргающая эндпоинт P-FS-05 и
сохраняющая файл в браузере.

## Критерий готовности

На вкладке «Ячейки» кнопка → скачивается `labels.pdf` текущего склада; admin-only; ошибка бэкенда
показывается сообщением.

## Что сделано

- **`ApiConst.cellLabelsPdf = 'cells/labels.pdf'`** (без ведущего `/`, как все маршруты).
- **`CellsRepository.downloadCellLabels()`** → `Either<Failure, Uint8List>`: `GET cells/labels.pdf`
  `?warehouse=SHB`, `responseType: bytes` (тело не JSON); токен подставляет `AuthInterceptor`,
  404/403 → `ServerFailure`. Склад — константа `SHB` (склад один на пилоте; совпадает с дефолтом бэка).
- **`web_download.dart` — `downloadBytes(bytes, filename, mime)`:** сохранение файла в браузере через
  Blob + object URL + скрытый `<a download>` (по образцу `web_file_picker.dart`, `package:web` + js-interop).
- **`CellsTab`:** новая карточка «Этикетки ячеек» над блоком импорта — заголовок/описание + кнопка
  `FilledButton.icon` (иконка `download`; при загрузке — спиннер + «Формирование PDF…»); ошибка
  показывается тем же `_errorText`. Состояние скачивания (`_downloadingLabels`/`_labelsError`)
  независимо от импорта; обработчик `downloadLabels()` вынесен из `build`.
- **i18n** (`portal.cells.labels*`): title/description/download/downloading; slang перегенерён.

## Решения

- **`responseType: bytes`** — PDF не парсим как JSON; репозиторий отдаёт `Uint8List`, UI отдаёт файл.
- **Скачивание — веб-хелпер без плагина** (как `web_file_picker`): `package:web`, чтобы не тянуть
  file-плагины (конфликт с talker по win32 — уже решался в проекте).
- **Склад захардкожен `SHB`** — на пилоте один; без селектора склада (решение пользователя).
- **Кнопка отдельной карточкой над импортом** — печать этикеток логически предшествует наклейке и
  проходу; импорт ячеек остаётся ниже.

## Проверка

- `flutter analyze` — **No issues**.
- Тесты: `test/portal/cells_repository_test.dart` — успех (байты PDF, `GET cells/labels.pdf`,
  `warehouse=SHB`, `responseType: bytes`), 404 → `ServerFailure(404)`, маршрут без ведущего `/`.
  Полный прогон — **31 тест зелёный** (регрессий нет).
- `flutter build web -t lib/main_portal.dart --dart-define-from-file=.env --release` — **зелёная**
  (гейт компиляции портала).

```bash
cd apps/craft_wms
flutter analyze
flutter test test/portal/cells_repository_test.dart
flutter build web -t lib/main_portal.dart --dart-define-from-file=.env --release
```

## Границы

- ⚠ Клиентский визуал/скачивание вживую (клик → файл) — за пользователем: логика скачивания —
  веб-специфична, юнит покрывает репозиторий, компиляция — гейтом.
- Публикация портала на прод — вручную (P1-09-1), воспроизводимый деплой снят (P1-09-3).
- Поток ввода остатков на ТСД (скан ячейки этим ШК) — **P-FS-07**.
