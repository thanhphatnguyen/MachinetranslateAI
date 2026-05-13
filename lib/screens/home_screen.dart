import 'package:flutter/material.dart';
import 'gemini_live_screen.dart';
import 'offline_translate_screen.dart';
import 'ai_translate_screen.dart';
import '../services/service_manager.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with TickerProviderStateMixin {
  late AnimationController _fadeController;
  late AnimationController _pulseController;
  late Animation<double> _fadeAnimation;
  late Animation<double> _pulseAnimation;

  final ServiceManager _serviceManager = ServiceManager();

  @override
  void initState() {
    super.initState();
    _fadeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    _fadeAnimation = CurvedAnimation(
      parent: _fadeController,
      curve: Curves.easeOut,
    );
    _fadeController.forward();

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    )..repeat(reverse: true);
    _pulseAnimation = Tween<double>(begin: 0.85, end: 1.0).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    // Lắng nghe thay đổi trạng thái service
    _serviceManager.onStateChanged = (_) {
      if (mounted) setState(() {});
    };
  }

  @override
  void dispose() {
    _fadeController.dispose();
    _pulseController.dispose();
    super.dispose();
  }

  void _navigateTo(Widget screen) {
    Navigator.push(
      context,
      PageRouteBuilder(
        pageBuilder: (context, animation, secondaryAnimation) => screen,
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          return FadeTransition(
            opacity: animation,
            child: SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0.05, 0),
                end: Offset.zero,
              ).animate(CurvedAnimation(
                parent: animation,
                curve: Curves.easeOut,
              )),
              child: child,
            ),
          );
        },
        transitionDuration: const Duration(milliseconds: 400),
      ),
    ).then((_) {
      // Khi quay lại HomeScreen, cập nhật trạng thái
      if (mounted) setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    final isGeminiRunning = _serviceManager.isGeminiLiveRunning;
    final isOfflineRunning = _serviceManager.isOfflineTranslateRunning;
    final isAiRunning = _serviceManager.isAiTranslateRunning;
    final isAnyRunning = _serviceManager.isAnyServiceRunning;

    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color(0xFF0A0A0A),
              Color(0xFF0D1B0E),
              Color(0xFF0A0A0A),
            ],
          ),
        ),
        child: SafeArea(
          child: FadeTransition(
            opacity: _fadeAnimation,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Column(
                children: [
                  const SizedBox(height: 40),

                  // Logo / Header
                  ScaleTransition(
                    scale: _pulseAnimation,
                    child: Container(
                      width: 80,
                      height: 80,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: const LinearGradient(
                          colors: [Color(0xFF00C853), Color(0xFF1DE9B6)],
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: const Color(0xFF00C853).withValues(alpha: 0.3),
                            blurRadius: 24,
                            spreadRadius: 4,
                          ),
                        ],
                      ),
                      child: const Icon(
                        Icons.translate_rounded,
                        color: Colors.white,
                        size: 40,
                      ),
                    ),
                  ),

                  const SizedBox(height: 24),

                  // App Title
                  const Text(
                    "Machine Translate AI",
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 28,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.5,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    "Chọn chế độ dịch phù hợp với bạn",
                    style: TextStyle(
                      color: Colors.grey.shade500,
                      fontSize: 15,
                    ),
                  ),

                  // Hiển thị trạng thái chạy ngầm
                  if (isAnyRunning) ...[
                    const SizedBox(height: 16),
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
                          Text(
                            isGeminiRunning
                                ? "AI Live đang chạy ngầm"
                                : isOfflineRunning
                                ? "Offline đang chạy ngầm"
                                : "AI Translate đang chạy ngầm",
                            style: const TextStyle(
                              color: Color(0xFF69F0AE),
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],

                  const SizedBox(height: 48),

                  // === 3 Cards ===
                  // 1. Offline Translate
                  _buildFeatureCard(
                    index: 0,
                    icon: Icons.wifi_off_rounded,
                    title: "Offline Translate",
                    subtitle: isGeminiRunning
                        ? "Đang bị khóa (AI Live đang chạy)"
                        : isAiRunning
                        ? "Đang bị khóa (AI Translate đang chạy)"
                        : "Dịch ngoại tuyến, không cần internet",
                    gradientColors: const [Color(0xFF455A64), Color(0xFF37474F)],
                    iconBgColor: const Color(0xFF546E7A),
                    isEnabled: !isGeminiRunning && !isAiRunning,
                    isRunning: isOfflineRunning,
                    onTap: () {
                      if (!isGeminiRunning && !isAiRunning) {
                        _navigateTo(const OfflineTranslateScreen());
                      }
                    },
                  ),

                  const SizedBox(height: 16),

                  // // 2. AI Live Translate (TẠM ẨN - phát triển sau)
                  // _buildFeatureCard(
                  //   index: 1,
                  //   icon: Icons.headset_mic_rounded,
                  //   title: "AI Live Translate",
                  //   subtitle: isOfflineRunning
                  //       ? "Đang bị khóa (Offline đang chạy)"
                  //       : isAiRunning
                  //       ? "Đang bị khóa (AI Translate đang chạy)"
                  //       : "Dịch trực tiếp bằng Gemini AI Live",
                  //   gradientColors: const [Color(0xFF1B5E20), Color(0xFF2E7D32)],
                  //   iconBgColor: const Color(0xFF43A047),
                  //   isHighlighted: true,
                  //   isEnabled: !isOfflineRunning && !isAiRunning,
                  //   isRunning: isGeminiRunning,
                  //   onTap: () {
                  //     if (!isOfflineRunning && !isAiRunning) {
                  //       _navigateTo(const GeminiLiveScreen());
                  //     }
                  //   },
                  // ),

                  // const SizedBox(height: 16),

                  // 3. AI Translate
                  _buildFeatureCard(
                    index: 2,
                    icon: Icons.auto_awesome_rounded,
                    title: "AI Translate",
                    subtitle: isGeminiRunning
                        ? "Đang bị khóa (AI Live đang chạy)"
                        : isOfflineRunning
                        ? "Đang bị khóa (Offline đang chạy)"
                        : "Dịch giọng nói thời gian thực với Pipecat AI",
                    gradientColors: const [Color(0xFF4A148C), Color(0xFF6A1B9A)],
                    iconBgColor: const Color(0xFF8E24AA),
                    isEnabled: !isGeminiRunning && !isOfflineRunning,
                    isRunning: isAiRunning,
                    onTap: () {
                      if (!isGeminiRunning && !isOfflineRunning) {
                        _navigateTo(const AiTranslateScreen());
                      }
                    },
                  ),

                  const Spacer(),

                  // Footer
                  Padding(
                    padding: const EdgeInsets.only(bottom: 24),
                    child: Text(
                      "Powered by Google Gemini AI",
                      style: TextStyle(
                        color: Colors.grey.shade700,
                        fontSize: 12,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildFeatureCard({
    required int index,
    required IconData icon,
    required String title,
    required String subtitle,
    required List<Color> gradientColors,
    required Color iconBgColor,
    required VoidCallback onTap,
    bool isHighlighted = false,
    bool isEnabled = true,
    bool isRunning = false,
  }) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.0, end: 1.0),
      duration: Duration(milliseconds: 600 + (index * 200)),
      curve: Curves.easeOutCubic,
      builder: (context, value, child) {
        return Transform.translate(
          offset: Offset(0, 30 * (1 - value)),
          child: Opacity(opacity: value, child: child),
        );
      },
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: isEnabled ? onTap : null,
          borderRadius: BorderRadius.circular(20),
          splashColor: isEnabled
              ? gradientColors[1].withValues(alpha: 0.3)
              : Colors.transparent,
          child: Opacity(
            opacity: isEnabled ? 1.0 : 0.4,
            child: Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(20),
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    gradientColors[0].withValues(alpha: 0.6),
                    gradientColors[1].withValues(alpha: 0.3),
                  ],
                ),
                border: Border.all(
                  color: isRunning
                      ? const Color(0xFF00C853).withValues(alpha: 0.8)
                      : isHighlighted
                          ? const Color(0xFF00C853).withValues(alpha: 0.5)
                          : Colors.white.withValues(alpha: 0.08),
                  width: isRunning ? 2.0 : isHighlighted ? 1.5 : 1,
                ),
                boxShadow: isRunning
                    ? [
                        BoxShadow(
                          color: const Color(0xFF00C853).withValues(alpha: 0.3),
                          blurRadius: 20,
                          spreadRadius: 2,
                        ),
                      ]
                    : isHighlighted
                        ? [
                            BoxShadow(
                              color: const Color(0xFF00C853).withValues(alpha: 0.15),
                              blurRadius: 20,
                              spreadRadius: 2,
                            ),
                          ]
                        : null,
              ),
              child: Row(
                children: [
                  // Icon Circle
                  Container(
                    width: 56,
                    height: 56,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: iconBgColor.withValues(alpha: 0.25),
                    ),
                    child: Icon(icon, color: Colors.white, size: 28),
                  ),
                  const SizedBox(width: 16),

                  // Text Content
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text(
                              title,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 17,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 0.3,
                              ),
                            ),
                            if (isRunning) ...[
                              const SizedBox(width: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF00C853),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: const Text(
                                  "ĐANG CHẠY",
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 10,
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: 1,
                                  ),
                                ),
                              ),
                            ] else if (isHighlighted) ...[
                              const SizedBox(width: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF00C853),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: const Text(
                                  "LIVE",
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 10,
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: 1,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          subtitle,
                          style: TextStyle(
                            color: isEnabled
                                ? Colors.white.withValues(alpha: 0.6)
                                : Colors.red.withValues(alpha: 0.6),
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),

                  // Arrow
                  Icon(
                    Icons.arrow_forward_ios_rounded,
                    color: Colors.white.withValues(alpha: isEnabled ? 0.4 : 0.2),
                    size: 18,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
