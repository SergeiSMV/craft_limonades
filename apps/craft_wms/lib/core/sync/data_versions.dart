import 'dart:async';

import 'package:injectable/injectable.dart';

/// Области данных сервера (ADHOC-60, миграция 43): единицы перечитывания на клиентах.
abstract final class DataDomain {
  /// Номенклатура, группы, поставщики, штрихкоды.
  static const goods = 'goods';

  /// Склады, ячейки, стеллажи.
  static const cells = 'cells';

  /// Внутренние склады, причины проблем, должности, пользователи.
  static const settings = 'settings';

  /// Остатки, партии, короба, марки ЧЗ — снимок склада.
  static const contents = 'contents';

  /// Задания для склада и их ход.
  static const tasks = 'tasks';

  /// Проблемы склада.
  static const problems = 'problems';

  /// Пересчёты.
  static const stocktakes = 'stocktakes';

  /// Документы для 1С.
  static const documents = 'documents';

  /// Сборка по реестру 1С: заказы, строки, пики, короба (P9-02).
  static const picking = 'picking';
}

/// Версии данных сервера, известные клиенту (ADHOC-60, ADR-0018).
///
/// Что: помнит версию каждой области и сообщает, какие области ушли вперёд.
/// Зачем: сервер отдаёт версии в каждом ответе — клиент перечитывает только изменившееся, без
///        WebSocket и без фонового опроса, который сажает батарею ТСД.
/// Как: [observe] получает заголовок `X-Data-Versions` из каждого ответа (перехватчик Dio).
///      Первый ответ после входа только запоминает версии: загрузку при входе клиент делает и
///      так. Дальше область считается изменившейся, только если версия выросла — ответ, пришедший
///      позже более свежего, не вызовет лишней загрузки.
@lazySingleton
class DataVersions {
  final Map<String, int> _known = {};
  bool _seeded = false;
  final _changes = StreamController<Set<String>>.broadcast();

  /// Области, ушедшие вперёд, — по одному событию на ответ сервера.
  Stream<Set<String>> get changes => _changes.stream;

  /// Изменилась хоть одна из [domains].
  Stream<Set<String>> on(Set<String> domains) =>
      changes.where((changed) => changed.any(domains.contains));

  /// Версии из заголовка ответа: «contents=340,goods=12». Пусто или `null` — ничего.
  void observe(String? header) {
    final versions = parse(header);
    if (versions.isEmpty) return;
    if (!_seeded) {
      _seeded = true;
      _known.addAll(versions);
      return;
    }
    final changed = <String>{};
    versions.forEach((domain, version) {
      final known = _known[domain];
      if (known == null || version > known) {
        _known[domain] = version;
        if (known != null) changed.add(domain);
      }
    });
    if (changed.isNotEmpty) _changes.add(changed);
  }

  /// Забыть версии — при выходе: следующий вход загрузит всё заново и запомнит их снова.
  void reset() {
    _known.clear();
    _seeded = false;
  }

  /// Разбор заголовка; кривые части пропускаются.
  static Map<String, int> parse(String? header) {
    final out = <String, int>{};
    if (header == null) return out;
    for (final part in header.split(',')) {
      final kv = part.split('=');
      if (kv.length != 2) continue;
      final version = int.tryParse(kv[1].trim());
      final domain = kv[0].trim();
      if (domain.isEmpty || version == null) continue;
      out[domain] = version;
    }
    return out;
  }
}
