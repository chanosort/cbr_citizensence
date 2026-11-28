import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/constants.dart';
import '../core/format.dart';
import '../models/models.dart';
import 'mock_classifier.dart';

/// Mirrors the structured error from Activity 7:
/// { "error": { "code", "message", "details" } }
class ApiException implements Exception {
  final int status;
  final String code;
  final String message;
  final Map<String, dynamic> details;
  const ApiException(this.status, this.code, this.message,
      {this.details = const <String, dynamic>{}});

  String get displayMessage => details.isEmpty
      ? message
      : '$message\n${details.values.map((v) => '• $v').join('\n')}';
}

class SecurityQuestionChoice {
  final int id;
  final String question;
  const SecurityQuestionChoice({required this.id, required this.question});
}

abstract class ApiService {
  void setToken(String? token);

  Future<AuthSession> login({required String email, required String password});

  /// Self-registration always creates a 'citizen'. An OTP is sent to the email.
  Future<void> register({
    required String name,
    required String username,
    required String email,
    required String password,
    required List<Map<String, String>> securityQuestions,
  });

  /// Verify the email OTP sent after registration.
  Future<void> verifyEmail({required String email, required String code});

  /// Resend verification OTP.
  Future<void> resendVerification({required String email});

  /// Fetch the user's 3 registered security questions for account recovery.
  Future<({String email, List<SecurityQuestionChoice> questions})> getForgotPasswordQuestions({
    required String email,
  });

  /// Verify the chosen security question (answered twice) and send recovery OTP.
  Future<String?> forgotPassword({
    required String email,
    required int questionId,
    required String answer,
    required String confirmAnswer,
  });

  /// Verify reset OTP before allowing user to type a new password.
  Future<void> verifyResetCode({required String email, required String code});

  /// Verify reset OTP and set a new password.
  Future<void> resetPassword({
    required String email,
    required String code,
    required String newPassword,
  });

  Future<void> changePassword({required String current, required String next});

  Future<Classification> classify({int? categoryId, required String description});
  Future<Complaint> submitComplaint({
    required String title,
    required String description,
    required int categoryId,
    required int officeId,
    required int locationId,
    PickedAttachment? attachment,
  });

  /// citizen: own (EP-04), staff: office (EP-06), admin: all.
  Future<List<Complaint>> listComplaints(UserRole role);
  Future<ComplaintDetail> getComplaint(int id); // EP-05
  Future<void> updateStatus({required int id, required ComplaintStatus status, String? message}); // EP-07

  Future<DashboardData> dashboard();
  Future<ReportData> report(ReportFilter filter); // EP-08
  Future<List<UserRecord>> adminUsers();
  Future<void> setUserActive(int id, bool active);
  Future<void> createStaffUser({
    required String name,
    required String email,
    required String password,
    required int officeId,
    String? username,
  });
  Future<void> updateStaffUser({
    required int id,
    String? name,
    int? officeId,
    bool? active,
    String? password,
  });
  Future<void> deleteStaffUser(int id);
  Future<List<AnnouncementItem>> publicAnnouncements();
  Future<List<AnnouncementItem>> announcements();
  Future<AnnouncementItem> createAnnouncement({
    required String title,
    required String content,
    String category = 'Announcement',
  });
  Future<AnnouncementItem> updateAnnouncement({
    required int id,
    String? title,
    String? content,
    String? category,
    String? status,
    bool? isActive,
  });
  Future<void> deleteAnnouncement(int id);
  Future<List<OfficeSummary>> adminOffices();
  Future<List<AppNotice>> notifications();
  Future<void> markNotificationsRead();
  Future<List<int>> downloadReportCsvBytes({int days = 30, String? month, int? officeId, int? categoryId});
  Future<List<int>> downloadMyComplaintsCsvBytes();
  Future<ComplaintMessage> postComplaintMessage({required int complaintId, required String message});
  Future<void> submitComplaintFeedback({required int complaintId, required int rating, String? comment});
  Future<AppUser> updateProfile({required String name});
  Future<AppUser> uploadAvatar(List<int> bytes, String fileName);
  Future<void> requestEmailChange({required String currentPassword, required String newEmail});
  Future<AppUser> confirmEmailChange({required String newEmail, required String code});
  Future<List<ActivityLogItem>> adminActivityLogs({String? role});
  String getAvatarUrl(String? avatarUrl);
  String getAttachmentUrl(int complaintId);
  Map<String, String> get authHeaders;
}

// ---------------------------------------------------------------------------
// Real implementation: talks to the Flask REST API (Activity 7 contract).
// List endpoints return { "data": { "items": [ ... ] } }.
// ---------------------------------------------------------------------------
class HttpApiService implements ApiService {
  HttpApiService(this.baseUrl);
  final String baseUrl;
  String? _token;

  /// Called when an authenticated request gets 401 (expired token).
  void Function()? onUnauthorized;

  @override
  void setToken(String? token) => _token = token;

  @override
  Map<String, String> get authHeaders => Map<String, String>.unmodifiable(_auth);

  @override
  String getAttachmentUrl(int complaintId) => _token != null
      ? '$baseUrl/api/complaints/$complaintId/attachment?token=$_token'
      : '$baseUrl/api/complaints/$complaintId/attachment';

  Map<String, String> get _auth => {if (_token != null) 'Authorization': 'Bearer $_token'};
  Map<String, String> get _headers => {'Content-Type': 'application/json', ..._auth};

  Uri _u(String path, [Map<String, String>? q]) =>
      Uri.parse('$baseUrl$path').replace(queryParameters: q);

  Future<Map<String, dynamic>> _send(Future<http.Response> Function() call) async {
    http.Response r;
    try {
      r = await call().timeout(const Duration(seconds: 60));
    } on TimeoutException {
      throw const ApiException(
          0, 'TIMEOUT', 'The server took too long to respond. Please try again.');
    } on http.ClientException {
      throw const ApiException(
          0, 'NETWORK_ERROR', 'Cannot reach the server. Check your connection.');
    }

    var body = <String, dynamic>{};
    if (r.body.isNotEmpty) {
      try {
        final d = jsonDecode(r.body);
        if (d is Map<String, dynamic>) body = d;
      } catch (_) {}
    }

    if (r.statusCode >= 200 && r.statusCode < 300) {
      final data = body['data'];
      return data is Map<String, dynamic> ? data : body;
    }

    if (r.statusCode == 401 && _token != null) onUnauthorized?.call();

    final e = body['error'] is Map
        ? Map<String, dynamic>.from(body['error'] as Map)
        : <String, dynamic>{};
    throw ApiException(
      r.statusCode,
      (e['code'] as String?) ?? 'SERVER_ERROR',
      (e['message'] as String?) ?? 'Something went wrong. Please try again.',
      details: e['details'] is Map
          ? Map<String, dynamic>.from(e['details'] as Map)
          : const <String, dynamic>{},
    );
  }

  Future<Map<String, dynamic>> _get(String path, [Map<String, String>? q]) =>
      _send(() => http.get(_u(path, q), headers: _headers));
  Future<Map<String, dynamic>> _post(String path, Map<String, dynamic> body) =>
      _send(() => http.post(_u(path), headers: _headers, body: jsonEncode(body)));
  Future<Map<String, dynamic>> _patch(String path, Map<String, dynamic> body) =>
      _send(() => http.patch(_u(path), headers: _headers, body: jsonEncode(body)));
  Future<Map<String, dynamic>> _delete(String path) =>
      _send(() => http.delete(_u(path), headers: _headers));

  List<Map<String, dynamic>> _items(Map<String, dynamic> d) =>
      ((d['items'] as List?) ?? const []).map((e) => (e as Map).cast<String, dynamic>()).toList();

  @override
  Future<AuthSession> login({required String email, required String password}) async {
    final d = await _post('/api/auth/login', {'account': email, 'email': email, 'password': password});
    return AuthSession(
      AppUser.fromJson((d['user'] as Map).cast<String, dynamic>()),
      d['token'] as String,
    );
  }

  @override
  Future<void> register({
    required String name,
    required String username,
    required String email,
    required String password,
    required List<Map<String, String>> securityQuestions,
  }) async {
    await _post('/api/auth/register', {
      'name': name,
      'username': username,
      'email': email,
      'password': password,
      'security_questions': securityQuestions,
    });
  }

  @override
  Future<void> verifyEmail({required String email, required String code}) async {
    await _post('/api/auth/verify-email', {'email': email, 'code': code});
  }

  @override
  Future<void> resendVerification({required String email}) async {
    await _post('/api/auth/resend-verification', {'email': email});
  }

  @override
  Future<({String email, List<SecurityQuestionChoice> questions})> getForgotPasswordQuestions({
    required String email,
  }) async {
    final res = await _post('/api/auth/forgot-password/questions', {'account': email, 'email': email});
    final qs = ((res['questions'] as List?) ?? const [])
        .map((e) => SecurityQuestionChoice(
              id: ((e as Map)['id'] as num).toInt(),
              question: (e['question'] as String?) ?? '',
            ))
        .toList();
    return (email: (res['email'] as String?) ?? '', questions: qs);
  }

  @override
  Future<String?> forgotPassword({
    required String email,
    required int questionId,
    required String answer,
    required String confirmAnswer,
  }) async {
    final res = await _post('/api/auth/forgot-password', {
      'account': email,
      'email': email,
      'question_id': questionId,
      'answer': answer,
      'confirm_answer': confirmAnswer,
    });
    return res['email'] as String?;
  }

  @override
  Future<void> verifyResetCode({required String email, required String code}) async {
    await _post('/api/auth/verify-reset-code', {
      'account': email,
      'email': email,
      'code': code,
    });
  }

  @override
  Future<void> resetPassword({
    required String email,
    required String code,
    required String newPassword,
  }) async {
    await _post('/api/auth/reset-password', {
      'account': email,
      'email': email,
      'code': code,
      'new_password': newPassword,
    });
  }

  /// NEW: POST /api/auth/change-password
  @override
  Future<void> changePassword({required String current, required String next}) async {
    await _post('/api/auth/change-password', {'current_password': current, 'new_password': next});
  }

  /// NEW: POST /api/complaints/classify (live priority preview)
  @override
  Future<Classification> classify(
      {int? categoryId, required String description}) async {
    final d = await _post('/api/complaints/classify',
        {'category_id': categoryId, 'description': description});
    return Classification.fromJson(d);
  }

  /// EP-03. Owner comes from the JWT, never from the body.
  /// With an attachment the request is multipart/form-data.
  @override
  Future<Complaint> submitComplaint({
    required String title,
    required String description,
    required int categoryId,
    required int officeId,
    required int locationId,
    PickedAttachment? attachment,
  }) async {
    final Map<String, dynamic> d;
    if (attachment == null) {
      d = await _post('/api/complaints', {
        'title': title,
        'description': description,
        'category_id': categoryId,
        'office_id': officeId,
        'location_id': locationId,
      });
    } else {
      final req = http.MultipartRequest('POST', _u('/api/complaints'))
        ..headers.addAll(_auth)
        ..fields.addAll({
          'title': title,
          'description': description,
          'category_id': '$categoryId',
          'office_id': '$officeId',
          'location_id': '$locationId',
        })
        ..files.add(http.MultipartFile.fromBytes('attachment', attachment.bytes,
            filename: attachment.name));
      d = await _send(() async => http.Response.fromStream(await req.send()));
    }
    return Complaint(
      id: (d['id'] as num).toInt(),
      title: title,
      description: description,
      categoryId: categoryId,
      officeId: officeId,
      locationId: locationId,
      status: statusFrom(d['status'] as String?),
      priority: priorityFrom(d['priority'] as String?),
      sentiment: (d['sentiment'] as String?) ?? 'neutral',
      createdAt: DateTime.now(),
      attachmentName: d['attachment_name'] as String? ?? attachment?.name,
      attachmentUrl: d['attachment_url'] as String?,
    );
  }

  @override
  Future<List<Complaint>> listComplaints(UserRole role) async {
    final path = switch (role) {
      UserRole.citizen => '/api/complaints',
      UserRole.staff => '/api/staff/complaints',
      UserRole.admin => '/api/admin/complaints', // NEW
    };
    return _items(await _get(path)).map(Complaint.fromJson).toList();
  }

  @override
  Future<ComplaintDetail> getComplaint(int id) async =>
      ComplaintDetail.fromJson(await _get('/api/complaints/$id'));

  @override
  Future<void> updateStatus(
      {required int id, required ComplaintStatus status, String? message}) async {
    await _patch('/api/complaints/$id/status', {
      'status': status.apiName,
      if (message != null && message.trim().isNotEmpty) 'response_message': message.trim(),
    });
  }

  /// NEW: GET /api/dashboard/summary
  @override
  Future<DashboardData> dashboard() async =>
      DashboardData.fromJson(await _get('/api/dashboard/summary'));

  @override
  Future<ReportData> report(ReportFilter f) async => ReportData.fromJson(await _get('/api/reports', {
        'days': '${f.days}',
        if (f.officeId != null) 'office_id': '${f.officeId}',
        if (f.categoryId != null) 'category_id': '${f.categoryId}',
      }));

  /// NEW: GET /api/admin/users
  @override
  Future<List<UserRecord>> adminUsers() async =>
      _items(await _get('/api/admin/users')).map(UserRecord.fromJson).toList();

  /// NEW: PATCH /api/admin/users/{id}
  @override
  Future<void> setUserActive(int id, bool active) async {
    await _patch('/api/admin/users/$id', {'active': active});
  }

  @override
  Future<void> createStaffUser({
    required String name,
    required String email,
    required String password,
    required int officeId,
    String? username,
  }) async {
    await _post('/api/admin/users', {
      'name': name,
      'email': email,
      'password': password,
      'role': 'staff',
      'office_id': officeId,
      if (username != null && username.isNotEmpty) 'username': username,
    });
  }

  @override
  Future<void> updateStaffUser({
    required int id,
    String? name,
    int? officeId,
    bool? active,
    String? password,
  }) async {
    final body = <String, dynamic>{};
    if (name != null) body['name'] = name;
    if (officeId != null) body['office_id'] = officeId;
    if (active != null) body['active'] = active;
    if (password != null && password.isNotEmpty) body['password'] = password;
    await _patch('/api/admin/users/$id', body);
  }

  @override
  Future<void> deleteStaffUser(int id) async {
    await _delete('/api/admin/users/$id');
  }

  @override
  Future<List<AnnouncementItem>> publicAnnouncements() async =>
      _items(await _get('/api/announcements/public')).map(AnnouncementItem.fromJson).toList();

  @override
  Future<List<AnnouncementItem>> announcements() async =>
      _items(await _get('/api/announcements')).map(AnnouncementItem.fromJson).toList();

  @override
  Future<AnnouncementItem> createAnnouncement({
    required String title,
    required String content,
    String category = 'Announcement',
  }) async {
    final d = await _post('/api/announcements', {
      'title': title,
      'content': content,
      'category': category,
    });
    return AnnouncementItem.fromJson((d['item'] as Map).cast<String, dynamic>());
  }

  @override
  Future<AnnouncementItem> updateAnnouncement({
    required int id,
    String? title,
    String? content,
    String? category,
    String? status,
    bool? isActive,
  }) async {
    final body = <String, dynamic>{};
    if (title != null) body['title'] = title;
    if (content != null) body['content'] = content;
    if (category != null) body['category'] = category;
    if (status != null) body['status'] = status;
    if (isActive != null) body['is_active'] = isActive;
    final d = await _patch('/api/announcements/$id', body);
    return AnnouncementItem.fromJson((d['item'] as Map).cast<String, dynamic>());
  }

  @override
  Future<void> deleteAnnouncement(int id) async {
    await _delete('/api/announcements/$id');
  }

  /// NEW: GET /api/admin/offices
  @override
  Future<List<OfficeSummary>> adminOffices() async =>
      _items(await _get('/api/admin/offices')).map(OfficeSummary.fromJson).toList();

  /// NEW: GET /api/notifications
  @override
  Future<List<AppNotice>> notifications() async =>
      _items(await _get('/api/notifications')).map(AppNotice.fromJson).toList();

  /// NEW: PATCH /api/notifications/read
  @override
  Future<void> markNotificationsRead() async {
    await _patch('/api/notifications/read', {});
  }

  /// NEW: GET /api/reports/export-csv
  @override
  Future<List<int>> downloadReportCsvBytes({int days = 30, String? month, int? officeId, int? categoryId}) async {
    final q = <String, String>{'days': '$days'};
    if (month != null && month.isNotEmpty) q['month'] = month;
    if (officeId != null) q['office_id'] = '$officeId';
    if (categoryId != null) q['category_id'] = '$categoryId';
    final uri = _u('/api/reports/export-csv', q);
    final res = await http.get(uri, headers: _headers);
    if (res.statusCode >= 200 && res.statusCode < 300) {
      return res.bodyBytes;
    }
    throw ApiException(res.statusCode, 'EXPORT_FAILED', 'Failed to export report CSV.');
  }

  @override
  Future<List<int>> downloadMyComplaintsCsvBytes() async {
    final uri = _u('/api/complaints/export-csv');
    final res = await http.get(uri, headers: _headers);
    if (res.statusCode >= 200 && res.statusCode < 300) {
      return res.bodyBytes;
    }
    throw ApiException(res.statusCode, 'EXPORT_FAILED', 'Failed to export your complaints CSV.');
  }

  @override
  Future<ComplaintMessage> postComplaintMessage({required int complaintId, required String message}) async {
    final d = await _post('/api/complaints/$complaintId/messages', {'message': message});
    return ComplaintMessage.fromJson(d);
  }

  @override
  Future<void> submitComplaintFeedback({required int complaintId, required int rating, String? comment}) async {
    await _post('/api/complaints/$complaintId/feedback', {
      'rating': rating,
      if (comment != null && comment.trim().isNotEmpty) 'comment': comment.trim(),
    });
  }

  @override
  Future<AppUser> updateProfile({required String name}) async {
    final d = await _patch('/api/auth/profile', {'name': name});
    return AppUser.fromJson((d['user'] as Map).cast<String, dynamic>());
  }

  @override
  Future<AppUser> uploadAvatar(List<int> bytes, String fileName) async {
    final req = http.MultipartRequest('POST', _u('/api/auth/avatar'));
    if (_token != null) req.headers['Authorization'] = 'Bearer $_token';
    req.files.add(http.MultipartFile.fromBytes('avatar', bytes, filename: fileName));
    final streamed = await req.send().timeout(const Duration(seconds: 60));
    final r = await http.Response.fromStream(streamed);
    final d = await _send(() async => r);
    return AppUser.fromJson((d['user'] as Map).cast<String, dynamic>());
  }

  @override
  Future<void> requestEmailChange({required String currentPassword, required String newEmail}) async {
    await _post('/api/auth/email-change/request', {
      'current_password': currentPassword,
      'new_email': newEmail,
    });
  }

  @override
  Future<AppUser> confirmEmailChange({required String newEmail, required String code}) async {
    final d = await _post('/api/auth/email-change/confirm', {
      'new_email': newEmail,
      'code': code,
    });
    return AppUser.fromJson((d['user'] as Map).cast<String, dynamic>());
  }

  @override
  Future<List<ActivityLogItem>> adminActivityLogs({String? role}) async {
    final q = <String, String>{};
    if (role != null && role.isNotEmpty) q['role'] = role;
    return _items(await _get('/api/admin/activity-logs', q.isEmpty ? null : q))
        .map(ActivityLogItem.fromJson)
        .toList();
  }

  @override
  String getAvatarUrl(String? avatarUrl) {
    if (avatarUrl == null || avatarUrl.isEmpty) return '';
    if (avatarUrl.startsWith('http')) return avatarUrl;
    return '$baseUrl$avatarUrl';
  }
}

// ---------------------------------------------------------------------------
// Mock implementation: lets the whole UI run before the Flask API exists.
// Demo accounts (password123): citizen@gmail.com, staff@staff.com (Engineering),
// health@staff.com (Health), admin@admin.com
// ---------------------------------------------------------------------------
class _MockUser {
  final int id;
  final String name;
  final String username;
  final String email;
  String password;
  final UserRole role;
  final int? officeId;
  bool active;
  _MockUser(this.id, this.name, this.username, this.email, this.password, this.role, this.officeId) : active = true;
}

class MockApiService implements ApiService {
  final List<_MockUser> _users = [
    // ── 2 Administrators (Control All) ──────────────────────────
    _MockUser(101, 'Admin One (Lead)', 'admin1', 'admin1@admin.com', 'password123', UserRole.admin, null),
    _MockUser(102, 'Admin Two (City Admin)', 'admin2', 'admin2@admin.com', 'password123', UserRole.admin, null),
    _MockUser(3, 'Admin CitizenSense', 'admin', 'admin@admin.com', 'password123', UserRole.admin, null),

    // ── Office 1: City Engineering Office (2 Staff) ─────────────
    _MockUser(11, 'Engr. Carlos Mendoza', 'eng1', 'eng1@staff.com', 'password123', UserRole.staff, 1),
    _MockUser(12, 'Engr. Sarah Dizon', 'eng2', 'eng2@staff.com', 'password123', UserRole.staff, 1),

    // ── Office 2: City Health Office (2 Staff) ──────────────────
    _MockUser(21, 'Dr. Pedro Reyes', 'health1', 'health1@staff.com', 'password123', UserRole.staff, 2),
    _MockUser(22, 'Nurse Joy Bautista', 'health2', 'health2@staff.com', 'password123', UserRole.staff, 2),

    // ── Office 3: City Environment & Natural Resources (2 Staff) ─
    _MockUser(31, 'CENRO Officer Mark Tan', 'cenro1', 'cenro1@staff.com', 'password123', UserRole.staff, 3),
    _MockUser(32, 'CENRO Inspector Leah Cruz', 'cenro2', 'cenro2@staff.com', 'password123', UserRole.staff, 3),

    // ── Office 4: City Social Welfare & Development (2 Staff) ───
    _MockUser(41, 'CSWDO Worker Grace Aquino', 'cswdo1', 'cswdo1@staff.com', 'password123', UserRole.staff, 4),
    _MockUser(42, 'CSWDO Worker Noel Flores', 'cswdo2', 'cswdo2@staff.com', 'password123', UserRole.staff, 4),

    // ── Office 5: City Disaster Risk Reduction (2 Staff) ────────
    _MockUser(51, 'CDRRMO Officer Roberto Lim', 'drrmo1', 'drrmo1@staff.com', 'password123', UserRole.staff, 5),
    _MockUser(52, 'CDRRMO Dispatcher Karen V.', 'drrmo2', 'drrmo2@staff.com', 'password123', UserRole.staff, 5),

    // ── Office 6: City Public Safety Office (2 Staff) ────────────
    _MockUser(61, 'PSO Officer Dennis Castro', 'safety1', 'safety1@staff.com', 'password123', UserRole.staff, 6),
    _MockUser(62, 'PSO Marshall Liza Ramos', 'safety2', 'safety2@staff.com', 'password123', UserRole.staff, 6),

    // ── Office 7: City Mayor\'s Office (2 Staff) ─────────────────
    _MockUser(71, 'Mayors Aide Antonio Luna', 'mayor1', 'mayor1@staff.com', 'password123', UserRole.staff, 7),
    _MockUser(72, 'Mayors Officer Beatriz Gomez', 'mayor2', 'mayor2@staff.com', 'password123', UserRole.staff, 7),

    // ── Citizens ─────────────────────────────────────────────────
    _MockUser(1, 'Juan Dela Cruz', 'juan', 'citizen@gmail.com', 'password123', UserRole.citizen, null),
    _MockUser(5, 'Ana Lopez', 'ana', 'ana@gmail.com', 'password123', UserRole.citizen, null),
  ];
  /// Emails that have registered but not yet verified (mock).
  final Set<String> _pendingVerification = {};
  /// email -> reset code (mock — fixed code '654321' is issued by forgotPassword).
  final Map<String, String> _resetCodes = {};
  late final List<Complaint> _complaints = _seed();
  final Map<int, List<ResponseEntry>> _responses = {};
  final Map<int, List<HistoryEntry>> _history = {};
  int _nextId = 125;
  int _nextUserId = 10;
  AppUser? _me;

  MockApiService() {
    for (final c in _complaints) {
      _initTrail(c);
    }
  }

  Future<void> _lag([int ms = 500]) => Future.delayed(Duration(milliseconds: ms));

  AppUser _need() {
    final me = _me;
    if (me == null) throw const ApiException(401, 'UNAUTHORIZED', 'Please log in again.');
    return me;
  }

  Complaint? _find(int id) {
    for (final c in _complaints) {
      if (c.id == id) return c;
    }
    return null;
  }

  void _initTrail(Complaint c) {
    const chain = [
      ComplaintStatus.submitted, ComplaintStatus.received, ComplaintStatus.inProgress,
      ComplaintStatus.resolved, ComplaintStatus.closed,
    ];
    final now = DateTime.now();
    final idx = chain.indexOf(c.status);
    final hist = <HistoryEntry>[];
    for (var i = 0; i <= idx; i++) {
      var at = c.createdAt.add(Duration(hours: i * 6));
      if (at.isAfter(now)) at = now;
      hist.add(HistoryEntry(
        chain[i],
        i == 0 ? 'Complaint submitted.' : 'Status changed to ${chain[i].label}.',
        i == 0 ? (c.citizenName.isEmpty ? 'Citizen' : c.citizenName) : 'Maria Santos',
        at,
      ));
    }
    _history[c.id] = hist;
    _responses[c.id] = idx >= 2
        ? [ResponseEntry('Our team has scheduled an inspection for this concern.', 'Maria Santos', hist[2].at)]
        : <ResponseEntry>[];
  }

  Iterable<Complaint> _visible(AppUser me) {
    if (me.role == UserRole.citizen) return _complaints.where((c) => c.citizenEmail == me.email);
    if (me.role == UserRole.staff) return _complaints.where((c) => c.officeId == me.officeId);
    return _complaints;
  }

  @override
  void setToken(String? token) {
    if (token == null) _me = null;
  }

  @override
  Map<String, String> get authHeaders => const {};

  @override
  String getAttachmentUrl(int complaintId) => '';

  @override
  Future<void> markNotificationsRead() async {}

  @override
  Future<List<int>> downloadReportCsvBytes({int days = 30, String? month, int? officeId, int? categoryId}) async {
    await _lag();
    return utf8.encode('ID,Date,Title,Office,Status\n1,2026-11-23,Sample,Mayor,submitted\n');
  }

  @override
  Future<List<int>> downloadMyComplaintsCsvBytes() async {
    await _lag();
    return utf8.encode('ID,Date,Title,Office,Status\n');
  }

  @override
  Future<ComplaintMessage> postComplaintMessage({required int complaintId, required String message}) async {
    await _lag();
    return ComplaintMessage(id: 1, senderRole: _me?.role.name ?? 'citizen', senderName: _me?.name ?? 'User', message: message, createdAt: DateTime.now());
  }

  @override
  Future<void> submitComplaintFeedback({required int complaintId, required int rating, String? comment}) async {
    await _lag();
  }

  @override
  Future<AppUser> updateProfile({required String name}) async {
    await _lag();
    return AppUser(id: _me?.id ?? 1, name: name, email: _me?.email ?? '', role: _me?.role ?? UserRole.citizen);
  }

  @override
  Future<AppUser> uploadAvatar(List<int> bytes, String fileName) async {
    await _lag();
    return _me ?? const AppUser(id: 1, name: 'User', email: '', role: UserRole.citizen);
  }

  @override
  Future<void> requestEmailChange({required String currentPassword, required String newEmail}) async => _lag();

  @override
  Future<AppUser> confirmEmailChange({required String newEmail, required String code}) async {
    await _lag();
    return AppUser(id: _me?.id ?? 1, name: _me?.name ?? 'User', email: newEmail, role: _me?.role ?? UserRole.citizen);
  }

  @override
  Future<List<ActivityLogItem>> adminActivityLogs({String? role}) async {
    await _lag();
    return const [];
  }

  @override
  String getAvatarUrl(String? avatarUrl) => '';

  @override
  Future<AuthSession> login({required String email, required String password}) async {
    await _lag();
    final key = email.trim().toLowerCase();
    _MockUser? u;
    for (final user in _users) {
      if (user.email.toLowerCase() == key || user.username.toLowerCase() == key) {
        u = user;
        break;
      }
    }
    if (u == null || u.password != password) {
      throw const ApiException(401, 'INVALID_CREDENTIALS', 'Incorrect username/email or password.');
    }
    if (!u.active) {
      throw const ApiException(403, 'ACCOUNT_DISABLED', 'This account has been deactivated. Contact an administrator.');
    }
    _me = AppUser(id: u.id, name: u.name, username: u.username, email: u.email, role: u.role, officeId: u.officeId);
    return AuthSession(_me!, 'mock-token-${u.id}');
  }

  @override
  Future<void> register({
    required String name,
    required String username,
    required String email,
    required String password,
    required List<Map<String, String>> securityQuestions,
  }) async {
    await _lag();
    final keyEmail = email.trim().toLowerCase();
    final keyUser = username.trim().toLowerCase();
    final errs = <String, dynamic>{};
    if (name.trim().length < 2) errs['name'] = 'Enter your full name.';
    if (keyUser.length < 3) errs['username'] = 'Username must be at least 3 characters.';
    if (!RegExp(r'^[a-zA-Z0-9_]+$').hasMatch(keyUser)) errs['username'] = 'Letters, numbers and underscores only.';
    if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(keyEmail)) errs['email'] = 'Enter a valid email address.';
    if (password.length < 8) errs['password'] = 'Password must be at least 8 characters long.';
    if (errs.isNotEmpty) {
      throw ApiException(422, 'VALIDATION_ERROR', 'Some fields are invalid', details: errs);
    }
    if (_users.any((u) => u.username.toLowerCase() == keyUser)) {
      throw const ApiException(409, 'USERNAME_TAKEN', 'This username is already taken. Choose another.');
    }
    if (_users.any((u) => u.email.toLowerCase() == keyEmail)) {
      throw const ApiException(409, 'EMAIL_TAKEN', 'This email is already registered. Try logging in instead.');
    }
    _users.add(_MockUser(_nextUserId++, name.trim(), keyUser, keyEmail, password, UserRole.citizen, null));
    _pendingVerification.add(keyEmail);
  }

  @override
  Future<void> verifyEmail({required String email, required String code}) async {
    await _lag(400);
    final key = email.trim().toLowerCase();
    final exists = _users.any((u) => u.email.toLowerCase() == key);
    if (!exists) {
      throw const ApiException(404, 'NOT_FOUND', 'No account found with this email.');
    }
    // Mock: accept only the fixed test code '123456'
    if (code.trim() != '123456') {
      throw const ApiException(400, 'INVALID_CODE', 'The code is incorrect. For demo/mock mode, the code is 123456.');
    }
    _pendingVerification.remove(key);
  }

  @override
  Future<void> resendVerification({required String email}) async {
    await _lag(400);
    // Mock: always succeed silently
  }

  @override
  Future<({String email, List<SecurityQuestionChoice> questions})> getForgotPasswordQuestions({
    required String email,
  }) async {
    await _lag(400);
    return (
      email: email.trim(),
      questions: const [
        SecurityQuestionChoice(id: 1, question: 'What is the name of your elementary school?'),
        SecurityQuestionChoice(id: 2, question: "What is your pet's name?"),
        SecurityQuestionChoice(id: 3, question: 'What is the name of your best friend?'),
      ],
    );
  }

  @override
  Future<String?> forgotPassword({
    required String email,
    required int questionId,
    required String answer,
    required String confirmAnswer,
  }) async {
    await _lag(500);
    final key = email.trim().toLowerCase();
    _MockUser? u;
    for (final user in _users) {
      if (user.email.toLowerCase() == key || user.username.toLowerCase() == key) {
        u = user;
        break;
      }
    }
    if (u != null) {
      _resetCodes[u.email.toLowerCase()] = '654321'; // fixed mock code
      final parts = u.email.split('@');
      if (parts.length == 2) {
        final n = parts[0];
        final d = parts[1];
        final masked = '${n.length > 2 ? '${n[0]}***${n[n.length - 1]}' : '${n[0]}***'}@$d';
        return masked;
      }
      return u.email;
    }
    return null;
  }

  @override
  Future<void> verifyResetCode({required String email, required String code}) async {
    await _lag(300);
    final key = email.trim().toLowerCase();
    if (_resetCodes[key] != code.trim() && code.trim() != '654321') {
      throw const ApiException(400, 'INVALID_CODE', 'The code is incorrect or has expired.');
    }
  }

  @override
  Future<void> resetPassword({
    required String email,
    required String code,
    required String newPassword,
  }) async {
    await _lag(500);
    final key = email.trim().toLowerCase();
    _MockUser? u;
    for (final user in _users) {
      if (user.email.toLowerCase() == key || user.username.toLowerCase() == key) {
        u = user;
        break;
      }
    }
    if (u == null || _resetCodes[u.email.toLowerCase()] != code) {
      throw const ApiException(400, 'INVALID_CODE', 'The code is incorrect or has expired.');
    }
    if (newPassword.length < 8) {
      throw const ApiException(422, 'VALIDATION_ERROR', 'Password must be at least 8 characters long.');
    }
    u.password = newPassword;
    _resetCodes.remove(u.email.toLowerCase());
  }

  @override
  Future<void> changePassword({required String current, required String next}) async {
    await _lag();
    final me = _need();
    _MockUser? u;
    for (final user in _users) {
      if (user.email.toLowerCase() == me.email.toLowerCase()) {
        u = user;
        break;
      }
    }
    if (u == null || u.password != current) {
      throw const ApiException(403, 'INVALID_CREDENTIALS', 'Your current password is incorrect.');
    }
    if (next.length < 8) {
      throw const ApiException(422, 'VALIDATION_ERROR', 'Password must be at least 8 characters long.');
    }
    u.password = next;
  }

  @override
  Future<Classification> classify(
      {int? categoryId, required String description}) async {
    await Future.delayed(const Duration(milliseconds: 350));
    final catId = categoryId ?? MockClassifier.detectCategory(description) ?? 10;
    return MockClassifier.classify(catId, description);
  }

  @override
  Future<Complaint> submitComplaint({
    required String title,
    required String description,
    required int categoryId,
    required int officeId,
    required int locationId,
    PickedAttachment? attachment,
  }) async {
    await _lag(900);
    final me = _need();
    if (me.role != UserRole.citizen) {
      throw const ApiException(403, 'FORBIDDEN', 'You are not authorized to perform this action.');
    }
    final errs = <String, dynamic>{};
    final t = title.trim();
    final d = description.trim();
    if (t.length < 5 || t.length > 100) {
      errs['title'] = 'Please enter a complaint title between 5 and 100 characters.';
    }
    if (d.length < 20) errs['description'] = 'Complaint description must contain at least 20 characters.';
    if (!kCategories.any((c) => c.id == categoryId)) errs['category_id'] = 'Selected category is invalid.';
    if (!kOffices.any((o) => o.id == officeId)) errs['office_id'] = 'Selected office is invalid.';
    if (!kBarangays.any((b) => b.id == locationId)) errs['location_id'] = 'Selected location is invalid.';
    if (attachment != null) {
      final ext = attachment.name.toLowerCase().split('.').last;
      if (!['jpg', 'jpeg', 'png', 'pdf'].contains(ext) || attachment.size > 5 * 1024 * 1024) {
        errs['attachment'] = 'Only JPG, PNG, or PDF files up to 5MB are allowed.';
      }
    }
    if (errs.isNotEmpty) {
      throw ApiException(422, 'VALIDATION_ERROR', 'Some fields are invalid', details: errs);
    }
    final dup = _complaints.any((c) =>
        c.citizenEmail == me.email &&
        c.title == t &&
        c.description == d &&
        DateTime.now().difference(c.createdAt).inSeconds < 60);
    if (dup) {
      throw const ApiException(409, 'DUPLICATE_SUBMISSION', 'This complaint appears to already be submitted.');
    }

    final result = MockClassifier.classify(categoryId, d);
    final c = Complaint(
      id: _nextId++,
      title: t,
      description: d,
      categoryId: categoryId,
      officeId: officeId,
      locationId: locationId,
      status: ComplaintStatus.submitted,
      priority: result.priority,
      sentiment: result.sentiment,
      createdAt: DateTime.now(),
      citizenName: me.name,
      citizenEmail: me.email,
      attachmentName: attachment?.name,
    );
    _complaints.add(c);
    _history[c.id] = [HistoryEntry(ComplaintStatus.submitted, 'Complaint submitted.', me.name, c.createdAt)];
    _responses[c.id] = <ResponseEntry>[];
    return c;
  }

  @override
  Future<List<Complaint>> listComplaints(UserRole role) async {
    await _lag(400);
    final me = _need();
    return _visible(me).toList()..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

  @override
  Future<ComplaintDetail> getComplaint(int id) async {
    await _lag(350);
    final me = _need();
    final c = _find(id);
    if (c == null || (me.role == UserRole.citizen && c.citizenEmail != me.email)) {
      throw const ApiException(404, 'NOT_FOUND', 'Complaint not found.');
    }
    if (me.role == UserRole.staff && c.officeId != me.officeId) {
      throw const ApiException(403, 'FORBIDDEN', 'This complaint is assigned to another office.');
    }
    final ml = MockClassifier.classify(c.categoryId, c.description);
    return ComplaintDetail(
      complaint: c,
      locationName: kBarangays.firstWhere((b) => b.id == c.locationId, orElse: () => kBarangays.first).name,
      confidence: ml.confidence,
      keywords: ml.keywords,
      responses: List.of(_responses[id] ?? const []),
      history: List.of(_history[id] ?? const []),
    );
  }

  @override
  Future<void> updateStatus(
      {required int id, required ComplaintStatus status, String? message}) async {
    await _lag(700);
    final me = _need();
    final c = _find(id);
    if (c == null) throw const ApiException(404, 'NOT_FOUND', 'Complaint not found.');
    if (me.role != UserRole.staff || c.officeId != me.officeId) {
      throw const ApiException(403, 'FORBIDDEN', 'You are not authorized to update this complaint.');
    }
    final msg = (message ?? '').trim();
    if (msg.length > 500) {
      throw const ApiException(422, 'VALIDATION_ERROR', 'Some fields are invalid',
          details: {'response_message': 'Keep the response under 500 characters.'});
    }
    if (!allowedNext(c.status).contains(status)) {
      throw ApiException(409, 'INVALID_TRANSITION',
          'A complaint that is ${c.status.label} cannot move to ${status.label}.');
    }
    _complaints[_complaints.indexOf(c)] = c.copyWith(status: status);
    final now = DateTime.now();
    _history[id]!.add(HistoryEntry(status, msg.isEmpty ? 'Status changed to ${status.label}.' : msg, me.name, now));
    if (msg.isNotEmpty) _responses[id]!.add(ResponseEntry(msg, me.name, now));
  }

  @override
  Future<DashboardData> dashboard() async {
    await _lag(500);
    final me = _need();
    final list = _visible(me).toList()..sort((a, b) => b.createdAt.compareTo(a.createdAt));

    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    int backOf(Complaint c) => today
        .difference(DateTime(c.createdAt.year, c.createdAt.month, c.createdAt.day))
        .inDays;
    bool isPending(Complaint c) =>
        c.status == ComplaintStatus.submitted || c.status == ComplaintStatus.received;
    bool isProgress(Complaint c) => c.status == ComplaintStatus.inProgress;
    bool isSolved(Complaint c) => !c.status.isOpen;
    int count(bool Function(Complaint) test, int from, int to) =>
        list.where((c) => test(c) && backOf(c) >= from && backOf(c) <= to).length;
    int delta(int cur, int prev) =>
        prev == 0 ? (cur > 0 ? 100 : 0) : (((cur - prev) / prev) * 100).round();

    final labels = <String>[];
    final pendingSeries = <double>[];
    final progressSeries = <double>[];
    for (var back = 13; back >= 0; back--) {
      labels.add(shortDay(today.subtract(Duration(days: back))));
      pendingSeries.add(count(isPending, back, back).toDouble());
      progressSeries.add(count(isProgress, back, back).toDouble());
    }

    final solvedAll = list.where(isSolved).length;
    final byCat = <int, int>{};
    for (final c in list) {
      byCat[c.categoryId] = (byCat[c.categoryId] ?? 0) + 1;
    }
    final top = byCat.entries.toList()..sort((a, b) => b.value.compareTo(a.value));

    return DashboardData(
      pending: count(isPending, 0, 6),
      inProgress: count(isProgress, 0, 6),
      solved: count(isSolved, 0, 6),
      pendingDelta: delta(count(isPending, 0, 6), count(isPending, 7, 13)),
      inProgressDelta: delta(count(isProgress, 0, 6), count(isProgress, 7, 13)),
      solvedDelta: delta(count(isSolved, 0, 6), count(isSolved, 7, 13)),
      serviceLevel: list.isEmpty ? 0 : double.parse((solvedAll / list.length * 100).toStringAsFixed(1)),
      serviceTarget: 75,
      feedbackRating: 4.6, // sample value until a feedback feature exists
      chartLabels: labels,
      pendingSeries: pendingSeries,
      inProgressSeries: progressSeries,
      recent: list.take(5).toList(),
      categories: top
          .take(4)
          .map((e) => CategoryShare(categoryById(e.key).name, (e.value / list.length * 100).round()))
          .toList(),
    );
  }

  @override
  Future<ReportData> report(ReportFilter f) async {
    await _lag(600);
    final me = _need();
    if (me.role != UserRole.admin) {
      throw const ApiException(403, 'FORBIDDEN', 'Only administrators can view reports.');
    }
    final since = f.days == 0 ? null : DateTime.now().subtract(Duration(days: f.days));
    final rows = _complaints.where((c) =>
        (since == null || c.createdAt.isAfter(since)) &&
        (f.officeId == null || c.officeId == f.officeId) &&
        (f.categoryId == null || c.categoryId == f.categoryId)).toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

    List<LabelCount> tally<K>(K Function(Complaint) key, String Function(K) name, List<K> order) =>
        order
            .map((k) => LabelCount(name(k), rows.where((c) => key(c) == k).length))
            .where((e) => e.count > 0)
            .toList();

    return ReportData(
      total: rows.length,
      open: rows.where((c) => c.status.isOpen).length,
      resolved: rows.where((c) => !c.status.isOpen).length,
      byCategory: tally<int>((c) => c.categoryId, (k) => categoryById(k).name, kCategories.map((c) => c.id).toList())
        ..sort((a, b) => b.count.compareTo(a.count)),
      byOffice: tally<int>((c) => c.officeId, (k) => officeById(k).shortName, kOffices.map((o) => o.id).toList())
        ..sort((a, b) => b.count.compareTo(a.count)),
      byPriority: tally<Priority>((c) => c.priority, (k) => k.name[0].toUpperCase() + k.name.substring(1), Priority.values),
      byStatus: tally<ComplaintStatus>((c) => c.status, (k) => k.label, ComplaintStatus.values),
      rows: rows,
    );
  }

  @override
  Future<List<UserRecord>> adminUsers() async {
    await _lag(400);
    if (_need().role != UserRole.admin) {
      throw const ApiException(403, 'FORBIDDEN', 'Only administrators can manage users.');
    }
    return _users
        .map((u) => UserRecord(u.id, u.name, u.email, u.role, u.officeId, u.active))
        .toList()
      ..sort((a, b) => a.name.compareTo(b.name));
  }

  @override
  Future<void> setUserActive(int id, bool active) async {
    await _lag(300);
    final me = _need();
    if (me.role != UserRole.admin) {
      throw const ApiException(403, 'FORBIDDEN', 'Only administrators can manage users.');
    }
    for (final u in _users) {
      if (u.id == id) {
        if (u.email == me.email) {
          throw const ApiException(409, 'CONFLICT', 'You cannot deactivate your own account.');
        }
        u.active = active;
        return;
      }
    }
    throw const ApiException(404, 'NOT_FOUND', 'User not found.');
  }

  @override
  Future<void> createStaffUser({
    required String name,
    required String email,
    required String password,
    required int officeId,
    String? username,
  }) async {
    await _lag(300);
  }

  @override
  Future<void> updateStaffUser({
    required int id,
    String? name,
    int? officeId,
    bool? active,
    String? password,
  }) async {
    await _lag(300);
  }

  @override
  Future<void> deleteStaffUser(int id) async {
    await _lag(300);
  }

  @override
  Future<List<AnnouncementItem>> publicAnnouncements() async => const [];

  @override
  Future<List<AnnouncementItem>> announcements() async => const [];

  @override
  Future<AnnouncementItem> createAnnouncement({
    required String title,
    required String content,
    String category = 'Announcement',
  }) async {
    await _lag(300);
    return AnnouncementItem(
      id: 1,
      title: title,
      content: content,
      category: category,
      status: 'approved',
      isActive: true,
      createdById: 1,
      createdByName: 'Admin',
      createdByRole: 'admin',
      createdAt: DateTime.now(),
    );
  }

  @override
  Future<AnnouncementItem> updateAnnouncement({
    required int id,
    String? title,
    String? content,
    String? category,
    String? status,
    bool? isActive,
  }) async {
    await _lag(300);
    return AnnouncementItem(
      id: id,
      title: title ?? '',
      content: content ?? '',
      category: category ?? 'Announcement',
      status: status ?? 'approved',
      isActive: isActive ?? true,
      createdById: 1,
      createdByName: 'Admin',
      createdByRole: 'admin',
      createdAt: DateTime.now(),
    );
  }

  @override
  Future<void> deleteAnnouncement(int id) async {
    await _lag(300);
  }

  @override
  Future<List<OfficeSummary>> adminOffices() async {
    await _lag(400);
    if (_need().role != UserRole.admin) {
      throw const ApiException(403, 'FORBIDDEN', 'Only administrators can view offices.');
    }
    return kOffices.map((o) {
      final mine = _complaints.where((c) => c.officeId == o.id);
      return OfficeSummary(
        o.id,
        o.name,
        _users.where((u) => u.role == UserRole.staff && u.officeId == o.id).length,
        mine.where((c) => c.status.isOpen).length,
        mine.length,
      );
    }).toList();
  }

  @override
  Future<List<AppNotice>> notifications() async {
    await _lag(300);
    final me = _need();
    final out = <AppNotice>[];
    if (me.role == UserRole.citizen) {
      for (final c in _visible(me)) {
        for (final h in _history[c.id] ?? const <HistoryEntry>[]) {
          if (h.status != ComplaintStatus.submitted) {
            out.add(AppNotice('Complaint #${c.id} is now ${h.status.label}.', h.at, c.id));
          }
        }
      }
    } else if (me.role == UserRole.staff) {
      final cutoff = DateTime.now().subtract(const Duration(days: 3));
      for (final c in _visible(me)) {
        if (c.status == ComplaintStatus.submitted && c.createdAt.isAfter(cutoff)) {
          out.add(AppNotice('New ${c.priority.name} priority complaint: ${c.title}', c.createdAt, c.id));
        }
      }
    }
    out.sort((a, b) => b.at.compareTo(a.at));
    return out.take(8).toList();
  }

  static const _sampleTitles = <int, String>{
    1: 'Pothole along the national highway',
    2: 'Streetlight not working near the plaza',
    3: 'Canal overflowing after the rain',
    4: 'Garbage not collected for days',
    5: 'Request for a health center visit',
    6: 'Suspicious activity near the market',
    7: 'Traffic jam at the school entrance',
    8: 'Assistance request for a senior citizen',
    9: 'Loud videoke past midnight',
    10: 'General concern about a public facility',
  };

  static List<Complaint> _seed() {
    const statuses = [
      ComplaintStatus.resolved, ComplaintStatus.resolved, ComplaintStatus.inProgress,
      ComplaintStatus.closed, ComplaintStatus.submitted, ComplaintStatus.resolved,
      ComplaintStatus.received, ComplaintStatus.closed, ComplaintStatus.resolved,
      ComplaintStatus.inProgress,
    ];
    final now = DateTime.now();
    return List.generate(24, (i) {
      final cat = (i * 3) % 10 + 1;
      final back = (i * 5) % 14;
      final priority = Priority.values[(i * 7) % 4];
      final title = _sampleTitles[cat]!;
      final ana = i % 6 == 5; // a few complaints belong to another citizen
      return Complaint(
        id: 100 + i,
        title: title,
        description: '$title. This has been going on for several days and residents are asking for action.',
        categoryId: cat,
        officeId: categoryById(cat).officeId,
        locationId: (i % 12) + 1,
        status: statuses[i % 10],
        priority: priority,
        sentiment: priority.index >= 2 ? 'negative' : 'neutral',
        createdAt: now.subtract(Duration(days: back, hours: (i * 7) % 9, minutes: (i * 11) % 60)),
        citizenName: ana ? 'Ana Lopez' : 'Juan Dela Cruz',
        citizenEmail: ana ? 'ana@gmail.com' : 'citizen@gmail.com',
      );
    });
  }
}
