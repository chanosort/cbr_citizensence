import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../core/constants.dart';
import '../core/theme.dart';
import '../models/models.dart';
import '../core/format.dart';
import '../providers/auth_provider.dart';
import '../services/api_service.dart';
import 'announcement_slideshow.dart';
import 'seal_logo.dart';

class NavItem {
  final String label;
  final IconData icon;
  final String route;
  const NavItem(this.label, this.icon, this.route);
}

List<NavItem> navFor(UserRole role) {
  switch (role) {
    case UserRole.citizen:
      return [
        NavItem('Dashboard', Icons.space_dashboard_outlined, role.home),
        const NavItem('Submit Complaint', Icons.edit_note_rounded, '/submit-complaint'),
        NavItem(role.listLabel, Icons.list_alt_rounded, role.listRoute),
        const NavItem('Settings', Icons.settings_outlined, '/settings'),
      ];
    case UserRole.staff:
      return [
        NavItem('Dashboard', Icons.space_dashboard_outlined, role.home),
        NavItem(role.listLabel, Icons.assignment_outlined, role.listRoute),
        const NavItem('Settings', Icons.settings_outlined, '/settings'),
      ];
    case UserRole.admin:
      return [
        NavItem('Dashboard', Icons.space_dashboard_outlined, role.home),
        NavItem(role.listLabel, Icons.list_alt_rounded, role.listRoute),
        const NavItem('Reports', Icons.bar_chart_rounded, '/reports-analytics'),
        const NavItem('Users & Offices', Icons.groups_2_outlined, '/admin/users'),
        const NavItem('Settings', Icons.settings_outlined, '/settings'),
      ];
  }
}

/// Blue sidebar + top bar, like the reference dashboard. Becomes a drawer on
/// narrow screens.
class AppShell extends StatefulWidget {
  const AppShell({
    super.key,
    required this.title,
    required this.activeLabel,
    required this.child,
  });
  final String title;
  final String activeLabel;
  final Widget child;

  /// Tracks user IDs that already saw the login announcement popup this session.
  static final Set<int> _announcedUsers = <int>{};

  static void resetAnnouncementsSession() => _announcedUsers.clear();

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final user = context.read<AuthProvider>().user;
      if (user != null &&
          user.role == UserRole.citizen &&
          !AppShell._announcedUsers.contains(user.id)) {
        AppShell._announcedUsers.add(user.id);
        showCitizenAnnouncementsDialog(context);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final user = context.watch<AuthProvider>().user;
    if (user == null) return const SizedBox.shrink();

    return LayoutBuilder(builder: (context, box) {
      if (box.maxHeight <= 50 || box.maxWidth <= 50) {
        return const SizedBox.shrink();
      }
      final wide = box.maxWidth >= 960;
      final content = Column(children: [
        _TopBar(
          title: widget.title,
          user: user,
          showMenu: !wide,
          allowSearch: widget.activeLabel == user.role.listLabel,
        ),
        Expanded(child: widget.child),
      ]);
      return Scaffold(
        drawer: wide
            ? null
            : Drawer(
                backgroundColor: AppColors.navy,
                child: _Sidebar(user: user, activeLabel: widget.activeLabel, inDrawer: true),
              ),
        body: wide
            ? Row(children: [
                SizedBox(
                    width: 260,
                    child: _Sidebar(user: user, activeLabel: widget.activeLabel, inDrawer: false)),
                Expanded(child: content),
              ])
            : SafeArea(child: content),
      );
    });
  }
}

class _Sidebar extends StatelessWidget {
  const _Sidebar({required this.user, required this.activeLabel, required this.inDrawer});
  final AppUser user;
  final String activeLabel;
  final bool inDrawer;

  @override
  Widget build(BuildContext context) {
    final items = navFor(user.role);
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [AppColors.navy, AppColors.navyDark],
        ),
      ),
      child: SafeArea(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 24, 20, 8),
            child: Row(children: [
              SealLogo(size: 52),
              SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text('CitizenSense',
                        maxLines: 1,
                        softWrap: false,
                        style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w800)),
                  ),
                  Text('Cabadbaran City',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: Colors.white70, fontSize: 12)),
                ]),
              ),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.only(left: 20, bottom: 16),
            child: Container(width: 36, height: 3, color: AppColors.gold),
          ),
          // Profile + Notification Bell transferred to the side panel
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 16),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: Colors.white.withValues(alpha: 0.15)),
              ),
              child: Row(children: [
                CircleAvatar(
                  radius: 19,
                  backgroundColor: Colors.white,
                  backgroundImage: (user.avatarUrl != null && user.avatarUrl!.isNotEmpty)
                      ? NetworkImage(context.read<ApiService>().getAvatarUrl(user.avatarUrl))
                      : null,
                  child: (user.avatarUrl == null || user.avatarUrl!.isEmpty)
                      ? Text(user.initials,
                          style: const TextStyle(color: AppColors.navy, fontWeight: FontWeight.w800, fontSize: 13))
                      : null,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                    Text(user.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 13)),
                    Text(user.role.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white70, fontSize: 11)),
                  ]),
                ),
                const _Bell(light: true),
              ]),
            ),
          ),
          Expanded(
            child: ListView(children: [
              for (final it in items)
                _NavTile(
                  icon: it.icon,
                  label: it.label,
                  active: it.label == activeLabel,
                  onTap: () {
                    if (inDrawer) Navigator.of(context).pop();
                    context.go(it.route);
                  },
                ),
            ]),
          ),
          _NavTile(
            icon: Icons.logout_rounded,
            label: 'Logout',
            active: false,
            onTap: () {
              if (inDrawer) Navigator.of(context).pop();
              context.read<AuthProvider>().logout();
            },
          ),
          const SizedBox(height: 16),
        ]),
      ),
    );
  }
}

class _NavTile extends StatelessWidget {
  const _NavTile({required this.icon, required this.label, required this.active, required this.onTap});
  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    const radius = BorderRadius.horizontal(left: Radius.circular(28));
    return Padding(
      padding: const EdgeInsets.only(left: 16, bottom: 6),
      child: Material(
        color: active ? Colors.white : Colors.transparent,
        borderRadius: radius,
        child: InkWell(
          borderRadius: radius,
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
            child: Row(children: [
              Icon(icon, size: 22, color: active ? AppColors.navy : Colors.white70),
              const SizedBox(width: 14),
              Expanded(
                child: Text(label,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: active ? AppColors.navy : Colors.white,
                      fontWeight: active ? FontWeight.w800 : FontWeight.w500,
                    )),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.title,
    required this.user,
    required this.showMenu,
    required this.allowSearch,
  });
  final String title;
  final AppUser user;
  final bool showMenu;
  final bool allowSearch;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      final showSearch = allowSearch && box.maxWidth >= 760;
      return Padding(
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 10),
        child: Row(children: [
          if (showMenu)
            Builder(
              builder: (ctx) => IconButton(
                tooltip: 'Open menu',
                icon: const Icon(Icons.menu_rounded),
                onPressed: () => Scaffold.of(ctx).openDrawer(),
              ),
            ),
          Flexible(
            child: Text(
              title,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
            ),
          ),
          if (showSearch) ...[
            const SizedBox(width: 28),
            Flexible(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 340),
                child: TextField(
                  textInputAction: TextInputAction.search,
                  onSubmitted: (q) => context.go(
                      '${user.role.listRoute}?q=${Uri.encodeQueryComponent(q.trim())}'),
                  decoration: const InputDecoration(
                    hintText: 'Search complaints',
                    isDense: true,
                    prefixIcon: Icon(Icons.search_rounded, size: 20),
                  ),
                ),
              ),
            ),
          ],
          if (showMenu) ...[
            const Spacer(),
            const _Bell(),
          ],
        ]),
      );
    });
  }
}

class _Bell extends StatefulWidget {
  const _Bell({this.light = false});
  final bool light;

  @override
  State<_Bell> createState() => _BellState();
}

class _BellState extends State<_Bell> {
  List<AppNotice> _items = const [];
  bool _seen = false;

  @override
  void initState() {
    super.initState();
    _load();
    // Auto-refresh notifications every 30 seconds
    _startPolling();
  }

  void _startPolling() {
    Future.doWhile(() async {
      await Future.delayed(const Duration(seconds: 30));
      if (!mounted) return false;
      await _load();
      return mounted;
    });
  }

  Future<void> _load() async {
    final api = context.read<ApiService>();
    try {
      final r = await api.notifications();
      if (mounted) {
        setState(() {
          _items = r;
          if (r.any((n) => !n.isRead)) _seen = false;
        });
      }
    } catch (_) {}
  }

  void _open() {
    setState(() => _seen = true);
    // Mark all as read on the server
    final api = context.read<ApiService>();
    api.markNotificationsRead().catchError((_) {});

    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Row(
          children: [
            Icon(Icons.notifications_active_rounded, color: AppColors.navy, size: 22),
            SizedBox(width: 8),
            Text('Notifications', style: TextStyle(fontWeight: FontWeight.w800)),
          ],
        ),
        content: SizedBox(
          width: 420,
          child: _items.isEmpty
              ? const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Row(
                    children: [
                      Icon(Icons.check_circle_outline, color: AppColors.muted, size: 20),
                      SizedBox(width: 8),
                      Text('No new notifications.', style: TextStyle(color: AppColors.muted)),
                    ],
                  ),
                )
              : ListView(
                  shrinkWrap: true,
                  children: [
                    for (final n in _items)
                      _NoticeRow(notice: n, onTap: n.complaintId == null
                          ? null
                          : () {
                              Navigator.of(ctx).pop();
                              context.go('/complaints/${n.complaintId}');
                            }),
                  ],
                ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              // Reload after closing so badge resets
              _load();
            },
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final count = _seen ? 0 : _items.where((n) => !n.isRead).length;
    return Stack(clipBehavior: Clip.none, children: [
      IconButton(
        tooltip: 'Notifications',
        icon: Icon(
          Icons.notifications_none_rounded,
          color: widget.light ? Colors.white : null,
        ),
        onPressed: _open,
      ),
      if (count > 0)
        Positioned(
          right: 4,
          top: 4,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
            decoration: BoxDecoration(color: AppColors.gold, borderRadius: BorderRadius.circular(10)),
            child: Text(count > 9 ? '9+' : '$count',
                style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: AppColors.ink)),
          ),
        ),
    ]);
  }
}

class _NoticeRow extends StatelessWidget {
  const _NoticeRow({required this.notice, this.onTap});
  final AppNotice notice;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final isStatus = notice.text.contains('resolved') || notice.text.contains('processed') || notice.text.contains('received') || notice.text.contains('closed');
    final icon = isStatus ? Icons.update_rounded : Icons.assignment_add;
    final color = isStatus ? AppColors.forest : AppColors.navy;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(color: color.withValues(alpha: 0.1), shape: BoxShape.circle),
              child: Icon(icon, color: color, size: 18),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(notice.text, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Text(fmtDate(notice.at), style: const TextStyle(fontSize: 11.5, color: AppColors.muted)),
                ],
              ),
            ),
            if (onTap != null)
              const Icon(Icons.chevron_right_rounded, color: AppColors.muted, size: 18),
          ],
        ),
      ),
    );
  }
}
