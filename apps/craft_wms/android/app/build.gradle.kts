import java.util.Base64
import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Сборка для тестового стенда (ADHOC-39, долг 28): `flutter build apk --dart-define=STAND=true`.
// Что: отдельный идентификатор приложения и своя подпись на рабочем столе.
// Зачем: под одним идентификатором APK стенда вставала поверх боевой, а очередь операций
//        переживает переустановку — неотправленное против стенда уходило на прод и наоборот.
// Как: Flutter передаёт dart-define в Gradle свойством `dart-defines` (пары KEY=VALUE в base64
//      через запятую); flavor не заводим, чтобы боевой сборке не понадобился `--flavor`.
val dartDefines: Map<String, String> =
    (project.findProperty("dart-defines") as String?)
        ?.split(",")
        ?.map { String(Base64.getDecoder().decode(it), Charsets.UTF_8) }
        ?.mapNotNull { pair ->
            pair.split("=", limit = 2).takeIf { it.size == 2 }?.let { it[0] to it[1] }
        }
        ?.toMap()
        ?: emptyMap()
val isStand = dartDefines["STAND"] == "true"

// Ключ приложения для RuStore (ADHOC-66).
// Что: релиз боевого приложения подписывается своим ключом из `android/key.properties`
//      (storeFile, storePassword, keyAlias, keyPassword; файл и ключ — вне git).
// Зачем: RuStore принимает обновление, только если подпись совпадает с первой версией, а
//        отладочный ключ у каждой машины свой — им публиковать нельзя.
// Как: нет файла (CI, чужая машина) — релиз, как раньше, подписывается отладочным ключом;
//      стенд всегда на отладочном: его не публикуем, и он не должен требовать ключа.
val keyProperties = Properties().apply {
    val file = rootProject.file("key.properties")
    if (file.exists()) file.inputStream().use { load(it) }
}
val hasReleaseKey = !isStand && keyProperties.getProperty("storeFile") != null

android {
    namespace = "com.craftlimonades.sklad"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // namespace (пакет Kotlin-кода) не меняется — только идентификатор установленного приложения.
        applicationId = if (isStand) "com.craftlimonades.sklad.stand" else "com.craftlimonades.sklad"
        manifestPlaceholders["appLabel"] = if (isStand) "КЛ: Склад · СТЕНД" else "КЛ: Склад"
        // ТСД-цель: Android 11+ → minSdk 30 (по плану P0-05).
        minSdk = 30
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseKey) {
            create("release") {
                storeFile = file(keyProperties.getProperty("storeFile"))
                storePassword = keyProperties.getProperty("storePassword")
                keyAlias = keyProperties.getProperty("keyAlias")
                keyPassword = keyProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName(if (hasReleaseKey) "release" else "debug")
            // Свои правила R8 поверх правил Flutter (ADHOC-69): имена ошибок SDK RuStore.
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }
}

flutter {
    source = "../.."
}
