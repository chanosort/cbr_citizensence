import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../core/theme.dart';
import '../core/validators.dart';
import '../providers/auth_provider.dart';
import '../widgets/auth_layout.dart';
import '../widgets/terms_dialog.dart';

class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key});

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

const _kSecurityQuestions = <String>[
  'What is the name of your elementary school?',
  "What is your pet's name?",
  'What is the name of your best friend?',
  "What is your mother's maiden name?",
  'In what city were you born?',
  'What was your childhood nickname?',
  'What is the name of your favorite teacher?',
  'What was the make of your first car or bike?',
];

class _RegisterScreenState extends State<RegisterScreen> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _username = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  final _ans1 = TextEditingController();
  final _ans2 = TextEditingController();
  final _ans3 = TextEditingController();
  String _q1 = _kSecurityQuestions[0];
  String _q2 = _kSecurityQuestions[1];
  String _q3 = _kSecurityQuestions[2];
  late final TapGestureRecognizer _termsTap;
  bool _obscure = true;
  bool _agreed = false;
  bool _termsError = false;

  @override
  void initState() {
    super.initState();
    _termsTap = TapGestureRecognizer()..onTap = _openTerms;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<AuthProvider>().clearError();
    });
  }

  @override
  void dispose() {
    _termsTap.dispose();
    _name.dispose();
    _username.dispose();
    _email.dispose();
    _password.dispose();
    _confirm.dispose();
    _ans1.dispose();
    _ans2.dispose();
    _ans3.dispose();
    super.dispose();
  }

  Future<void> _openTerms() async {
    final ok = await showTermsDialog(context);
    if (ok == true && mounted) {
      setState(() {
        _agreed = true;
        _termsError = false;
      });
    }
  }

  Future<void> _submit() async {
    final valid = _form.currentState!.validate();
    if (!_agreed) setState(() => _termsError = true);
    if (!valid || !_agreed) return;

    final auth = context.read<AuthProvider>();
    final email = _email.text.trim();

    final success = await auth.register(
      name: _name.text,
      username: _username.text,
      email: email,
      password: _password.text,
      securityQuestions: [
        {'question': _q1, 'answer': _ans1.text.trim()},
        {'question': _q2, 'answer': _ans2.text.trim()},
        {'question': _q3, 'answer': _ans3.text.trim()},
      ],
    );

    if (success && mounted) {
      // Navigate to the OTP verification screen, passing the email
      context.go('/verify-email?email=${Uri.encodeComponent(email)}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();

    return AuthLayout(
      child: Form(
        key: _form,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Create your account',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: 6),
          const Text(
            'Register with your email to submit complaints. '
            'Staff and admin accounts are set up by administrators.',
            style: TextStyle(color: AppColors.muted),
          ),
          const SizedBox(height: 22),
          if (auth.error != null) ...[
            MessageBanner(message: auth.error!),
            const SizedBox(height: 16),
          ],
          TextFormField(
            controller: _name,
            textCapitalization: TextCapitalization.words,
            textInputAction: TextInputAction.next,
            autofillHints: const [AutofillHints.name],
            decoration: const InputDecoration(labelText: 'Full name'),
            validator: (v) => (v ?? '').trim().length < 2 ? 'Enter your full name.' : null,
          ),
          const SizedBox(height: 16),
          TextFormField(
            controller: _username,
            textInputAction: TextInputAction.next,
            autofillHints: const [AutofillHints.username],
            decoration: const InputDecoration(
              labelText: 'Username',
              helperText: 'For login and account recovery (letters, numbers, underscores).',
            ),
            validator: validateUsername,
          ),
          const SizedBox(height: 16),
          TextFormField(
            controller: _email,
            keyboardType: TextInputType.emailAddress,
            textInputAction: TextInputAction.next,
            autofillHints: const [AutofillHints.email],
            decoration: const InputDecoration(
              labelText: 'Email address',
              helperText: 'A verification code will be sent to this email.',
            ),
            validator: validateRegisterEmail,
          ),
          const SizedBox(height: 16),
          TextFormField(
            controller: _password,
            obscureText: _obscure,
            textInputAction: TextInputAction.next,
            decoration: InputDecoration(
              labelText: 'Password',
              helperText: kPasswordRuleHint,
              helperMaxLines: 2,
              suffixIcon: IconButton(
                tooltip: _obscure ? 'Show password' : 'Hide password',
                icon: Icon(_obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                onPressed: () => setState(() => _obscure = !_obscure),
              ),
            ),
            validator: (v) => validatePassword(v, strict: true),
          ),
          const SizedBox(height: 16),
          TextFormField(
            controller: _confirm,
            obscureText: _obscure,
            textInputAction: TextInputAction.next,
            decoration: const InputDecoration(labelText: 'Confirm password'),
            validator: (v) => v != _password.text ? 'Passwords do not match.' : null,
          ),
          const SizedBox(height: 20),
          Text('Security Questions',
              style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          const Text(
            'Choose 3 different questions and provide your answers for account recovery.',
            style: TextStyle(color: AppColors.muted, fontSize: 12.5),
          ),
          const SizedBox(height: 12),
          _buildQuestionPicker(
            label: 'Security Question 1',
            value: _q1,
            others: {_q2, _q3},
            onChanged: (v) => setState(() => _q1 = v!),
            answerController: _ans1,
            answerAction: TextInputAction.next,
          ),
          const SizedBox(height: 12),
          _buildQuestionPicker(
            label: 'Security Question 2',
            value: _q2,
            others: {_q1, _q3},
            onChanged: (v) => setState(() => _q2 = v!),
            answerController: _ans2,
            answerAction: TextInputAction.next,
          ),
          const SizedBox(height: 12),
          _buildQuestionPicker(
            label: 'Security Question 3',
            value: _q3,
            others: {_q1, _q2},
            onChanged: (v) => setState(() => _q3 = v!),
            answerController: _ans3,
            answerAction: TextInputAction.done,
          ),
          const SizedBox(height: 14),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Checkbox(
              value: _agreed,
              onChanged: (v) => setState(() {
                _agreed = v ?? false;
                if (_agreed) _termsError = false;
              }),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text.rich(TextSpan(style: const TextStyle(height: 1.4), children: [
                  const TextSpan(text: 'I have read and agree to the '),
                  TextSpan(
                    text: 'Terms of Use and Data Privacy Notice',
                    recognizer: _termsTap,
                    style: const TextStyle(
                        color: AppColors.navy,
                        fontWeight: FontWeight.w700,
                        decoration: TextDecoration.underline),
                  ),
                  const TextSpan(text: '.'),
                ])),
              ),
            ),
          ]),
          if (_termsError)
            const Padding(
              padding: EdgeInsets.only(left: 12, bottom: 4),
              child: Text('You need to agree before creating an account.',
                  style: TextStyle(color: AppColors.star, fontSize: 12.5)),
            ),
          const SizedBox(height: 14),
          ElevatedButton(
            onPressed: auth.busy ? null : _submit,
            child: auth.busy
                ? const SizedBox(
                    width: 22, height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white))
                : const Text('Create account'),
          ),
          const SizedBox(height: 18),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            const Text('Already registered?', style: TextStyle(color: AppColors.muted)),
            TextButton(onPressed: () => context.go('/login'), child: const Text('Log in')),
          ]),
        ]),
      ),
    );
  }

  Widget _buildQuestionPicker({
    required String label,
    required String value,
    required Set<String> others,
    required ValueChanged<String?> onChanged,
    required TextEditingController answerController,
    required TextInputAction answerAction,
  }) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      DropdownButtonFormField<String>(
        initialValue: value,
        isExpanded: true,
        decoration: InputDecoration(labelText: label),
        items: _kSecurityQuestions
            .map((q) => DropdownMenuItem<String>(
                  value: q,
                  child: Text(q, overflow: TextOverflow.ellipsis),
                ))
            .toList(),
        onChanged: onChanged,
        validator: (v) {
          if (v == null || v.isEmpty) return 'Select a question.';
          if (others.contains(v)) return 'Please choose 3 different questions.';
          return null;
        },
      ),
      const SizedBox(height: 8),
      TextFormField(
        controller: answerController,
        textInputAction: answerAction,
        decoration: const InputDecoration(labelText: 'Your answer'),
        validator: (v) => (v ?? '').trim().isEmpty ? 'Enter your answer.' : null,
      ),
    ]);
  }
}
