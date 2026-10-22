# ADHOC-39 (fe) · ТСД: приложение стенда рядом с боевым, скан — только приложению на экране

**Статус:** ✅ завершена (`flutter analyze` 0 issues, 655 тестов Flutter зелёные; обе релизные
APK собраны, идентификатор и подпись проверены `aapt2 dump badging`).
**Категория:** внеплановая, `adhoc-fe`. Строки в `plan_v3.docx` нет; закрывает долг 28.

## Задача

Сборка ТСД против тестового стенда (`stand.sh apk`) ставилась поверх боевой: идентификатор
приложения один (`com.craftlimonades.sklad`), а очередь операций переживает переустановку.
Неотправленная операция, сделанная против стенда, после возврата боевой сборки уходила на
прод, и наоборот. Защитой было только правило «переключать терминал с пустой очередью».

## Критерий готовности

Приложение стенда ставится на тот же терминал рядом с боевым, у каждого своя база и очередь;
боевая сборка собирается прежней командой и не меняет идентификатора; скан получает только
приложение на экране.

## Что сделано

| Файл                                          | Правка                                      |
|-----------------------------------------------|---------------------------------------------|
| `android/app/build.gradle.kts`                | `STAND=true` → свой id и подпись            |
| `android/app/src/main/AndroidManifest.xml`    | подпись из `${appLabel}`                    |
| `lib/core/scanner/scanner_service.dart`       | скан — только приложению на экране          |
| `test/core/scanner/scanner_service_test.dart` | скан в фоне отбрасывается                   |
| `deploy/test_stand/stand.sh`                  | `apk` собирает с `--dart-define=STAND=true` |
| `docs/deploy/test-stand.md`                   | раздел «ТСД на стенде»                      |

## Ключевые решения

### Признак сборки, а не flavor

Сборка стенда помечается `--dart-define=STAND=true`. Flutter передаёт dart-define в Gradle
свойством `dart-defines` (пары `KEY=VALUE` в base64 через запятую); `build.gradle.kts` их
разбирает и при `STAND=true` ставит идентификатор `com.craftlimonades.sklad.stand` и подпись
«КЛ: Склад · СТЕНД». Пакет Kotlin-кода (`namespace`) не меняется.

Flavor отверг: с заведёнными в Android-проекте flavor'ами `--flavor` понадобился бы в каждой
сборке — в боевой команде, в CI и в инструкции ввода ТСД. Сейчас боевая сборка собирается
прежней командой, с прежним идентификатором и без переустановки на терминалах.

### Скан — только приложению на экране

Нашлось при разборе. Сканер Urovo рассылает код всем приложениям, а приёмник канала
регистрируется на время жизни движка и в фоне не снимается. С одним приложением это не
мешало; с двумя скан в приложении стенда получило бы и боевое, висящее в фоне на экране,
который ждёт скан. `HardwareScannerService` пропускает события, только пока состояние
приложения — `resumed`; пока состояния нет (старт), не отсекает.

### Переход

Сборки стенда до этого ставились под боевым идентификатором. Терминал, на котором сейчас
такая, переводится на боевую APK по прежнему правилу — с пустой очередью; дальше стенд
ставится отдельным приложением.

## Проверка

```bash
cd apps/craft_wms
dart run build_runner build --delete-conflicting-outputs
flutter analyze && flutter test
flutter build apk --release -t lib/main.dart --dart-define-from-file=.env --dart-define=STAND=true
"$(ls -d ~/Library/Android/sdk/build-tools/*/ | sort -V | tail -1)aapt2" dump badging \
  build/app/outputs/flutter-apk/app-release.apk | grep -E "^package:|application-label:"
flutter build apk --release -t lib/main.dart --dart-define-from-file=.env
"$(ls -d ~/Library/Android/sdk/build-tools/*/ | sort -V | tail -1)aapt2" dump badging \
  build/app/outputs/flutter-apk/app-release.apk | grep -E "^package:|application-label:"
```

Ожидаемо: у сборки стенда — `com.craftlimonades.sklad.stand` и «КЛ: Склад · СТЕНД», у боевой —
`com.craftlimonades.sklad` и «КЛ: Склад».

## Границы задачи

- Иконка приложения стенда та же; различие — подпись на рабочем столе.
- Внутри приложения стенд ничем не помечен.
- Сервер и схема не менялись.
