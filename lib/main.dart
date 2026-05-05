import 'package:flutter/material.dart';
import 'screens/home_screen.dart';
import 'services/unified_background_service.dart';

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
      home: const HomeScreen(),
      debugShowCheckedModeBanner: false,
    );
  }
}
