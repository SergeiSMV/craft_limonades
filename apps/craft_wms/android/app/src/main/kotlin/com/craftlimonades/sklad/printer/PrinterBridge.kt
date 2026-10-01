package com.craftlimonades.sklad.printer

import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothSocket
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.IOException
import java.io.OutputStream
import java.util.UUID
import java.util.concurrent.Executors

/**
 * Мост «Bluetooth-принтер этикеток → Flutter» (P4-05).
 *
 * Что: держит RFCOMM-соединение с термопринтером и отдаёт в него сырые байты команд.
 * Зачем: ярлык грузовой единицы печатается прямо на приёмке, у стеллажа. Принтер аккумуляторный
 *      и ездит вместе с кладовщиком, поэтому транспорт — Bluetooth, а не USB или Wi-Fi.
 * Как: классический SPP (Serial Port Profile) — принтер выглядит последовательным портом, в него
 *      пишется поток команд выбранного языка (TSPL/ZPL). Соединение держится открытым между
 *      этикетками: установка RFCOMM-сокета занимает ощутимое время, и переподключаться на каждую
 *      наклейку значило бы заставлять человека ждать у принтера.
 *
 * Своя реализация, а не пакет с pub.dev: нужно ровно три вещи — список устройств, сокет и запись
 * байтов, — и тот же приём уже применён к сканеру. Сторонние обёртки печати тянут за собой ESC/POS
 * и чековую модель, которая для этикеток не подходит.
 *
 * ⚠ Разрешений этот класс НЕ запрашивает: диалог требует активити, а мост живёт на
 * `applicationContext`. Запрашивает их Dart (`permission_handler`) до вызова; сюда отказ приходит
 * исключением Android, и оно уезжает в Dart как ошибка канала с кодом `permission`.
 */
class PrinterBridge(private val context: Context) :
    MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    /** Единственный рабочий поток: запись в сокет обязана быть строго последовательной. */
    private val io = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    private var socket: BluetoothSocket? = null
    private var output: OutputStream? = null
    private var connectedAddress: String? = null

    /** Приёмник найденных устройств. Живёт только пока Dart подписан на поиск. */
    private var discoveryReceiver: BroadcastReceiver? = null

    /** Приёмник смены состояния спаривания. Живёт ровно на время одной попытки. */
    private var bondReceiver: BroadcastReceiver? = null

    private val adapter: BluetoothAdapter?
        get() = (context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager)?.adapter

    //* --- методы --- *//

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "status" -> result.success(status())
            "bonded" -> guarded(result) { bonded() }
            "bond" -> {
                val address = call.argument<String>("address")
                if (address == null) {
                    result.error("argument", "address обязателен", null)
                    return
                }
                bond(address, result)
            }
            "connect" -> {
                val address = call.argument<String>("address")
                if (address == null) {
                    result.error("argument", "address обязателен", null)
                    return
                }
                // Соединение устанавливается в фоне: connect() на RFCOMM блокирует поток
                // до успеха или таймаута, и на главном это дало бы ANR.
                io.execute {
                    val error = runCatching { openSocket(address) }.exceptionOrNull()
                    main.post {
                        if (error == null) result.success(null) else result.fail(error)
                    }
                }
            }
            "write" -> {
                val bytes = call.argument<ByteArray>("bytes")
                if (bytes == null) {
                    result.error("argument", "bytes обязательны", null)
                    return
                }
                io.execute {
                    val error = runCatching { writeBytes(bytes) }.exceptionOrNull()
                    main.post {
                        if (error == null) result.success(null) else result.fail(error)
                    }
                }
            }
            "disconnect" -> {
                io.execute {
                    closeSocket()
                    main.post { result.success(null) }
                }
            }
            else -> result.notImplemented()
        }
    }

    /** Состояние адаптера и соединения — чтобы экран объяснял человеку, что именно не так. */
    private fun status(): Map<String, Any?> {
        val a = adapter
        return mapOf(
            "supported" to (a != null),
            "enabled" to (a?.isEnabled == true),
            "connected" to (socket?.isConnected == true),
            "address" to connectedAddress,
        )
    }

    /**
     * Спаренные устройства. Именно они — основной путь: принтер спаривается один раз,
     * дальше приложение просто помнит его адрес.
     */
    private fun bonded(): List<Map<String, String>> =
        adapter?.bondedDevices.orEmpty().map { it.toMap() }

    /**
     * Спаривает терминал с принтером и дожидается исхода.
     *
     * Зачем отдельным шагом, а не «само получится при подключении»: неявное спаривание, которое
     * запускает `socket.connect()` на незнакомом устройстве, Android ведёт по упрощённому пути —
     * показывает согласие «Добавить устройство?» вместо запроса PIN. Принтеру XP-P323B PIN нужен,
     * и попытка срывалась аутентификацией (HCI 0x05) ещё до того, как доходило до сокета.
     * Явный `createBond()` поднимает штатный диалог спаривания со вводом кода.
     *
     * Ответ приходит по broadcast'у, поэтому результат канала удерживается до смены состояния:
     * человеку нужно время на диалог, и возвращать «готово» сразу значило бы врать.
     */
    private fun bond(address: String, result: MethodChannel.Result) {
        val a = adapter
        if (a == null) {
            result.error("unsupported", "Bluetooth на устройстве недоступен", null)
            return
        }
        val device = runCatching { a.getRemoteDevice(address) }.getOrNull()
        if (device == null) {
            result.error("argument", "Неизвестный адрес устройства", null)
            return
        }
        if (device.bondState == BluetoothDevice.BOND_BONDED) {
            result.success(null)
            return
        }
        if (bondReceiver != null) {
            result.error("io", "Спаривание уже идёт", null)
            return
        }

        // Поиск держит радио и мешает спариванию ровно так же, как и соединению.
        runCatching { a.cancelDiscovery() }

        var answered = false
        val created = object : BroadcastReceiver() {
            override fun onReceive(ctx: Context?, intent: Intent?) {
                val changed = intent?.device() ?: return
                if (!changed.address.equals(address, ignoreCase = true)) return
                when (intent.getIntExtra(BluetoothDevice.EXTRA_BOND_STATE, -1)) {
                    BluetoothDevice.BOND_BONDED -> {
                        if (answered) return
                        answered = true
                        clearBondReceiver()
                        main.post { result.success(null) }
                    }
                    BluetoothDevice.BOND_NONE -> {
                        if (answered) return
                        answered = true
                        clearBondReceiver()
                        val reason = intent.getIntExtra(EXTRA_BOND_REASON, -1)
                        main.post { result.error("bond", bondFailureMessage(reason), null) }
                    }
                }
            }
        }
        context.registerReceiver(created, IntentFilter(BluetoothDevice.ACTION_BOND_STATE_CHANGED))
        bondReceiver = created

        val started = runCatching { device.createBond() }
        if (started.isFailure || started.getOrDefault(false).not()) {
            answered = true
            clearBondReceiver()
            val error = started.exceptionOrNull()
            if (error != null) result.fail(error)
            else result.error("bond", "Спаривание не запустилось", null)
        }
    }

    private fun clearBondReceiver() {
        bondReceiver?.let { runCatching { context.unregisterReceiver(it) } }
        bondReceiver = null
    }

    /**
     * Открывает RFCOMM-сокет к принтеру по стандартному UUID SPP.
     *
     * Поиск гасится перед соединением намеренно: активное обнаружение занимает радио целиком,
     * и подключение поверх него либо тормозит, либо срывается.
     */
    private fun openSocket(address: String) {
        val a = adapter ?: throw IOException("Bluetooth на устройстве недоступен")
        if (!a.isEnabled) throw IOException("Bluetooth выключен")
        closeSocket()
        a.cancelDiscovery()
        val device = a.getRemoteDevice(address)
        val created = device.createRfcommSocketToServiceRecord(SPP_UUID)
        created.connect()
        socket = created
        output = created.outputStream
        connectedAddress = address
    }

    /**
     * Пишет команды в принтер.
     *
     * `flush` обязателен: без него последняя этикетка остаётся в буфере потока, и человек видит
     * «всё отправлено» при пустом принтере.
     */
    private fun writeBytes(bytes: ByteArray) {
        val stream = output ?: throw IOException("Принтер не подключён")
        stream.write(bytes)
        stream.flush()
    }

    private fun closeSocket() {
        runCatching { output?.close() }
        runCatching { socket?.close() }
        output = null
        socket = null
        connectedAddress = null
    }

    //* --- поиск устройств --- *//

    /**
     * Поток найденных устройств. Подписка включает обнаружение, отмена — гасит его.
     *
     * Обнаружение намеренно живёт ровно на время подписки: оно сажает батарею и занимает радио,
     * а оставленное включённым мешает самому соединению с принтером.
     */
    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        val sink = events ?: return
        onCancel(null)
        val a = adapter
        if (a == null) {
            sink.error("unsupported", "Bluetooth на устройстве недоступен", null)
            return
        }
        val created = object : BroadcastReceiver() {
            override fun onReceive(ctx: Context?, intent: Intent?) {
                when (intent?.action) {
                    BluetoothDevice.ACTION_FOUND -> {
                        val device = intent.device() ?: return
                        if (!device.supportsSpp()) return
                        runCatching { sink.success(device.toMap()) }
                    }
                    BluetoothAdapter.ACTION_DISCOVERY_FINISHED ->
                        runCatching { sink.endOfStream() }
                }
            }
        }
        val filter = IntentFilter().apply {
            addAction(BluetoothDevice.ACTION_FOUND)
            addAction(BluetoothAdapter.ACTION_DISCOVERY_FINISHED)
        }
        // Интенты шлёт система, поэтому приёмник не экспортируемый — в отличие от моста сканера,
        // где broadcast приходит от стороннего приложения декодера.
        context.registerReceiver(created, filter)
        discoveryReceiver = created
        try {
            a.cancelDiscovery()
            if (!a.startDiscovery()) {
                sink.error("permission", "Поиск не запустился: нет разрешения или Bluetooth выключен", null)
            }
        } catch (e: SecurityException) {
            sink.error("permission", e.message, null)
        }
    }

    override fun onCancel(arguments: Any?) {
        discoveryReceiver?.let { runCatching { context.unregisterReceiver(it) } }
        discoveryReceiver = null
        runCatching { adapter?.cancelDiscovery() }
    }

    //* --- вспомогательное --- *//

    /** Выполняет чтение адаптера, переводя отказ в разрешениях в понятную ошибку канала. */
    private fun guarded(result: MethodChannel.Result, block: () -> Any?) {
        val value = runCatching(block)
        value.fold({ result.success(it) }, { result.fail(it) })
    }

    companion object {
        /** Стандартный UUID профиля последовательного порта — им говорят все принтеры этикеток. */
        private val SPP_UUID: UUID = UUID.fromString("00001101-0000-1000-8000-00805F9B34FB")

        /**
         * Причина разрыва спаривания. Константа скрыта в SDK (`BluetoothDevice.EXTRA_REASON`),
         * но сам extra приходит всегда — без него «не удалось» неотличимо от «отменили».
         */
        private const val EXTRA_BOND_REASON = "android.bluetooth.device.extra.REASON"

        /** Отказ аутентификации: неверный PIN либо принтер не принял упрощённое спаривание. */
        private const val BOND_REASON_AUTH_FAILED = 1

        /** Человек нажал «Отмена» в диалоге спаривания. */
        private const val BOND_REASON_AUTH_CANCELED = 3

        /** Устройство не ответило: выключено, далеко или занято другим хостом. */
        private const val BOND_REASON_REMOTE_DEVICE_DOWN = 2

        /** Текст отказа, по которому человек поймёт, что делать дальше. */
        private fun bondFailureMessage(reason: Int): String = when (reason) {
            BOND_REASON_AUTH_FAILED ->
                "Принтер не принял спаривание. Попробуйте PIN 0000 или 1234, " +
                    "либо спарьте его в настройках Android."
            BOND_REASON_AUTH_CANCELED -> "Спаривание отменено"
            BOND_REASON_REMOTE_DEVICE_DOWN ->
                "Принтер не отвечает: включён ли он и не занят ли другим устройством"
            else -> "Не удалось спарить принтер (причина $reason)"
        }

        private const val METHOD_CHANNEL = "craft_wms/printer"
        private const val DISCOVERY_CHANNEL = "craft_wms/printer/discovery"

        /** Подключает каналы моста к движку Flutter. */
        fun register(messenger: BinaryMessenger, context: Context) {
            val bridge = PrinterBridge(context)
            MethodChannel(messenger, METHOD_CHANNEL).setMethodCallHandler(bridge)
            EventChannel(messenger, DISCOVERY_CHANNEL).setStreamHandler(bridge)
        }
    }
}

/**
 * Годится ли устройство под печать: отсекаем «чистый» Bluetooth Low Energy.
 *
 * Зачем: принтер XP-P323B виден в эфире ДВАЖДЫ — классическим устройством (`DC:0D:30:53:26:BD`)
 * и BLE-объявлением (`DD:…`), адреса отличаются одним символом. SPP, то есть сама печать, живёт
 * только на классическом; спаривание со вторым срывается отказом аутентификации. Снято с живого
 * DT50S: первая попытка подключения ушла именно в BLE-адрес.
 *
 * Без фильтра кладовщик видел бы в списке две почти одинаковые строки, из которых рабочая — одна,
 * и выбор между ними был бы угадыванием.
 *
 * `DEVICE_TYPE_UNKNOWN` оставляем: тип не всегда успевает определиться к моменту находки,
 * и прятать устройство из-за этого значило бы терять рабочий принтер.
 */
private fun BluetoothDevice.supportsSpp(): Boolean =
    runCatching { type }.getOrDefault(BluetoothDevice.DEVICE_TYPE_UNKNOWN) !=
        BluetoothDevice.DEVICE_TYPE_LE

/** Устройство в виде, понятном Dart. Имя может отсутствовать — показываем адрес. */
private fun BluetoothDevice.toMap(): Map<String, String> = mapOf(
    "name" to (runCatching { name }.getOrNull() ?: ""),
    "address" to address,
)

/** Устройство из интента обнаружения. Со вкусом версии: на 33+ типизированный extra. */
private fun Intent.device(): BluetoothDevice? =
    if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.TIRAMISU) {
        getParcelableExtra(BluetoothDevice.EXTRA_DEVICE, BluetoothDevice::class.java)
    } else {
        @Suppress("DEPRECATION")
        getParcelableExtra(BluetoothDevice.EXTRA_DEVICE)
    }

/**
 * Ошибка в ответ канала с кодом, по которому Dart отличает нехватку прав от обрыва связи:
 * первое чинит человек в настройках, второе — повтор подключения.
 */
private fun MethodChannel.Result.fail(e: Throwable) {
    val code = if (e is SecurityException) "permission" else "io"
    error(code, e.message ?: e.toString(), null)
}
