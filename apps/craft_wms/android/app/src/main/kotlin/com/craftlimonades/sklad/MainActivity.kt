package com.craftlimonades.sklad

import com.craftlimonades.sklad.printer.PrinterBridge
import com.craftlimonades.sklad.scanner.ScannerBridge
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    /**
     * Подключаем платформенные каналы приложения.
     *
     * Оба моста берут `applicationContext`, а не активити: их BroadcastReceiver'ы живут по подписке
     * из Dart, и привязка к активити давала бы утечку при пересоздании экрана. Разрешения мосты
     * поэтому не запрашивают — диалог требует активити, и этим занимается Dart.
     */
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        ScannerBridge.register(flutterEngine.dartExecutor.binaryMessenger, applicationContext)
        PrinterBridge.register(flutterEngine.dartExecutor.binaryMessenger, applicationContext)
        AppBridge.register(flutterEngine.dartExecutor.binaryMessenger, applicationContext)
    }
}
