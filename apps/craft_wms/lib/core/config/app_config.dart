import 'package:flutter/foundation.dart';

import '../constants/api_constants.dart';

/// Режим приложения ТСД (ADHOC-67): рабочий сервер или демо-сервер с выдуманным складом.
enum AppMode { work, demo }

/// Конфигурация приложения из dart-define (`--dart-define-from-file=.env`).
///
/// Зачем: один код собирается против разных бэкендов (эмулятор/сервер) без правок -
/// адрес берётся из `.env` (в `.gitignore`, свой на каждой машине/окружении).
class AppConfig {
  /// Текущий режим. Читается из хранилища до сборки зависимостей (`AppModeSwitch.load` в
  /// `main`) и до перезапуска процесса не меняется: от него зависят адрес сервера, файл
  /// локальной базы и ключи токенов, а все они живут в синглтонах.
  static AppMode mode = AppMode.work;

  /// Приложение работает с демо-сервером.
  static bool get isDemo => mode == AppMode.demo;

  /// Сборка тестового стенда (`--dart-define=STAND=true`, пакет `…sklad.stand`, ADHOC-39).
  /// Стенда нет в RuStore, поэтому обновление из магазина в нём не проверяется (ADHOC-69).
  static const bool isStand = bool.fromEnvironment('STAND');

  /// Адрес API демо-сервера (`DEMO_BASE_URL` в dart-define); пусто - демо-режима в сборке нет.
  static String get demoBaseUrl {
    const value = String.fromEnvironment('DEMO_BASE_URL');
    return value.isEmpty ? '' : '${value.replaceAll(RegExp(r'/+$'), '')}/';
  }

  /// Можно ли перейти в демо: только ТСД (портал демо - свой адрес) и только если адрес задан.
  static bool get demoAvailable => !kIsWeb && demoBaseUrl.isNotEmpty;

  /// Базовый URL бэкенда с префиксом `/api/v1/`. В демо-режиме - [demoBaseUrl].
  /// (прикладной API живёт под ним, ADR-0015).
  /// Значение - из `.env` по ключу [ApiConst.kBaseUrl]; дефолт - локальный эмулятор.
  /// Гарантируем завершающий `/`: маршруты в коде - без ведущего `/` (см. [ApiConst]),
  /// поэтому dio склеивает `baseUrl` + `path` в корректный URL без двойного слэша.
  static String get baseUrl {
    if (isDemo && demoAvailable) return demoBaseUrl;
    const value = String.fromEnvironment(
      ApiConst.kBaseUrl,
      defaultValue: 'http://10.0.2.2:8080/api/v1/',
    );
    // Срезаем любые завершающие `/` и добавляем ровно один: устойчиво к тому, как
    // записан URL в .env (с/без слэша, случайный двойной), без двойного слэша в запросах.
    return '${value.replaceAll(RegExp(r'/+$'), '')}/';
  }

  /// Политика конфиденциальности (ADHOC-66): страница `privacy.html` веб-портала.
  /// Портал живёт на том же origin, что и API (ADR-0015), поэтому адрес выводится из [baseUrl],
  /// а не задаётся отдельно: боевая сборка откроет страницу прода, сборка стенда - стенда.
  static String get privacyPolicyUrl =>
      Uri.parse(baseUrl).resolve('/privacy.html').toString();

  /// Название склада для шапки ТСД. На пилоте склад один («Шабулина») - берём из dart-define
  /// (`WAREHOUSE_NAME` в `.env`), с дефолтом. ⚠ Плейсхолдер: при мультискладе/привязке устройства
  /// склад должен приходить из профиля/конфига устройства, а не из константы клиента.
  static String get warehouseName =>
      const String.fromEnvironment('WAREHOUSE_NAME', defaultValue: 'Шабулина');
}
