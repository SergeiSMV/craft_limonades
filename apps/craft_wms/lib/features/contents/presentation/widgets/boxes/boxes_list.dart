import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../../core/constants/app_insets.dart';
import '../../../../../core/constants/app_sizes.dart';
import '../../../../../core/gen/strings.g.dart';
import '../../../../../core/router/app_router.dart';
import '../../../../../core/widgets/error_retry.dart';
import '../../../domain/contents_entities.dart';
import '../../bloc/boxes_cubit.dart';
import '../common/box_list_tile.dart';
import '../common/contents_message.dart';
import '../common/freshness_note.dart';

/// Вкладка «Короба» в «Остатках» (P5-05-1): короба склада или выдача поиска по короткому коду.
/// Тянется вниз — обновить снимок и перечитать.
class BoxesList extends StatelessWidget {
  const BoxesList({super.key});

  /// Обновить снимок с сервера и перечитать.
  Future<void> reload(BuildContext context) =>
      context.read<BoxesCubit>().reload();

  /// Открыть карточку короба.
  void openLoadUnit(BuildContext context, LoadUnitView lu) =>
      context.router.push(LoadUnitRoute(loadUnitId: lu.id));

  @override
  Widget build(BuildContext context) {
    final state = context.watch<BoxesCubit>().state;
    switch (state.status) {
      // Вкладку ещё не открывали — она живёт в IndexedStack невидимой, и крутилка вертелась
      // бы впустую с самого входа в «Остатки».
      case BoxesStatus.initial:
        return const SizedBox.shrink();
      case BoxesStatus.loading:
        return const Center(
          child: SizedBox(
            height: AppSizes.kIcon18,
            width: AppSizes.kIcon18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        );
      case BoxesStatus.failed:
        // Прокручиваемо: при открытой клавиатуре высоты под картинку ошибки не хватает,
        // и она переполняла экран (найдено на DT50S).
        return LayoutBuilder(
          builder: (context, box) => SingleChildScrollView(
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: box.maxHeight),
              child: ErrorRetry(onRetry: () => reload(context)),
            ),
          ),
        );
      case BoxesStatus.ready:
        break;
    }

    final data = state.data;
    final units = state.invalidQuery
        ? const <LoadUnitView>[]
        : data?.value ?? [];
    final String? message = state.invalidQuery
        ? t.contents.shortCodeInvalid
        : units.isNotEmpty
        ? null
        : state.searching
        ? t.contents.boxesNotFound(code: state.query.trim())
        : t.contents.boxesEmpty;

    return RefreshIndicator(
      onRefresh: () => reload(context),
      child: ListView.builder(
        // Отступы — у плашек, как в списке товаров: тень неоморфной плашки не режется краем.
        padding: EdgeInsets.zero,
        physics: const AlwaysScrollableScrollPhysics(),
        // Первый элемент — подпись о снимке и сообщение, дальше короба.
        itemCount: units.length + 1,
        itemBuilder: (context, i) {
          if (i == 0) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              // Подпись и сообщения — с отступами списка, плашки задают свои сами.
              children: [
                if (data != null && !state.invalidQuery)
                  Padding(
                    padding: AppInsets.h8 + AppInsets.top8,
                    child: FreshnessNote(freshness: data.freshness),
                  ),
                if (message != null) ContentsMessage(text: message),
              ],
            );
          }
          final lu = units[i - 1];
          return Padding(
            padding: AppInsets.h8 + AppInsets.bottom8,
            child: BoxListTile(
              loadUnit: lu,
              onTap: () => openLoadUnit(context, lu),
            ),
          );
        },
      ),
    );
  }
}
