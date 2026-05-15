import 'package:flutter/material.dart';
import 'offline_translate_screen.dart';
import 'ai_translate_screen.dart';
import '../services/service_manager.dart';
import '../services/license_service.dart';
import '../widgets/license_dialog.dart';

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
      backgroundColor: const Color(0xFFF8FAFC),
      body: SafeArea(
        child: FadeTransition(
          opacity: _fadeAnimation,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Column(
              children: [
                const SizedBox(height: 48),

                // Logo
                ScaleTransition(
                  scale: _pulseAnimation,
                  child: Container(
                    width: 88,
                    height: 88,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: const LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [Color(0xFF0EA5E9), Color(0xFF38BDF8)],
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFF0EA5E9).withValues(alpha: 0.3),
                          blurRadius: 28,
                          spreadRadius: 4,
                        ),
                      ],
                    ),
                    child: const Icon(
                      Icons.translate_rounded,
                      color: Colors.white,
                      size: 42,
                    ),
                  ),
                ),

                const SizedBox(height: 28),

                // App Title
                const Text(
                  "Machine Translate AI",
                  style: TextStyle(
                    color: Color(0xFF0F172A),
                    fontSize: 28,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.5,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  "Chọn chế độ dịch phù hợp với bạn",
                  style: TextStyle(
                    color: Color(0xFF64748B),
                    fontSize: 15,
                    fontWeight: FontWeight.w400,
                  ),
                ),

                // Running status
                if (isAnyRunning) ...[
                  const SizedBox(height: 20),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 18,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0EA5E9).withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(
                        color: const Color(0xFF0EA5E9).withValues(alpha: 0.2),
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
                            color: const Color(0xFF0EA5E9),
                            boxShadow: [
                              BoxShadow(
                                color: const Color(0xFF0EA5E9).withValues(alpha: 0.5),
                                blurRadius: 6,
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 10),
                        Text(
                          isGeminiRunning
                              ? "AI Live đang chạy ngầm"
                              : isOfflineRunning
                              ? "Offline đang chạy ngầm"
                              : "AI Translate đang chạy ngầm",
                          style: const TextStyle(
                            color: Color(0xFF0EA5E9),
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],

                const SizedBox(height: 48),

                // Feature Cards
                _buildFeatureCard(
                  index: 0,
                  icon: Icons.wifi_off_rounded,
                  title: "Offline Translate",
                  subtitle: isGeminiRunning
                      ? "Đang bị khóa (AI Live đang chạy)"
                      : isAiRunning
                      ? "Đang bị khóa (AI Translate đang chạy)"
                      : "Dịch ngoại tuyến, không cần internet",
                  color: const Color(0xFF64748B),
                  isEnabled: !isGeminiRunning && !isAiRunning,
                  isRunning: isOfflineRunning,
                  onTap: () {
                    if (!isGeminiRunning && !isAiRunning) {
                      _navigateTo(const OfflineTranslateScreen());
                    }
                  },
                ),

                const SizedBox(height: 16),

                _buildFeatureCard(
                  index: 1,
                  icon: Icons.auto_awesome_rounded,
                  title: "AI Translate",
                  subtitle: isGeminiRunning
                      ? "Đang bị khóa (AI Live đang chạy)"
                      : isOfflineRunning
                      ? "Đang bị khóa (Offline đang chạy)"
                      : "Dịch giọng nói thời gian thực với AI",
                  color: const Color(0xFF0EA5E9),
                  isEnabled: !isGeminiRunning && !isOfflineRunning,
                  isRunning: isAiRunning,
                  onTap: () async {
                    if (!isGeminiRunning && !isOfflineRunning) {
                      final isLicensed = await LicenseService.isLicensed();
                      if (!isLicensed && mounted) {
                        final licensed = await LicenseDialog.show(context);
                        if (!licensed) return;
                      }
                      if (mounted) {
                        _navigateTo(const AiTranslateScreen());
                      }
                    }
                  },
                ),

                const Spacer(),

                // Footer
                Padding(
                  padding: const EdgeInsets.only(bottom: 28),
                  child: Text(
                    "Powered by Thanh Phat Nguyen Deutsch",
                    style: TextStyle(
                      color: Colors.grey.shade400,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      letterSpacing: 0.3,
                    ),
                  ),
                ),
              ],
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
    required Color color,
    required VoidCallback onTap,
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
              ? color.withValues(alpha: 0.1)
              : Colors.transparent,
          child: Opacity(
            opacity: isEnabled ? 1.0 : 0.45,
            child: Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(20),
                color: Colors.white,
                border: Border.all(
                  color: isRunning
                      ? const Color(0xFF0EA5E9).withValues(alpha: 0.4)
                      : const Color(0xFFE2E8F0),
                  width: isRunning ? 1.5 : 1,
                ),
                boxShadow: [
                  BoxShadow(
                    color: isRunning
                        ? const Color(0xFF0EA5E9).withValues(alpha: 0.12)
                        : Colors.black.withValues(alpha: 0.04),
                    blurRadius: isRunning ? 20 : 12,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Row(
                children: [
                  // Icon
                  Container(
                    width: 56,
                    height: 56,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(16),
                      color: color.withValues(alpha: 0.1),
                    ),
                    child: Icon(icon, color: color, size: 28),
                  ),
                  const SizedBox(width: 16),

                  // Text
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text(
                              title,
                              style: TextStyle(
                                color: const Color(0xFF0F172A),
                                fontSize: 17,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            if (isRunning) ...[
                              const SizedBox(width: 10),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 3,
                                ),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF0EA5E9),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: const Text(
                                  "ĐANG CHẠY",
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 10,
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: 0.5,
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
                                ? const Color(0xFF94A3B8)
                                : const Color(0xFFEF4444).withValues(alpha: 0.7),
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),

                  // Arrow
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: const Color(0xFFF1F5F9),
                    ),
                    child: Icon(
                      Icons.arrow_forward_ios_rounded,
                      color: isEnabled
                          ? const Color(0xFF94A3B8)
                          : const Color(0xFFCBD5E1),
                      size: 16,
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
}
