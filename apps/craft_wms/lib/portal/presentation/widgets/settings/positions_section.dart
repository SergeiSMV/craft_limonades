import 'package:either_dart/either.dart';
import 'package:flutter/material.dart';

import '../../../../core/di/injection.dart';
import '../../../../core/error/failure.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/sync/data_versions.dart';
import '../../../../core/widgets/data_versions_listener.dart';
import '../../../data/users_repository.dart';
import 'access_common.dart';
import 'position_dialogs.dart';
import 'position_row.dart';
import '../ui/portal_annotated_section.dart';
import '../ui/portal_button.dart';

/// Раздел «Должности» в настройках портала (ADHOC-50).
///
/// Что: должности и их права — завести, изменить, удалить пустую. «Администратор» — все права,
/// не меняется. Сохранение, которое оставило бы систему без управления пользователями, сервер
/// отклоняет с объяснением — оно показывается под списком.
/// [changes] — общий счётчик правок раздела «Пользователи»: число людей на должностях меняется
/// оттуда, и список перечитывается.
class PositionsSection extends StatefulWidget {
  const PositionsSection({super.key, required this.changes});

  final ValueNotifier<int> changes;

  @override
  State<PositionsSection> createState() => _PositionsSectionState();
}

class _PositionsSectionState extends State<PositionsSection> {
  final _repo = getIt<UsersRepository>();

  List<PortalPosition>? _items;
  bool _loading = true;

  /// Должность, с которой идёт действие; пустая строка — заводится новая.
  String? _busyId;
  String? _error;

  @override
  void initState() {
    super.initState();
    widget.changes.addListener(load);
    load();
  }

  @override
  void dispose() {
    widget.changes.removeListener(load);
    super.dispose();
  }

  /// Перечитать список с сервера.
  Future<void> load() async {
    setState(() => _loading = true);
    final res = await _repo.positions();
    if (!mounted) return;
    setState(() {
      _loading = false;
      res.fold((f) => _error = accessErrorText(f), (items) {
        _items = items;
        _error = null;
      });
    });
  }

  /// Завести должность.
  Future<void> create() async {
    final d = await showPositionDialog(context);
    if (d == null || !mounted) return;
    await _run('', () => _repo.createPosition(d.name, d.rights));
  }

  /// Изменить название и права.
  Future<void> edit(PortalPosition p) async {
    final d = await showPositionDialog(
      context,
      current: (name: p.name, rights: p.rights),
    );
    if (d == null || !mounted) return;
    await _run(p.id, () => _repo.updatePosition(p.id, d.name, d.rights));
  }

  /// Удалить должность без пользователей — после подтверждения.
  Future<void> delete(PortalPosition p) async {
    if (!await showDeletePositionDialog(context, name: p.name) || !mounted) {
      return;
    }
    await _run(p.id, () => _repo.deletePosition(p.id));
  }

  /// Выполнить действие; успех — сигнал разделу «Пользователи» (там видны названия) и
  /// перечитать свой список.
  Future<void> _run(
    String id,
    Future<Either<Failure, Object?>> Function() action,
  ) async {
    setState(() {
      _busyId = id;
      _error = null;
    });
    final res = await action();
    if (!mounted) return;
    setState(() => _busyId = null);
    if (res.isLeft) {
      setState(() => _error = accessErrorText(res.left));
      return;
    }
    widget.changes.value++;
  }

  /// Настройки изменились на сервере (ADHOC-60): перечитать список. Пока идёт своё действие,
  /// не перечитывать — оно само перечитает список по завершении. Правка в открытом окне не
  /// страдает: окно держит свою копию данных, а список под ним остаётся на экране до ответа.
  void onDataChanged() {
    if (_busyId != null) return;
    load();
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    return DataVersionsListener(
      domains: const {DataDomain.settings},
      onChanged: onDataChanged,
      child: PortalAnnotatedSection(
        title: t.portal.positions.title,
        description: t.portal.positions.description,
        action: PortalButton(
          label: t.portal.positions.add,
          icon: Icons.add,
          busy: _busyId == '',
          onPressed: create,
        ),
        child: SettingsListCard(
          loading: _loading && items == null,
          error: _error,
          rows: [
            for (final p in items ?? const <PortalPosition>[])
              PositionRow(
                position: p,
                busy: _busyId == p.id,
                onEdit: () => edit(p),
                onDelete: () => delete(p),
              ),
          ],
        ),
      ),
    );
  }
}
