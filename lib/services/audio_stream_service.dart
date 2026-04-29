import 'dart:convert';
import 'dart:typed_data';
import 'package:record/record.dart';

class AudioStreamService {
  final _record = AudioRecorder();
  bool _isRecording = false;

  Future<void> startStreaming(Function(String base64Chunk) onAudioChunk) async {
    if (_isRecording) return;

    // BỎ LUÔN BƯỚC CHECK QUYỀN VÌ UI ĐÃ CHECK RỒI! ÉP MỞ MIC LUÔN!
    print(
      "🎤 [AudioStream] Đã bỏ qua bước check quyền. Đang mở luồng thu âm...",
    );
    _isRecording = true;

    try {
      final stream = await _record.startStream(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: 16000,
          numChannels: 1,
        ),
      );

      print("🎤 [AudioStream] Luồng đã mở! Bắt đầu lắng nghe tiếng động...");

      stream.listen(
        (Uint8List data) {
          // Log báo tín hiệu thu âm
          print("🎤 [AudioStream] Đã thu được: ${data.length} bytes");

          if (data.isNotEmpty) {
            final base64Str = base64Encode(data);
            onAudioChunk(base64Str);
          }
        },
        onError: (err) {
          print("❌ [AudioStream] Lỗi trong lúc thu âm: $err");
        },
        onDone: () {
          print("⏹️ [AudioStream] Đã đóng luồng thu âm!");
        },
      );
    } catch (e) {
      print(
        "❌ [AudioStream] Lỗi không thể mở Mic (Cố tình ép nhưng thất bại): $e",
      );
    }
  }

  Future<void> stopStreaming() async {
    if (_isRecording) {
      await _record.stop();
      _isRecording = false;
      print("⏹️ [AudioStream] Đã ra lệnh tắt Mic.");
    }
  }
}

final audioStreamService = AudioStreamService();
