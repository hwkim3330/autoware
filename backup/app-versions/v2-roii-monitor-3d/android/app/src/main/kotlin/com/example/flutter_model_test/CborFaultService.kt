package com.example.flutter_model_test

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Handler
import android.os.Looper
import android.util.Log
import com.fasterxml.jackson.databind.ObjectMapper
import com.fasterxml.jackson.dataformat.cbor.CBORFactory
import io.flutter.plugin.common.EventChannel

class CborFaultService(private val context: Context) {
    companion object {
        private const val TAG = "CborFaultService"
        private const val ACTION_SIMULATE_CBOR = "com.pleos.SIMULATE_CBOR"
        private const val EXTRA_CBOR_HEX = "cbor_hex"
    }

    private var eventSink: EventChannel.EventSink? = null
    private val mainThreadHandler = Handler(Looper.getMainLooper())
    private val cborMapper = ObjectMapper(CBORFactory())
    private val jsonMapper = ObjectMapper()

    private val broadcastReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action == ACTION_SIMULATE_CBOR) {
                val hexString = intent.getStringExtra(EXTRA_CBOR_HEX)
                if (hexString != null) {
                    Log.d(TAG, "Received CBOR hex: $hexString")
                    processCborHex(hexString)
                } else {
                    Log.w(TAG, "Received broadcast without cbor_hex extra")
                }
            }
        }
    }

    fun startListening() {
        val filter = IntentFilter(ACTION_SIMULATE_CBOR)
        context.registerReceiver(broadcastReceiver, filter, Context.RECEIVER_EXPORTED)
        Log.d(TAG, "CborFaultService started listening for broadcasts")
    }

    fun stopListening() {
        try {
            context.unregisterReceiver(broadcastReceiver)
            Log.d(TAG, "CborFaultService stopped listening")
        } catch (e: IllegalArgumentException) {
            Log.w(TAG, "Receiver was not registered")
        }
    }

    fun setEventSink(sink: EventChannel.EventSink?) {
        this.eventSink = sink
        Log.d(TAG, "EventSink ${if (sink != null) "connected" else "disconnected"}")
    }

    private fun processCborHex(hexString: String) {
        try {
            // Step 1: Convert hex string to bytes
            val cborBytes = parseHexToCbor(hexString)
            Log.d(TAG, "Parsed ${cborBytes.size} bytes from hex")

            // Step 2: Parse CBOR to JSON-compatible map
            val jsonData = cborToJson(cborBytes)
            Log.d(TAG, "Parsed CBOR to JSON: $jsonData")

            // Step 3: Send to Flutter via EventChannel
            sendToFlutter(jsonData)
        } catch (e: Exception) {
            Log.e(TAG, "Error processing CBOR data", e)
            mainThreadHandler.post {
                eventSink?.error("CBOR_PARSE_ERROR", e.message, e.stackTraceToString())
            }
        }
    }

    private fun parseHexToCbor(hexString: String): ByteArray {
        // Remove any whitespace and convert to uppercase
        val cleanHex = hexString.replace("\\s".toRegex(), "").uppercase()
        
        // Validate hex string
        if (cleanHex.length % 2 != 0) {
            throw IllegalArgumentException("Hex string must have even length")
        }
        
        if (!cleanHex.matches(Regex("[0-9A-F]*"))) {
            throw IllegalArgumentException("Invalid hex string")
        }

        // Convert to byte array
        return cleanHex.chunked(2)
            .map { it.toInt(16).toByte() }
            .toByteArray()
    }

    private fun cborToJson(cborBytes: ByteArray): Map<String, Any> {
        // Parse CBOR bytes to a generic object
        val parsedObject = cborMapper.readValue(cborBytes, Any::class.java)
        
        // Convert to JSON-compatible Map
        return when (parsedObject) {
            is Map<*, *> -> {
                @Suppress("UNCHECKED_CAST")
                parsedObject as Map<String, Any>
            }
            else -> {
                throw IllegalArgumentException("Expected CBOR map, got ${parsedObject?.javaClass?.simpleName}")
            }
        }
    }

    private fun sendToFlutter(data: Map<String, Any>) {
        mainThreadHandler.post {
            if (eventSink != null) {
                val faultData = mutableMapOf<String, Any>()
                
                // Handle 'action' field (1 = add, 0 = remove)
                val action = data["action"] ?: data["a"] ?: 1
                faultData["action"] = when (action) {
                    is Number -> action.toInt()
                    is String -> action.toIntOrNull() ?: 1
                    else -> 1
                }
                
                // Handle 'id' field (required)
                val id = data["id"] ?: data["i"]
                if (id != null) {
                    faultData["id"] = when (id) {
                        is Number -> id.toInt()
                        is String -> id.toIntOrNull() ?: 0
                        else -> 0
                    }
                } else {
                    Log.w(TAG, "No ID provided in CBOR data")
                    return@post
                }
                
                // For add action (action == 1), include code, target, severity
                if (faultData["action"] == 1) {
                    // Handle 'code' field
                    val code = data["code"] ?: data["c"]
                    if (code != null) {
                        faultData["code"] = when (code) {
                            is Number -> code.toInt()
                            is String -> code.toIntOrNull() ?: 0
                            else -> 0
                        }
                    }
                    
                    // Handle 'target' field
                    val target = data["target"] ?: data["t"]
                    if (target != null) {
                        faultData["target"] = target.toString()
                    }
                    
                    // Handle 'severity' field
                    val severity = data["severity"] ?: data["s"]
                    if (severity != null) {
                        faultData["severity"] = when (severity) {
                            is Number -> severity.toInt()
                            is String -> severity.toIntOrNull() ?: 1
                            else -> 1
                        }
                    }
                }
                
                Log.d(TAG, "Sending to Flutter: $faultData")
                eventSink?.success(faultData)
            } else {
                Log.w(TAG, "EventSink is null, cannot send data to Flutter")
            }
        }
    }
}

