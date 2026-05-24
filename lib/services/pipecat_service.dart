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
  final String sourceText;
  final bool isProTranslate;
  final String audioTarget; // ← MỚI: "speaker1" hoặc "speaker2"
  final String translationLanguage;
  final String sourceLanguage;

  PipecatTranscript({
    required this.text,
    required this.speaker,
    this.timestamp,
    this.isFinal = true,
    this.sourceText = '',
    this.isProTranslate = false,
    this.audioTarget = 'speaker1', // ← MỚI
    this.translationLanguage = '',
    this.sourceLanguage = '',
  });
}

class PipecatPartialTranscript {
  final String text;
  final String speaker;
  final String language;

  PipecatPartialTranscript({
    required this.text,
    required this.speaker,
    this.language = '',
  });
}

class PipecatService {
  static final PipecatService _instance = PipecatService._();
  factory PipecatService() => _instance;
  PipecatService._();

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
  final _partialTranscriptController =
      StreamController<PipecatPartialTranscript>.broadcast();
  final _botOutputController = StreamController<String>.broadcast();
  final _errorController = StreamController<String>.broadcast();
  final _audioLevelController = StreamController<double>.broadcast();

  Stream<PipecatConnectionState> get connectionState =>
      _connectionStateController.stream;
  Stream<PipecatTranscript> get transcripts => _transcriptController.stream;
  Stream<PipecatPartialTranscript> get partialTranscripts =>
      _partialTranscriptController.stream;
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
    debugPrint('PipecatService: _applyAudioOutput called: ${output.name}');
    try {
      final outputType = output.name;
      debugPrint('PipecatService: invoking setAudioOutput type=$outputType');
      final result = await _audioChannel.invokeMethod('setAudioOutput', {
        'type': outputType,
      });
      debugPrint('PipecatService: setAudioOutput result=$result');
    } catch (e) {
      debugPrint('PipecatService: setAudioOutput EXCEPTION: $e');
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
      final typeName = type.name;
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

  // ── Helper: tính audioTarget từ speaker label ─────────────────────────
  // Speaker 1 từ Soniox → output device 1
  // Speaker 2 từ Soniox → output device 2
  String _inferAudioTarget(
    String speaker,
    String? serverTarget,
    String translationLanguage,
  ) {
    // Ưu tiên dùng giá trị server gửi về nếu có
    if (serverTarget != null && serverTarget.isNotEmpty) {
      return serverTarget;
    }
    final config = _config;
    if (config != null &&
        config.proTranslationType == 'two_way' &&
        config.proTwoWayProcessLogic == 'translate' &&
        translationLanguage.isNotEmpty) {
      return translationLanguage == config.proSourceLanguage
          ? 'speaker2'
          : 'speaker1';
    }
    // Fallback: tự tính từ speaker label
    final numStr = speaker.replaceAll(RegExp(r'[^0-9]'), '');
    final num = int.tryParse(numStr) ?? 1;
    return num == 1 ? 'speaker1' : 'speaker2';
  }

  void _handleServerMessage(Map<String, dynamic> data) {
    final type = data['type'] as String?;
    final payload = data['data'] is Map
        ? data['data'] as Map<String, dynamic>
        : <String, dynamic>{};

    switch (type) {
      case 'pro_translate':
        final speaker = payload['speaker'] as String? ?? 'Speaker 1';
        final source = payload['source'] as String? ?? '';
        final translation = payload['translation'] as String? ?? '';
        final translationLanguage =
            payload['translation_language'] as String? ?? '';
        final sourceLanguage = payload['source_language'] as String? ?? '';
        // Lấy audio_target từ server (ws_server.py gửi về)
        final serverTarget = payload['audio_target'] as String?;
        final audioTarget = _inferAudioTarget(
          speaker,
          serverTarget,
          translationLanguage,
        );

        debugPrint(
          'PipecatService: pro_translate speaker=$speaker translationLanguage=$translationLanguage → audioTarget=$audioTarget',
        );

        if (translation.isNotEmpty) {
          _transcriptController.add(
            PipecatTranscript(
              text: translation,
              speaker: speaker,
              isFinal: true,
              sourceText: source,
              isProTranslate: true,
              audioTarget: audioTarget, // ← MỚI
              translationLanguage: translationLanguage,
              sourceLanguage: sourceLanguage,
            ),
          );
        }
        break;

      case 'pro_input_partial':
        final speaker = payload['speaker'] as String? ?? '1';
        final source = payload['source'] as String? ?? '';
        final language = payload['language'] as String? ?? '';
        if (source.isNotEmpty) {
          _partialTranscriptController.add(
            PipecatPartialTranscript(
              text: source,
              speaker: speaker,
              language: language,
            ),
          );
        }
        break;

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
    _partialTranscriptController.close();
    _botOutputController.close();
    _errorController.close();
    _audioLevelController.close();
  }
}
