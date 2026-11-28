import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';

import 'core/constants.dart';
import 'core/theme.dart';
import 'providers/auth_provider.dart';
import 'providers/dashboard_provider.dart';
import 'providers/theme_provider.dart';
import 'router.dart';
import 'services/api_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!kUseMockApi) {
    // Non-blocking warm-up ping so Render free tier wakes up while user types.
    http.get(Uri.parse('$kApiBaseUrl/api/health')).then((_) {}, onError: (_) {});
  }
  final ApiService api = kUseMockApi ? MockApiService() : HttpApiService(kApiBaseUrl);
  final auth = AuthProvider(api);
  final theme = ThemeProvider();
  if (api is HttpApiService) api.onUnauthorized = auth.logout;
  await Future.wait([auth.restore(), theme.restore()]);
  runApp(CitizenSenseApp(api: api, auth: auth, theme: theme));
}

class CitizenSenseApp extends StatefulWidget {
  const CitizenSenseApp({super.key, required this.api, required this.auth, required this.theme});
  final ApiService api;
  final AuthProvider auth;
  final ThemeProvider theme;

  @override
  State<CitizenSenseApp> createState() => _CitizenSenseAppState();
}

class _CitizenSenseAppState extends State<CitizenSenseApp> {
  static const _idleTimeout = Duration(minutes: 15);
  late final DashboardProvider _dashboard;
  late final GoRouter _router;
  Timer? _idleTimer;

  @override
  void initState() {
    super.initState();
    _dashboard = DashboardProvider(widget.api);
    _router = buildRouter(widget.auth);
    widget.auth.addListener(_onAuthChanged);
    _resetIdleTimer();
  }

  void _onAuthChanged() {
    if (widget.auth.user != null) {
      _resetIdleTimer();
    } else {
      _idleTimer?.cancel();
      _idleTimer = null;
    }
  }

  void _resetIdleTimer() {
    _idleTimer?.cancel();
    if (widget.auth.user == null) return;
    _idleTimer = Timer(_idleTimeout, () {
      if (widget.auth.user != null) {
        widget.auth.logout(
          notice: 'Your session expired after 15 minutes of inactivity. Please log in again.',
        );
      }
    });
  }

  @override
  void dispose() {
    _idleTimer?.cancel();
    widget.auth.removeListener(_onAuthChanged);
    widget.auth.dispose();
    _dashboard.dispose();
    _router.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => _resetIdleTimer(),
      onPointerMove: (_) => _resetIdleTimer(),
      child: MultiProvider(
        providers: [
          Provider<ApiService>.value(value: widget.api),
          ChangeNotifierProvider<AuthProvider>.value(value: widget.auth),
          ChangeNotifierProvider<DashboardProvider>.value(value: _dashboard),
          ChangeNotifierProvider<ThemeProvider>.value(value: widget.theme),
        ],
        child: Consumer<ThemeProvider>(
          builder: (context, themeProv, _) => MaterialApp.router(
            title: 'Cabadbaran CitizenSense',
            debugShowCheckedModeBanner: false,
            theme: buildTheme(),
            darkTheme: buildDarkTheme(),
            themeMode: themeProv.mode,
            routerConfig: _router,
          ),
        ),
      ),
    );
  }
}
