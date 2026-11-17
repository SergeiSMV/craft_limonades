import 'package:flutter/services.dart';
import 'package:flutter_neumorphic_plus/flutter_neumorphic.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';

import '../constants/app_borders.dart';
import '../constants/app_boxes.dart';
import '../constants/app_colors.dart';
import '../constants/app_insets.dart';
import '../constants/app_sizes.dart';
import '../di/injection.dart';
import '../gen/strings.g.dart';
import '../scanner/hardware_scan_listener.dart';
import '../scanner/scan_code.dart';
import '../scanner/scan_deduper.dart';
import '../theme/regular_text.dart';
import '../theme/semibold_text.dart';
import '../../features/stock/data/catalog_models.dart';
import '../../features/stock/data/catalog_repository.dart';

/// Нижний лист смены ячейки (коррекция «не та ячейка»): высокий лист с полем сверху и встроенным
/// прокручиваемым списком ячеек (локальная prefix-фильтрация). В отличие от инлайн-автокомплита на
/// экране выбора, здесь список НЕ оверлей (в нижнем листе поле у низа - оверлею некуда развернуться),
/// а обычный список во всю высоту над клавиатурой. По выбору/скану возвращает ячейку через `pop`.
///
/// Общий для «Ввода остатков» и приёмки (P4-09): в обоих потоках ячейку меняют одинаково -
/// сканом этикетки или набором адреса. Заголовок у каждого свой.
class CellChangeSheet extends StatefulWidget {
  const CellChangeSheet({super.key, this.title});

  /// Заголовок листа; `null` - «Сменить ячейку».
  final String? title;

  @override
  State<CellChangeSheet> createState() => _CellChangeSheetState();
}

class _CellChangeSheetState extends State<CellChangeSheet>
    with HardwareScanListener {
  /// Репозиторий каталога - источник списка ячеек.
  final _repo = getIt<CatalogRepository>();

  /// Контроллер поля поиска/скана; слушатель на нём триггерит фильтрацию.
  final _controller = TextEditingController();

  /// Отсекает дубль, если устройство отдаёт код и в поле, и интентом.
  final _deduper = ScanDeduper();

  /// Фокус поля - используется для автофокуса и возврата фокуса после действий.
  final _focusNode = FocusNode();

  /// Полный список ячеек с сервера - источник для локальной фильтрации.
  List<Cell> _all = const [];

  /// Ячейки после prefix-фильтрации по текущему запросу - то, что выводится в списке.
  List<Cell> _filtered = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onQueryChanged);
    _load();
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  /// Загрузить весь справочник ячеек склада для локального фильтра.
  Future<void> _load() async {
    final res = await _repo.listAllCells();
    if (!mounted) return;
    setState(() {
      _loading = false;
      _all = res.fold((_) => const [], (c) => c);
      // Список скрыт, пока не введён адрес (пустой ввод → ничего не показываем).
    });
    if (res.isLeft) _snack(t.cellPicker.loadFailed);
  }

  /// Пересчитать список по вводу: пусто → список скрыт; иначе - адреса, начинающиеся с ввода (prefix).
  void _onQueryChanged() {
    final q = _controller.text.trim().toLowerCase();
    setState(() {
      _filtered = q.isEmpty
          ? const []
          : _all.where((c) => c.address.toLowerCase().startsWith(q)).toList();
    });
  }

  /// Резолв адреса (скан/Enter) по справочнику; найдено точное совпадение → вернуть ячейку.
  /// Код с аппаратного сканера (intent-режим). До ADHOC-07 лист не был подписан на поток:
  /// сканы доставляются верхнему экрану стопки, а нижний лист экраном не является, и в
  /// intent-режиме смена ячейки сканом молча не работала - только ручным вводом.
  @override
  void onHardwareScan(ScanCode code) {
    final raw = code.raw.trim();
    if (raw.isEmpty || !_deduper.allow(raw)) return;
    _controller.text = raw;
    _onSubmit(raw);
  }

  void _onSubmit(String value) {
    final a = value.trim().toLowerCase();
    if (a.isEmpty) return;
    for (final c in _all) {
      if (c.address.toLowerCase() == a) {
        Navigator.of(context).pop(c);
        return;
      }
    }
    _snack(t.cellPicker.notFound);
  }

  void _snack(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    // Лист сжат по контенту: пустой ввод → только заголовок + поле; появились варианты → секция
    // результатов растёт вниз (поле «поднимается») до половины свободной высоты, список прокручивается.
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Padding(
        padding: AppInsets.h8 + AppInsets.bottom24,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: AppInsets.h8,
              child: Text(
                widget.title ?? t.cellPicker.title,
                style: SemiboldTextStyles().semiboldInter18,
              ),
            ),
            AppBoxes.kHeight12,
            _field(),
            ..._results(context),
          ],
        ),
      ),
    );
  }

  /// Неоморф-поле адреса (вдавленное); ввод сканером/руками, submit → [_onSubmit].
  Widget _field() {
    return Padding(
      padding: AppInsets.h8,
      child: Neumorphic(
        style: NeumorphicStyle(
          shadowLightColor: AppColors.kNeumorphicLight,
          shadowDarkColor: AppColors.kNeumorphicDark,
          intensity: 1,
          color: AppColors.kNeumorphicBg,
          depth: -2,
          shape: NeumorphicShape.flat,
        ),
        child: TextField(
          controller: _controller,
          focusNode: _focusNode,
          autofocus: true,
          cursorColor: AppColors.kTextMuted,
          cursorWidth: 1.5,
          cursorHeight: 20,
          textInputAction: TextInputAction.done,
          // Свернули клавиатуру - поле сохраняет фокус; по тапу принудительно показываем её снова.
          onTap: () {
            if (_focusNode.hasFocus) {
              SystemChannels.textInput.invokeMethod<void>('TextInput.show');
            }
          },
          onSubmitted: _onSubmit,
          decoration: InputDecoration(
            prefixIcon: Icon(
              MdiIcons.barcode,
              size: AppSizes.kIcon25,
              color: AppColors.kTextMuted,
            ),
            hintText: t.cellPicker.hint,
            hintStyle: RegularTextStyles().regularInter16.copyWith(
              color: AppColors.kBorderDashed,
            ),
            border: const OutlineInputBorder(
              borderRadius: AppBorders.kCircular8,
              borderSide: BorderSide.none,
            ),
            isDense: true,
          ),
        ),
      ),
    );
  }

  /// Секция результатов под полем. Пустой ввод → секции нет (лист компактный, поле не поднимается);
  /// идёт загрузка / нет совпадений → компактный индикатор/подпись; есть варианты → прокручиваемый
  /// список (неоморф-плитки, как в «Остатках»), высотой до половины свободного места.
  List<Widget> _results(BuildContext context) {
    if (_controller.text.trim().isEmpty) return const [];
    if (_loading) {
      return const [
        AppBoxes.kHeight8,
        Padding(
          padding: AppInsets.v16,
          child: Center(child: CircularProgressIndicator()),
        ),
      ];
    }
    if (_filtered.isEmpty) {
      return [
        AppBoxes.kHeight8,
        Padding(
          padding: AppInsets.v16,
          child: Center(child: Text(t.cellPicker.nothingFound)),
        ),
      ];
    }
    final maxHeight =
        (MediaQuery.of(context).size.height -
            MediaQuery.of(context).viewInsets.bottom) *
        0.5;
    return [
      AppBoxes.kHeight8,
      ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: ListView.builder(
          padding: EdgeInsets.zero,
          shrinkWrap: true,
          itemCount: _filtered.length,
          itemBuilder: (context, i) => _tile(_filtered[i]),
        ),
      ),
    ];
  }

  /// Неоморф-плитка ячейки (как в «Остатках»); тап → выбор.
  Widget _tile(Cell c) {
    return Padding(
      padding: AppInsets.all8,
      child: Neumorphic(
        style: NeumorphicStyle(
          shadowLightColor: AppColors.kNeumorphicLight,
          shadowDarkColor: AppColors.kNeumorphicDark,
          intensity: 1,
          color: AppColors.kNeumorphicBg,
          depth: 3,
          shape: NeumorphicShape.flat,
          boxShape: NeumorphicBoxShape.roundRect(AppBorders.kCircular8),
        ),
        child: ListTile(
          dense: true,
          title: Row(
            children: [
              Text(c.address, style: RegularTextStyles().regularInter14),
              AppBoxes.kWidth8,
              if (c.isFloor)
                Icon(
                  MdiIcons.arrowDownBold,
                  size: AppSizes.kIcon20,
                  color: AppColors.kTextMuted,
                ),
            ],
          ),
          onTap: () => Navigator.of(context).pop(c),
        ),
      ),
    );
  }
}
