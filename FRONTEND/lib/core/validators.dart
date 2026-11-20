import 'constants.dart';

/// Used on the LOGIN screen: shows a hint for known role domains.
/// Does NOT block non-domain emails — citizens may use any valid address.
String? validateEmail(String? v) {
  final e = (v ?? '').trim();
  if (e.isEmpty) return 'Enter your email address.';
  if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(e)) {
    return 'Enter a valid email address.';
  }
  return null;
}

/// Used on the REGISTER screen: any real-looking email is accepted.
/// The server will send a verification OTP, so legitimacy is confirmed there.
String? validateRegisterEmail(String? v) {
  final e = (v ?? '').trim();
  if (e.isEmpty) return 'Enter your email address.';
  if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(e)) {
    return 'Enter a valid email address.';
  }
  return null;
}

String? validatePassword(String? v, {bool strict = false}) {
  final p = v ?? '';
  if (p.isEmpty) return 'Enter your password.';
  if (strict && p.length < 8) return 'Password must be at least 8 characters long.';
  return null;
}

String? validateUsername(String? v) {
  final u = (v ?? '').trim();
  if (u.isEmpty) return 'Choose a username.';
  if (u.length < 3) return 'Username must be at least 3 characters.';
  if (u.length > 30) return 'Username must be under 30 characters.';
  if (!RegExp(r'^[a-zA-Z0-9_]+$').hasMatch(u)) {
    return 'Use only letters, numbers, and underscores.';
  }
  return null;
}

String? validateLoginAccount(String? v) {
  final a = (v ?? '').trim();
  if (a.isEmpty) return 'Enter your username or email address.';
  return null;
}

/// Returns the role hint text for a given email, if the domain is a known one.
/// Returns null for ordinary citizen emails (no hint needed).
String? roleHintText(String email) {
  final role = roleFromEmail(email.trim().toLowerCase());
  return switch (role) {
    UserRole.staff => 'Staff account',
    UserRole.admin => 'Administrator account',
    _ => null,
  };
}
