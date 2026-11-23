import 'package:flutter/widgets.dart' show Page, ValueKey, Widget;
import 'package:go_router/go_router.dart';

import 'core/constants.dart';
import 'providers/auth_provider.dart';
import 'screens/auth_otp_screens.dart';
import 'screens/complaint_detail_screen.dart';
import 'screens/complaints_list_screen.dart';
import 'screens/dashboard_screen.dart';
import 'screens/login_screen.dart';
import 'screens/misc_screens.dart';
import 'screens/register_screen.dart';
import 'screens/reports_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/submit_complaint_screen.dart';
import 'screens/users_offices_screen.dart';

/// Helper to produce a zero-transition page without zoom/minimize-to-maximize effect.
Page<void> _noTransition(GoRouterState state, Widget child) =>
    NoTransitionPage<void>(key: state.pageKey, child: child);

/// Routes follow the Activity 6 navigation plan. The redirect is the client-side
/// guard; the Flask API still re-checks the JWT and role on every request.
GoRouter buildRouter(AuthProvider auth) {
  // path -> the only role allowed to open it
  const roleOnly = {
    '/citizen/dashboard': UserRole.citizen,
    '/staff/dashboard': UserRole.staff,
    '/admin/dashboard': UserRole.admin,
    '/submit-complaint': UserRole.citizen,
    '/complaint-tracking': UserRole.citizen,
    '/complaint-review': UserRole.staff,
    '/admin/complaints': UserRole.admin,
    '/reports-analytics': UserRole.admin,
    '/admin/users': UserRole.admin,
  };

  /// Auth-only pages that are accessible without being logged in.
  const publicPaths = {
    '/login',
    '/register',
    '/verify-email',
    '/forgot-password',
    '/reset-password',
  };

  return GoRouter(
    initialLocation: '/login',
    refreshListenable: auth,
    redirect: (context, state) {
      final loc = state.matchedLocation;
      final user = auth.user;
      final onPublicPage = publicPaths.any((p) => loc == p || loc.startsWith('$p?') || loc.startsWith('$p/'));

      if (user == null) return onPublicPage ? null : '/login';
      // Logged-in users are redirected away from public auth pages
      if (onPublicPage || loc == '/') return user.role.home;

      final only = roleOnly[loc];
      if (only != null && only != user.role) return '/unauthorized';
      return null;
    },
    routes: [
      GoRoute(
        path: '/login',
        pageBuilder: (c, s) => _noTransition(
          s,
          LoginScreen(
            justRegistered: s.uri.queryParameters['registered'] == '1',
            justVerified: s.uri.queryParameters['verified'] == '1',
            justReset: s.uri.queryParameters['reset'] == '1',
          ),
        ),
      ),
      GoRoute(
        path: '/register',
        pageBuilder: (c, s) => _noTransition(s, const RegisterScreen()),
      ),

      // ── OTP / password-reset routes ────────────────────────────────────
      GoRoute(
        path: '/verify-email',
        pageBuilder: (c, s) {
          final email = s.uri.queryParameters['email'] ?? '';
          return _noTransition(s, VerifyEmailScreen(email: email));
        },
      ),
      GoRoute(
        path: '/forgot-password',
        pageBuilder: (c, s) => _noTransition(s, const ForgotPasswordScreen()),
      ),
      GoRoute(
        path: '/reset-password',
        pageBuilder: (c, s) {
          final email = s.uri.queryParameters['email'] ?? '';
          final account = s.uri.queryParameters['account'];
          return _noTransition(s, ResetPasswordScreen(email: email, account: account));
        },
      ),

      // ── App screens ────────────────────────────────────────────────────
      GoRoute(
        path: '/citizen/dashboard',
        pageBuilder: (c, s) => _noTransition(s, const DashboardScreen()),
      ),
      GoRoute(
        path: '/staff/dashboard',
        pageBuilder: (c, s) => _noTransition(s, const DashboardScreen()),
      ),
      GoRoute(
        path: '/admin/dashboard',
        pageBuilder: (c, s) => _noTransition(s, const DashboardScreen()),
      ),
      GoRoute(
        path: '/submit-complaint',
        pageBuilder: (c, s) => _noTransition(s, const SubmitComplaintScreen()),
      ),
      for (final path in const ['/complaint-tracking', '/complaint-review', '/admin/complaints'])
        GoRoute(
          path: path,
          pageBuilder: (c, s) {
            final q = s.uri.queryParameters['q'] ?? '';
            return _noTransition(s, ComplaintsListScreen(key: ValueKey('$path|$q'), initialQuery: q));
          },
        ),
      GoRoute(
        path: '/complaints/:id',
        pageBuilder: (c, s) {
          final id = int.tryParse(s.pathParameters['id'] ?? '');
          if (id == null) return _noTransition(s, const UnauthorizedScreen());
          return _noTransition(s, ComplaintDetailScreen(key: ValueKey('complaint-$id'), id: id));
        },
      ),
      GoRoute(
        path: '/reports-analytics',
        pageBuilder: (c, s) => _noTransition(s, const ReportsScreen()),
      ),
      GoRoute(
        path: '/admin/users',
        pageBuilder: (c, s) => _noTransition(s, const UsersOfficesScreen()),
      ),
      GoRoute(
        path: '/settings',
        pageBuilder: (c, s) => _noTransition(s, const SettingsScreen()),
      ),
      GoRoute(
        path: '/unauthorized',
        pageBuilder: (c, s) => _noTransition(s, const UnauthorizedScreen()),
      ),
    ],
    errorPageBuilder: (c, s) => _noTransition(s, const UnauthorizedScreen()),
  );
}
