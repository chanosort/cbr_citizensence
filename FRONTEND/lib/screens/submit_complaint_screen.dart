import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../core/constants.dart';
import '../core/theme.dart';
import '../models/models.dart';
import '../services/api_service.dart';
import '../services/mock_classifier.dart';
import '../widgets/app_shell.dart';
import '../widgets/auth_layout.dart' show MessageBanner;
import '../widgets/chips.dart';
import '../widgets/classification_card.dart';
import '../widgets/terms_dialog.dart';

class SubmitComplaintScreen extends StatefulWidget {
  const SubmitComplaintScreen({super.key});

  @override
  State<SubmitComplaintScreen> createState() => _SubmitComplaintScreenState();
}

class _SubmitComplaintScreenState extends State<SubmitComplaintScreen> {
  final _form = GlobalKey<FormState>();
  final _title = TextEditingController();
  final _desc = TextEditingController();
  late final TapGestureRecognizer _termsTap;

  int? _categoryId;
  bool _categoryManuallySet = false; // true once the citizen picks a category manually
  int? _officeId;
  int? _locationId;
  bool _officeTouched = false;
  int _officeVersion = 0;
  int _categoryVersion = 0; // forces the category dropdown to show programmatic change

  PickedAttachment? _attachment;
  String? _attachmentError;

  bool _agreed = false;
  bool _termsError = false;
  bool _sending = false;
  String? _submitError;

  Classification? _result;
  bool _classifying = false;
  String? _classifyError;
  Timer? _debounce;
  int _reqId = 0;

  @override
  void initState() {
    super.initState();
    _termsTap = TapGestureRecognizer()..onTap = _openTerms;
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _termsTap.dispose();
    _title.dispose();
    _desc.dispose();
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

  Future<void> _pickFile() async {
    try {
      final res = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['jpg', 'jpeg', 'png', 'pdf'],
        withData: true,
      );
      if (res == null || res.files.isEmpty) return;
      final f = res.files.single;
      final bytes = f.bytes;
      if (bytes == null) return;
      if (bytes.length > 5 * 1024 * 1024) {
        setState(() {
          _attachment = null;
          _attachmentError = 'Only JPG, PNG, or PDF files up to 5MB are allowed.';
        });
        return;
      }
      setState(() {
        _attachment = PickedAttachment(f.name, bytes);
        _attachmentError = null;
      });
    } catch (_) {
      setState(() => _attachmentError = 'Could not open the file picker.');
    }
  }

  String _size(int b) => b < 1024 * 1024 ? '${(b / 1024).ceil()} KB' : '${(b / 1024 / 1024).toStringAsFixed(1)} MB';

  /// NLP auto-detection: reads the description and auto-fills category + office + priority.
  void _autoDetectFromDescription(String text) {
    if (text.trim().length < 5) {
      _debounce?.cancel();
      if (_result != null || _classifying || _classifyError != null) {
        setState(() {
          _result = null;
          _classifying = false;
          _classifyError = null;
        });
      }
      return;
    }

    // Auto-detect category from text (only if user hasn't manually chosen)
    if (!_categoryManuallySet) {
      final detectedCatId = MockClassifier.detectCategory(text);
      if (detectedCatId != null && detectedCatId != _categoryId) {
        setState(() {
          _categoryId = detectedCatId;
          _categoryVersion++;
          if (!_officeTouched) {
            _officeId = categoryById(detectedCatId).officeId;
            _officeVersion++;
          }
        });
      }
    }

    // Run the full classification
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 500), _classify);
  }

  /// Runs the ML/NLP classification check.
  Future<void> _classify() async {
    final text = _desc.text.trim();
    if (text.length < 5 && _categoryId == null) return;
    final api = context.read<ApiService>();
    final id = ++_reqId;
    setState(() {
      _classifying = true;
      _classifyError = null;
    });
    try {
      final r = await api.classify(categoryId: _categoryId, description: text);
      if (!mounted || id != _reqId) return;
      setState(() {
        _result = r;
        _classifying = false;
        if (!_categoryManuallySet && r.categoryId != null && r.categoryId != _categoryId) {
          _categoryId = r.categoryId;
          _categoryVersion++;
        }
        if (!_officeTouched && r.officeId != null && r.officeId != _officeId) {
          _officeId = r.officeId;
          _officeVersion++;
        }
      });
    } on ApiException catch (e) {
      if (!mounted || id != _reqId) return;
      setState(() {
        _classifying = false;
        _classifyError = e.message;
      });
    } catch (_) {
      if (!mounted || id != _reqId) return;
      setState(() {
        _classifying = false;
        _classifyError = 'Classification failed.';
      });
    }
  }

  void _onCategoryChanged(int? v) {
    if (v == null) return;
    _debounce?.cancel();
    setState(() {
      _categoryId = v;
      _categoryManuallySet = true;
      if (!_officeTouched) {
        _officeId = categoryById(v).officeId;
        _officeVersion++;
      }
    });
    _classify();
  }

  void _onDescChanged(String text) {
    setState(() {}); // refresh the character counter
    _autoDetectFromDescription(text);
  }

  Future<void> _submit() async {
    setState(() => _submitError = null);
    final valid = _form.currentState!.validate();
    if (!_agreed) setState(() => _termsError = true);
    if (!valid || !_agreed) return;

    final api = context.read<ApiService>();
    setState(() => _sending = true);
    try {
      final c = await api.submitComplaint(
        title: _title.text.trim(),
        description: _desc.text.trim(),
        categoryId: _categoryId!,
        officeId: _officeId!,
        locationId: _locationId!,
        attachment: _attachment,
      );
      if (!mounted) return;
      setState(() => _sending = false);
      await _showSuccess(c);
      if (mounted) context.go(UserRole.citizen.home);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _sending = false;
        _submitError = e.displayMessage;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _sending = false;
        _submitError = 'Submission failed. Your details are still here, please try again.';
      });
    }
  }

  Future<void> _showSuccess(Complaint c) {
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(children: [
          const Icon(Icons.check_circle_rounded, color: AppColors.forest, size: 28),
          const SizedBox(width: 10),
          Expanded(child: Text('Complaint #${c.id} submitted', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 18))),
        ]),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          _kv('Priority', PriorityChip(c.priority)),
          _kv('Sent to', Text(officeById(c.officeId).name, textAlign: TextAlign.right, style: const TextStyle(fontWeight: FontWeight.w700))),
          _kv('Status', StatusChip(c.status)),
          if (c.priority == Priority.critical) ...[
            const SizedBox(height: 8),
            const Text('This looks like an emergency. Please also call 911.',
                style: TextStyle(color: AppColors.star, fontWeight: FontWeight.w700)),
          ],
        ]),
        actions: [
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Padding(padding: EdgeInsets.symmetric(horizontal: 12), child: Text('Back to dashboard')),
          ),
        ],
      ),
    );
  }

  Widget _kv(String k, Widget v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: SizedBox(
          width: 300,
          child: Row(children: [
            Expanded(child: Text(k, style: const TextStyle(color: AppColors.muted))),
            Flexible(child: v),
          ]),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return AppShell(
      title: 'Submit Complaint',
      activeLabel: 'Submit Complaint',
      child: LayoutBuilder(builder: (context, box) {
        final wide = box.maxWidth >= 980;
        final card = ClassificationCard(
          hasCategory: _categoryId != null,
          loading: _classifying,
          result: _result,
          error: _classifyError,
        );
        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
          child: wide
              ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(flex: 6, child: _formCard(inlineCard: null)),
                  const SizedBox(width: 20),
                  Expanded(flex: 4, child: card),
                ])
              : _formCard(inlineCard: card),
        );
      }),
    );
  }

  Widget _formCard({required Widget? inlineCard}) {
    const space = SizedBox(height: 16);
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.line),
      ),
      child: Form(
        key: _form,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Text('File a complaint', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          const Text('Fire, injury, or danger to life? Call 911 first, then file here.',
              style: TextStyle(color: AppColors.muted)),
          const SizedBox(height: 22),

          // ── Description FIRST — NLP reads this to auto-detect category ──
          TextFormField(
            controller: _desc,
            minLines: 5,
            maxLines: 8,
            maxLength: 1000,
            onChanged: _onDescChanged,
            decoration: const InputDecoration(
              labelText: 'What happened? *',
              alignLabelWithHint: true,
              helperText: 'Describe the problem. The system will automatically detect the category, priority, and office.',
              helperMaxLines: 2,
            ),
            validator: (v) => (v ?? '').trim().length < 20
                ? 'Complaint description must contain at least 20 characters.'
                : null,
          ),

          // ── NLP auto-detection hint ────────────────────────────────────
          if (_categoryId != null && !_categoryManuallySet) ...[
            Builder(builder: (context) {
              final isMulti = _result != null && _result!.coOfficeIds.isNotEmpty;
              final officeDisplay = isMulti && _result!.officeNames.isNotEmpty
                  ? _result!.officeNames.join(' & ')
                  : (_officeId != null ? officeById(_officeId!).name : 'Suggested office');
              return Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: isMulti ? const Color(0xFFE0F2FE) : const Color(0xFFE8F5E9),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: isMulti
                        ? const Color(0xFF0284C7).withValues(alpha: 0.35)
                        : AppColors.forest.withValues(alpha: 0.35),
                  ),
                ),
                child: Row(children: [
                  Icon(
                    isMulti ? Icons.hub_rounded : Icons.auto_awesome_rounded,
                    size: 18,
                    color: isMulti ? const Color(0xFF0284C7) : AppColors.forest,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: RichText(
                      text: TextSpan(
                        style: TextStyle(
                          fontSize: 13,
                          color: isMulti ? const Color(0xFF0369A1) : AppColors.forest,
                          height: 1.35,
                        ),
                        children: [
                          TextSpan(
                            text: isMulti ? 'NLP Multi-Office Dispatch: ' : 'NLP Auto-Triage: ',
                            style: const TextStyle(fontWeight: FontWeight.w800),
                          ),
                          TextSpan(
                            text: categoryById(_categoryId!).name,
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                          TextSpan(text: isMulti ? ' → Joint Action: ' : ' → Routed to: '),
                          TextSpan(
                            text: officeDisplay,
                            style: const TextStyle(fontWeight: FontWeight.w800),
                          ),
                          if (isMulti)
                            const TextSpan(
                              text: ' (Both offices will receive & handle this)',
                              style: TextStyle(fontStyle: FontStyle.italic, fontSize: 12),
                            ),
                        ],
                      ),
                    ),
                  ),
                ]),
              );
            }),
            const SizedBox(height: 10),
          ],

          if (inlineCard != null) ...[space, inlineCard],
          space,

          // ── Category dropdown — auto-filled by NLP, user can override ──
          DropdownButtonFormField<int>(
            key: ValueKey('cat-$_categoryVersion'),
            initialValue: _categoryId,
            isExpanded: true,
            decoration: InputDecoration(
              labelText: 'Category *',
              helperText: _categoryManuallySet
                  ? 'You chose this category.'
                  : 'Auto-detected from your description. Change it if needed.',
              helperMaxLines: 2,
            ),
            items: kCategories
                .map((c) => DropdownMenuItem(
                      value: c.id,
                      child: Row(children: [
                        Icon(c.icon, size: 18, color: AppColors.navy),
                        const SizedBox(width: 10),
                        Flexible(child: Text(c.name, overflow: TextOverflow.ellipsis)),
                      ]),
                    ))
                .toList(),
            onChanged: _onCategoryChanged,
            validator: (v) => v == null ? 'Describe your complaint above so the system can detect the category, or select one.' : null,
          ),
          space,
          TextFormField(
            controller: _title,
            maxLength: 100,
            textInputAction: TextInputAction.next,
            decoration: const InputDecoration(labelText: 'Complaint title *'),
            validator: (v) {
              final n = (v ?? '').trim().length;
              return n < 5 || n > 100 ? 'Please enter a complaint title between 5 and 100 characters.' : null;
            },
          ),
          space,
          FormField<int>(
            initialValue: _locationId,
            validator: (v) => (_locationId == null) ? 'Select where this happened.' : null,
            builder: (state) {
              final selected = _locationId == null
                  ? null
                  : kBarangays.firstWhere((b) => b.id == _locationId, orElse: () => kBarangays.first);
              return InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () async {
                  final picked = await _pickBarangayDialog(context, _locationId);
                  if (picked != null) {
                    setState(() => _locationId = picked);
                    state.didChange(picked);
                  }
                },
                child: InputDecorator(
                  decoration: InputDecoration(
                    labelText: 'Barangay / location *',
                    errorText: state.errorText,
                    suffixIcon: const Icon(Icons.search_rounded),
                  ),
                  child: Text(
                    selected?.name ?? 'Tap to search & select barangay (31 barangays)',
                    style: TextStyle(
                      color: selected == null ? AppColors.muted : null,
                    ),
                  ),
                ),
              );
            },
          ),
          space,
          DropdownButtonFormField<int>(
            key: ValueKey('office-$_officeVersion'),
            initialValue: _officeId,
            isExpanded: true,
            decoration: InputDecoration(
              labelText: 'Send to office *',
              helperText: _officeTouched
                  ? 'You chose this office.'
                  : 'Auto-suggested from your complaint. Change it if another office should handle this.',
              helperMaxLines: 2,
            ),
            items: kOffices
                .map((o) => DropdownMenuItem(value: o.id, child: Text(o.name, overflow: TextOverflow.ellipsis)))
                .toList(),
            onChanged: (v) => setState(() {
              _officeId = v;
              _officeTouched = true;
            }),
            validator: (v) => v == null ? 'Select the office that should receive this.' : null,
          ),
          space,
          Row(children: [
            const Icon(Icons.add_a_photo_outlined, size: 18, color: AppColors.navy),
            const SizedBox(width: 8),
            const Text('Verification Photo / Proof',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13.5)),
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(color: AppColors.panel, borderRadius: BorderRadius.circular(6)),
              child: const Text('Optional',
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppColors.muted)),
            ),
          ]),
          const SizedBox(height: 4),
          const Text(
            'Upload a clear photo or document of the issue. City staff and administrators can view this image to verify and respond to your complaint faster.',
            style: TextStyle(color: AppColors.muted, fontSize: 12, height: 1.35),
          ),
          const SizedBox(height: 10),
          if (_attachment == null)
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: _pickFile,
                icon: const Icon(Icons.upload_file_rounded, size: 18),
                label: const Text('Upload Photo (JPG, PNG) or PDF (max 5MB)'),
              ),
            )
          else ...[
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.panel,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: AppColors.line),
              ),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  const Icon(Icons.check_circle_rounded, color: AppColors.forest, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(_attachment!.name,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
                      Text(_size(_attachment!.size),
                          style: const TextStyle(color: AppColors.muted, fontSize: 11.5)),
                    ]),
                  ),
                  TextButton.icon(
                    onPressed: _pickFile,
                    icon: const Icon(Icons.change_circle_outlined, size: 16),
                    label: const Text('Change', style: TextStyle(fontSize: 12)),
                  ),
                  IconButton(
                    tooltip: 'Remove photo',
                    icon: const Icon(Icons.close_rounded, color: AppColors.star),
                    onPressed: () => setState(() => _attachment = null),
                  ),
                ]),
                if (_attachment!.name.toLowerCase().endsWith('.jpg') ||
                    _attachment!.name.toLowerCase().endsWith('.jpeg') ||
                    _attachment!.name.toLowerCase().endsWith('.png') ||
                    _attachment!.name.toLowerCase().endsWith('.webp')) ...[
                  const SizedBox(height: 10),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: Container(
                      width: double.infinity,
                      constraints: const BoxConstraints(maxHeight: 180),
                      color: Colors.black12,
                      child: Image.memory(
                        _attachment!.bytes,
                        fit: BoxFit.contain,
                        alignment: Alignment.centerLeft,
                      ),
                    ),
                  ),
                ],
              ]),
            ),
          ],
          if (_attachmentError != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(_attachmentError!, style: const TextStyle(color: AppColors.star, fontSize: 12.5)),
            ),
          const SizedBox(height: 18),

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
                  const TextSpan(text: 'I confirm these details are true and I agree to the '),
                  TextSpan(
                    text: 'Terms of Use and Data Privacy Notice',
                    recognizer: _termsTap,
                    style: const TextStyle(color: AppColors.navy, fontWeight: FontWeight.w700, decoration: TextDecoration.underline),
                  ),
                  const TextSpan(text: ', including automatic NLP classification of my complaint.'),
                ])),
              ),
            ),
          ]),
          if (_termsError)
            const Padding(
              padding: EdgeInsets.only(left: 12, bottom: 4),
              child: Text('You need to agree before submitting.', style: TextStyle(color: AppColors.star, fontSize: 12.5)),
            ),
          if (_submitError != null) ...[
            const SizedBox(height: 12),
            MessageBanner(message: _submitError!),
          ],
          const SizedBox(height: 16),
          ElevatedButton(
            onPressed: _sending ? null : _submit,
            child: _sending
                ? const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                    SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white)),
                    SizedBox(width: 12),
                    Text('Submitting…'),
                  ])
                : const Text('Submit complaint'),
          ),
        ]),
      ),
    );
  }
}

Future<int?> _pickBarangayDialog(BuildContext context, int? currentId) {
  return showDialog<int>(
    context: context,
    builder: (ctx) {
      String query = '';
      return StatefulBuilder(
        builder: (ctx, setS) {
          final filtered = kBarangays
              .where((b) => query.trim().isEmpty || b.name.toLowerCase().contains(query.trim().toLowerCase()))
              .toList();
          return AlertDialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            title: const Text('Select Barangay', style: TextStyle(fontWeight: FontWeight.w800)),
            content: SizedBox(
              width: 400,
              height: 400,
              child: Column(
                children: [
                  TextField(
                    autofocus: true,
                    decoration: const InputDecoration(
                      hintText: 'Search Cabadbaran barangay...',
                      prefixIcon: Icon(Icons.search_rounded),
                      isDense: true,
                    ),
                    onChanged: (v) => setS(() => query = v),
                  ),
                  const SizedBox(height: 10),
                  Expanded(
                    child: filtered.isEmpty
                        ? const Center(child: Text('No matching barangay.', style: TextStyle(color: AppColors.muted)))
                        : ListView.builder(
                            itemCount: filtered.length,
                            itemBuilder: (_, i) {
                              final b = filtered[i];
                              final selected = b.id == currentId;
                              return ListTile(
                                dense: true,
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                selected: selected,
                                leading: Icon(
                                  selected ? Icons.check_circle_rounded : Icons.location_on_outlined,
                                  color: selected ? AppColors.navy : AppColors.muted,
                                  size: 20,
                                ),
                                title: Text(b.name, style: TextStyle(fontWeight: selected ? FontWeight.w800 : FontWeight.w600)),
                                onTap: () => Navigator.pop(ctx, b.id),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            ],
          );
        },
      );
    },
  );
}
