# Правила R8 релизной сборки ТСД.

# ADHOC-69: ошибки SDK RuStore доходят до Dart именем класса (PlatformException.message) и
# пишутся в журнал приложения - по нему видно, почему обновление недоступно (нет RuStore, нет
# входа в RuStore и т.д.). Свои правила SDK сохраняют только ошибки установки, а классы
# ru.rustore.sdk.core.exception R8 переименовывает в «c». Сохраняем только имена, код сжимается.
-keepnames class ru.rustore.sdk.core.exception.** { *; }
