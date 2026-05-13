import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:http/http.dart' as http;
import '../models/ai_translate_config.dart';

enum PipecatConnectionState { disconnected, connecting, connected, error }

class PipecatTranscript {
  final String text;
  final String speaker;
  final String? timestamp;
  final bool isFinal;

  PipecatTranscript({
    required this.text,
    required this.speaker,
    this.timestamp,
    this.isFinal = true,
  });
}

class PipecatService {
  static final PipecatService _instance = PipecatService._();
  factory PipecatService() => _instance;
  PipecatService._();

  // ── 1 channel duy nhất, bỏ _channel trùng lặp ──
  static const _audioChannel = MethodChannel(
    'com.example.machinetranslateai/audio',
  );

  RTCPeerConnection? _pc;
  MediaStream? _localStream;
  RTCDataChannel? _dataChannel;
  AiTranslateConfig? _config;

  final _connectionStateController =
      StreamController<PipecatConnectionState>.broadcast();
  final _transcriptController = StreamController<PipecatTranscript>.broadcast();
  final _botOutputController = StreamController<String>.broadcast();
  final _errorController = StreamController<String>.broadcast();
  final _audioLevelController = StreamController<double>.broadcast();

  Stream<PipecatConnectionState> get connectionState =>
      _connectionStateController.stream;
  Stream<PipecatTranscript> get transcripts => _transcriptController.stream;
  Stream<String> get botOutput => _botOutputController.stream;
  Stream<String> get errors => _errorController.stream;
  Stream<double> get audioLevel => _audioLevelController.stream;

  PipecatConnectionState _state = PipecatConnectionState.disconnected;
  PipecatConnectionState get currentState => _state;
  bool get isConnected => _state == PipecatConnectionState.connected;

  Future<void> connect(AiTranslateConfig config) async {
    if (_state == PipecatConnectionState.connecting ||
        _state == PipecatConnectionState.connected) {
      return;
    }

    _config = config;
    _updateState(PipecatConnectionState.connecting);

    try {
      final iceConfig = {
        'iceServers': [
          {
            'urls': 'turn:103.118.29.243:3479?transport=tcp',
            'username': 'test',
            'credential': 'test123',
          },
        ],
        'iceTransportPolicy': 'relay',
        'sdpSemantics': 'unified-plan',
      };

      _pc = await createPeerConnection(iceConfig);

      _localStream = await navigator.mediaDevices.getUserMedia({
        'audio': {
          'echoCancellation': true,
          'noiseSuppression': true,
          'autoGainControl': true,
        },
        'video': false,
      });

      // Apply audio route trước khi WebRTC bắt đầu stream
      debugPrint('PipecatService: audioOutput = ${config.audioOutput.name}');
      debugPrint(
        'PipecatService: audioStreamType = ${config.audioStreamType.name}',
      );
      await _applyAudioOutput(config.audioOutput);
      await _applyAudioStreamType(config.audioStreamType);

      for (final track in _localStream!.getTracks()) {
        await _pc!.addTrack(track, _localStream!);
      }

      _dataChannel = await _pc!.createDataChannel(
        'events',
        RTCDataChannelInit()..ordered = true,
      );
      _setupDataChannel(_dataChannel!);

      _pc!.onTrack = (RTCTrackEvent event) {
        debugPrint(
          'PipecatService: Remote track received: ${event.track.kind}',
        );
      };

      _pc!.onConnectionState = (RTCPeerConnectionState state) {
        debugPrint('PipecatService: Connection state: $state');
        if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
          _updateState(PipecatConnectionState.connected);
        } else if (state ==
                RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
            state == RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
          _updateState(PipecatConnectionState.disconnected);
        }
      };

      _pc!.onIceConnectionState = (RTCIceConnectionState state) {
        debugPrint('PipecatService: ICE state: $state');
      };

      final offer = await _pc!.createOffer({
        'offerToReceiveAudio': true,
        'offerToReceiveVideo': false,
      });
      await _pc!.setLocalDescription(offer);

      await _waitForIceGathering();

      final localDesc = await _pc!.getLocalDescription();
      final connectUrl = config.buildConnectUrl();
      debugPrint('PipecatService: POST $connectUrl');

      final response = await http.post(
        Uri.parse(connectUrl),
        headers: {
          'Content-Type': 'application/json',
          'ngrok-skip-browser-warning': '1',
        },
        body: jsonEncode({
          'sdp': localDesc!.sdp,
          'type': localDesc.type,
          'config': config.toServerParams(),
        }),
      );

      debugPrint(
        'PipecatService: Response ${response.statusCode}: ${response.body}',
      );

      if (response.statusCode != 200) {
        throw Exception(
          'Server error: ${response.statusCode} - ${response.body}',
        );
      }

      final answerData = jsonDecode(response.body);
      if (answerData is! Map) {
        throw Exception(
          'Unexpected response format: ${answerData.runtimeType}',
        );
      }

      final sdp = answerData['sdp'];
      final type = answerData['type'];
      if (sdp is! String || type is! String) {
        throw Exception('Invalid SDP or type in response');
      }

      await _pc!.setRemoteDescription(RTCSessionDescription(sdp, type));
      debugPrint('PipecatService: WebRTC handshake complete');
    } catch (e) {
      debugPrint('PipecatService: Connection error: $e');
      _updateState(PipecatConnectionState.error);
      _errorController.add('Connection failed: $e');
      await _cleanup();
    }
  }

  Future<void> _waitForIceGathering() async {
    final completer = Completer<void>();
    Timer(const Duration(seconds: 5), () {
      if (!completer.isCompleted) completer.complete();
    });
    _pc!.onIceGatheringState = (RTCIceGatheringState state) {
      if (state == RTCIceGatheringState.RTCIceGatheringStateComplete) {
        if (!completer.isCompleted) completer.complete();
      }
    };
    await completer.future;
  }

  // ── Audio routing ─────────────────────────────────────────────────────

  Future<void> _applyAudioOutput(AudioOutputOption output) async {
    debugPrint(
      'PipecatService: _applyAudioOutput called: ${output.name}',
    ); // ← thêm
    try {
      final outputType = output.name;
      debugPrint(
        'PipecatService: invoking setAudioOutput type=$outputType',
      ); // ← thêm
      final result = await _audioChannel.invokeMethod('setAudioOutput', {
        'type': outputType,
      });
      debugPrint('PipecatService: setAudioOutput result=$result'); // ← thêm
    } catch (e) {
      debugPrint('PipecatService: setAudioOutput EXCEPTION: $e');
      // Fallback nếu platform channel fail
      switch (output) {
        case AudioOutputOption.phone:
          Helper.setSpeakerphoneOn(true);
          break;
        case AudioOutputOption.bluetooth:
        case AudioOutputOption.earpiece:
          Helper.setSpeakerphoneOn(false);
          break;
      }
    }
  }

  Future<void> _applyAudioStreamType(AudioStreamType type) async {
    try {
      final typeName = type.name; // 'media', 'assistant', 'communication'
      await _audioChannel.invokeMethod('setAudioStreamType', {
        'type': typeName,
      });
      debugPrint('PipecatService: Audio stream type → $typeName');
    } catch (e) {
      debugPrint('PipecatService: setAudioStreamType error: $e');
    }
  }

  // ── Data channel ──────────────────────────────────────────────────────

  void _setupDataChannel(RTCDataChannel channel) {
    channel.onMessage = (RTCDataChannelMessage message) {
      try {
        if (message.isBinary) return;
        final data = jsonDecode(message.text);
        _handleServerMessage(data);
      } catch (e) {
        debugPrint('PipecatService: Data channel parse error: $e');
      }
    };
    channel.onDataChannelState = (RTCDataChannelState state) {
      debugPrint('PipecatService: Data channel state: $state');
    };
  }

  String _currentBotText = "";

  void _handleServerMessage(Map<String, dynamic> data) {
    final type = data['type'] as String?;
    final payload = data['data'] is Map ? data['data'] : {};

    switch (type) {
      case 'user-transcription':
        final text = payload['text'] as String? ?? '';
        final isFinal = payload['is_final'] as bool? ?? true;
        if (text.isNotEmpty) {
          _transcriptController.add(
            PipecatTranscript(text: text, speaker: 'user', isFinal: isFinal),
          );
        }
        break;

      case 'bot-llm-text':
        final text = payload['text'] as String? ?? '';
        if (text.isNotEmpty) {
          _botOutputController.add(text);
          _currentBotText += text;
          _transcriptController.add(
            PipecatTranscript(
              text: _currentBotText,
              speaker: 'bot',
              isFinal: false,
            ),
          );
        }
        break;

      case 'bot-tts-stopped':
        if (_currentBotText.isNotEmpty) {
          _transcriptController.add(
            PipecatTranscript(
              text: _currentBotText,
              speaker: 'bot',
              isFinal: true,
            ),
          );
          _currentBotText = "";
        }
        break;

      case 'user-started-speaking':
        debugPrint('🎤 Bạn đang nói...');
        break;

      case 'user-stopped-speaking':
        debugPrint('🛑 Bạn đã dừng nói');
        break;

      case 'error':
        final message = payload['message'] as String? ?? 'Unknown error';
        _errorController.add(message);
        break;
    }
  }

  // ── Public methods ────────────────────────────────────────────────────

  void setMicEnabled(bool enabled) {
    _localStream?.getAudioTracks().forEach((track) {
      track.enabled = enabled;
    });
  }

  void sendTextMessage(String text) {
    if (_dataChannel?.state != RTCDataChannelState.RTCDataChannelOpen) return;
    _dataChannel!.send(
      RTCDataChannelMessage(
        jsonEncode({
          'type': 'text',
          'data': {'text': text},
        }),
      ),
    );
  }

  Future<void> disconnect() async {
    await _cleanup();
    _updateState(PipecatConnectionState.disconnected);
  }

  Future<void> _cleanup() async {
    try {
      _dataChannel?.close();
      _dataChannel = null;

      _localStream?.getTracks().forEach((track) => track.stop());
      await _localStream?.dispose();
      _localStream = null;

      await _pc?.close();
      _pc = null;

      // Abandon AudioFocus sau khi đóng peer connection
      await _audioChannel.invokeMethod('abandonAudioFocus');
    } catch (e) {
      debugPrint('PipecatService: Cleanup error: $e');
    }
  }

  void _updateState(PipecatConnectionState state) {
    _state = state;
    _connectionStateController.add(state);
  }

  void dispose() {
    disconnect();
    _connectionStateController.close();
    _transcriptController.close();
    _botOutputController.close();
    _errorController.close();
    _audioLevelController.close();
  }
}
