import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/constants.dart';
import '../core/theme.dart';
import '../core/validators.dart';
import '../models/models.dart';
import '../providers/auth_provider.dart';
import '../providers/theme_provider.dart';
import '../services/api_service.dart';
import '../widgets/announcement_slideshow.dart';
import '../widgets/app_shell.dart';
import '../widgets/auth_layout.dart' show MessageBanner;
import '../widgets/terms_dialog.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  Widget _card(BuildContext context, Widget child) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E293B) : Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: isDark ? const Color(0xFF334155) : AppColors.line),
      ),
      child: child,
    );
  }

  void _openChangePasswordDialog() {
    showDialog<void>(
      context: context,
      builder: (_) => const _ChangePasswordDialog(),
    );
  }

  void _openStaffCrudDialog() {
    showDialog<void>(
      context: context,
      builder: (_) => const _StaffCrudDialog(),
    );
  }

  void _openAnnouncementsDialog(UserRole role) {
    if (role == UserRole.citizen) {
      showCitizenAnnouncementsDialog(context);
      return;
    }
    showDialog<void>(
      context: context,
      builder: (_) => _AnnouncementsManagerDialog(isAdmin: role == UserRole.admin),
    );
  }

  void _openChangeEmailDialog() {
    showDialog<void>(
      context: context,
      builder: (_) => const _ChangeEmailDialog(),
    );
  }

  void _openActivityLogsDialog() {
    showDialog<void>(
      context: context,
      builder: (_) => const _ActivityLogsDialog(),
    );
  }

  Future<void> _uploadProfilePhoto() async {
    final api = context.read<ApiService>();
    final auth = context.read<AuthProvider>();
    final messenger = ScaffoldMessenger.of(context);
    try {
      final res = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['jpg', 'jpeg', 'png'],
        withData: true,
      );
      if (res == null || res.files.isEmpty) return;
      final f = res.files.single;
      final bytes = f.bytes;
      if (bytes == null) return;
      final updated = await api.uploadAvatar(bytes, f.name);
      await auth.updateUser(updated);
      if (!mounted) return;
      messenger.showSnackBar(const SnackBar(
        backgroundColor: AppColors.forest,
        content: Text('Profile photo updated!'),
      ));
    } on ApiException catch (e) {
      if (mounted) messenger.showSnackBar(SnackBar(content: Text(e.displayMessage)));
    } catch (_) {
      if (mounted) messenger.showSnackBar(const SnackBar(content: Text('Could not upload profile photo.')));
    }
  }

  void _showAboutDialog() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Row(children: [
          Icon(Icons.info_outline_rounded, color: AppColors.navy),
          SizedBox(width: 8),
          Text('About CitizenSense', style: TextStyle(fontWeight: FontWeight.w800)),
        ]),
        content: const Text(
          'Cabadbaran CitizenSense v2.1\n\n'
          'AI-powered Citizen Complaint & Service Routing System for the City Government of Cabadbaran, Agusan del Norte.\n\n'
          'Powered by Hybrid TF-IDF + Multinomial Naive Bayes & Multilingual NLP (Cebuano, Tagalog, English).',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final user = context.watch<AuthProvider>().user;
    final themeProv = context.watch<ThemeProvider>();
    if (user == null) return const SizedBox.shrink();

    final isAdmin = user.role == UserRole.admin;
    final isStaff = user.role == UserRole.staff;

    return AppShell(
      title: 'Settings',
      activeLabel: 'Settings',
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
        children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 680),
              child: Column(children: [
                // ── Profile Summary Card ──────────────────────────────
                _card(
                  context,
                  Row(children: [
                    CircleAvatar(
                      radius: 30,
                      backgroundColor: AppColors.navy,
                      backgroundImage: (user.avatarUrl != null && user.avatarUrl!.isNotEmpty)
                          ? NetworkImage(context.read<ApiService>().getAvatarUrl(user.avatarUrl))
                          : null,
                      child: (user.avatarUrl == null || user.avatarUrl!.isEmpty)
                          ? Text(user.initials,
                              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 20))
                          : null,
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(user.name, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                        Text(user.email, style: const TextStyle(color: AppColors.muted)),
                        const SizedBox(height: 6),
                        Text(
                          isStaff && user.officeId != null
                              ? '${user.role.label} · ${officeById(user.officeId!).name}'
                              : user.role.label,
                          style: const TextStyle(fontWeight: FontWeight.w700, color: AppColors.seal, fontSize: 13),
                        ),
                      ]),
                    ),
                    OutlinedButton.icon(
                      onPressed: _uploadProfilePhoto,
                      icon: const Icon(Icons.camera_alt_outlined, size: 16),
                      label: Text(user.role == UserRole.citizen ? 'Photo' : 'Logo / Photo'),
                    ),
                  ]),
                ),
                const SizedBox(height: 18),

                // ── Settings Controls Card ────────────────────────────
                _card(
                  context,
                  Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    const Text('Account & System Settings',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
                    const SizedBox(height: 4),
                    const Text('Manage security, appearance, staff accounts, and announcements.',
                        style: TextStyle(color: AppColors.muted, fontSize: 13)),
                    const SizedBox(height: 16),

                    // 1. Change Password Button
                    _SettingsTile(
                      icon: Icons.lock_reset_rounded,
                      iconColor: AppColors.navy,
                      title: 'Change Password',
                      subtitle: 'Update your account password securely',
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: _openChangePasswordDialog,
                    ),
                    const Divider(height: 18),

                    // 1b. Change Email (OTP Verified)
                    _SettingsTile(
                      icon: Icons.mark_email_read_outlined,
                      iconColor: Colors.indigo,
                      title: 'Update Email Address',
                      subtitle: 'Verify via 6-digit OTP sent to your email',
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: _openChangeEmailDialog,
                    ),
                    const Divider(height: 18),

                    // 2. Dark Mode Toggle Button
                    _SettingsTile(
                      icon: themeProv.isDark ? Icons.dark_mode_rounded : Icons.light_mode_rounded,
                      iconColor: themeProv.isDark ? AppColors.gold : Colors.orange,
                      title: 'Dark Mode',
                      subtitle: themeProv.isDark ? 'Dark theme enabled' : 'Light theme enabled',
                      trailing: Switch(
                        value: themeProv.isDark,
                        onChanged: (v) => themeProv.setDark(v),
                      ),
                      onTap: () => themeProv.toggle(),
                    ),

                    // 3. Admin-only: Staff Account CRUD & Activity Logs Buttons
                    if (isAdmin) ...[
                      const Divider(height: 18),
                      _SettingsTile(
                        icon: Icons.manage_accounts_rounded,
                        iconColor: AppColors.forest,
                        title: 'Staff Account Management (CRUD)',
                        subtitle: 'Add new staff accounts, rename staff, reassign offices, or delete',
                        trailing: const Icon(Icons.chevron_right_rounded),
                        onTap: _openStaffCrudDialog,
                      ),
                      const Divider(height: 18),
                      _SettingsTile(
                        icon: Icons.history_rounded,
                        iconColor: Colors.deepPurple,
                        title: 'Activity Logs (Citizen & Staff)',
                        subtitle: 'View readable audit trail of actions across the system',
                        trailing: const Icon(Icons.chevron_right_rounded),
                        onTap: _openActivityLogsDialog,
                      ),
                    ],

                    // 4. Announcements & Promotions Button
                    const Divider(height: 18),
                    _SettingsTile(
                      icon: Icons.campaign_rounded,
                      iconColor: AppColors.seal,
                      title: isAdmin
                          ? 'Manage Announcements & Approvals'
                          : isStaff
                              ? 'Request Announcement / Promotion'
                              : 'City Announcements',
                      subtitle: isAdmin
                          ? 'Publish login slideshow banners & review staff requests'
                          : isStaff
                              ? 'Submit an announcement or promotion request to Admin'
                              : 'View active Cabadbaran City announcements',
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () => _openAnnouncementsDialog(user.role),
                    ),

                    // 5. Privacy & Terms Button
                    const Divider(height: 18),
                    _SettingsTile(
                      icon: Icons.privacy_tip_outlined,
                      iconColor: Colors.teal,
                      title: 'Privacy & Terms of Use',
                      subtitle: 'How CitizenSense protects your personal data',
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () => showTermsDialog(context),
                    ),

                    // 6. About System Button
                    const Divider(height: 18),
                    _SettingsTile(
                      icon: Icons.info_outline_rounded,
                      iconColor: AppColors.muted,
                      title: 'About CitizenSense',
                      subtitle: 'Version info & AI/NLP model details',
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: _showAboutDialog,
                    ),
                  ]),
                ),
                const SizedBox(height: 18),

                // ── Log Out Button ────────────────────────────────────
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      foregroundColor: AppColors.star,
                      side: const BorderSide(color: AppColors.star),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    ),
                    onPressed: () {
                      AppShell.resetAnnouncementsSession();
                      context.read<AuthProvider>().logout();
                    },
                    icon: const Icon(Icons.logout_rounded, size: 18),
                    label: const Text('Log out', style: TextStyle(fontWeight: FontWeight.w700)),
                  ),
                ),
              ]),
            ),
          ),
        ],
      ),
    );
  }
}

class _SettingsTile extends StatelessWidget {
  const _SettingsTile({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.subtitle,
    required this.trailing,
    required this.onTap,
  });
  final IconData icon;
  final Color iconColor;
  final String title;
  final String subtitle;
  final Widget trailing;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
        child: Row(
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: iconColor.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, color: iconColor, size: 22),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14.5)),
                const SizedBox(height: 2),
                Text(subtitle, style: const TextStyle(color: AppColors.muted, fontSize: 12.5)),
              ]),
            ),
            const SizedBox(width: 8),
            trailing,
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Change Password Dialog
// ---------------------------------------------------------------------------
class _ChangePasswordDialog extends StatefulWidget {
  const _ChangePasswordDialog();

  @override
  State<_ChangePasswordDialog> createState() => _ChangePasswordDialogState();
}

class _ChangePasswordDialogState extends State<_ChangePasswordDialog> {
  final _form = GlobalKey<FormState>();
  final _current = TextEditingController();
  final _new = TextEditingController();
  final _confirm = TextEditingController();
  bool _saving = false;
  bool _obscure = true;
  String? _error;
  String? _ok;

  @override
  void dispose() {
    _current.dispose();
    _new.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    final api = context.read<ApiService>();
    setState(() {
      _saving = true;
      _error = null;
      _ok = null;
    });
    try {
      await api.changePassword(current: _current.text, next: _new.text);
      if (!mounted) return;
      _current.clear();
      _new.clear();
      _confirm.clear();
      setState(() {
        _saving = false;
        _ok = 'Password updated successfully.';
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = e.displayMessage;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = 'Could not update the password. Please try again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      title: const Row(children: [
        Icon(Icons.lock_reset_rounded, color: AppColors.navy),
        SizedBox(width: 8),
        Text('Change Password', style: TextStyle(fontWeight: FontWeight.w800)),
      ]),
      content: SizedBox(
        width: 400,
        child: Form(
          key: _form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_error != null) ...[MessageBanner(message: _error!), const SizedBox(height: 12)],
              if (_ok != null) ...[MessageBanner(message: _ok!, good: true), const SizedBox(height: 12)],
              TextFormField(
                controller: _current,
                obscureText: _obscure,
                decoration: const InputDecoration(labelText: 'Current password'),
                validator: (v) => (v ?? '').isEmpty ? 'Enter your current password.' : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _new,
                obscureText: _obscure,
                decoration: InputDecoration(
                  labelText: 'New password',
                  helperText: kPasswordRuleHint,
                  helperMaxLines: 2,
                  suffixIcon: IconButton(
                    icon: Icon(_obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                    onPressed: () => setState(() => _obscure = !_obscure),
                  ),
                ),
                validator: (v) => validatePassword(v, strict: true),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _confirm,
                obscureText: _obscure,
                decoration: const InputDecoration(labelText: 'Confirm new password'),
                validator: (v) => v != _new.text ? 'Passwords do not match.' : null,
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
        ElevatedButton(
          onPressed: _saving ? null : _submit,
          child: _saving
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : const Text('Update Password'),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Admin Staff Account CRUD Dialog (Admin 1 & Admin 2)
// ---------------------------------------------------------------------------
class _StaffCrudDialog extends StatefulWidget {
  const _StaffCrudDialog();

  @override
  State<_StaffCrudDialog> createState() => _StaffCrudDialogState();
}

class _StaffCrudDialogState extends State<_StaffCrudDialog> {
  List<UserRecord> _staff = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final all = await context.read<ApiService>().adminUsers();
      if (!mounted) return;
      setState(() {
        _staff = all.where((u) => u.role == UserRole.staff).toList();
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Failed to load staff accounts.';
      });
    }
  }

  Future<void> _openCreateOrEdit({UserRecord? existing}) async {
    final form = GlobalKey<FormState>();
    final nameCtrl = TextEditingController(text: existing?.name ?? '');
    final emailCtrl = TextEditingController(text: existing?.email ?? '');
    final passCtrl = TextEditingController();
    int officeId = existing?.officeId ?? kOffices.first.id;
    bool saving = false;
    String? err;

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: Text(
            existing == null ? 'Add New Staff Account' : 'Edit Staff Account',
            style: const TextStyle(fontWeight: FontWeight.w800),
          ),
          content: SizedBox(
            width: 420,
            child: Form(
              key: form,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (err != null) ...[MessageBanner(message: err!), const SizedBox(height: 10)],
                  TextFormField(
                    controller: nameCtrl,
                    decoration: const InputDecoration(labelText: 'Staff Full Name'),
                    validator: (v) => (v ?? '').trim().length < 2 ? 'Enter staff name.' : null,
                  ),
                  const SizedBox(height: 12),
                  if (existing == null) ...[
                    TextFormField(
                      controller: emailCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Staff Email',
                        hintText: 'e.g. juan@staff.com',
                      ),
                      validator: (v) => (v ?? '').contains('@') ? null : 'Enter a valid email.',
                    ),
                    const SizedBox(height: 12),
                  ],
                  DropdownButtonFormField<int>(
                    initialValue: officeId,
                    decoration: const InputDecoration(labelText: 'Assigned Office'),
                    items: [
                      for (final o in kOffices) DropdownMenuItem(value: o.id, child: Text(o.name)),
                    ],
                    onChanged: (v) => setS(() => officeId = v ?? officeId),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: passCtrl,
                    obscureText: true,
                    decoration: InputDecoration(
                      labelText: existing == null ? 'Password' : 'New Password (optional)',
                      helperText: kPasswordRuleHint,
                      helperMaxLines: 2,
                    ),
                    validator: (v) {
                      final val = v ?? '';
                      if (existing == null) return validatePassword(val, strict: true);
                      if (val.isNotEmpty) return validatePassword(val, strict: true);
                      return null;
                    },
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            ElevatedButton(
              onPressed: saving
                  ? null
                  : () async {
                      if (!form.currentState!.validate()) return;
                      setS(() {
                        saving = true;
                        err = null;
                      });
                      try {
                        final api = context.read<ApiService>();
                        if (existing == null) {
                          await api.createStaffUser(
                            name: nameCtrl.text.trim(),
                            email: emailCtrl.text.trim(),
                            password: passCtrl.text,
                            officeId: officeId,
                          );
                        } else {
                          await api.updateStaffUser(
                            id: existing.id,
                            name: nameCtrl.text.trim(),
                            officeId: officeId,
                            password: passCtrl.text.isNotEmpty ? passCtrl.text : null,
                          );
                        }
                        if (ctx.mounted) Navigator.pop(ctx);
                        _load();
                      } on ApiException catch (e) {
                        setS(() {
                          saving = false;
                          err = e.displayMessage;
                        });
                      } catch (_) {
                        setS(() {
                          saving = false;
                          err = 'Operation failed. Please try again.';
                        });
                      }
                    },
              child: saving
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : Text(existing == null ? 'Create Staff' : 'Save Changes'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _deleteStaff(UserRecord u) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Staff Account?'),
        content: Text('Are you sure you want to delete "${u.name}" (${u.email})?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.star),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;
    try {
      await context.read<ApiService>().deleteStaffUser(u.id);
      _load();
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      title: Row(children: [
        const Icon(Icons.manage_accounts_rounded, color: AppColors.forest),
        const SizedBox(width: 8),
        const Expanded(child: Text('Staff Account CRUD', style: TextStyle(fontWeight: FontWeight.w800))),
        ElevatedButton.icon(
          style: ElevatedButton.styleFrom(minimumSize: const Size(0, 38), padding: const EdgeInsets.symmetric(horizontal: 12)),
          onPressed: () => _openCreateOrEdit(),
          icon: const Icon(Icons.person_add_rounded, size: 16),
          label: const Text('Add Staff'),
        ),
      ]),
      content: SizedBox(
        width: 580,
        height: 420,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
                ? Center(child: Text(_error!))
                : _staff.isEmpty
                    ? const Center(child: Text('No staff accounts found.'))
                    : ListView.separated(
                        itemCount: _staff.length,
                        separatorBuilder: (_, __) => const Divider(height: 12),
                        itemBuilder: (context, i) {
                          final u = _staff[i];
                          final officeName = u.officeId != null ? officeById(u.officeId!).name : 'Unassigned';
                          return ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: CircleAvatar(
                              backgroundColor: u.active ? AppColors.navy : AppColors.muted,
                              child: Text(u.name.isNotEmpty ? u.name[0].toUpperCase() : 'S',
                                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
                            ),
                            title: Text(u.name, style: const TextStyle(fontWeight: FontWeight.w700)),
                            subtitle: Text('${u.email} · $officeName${u.active ? '' : ' (Inactive)'}'),
                            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                              IconButton(
                                tooltip: 'Edit name / office / password',
                                icon: const Icon(Icons.edit_rounded, color: AppColors.navy),
                                onPressed: () => _openCreateOrEdit(existing: u),
                              ),
                              IconButton(
                                tooltip: u.active ? 'Deactivate' : 'Activate',
                                icon: Icon(u.active ? Icons.toggle_on_rounded : Icons.toggle_off_rounded,
                                    color: u.active ? AppColors.forest : AppColors.muted, size: 28),
                                onPressed: () async {
                                  await context.read<ApiService>().updateStaffUser(id: u.id, active: !u.active);
                                  _load();
                                },
                              ),
                              IconButton(
                                tooltip: 'Delete staff',
                                icon: const Icon(Icons.delete_outline_rounded, color: AppColors.star),
                                onPressed: () => _deleteStaff(u),
                              ),
                            ]),
                          );
                        },
                      ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Announcements Manager (Admin: Create/Approve/Reject/Delete; Staff: Request)
// ---------------------------------------------------------------------------
class _AnnouncementsManagerDialog extends StatefulWidget {
  const _AnnouncementsManagerDialog({required this.isAdmin});
  final bool isAdmin;

  @override
  State<_AnnouncementsManagerDialog> createState() => _AnnouncementsManagerDialogState();
}

class _AnnouncementsManagerDialogState extends State<_AnnouncementsManagerDialog> {
  List<AnnouncementItem> _items = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await context.read<ApiService>().announcements();
      if (!mounted) return;
      setState(() {
        _items = list;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Unable to load announcements.';
      });
    }
  }

  Future<void> _openCreateForm({AnnouncementItem? existing}) async {
    final form = GlobalKey<FormState>();
    final titleCtrl = TextEditingController(text: existing?.title ?? '');
    final contentCtrl = TextEditingController(text: existing?.content ?? '');
    const validCategories = ['Announcement', 'Promotion', 'Advisory', 'Event'];
    String category = (existing != null && validCategories.contains(existing.category))
        ? existing.category
        : 'Announcement';
    bool saving = false;

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: Text(
            existing != null
                ? 'Edit Announcement / Promotion'
                : widget.isAdmin
                    ? 'Publish Announcement / Promotion'
                    : 'Request Announcement / Promotion',
            style: const TextStyle(fontWeight: FontWeight.w800),
          ),
          content: SizedBox(
            width: 440,
            child: Form(
              key: form,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (!widget.isAdmin && existing == null)
                    const Padding(
                      padding: EdgeInsets.only(bottom: 12),
                      child: MessageBanner(
                        message: 'Your request will be sent to Admin for approval before appearing on the Login page.',
                        good: true,
                      ),
                    ),
                  DropdownButtonFormField<String>(
                    initialValue: category,
                    decoration: const InputDecoration(labelText: 'Category'),
                    items: const [
                      DropdownMenuItem(value: 'Announcement', child: Text('Announcement')),
                      DropdownMenuItem(value: 'Promotion', child: Text('Promotion')),
                      DropdownMenuItem(value: 'Advisory', child: Text('Advisory')),
                      DropdownMenuItem(value: 'Event', child: Text('Event')),
                    ],
                    onChanged: (v) => setS(() => category = v ?? 'Announcement'),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: titleCtrl,
                    decoration: const InputDecoration(labelText: 'Title'),
                    validator: (v) => (v ?? '').trim().length < 3 ? 'Enter a title.' : null,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: contentCtrl,
                    maxLines: 4,
                    decoration: const InputDecoration(labelText: 'Details / Message'),
                    validator: (v) => (v ?? '').trim().length < 5 ? 'Enter announcement details.' : null,
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            ElevatedButton(
              onPressed: saving
                  ? null
                  : () async {
                      if (!form.currentState!.validate()) return;
                      setS(() => saving = true);
                      try {
                        final api = context.read<ApiService>();
                        if (existing != null) {
                          await api.updateAnnouncement(
                            id: existing.id,
                            title: titleCtrl.text.trim(),
                            content: contentCtrl.text.trim(),
                            category: category,
                          );
                        } else {
                          await api.createAnnouncement(
                            title: titleCtrl.text.trim(),
                            content: contentCtrl.text.trim(),
                            category: category,
                          );
                        }
                        if (ctx.mounted) Navigator.pop(ctx);
                        _load();
                      } catch (_) {
                        setS(() => saving = false);
                      }
                    },
              child: Text(
                existing != null
                    ? 'Save Changes'
                    : (widget.isAdmin ? 'Publish Now' : 'Submit Request'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      title: Row(children: [
        const Icon(Icons.campaign_rounded, color: AppColors.seal),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            widget.isAdmin ? 'Announcements & Requests' : 'Announcement Requests',
            style: const TextStyle(fontWeight: FontWeight.w800),
          ),
        ),
        ElevatedButton.icon(
          style: ElevatedButton.styleFrom(minimumSize: const Size(0, 38), padding: const EdgeInsets.symmetric(horizontal: 12)),
          onPressed: _openCreateForm,
          icon: const Icon(Icons.add_rounded, size: 16),
          label: Text(widget.isAdmin ? 'New Announcement' : 'Request Form'),
        ),
      ]),
      content: SizedBox(
        width: 600,
        height: 430,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
                ? Center(child: Text(_error!))
                : _items.isEmpty
                    ? const Center(child: Text('No announcements yet.'))
                    : ListView.separated(
                        itemCount: _items.length,
                        separatorBuilder: (_, __) => const Divider(height: 14),
                        itemBuilder: (context, i) {
                          final a = _items[i];
                          final statusColor = a.status == 'approved'
                              ? AppColors.forest
                              : a.status == 'pending'
                                  ? Colors.orange
                                  : AppColors.star;
                          return ListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Row(children: [
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                decoration: BoxDecoration(
                                  color: statusColor.withValues(alpha: 0.14),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Text(
                                  a.status.toUpperCase(),
                                  style: TextStyle(color: statusColor, fontSize: 10, fontWeight: FontWeight.w800),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(child: Text(a.title, style: const TextStyle(fontWeight: FontWeight.w700))),
                            ]),
                            subtitle: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const SizedBox(height: 4),
                                Text(a.content, maxLines: 2, overflow: TextOverflow.ellipsis),
                                const SizedBox(height: 4),
                                Text('${a.category} · By ${a.createdByName} (${a.createdByRole})',
                                    style: const TextStyle(fontSize: 11.5, color: AppColors.muted)),
                              ],
                            ),
                            trailing: widget.isAdmin
                                ? Row(mainAxisSize: MainAxisSize.min, children: [
                                    if (a.status == 'pending') ...[
                                      IconButton(
                                        tooltip: 'Approve & Publish',
                                        icon: const Icon(Icons.check_circle_rounded, color: AppColors.forest),
                                        onPressed: () async {
                                          await context.read<ApiService>().updateAnnouncement(id: a.id, status: 'approved', isActive: true);
                                          _load();
                                        },
                                      ),
                                      IconButton(
                                        tooltip: 'Reject',
                                        icon: const Icon(Icons.cancel_rounded, color: AppColors.star),
                                        onPressed: () async {
                                          await context.read<ApiService>().updateAnnouncement(id: a.id, status: 'rejected', isActive: false);
                                          _load();
                                        },
                                      ),
                                    ] else
                                      IconButton(
                                        tooltip: a.isActive ? 'Hide from Login' : 'Show on Login',
                                        icon: Icon(a.isActive ? Icons.visibility_rounded : Icons.visibility_off_rounded,
                                            color: a.isActive ? AppColors.navy : AppColors.muted),
                                        onPressed: () async {
                                          await context.read<ApiService>().updateAnnouncement(id: a.id, isActive: !a.isActive);
                                          _load();
                                        },
                                      ),
                                    IconButton(
                                      tooltip: 'Edit announcement',
                                      icon: const Icon(Icons.edit_rounded, color: AppColors.navy),
                                      onPressed: () => _openCreateForm(existing: a),
                                    ),
                                    IconButton(
                                      tooltip: 'Delete',
                                      icon: const Icon(Icons.delete_outline_rounded, color: AppColors.star),
                                      onPressed: () async {
                                        await context.read<ApiService>().deleteAnnouncement(a.id);
                                        _load();
                                      },
                                    ),
                                  ])
                                : (a.status == 'pending'
                                    ? IconButton(
                                        tooltip: 'Cancel request',
                                        icon: const Icon(Icons.delete_outline_rounded, color: AppColors.star),
                                        onPressed: () async {
                                          await context.read<ApiService>().deleteAnnouncement(a.id);
                                          _load();
                                        },
                                      )
                                    : null),
                          );
                        },
                      ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Change Email Dialog (OTP Verified)
// ---------------------------------------------------------------------------
class _ChangeEmailDialog extends StatefulWidget {
  const _ChangeEmailDialog();

  @override
  State<_ChangeEmailDialog> createState() => _ChangeEmailDialogState();
}

class _ChangeEmailDialogState extends State<_ChangeEmailDialog> {
  final _passCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _codeCtrl = TextEditingController();
  bool _codeSent = false;
  bool _busy = false;
  String? _error;
  String? _ok;

  @override
  void dispose() {
    _passCtrl.dispose();
    _emailCtrl.dispose();
    _codeCtrl.dispose();
    super.dispose();
  }

  Future<void> _sendCode() async {
    if (_passCtrl.text.isEmpty || !_emailCtrl.text.contains('@')) {
      setState(() => _error = 'Enter your current password and a valid new email.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _ok = null;
    });
    try {
      await context.read<ApiService>().requestEmailChange(
            currentPassword: _passCtrl.text,
            newEmail: _emailCtrl.text.trim(),
          );
      if (!mounted) return;
      setState(() {
        _busy = false;
        _codeSent = true;
        _ok = 'A 6-digit verification code was sent to your current email.';
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.displayMessage;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'Could not send verification code.';
      });
    }
  }

  Future<void> _confirmCode() async {
    if (_codeCtrl.text.trim().length != 6) {
      setState(() => _error = 'Enter the 6-digit verification code.');
      return;
    }
    final api = context.read<ApiService>();
    final auth = context.read<AuthProvider>();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final updated = await api.confirmEmailChange(
        newEmail: _emailCtrl.text.trim(),
        code: _codeCtrl.text.trim(),
      );
      await auth.updateUser(updated);
      if (!mounted) return;
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(backgroundColor: AppColors.forest, content: Text('Email updated successfully!')),
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.displayMessage;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'Verification failed. Check the code and try again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      title: const Row(children: [
        Icon(Icons.mark_email_read_outlined, color: Colors.indigo),
        SizedBox(width: 8),
        Text('Update Email Address', style: TextStyle(fontWeight: FontWeight.w800)),
      ]),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_error != null) ...[MessageBanner(message: _error!), const SizedBox(height: 10)],
            if (_ok != null) ...[MessageBanner(message: _ok!, good: true), const SizedBox(height: 10)],
            TextField(
              controller: _passCtrl,
              obscureText: true,
              enabled: !_codeSent,
              decoration: const InputDecoration(labelText: 'Current password'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _emailCtrl,
              enabled: !_codeSent,
              decoration: const InputDecoration(labelText: 'New email address'),
            ),
            if (_codeSent) ...[
              const SizedBox(height: 12),
              TextField(
                controller: _codeCtrl,
                maxLength: 6,
                decoration: const InputDecoration(labelText: '6-digit verification code'),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
        ElevatedButton(
          onPressed: _busy ? null : (_codeSent ? _confirmCode : _sendCode),
          child: _busy
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : Text(_codeSent ? 'Verify & Update Email' : 'Send Verification Code'),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Admin Activity Logs Dialog
// ---------------------------------------------------------------------------
class _ActivityLogsDialog extends StatefulWidget {
  const _ActivityLogsDialog();

  @override
  State<_ActivityLogsDialog> createState() => _ActivityLogsDialogState();
}

class _ActivityLogsDialogState extends State<_ActivityLogsDialog> {
  List<ActivityLogItem> _logs = const [];
  String? _roleFilter;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final list = await context.read<ApiService>().adminActivityLogs(role: _roleFilter);
      if (mounted) {
        setState(() {
          _logs = list;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      title: const Row(children: [
        Icon(Icons.history_rounded, color: Colors.deepPurple),
        SizedBox(width: 8),
        Text('System Activity Logs', style: TextStyle(fontWeight: FontWeight.w800)),
      ]),
      content: SizedBox(
        width: 620,
        height: 440,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(spacing: 8, children: [
              for (final entry in <String?, String>{null: 'All', 'citizen': 'Citizens', 'staff': 'Staff', 'admin': 'Admins'}.entries)
                ChoiceChip(
                  label: Text(entry.value),
                  selected: _roleFilter == entry.key,
                  onSelected: (_) {
                    _roleFilter = entry.key;
                    _load();
                  },
                ),
            ]),
            const SizedBox(height: 12),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _logs.isEmpty
                      ? const Center(child: Text('No activity logs recorded yet.', style: TextStyle(color: AppColors.muted)))
                      : ListView.separated(
                          itemCount: _logs.length,
                          separatorBuilder: (_, __) => const Divider(height: 12),
                          itemBuilder: (_, i) {
                            final l = _logs[i];
                            return ListTile(
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              leading: CircleAvatar(
                                radius: 16,
                                backgroundColor: AppColors.navy.withValues(alpha: 0.12),
                                child: Text(
                                  l.actorRole.isNotEmpty ? l.actorRole[0].toUpperCase() : 'S',
                                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: AppColors.navy),
                                ),
                              ),
                              title: Text(l.summary, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5)),
                              subtitle: Text('${l.actorName} (${l.actorRole}) · ${l.createdAt.toLocal().toString().substring(0, 16)}',
                                  style: const TextStyle(fontSize: 11.5, color: AppColors.muted)),
                            );
                          },
                        ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
      ],
    );
  }
}
