import 'package:flutter/widgets.dart';

/// No-op reCAPTCHA widget on non-web platforms (Android/iOS/Desktop).
class RecaptchaBox extends StatelessWidget {
  const RecaptchaBox({
    super.key,
    required this.onChanged,
    this.resetTrigger = 0,
  });

  final ValueChanged<String?> onChanged;
  final int resetTrigger;

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
