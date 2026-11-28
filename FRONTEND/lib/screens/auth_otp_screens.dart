import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../core/theme.dart';
import '../core/validators.dart';
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
// Forgot Password Screen — Step 1: enter account, Step 2: choose 1 question & answer twice
// ─────────────────────────────────────────────────────────────────────────────

class ForgotPasswordScreen extends StatefulWidget {
  const ForgotPasswordScreen({super.key});

  @override
  State<ForgotPasswordScreen> createState() => _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends State<ForgotPasswordScreen> {
  final _account = TextEditingController();
  final _answer1 = TextEditingController();
  final _answer2 = TextEditingController();
  List<SecurityQuestionChoice> _questions = const [];
  int? _selectedQuestionId;
  String? _localError;

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
    _answer1.dispose();
    _answer2.dispose();
    super.dispose();
  }

  Future<void> _lookupQuestions() async {
    final account = _account.text.trim();
    if (account.isEmpty) {
      setState(() => _localError = 'Enter your username or email address.');
      return;
    }
    setState(() => _localError = null);
    final auth = context.read<AuthProvider>();
    final res = await auth.fetchForgotPasswordQuestions(email: account);
    if (res != null && mounted) {
      setState(() {
        _questions = res.questions;
        _selectedQuestionId = res.questions.isNotEmpty ? res.questions.first.id : null;
        _answer1.clear();
        _answer2.clear();
      });
    }
  }

  Future<void> _submitAnswer() async {
    final account = _account.text.trim();
    final qId = _selectedQuestionId;
    final a1 = _answer1.text.trim();
    final a2 = _answer2.text.trim();
    if (qId == null) {
      setState(() => _localError = 'Select one of your security questions.');
      return;
    }
    if (a1.isEmpty || a2.isEmpty) {
      setState(() => _localError = 'Please type your answer twice.');
      return;
    }
    if (a1.toLowerCase() != a2.toLowerCase()) {
      setState(() => _localError = 'Your two answers do not match. Please type the same answer twice.');
      return;
    }
    setState(() => _localError = null);
    final auth = context.read<AuthProvider>();
    final hint = await auth.forgotPassword(
      email: account,
      questionId: qId,
      answer: a1,
      confirmAnswer: a2,
    );
    if (hint != null && mounted) {
      context.go('/reset-password?account=${Uri.encodeComponent(account)}&email=${Uri.encodeComponent(hint)}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final hasQuestions = _questions.isNotEmpty;
    final bannerMsg = _localError ?? auth.error;

    return AuthLayout(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('Forgot your account?',
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
        const SizedBox(height: 6),
        Text(
          hasQuestions
              ? 'Choose 1 of your security questions and type the answer twice. When verified, a recovery code will be sent to your registered email.'
              : 'Enter your username or email address to load your security questions.',
          style: const TextStyle(color: AppColors.muted),
        ),
        const SizedBox(height: 22),
        if (bannerMsg != null) ...[
          MessageBanner(message: bannerMsg),
          const SizedBox(height: 16),
        ],
        if (!hasQuestions) ...[
          TextField(
            controller: _account,
            keyboardType: TextInputType.text,
            textInputAction: TextInputAction.done,
            autofillHints: const [AutofillHints.username, AutofillHints.email],
            decoration: const InputDecoration(
              labelText: 'Username or email address',
              hintText: 'e.g. juan or juan@gmail.com',
            ),
            onSubmitted: (_) => auth.busy ? null : _lookupQuestions(),
          ),
          const SizedBox(height: 20),
          ElevatedButton(
            onPressed: auth.busy ? null : _lookupQuestions,
            child: auth.busy
                ? const SizedBox(
                    width: 22, height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white))
                : const Text('Continue'),
          ),
        ] else ...[
          DropdownButtonFormField<int>(
            initialValue: _selectedQuestionId,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Select a security question'),
            items: _questions
                .map((q) => DropdownMenuItem<int>(
                      value: q.id,
                      child: Text(q.question, overflow: TextOverflow.ellipsis),
                    ))
                .toList(),
            onChanged: (v) => setState(() => _selectedQuestionId = v),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _answer1,
            textInputAction: TextInputAction.next,
            decoration: const InputDecoration(labelText: 'Answer (1st entry)'),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _answer2,
            textInputAction: TextInputAction.done,
            decoration: const InputDecoration(labelText: 'Confirm answer (2nd entry)'),
            onSubmitted: (_) => auth.busy ? null : _submitAnswer(),
          ),
          const SizedBox(height: 20),
          ElevatedButton(
            onPressed: auth.busy ? null : _submitAnswer,
            child: auth.busy
                ? const SizedBox(
                    width: 22, height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white))
                : const Text('Verify & send recovery code'),
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: auth.busy
                ? null
                : () {
                    context.read<AuthProvider>().clearError();
                    setState(() {
                      _questions = const [];
                      _selectedQuestionId = null;
                      _localError = null;
                    });
                  },
            child: const Text('Use a different username or email'),
          ),
        ],
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
    final passErr = validatePassword(_newPassword.text, strict: true);
    if (passErr != null) {
      setState(() => _codeError = passErr);
      return;
    }
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
              helperText: kPasswordRuleHint,
              helperMaxLines: 2,
              errorText: _newPassword.text.isNotEmpty ? validatePassword(_newPassword.text, strict: true) : _codeError,
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
