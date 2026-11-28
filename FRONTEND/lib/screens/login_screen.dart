import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../core/theme.dart';
import '../core/validators.dart';
import '../providers/auth_provider.dart';
import '../widgets/announcement_slideshow.dart';
import '../widgets/auth_layout.dart';
import '../widgets/recaptcha_box.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, this.justRegistered = false, this.justVerified = false, this.justReset = false});
  final bool justRegistered;
  final bool justVerified;
  final bool justReset;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _form = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _obscure = true;
  String? _recaptchaToken;
  bool _captchaError = false;
  int _captchaReset = 0;

  @override
  void initState() {
    super.initState();
    _email.addListener(() => setState(() {}));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<AuthProvider>().clearError();
    });
  }

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    if (kIsWeb && (_recaptchaToken == null || _recaptchaToken!.isEmpty)) {
      setState(() => _captchaError = true);
      return;
    }
    setState(() => _captchaError = false);
    // On success the router redirects to the dashboard for the detected role.
    final ok = await context.read<AuthProvider>().login(
          _email.text,
          _password.text,
          recaptchaToken: _recaptchaToken,
        );
    if (!ok && mounted && kIsWeb) {
      setState(() {
        _recaptchaToken = null;
        _captchaReset++;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    return AuthLayout(
      child: Form(
        key: _form,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const AnnouncementSlideshow(),
          Text('Welcome',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: 6),
          const Text('Log in to file or manage complaints.',
              style: TextStyle(color: AppColors.muted)),
          const SizedBox(height: 22),
          if (widget.justRegistered && auth.error == null) ...[
            const MessageBanner(message: 'Account created. Check your email for the verification code.', good: true),
            const SizedBox(height: 16),
          ],
          if (widget.justVerified && auth.error == null) ...[
            const MessageBanner(message: 'Email verified! You can now log in.', good: true),
            const SizedBox(height: 16),
          ],
          if (widget.justReset && auth.error == null) ...[
            const MessageBanner(message: 'Password reset successfully. You can now log in.', good: true),
            const SizedBox(height: 16),
          ],
          if (auth.error != null) ...[
            MessageBanner(message: auth.error!),
            const SizedBox(height: 16),
          ],
          TextFormField(
            controller: _email,
            keyboardType: TextInputType.text,
            autofillHints: const [AutofillHints.username, AutofillHints.email],
            textInputAction: TextInputAction.next,
            decoration: const InputDecoration(
              labelText: 'Username or email address',
              hintText: 'Enter your username or email',
            ),
            validator: validateLoginAccount,
          ),
          RoleHint(email: _email.text),
          const SizedBox(height: 16),
          TextFormField(
            controller: _password,
            obscureText: _obscure,
            autofillHints: const [AutofillHints.password],
            textInputAction: TextInputAction.done,
            onFieldSubmitted: (_) => auth.busy ? null : _submit(),
            decoration: InputDecoration(
              labelText: 'Password',
              suffixIcon: IconButton(
                tooltip: _obscure ? 'Show password' : 'Hide password',
                icon: Icon(_obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                onPressed: () => setState(() => _obscure = !_obscure),
              ),
            ),
            validator: validatePassword,
          ),
          if (kIsWeb) ...[
            const SizedBox(height: 16),
            RecaptchaBox(
              resetTrigger: _captchaReset,
              onChanged: (token) => setState(() {
                _recaptchaToken = token;
                if (token != null) _captchaError = false;
              }),
            ),
            if (_captchaError)
              const Padding(
                padding: EdgeInsets.only(top: 6),
                child: Text(
                  'Please complete the reCAPTCHA verification.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: AppColors.star, fontSize: 12.5, fontWeight: FontWeight.w600),
                ),
              ),
          ],
          const SizedBox(height: 24),
          ElevatedButton(
            onPressed: auth.busy ? null : _submit,
            child: auth.busy
                ? const SizedBox(
                    width: 22, height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white))
                : const Text('Log in'),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: () => context.go('/forgot-password'),
              child: const Text('Forgot password?'),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Text('No account yet?', style: TextStyle(color: AppColors.muted)),
              const SizedBox(width: 4),
              TextButton(
                onPressed: () => context.go('/register'),
                child: const Text('Create an account'),
              ),
            ],
          ),
        ]),
      ),
    );
  }
}
