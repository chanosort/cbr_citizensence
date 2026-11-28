import 'package:flutter/material.dart';

class SealLogo extends StatelessWidget {
  const SealLogo({super.key, this.size = 64, this.circular = true});
  final double size;
  final bool circular;

  @override
  Widget build(BuildContext context) {
    Widget img = Image.asset(
      'assets/images/app_logo.png',
      width: size,
      height: size,
      fit: BoxFit.contain,
      semanticLabel: 'Cabadbaran CitizenSense logo',
      errorBuilder: (context, error, stackTrace) => Image.asset(
        'assets/images/cabadbaran_seal.png',
        width: size,
        height: size,
        fit: BoxFit.contain,
        semanticLabel: 'City of Cabadbaran official seal',
        errorBuilder: (_, __, ___) => Icon(
          Icons.shield_rounded,
          size: size,
          color: const Color(0xFFE5A823),
        ),
      ),
    );

    if (circular) {
      img = ClipOval(child: img);
    }
    return img;
  }
}
