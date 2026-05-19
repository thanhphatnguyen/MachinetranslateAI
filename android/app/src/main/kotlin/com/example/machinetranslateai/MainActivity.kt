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
				"routeAudioToDevice" -> {
					val deviceId = call.argument<String>("deviceId") ?: ""
					result.success(routeAudioToDevice(deviceId))
				}
				"routeAudioToDefault" -> {
					result.success(routeAudioToDefault())
				}
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
                "listAudioDevices" -> {
                    result.success(listAudioDevices())
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
                        val btDevice = findBluetoothCommunicationDevice(am)

                        if (btDevice != null) {
                            am.mode = AudioManager.MODE_IN_COMMUNICATION
                            am.isSpeakerphoneOn = false
                            requestCommunicationAudioFocus(am)
                            val success = am.setCommunicationDevice(btDevice)
                            Log.d(TAG, "setCommunicationDevice: $success, device: ${btDevice.productName} (type=${btDevice.type})")
                        } else {
                            am.mode = AudioManager.MODE_NORMAL
                            am.isSpeakerphoneOn = true
                            requestAssistantAudioFocus(am)
                        }
                    } else {
                        am.mode = AudioManager.MODE_IN_COMMUNICATION
                        am.isSpeakerphoneOn = false
                        am.isBluetoothScoOn = true
                        am.startBluetoothSco()
                    }
                }

                "phone" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                        am.clearCommunicationDevice()
                    }
                    am.mode = AudioManager.MODE_NORMAL
                    am.isSpeakerphoneOn = true
                    requestAssistantAudioFocus(am)
                }

                "earpiece" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                        am.clearCommunicationDevice()
                    }
                    am.mode = AudioManager.MODE_IN_COMMUNICATION
                    am.isSpeakerphoneOn = false
                }
            }
            true
        } catch (e: Exception) {
            Log.e(TAG, "setAudioOutput error: ${e.message}")
            false
        }
    }
	private fun routeAudioToDevice(deviceId: String): Boolean {
		return try {
			if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) {
				Log.w(TAG, "routeAudioToDevice requires API 31+")
				return false
			}
			val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
			val outputs = am.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
            val requestedAddress = when {
                deviceId.startsWith("bt_a2dp_") -> deviceId.removePrefix("bt_a2dp_")
                deviceId.startsWith("bt_sco_") -> deviceId.removePrefix("bt_sco_")
                else -> ""
            }

			// Tìm device theo id format từ listAudioDevices()
			val target: AudioDeviceInfo? = when {
				deviceId.startsWith("audio_out_") -> {
					val numId = deviceId.removePrefix("audio_out_").toIntOrNull()
					outputs.firstOrNull { it.id == numId }
				}
				deviceId.startsWith("bt_a2dp_") -> {
					val address = deviceId.removePrefix("bt_a2dp_")
					if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
						outputs.firstOrNull {
							it.address?.equals(address, ignoreCase = true) == true
						}
					} else null
				}
				else -> null
			}

			// Thử route qua setCommunicationDevice
			val commDevices = am.availableCommunicationDevices
            Log.d(TAG, "availableCommunicationDevices: ${commDevices.joinToString { "${it.productName}(id=${it.id},type=${it.type},address=${getDeviceAddress(it)})" }}")
			val commTarget = when {
                target != null -> commDevices.firstOrNull { it.id == target.id }
                    ?: commDevices.firstOrNull {
                        val targetAddress = getDeviceAddress(target)
                        targetAddress.isNotEmpty() && getDeviceAddress(it).equals(targetAddress, ignoreCase = true)
                    }
                requestedAddress.isNotEmpty() && Build.VERSION.SDK_INT >= Build.VERSION_CODES.P ->
                    commDevices.firstOrNull { it.address?.equals(requestedAddress, ignoreCase = true) == true }
                else -> null
            }

            if (target == null && commTarget == null) {
                Log.w(TAG, "routeAudioToDevice: không tìm thấy device id=$deviceId")
                return false
            }

			return if (commTarget != null) {
                am.mode = AudioManager.MODE_IN_COMMUNICATION
                am.isSpeakerphoneOn = false
                requestCommunicationAudioFocus(am)
				val ok = am.setCommunicationDevice(commTarget)
				Log.d(TAG, "routeAudioToDevice: $ok → ${commTarget.productName} (id=${commTarget.id}, type=${commTarget.type}, address=${getDeviceAddress(commTarget)})")
				ok
			} else {
				Log.w(TAG, "routeAudioToDevice: ${target?.productName} không nằm trong availableCommunicationDevices; WebRTC không thể route chắc chắn tới device này")
				false
			}
		} catch (e: Exception) {
			Log.e(TAG, "routeAudioToDevice error: ${e.message}")
			false
		}
	}

	private fun routeAudioToDefault(): Boolean {
		return try {
			val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
			if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
				am.clearCommunicationDevice()
			}
			am.mode = AudioManager.MODE_NORMAL
			Log.d(TAG, "routeAudioToDefault: cleared")
			true
		} catch (e: Exception) {
			Log.e(TAG, "routeAudioToDefault error: ${e.message}")
			false
		}
	}
    private fun findBluetoothCommunicationDevice(am: AudioManager): AudioDeviceInfo? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return null

        val commDevices = am.availableCommunicationDevices
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
            am.requestAudioFocus(req)
        } else {
            @Suppress("DEPRECATION")
            am.requestAudioFocus(null, AudioManager.STREAM_MUSIC, AudioManager.AUDIOFOCUS_GAIN)
        }
    }

    private fun requestCommunicationAudioFocus(am: AudioManager) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            audioFocusRequest?.let { am.abandonAudioFocusRequest(it) }

            val attrs = AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                .build()

            val req = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                .setAudioAttributes(attrs)
                .setAcceptsDelayedFocusGain(false)
                .setWillPauseWhenDucked(false)
                .build()

            audioFocusRequest = req
            am.requestAudioFocus(req)
        } else {
            @Suppress("DEPRECATION")
            am.requestAudioFocus(null, AudioManager.STREAM_VOICE_CALL, AudioManager.AUDIOFOCUS_GAIN)
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
    }

    private fun setAudioStreamType(type: String): Boolean {
        return try {
            val streamType = when (type) {
                "communication" -> AudioManager.STREAM_VOICE_CALL
                else -> AudioManager.STREAM_MUSIC
            }
            runOnUiThread { volumeControlStream = streamType }
            true
        } catch (e: Exception) {
            false
        }
    }

    private fun listAudioDevices(): List<Map<String, Any>> {
        val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        val devices = mutableListOf<Map<String, Any>>()
        val seenDevices = mutableSetOf<String>()

        // ── 1. Quét toàn bộ MIC (Input Devices) ──
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            for (device in am.getDevices(AudioManager.GET_DEVICES_INPUTS)) {
                val typeName = mapInputDeviceType(device.type)
                val address = getDeviceAddress(device)
                val key = "in_${device.id}:$typeName:$address"

                if (seenDevices.add(key)) {
                    devices.add(
                        mapOf(
                            "id" to "audio_in_${device.id}",
                            "name" to deviceDisplayName(device, isOutput = false),
                            "type" to typeName,
                            "address" to address,
                            "isOutput" to false,
                        )
                    )
                }
            }
        }

        // ── 2. Quét toàn bộ LOA (Output Devices) ──
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            for (device in am.getDevices(AudioManager.GET_DEVICES_OUTPUTS)) {
                val typeName = mapOutputDeviceType(device.type)
                val address = getDeviceAddress(device)
                val key = "out_${device.id}:$typeName:$address"

                if (seenDevices.add(key)) {
                    devices.add(
                        mapOf(
                            "id" to "audio_out_${device.id}",
                            "name" to deviceDisplayName(device, isOutput = true),
                            "type" to typeName,
                            "address" to address,
                            "isOutput" to true,
                        )
                    )
                }
            }
        }

        return devices
    }

    private fun mapOutputDeviceType(type: Int): String = when (type) {
        AudioDeviceInfo.TYPE_BLUETOOTH_A2DP -> "bluetooth_a2dp"
        AudioDeviceInfo.TYPE_BLUETOOTH_SCO -> "bluetooth_sco"
        AudioDeviceInfo.TYPE_BLE_HEADSET -> "ble_headset"
        AudioDeviceInfo.TYPE_BLE_SPEAKER -> "ble_speaker"
        AudioDeviceInfo.TYPE_BUILTIN_SPEAKER -> "builtin_speaker"
        AudioDeviceInfo.TYPE_BUILTIN_EARPIECE -> "builtin_earpiece"
        AudioDeviceInfo.TYPE_WIRED_HEADSET -> "wired_headset"
        AudioDeviceInfo.TYPE_WIRED_HEADPHONES -> "wired_headphones"
        AudioDeviceInfo.TYPE_USB_DEVICE -> "usb_device"
        AudioDeviceInfo.TYPE_USB_HEADSET -> "usb_headset"
        AudioDeviceInfo.TYPE_LINE_ANALOG -> "line_analog"
        AudioDeviceInfo.TYPE_LINE_DIGITAL -> "line_digital"
        else -> "other_output_$type"
    }

    private fun mapInputDeviceType(type: Int): String = when (type) {
        AudioDeviceInfo.TYPE_BLUETOOTH_SCO -> "bluetooth_sco_mic"
        AudioDeviceInfo.TYPE_BLE_HEADSET -> "ble_headset"
        AudioDeviceInfo.TYPE_BUILTIN_MIC -> "builtin_mic"
        AudioDeviceInfo.TYPE_WIRED_HEADSET -> "wired_headset"
        AudioDeviceInfo.TYPE_USB_DEVICE -> "usb_device"
        AudioDeviceInfo.TYPE_USB_HEADSET -> "usb_headset"
        AudioDeviceInfo.TYPE_LINE_ANALOG -> "line_analog"
        AudioDeviceInfo.TYPE_LINE_DIGITAL -> "line_digital"
        else -> "other_input_$type"
    }

    private fun getDeviceAddress(device: AudioDeviceInfo): String {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            device.address ?: ""
        } else ""
    }

    private fun deviceDisplayName(device: AudioDeviceInfo, isOutput: Boolean): String {
        val rawName = device.productName?.toString()?.takeIf { it.isNotBlank() }
        val baseName = rawName ?: humanReadableName(
            if (isOutput) mapOutputDeviceType(device.type) else mapInputDeviceType(device.type)
        )
        val phoneName = Build.MODEL.takeIf { it.isNotBlank() } ?: "Phone"

        return when (device.type) {
            AudioDeviceInfo.TYPE_BUILTIN_MIC -> "$phoneName built-in mic"
            AudioDeviceInfo.TYPE_BUILTIN_SPEAKER -> "$phoneName loudspeaker"
            AudioDeviceInfo.TYPE_BUILTIN_EARPIECE -> "$phoneName earpiece"
            AudioDeviceInfo.TYPE_BLUETOOTH_A2DP -> "$baseName speaker/headphones"
            AudioDeviceInfo.TYPE_BLUETOOTH_SCO -> if (isOutput) "$baseName headset speaker" else "$baseName mic"
            AudioDeviceInfo.TYPE_BLE_HEADSET -> if (isOutput) "$baseName BLE headset speaker" else "$baseName BLE mic"
            AudioDeviceInfo.TYPE_BLE_SPEAKER -> "$baseName BLE speaker"
            AudioDeviceInfo.TYPE_WIRED_HEADSET -> if (isOutput) "$baseName wired headset speaker" else "$baseName wired headset mic"
            AudioDeviceInfo.TYPE_WIRED_HEADPHONES -> "$baseName wired headphones"
            AudioDeviceInfo.TYPE_USB_HEADSET -> if (isOutput) "$baseName USB headset speaker" else "$baseName USB headset mic"
            AudioDeviceInfo.TYPE_USB_DEVICE -> if (isOutput) "$baseName USB speaker/audio" else "$baseName USB mic/audio"
            AudioDeviceInfo.TYPE_LINE_ANALOG -> if (isOutput) "$baseName 3.5mm/line output" else "$baseName 3.5mm/line input"
            AudioDeviceInfo.TYPE_LINE_DIGITAL -> if (isOutput) "$baseName digital line output" else "$baseName digital line input"
            else -> if (isOutput) "$baseName output" else "$baseName mic"
        }
    }

    private fun humanReadableName(type: String): String = when (type) {
        "builtin_speaker" -> "Phone loudspeaker"
        "builtin_earpiece" -> "Phone earpiece"
        "builtin_mic" -> "Phone built-in mic"
        "bluetooth_a2dp" -> "Bluetooth"
        "bluetooth_sco", "bluetooth_sco_mic" -> "Bluetooth SCO"
        "ble_headset" -> "BLE headset"
        "ble_speaker" -> "BLE speaker"
        "wired_headset" -> "Wired headset"
        "wired_headphones" -> "Wired headphones"
        "usb_device", "usb_headset" -> "USB audio"
        "line_analog" -> "3.5mm/line audio"
        "line_digital" -> "Digital line audio"
        else -> type
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
