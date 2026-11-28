import 'package:flutter/material.dart';

class SealLogo extends StatelessWidget {
  const SealLogo({super.key, this.size = 64, this.circular = true});
  final double size;
  final bool circular;

  @override
  Widget build(BuildContext context) {
    return Image.asset(
      'assets/images/app_logo.png',
      width: size,
      height: size,
      fit: BoxFit.contain,
      semanticLabel: 'Cabadbaran CitizenSense logo',
      errorBuilder: (_, __, ___) => Icon(
        Icons.shield_rounded,
        size: size,
        color: const Color(0xFFE5A823),
      ),
    );
  }
}
