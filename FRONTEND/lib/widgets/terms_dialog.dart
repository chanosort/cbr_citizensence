import 'package:flutter/material.dart';

import '../core/theme.dart';
import 'seal_logo.dart';

/// Comprehensive Terms of Use and Data Privacy Notice tailored specifically
/// for the Cabadbaran CitizenSense platform (City Government of Cabadbaran, Agusan del Norte),
/// in compliance with the Philippine Data Privacy Act of 2012 (R.A. 10173) and
/// the Ease of Doing Business Act (R.A. 11032).
const _sections = <(String, String)>[
  (
    '1. Purpose and Acceptance',
    'Cabadbaran CitizenSense is the official citizen-engagement and grievance-handling platform '
    'of the City Government of Cabadbaran, Province of Agusan del Norte. It is designed to empower '
    'residents to submit civic concerns, report public infrastructure and sanitation issues, and '
    'track their resolution transparently. By creating an account, accessing, or submitting complaints '
    'through CitizenSense, you confirm that you have read, understood, and agreed to these Terms of '
    'Use and the Data Privacy Notice. If you do not agree, please refrain from using the platform.'
  ),
  (
    '2. Least Privilege Role Architecture',
    'CitizenSense enforces strict Role-Based Access Control (RBAC) following the principle of least privilege:\n'
    '• Citizen: Self-registered residents who may submit complaints, upload supporting evidence, '
    'track the progress of their own filed concerns, and manage their profile.\n'
    '• Office Staff: Designated personnel assigned strictly to specific city departments '
    '(e.g., City Engineering Office, City Health Office, CENRO, CSWDO, CDRRMO, Public Safety, Mayor\'s Office). '
    'Staff can only view, review, and resolve complaints routed to their designated office.\n'
    '• Administrator: Authorized city administrative officers who manage user statuses, oversee '
    'city-wide analytics, and audit cross-departmental compliance.\n'
    'Public self-registration is strictly restricted to the Citizen role. Staff and Administrator '
    'accounts are provisioned and vetted exclusively by the City Government and cannot be self-created.'
  ),
  (
    '3. Legitimate Email & Security Verification',
    'To preserve the integrity of municipal records, eliminate fraudulent or automated prank entries, '
    'and maintain reliable communication, every registering citizen must provide a legitimate, active '
    'email address. The system requires confirmation via a single-use 6-digit email verification code (OTP). '
    'Accounts remain inactive and cannot file complaints until verified. Account recovery and password '
    'resets likewise require verification codes delivered to the registered email.'
  ),
  (
    '4. Standards for Filing Complaints',
    'When submitting concerns, citizens agree to provide truthful, accurate, and constructive information:\n'
    '• Scope: Complaints must relate to public matters and city services within Cabadbaran City and its barangays.\n'
    '• Evidence: Attachments (photos/documents) must be genuine and relevant (JPG, PNG, or PDF format, up to 5MB).\n'
    '• Conduct: Vulgar, defamatory, abusive, or malicious submissions are strictly prohibited and will result '
    'in account suspension and potential legal liability.\n'
    '• Non-Emergency Notice: CitizenSense is an administrative grievance and service-request mechanism. '
    'It is NOT an emergency dispatch system. In urgent, life-threatening events (active fires, crimes in '
    'progress, or immediate medical emergencies), citizens must contact 911 or local emergency hotlines immediately.'
  ),
  (
    '5. Machine Learning & Automated Triage',
    'CitizenSense integrates Machine Learning (ML) and Natural Language Processing (NLP) models to '
    'assist city personnel by automatically assessing submitted complaints to suggest office categories, '
    'detect sentiment, and recommend priority ratings (Low, Medium, High, or Critical). These automated '
    'outputs serve as preliminary recommendations to expedite response times; all final assessments, '
    'actions, and official responses are validated and determined by authorized human city personnel.'
  ),
  (
    '6. Data Privacy Notice (R.A. 10173 Compliance)',
    'In accordance with Republic Act No. 10173 (Data Privacy Act of 2012), the City Government of '
    'Cabadbaran is committed to safeguarding your personal data:\n'
    '• Information Collected: Full name, verified email, barangay location, complaint narrative, '
    'attached media, status update logs, and authentication timestamps.\n'
    '• Purpose of Processing: To verify complainant identity, route complaints to appropriate city departments, '
    'coordinate field investigations, communicate status updates, and generate anonymized city analytics.\n'
    '• Confidentiality: Your personal information is accessible only to you, the assigned department personnel, '
    'and authorized system administrators. We do not sell, rent, or commercialize your personal data.'
  ),
  (
    '7. Security Measures & Data Retention',
    'Your data is protected using industry-standard technical and organizational safeguards:\n'
    '• All transmissions are secured through end-to-end HTTPS encryption.\n'
    '• Passwords are cryptographically salted and hashed using PBKDF2 with SHA-256.\n'
    '• Verification codes (OTP) are hashed and automatically expire within 10 minutes.\n'
    '• Complaint records are retained for historical audit trails, resolution tracking, and statutory '
    'reporting requirements in accordance with municipal retention policies.'
  ),
  (
    '8. Complainant Rights & Contact Information',
    'Under R.A. 10173, you have the right to be informed, access your personal information, request '
    'reasonable corrections to inaccurate data, and object to processing where permitted by law. '
    'For inquiries regarding data privacy or platform use, you may reach the City Government of '
    'Cabadbaran Data Protection Officer at City Hall, Cabadbaran City, Agusan del Norte.'
  ),
];

/// Returns true when the person taps "I agree".
Future<bool?> showTermsDialog(BuildContext context) =>
    showDialog<bool>(context: context, builder: (_) => const _TermsDialog());

class _TermsDialog extends StatelessWidget {
  const _TermsDialog();

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.white,
      insetPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640, maxHeight: 680),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 20, 22, 16),
            child: Row(children: [
              const SealLogo(size: 46),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Terms of Use & Privacy Notice',
                      style: Theme.of(context)
                          .textTheme
                          .titleMedium
                          ?.copyWith(fontWeight: FontWeight.w800, color: AppColors.navy),
                    ),
                    const SizedBox(height: 2),
                    const Text(
                      'City Government of Cabadbaran · CitizenSense',
                      style: TextStyle(fontSize: 12, color: AppColors.muted),
                    ),
                  ],
                ),
              ),
            ]),
          ),
          const Divider(height: 1, color: AppColors.line),
          Flexible(
            child: ListView.separated(
              padding: const EdgeInsets.all(22),
              shrinkWrap: true,
              itemCount: _sections.length,
              separatorBuilder: (_, __) => const SizedBox(height: 16),
              itemBuilder: (_, idx) {
                final s = _sections[idx];
                return Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: AppColors.canvas,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppColors.line),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        s.$1,
                        style: const TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 14,
                          color: AppColors.navy,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        s.$2,
                        style: const TextStyle(
                          height: 1.5,
                          fontSize: 13,
                          color: AppColors.ink,
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
          const Divider(height: 1, color: AppColors.line),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Republic Act No. 10173 Compliant',
                  style: TextStyle(fontSize: 11.5, color: AppColors.muted, fontWeight: FontWeight.w600),
                ),
                Row(children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(false),
                    child: const Text('Close'),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    onPressed: () => Navigator.of(context).pop(true),
                    child: const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 14),
                      child: Text('I agree'),
                    ),
                  ),
                ]),
              ],
            ),
          ),
        ]),
      ),
    );
  }
}
