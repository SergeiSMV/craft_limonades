package com.craftlimonades.sklad

import com.craftlimonades.sklad.scanner.ScannerBridge
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    /**
     * Подключаем платформенные каналы приложения.
     *
     * Мост сканера берёт `applicationContext`, а не активити: BroadcastReceiver живёт по подписке
     * из Dart, и привязка к активити давала бы утечку при пересоздании экрана.
     */
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        ScannerBridge.register(flutterEngine.dartExecutor.binaryMessenger, applicationContext)
    }
}
