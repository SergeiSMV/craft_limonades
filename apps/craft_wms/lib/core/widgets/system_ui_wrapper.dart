import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Стиль иконок/текста системного статусбара.
/// [light] — светлые (белые) иконки (для тёмного фона),
/// [dark] — тёмные (чёрные) иконки (для светлого фона).
enum StatusBarStyle { light, dark }

/// Обёртка, задающая стиль системного статусбара для экрана.
///
/// Что: оборачивает любой Scaffold и выставляет цвет иконок/текста статусбара.
/// Зачем: на тёмных брендовых экранах (splash/login) нужен светлый статусбар,
///        на светлых — тёмный; единое место вместо дублей SystemUiOverlayStyle.
/// Как: AnnotatedRegion применяет стиль, пока экран на переднем плане.
///
/// Пример:
/// ```dart
/// SystemUiWrapper(
///   style: StatusBarStyle.light,
///   child: Scaffold(...),
/// );
/// ```
class SystemUiWrapper extends StatelessWidget {
  const SystemUiWrapper({
    super.key,
    required this.child,
    this.style = StatusBarStyle.dark,
  });

  /// Оборачиваемый экран (обычно Scaffold).
  final Widget child;

  /// Светлый (белые иконки) или тёмный (чёрные иконки) статусбар.
  final StatusBarStyle style;

  @override
  Widget build(BuildContext context) {
    // Важно: во Flutter Brightness.light = СВЕТЛЫЕ (белые) иконки — контринтуитивно.
    final isLight = style == StatusBarStyle.light;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        // Android: цвет иконок/текста статусбара.
        statusBarIconBrightness: isLight ? Brightness.light : Brightness.dark,
        // iOS: яркость «фона» статусбара (обратная логика к иконкам).
        statusBarBrightness: isLight ? Brightness.dark : Brightness.light,
      ),
      child: child,
    );
  }
}
