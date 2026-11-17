package com.craftlimonades.sklad.scanner

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.os.Build
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Мост «аппаратный сканер ТСД → Flutter» (P2-01).
 *
 * Что: принимает broadcast-интенты декодера Urovo и отдаёт их в Dart единым потоком событий,
 *      плюс отвечает на вопрос «есть ли на этом устройстве аппаратный сканер».
 * Зачем: до P2-01 коды приходили только в режиме «клавиатуры» - символьным вводом в сфокусированное
 *      поле. Оттуда не видно символики (QR это или EAN-13), а фокус приходится удерживать вручную.
 *      Intent-режим отдаёт и сам код, и тип символики, и не зависит от фокуса.
 * Как: EventChannel держит BroadcastReceiver ровно на время подписки из Dart; MethodChannel `probe`
 *      отвечает по системному сервису декодера и по установленным пакетам штатного ПО сканера.
 *
 * Приложение НЕ переключает режим вывода сканера само: смена режима - настройка устройства
 * (ScannerTool), и она ломает клавиатурный ввод, на котором работают текущие экраны. Мост слушает
 * broadcast всегда; если устройство в клавиатурном режиме, поток просто молчит.
 */
class ScannerBridge(private val context: Context) :
    EventChannel.StreamHandler, MethodChannel.MethodCallHandler {

    /** Приёмник интентов декодера. Живёт только пока Dart подписан на поток. */
    private var receiver: BroadcastReceiver? = null

    //* --- поток сканов --- *//

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        val sink = events ?: return
        onCancel(null) // страховка от утечки, если подписка пересоздалась без отмены
        val created = object : BroadcastReceiver() {
            override fun onReceive(ctx: Context?, intent: Intent?) {
                if (intent != null) sink.success(toEvent(intent))
            }
        }
        val filter = IntentFilter().apply {
            ACTIONS.forEach { addAction(it) }
        }
        // Android 13+ требует явно объявить экспорт приёмника. Интенты шлёт стороннее (системное)
        // приложение декодера, поэтому именно EXPORTED - с NOT_EXPORTED сканы отсекались бы молча.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            context.registerReceiver(created, filter, Context.RECEIVER_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            context.registerReceiver(created, filter)
        }
        receiver = created
    }

    override fun onCancel(arguments: Any?) {
        receiver?.let { runCatching { context.unregisterReceiver(it) } }
        receiver = null
    }

    /**
     * Разбор интента в событие для Dart.
     *
     * Всегда отдаём и разобранные поля, и полный сырой набор extras: набор ключей у прошивок Urovo
     * расходится, а диагностический экран показывает сырьё как есть - по нему видно, что реально
     * прислало устройство, если код не распознан.
     */
    private fun toEvent(intent: Intent): Map<String, Any?> {
        val extras = intent.extras
        val raw = LinkedHashMap<String, String>()
        extras?.keySet()?.forEach { key ->
            @Suppress("DEPRECATION")
            raw[key] = describe(extras.get(key))
        }
        return mapOf(
            "action" to intent.action,
            "code" to extractCode(intent),
            "symbology" to extractSymbology(intent),
            "aim" to extractAim(intent),
            "extras" to raw,
        )
    }

    /**
     * Полезная нагрузка скана: сначала строковый ключ, затем байтовый.
     * `null` (ни один ключ не подошёл) - не ошибка: событие всё равно уйдёт в Dart с сырыми extras,
     * а поток распознанных кодов такое просто пропустит.
     */
    private fun extractCode(intent: Intent): String? {
        intent.getStringExtra(EXTRA_TEXT)?.trim()?.takeIf { it.isNotEmpty() }?.let { return it }
        intent.getByteArrayExtra(EXTRA_BYTES)?.let { bytes ->
            val text = String(bytes, Charsets.UTF_8).trim()
            if (text.isNotEmpty()) return text
        }
        return null
    }

    /**
     * Символика (тип кода). Отдаём строкой «как пришло», без попытки перевести числовой код
     * в название: таблица кодов у Urovo по моделям расходится, а угаданное соответствие хуже
     * отсутствующего - на нём молча сломается классификация QR/EAN.
     */
    private fun extractSymbology(intent: Intent): String? {
        val extras = intent.extras ?: return null
        SYMBOLOGY_KEYS.forEach { key ->
            if (extras.containsKey(key)) {
                @Suppress("DEPRECATION")
                val value = extras.get(key) ?: return@forEach
                return value.toString()
            }
        }
        return null
    }

    /**
     * Идентификатор символики по AIM (ISO/IEC 15424): `]` + буква схемы + модификатор,
     * например `]C0` - Code128, `]Q0` - QR, `]d2` - GS1 DataMatrix.
     *
     * Зачем отдельно от имени: буква схемы стандартизована и одинакова у всех производителей
     * сканеров, а вендорское имя пишется как попало (`QRCode` у Urovo, `QR_CODE` у других).
     * Приходит массивом байт, поэтому декодируем, а не берём `toString` - иначе в поле легла бы
     * ссылка на объект.
     */
    private fun extractAim(intent: Intent): String? {
        val extras = intent.extras ?: return null
        AIM_KEYS.forEach { key ->
            @Suppress("DEPRECATION")
            val value = extras.get(key) ?: return@forEach
            val text = when (value) {
                is ByteArray -> String(value, Charsets.UTF_8)
                else -> "$value"
            }.trim()
            if (text.isNotEmpty()) return text
        }
        return null
    }

    /** Человекочитаемое представление extra для диагностики (байты - и размером, и текстом). */
    private fun describe(value: Any?): String = when (value) {
        null -> "null"
        is ByteArray -> "bytes[${value.size}] ${String(value, Charsets.UTF_8)}"
        else -> "$value"
    }

    //* --- определение возможностей устройства --- *//

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "probe" -> result.success(probe())
            else -> result.notImplemented()
        }
    }

    /**
     * Есть ли на устройстве аппаратный сканер (вариант «по возможности», а не по списку моделей).
     *
     * Признак - установленное штатное ПО сканера. Список моделей отвергнут не умозрительно:
     * на боевом DT50S `Build.MANUFACTURER` = `UBX`, хотя `ro.product.manufacturer` = `UROVO`,
     * и проверка на «UROVO» провалилась бы на самом целевом устройстве.
     *
     * ⚠ Системный сервис декодера (`android.os.IScanService`) сюда НЕ годится, хотя в
     * `service list` на DT50S он есть: `Context.getSystemService` отдаёт только сервисы из
     * `SystemServiceRegistry` фреймворка, а вендорские, зарегистрированные в ServiceManager,
     * ему не видны - проверка вернула бы `false` на любом устройстве. Прямой доступ к
     * ServiceManager - скрытый API, на Android 11+ закрыт.
     *
     * Производитель и бренд возвращаются для диагностики (они расходятся), но на решение
     * не влияют.
     */
    private fun probe(): Map<String, Any?> {
        val packages = SCANNER_PACKAGES.filter { isInstalled(it) }
        return mapOf(
            "available" to packages.isNotEmpty(),
            "packages" to packages,
            "manufacturer" to Build.MANUFACTURER,
            "brand" to Build.BRAND,
            "model" to Build.MODEL,
            "device" to Build.DEVICE,
            "actions" to ACTIONS,
        )
    }

    /** Установлен ли пакет. Видимость пакетов на Android 11+ даёт `<queries>` в манифесте. */
    private fun isInstalled(packageName: String): Boolean = try {
        context.packageManager.getPackageInfo(packageName, 0)
        true
    } catch (_: PackageManager.NameNotFoundException) {
        false
    }

    companion object {
        private const val METHOD_CHANNEL = "craft_wms/scanner"
        private const val EVENT_CHANNEL = "craft_wms/scanner/scans"

        /** Действие декодера Urovo по умолчанию (в ScannerTool - ключ `WEDGE_INTENT_ACTION_NAME`). */
        private const val ACTION_UROVO_DECODE = "android.intent.ACTION_DECODE_DATA"

        /**
         * Собственное действие приложения. Если прописать его в ScannerTool вместо действия по
         * умолчанию, сканы увидит только это приложение - соседние приложения на ТСД перестанут
         * получать чужие коды.
         */
        private const val ACTION_APP_SCAN = "com.craftlimonades.sklad.SCAN"

        private val ACTIONS = listOf(ACTION_UROVO_DECODE, ACTION_APP_SCAN)

        /** Ключи полезной нагрузки, снятые с живого DT50S. */
        private const val EXTRA_TEXT = "barcode_string"
        private const val EXTRA_BYTES = "barcode"

        /** Ключи идентификатора AIM (снято с DT50S: приходит массивом байт `]C0`). */
        private val AIM_KEYS = listOf("com.ubx.datawedge.aimcode", "aimcode")

        /**
         * Ключи символики в порядке предпочтения: сначала ИМЯ, потом числовой код.
         *
         * Снято с живого DT50S: декодер кладёт символику дважды - именем (`symName`, `codetype`,
         * `com.ubx.datawedge.symbology_name` = `QRCode` / `Code128`) и числом (`barcodeType`,
         * `symbologyId` = 31 / 8). Имя самодостаточно и переносимо, число у прошивок расходится,
         * поэтому имя идёт первым; числовые ключи оставлены запасным вариантом на случай прошивки
         * без имени - распознать по ним ничего нельзя, но в диагностике они пригодятся.
         */
        private val SYMBOLOGY_KEYS = listOf(
            "symName",
            "codetype",
            "com.ubx.datawedge.symbology_name",
            "barcodeType",
            "barcode_type",
            "symbologyId",
        )

        /** Штатное ПО сканера Urovo: служба декодера и приложение настроек. */
        private val SCANNER_PACKAGES = listOf("com.ubx.uscanner", "com.ubx.barcodescanner.tool")

        /** Подключение моста к движку Flutter (вызывается из MainActivity). */
        fun register(messenger: BinaryMessenger, context: Context) {
            val bridge = ScannerBridge(context)
            MethodChannel(messenger, METHOD_CHANNEL).setMethodCallHandler(bridge)
            EventChannel(messenger, EVENT_CHANNEL).setStreamHandler(bridge)
        }
    }
}
