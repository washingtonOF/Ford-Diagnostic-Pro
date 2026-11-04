package br.com.forddiagnosticpro.app

import android.Manifest
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothSocket
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.ActivityCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.UUID
import java.io.IOException
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val executor = Executors.newSingleThreadExecutor()
    private var socket: BluetoothSocket? = null
    private val uuid = UUID.fromString("00001101-0000-1000-8000-00805F9B34FB")
    private val channelName = "ford_diagnostic/obd"
    private val requestCode = 2001
    private var pending: MethodChannel.Result? = null
    private var pendingMethod: String? = null
    private var pendingArgs: Map<*, *>? = null

    private fun adapter(): BluetoothAdapter? =
        (getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager).adapter

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName).setMethodCallHandler { call, result ->
            val args = call.arguments as? Map<*, *>
            if (Build.VERSION.SDK_INT >= 31 &&
                ActivityCompat.checkSelfPermission(this, Manifest.permission.BLUETOOTH_CONNECT) != PackageManager.PERMISSION_GRANTED) {
                pending = result; pendingMethod = call.method; pendingArgs = args
                ActivityCompat.requestPermissions(this, arrayOf(Manifest.permission.BLUETOOTH_CONNECT), requestCode)
            } else execute(call.method, args, result)
        }
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == this.requestCode) {
            val r = pending; val m = pendingMethod; val a = pendingArgs
            pending = null; pendingMethod = null; pendingArgs = null
            if (r != null && m != null) {
                if (grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED) execute(m, a, r)
                else r.error("PERMISSION", "Permissão Bluetooth negada", null)
            }
        }
    }

    private fun execute(method: String, args: Map<*, *>?, result: MethodChannel.Result) {
        executor.execute {
            try {
                val value: Any? = when (method) {
                    "paired" -> adapter()?.bondedDevices?.map { mapOf("name" to (it.name ?: "Bluetooth"), "address" to it.address) } ?: emptyList<Map<String, String>>()
                    "connect" -> {
                        val address = args?.get("address") as? String ?: error("Endereço ausente")
                        socket?.close()
                        val device = adapter()?.getRemoteDevice(address) ?: error("Bluetooth indisponível")
                        // Sem varredura: conexao com dispositivo ja pareado
                        try {
                            socket = device.createRfcommSocketToServiceRecord(uuid)
                            socket!!.connect()
                        } catch (first: IOException) {
                            try { socket?.close() } catch (_: Exception) {}
                            socket = null
                            throw IOException("Falha ao conectar ao ELM327 pareado: ${first.message}")
                        }
                        null
                    }
                    "disconnect" -> { socket?.close(); socket = null; null }
                    "command" -> {
                        val command = args?.get("command") as? String ?: error("Comando ausente")
                        require(Regex("^(AT[A-Z0-9]*|01[0-9A-F]{2}|0[347A]|0902)$").matches(command)) { "Comando não permitido" }
                        send(command)
                    }
                    else -> error("Método desconhecido: $method")
                }
                runOnUiThread { result.success(value) }
            } catch (e: Exception) {
                runOnUiThread { result.error("OBD_ERROR", e.message ?: "Erro de conexão", null) }
            }
        }
    }

    private fun send(command: String): String {
        val s = socket ?: error("ELM327 desconectado")
        val input = s.inputStream
        val output = s.outputStream
        while (input.available() > 0) input.read()
        output.write("$command\r".toByteArray(Charsets.US_ASCII))
        output.flush()
        val sb = StringBuilder()
        val deadline = System.currentTimeMillis() + 6500
        while (System.currentTimeMillis() < deadline) {
            if (input.available() > 0) {
                val c = input.read()
                if (c < 0) error("Conexão encerrada")
                if (c.toChar() == '>') return sb.toString()
                sb.append(c.toChar())
                if (sb.length > 8192) error("Resposta muito longa")
            } else Thread.sleep(20)
        }
        error("Tempo esgotado aguardando ELM327: $command")
    }

    override fun onDestroy() {
        try { socket?.close() } catch (_: Exception) {}
        executor.shutdownNow()
        super.onDestroy()
    }
}
