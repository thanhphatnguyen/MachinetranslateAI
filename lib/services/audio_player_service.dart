import 'dart:convert';
import 'dart:typed_data';
import 'package:audioplayers/audioplayers.dart';

class AudioPlayerService {
  final AudioPlayer _audioPlayer = AudioPlayer();

  AudioPlayerService() {
    // KÝ HIỆP ƯỚC HÒA BÌNH: Cấu hình cho Loa không được giật quyền của Mic
    _audioPlayer.setAudioContext(
      AudioContext(
        android: AudioContextAndroid(
          audioFocus: AndroidAudioFocus.none, // Bỏ tranh giành quyền!
          contentType: AndroidContentType.speech,
          usageType: AndroidUsageType.media,
        ),
        iOS: AudioContextIOS(
          category: AVAudioSessionCategory.playAndRecord,
          options: {
            // <--- ĐỔI NGOẶC VUÔNG '[' THÀNH NGOẶC NHỌN '{' Ở ĐÂY
            AVAudioSessionOptions.defaultToSpeaker,
            AVAudioSessionOptions.mixWithOthers,
          }, // <--- VÀ ĐỔI NGOẶC VUÔNG ']' THÀNH NGOẶC NHỌN '}' Ở ĐÂY
        ),
      ),
    );
  }

  Future<void> playAudio(String base64Audio) async {
    try {
      // 1. Giải mã Base64 thành mảng byte PCM thô
      Uint8List pcmBytes = base64Decode(base64Audio);

      // 2. Gắn đầu chuẩn WAV (Google Gemini mặc định trả về PCM 24000Hz, 1 channel)
      Uint8List wavBytes = _addWavHeader(pcmBytes, 24000);

      // 3. Phát âm thanh trực tiếp từ RAM
      await _audioPlayer.play(BytesSource(wavBytes));
      print("🔊 Đang phát âm thanh từ AI...");
    } catch (e) {
      print("❌ [Lỗi Loa]: Không thể phát âm thanh - $e");
    }
  }

  // Hàm chế tạo "Nón WAV" thần thánh
  Uint8List _addWavHeader(Uint8List pcmData, int sampleRate) {
    int channels = 1;
    int byteRate = sampleRate * channels * 2;
    var header = ByteData(44);

    header.setUint32(0, 0x52494646, Endian.big); // "RIFF"
    header.setUint32(4, 36 + pcmData.length, Endian.little);
    header.setUint32(8, 0x57415645, Endian.big); // "WAVE"
    header.setUint32(12, 0x666D7420, Endian.big); // "fmt "
    header.setUint32(16, 16, Endian.little); // chunk size
    header.setUint16(20, 1, Endian.little); // Định dạng PCM
    header.setUint16(22, channels, Endian.little);
    header.setUint32(24, sampleRate, Endian.little);
    header.setUint32(28, byteRate, Endian.little);
    header.setUint16(32, channels * 2, Endian.little);
    header.setUint16(34, 16, Endian.little); // bits per sample
    header.setUint32(36, 0x64617461, Endian.big); // "data"
    header.setUint32(40, pcmData.length, Endian.little);

    var wavBuilder = BytesBuilder();
    wavBuilder.add(header.buffer.asUint8List());
    wavBuilder.add(pcmData);
    return wavBuilder.toBytes();
  }
}

// Xuất ra một biến xài chung
final audioPlayerService = AudioPlayerService();
