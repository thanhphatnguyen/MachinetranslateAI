import 'package:flutter/material.dart';
import 'services/unified_background_service.dart';
import 'widgets/auth_gate.dart';

void main() async {
  // 1. Phải khởi tạo Flutter Binding trước
  WidgetsFlutterBinding.ensureInitialized();

  // 2. Khởi tạo Unified Background Service (chỉ 1 lần)
  await UnifiedBackgroundService.initialize();

  // 3. Khởi chạy giao diện App
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AI Smart Gemini Live',
      theme: ThemeData(
        brightness: Brightness.dark,
        primaryColor: Colors.green,
        scaffoldBackgroundColor: Colors.black,
      ),
      home: const AuthGate(),
      debugShowCheckedModeBanner: false,
    );
  }
}
