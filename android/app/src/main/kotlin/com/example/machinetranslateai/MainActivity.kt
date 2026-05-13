package com.example.machinetranslateai

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioDeviceInfo
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.Build
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.example.machinetranslateai/audio"
    private val TAG = "AudioRouting"

    private var audioFocusRequest: AudioFocusRequest? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CHANNEL
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "setAudioOutput" -> {
                    val type = call.argument<String>("type") ?: "phone"
                    result.success(setAudioOutput(type))
                }
                "setAudioStreamType" -> {
                    val type = call.argument<String>("type") ?: "assistant"
                    result.success(setAudioStreamType(type))
                }
                "abandonAudioFocus" -> {
                    abandonAudioFocus()
                    result.success(true)
                }
                "isBluetoothConnected" -> {
                    result.success(isBluetoothConnected())
                }
                "isBluetoothA2dpConnected" -> {
                    result.success(isBluetoothA2dpConnected())
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun setAudioOutput(type: String): Boolean {
        return try {
            val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager

            // Dừng SCO cũ nếu có
            if (am.isBluetoothScoOn) {
                am.isBluetoothScoOn = false
                am.stopBluetoothSco()
            }

            when (type) {
                "bluetooth" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                        // ── Android 12+: setCommunicationDevice ──────────
                        // Cho phép mic BT mà không cần bật SCO toàn bộ
                        // Output vẫn đi qua A2DP (USAGE_ASSISTANT)
                        val btDevice = findBluetoothCommunicationDevice(am)

                        if (btDevice != null) {
                            // Set BT làm communication device (mic input)
                            val success = am.setCommunicationDevice(btDevice)
                            Log.d(TAG, "setCommunicationDevice: $success, device: ${btDevice.productName} (type=${btDevice.type})")

                            // Request AudioFocus với USAGE_ASSISTANT cho output
                            am.mode = AudioManager.MODE_NORMAL
                            am.isSpeakerphoneOn = false
                            requestAssistantAudioFocus(am)

                            Log.d(TAG, "Audio → BT mic (setCommunicationDevice) + A2DP output (USAGE_ASSISTANT)")
                        } else {
                            // Không tìm thấy BT communication device → fallback loa ngoài
                            am.mode = AudioManager.MODE_NORMAL
                            am.isSpeakerphoneOn = true
                            requestAssistantAudioFocus(am)
                            Log.d(TAG, "Audio → No BT comm device found, fallback Speaker")
                        }
                    } else {
                        // Android < 12: SCO fallback
                        am.mode = AudioManager.MODE_IN_COMMUNICATION
                        am.isSpeakerphoneOn = false
                        am.isBluetoothScoOn = true
                        am.startBluetoothSco()
                        Log.d(TAG, "Audio → BT SCO (Android < 12 fallback)")
                    }
                }

                "phone" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                        am.clearCommunicationDevice()
                    }
                    am.mode = AudioManager.MODE_NORMAL
                    am.isSpeakerphoneOn = true
                    requestAssistantAudioFocus(am)
                    Log.d(TAG, "Audio → Phone Speaker (USAGE_ASSISTANT)")
                }

                "earpiece" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                        am.clearCommunicationDevice()
                    }
                    am.mode = AudioManager.MODE_IN_COMMUNICATION
                    am.isSpeakerphoneOn = false
                    Log.d(TAG, "Audio → Earpiece")
                }
            }
            true
        } catch (e: Exception) {
            Log.e(TAG, "setAudioOutput error: ${e.message}")
            false
        }
    }

    // Tìm BT device phù hợp cho setCommunicationDevice (API 31+)
    private fun findBluetoothCommunicationDevice(am: AudioManager): AudioDeviceInfo? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return null

        val commDevices = am.availableCommunicationDevices
        Log.d(TAG, "Available communication devices: ${commDevices.map { "${it.productName}(${it.type})" }}")

        // Ưu tiên: BLE Headset > BT SCO > BT HFP
        return commDevices.firstOrNull { it.type == AudioDeviceInfo.TYPE_BLE_HEADSET }
            ?: commDevices.firstOrNull { it.type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO }
            ?: commDevices.firstOrNull { it.type == AudioDeviceInfo.TYPE_BLUETOOTH_A2DP }
    }

    private fun requestAssistantAudioFocus(am: AudioManager) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            audioFocusRequest?.let { am.abandonAudioFocusRequest(it) }

            val attrs = AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_ASSISTANT)
                .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                .build()

            val req = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                .setAudioAttributes(attrs)
                .setAcceptsDelayedFocusGain(false)
                .setWillPauseWhenDucked(false)
                .build()

            audioFocusRequest = req
            val result = am.requestAudioFocus(req)
            Log.d(TAG, "AudioFocus USAGE_ASSISTANT: $result")
        } else {
            @Suppress("DEPRECATION")
            am.requestAudioFocus(null, AudioManager.STREAM_MUSIC, AudioManager.AUDIOFOCUS_GAIN)
        }
    }

    private fun abandonAudioFocus() {
        val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            am.clearCommunicationDevice()
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            audioFocusRequest?.let {
                am.abandonAudioFocusRequest(it)
                audioFocusRequest = null
            }
        } else {
            @Suppress("DEPRECATION")
            am.abandonAudioFocus(null)
        }
        am.mode = AudioManager.MODE_NORMAL
        am.isSpeakerphoneOn = false
        if (am.isBluetoothScoOn) {
            am.isBluetoothScoOn = false
            am.stopBluetoothSco()
        }
        Log.d(TAG, "AudioFocus abandoned + CommunicationDevice cleared")
    }

    private fun setAudioStreamType(type: String): Boolean {
        return try {
            val streamType = when (type) {
                "communication" -> AudioManager.STREAM_VOICE_CALL
                else -> AudioManager.STREAM_MUSIC
            }
            runOnUiThread { volumeControlStream = streamType }
            Log.d(TAG, "Volume stream → $type ($streamType)")
            true
        } catch (e: Exception) {
            Log.e(TAG, "setAudioStreamType error: ${e.message}")
            false
        }
    }

    private fun isBluetoothConnected(): Boolean =
        isBluetoothA2dpConnected() || isBluetoothScoConnected()

    private fun isBluetoothA2dpConnected(): Boolean {
        return try {
            val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                am.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
                    .any { it.type == AudioDeviceInfo.TYPE_BLUETOOTH_A2DP }
            } else {
                @Suppress("DEPRECATION") am.isBluetoothA2dpOn
            }
        } catch (e: Exception) { false }
    }

    private fun isBluetoothScoConnected(): Boolean {
        return try {
            val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                am.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
                    .any { it.type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO }
            } else {
                @Suppress("DEPRECATION") am.isBluetoothScoOn
            }
        } catch (e: Exception) { false }
    }
}