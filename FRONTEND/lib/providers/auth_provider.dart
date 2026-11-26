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

  // ── Login ────────────────────────────────────────────────────────────────

  Future<bool> login(String email, String password) async {
    busy = true;
    error = null;
    notifyListeners();
    try {
      final s = await _api.login(email: email.trim(), password: password);
      _api.setToken(s.token);
      await _save(s.token, s.user);
      user = s.user;
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

  // ── Register (citizen; navigates to OTP screen on success) ───────────────

  /// Returns true on success. Caller should navigate to the OTP verification screen.
  Future<bool> register({
    required String name,
    required String username,
    required String email,
    required String password,
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

  Future<String?> forgotPassword({required String email}) async {
    busy = true;
    error = null;
    notifyListeners();
    try {
      final hint = await _api.forgotPassword(email: email.trim());
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

  void logout() {
    _api.setToken(null);
    _clearSaved();
    user = null;
    error = null;
    notifyListeners();
  }
}
