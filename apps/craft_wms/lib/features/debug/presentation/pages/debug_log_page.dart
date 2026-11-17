import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:talker_flutter/talker_flutter.dart';

import '../../../../core/di/injection.dart';

/// Экран логов на устройстве (talker_flutter). Показывает всё, что пишут dio- и bloc-логгеры.
/// Для ТСД критично: терминал в руках, без консоли - а тут видно, что пошло не так.
/// Позже спрячем за жест/роль admin.
@RoutePage()
class DebugLogPage extends StatelessWidget {
  const DebugLogPage({super.key});

  @override
  Widget build(BuildContext context) {
    return TalkerScreen(talker: getIt<Talker>());
  }
}
