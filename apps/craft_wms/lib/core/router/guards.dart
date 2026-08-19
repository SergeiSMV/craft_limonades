import 'package:auto_route/auto_route.dart';
import 'package:injectable/injectable.dart';

import '../auth/auth_cubit.dart';

/// Гард защищённых роутов: пускает только аутентифицированного пользователя.
/// Фактический редирект на вход делает BlocListener в app.dart; гард отсекает прямой заход.
@injectable
class AuthGuard extends AutoRouteGuard {
  AuthGuard(this._auth);

  final AuthCubit _auth;

  /// Пропускает переход только если пользователь аутентифицирован; иначе auto_route отклоняет
  /// маршрут (роутер уводит на вход).
  @override
  void onNavigation(NavigationResolver resolver, StackRouter router) {
    resolver.next(_auth.state is AuthAuthenticated);
  }
}
