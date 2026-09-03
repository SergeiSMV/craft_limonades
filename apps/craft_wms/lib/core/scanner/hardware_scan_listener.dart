import 'package:flutter/material.dart';

import '../di/injection.dart';
import 'scan_code.dart';
import 'scan_router.dart';

/// Подписка экрана или диалога на аппаратный сканер: подмешивается в `State` и зовёт
/// [onHardwareScan] на каждый код, пока подписчик верхний в стопке.
///
/// Зачем миксин, а не виджет-обёртка: в клавиатурном режиме код прилетает в сфокусированное поле,
/// а в intent-режиме — в приложение целиком, мимо дерева виджетов. Подписка ничего не рисует,
/// поэтому и место ей в состоянии, а не в разметке — обёртка добавляла бы уровень вложенности
/// вокруг всего `build` ради поведения, которое к вёрстке отношения не имеет.
///
/// Раздачей занимается [ScanRouter] (ADHOC-08): раньше каждый подписчик слушал поток сам и сам
/// решал, его ли это код. Правило «мой ли скан» жило в каждом подписчике, а случая «код не взял
/// никто» не существовало — скан исчезал бесследно.
///
/// **Подмешивать нужно и в диалоги с нижние листы, а не только в экраны.** Модальный слой
/// становится верхним в стопке, и без подписки код не получит ни он, ни экран под ним:
/// экран перестаёт быть текущим. Ровно так терялись сканы в диалоге привязки ШК (ADHOC-07).
mixin HardwareScanListener<T extends StatefulWidget> on State<T>
    implements ScanConsumer {
  /// Обработчик кода — реализует экран или диалог.
  void onHardwareScan(ScanCode code);

  /// Приём кодов включён. Подписчик может выключить его на время своего особого режима.
  bool get hardwareScanEnabled => true;

  /// Готов ли взять код: виджет в дереве, приём включён и подписчик верхний в стопке
  /// маршрутов. Без проверки маршрута стопка «список товаров → карточка» обработала бы
  /// один скан дважды.
  @override
  bool get canAcceptScan {
    if (!mounted || !hardwareScanEnabled) return false;
    final route = ModalRoute.of(context);
    return route == null || route.isCurrent;
  }

  @override
  bool acceptScan(ScanCode code) {
    onHardwareScan(code);
    return true;
  }

  @override
  void initState() {
    super.initState();
    getIt<ScanRouter>().register(this);
  }

  @override
  void dispose() {
    getIt<ScanRouter>().unregister(this);
    super.dispose();
  }
}
