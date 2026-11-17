import 'package:flutter/material.dart';

import '../../../../core/constants/app_boxes.dart';
import '../../../../core/constants/app_colors.dart';
import '../../../../core/constants/app_sizes.dart';
import '../../../../core/gen/strings.g.dart';
import '../../../../core/theme/regular_text.dart';
import '../../../data/users_repository.dart';
import '../ui/portal_modal.dart';
import '../ui/portal_input.dart';
import '../ui/portal_button.dart';
import '../ui/portal_choice.dart';

/// ФИО и должность при правке пользователя.
typedef UserEdit = ({String fullName, String positionId});

/// Диалог «Новый пользователь» (ADHOC-50): ФИО, должность и вход - бейдж или логин с паролем.
/// `null` - оператор передумал.
Future<UserDraft?> showCreateUserDialog(
  BuildContext context, {
  required List<PortalPosition> positions,
}) async =>
    await showDialog<Object>(
          context: context,
          builder: (_) => _UserDialog(positions: positions),
        )
        as UserDraft?;

/// Диалог правки пользователя: ФИО и должность; вход меняется отдельными действиями.
Future<UserEdit?> showEditUserDialog(
  BuildContext context, {
  required List<PortalPosition> positions,
  required PortalUser current,
}) async =>
    await showDialog<Object>(
          context: context,
          builder: (_) => _UserDialog(positions: positions, current: current),
        )
        as UserEdit?;

class _UserDialog extends StatefulWidget {
  const _UserDialog({required this.positions, this.current});

  final List<PortalPosition> positions;
  final PortalUser? current;

  @override
  State<_UserDialog> createState() => _UserDialogState();
}

class _UserDialogState extends State<_UserDialog> {
  late final _name = TextEditingController(text: widget.current?.fullName);
  final _badge = TextEditingController();
  final _username = TextEditingController();
  final _password = TextEditingController();

  /// Должность: у нового - «Кладовщик» или первая не системная, если есть.
  late String _positionId =
      widget.current?.positionId ??
      (widget.positions.where((p) => !p.isSystem).firstOrNull ??
              widget.positions.firstOrNull)
          ?.id ??
      '';

  /// Вход нового пользователя: бейдж - по умолчанию, на складе он у всех.
  bool _byBadge = true;

  /// Выбрать должность.
  void selectPosition(String id) => setState(() => _positionId = id);

  /// Выбрать способ входа.
  void selectBadge(bool byBadge) => setState(() => _byBadge = byBadge);

  /// Сохранить: правка - ФИО и должность; новый - с входом выбранного вида.
  void submit() {
    final name = _name.text.trim();
    if (widget.current != null) {
      Navigator.of(context).pop((fullName: name, positionId: _positionId));
      return;
    }
    final UserDraft draft = (
      fullName: name,
      positionId: _positionId,
      badge: _byBadge ? _badge.text.trim() : null,
      username: _byBadge ? null : _username.text.trim(),
      password: _byBadge ? null : _password.text,
    );
    Navigator.of(context).pop(draft);
  }

  @override
  void dispose() {
    _name.dispose();
    _badge.dispose();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final editing = widget.current != null;
    return PortalModal(
      title: editing ? t.portal.users.editTitle : t.portal.users.createTitle,
      content: _Body(
        children: [
          PortalInput(
            controller: _name,
            hint: t.portal.users.nameHint,
            autofocus: !editing,
          ),
          AppBoxes.kHeight16,
          PortalFieldLabel(t.portal.users.positionLabel),
          Wrap(
            spacing: AppSizes.kChipSpacing,
            runSpacing: AppSizes.kChipSpacing,
            children: [
              for (final p in widget.positions)
                PortalChoice(
                  label: p.name,
                  selected: p.id == _positionId,
                  onTap: () => selectPosition(p.id),
                ),
            ],
          ),
          if (!editing) ...[
            AppBoxes.kHeight16,
            PortalFieldLabel(t.portal.users.loginLabel),
            Wrap(
              spacing: AppSizes.kChipSpacing,
              children: [
                PortalChoice(
                  label: t.portal.users.byBadge,
                  selected: _byBadge,
                  onTap: () => selectBadge(true),
                ),
                PortalChoice(
                  label: t.portal.users.byPassword,
                  selected: !_byBadge,
                  onTap: () => selectBadge(false),
                ),
              ],
            ),
            AppBoxes.kHeight16,
            if (_byBadge) ...[
              PortalInput(
                controller: _badge,
                hint: t.portal.users.badgeHint,
                onSubmitted: (_) => submit(),
              ),
              AppBoxes.kHeight8,
              _Help(t.portal.users.badgeHelp),
            ] else ...[
              PortalInput(
                controller: _username,
                hint: t.portal.users.usernameHint,
              ),
              AppBoxes.kHeight16,
              PortalInput(
                controller: _password,
                hint: t.portal.users.passwordHint,
                obscureText: true,
                onSubmitted: (_) => submit(),
              ),
            ],
          ],
        ],
      ),
      actions: [
        portalCancel(context, label: t.portal.users.cancel),
        PortalButton(
          label: editing ? t.portal.users.save : t.portal.users.create,
          kind: PortalButtonKind.primary,
          onPressed: submit,
        ),
      ],
    );
  }
}

/// Диалог нового входа взамен прежнего: бейдж ([badge] = true) или пароль. Возвращает
/// введённое; `null` - оператор передумал.
Future<String?> showNewSecretDialog(
  BuildContext context, {
  required bool badge,
}) {
  final value = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (ctx) {
      void submit() =>
          Navigator.of(ctx).pop(badge ? value.text.trim() : value.text);
      return PortalModal(
        title: badge
            ? t.portal.users.newBadgeTitle
            : t.portal.users.newPasswordTitle,
        content: _Body(
          children: [
            PortalInput(
              controller: value,
              hint: badge
                  ? t.portal.users.badgeHint
                  : t.portal.users.newPasswordHint,
              autofocus: true,
              obscureText: !badge,
              onSubmitted: (_) => submit(),
            ),
            if (badge) ...[AppBoxes.kHeight8, _Help(t.portal.users.badgeHelp)],
          ],
        ),
        actions: [
          portalCancel(ctx, label: t.portal.users.cancel),
          PortalButton(
            label: t.portal.users.save,
            kind: PortalButtonKind.primary,
            onPressed: submit,
          ),
        ],
      );
    },
  );
}

/// Подсказка под полем.
class _Help extends StatelessWidget {
  const _Help(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: RegularTextStyles().regularInter12.copyWith(
      color: AppColors.kTextMuted,
    ),
  );
}

/// Содержимое диалога - не шире половины колонки, как диалоги складов.
class _Body extends StatelessWidget {
  const _Body({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: const BoxConstraints(maxWidth: AppSizes.kContentMaxWidth / 2),
    child: SizedBox(
      width: double.maxFinite,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    ),
  );
}
