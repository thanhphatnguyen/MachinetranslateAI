import 'package:flutter/material.dart';

import '../screens/home_screen.dart';
import '../screens/login_screen.dart';
import '../services/auth_service.dart';

class AuthGate extends StatefulWidget {
  const AuthGate({super.key});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  final AuthService _authService = AuthService();
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    await _authService.loadSession();
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _logout() async {
    await _authService.logout();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        backgroundColor: Color(0xFFF8FAFC),
        body: Center(
          child: CircularProgressIndicator(color: Color(0xFF0EA5E9)),
        ),
      );
    }

    if (!_authService.isAuthenticated) {
      return LoginScreen(
        authService: _authService,
        onAuthenticated: () => setState(() {}),
      );
    }

    return HomeScreen(
      userEmail: _authService.session?.user.email ?? '',
      onLogout: _logout,
    );
  }
}
