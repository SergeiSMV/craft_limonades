import 'package:either_dart/either.dart';
import 'package:flutter/material.dart';

import '../../../../core/constants/app_boxes.dart';
import '../../../../core/di/injection.dart';
import '../../../../core/error/failure.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../data/users_repository.dart';
import '../common/neumorphic_plate.dart';
import '../common/neumorphic_text_button.dart';
import 'access_common.dart';
import 'position_dialogs.dart';
import 'position_row.dart';

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

  @override
  Widget build(BuildContext context) {
    final items = _items;
    return NeumorphicPlate(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AccessSectionHeader(
            title: t.portal.positions.title,
            description: t.portal.positions.description,
            action: NeumorphicTextButton(
              label: t.portal.positions.add,
              icon: Icons.add,
              accent: true,
              busy: _busyId == '',
              onPressed: create,
            ),
          ),
          AppBoxes.kHeight16,
          if (_loading && items == null)
            const Center(child: CircularProgressIndicator())
          else
            for (final p in items ?? const <PortalPosition>[])
              PositionRow(
                position: p,
                busy: _busyId == p.id,
                onEdit: () => edit(p),
                onDelete: () => delete(p),
              ),
          if (_error != null) ...[AppBoxes.kHeight16, AccessError(_error!)],
        ],
      ),
    );
  }
}
