// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:async';
import 'dart:html' as html;
import 'dart:js' as js;
import 'dart:ui_web' as ui_web;

import 'package:flutter/material.dart';

const String _kRecaptchaSiteKey = '6Lfamy4uAAAAAL1UwtY0wE-9sURICDcHc8zRFq_O';

/// Renders Google reCAPTCHA v2 ("I'm not a robot") on Flutter Web.
class RecaptchaBox extends StatefulWidget {
  const RecaptchaBox({
    super.key,
    required this.onChanged,
    this.resetTrigger = 0,
  });

  final ValueChanged<String?> onChanged;
  final int resetTrigger;

  @override
  State<RecaptchaBox> createState() => _RecaptchaBoxState();
}

class _RecaptchaBoxState extends State<RecaptchaBox> {
  static int _counter = 0;
  late final String _viewType;
  late final String _elementId;
  int? _widgetId;
  Timer? _pollTimer;
  StreamSubscription<html.MessageEvent>? _msgSub;

  @override
  void initState() {
    super.initState();
    _counter++;
    _viewType = 'recaptcha-view-$_counter';
    _elementId = 'recaptcha-el-$_counter';

    ui_web.platformViewRegistry.registerViewFactory(_viewType, (int viewId) {
      final container = html.DivElement()
        ..id = _elementId
        ..style.width = '100%'
        ..style.display = 'flex'
        ..style.justifyContent = 'center';
      return container;
    });

    _msgSub = html.window.onMessage.listen((event) {
      final data = event.data;
      if (data is Map && data['type'] == 'recaptcha-token' && data['elId'] == _elementId) {
        if (mounted) widget.onChanged(data['token'] as String?);
      }
    });

    WidgetsBinding.instance.addPostFrameCallback((_) => _tryRender());
  }

  @override
  void didUpdateWidget(covariant RecaptchaBox oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.resetTrigger != widget.resetTrigger && _widgetId != null) {
      try {
        final grecaptcha = js.context['grecaptcha'];
        if (grecaptcha is js.JsObject) {
          grecaptcha.callMethod('reset', [_widgetId]);
        }
      } catch (_) {}
      widget.onChanged(null);
    }
  }

  void _tryRender([int attempt = 0]) {
    if (!mounted || _widgetId != null) return;
    final el = html.document.getElementById(_elementId);
    if (el != null) {
      try {
        final res = js.context.callMethod('renderRecaptcha', [_elementId, _kRecaptchaSiteKey]);
        if (res is int && res >= 0) {
          _widgetId = res;
          return;
        }
      } catch (_) {}
    }
    if (attempt < 40) {
      _pollTimer?.cancel();
      _pollTimer = Timer(const Duration(milliseconds: 250), () => _tryRender(attempt + 1));
    }
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _msgSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 82,
      child: HtmlElementView(viewType: _viewType),
    );
  }
}
