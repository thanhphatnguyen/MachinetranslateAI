import 'dart:convert';
import 'package:web_socket_channel/web_socket_channel.dart';

class GeminiSocketService {
  WebSocketChannel? _channel;
  bool isConnected = false;
  bool isInitialized = false;

  // Callbacks để báo ra ngoài
  Function(String base64Audio)? onAudioResponseComplete;
  Function(String errorMsg)? onSocketError;

  final List<String> _responseQueue = [];

  Future<void> connect(String apiKey, String model, String prompt) async {
    if (_channel != null) return;

    final url =
        'wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1alpha.GenerativeService.BidiGenerateContent?key=$apiKey';

    try {
      _channel = WebSocketChannel.connect(Uri.parse(url));

      _channel!.stream.listen(
        (message) {
          _handleMessage(message);
        },
        onError: (error) {
          onSocketError?.call("Lỗi mạng: $error");
          _resetState();
        },
        onDone: () {
          // THÊM 3 DÒNG NÀY ĐỂ BẮT QUẢ TANG GOOGLE
          print("🌐 [GeminiSocket] GOOGLE ĐÃ ĐÓNG SẬP CỬA!");
          print("🚨 Mã lỗi (Close Code): ${_channel?.closeCode}");
          print("🚨 Lý do (Close Reason): ${_channel?.closeReason}");
          _resetState();
        },
      );

      // Gửi Setup Message dặn dò AI ngay khi mở luồng
      final setupMessage = {
        "setup": {
          "model": "models/$model",
          "systemInstruction": {
            "parts": [
              {"text": prompt},
            ],
          },
          "generationConfig": {
            "responseModalities": ["AUDIO"],
          },
        },
      };
      _channel!.sink.add(jsonEncode(setupMessage));
      isConnected = true;
    } catch (e) {
      onSocketError?.call(e.toString());
    }
  }

  void _handleMessage(dynamic data) {
    try {
      // 1. GIẢI MÃ NHỊ PHÂN THÀNH CHỮ CHUẨN XÁC
      String jsonString;
      if (data is String) {
        jsonString = data;
      } else if (data is List<int>) {
        jsonString = utf8.decode(
          data,
        ); // Phải dùng utf8 để dịch mã nhị phân ra chữ
      } else {
        return;
      }

      final decoded = jsonDecode(jsonString);
      Map<String, dynamic> message = {};

      // 2. PHÂN LOẠI DỮ LIỆU
      if (decoded is List) {
        if (decoded.isEmpty) return;
        if (decoded[0] is Map) {
          message = decoded[0] as Map<String, dynamic>;
        } else {
          print("❌ [Gemini Error]: Lỗi lạ từ server - $decoded");
          onSocketError?.call("Lỗi từ Google: $decoded");
          return;
        }
      } else if (decoded is Map) {
        message = decoded as Map<String, dynamic>;
      } else {
        return;
      }

      // 3. Xác nhận setup thành công
      if (message.containsKey('setupComplete')) {
        isInitialized = true;
      }

      // 4. Gom các chunk âm thanh (Base64) từ AI trả về
      if (message['serverContent']?['modelTurn']?['parts'] != null) {
        for (var part in message['serverContent']['modelTurn']['parts']) {
          if (part['inlineData']?['data'] != null) {
            _responseQueue.add(part['inlineData']['data']);
          }
        }
      }

      // 5. Khi AI nói xong -> Gộp toàn bộ mảng chuỗi và bắn ra ngoài cho Loa phát
      if (message['serverContent']?['turnComplete'] == true ||
          message['serverContent']?['generationComplete'] == true) {
        if (_responseQueue.isNotEmpty) {
          try {
            // Giải mã từng mảnh nhỏ thành byte thô để gỡ bỏ dấu "=" (niêm phong)
            List<int> combinedBytes = [];
            for (String chunk in _responseQueue) {
              combinedBytes.addAll(base64Decode(chunk));
            }

            // Đóng gói lại toàn bộ thành 1 cục Base64 hoàn hảo và sạch sẽ
            final fullAudio = base64Encode(combinedBytes);

            _responseQueue.clear();
            onAudioResponseComplete?.call(fullAudio);
          } catch (e) {
            print("❌ Lỗi ghép file Audio: $e");
          }
        }
      }
    } catch (e) {
      print("❌ [Gemini Parse Error]: Lỗi phân tích dữ liệu json - $e");
    }
  }

  // Hàm để Micro gọi và ném âm thanh lên
  // Hàm để Micro gọi và ném âm thanh lên
  void sendAudioChunk(String base64String) {
    if (isConnected && isInitialized) {
      // Đèn báo để chắc chắn Mic vẫn đang hoạt động
      print("🎤 [Mic] Bắn âm thanh lên Google: ${base64String.length} bytes");

      final message = {
        "realtimeInput": {
          "audio": {
            // <-- Google bắt đổi thành chữ này đây
            "mimeType": "audio/pcm;rate=16000",
            "data": base64String,
          },
        },
      };
      _channel?.sink.add(jsonEncode(message));
    }
  }

  void disconnect() {
    _channel?.sink.close();
    _resetState();
  }

  void _resetState() {
    _channel = null;
    isConnected = false;
    isInitialized = false;
    _responseQueue.clear();
  }
}

// Bơm ra một biến global để các service khác xài chung
final geminiSocketService = GeminiSocketService();
