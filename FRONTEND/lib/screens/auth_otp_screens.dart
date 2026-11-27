import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../core/theme.dart';
import '../providers/auth_provider.dart';
import '../services/api_service.dart';
import '../widgets/auth_layout.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Email OTP Verification Screen
// Shown after registration. User enters the 6-digit code sent to their email.
// ─────────────────────────────────────────────────────────────────────────────

class VerifyEmailScreen extends StatefulWidget {
  const VerifyEmailScreen({super.key, required this.email});
  final String email;

  @override
  State<VerifyEmailScreen> createState() => _VerifyEmailScreenState();
}

class _VerifyEmailScreenState extends State<VerifyEmailScreen> {
  final _code = TextEditingController();
  String? _fieldError;
  bool _resent = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<AuthProvider>().clearError();
    });
  }

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final code = _code.text.trim();
    if (code.length != 6 || !RegExp(r'^\d{6}$').hasMatch(code)) {
      setState(() => _fieldError = 'Enter the 6-digit code from your email.');
      return;
    }
    setState(() => _fieldError = null);
    final auth = context.read<AuthProvider>();
    final ok = await auth.verifyEmail(email: widget.email, code: code);
    if (ok && mounted) {
      context.go('/login?verified=1');
    }
  }

  Future<void> _resend() async {
    final auth = context.read<AuthProvider>();
    final ok = await auth.resendVerification(email: widget.email);
    if (ok && mounted) setState(() => _resent = true);
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();

    return AuthLayout(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('Verify your email',
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
        const SizedBox(height: 6),
        Text(
          'We sent a 6-digit code to ${widget.email}. Enter it below to activate your account.',
          style: const TextStyle(color: AppColors.muted),
        ),
        const SizedBox(height: 22),
        if (auth.error != null) ...[
          MessageBanner(message: auth.error!),
          const SizedBox(height: 16),
        ],
        if (_resent) ...[
          const MessageBanner(message: 'A new code has been sent to your email.', good: true),
          const SizedBox(height: 16),
        ],
        TextField(
          controller: _code,
          keyboardType: TextInputType.number,
          maxLength: 6,
          textAlign: TextAlign.center,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          style: Theme.of(context).textTheme.headlineMedium?.copyWith(letterSpacing: 10),
          decoration: InputDecoration(
            labelText: 'Verification code',
            counterText: '',
            errorText: _fieldError,
          ),
          onSubmitted: (_) => auth.busy ? null : _submit(),
        ),
        const SizedBox(height: 20),
        ElevatedButton(
          onPressed: auth.busy ? null : _submit,
          child: auth.busy
              ? const SizedBox(
                  width: 22, height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white))
              : const Text('Verify'),
        ),
        const SizedBox(height: 10),
        TextButton(
          onPressed: auth.busy ? null : _resend,
          child: const Text("Didn't receive a code? Resend"),
        ),
        TextButton(
          onPressed: () => context.go('/login'),
          child: const Text('Back to login'),
        ),
      ]),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Forgot Password Screen — Step 1: enter email
// ─────────────────────────────────────────────────────────────────────────────

class ForgotPasswordScreen extends StatefulWidget {
  const ForgotPasswordScreen({super.key});

  @override
  State<ForgotPasswordScreen> createState() => _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends State<ForgotPasswordScreen> {
  final _account = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<AuthProvider>().clearError();
    });
  }

  @override
  void dispose() {
    _account.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final account = _account.text.trim();
    if (account.isEmpty) return;
    final auth = context.read<AuthProvider>();
    final hint = await auth.forgotPassword(email: account);
    if (hint != null && mounted) {
      context.go('/reset-password?account=${Uri.encodeComponent(account)}&email=${Uri.encodeComponent(hint)}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();

    return AuthLayout(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('Forgot your account?',
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
        const SizedBox(height: 6),
        const Text(
          'Enter your username or email address. We will send a verification code to the registered email on file.',
          style: TextStyle(color: AppColors.muted),
        ),
        const SizedBox(height: 22),
        if (auth.error != null) ...[
          MessageBanner(message: auth.error!),
          const SizedBox(height: 16),
        ],
        TextField(
          controller: _account,
          keyboardType: TextInputType.text,
          textInputAction: TextInputAction.done,
          autofillHints: const [AutofillHints.username, AutofillHints.email],
          decoration: const InputDecoration(
            labelText: 'Username or email address',
            hintText: 'e.g. juan or juan@gmail.com',
          ),
          onSubmitted: (_) => auth.busy ? null : _submit(),
        ),
        const SizedBox(height: 20),
        ElevatedButton(
          onPressed: auth.busy ? null : _submit,
          child: auth.busy
              ? const SizedBox(
                  width: 22, height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white))
              : const Text('Send recovery code'),
        ),
        const SizedBox(height: 10),
        TextButton(
          onPressed: () => context.go('/login'),
          child: const Text('Back to login'),
        ),
      ]),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Reset Password Screen — Step 2: enter OTP + new password
// ─────────────────────────────────────────────────────────────────────────────

class ResetPasswordScreen extends StatefulWidget {
  const ResetPasswordScreen({super.key, required this.email, this.account});
  final String email;
  final String? account;

  @override
  State<ResetPasswordScreen> createState() => _ResetPasswordScreenState();
}

class _ResetPasswordScreenState extends State<ResetPasswordScreen> {
  final _code = TextEditingController();
  final _newPassword = TextEditingController();
  final _confirm = TextEditingController();
  bool _obscure = true;
  bool _codeVerified = false;
  bool _verifyingCode = false;
  String? _codeError;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<AuthProvider>().clearError();
    });
  }

  @override
  void dispose() {
    _code.dispose();
    _newPassword.dispose();
    _confirm.dispose();
    super.dispose();
  }

  String get _target => (widget.account != null && widget.account!.isNotEmpty)
      ? widget.account!
      : widget.email;

  Future<void> _verifyCode() async {
    final code = _code.text.trim();
    if (code.length != 6 || !RegExp(r'^\d{6}$').hasMatch(code)) {
      setState(() => _codeError = 'Enter the 6-digit code from your email.');
      return;
    }
    setState(() {
      _codeError = null;
      _verifyingCode = true;
    });
    try {
      await context.read<ApiService>().verifyResetCode(email: _target, code: code);
      if (!mounted) return;
      context.read<AuthProvider>().clearError();
      setState(() {
        _verifyingCode = false;
        _codeVerified = true;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _verifyingCode = false;
        _codeError = e.displayMessage;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _verifyingCode = false;
        _codeError = 'Could not verify the code. Please try again.';
      });
    }
  }

  Future<void> _submit() async {
    final code = _code.text.trim();
    if (!_codeVerified) {
      await _verifyCode();
      return;
    }
    if (_newPassword.text.length < 8) return;
    if (_newPassword.text != _confirm.text) return;
    setState(() => _codeError = null);

    final auth = context.read<AuthProvider>();
    final ok = await auth.resetPassword(
      email: _target,
      code: code,
      newPassword: _newPassword.text,
    );
    if (ok && mounted) {
      context.go('/login?reset=1');
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();

    return AuthLayout(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(_codeVerified ? 'Create new password' : 'Verify recovery code',
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
        const SizedBox(height: 6),
        Text(
          _codeVerified
              ? 'Code verified for ${widget.email}. Enter your new password below.'
              : 'We sent a 6-digit verification code to ${widget.email}. Verify the code first before setting a new password.',
          style: const TextStyle(color: AppColors.muted),
        ),
        const SizedBox(height: 22),
        if (_codeVerified && auth.error == null) ...[
          const MessageBanner(message: 'Verification code confirmed! You may now type your new password.', good: true),
          const SizedBox(height: 16),
        ],
        if (auth.error != null) ...[
          MessageBanner(message: auth.error!),
          const SizedBox(height: 16),
        ],
        if (!_codeVerified) ...[
          TextField(
            controller: _code,
            keyboardType: TextInputType.number,
            maxLength: 6,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.headlineMedium?.copyWith(letterSpacing: 10),
            decoration: InputDecoration(
              labelText: 'Verification code',
              counterText: '',
              errorText: _codeError,
            ),
            onSubmitted: (_) => _verifyingCode ? null : _verifyCode(),
          ),
          const SizedBox(height: 20),
          ElevatedButton(
            onPressed: _verifyingCode ? null : _verifyCode,
            child: _verifyingCode
                ? const SizedBox(
                    width: 22, height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white))
                : const Text('Verify code'),
          ),
        ] else ...[
          TextField(
            controller: _newPassword,
            obscureText: _obscure,
            textInputAction: TextInputAction.next,
            decoration: InputDecoration(
              labelText: 'New password',
              helperText: 'At least 8 characters.',
              suffixIcon: IconButton(
                tooltip: _obscure ? 'Show password' : 'Hide password',
                icon: Icon(_obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                onPressed: () => setState(() => _obscure = !_obscure),
              ),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _confirm,
            obscureText: _obscure,
            textInputAction: TextInputAction.done,
            decoration: InputDecoration(
              labelText: 'Confirm new password',
              errorText: _confirm.text.isNotEmpty && _confirm.text != _newPassword.text
                  ? 'Passwords do not match.'
                  : null,
            ),
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => auth.busy ? null : _submit(),
          ),
          const SizedBox(height: 20),
          ElevatedButton(
            onPressed: auth.busy ? null : _submit,
            child: auth.busy
                ? const SizedBox(
                    width: 22, height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white))
                : const Text('Reset password'),
          ),
        ],
        const SizedBox(height: 10),
        TextButton(
          onPressed: () => context.go('/forgot-password'),
          child: const Text('Resend code'),
        ),
        TextButton(
          onPressed: () => context.go('/login'),
          child: const Text('Back to login'),
        ),
      ]),
    );
  }
}
