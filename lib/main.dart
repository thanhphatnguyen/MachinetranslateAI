import 'package:flutter/material.dart';
import 'screens/home_screen.dart';
import 'services/background_task_service.dart'; // <--- Nối file dịch vụ vào đây

void main() async {
  // 1. Phải khởi tạo Flutter Binding trước
  WidgetsFlutterBinding.ensureInitialized();

  // 2. NẠP TRÍ NHỚ CHO BACKGROUND SERVICE (Thiếu dòng này là luồng ngầm bị tịt ngòi)
  await initializeService();

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
