import 'package:flutter/material.dart';
import 'gemini_live_screen.dart';
import 'offline_translate_screen.dart';

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
    );
  }

  @override
  Widget build(BuildContext context) {
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

                  const SizedBox(height: 48),

                  // === 3 Cards ===
                  // 1. Offline Translate
                  _buildFeatureCard(
                    index: 0,
                    icon: Icons.wifi_off_rounded,
                    title: "Offline Translate",
                    subtitle: "Dịch ngoại tuyến, không cần internet",
                    gradientColors: const [Color(0xFF455A64), Color(0xFF37474F)],
                    iconBgColor: const Color(0xFF546E7A),
                    onTap: () {
                      _navigateTo(const OfflineTranslateScreen());
                    },
                  ),

                  const SizedBox(height: 16),

                  // 2. AI Live Translate
                  _buildFeatureCard(
                    index: 1,
                    icon: Icons.headset_mic_rounded,
                    title: "AI Live Translate",
                    subtitle: "Dịch trực tiếp bằng Gemini AI Live",
                    gradientColors: const [Color(0xFF1B5E20), Color(0xFF2E7D32)],
                    iconBgColor: const Color(0xFF43A047),
                    isHighlighted: true,
                    onTap: () {
                      _navigateTo(const GeminiLiveScreen());
                    },
                  ),

                  const SizedBox(height: 16),

                  // 3. AI Translate
                  _buildFeatureCard(
                    index: 2,
                    icon: Icons.auto_awesome_rounded,
                    title: "AI Translate",
                    subtitle: "Dịch văn bản thông minh với AI",
                    gradientColors: const [Color(0xFF4A148C), Color(0xFF6A1B9A)],
                    iconBgColor: const Color(0xFF8E24AA),
                    onTap: () {
                      // TODO: Navigate to AI Translate screen
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text("🚧 Tính năng đang phát triển..."),
                          backgroundColor: Color(0xFF6A1B9A),
                          duration: Duration(seconds: 2),
                        ),
                      );
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
          onTap: onTap,
          borderRadius: BorderRadius.circular(20),
          splashColor: gradientColors[1].withValues(alpha: 0.3),
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
                color: isHighlighted
                    ? const Color(0xFF00C853).withValues(alpha: 0.5)
                    : Colors.white.withValues(alpha: 0.08),
                width: isHighlighted ? 1.5 : 1,
              ),
              boxShadow: isHighlighted
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
                          if (isHighlighted) ...[
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
                          color: Colors.white.withValues(alpha: 0.6),
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),

                // Arrow
                Icon(
                  Icons.arrow_forward_ios_rounded,
                  color: Colors.white.withValues(alpha: 0.4),
                  size: 18,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
