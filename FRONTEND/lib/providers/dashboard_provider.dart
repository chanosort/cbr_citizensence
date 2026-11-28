import 'package:flutter/foundation.dart';

import '../models/models.dart';
import '../services/api_service.dart';

class DashboardProvider extends ChangeNotifier {
  DashboardProvider(this._api);
  final ApiService _api;

  DashboardData? data;
  bool loading = false;
  String? error;

  Future<void> load({bool forceClear = false}) async {
    if (forceClear) data = null;
    loading = data == null;
    error = null;
    notifyListeners();
    try {
      data = await _api.dashboard();
    } on ApiException catch (e) {
      if (data == null) error = e.message;
    } catch (_) {
      if (data == null) error = 'Unable to load the dashboard. Please try again.';
    }
    loading = false;
    notifyListeners();
  }
}
