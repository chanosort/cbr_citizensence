import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/constants.dart';
import '../models/models.dart';
import '../services/api_service.dart';

class AuthProvider extends ChangeNotifier {
  AuthProvider(this._api);
  final ApiService _api;

  AppUser? user;
  bool busy = false;
  String? error;
  String? sessionNotice;
  int loginCooldownSeconds = 0;
  Timer? _cooldownTimer;

  @override
  void dispose() {
    _cooldownTimer?.cancel();
    super.dispose();
  }

  void _startLoginCooldown(int seconds, {bool ipBlocked = false}) {
    _cooldownTimer?.cancel();
    loginCooldownSeconds = seconds;
    if (seconds <= 0) return;
    _cooldownTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (loginCooldownSeconds <= 1) {
        t.cancel();
        loginCooldownSeconds = 0;
        error = null;
      } else {
        loginCooldownSeconds--;
        error = ipBlocked
            ? 'Too many failed login attempts from this IP. Please wait ${loginCooldownSeconds}s.'
            : 'Account locked due to too many failed login attempts. Please wait ${loginCooldownSeconds}s before trying again.';
      }
      notifyListeners();
    });
  }

  /// Real-API mode only: bring back the saved session after a page refresh.
  Future<void> restore() async {
    if (kUseMockApi) return;
    try {
      final p = await SharedPreferences.getInstance();
      final token = p.getString('token');
      final saved = p.getString('user');
      if (token != null && saved != null) {
        _api.setToken(token);
        user = AppUser.fromJson(jsonDecode(saved) as Map<String, dynamic>);
      }
    } catch (_) {}
  }

  Future<void> _save(String token, AppUser u) async {
    if (kUseMockApi) return;
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString('token', token);
      await p.setString('user', jsonEncode(u.toJson()));
    } catch (_) {}
  }

  Future<void> updateUser(AppUser updated) async {
    user = updated;
    notifyListeners();
    if (!kUseMockApi) {
      try {
        final p = await SharedPreferences.getInstance();
        await p.setString('user', jsonEncode(updated.toJson()));
      } catch (_) {}
    }
  }

  Future<void> _clearSaved() async {
    if (kUseMockApi) return;
    try {
      final p = await SharedPreferences.getInstance();
      await p.remove('token');
      await p.remove('user');
    } catch (_) {}
  }

  void clearError() {
    if (error != null) {
      error = null;
      notifyListeners();
    }
  }

  void clearSessionNotice() {
    if (sessionNotice != null) {
      sessionNotice = null;
      notifyListeners();
    }
  }

  // ── Login ────────────────────────────────────────────────────────────────

  Future<bool> login(String email, String password) async {
    if (loginCooldownSeconds > 0) return false;
    busy = true;
    error = null;
    sessionNotice = null;
    notifyListeners();
    try {
      final s = await _api.login(email: email.trim(), password: password);
      _cooldownTimer?.cancel();
      loginCooldownSeconds = 0;
      _api.setToken(s.token);
      await _save(s.token, s.user);
      user = s.user;
      busy = false;
      notifyListeners();
      return true;
    } on ApiException catch (e) {
      if (e.code == 'ACCOUNT_LOCKED' || e.code == 'IP_BLOCKED') {
        final rawRetry = e.details['retry_after'];
        final secs = rawRetry is int
            ? rawRetry
            : int.tryParse('${rawRetry ?? ''}') ?? (e.code == 'IP_BLOCKED' ? 600 : 15);
        error = e.message;
        _startLoginCooldown(secs, ipBlocked: e.code == 'IP_BLOCKED');
      } else {
        error = e.displayMessage;
      }
    } catch (_) {
      error = 'Something went wrong. Please try again.';
    }
    busy = false;
    notifyListeners();
    return false;
  }

  // ── Register (citizen; navigates to OTP screen on success) ───────────────

  /// Returns true on success. Caller should navigate to the OTP verification screen.
  Future<bool> register({
    required String name,
    required String username,
    required String email,
    required String password,
    required List<Map<String, String>> securityQuestions,
  }) async {
    busy = true;
    error = null;
    notifyListeners();
    try {
      await _api.register(
        name: name.trim(),
        username: username.trim(),
        email: email.trim(),
        password: password,
        securityQuestions: securityQuestions,
      );
      busy = false;
      notifyListeners();
      return true;
    } on ApiException catch (e) {
      error = e.displayMessage;
    } catch (_) {
      error = 'Something went wrong. Please try again.';
    }
    busy = false;
    notifyListeners();
    return false;
  }

  // ── Email verification OTP ───────────────────────────────────────────────

  Future<bool> verifyEmail({required String email, required String code}) async {
    busy = true;
    error = null;
    notifyListeners();
    try {
      await _api.verifyEmail(email: email.trim(), code: code.trim());
      busy = false;
      notifyListeners();
      return true;
    } on ApiException catch (e) {
      error = e.displayMessage;
    } catch (_) {
      error = 'Something went wrong. Please try again.';
    }
    busy = false;
    notifyListeners();
    return false;
  }

  Future<bool> resendVerification({required String email}) async {
    busy = true;
    error = null;
    notifyListeners();
    try {
      await _api.resendVerification(email: email.trim());
      busy = false;
      notifyListeners();
      return true;
    } on ApiException catch (e) {
      error = e.displayMessage;
    } catch (_) {
      error = 'Something went wrong. Please try again.';
    }
    busy = false;
    notifyListeners();
    return false;
  }

  // ── Forgot / reset password ──────────────────────────────────────────────

  Future<({String email, List<SecurityQuestionChoice> questions})?> fetchForgotPasswordQuestions({
    required String email,
  }) async {
    busy = true;
    error = null;
    notifyListeners();
    try {
      final res = await _api.getForgotPasswordQuestions(email: email.trim());
      busy = false;
      notifyListeners();
      return res;
    } on ApiException catch (e) {
      error = e.displayMessage;
    } catch (_) {
      error = 'Something went wrong. Please try again.';
    }
    busy = false;
    notifyListeners();
    return null;
  }

  Future<String?> forgotPassword({
    required String email,
    required int questionId,
    required String answer,
    required String confirmAnswer,
  }) async {
    busy = true;
    error = null;
    notifyListeners();
    try {
      final hint = await _api.forgotPassword(
        email: email.trim(),
        questionId: questionId,
        answer: answer,
        confirmAnswer: confirmAnswer,
      );
      busy = false;
      notifyListeners();
      return hint ?? email.trim();
    } on ApiException catch (e) {
      error = e.displayMessage;
    } catch (_) {
      error = 'Something went wrong. Please try again.';
    }
    busy = false;
    notifyListeners();
    return null;
  }

  Future<bool> resetPassword({
    required String email,
    required String code,
    required String newPassword,
  }) async {
    busy = true;
    error = null;
    notifyListeners();
    try {
      await _api.resetPassword(email: email.trim(), code: code.trim(), newPassword: newPassword);
      busy = false;
      notifyListeners();
      return true;
    } on ApiException catch (e) {
      error = e.displayMessage;
    } catch (_) {
      error = 'Something went wrong. Please try again.';
    }
    busy = false;
    notifyListeners();
    return false;
  }

  // ── Change password (authenticated) ──────────────────────────────────────

  Future<void> changePassword({required String current, required String next}) async {
    await _api.changePassword(current: current, next: next);
  }

  // ── Logout ───────────────────────────────────────────────────────────────

  void logout({String? notice}) {
    _api.setToken(null);
    _clearSaved();
    user = null;
    error = null;
    sessionNotice = notice;
    notifyListeners();
  }
}
