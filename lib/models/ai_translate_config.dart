import 'package:shared_preferences/shared_preferences.dart';

enum TranslateMode { sttLlmTts, geminiLive }

enum AudioOutputOption {
  phone, // Loa ngoài điện thoại (speakerphone)
  bluetooth, // Thiết bị Bluetooth đang kết nối
  earpiece, // Loa trong điện thoại (nhỏ, áp tai)
}

enum AudioStreamType {
  media, // Media (nhạc, video)
  assistant, // Trợ lý AI (voice assistant)
  communication, // Giao tiếp (call, voice chat)
}

class AiTranslateConfig {
  // Server
  String serverUrl;

  // Mode
  TranslateMode mode;

  // STT + LLM + TTS mode
  String sttProvider;
  String sttApiKey;
  String llmProvider;
  String llmApiKey;
  String llmModel;
  String ttsProvider;
  String ttsApiKey;
  bool speakerDiarization;
  bool instantResponse;

  // Audio output
  AudioOutputOption audioOutput;
  AudioStreamType audioStreamType;

  // Gemini Live mode
  String googleApiKey;
  String geminiModel;
  String customGeminiModel;
  String geminiVoice;
  String geminiPrompt;

  AiTranslateConfig({
    this.serverUrl = '',
    this.mode = TranslateMode.sttLlmTts,
    this.sttProvider = 'none',
    this.sttApiKey = '',
    this.llmProvider = 'none',
    this.llmApiKey = '',
    this.llmModel = '',
    this.ttsProvider = 'none',
    this.ttsApiKey = '',
    this.speakerDiarization = false,
    this.instantResponse = false,
    this.audioOutput = AudioOutputOption.phone,
    this.audioStreamType = AudioStreamType.assistant,
    this.googleApiKey = '',
    this.geminiModel = 'gemini-3.1-flash-live-preview',
    this.customGeminiModel = '',
    this.geminiVoice = 'Aoede',
    this.geminiPrompt =
        'You are a helpful translator. Translate what the user says to Vietnamese.',
  });

  static const _keys = [
    'ai_translate_server_url',
    'ai_translate_mode',
    'ai_translate_stt_provider',
    'ai_translate_stt_api_key',
    'ai_translate_llm_provider',
    'ai_translate_llm_api_key',
    'ai_translate_llm_model',
    'ai_translate_tts_provider',
    'ai_translate_tts_api_key',
    'ai_translate_speaker_diarization',
    'ai_translate_instant_response',
    'ai_translate_google_api_key',
    'ai_translate_gemini_model',
    'ai_translate_gemini_voice',
    'ai_translate_gemini_prompt',
    'ai_translate_custom_gemini_model',
    'ai_translate_audio_output',
    'ai_translate_audio_stream_type',
  ];

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    serverUrl = prefs.getString(_keys[0]) ?? '';
    mode = TranslateMode.values[prefs.getInt(_keys[1]) ?? 0];
    sttProvider = prefs.getString(_keys[2]) ?? 'none';
    sttApiKey = prefs.getString(_keys[3]) ?? '';
    llmProvider = prefs.getString(_keys[4]) ?? 'none';
    llmApiKey = prefs.getString(_keys[5]) ?? '';
    llmModel = prefs.getString(_keys[6]) ?? '';
    ttsProvider = prefs.getString(_keys[7]) ?? 'none';
    ttsApiKey = prefs.getString(_keys[8]) ?? '';
    speakerDiarization = prefs.getBool(_keys[9]) ?? false;
    instantResponse = prefs.getBool(_keys[10]) ?? false;
    googleApiKey = prefs.getString(_keys[11]) ?? '';
    geminiModel = prefs.getString(_keys[12]) ?? 'gemini-3.1-flash-live-preview';
    geminiVoice = prefs.getString(_keys[13]) ?? 'Aoede';
    geminiPrompt =
        prefs.getString(_keys[14]) ??
        'You are a helpful translator. Translate what the user says to Vietnamese.';
    customGeminiModel = prefs.getString(_keys[15]) ?? '';
    audioOutput = AudioOutputOption.values[prefs.getInt(_keys[16]) ?? 0];
    audioStreamType = AudioStreamType.values[prefs.getInt(_keys[17]) ?? 1];
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keys[0], serverUrl);
    await prefs.setInt(_keys[1], mode.index);
    await prefs.setString(_keys[2], sttProvider);
    await prefs.setString(_keys[3], sttApiKey);
    await prefs.setString(_keys[4], llmProvider);
    await prefs.setString(_keys[5], llmApiKey);
    await prefs.setString(_keys[6], llmModel);
    await prefs.setString(_keys[7], ttsProvider);
    await prefs.setString(_keys[8], ttsApiKey);
    await prefs.setBool(_keys[9], speakerDiarization);
    await prefs.setBool(_keys[10], instantResponse);
    await prefs.setString(_keys[11], googleApiKey);
    await prefs.setString(_keys[12], geminiModel);
    await prefs.setString(_keys[13], geminiVoice);
    await prefs.setString(_keys[14], geminiPrompt);
    await prefs.setString(_keys[15], customGeminiModel);
    await prefs.setInt(_keys[16], audioOutput.index);
    await prefs.setInt(_keys[17], audioStreamType.index);
  }

  List<String> validate() {
    final errors = <String>[];
    if (serverUrl.trim().isEmpty) {
      errors.add('Server URL là bắt buộc');
    }

    if (mode == TranslateMode.geminiLive) {
      if (googleApiKey.trim().isEmpty) {
        errors.add('Google API Key là bắt buộc cho Gemini Live');
      }
      if (geminiModel.trim().isEmpty) {
        errors.add('Gemini Model là bắt buộc');
      }
    } else {
      if (sttProvider != 'none' && sttApiKey.trim().isEmpty) {
        errors.add('API Key cho STT ($sttProvider) là bắt buộc');
      }
      if (llmProvider != 'none' && llmApiKey.trim().isEmpty) {
        errors.add('API Key cho LLM ($llmProvider) là bắt buộc');
      }
      if (llmProvider != 'none' && llmModel.trim().isEmpty) {
        errors.add('Model cho LLM ($llmProvider) là bắt buộc');
      }
      if (ttsProvider != 'none' && ttsApiKey.trim().isEmpty) {
        errors.add('API Key cho TTS ($ttsProvider) là bắt buộc');
      }
    }
    return errors;
  }

  String buildConnectUrl() {
    String url = serverUrl.trim();
    if (!url.endsWith('/connect')) {
      url = '$url/connect';
    }
    return url;
  }

  Map<String, dynamic> toServerParams() {
    if (mode == TranslateMode.geminiLive) {
      final model = geminiModel == 'custom' ? customGeminiModel : geminiModel;
      return {
        'mode': 'gemini_live',
        'google_api_key': googleApiKey,
        'model': model,
        'voice': geminiVoice,
        'prompt': geminiPrompt,
      };
    }

    return {
      'mode': 'stt_llm_tts',
      'stt': sttProvider == 'none'
          ? null
          : {'provider': sttProvider, 'api_key': sttApiKey},
      'llm': llmProvider == 'none'
          ? null
          : {'provider': llmProvider, 'api_key': llmApiKey, 'model': llmModel},
      'tts': ttsProvider == 'none'
          ? null
          : {'provider': ttsProvider, 'api_key': ttsApiKey},
      'speaker_diarization': speakerDiarization,
      'instant_response': instantResponse,
    };
  }
}

const List<String> sttProviders = [
  'none',
  'soniox',
  'deepgram',
  'google',
  'assemblyai',
  'openai',
  'whisper',
];

const List<String> llmProviders = [
  'none',
  'openai',
  'anthropic',
  'google',
  'groq',
  'mistral',
];

const List<String> ttsProviders = [
  'none',
  'soniox',
  'cartesia',
  'elevenlabs',
  'openai',
  'deepgram',
  'google',
];

const List<String> geminiModels = [
  'gemini-3.1-flash-live-preview',
  'gemini-2.0-flash-live-001',
  'gemini-2.0-flash-exp',
  'gemini-1.5-flash-live-002',
  'custom',
];

const List<String> geminiVoices = ['Aoede', 'Puck', 'Charon', 'Kore', 'Fenrir'];
