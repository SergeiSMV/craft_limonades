import 'dart:async';

import 'package:flutter/material.dart';

import '../di/injection.dart';
import 'scan_code.dart';
import 'scanner_service.dart';

/// Подписка экрана на аппаратный сканер: подмешивается в `State` и зовёт [onHardwareScan]
/// на каждый код, пока экран в дереве.
///
/// Зачем миксин, а не виджет-обёртка: в клавиатурном режиме код прилетает в сфокусированное поле,
/// а в intent-режиме — в приложение целиком, мимо дерева виджетов. Подписка ничего не рисует,
/// поэтому и место ей в состоянии экрана, а не в разметке — обёртка добавляла бы уровень вложенности
/// вокруг всего `build` ради поведения, которое к вёрстке отношения не имеет.
///
/// Код доставляется только когда экран верхний в стопке (`ModalRoute.isCurrent`): иначе стопка
/// экранов (список товаров → карточка) обработала бы один скан несколько раз. По той же причине
/// сканы не доходят до экрана, пока над ним открыт диалог или нижний лист.
mixin HardwareScanListener<T extends StatefulWidget> on State<T> {
  StreamSubscription<ScanCode>? _scanSubscription;

  /// Обработчик кода — реализует экран.
  void onHardwareScan(ScanCode code);

  /// Приём кодов включён. Экран может выключить его на время своего особого режима.
  bool get hardwareScanEnabled => true;

  @override
  void initState() {
    super.initState();
    _scanSubscription = getIt<ScannerService>().scans.listen(_deliver);
  }

  @override
  void dispose() {
    _scanSubscription?.cancel();
    super.dispose();
  }

  /// Доставка кода экрану, если приём включён и экран сейчас верхний в стопке.
  void _deliver(ScanCode code) {
    if (!mounted || !hardwareScanEnabled) return;
    final route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) return;
    onHardwareScan(code);
  }
}
