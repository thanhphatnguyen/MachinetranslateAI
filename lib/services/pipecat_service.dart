import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:http/http.dart' as http;
import '../models/ai_translate_config.dart';

enum PipecatConnectionState {
  disconnected,
  connecting,
  connected,
  error,
}

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

  RTCPeerConnection? _pc;
  MediaStream? _localStream;
  RTCDataChannel? _dataChannel;
  AiTranslateConfig? _config;

  final _connectionStateController =
      StreamController<PipecatConnectionState>.broadcast();
  final _transcriptController =
      StreamController<PipecatTranscript>.broadcast();
  final _botOutputController = StreamController<String>.broadcast();
  final _errorController = StreamController<String>.broadcast();
  final _audioLevelController = StreamController<double>.broadcast();

  Stream<PipecatConnectionState> get connectionState =>
      _connectionStateController.stream;
  Stream<PipecatTranscript> get transcripts =>
      _transcriptController.stream;
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
          {'urls': 'stun:stun.l.google.com:19302'},
          {'urls': 'stun:stun1.l.google.com:19302'},
          {
            'urls': 'turn:openrelay.metered.ca:80',
            'username': 'openrelayproject',
            'credential': 'openrelayproject',
          },
          {
            'urls': 'turn:openrelay.metered.ca:443',
            'username': 'openrelayproject',
            'credential': 'openrelayproject',
          },
          {
            'urls': 'turns:openrelay.metered.ca:443',
            'username': 'openrelayproject',
            'credential': 'openrelayproject',
          },
        ]
      };

      _pc = await createPeerConnection(iceConfig);

      _localStream = await navigator.mediaDevices.getUserMedia({
        'audio': true,
        'video': false,
      });

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
            'PipecatService: Remote track received: ${event.track.kind}');
      };

      _pc!.onConnectionState = (RTCPeerConnectionState state) {
        debugPrint('PipecatService: Connection state: $state');
        if (state ==
            RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
          _updateState(PipecatConnectionState.connected);
        } else if (state ==
                RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
            state ==
                RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
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
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'sdp': localDesc!.sdp,
          'type': localDesc.type,
          'config': config.toServerParams(),
        }),
      );

      debugPrint('PipecatService: Response ${response.statusCode}: ${response.body}');

      if (response.statusCode != 200) {
        throw Exception(
            'Server error: ${response.statusCode} - ${response.body}');
      }

      final answerData = jsonDecode(response.body);
      debugPrint('PipecatService: Answer data type: ${answerData.runtimeType}');

      if (answerData is! Map) {
        throw Exception('Unexpected response format: ${answerData.runtimeType}');
      }

      final sdp = answerData['sdp'];
      final type = answerData['type'];
      debugPrint('PipecatService: SDP type: ${sdp.runtimeType}, type field: ${type.runtimeType}');

      if (sdp is! String || type is! String) {
        throw Exception('Invalid SDP or type in response: sdp=${sdp.runtimeType}, type=${type.runtimeType}');
      }

      final answer = RTCSessionDescription(sdp, type);
      await _pc!.setRemoteDescription(answer);

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

  void _handleServerMessage(Map<String, dynamic> data) {
    final type = data['type'] as String?;
    final payload = data['data'];

    switch (type) {
      case 'transcript':
        final text = payload['text'] as String? ?? '';
        final speaker = payload['speaker'] as String? ?? 'user';
        final isFinal = payload['is_final'] as bool? ?? true;
        final timestamp = payload['timestamp'] as String?;
        if (text.isNotEmpty) {
          _transcriptController.add(PipecatTranscript(
            text: text,
            speaker: speaker,
            timestamp: timestamp,
            isFinal: isFinal,
          ));
        }
        break;

      case 'bot_output':
        final text = payload['text'] as String? ?? '';
        if (text.isNotEmpty) _botOutputController.add(text);
        break;

      case 'bot_transcript':
        final text = payload['text'] as String? ?? '';
        if (text.isNotEmpty) {
          _transcriptController
              .add(PipecatTranscript(text: text, speaker: 'bot'));
        }
        break;

      case 'user_transcript':
        final text = payload['text'] as String? ?? '';
        final userId = payload['user_id'] as String?;
        final isFinal = payload['is_final'] as bool? ?? true;
        final timestamp = payload['timestamp'] as String?;
        if (text.isNotEmpty) {
          _transcriptController.add(PipecatTranscript(
            text: text,
            speaker: userId != null ? 'user ($userId)' : 'user',
            timestamp: timestamp,
            isFinal: isFinal,
          ));
        }
        break;

      case 'llm_text':
        final text = payload['text'] as String? ?? '';
        if (text.isNotEmpty && _config?.instantResponse == true) {
          _transcriptController
              .add(PipecatTranscript(text: text, speaker: 'llm'));
        }
        break;

      case 'error':
        final message =
            payload['message'] as String? ?? 'Unknown error';
        _errorController.add(message);
        break;

      case 'connected':
        debugPrint('PipecatService: Server confirmed connection');
        break;

      case 'bot_ready':
        debugPrint('PipecatService: Bot is ready');
        break;

      case 'speaking':
        final speaker = payload['speaker'] as String?;
        final isSpeaking = payload['is_speaking'] as bool? ?? false;
        debugPrint(
            'PipecatService: $speaker ${isSpeaking ? "started" : "stopped"} speaking');
        break;

      default:
        debugPrint('PipecatService: Unknown message type: $type');
    }
  }

  void setMicEnabled(bool enabled) {
    final audioTracks = _localStream?.getAudioTracks();
    if (audioTracks != null) {
      for (final track in audioTracks) {
        track.enabled = enabled;
      }
    }
  }

  void sendTextMessage(String text) {
    if (_dataChannel?.state !=
        RTCDataChannelState.RTCDataChannelOpen) {
      return;
    }
    _dataChannel!.send(RTCDataChannelMessage(jsonEncode({
      'type': 'text',
      'data': {'text': text},
    })));
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
