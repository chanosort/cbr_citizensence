import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/theme.dart';
import '../models/models.dart';
import '../services/api_service.dart';

/// Automatic slideshow banner shown at the top of the Login screen.
/// Number of slides depends dynamically on how many approved announcements exist.
class AnnouncementSlideshow extends StatefulWidget {
  const AnnouncementSlideshow({super.key});

  @override
  State<AnnouncementSlideshow> createState() => _AnnouncementSlideshowState();
}

class _AnnouncementSlideshowState extends State<AnnouncementSlideshow> {
  final PageController _controller = PageController();
  List<AnnouncementItem> _items = const [];
  int _index = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final list = await context.read<ApiService>().publicAnnouncements();
      if (!mounted) return;
      setState(() => _items = list);
      _startTimer();
    } catch (_) {
      // Silently skip if offline/unavailable on login page
    }
  }

  void _startTimer() {
    _timer?.cancel();
    if (_items.length <= 1) return;
    _timer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!mounted || _items.length <= 1 || !_controller.hasClients) return;
      final next = (_index + 1) % _items.length;
      _controller.animateToPage(
        next,
        duration: const Duration(milliseconds: 450),
        curve: Curves.easeInOut,
      );
    });
  }

  Color _badgeColor(String category) {
    switch (category.toLowerCase()) {
      case 'promotion':
        return AppColors.forest;
      case 'advisory':
        return AppColors.star;
      case 'event':
        return AppColors.seal;
      default:
        return AppColors.gold;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_items.isEmpty) return const SizedBox.shrink();

    return Container(
      margin: const EdgeInsets.only(bottom: 18),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [AppColors.navyDark, AppColors.navy, Color(0xFF1558B0)],
        ),
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            color: AppColors.navy.withValues(alpha: 0.18),
            blurRadius: 14,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: 132,
            child: PageView.builder(
              controller: _controller,
              itemCount: _items.length,
              onPageChanged: (i) => setState(() => _index = i),
              itemBuilder: (context, i) {
                final a = _items[i];
                final badge = _badgeColor(a.category);
                final darkText = badge == AppColors.gold;
                return Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                          decoration: BoxDecoration(
                            color: badge,
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(
                            a.category.toUpperCase(),
                            style: TextStyle(
                              color: darkText ? AppColors.navyDark : Colors.white,
                              fontSize: 10,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0.6,
                            ),
                          ),
                        ),
                        const Spacer(),
                        if (_items.length > 1)
                          Text(
                            '${i + 1} / ${_items.length}',
                            style: const TextStyle(color: Colors.white70, fontSize: 11, fontWeight: FontWeight.w600),
                          ),
                      ]),
                      const SizedBox(height: 8),
                      Text(
                        a.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Expanded(
                        child: Text(
                          a.content,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Colors.white70, fontSize: 12.5, height: 1.35),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
          if (_items.length > 1)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  InkWell(
                    onTap: () {
                      final prev = (_index - 1 + _items.length) % _items.length;
                      _controller.animateToPage(prev,
                          duration: const Duration(milliseconds: 350), curve: Curves.easeInOut);
                    },
                    child: const Icon(Icons.chevron_left_rounded, color: Colors.white70, size: 20),
                  ),
                  const SizedBox(width: 8),
                  for (var i = 0; i < _items.length; i++)
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 250),
                      margin: const EdgeInsets.symmetric(horizontal: 3),
                      width: i == _index ? 18 : 7,
                      height: 7,
                      decoration: BoxDecoration(
                        color: i == _index ? AppColors.gold : Colors.white30,
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                  const SizedBox(width: 8),
                  InkWell(
                    onTap: () {
                      final next = (_index + 1) % _items.length;
                      _controller.animateToPage(next,
                          duration: const Duration(milliseconds: 350), curve: Curves.easeInOut);
                    },
                    child: const Icon(Icons.chevron_right_rounded, color: Colors.white70, size: 20),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Automatically displays active announcements upon citizen login, with an X close button.
Future<void> showCitizenAnnouncementsDialog(BuildContext context) async {
  List<AnnouncementItem> items;
  try {
    items = await context.read<ApiService>().publicAnnouncements();
  } catch (_) {
    return;
  }
  if (items.isEmpty || !context.mounted) return;

  await showDialog<void>(
    context: context,
    barrierDismissible: true,
    builder: (ctx) => _CitizenAnnouncementDialog(items: items),
  );
}

class _CitizenAnnouncementDialog extends StatefulWidget {
  const _CitizenAnnouncementDialog({required this.items});
  final List<AnnouncementItem> items;

  @override
  State<_CitizenAnnouncementDialog> createState() => _CitizenAnnouncementDialogState();
}

class _CitizenAnnouncementDialogState extends State<_CitizenAnnouncementDialog> {
  final PageController _controller = PageController();
  int _index = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    if (widget.items.length > 1) {
      _timer = Timer.periodic(const Duration(seconds: 5), (_) {
        if (!mounted || !_controller.hasClients) return;
        final next = (_index + 1) % widget.items.length;
        _controller.animateToPage(
          next,
          duration: const Duration(milliseconds: 450),
          curve: Curves.easeInOut,
        );
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      titlePadding: const EdgeInsets.fromLTRB(20, 16, 12, 8),
      title: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: AppColors.navy.withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.campaign_rounded, color: AppColors.navy, size: 22),
          ),
          const SizedBox(width: 10),
          const Expanded(
            child: Text(
              'City Announcements',
              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18),
            ),
          ),
          IconButton(
            tooltip: 'Close',
            onPressed: () => Navigator.pop(context),
            icon: const Icon(Icons.close_rounded),
          ),
        ],
      ),
      content: SizedBox(
        width: 460,
        height: 220,
        child: Column(
          children: [
            Expanded(
              child: PageView.builder(
                controller: _controller,
                itemCount: widget.items.length,
                onPageChanged: (i) => setState(() => _index = i),
                itemBuilder: (context, i) {
                  final a = widget.items[i];
                  return Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: isDark ? const Color(0xFF0F172A) : AppColors.panel,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: isDark ? const Color(0xFF334155) : AppColors.line,
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                              decoration: BoxDecoration(
                                color: AppColors.navy,
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Text(
                                a.category,
                                style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700),
                              ),
                            ),
                            const Spacer(),
                            Text(
                              'By ${a.createdByName}',
                              style: TextStyle(
                                fontSize: 11,
                                color: isDark ? Colors.white60 : AppColors.muted,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Text(
                          a.title,
                          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
                        ),
                        const SizedBox(height: 8),
                        Expanded(
                          child: SingleChildScrollView(
                            child: Text(
                              a.content,
                              style: const TextStyle(fontSize: 13.5, height: 1.45),
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
            if (widget.items.length > 1) ...[
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (var i = 0; i < widget.items.length; i++)
                    Container(
                      margin: const EdgeInsets.symmetric(horizontal: 3),
                      width: i == _index ? 18 : 7,
                      height: 7,
                      decoration: BoxDecoration(
                        color: i == _index ? AppColors.navy : AppColors.muted.withValues(alpha: 0.4),
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    );
  }
}
