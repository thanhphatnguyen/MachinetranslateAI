import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
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

  WebSocketChannel? _channel;
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
      final wsUrl = _buildWebSocketUrl(config.serverUrl);
      debugPrint('PipecatService: Connecting to $wsUrl');

      _channel = WebSocketChannel.connect(Uri.parse(wsUrl));

      await _channel!.ready;

      _updateState(PipecatConnectionState.connected);

      _sendConfig(config);

      _channel!.stream.listen(
        _onMessage,
        onError: _onError,
        onDone: _onDone,
      );
    } catch (e) {
      debugPrint('PipecatService: Connection error: $e');
      _updateState(PipecatConnectionState.error);
      _errorController.add('Connection failed: $e');
    }
  }

  String _buildWebSocketUrl(String serverUrl) {
    String url = serverUrl.trim();
    if (url.startsWith('http://')) {
      url = url.replaceFirst('http://', 'ws://');
    } else if (url.startsWith('https://')) {
      url = url.replaceFirst('https://', 'wss://');
    }
    if (!url.startsWith('ws://') && !url.startsWith('wss://')) {
      url = 'wss://$url';
    }
    if (!url.endsWith('/ws')) {
      url = '$url/ws';
    }
    return url;
  }

  void _sendConfig(AiTranslateConfig config) {
    final message = {
      'type': 'config',
      'data': config.toServerParams(),
    };

    _sendMessage(message);
  }

  void sendAudioData(List<int> audioBytes) {
    if (!isConnected) return;

    _channel!.sink.add(audioBytes);
  }

  void sendTextMessage(String text) {
    if (!isConnected) return;

    _sendMessage({
      'type': 'text',
      'data': {'text': text},
    });
  }

  void _sendMessage(Map<String, dynamic> message) {
    try {
      final jsonStr = jsonEncode(message);
      _channel?.sink.add(jsonStr);
    } catch (e) {
      debugPrint('PipecatService: Send error: $e');
    }
  }

  void _onMessage(dynamic message) {
    try {
      if (message is String) {
        final data = jsonDecode(message);
        _handleServerMessage(data);
      } else if (message is List<int>) {
        _audioLevelController.add(0.5);
      }
    } catch (e) {
      debugPrint('PipecatService: Message parse error: $e');
    }
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
        if (text.isNotEmpty) {
          _botOutputController.add(text);
        }
        break;

      case 'bot_transcript':
        final text = payload['text'] as String? ?? '';
        if (text.isNotEmpty) {
          _transcriptController.add(PipecatTranscript(
            text: text,
            speaker: 'bot',
          ));
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
          _transcriptController.add(PipecatTranscript(
            text: text,
            speaker: 'llm',
          ));
        }
        break;

      case 'error':
        final message = payload['message'] as String? ?? 'Unknown error';
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

  void _onError(Object error) {
    debugPrint('PipecatService: WebSocket error: $error');
    _updateState(PipecatConnectionState.error);
    _errorController.add('WebSocket error: $error');
  }

  void _onDone() {
    debugPrint('PipecatService: WebSocket closed');
    _updateState(PipecatConnectionState.disconnected);
  }

  void _updateState(PipecatConnectionState state) {
    _state = state;
    _connectionStateController.add(state);
  }

  Future<void> disconnect() async {
    try {
      await _channel?.sink.close();
    } catch (e) {
      debugPrint('PipecatService: Disconnect error: $e');
    }
    _channel = null;
    _updateState(PipecatConnectionState.disconnected);
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
