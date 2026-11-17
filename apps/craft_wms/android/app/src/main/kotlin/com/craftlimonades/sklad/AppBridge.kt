package com.craftlimonades.sklad

import android.content.Context
import android.content.Intent
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * Канал `craft_wms/app` - действия над самим приложением (ADHOC-67).
 *
 * `restart` перезапускает процесс: переключение между рабочим и демо-сервером меняет адрес API,
 * файл локальной базы и ключи сессии, которые Dart собирает один раз при старте. Новая задача
 * активити запускается до выхода, система поднимает для неё новый процесс.
 */
object AppBridge {
    private const val CHANNEL = "craft_wms/app"

    fun register(messenger: BinaryMessenger, context: Context) {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "restart" -> {
                    val launch = context.packageManager.getLaunchIntentForPackage(context.packageName)
                    val component = launch?.component
                    if (component == null) {
                        result.error("no_launch_intent", "не найдена стартовая активити", null)
                        return@setMethodCallHandler
                    }
                    context.startActivity(Intent.makeRestartActivityTask(component))
                    result.success(null)
                    Runtime.getRuntime().exit(0)
                }
                else -> result.notImplemented()
            }
        }
    }
}
