import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../core/constants.dart';
import '../core/file_download_helper.dart';
import '../core/theme.dart';
import '../models/models.dart';
import '../services/api_service.dart';
import '../widgets/app_shell.dart';
import '../widgets/auth_layout.dart' show showCenterPromptDialog;
import '../widgets/chips.dart';

/// Reports and Analytics (admin): EP-08 GET /api/reports.
class ReportsScreen extends StatefulWidget {
  const ReportsScreen({super.key});

  @override
  State<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends State<ReportsScreen> {
  static const _ranges = {7: 'Last 7 days', 14: 'Last 14 days', 30: 'Last 30 days', 90: 'Last 90 days', 0: 'All time'};
  int _days = 0; // default to All time to show all 2,030 complaints
  int? _officeId;
  int? _categoryId;
  ReportData? _data;
  String? _error;
  bool _loading = true;
  bool _exporting = false;
  int _reqId = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final api = context.read<ApiService>();
    final id = ++_reqId;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final r = await api.report(ReportFilter(days: _days, officeId: _officeId, categoryId: _categoryId));
      if (!mounted || id != _reqId) return;
      setState(() {
        _data = r;
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted || id != _reqId) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || id != _reqId) return;
      setState(() {
        _error = 'Report generation failed. Adjust the filters and try again.';
        _loading = false;
      });
    }
  }

  Future<void> _downloadReport() async {
    final now = DateTime.now();
    String mode = _days == 0 ? 'all' : 'days';
    int selectedDays = _days == 0 ? 30 : _days;
    String selectedMonth = '${now.year}-${now.month.toString().padLeft(2, '0')}';
    int? selectedOffice = _officeId;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: const Row(children: [
            Icon(Icons.download_rounded, color: AppColors.navy),
            SizedBox(width: 8),
            Text('Export CSV Report', style: TextStyle(fontWeight: FontWeight.w800)),
          ]),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                DropdownButtonFormField<String>(
                  initialValue: mode,
                  decoration: const InputDecoration(labelText: 'Report Type'),
                  items: const [
                    DropdownMenuItem(value: 'all', child: Text('All Time (All Complaints)')),
                    DropdownMenuItem(value: 'monthly', child: Text('Monthly Report (Pick Month)')),
                    DropdownMenuItem(value: 'days', child: Text('Recent Range (Last N Days)')),
                  ],
                  onChanged: (v) => setS(() => mode = v ?? 'all'),
                ),
                if (mode == 'monthly') ...[
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    initialValue: selectedMonth,
                    decoration: const InputDecoration(labelText: 'Select Month'),
                    items: List.generate(18, (i) {
                      final d = DateTime(now.year, now.month - i, 1);
                      final ym = '${d.year}-${d.month.toString().padLeft(2, '0')}';
                      const mNames = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
                      return DropdownMenuItem(value: ym, child: Text('${mNames[d.month - 1]} ${d.year} ($ym)'));
                    }),
                    onChanged: (v) => setS(() => selectedMonth = v ?? selectedMonth),
                  ),
                ],
                if (mode == 'days') ...[
                  const SizedBox(height: 12),
                  DropdownButtonFormField<int>(
                    initialValue: selectedDays,
                    decoration: const InputDecoration(labelText: 'Range'),
                    items: const [
                      DropdownMenuItem(value: 7, child: Text('Last 7 days')),
                      DropdownMenuItem(value: 14, child: Text('Last 14 days')),
                      DropdownMenuItem(value: 30, child: Text('Last 30 days')),
                      DropdownMenuItem(value: 90, child: Text('Last 90 days')),
                    ],
                    onChanged: (v) => setS(() => selectedDays = v ?? 30),
                  ),
                ],
                const SizedBox(height: 12),
                DropdownButtonFormField<int?>(
                  initialValue: selectedOffice,
                  decoration: const InputDecoration(labelText: 'Office Scope'),
                  items: [
                    const DropdownMenuItem<int?>(value: null, child: Text('All Offices (All Complaints)')),
                    for (final o in kOffices)
                      DropdownMenuItem<int?>(value: o.id, child: Text(o.name, overflow: TextOverflow.ellipsis)),
                  ],
                  onChanged: (v) => setS(() => selectedOffice = v),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            ElevatedButton.icon(
              onPressed: () => Navigator.pop(ctx, true),
              icon: const Icon(Icons.download_rounded, size: 18),
              label: const Text('Download CSV'),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true || !mounted) return;

    final api = context.read<ApiService>();
    setState(() => _exporting = true);
    try {
      final exportDays = mode == 'all' ? 0 : (mode == 'days' ? selectedDays : 0);
      final exportMonth = mode == 'monthly' ? selectedMonth : null;
      final bytes = await api.downloadReportCsvBytes(
        days: exportDays,
        month: exportMonth,
        officeId: selectedOffice,
        categoryId: _categoryId,
      );
      final scopeTag = selectedOffice == null ? 'AllOffices' : officeById(selectedOffice!).shortName.replaceAll(' ', '');
      final periodTag = exportMonth ?? (exportDays == 0 ? 'AllTime' : '${exportDays}days');
      final fileName = 'CitizenSense_Report_${periodTag}_$scopeTag.csv';
      downloadFileFromBytes(bytes, fileName);
      if (mounted) {
        await showCenterPromptDialog(
          context,
          title: 'Report Downloaded',
          message: 'Report downloaded as "$fileName".',
        );
      }
    } catch (e) {
      if (mounted) {
        await showCenterPromptDialog(
          context,
          title: 'Download Failed',
          message: 'Download failed: $e',
          good: false,
        );
      }
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppShell(
      title: 'Reports',
      activeLabel: 'Reports',
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
        children: [
          _filters(),
          const SizedBox(height: 16),
          if (_loading)
            const Padding(padding: EdgeInsets.all(48), child: Center(child: CircularProgressIndicator()))
          else if (_error != null)
            Center(
              child: Column(children: [
                const SizedBox(height: 32),
                const Icon(Icons.error_outline_rounded, size: 40, color: AppColors.star),
                const SizedBox(height: 8),
                Text(_error!),
                TextButton(onPressed: _load, child: const Text('Try again')),
              ]),
            )
          else if (_data != null)
            ..._report(_data!),
        ],
      ),
    );
  }

  Widget _filters() {
    final hasData = _data != null && _data!.total > 0;
    return Wrap(spacing: 12, runSpacing: 12, crossAxisAlignment: WrapCrossAlignment.center, children: [
      SizedBox(
        width: 180,
        child: DropdownButtonFormField<int>(
          initialValue: _days,
          isDense: true,
          decoration: const InputDecoration(labelText: 'Period', isDense: true),
          items: _ranges.entries.map((e) => DropdownMenuItem(value: e.key, child: Text(e.value))).toList(),
          onChanged: (v) {
            _days = v ?? 0;
            _load();
          },
        ),
      ),
      SizedBox(
        width: 230,
        child: DropdownButtonFormField<int?>(
          initialValue: _officeId,
          isExpanded: true,
          isDense: true,
          decoration: const InputDecoration(labelText: 'Office', isDense: true),
          items: [
            const DropdownMenuItem<int?>(value: null, child: Text('All offices')),
            for (final o in kOffices) DropdownMenuItem<int?>(value: o.id, child: Text(o.shortName)),
          ],
          onChanged: (v) {
            _officeId = v;
            _load();
          },
        ),
      ),
      SizedBox(
        width: 260,
        child: DropdownButtonFormField<int?>(
          initialValue: _categoryId,
          isExpanded: true,
          isDense: true,
          decoration: const InputDecoration(labelText: 'Category', isDense: true),
          items: [
            const DropdownMenuItem<int?>(value: null, child: Text('All categories')),
            for (final c in kCategories)
              DropdownMenuItem<int?>(value: c.id, child: Text(c.name, overflow: TextOverflow.ellipsis)),
          ],
          onChanged: (v) {
            _categoryId = v;
            _load();
          },
        ),
      ),
      FilledButton.icon(
        onPressed: hasData && !_exporting ? _downloadReport : null,
        icon: _exporting
            ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
            : const Icon(Icons.download_rounded, size: 18),
        label: Text(_exporting ? 'Generating...' : 'Download Report'),
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.navy,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        ),
      ),
    ]);
  }

  Color _prioColor(String label) => priorityFrom(label).color;

  List<Widget> _report(ReportData d) {
    Widget stat(String label, String value, Color color, IconData icon) => Expanded(
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(color: AppColors.panel, borderRadius: BorderRadius.circular(18)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(icon, color: color, size: 26),
              const SizedBox(height: 8),
              Text(value, style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w800, height: 1.1)),
              Text(label, style: const TextStyle(color: AppColors.muted, fontSize: 12.5)),
            ]),
          ),
        );

    Widget card(String title, Widget child) => Container(
          width: double.infinity,
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: AppColors.line),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
            const SizedBox(height: 14),
            child,
          ]),
        );

    if (d.total == 0) {
      return [
        card('No data', const Text('No complaints match these filters. Try a longer period or select "All time".',
            style: TextStyle(color: AppColors.muted))),
      ];
    }

    return [
      LayoutBuilder(builder: (context, box) {
        final tiles = [
          stat('Total complaints', '${d.total}', AppColors.navy, Icons.inventory_2_outlined),
          stat('Still open', '${d.open}', const Color(0xFFEF9F1A), Icons.hourglass_top_rounded),
          stat('Resolved or closed', '${d.resolved}', AppColors.forest, Icons.task_alt_rounded),
          stat('Service level', '${d.serviceLevel.toStringAsFixed(1)}%', AppColors.seal, Icons.speed_rounded),
        ];
        if (box.maxWidth >= 720) {
          return Row(children: [
            for (var i = 0; i < tiles.length; i++) ...[if (i > 0) const SizedBox(width: 12), tiles[i]],
          ]);
        }
        return Column(children: [
          Row(children: [tiles[0], const SizedBox(width: 12), tiles[1]]),
          const SizedBox(height: 12),
          Row(children: [tiles[2], const SizedBox(width: 12), tiles[3]]),
        ]);
      }),
      const SizedBox(height: 18),
      LayoutBuilder(builder: (context, box) {
        final a = card('By priority', BarList(items: [for (final e in d.byPriority) (e.label, e.count, _prioColor(e.label))]));
        final b = card('By status', BarList(items: [for (final e in d.byStatus) (e.label, e.count, null)]));
        if (box.maxWidth >= 820) {
          return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(child: a),
            const SizedBox(width: 18),
            Expanded(child: b),
          ]);
        }
        return Column(children: [a, const SizedBox(height: 18), b]);
      }),
      const SizedBox(height: 18),
      LayoutBuilder(builder: (context, box) {
        final a = card('By complaint type', BarList(items: [for (final e in d.byCategory) (e.label, e.count, null)], color: AppColors.seal));
        final b = card('By office', BarList(items: [for (final e in d.byOffice) (e.label, e.count, null)], color: AppColors.forest));
        if (box.maxWidth >= 820) {
          return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(child: a),
            const SizedBox(width: 18),
            Expanded(child: b),
          ]);
        }
        return Column(children: [a, const SizedBox(height: 18), b]);
      }),
      const SizedBox(height: 18),
      card(
        'Complaints in this report (${d.total} total)',
        Column(children: [
          for (final c in d.rows.take(15)) ...[
            InkWell(
              onTap: () => context.go('/complaints/${c.id}'),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(children: [
                  Expanded(
                    flex: 5,
                    child: Text('#${c.id}  ${c.title}', maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                  ),
                  const SizedBox(width: 8),
                  PriorityChip(c.priority),
                  const SizedBox(width: 8),
                  StatusChip(c.status),
                ]),
              ),
            ),
            const Divider(height: 1, color: AppColors.line),
          ],
          if (d.rows.length > 15)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Row(
                children: [
                  const Icon(Icons.info_outline_rounded, size: 15, color: AppColors.muted),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '+ ${d.rows.length - 15} more complaints. Click "Download Report" to export all ${d.total} rows as a formatted CSV.',
                      style: const TextStyle(color: AppColors.muted, fontSize: 12.5),
                    ),
                  ),
                ],
              ),
            ),
        ]),
      ),
    ];
  }
}
