import 'package:either_dart/either.dart';
import 'package:flutter/material.dart';

import '../../../../core/di/injection.dart';
import '../../../../core/error/failure.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../data/users_repository.dart';
import 'access_common.dart';
import 'user_dialogs.dart';
import 'user_row.dart';
import '../ui/portal_annotated_section.dart';
import '../ui/portal_button.dart';

/// Раздел «Пользователи» в настройках портала (ADHOC-50).
///
/// Что: кто входит в портал и на ТСД — завести (бейдж или логин с паролем), изменить ФИО и
/// должность, выдать новый бейдж или пароль взамен прежнего, заблокировать или вернуть.
/// Последнего администратора и себя заблокировать сервер не даст — объяснение под списком.
/// [changes] — общий счётчик правок с разделом «Должности»: названия должностей и число людей
/// на них перечитываются после правки в любом из двух разделов. [selfId] — вошедший оператор.
class UsersSection extends StatefulWidget {
  const UsersSection({super.key, required this.changes, required this.selfId});

  final ValueNotifier<int> changes;
  final String selfId;

  @override
  State<UsersSection> createState() => _UsersSectionState();
}

class _UsersSectionState extends State<UsersSection> {
  final _repo = getIt<UsersRepository>();

  List<PortalUser>? _items;
  List<PortalPosition> _positions = const [];
  bool _loading = true;

  /// Пользователь, с которым идёт действие; пустая строка — заводится новый.
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

  /// Перечитать пользователей и должности (для выбора в диалоге).
  Future<void> load() async {
    setState(() => _loading = true);
    final users = await _repo.users();
    final positions = await _repo.positions();
    if (!mounted) return;
    setState(() {
      _loading = false;
      _error = null;
      users.fold((f) => _error = accessErrorText(f), (items) => _items = items);
      positions.fold(
        (f) => _error = accessErrorText(f),
        (items) => _positions = items,
      );
    });
  }

  /// Завести пользователя.
  Future<void> create() async {
    final d = await showCreateUserDialog(context, positions: _positions);
    if (d == null || !mounted) return;
    await _run('', () => _repo.createUser(d));
  }

  /// Изменить ФИО и должность.
  Future<void> edit(PortalUser u) async {
    final d = await showEditUserDialog(
      context,
      positions: _positions,
      current: u,
    );
    if (d == null || !mounted) return;
    await _run(
      u.id,
      () => _repo.updateUser(
        u.id,
        fullName: d.fullName == u.fullName ? null : d.fullName,
        positionId: d.positionId == u.positionId ? null : d.positionId,
      ),
    );
  }

  /// Выдать новый бейдж или пароль — того же вида, что прежний вход.
  Future<void> newSecret(PortalUser u) async {
    final value = await showNewSecretDialog(context, badge: u.byBadge);
    if (value == null || !mounted) return;
    await _run(
      u.id,
      () => u.byBadge
          ? _repo.updateUser(u.id, badge: value)
          : _repo.updateUser(u.id, password: value),
    );
  }

  /// Заблокировать или вернуть доступ.
  Future<void> toggle(PortalUser u) =>
      _run(u.id, () => _repo.updateUser(u.id, isActive: !u.isActive));

  /// Выполнить действие; успех — перечитать оба раздела через общий счётчик.
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
    return PortalAnnotatedSection(
      title: t.portal.users.title,
      description: t.portal.users.description,
      action: PortalButton(
        label: t.portal.users.add,
        icon: Icons.add,
        busy: _busyId == '',
        onPressed: create,
      ),
      child: SettingsListCard(
        loading: _loading && items == null,
        error: _error,
        rows: [
          for (final u in items ?? const <PortalUser>[])
            UserRow(
              user: u,
              self: u.id == widget.selfId,
              busy: _busyId == u.id,
              onEdit: () => edit(u),
              onNewSecret: () => newSecret(u),
              onToggle: () => toggle(u),
            ),
        ],
      ),
    );
  }
}
