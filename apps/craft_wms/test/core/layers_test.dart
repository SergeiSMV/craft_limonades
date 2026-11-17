import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Тест-сторож слоёв Flutter (`dev.md §2`, ADHOC-71) - пара к `handler/layers_test.go` бэкенда.
///
/// Что: разбирает импорты исходников `lib/` и падает, если
/// - `presentation` фичи или портала, или общий виджет `core/widgets` импортирует `data/` -
///   своей фичи или чужой: экраны знают только интерфейсы `domain`;
/// - `domain` фичи или портала импортирует `data/`: домен не знает, откуда берутся данные.
/// Зачем: правило держалось на ревью и разошлось с кодом (долг 38); после уборки FE-1…FE-5
/// нарушение должно ронять `flutter test`, а не копиться снова.
/// Как: читает файлы как текст, без анализатора - только строки `import '…';`. Относительный
/// путь и `package:craft_wms/` сводятся к пути внутри `lib/`; сгенерированные файлы
/// (`*.g.dart`, `*.freezed.dart`, `*.gr.dart`, `*.config.dart`) не проверяются.
///
/// Портал (`lib/portal/`) проверяется наравне с фичами с FE-5 (до неё был исключением).
void main() {
  final lib = Directory('lib');
  final importLine = RegExp(r'''^import\s+'([^']+)';''', multiLine: true);
  final generated = RegExp(r'\.(g|freezed|gr|config)\.dart$');

  /// Путь импорта [uri] из файла [from] - внутри `lib/` (`features/x/data/y.dart`), либо
  /// `null` для чужого пакета и `dart:`.
  String? resolve(String from, String uri) {
    if (uri.startsWith('package:craft_wms/')) {
      return uri.substring('package:craft_wms/'.length);
    }
    if (uri.contains(':')) return null;
    // Относительный путь: от папки файла, `..` снимает сегмент.
    final parts = from.split('/')..removeLast();
    for (final seg in uri.split('/')) {
      if (seg == '..') {
        parts.removeLast();
      } else if (seg != '.') {
        parts.add(seg);
      }
    }
    return parts.skip(1).join('/'); // без ведущего `lib`
  }

  bool isData(String path) =>
      RegExp(r'^(features/[^/]+|portal)/data/').hasMatch(path);

  /// Нарушения: «файл → импорт» для файлов, отобранных [watched].
  List<String> violations(bool Function(String path) watched) {
    final found = <String>[];
    for (final entity in lib.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      if (generated.hasMatch(entity.path)) continue;
      final path = entity.path.substring('lib/'.length);
      if (!watched(path)) continue;
      for (final m in importLine.allMatches(entity.readAsStringSync())) {
        final target = resolve(entity.path, m.group(1)!);
        if (target != null && isData(target)) found.add('$path → $target');
      }
    }
    return found;
  }

  test('presentation и core/widgets не импортируют data/', () {
    final found = violations(
      (path) =>
          RegExp(r'^(features/[^/]+|portal)/presentation/').hasMatch(path) ||
          path.startsWith('core/widgets/'),
    );
    expect(found, isEmpty, reason: 'брать через интерфейс domain фичи');
  });

  test('domain не импортирует data/', () {
    final found = violations(
      (path) => RegExp(r'^(features/[^/]+|portal)/domain/').hasMatch(path),
    );
    expect(found, isEmpty, reason: 'домен не знает про источники данных');
  });
}
