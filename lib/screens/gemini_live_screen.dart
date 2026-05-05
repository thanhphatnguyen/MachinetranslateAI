import 'package:permission_handler/permission_handler.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/service_manager.dart';

class GeminiLiveScreen extends StatefulWidget {
  const GeminiLiveScreen({super.key});

  @override
  State<GeminiLiveScreen> createState() => _GeminiLiveScreenState();
}

class _GeminiLiveScreenState extends State<GeminiLiveScreen> {
  String _apiKey = "";
  String _model = "gemini-3.1-flash-live-preview";
  String _prompt =
      "Bạn là một thông dịch viên, khi nghe tiếng Đức hãy phiên dịch sang tiếng Việt, không nói gì thêm, không giải thích gì thêm!";

  final ServiceManager _serviceManager = ServiceManager();

  @override
  void initState() {
    super.initState();
    _loadSettings();
    
    // Lắng nghe thay đổi trạng thái service
    _serviceManager.onStateChanged = (_) {
      if (mounted) setState(() {});
    };
  }

  // Đọc cấu hình đã lưu
  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _apiKey = prefs.getString('settings_api_key') ?? "";
      _model =
          prefs.getString('settings_model') ?? "gemini-3.1-flash-live-preview";
      _prompt = prefs.getString('settings_prompt') ?? _prompt;
    });
  }

  // Lưu cấu hình
  Future<void> _saveSettings() async {
    if (_apiKey.trim().isEmpty) {
      _showErrorDialog(
        "Thiếu thông tin",
        "Google API Key là bắt buộc, không được để trống!",
      );
      return;
    }
    if (_model.trim().isEmpty) {
      _showErrorDialog(
        "Thiếu thông tin",
        "Google Model là bắt buộc, không được để trống!",
      );
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('settings_api_key', _apiKey);
    await prefs.setString('settings_model', _model);
    await prefs.setString('settings_prompt', _prompt);

    if (mounted) {
      Navigator.pop(context); // Đóng Modal Settings
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            "✅ Đã lưu cài đặt!",
            style: TextStyle(color: Colors.white),
          ),
          backgroundColor: Colors.green,
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  void _showErrorDialog(String title, String content) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF2A2A2A),
        title: Text(title, style: const TextStyle(color: Colors.white)),
        content: Text(content, style: const TextStyle(color: Colors.white70)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text(
              "OK",
              style: TextStyle(color: Colors.green, fontSize: 16),
            ),
          ),
        ],
      ),
    );
  }

  // Mở Popup Cài đặt (giống Modal bên React Native)
  void _showSettingsModal() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1A1A1A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(
              context,
            ).viewInsets.bottom, // Đẩy lên khi bàn phím xuất hiện
            left: 20,
            right: 20,
            top: 20,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Header của Modal
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      "⚙️ Cài đặt",
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, color: Colors.grey),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
                const SizedBox(height: 10),

                // Form Inputs
                _buildLabel("🔑 Google API Key *"),
                _buildTextField(
                  _apiKey,
                  (val) => _apiKey = val,
                  obscureText: true,
                  hintText: "Bắt buộc nhập API Key...",
                ),

                _buildLabel("🤖 Model"),
                _buildTextField(
                  _model,
                  (val) => _model = val,
                  hintText: "Nhập tên model...",
                ),

                _buildLabel("💬 Prompt (System Instruction)"),
                _buildTextField(
                  _prompt,
                  (val) => _prompt = val,
                  maxLines: 5,
                  hintText: "Nhập prompt hướng dẫn AI...",
                ),

                const SizedBox(height: 20),

                // Nút Lưu
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.green,
                    minimumSize: const Size.fromHeight(50),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  onPressed: _saveSettings,
                  child: const Text(
                    "💾 LƯU CÀI ĐẶT",
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                      letterSpacing: 1,
                    ),
                  ),
                ),
                const SizedBox(height: 30), // Padding đáy an toàn
              ],
            ),
          ),
        );
      },
    );
  }

  // Widget hỗ trợ vẽ Label cho Form
  Widget _buildLabel(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8.0, top: 16.0),
      child: Text(
        text,
        style: const TextStyle(
          color: Colors.grey,
          fontSize: 14,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  // Widget hỗ trợ vẽ Input cho Form
  Widget _buildTextField(
    String initialValue,
    Function(String) onChanged, {
    bool obscureText = false,
    int maxLines = 1,
    String hintText = "",
  }) {
    return TextFormField(
      initialValue: initialValue,
      style: const TextStyle(color: Colors.white, fontSize: 15),
      onChanged: onChanged,
      obscureText: obscureText,
      maxLines: maxLines,
      decoration: InputDecoration(
        hintText: hintText,
        hintStyle: const TextStyle(color: Color(0xFF666666)),
        filled: true,
        fillColor: const Color(0xFF2A2A2A),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 12,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: Color(0xFF444444)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: Color(0xFF444444)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: Colors.green),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isRunning = _serviceManager.isGeminiLiveRunning;

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: const Text(
          "🎧 AI Smart Gemini Live",
          style: TextStyle(
            color: Colors.white,
            fontSize: 20,
            fontWeight: FontWeight.bold,
          ),
        ),
        centerTitle: true,
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.settings, color: Colors.white, size: 28),
            onPressed: _showSettingsModal,
          ),
        ],
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Hiển thị trạng thái
              if (isRunning) ...[
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1A1A1A),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: const Color(0xFF00C853).withValues(alpha: 0.3),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: const Color(0xFF00C853),
                          boxShadow: [
                            BoxShadow(
                              color: const Color(0xFF00C853).withValues(alpha: 0.5),
                              blurRadius: 6,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      const Text(
                        "ĐANG CHẠY NGẦM",
                        style: TextStyle(
                          color: Color(0xFF69F0AE),
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
              ],

              // Nút Bắt đầu
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.green,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  onPressed: isRunning
                      ? null
                      : () async {
                          if (_apiKey.isEmpty) {
                            _showErrorDialog(
                              "Yêu cầu",
                              "Vui lòng nhập Google API Key trước khi bắt đầu!",
                            );
                            _showSettingsModal();
                          } else {
                            // 1. XIN QUYỀN TRƯỚC KHI CHẠY
                            await Permission.notification.request();
                            await Permission.microphone.request();

                            // 2. KIỂM TRA XEM USER CÓ CHO PHÉP KHÔNG
                            if (await Permission.microphone.isGranted) {
                              final success = await _serviceManager.startGeminiLive();
                              if (success && mounted) {
                                setState(() {});
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text("✅ Đã bắt đầu chạy ngầm!"),
                                    backgroundColor: Colors.green,
                                    duration: Duration(seconds: 2),
                                  ),
                                );
                              }
                            } else {
                              _showErrorDialog(
                                "Thiếu quyền",
                                "Bạn phải cấp quyền Micro để AI có thể nghe và dịch!",
                              );
                            }
                          }
                        },
                  child: Text(
                    "▶️ BẮT ĐẦU CHẠY NGẦM",
                    style: TextStyle(
                      color: isRunning ? Colors.grey : Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // Nút Dừng
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.red,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  onPressed: isRunning
                      ? () async {
                          await _serviceManager.stopGeminiLive();
                          if (mounted) {
                            setState(() {});
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text("⏹️ Đã dừng chạy ngầm!"),
                                backgroundColor: Colors.red,
                                duration: Duration(seconds: 2),
                              ),
                            );
                          }
                        }
                      : null,
                  child: Text(
                    "⏹️ DỪNG CHẠY NGẦM",
                    style: TextStyle(
                      color: isRunning ? Colors.white : Colors.grey,
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 24),

              const Text(
                "(Tắt màn hình app vẫn sẽ nghe và dịch)",
                style: TextStyle(color: Colors.grey, fontSize: 14),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
