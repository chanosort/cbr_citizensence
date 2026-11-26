import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Production/Live default: connects to the real backend with real OTP and database.
const bool kUseMockApi = false;

/// Auto-detects the right API URL:
/// - If explicitly set via --dart-define=API_BASE_URL=..., use it.
/// - If running in local web browser (localhost or 127.0.0.1), connect to local backend at http://localhost:8000.
/// - Otherwise, connect to live Render backend ('https://citizensense-backend.onrender.com').
String get kApiBaseUrl {
  const envUrl = String.fromEnvironment('API_BASE_URL', defaultValue: '');
  if (envUrl.isNotEmpty) return envUrl;
  if (kIsWeb) {
    final host = Uri.base.host;
    if (host == 'localhost' || host == '127.0.0.1') {
      return 'http://localhost:8000';
    }
  }
  return 'https://citizensense-backend.onrender.com';
}

enum UserRole { citizen, staff, admin }

extension UserRoleX on UserRole {
  String get label => switch (this) {
        UserRole.citizen => 'Citizen',
        UserRole.staff => 'Office Staff',
        UserRole.admin => 'Administrator',
      };

  /// Email domain that decides the role.
  String get domain => switch (this) {
        UserRole.citizen => '@gmail.com',
        UserRole.staff => '@staff.com',
        UserRole.admin => '@admin.com',
      };

  String get home => switch (this) {
        UserRole.citizen => '/citizen/dashboard',
        UserRole.staff => '/staff/dashboard',
        UserRole.admin => '/admin/dashboard',
      };

  /// List screen for this role (Activity 6 routes).
  String get listRoute => switch (this) {
        UserRole.citizen => '/complaint-tracking',
        UserRole.staff => '/complaint-review',
        UserRole.admin => '/admin/complaints',
      };

  String get listLabel => switch (this) {
        UserRole.citizen => 'My Complaints',
        UserRole.staff => 'Assigned Complaints',
        UserRole.admin => 'Complaints',
      };

  IconData get icon => switch (this) {
        UserRole.citizen => Icons.person_outline_rounded,
        UserRole.staff => Icons.badge_outlined,
        UserRole.admin => Icons.admin_panel_settings_outlined,
      };
}

/// Role-from-email is used only for the login hint widget.
/// Public self-registration always produces 'citizen' — the server enforces this.
/// Staff and admin accounts are created by an administrator.
UserRole? roleFromEmail(String email) {
  final e = email.trim().toLowerCase();
  for (final r in UserRole.values) {
    if (e.endsWith(r.domain) && e.length > r.domain.length) return r;
  }
  return null;
}

class Office {
  final int id;
  final String name;
  final String shortName;
  const Office(this.id, this.name, this.shortName);
}

// Replace with offices_tbl data (IT 108) once the API serves them.
const kOffices = <Office>[
  Office(1, 'City Engineering Office', 'Engineering'),
  Office(2, 'City Health Office', 'Health'),
  Office(3, 'City Environment and Natural Resources Office', 'CENRO'),
  Office(4, 'City Social Welfare and Development Office', 'Social Welfare'),
  Office(5, 'City Disaster Risk Reduction and Management Office', 'DRRMO'),
  Office(6, 'City Public Safety Office', 'Public Safety'),
  Office(7, "City Mayor's Office (General Concerns)", "Mayor's Office"),
];

Office officeById(int id) =>
    kOffices.firstWhere((o) => o.id == id, orElse: () => kOffices.last);

class ComplaintCategory {
  final int id;
  final String name;
  final IconData icon;
  final int officeId; // default office for this category
  const ComplaintCategory(this.id, this.name, this.icon, this.officeId);
}

// Replace with categories_tbl data (IT 108).
const kCategories = <ComplaintCategory>[
  ComplaintCategory(1, 'Roads & Infrastructure', Icons.construction_rounded, 1),
  ComplaintCategory(2, 'Streetlights & Electricity', Icons.lightbulb_outline_rounded, 1),
  ComplaintCategory(3, 'Drainage & Flooding', Icons.water_drop_outlined, 5),
  ComplaintCategory(4, 'Garbage & Sanitation', Icons.delete_outline_rounded, 3),
  ComplaintCategory(5, 'Health Concerns', Icons.medical_services_outlined, 2),
  ComplaintCategory(6, 'Peace, Order & Public Safety', Icons.shield_outlined, 6),
  ComplaintCategory(7, 'Traffic & Transport', Icons.traffic_outlined, 6),
  ComplaintCategory(8, 'Social Welfare & Assistance', Icons.volunteer_activism_outlined, 4),
  ComplaintCategory(9, 'Noise & Public Nuisance', Icons.volume_up_outlined, 6),
  ComplaintCategory(10, 'Other Concerns', Icons.help_outline_rounded, 7),
];

ComplaintCategory categoryById(int id) =>
    kCategories.firstWhere((c) => c.id == id, orElse: () => kCategories.last);

class Barangay {
  final int id;
  final String name;
  const Barangay(this.id, this.name);
}

// All 31 official barangays of Cabadbaran City, Agusan del Norte.
const kBarangays = <Barangay>[
  Barangay(1, 'Antonio Luna'),
  Barangay(2, 'Bay-ang'),
  Barangay(3, 'Bayabas'),
  Barangay(4, 'Caasinan'),
  Barangay(5, 'Cabinet'),
  Barangay(6, 'Calamba'),
  Barangay(7, 'Calibunan'),
  Barangay(8, 'Comagascas'),
  Barangay(9, 'Concepcion'),
  Barangay(10, 'Del Pilar'),
  Barangay(11, 'Katugasan'),
  Barangay(12, 'Kauswagan'),
  Barangay(13, 'La Union'),
  Barangay(14, 'Mabini'),
  Barangay(15, 'Mahaba'),
  Barangay(16, 'Poblacion 1'),
  Barangay(17, 'Poblacion 2'),
  Barangay(18, 'Poblacion 3'),
  Barangay(19, 'Poblacion 4'),
  Barangay(20, 'Poblacion 5'),
  Barangay(21, 'Poblacion 6'),
  Barangay(22, 'Poblacion 7'),
  Barangay(23, 'Poblacion 8'),
  Barangay(24, 'Poblacion 9'),
  Barangay(25, 'Poblacion 10'),
  Barangay(26, 'Poblacion 11'),
  Barangay(27, 'Poblacion 12'),
  Barangay(28, 'Puting Bato'),
  Barangay(29, 'Sanghan'),
  Barangay(30, 'Soriano'),
  Barangay(31, 'Tolosa'),
];