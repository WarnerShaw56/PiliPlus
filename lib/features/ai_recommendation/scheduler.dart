import 'dart:async';

import 'package:PiliPlus/features/ai_recommendation/preferences.dart';
import 'package:PiliPlus/features/ai_recommendation/repository.dart';
import 'package:PiliPlus/features/ai_recommendation/service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

class AiRecommendationScheduler with WidgetsBindingObserver {
  AiRecommendationScheduler._();

  static final instance = AiRecommendationScheduler._();

  Timer? _timer;
  bool _isRunning = false;

  void start() {
    if (_timer != null) return;
    WidgetsBinding.instance.addObserver(this);
    Future<void>.delayed(const Duration(seconds: 8), checkIfDue);
    _timer = Timer.periodic(const Duration(minutes: 30), (_) => checkIfDue());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) checkIfDue();
  }

  Future<void> checkIfDue() async {
    if (_isRunning || !AiRecommendationPreferences.enabled) return;
    final now = DateTime.now();
    if (now.hour < AiRecommendationPreferences.dailyHour) return;

    final generatedAt = AiRecommendationRepository.read()?.generatedAt
        .toLocal();
    if (generatedAt != null && _isSameDay(now, generatedAt)) return;

    final lastAttempt = AiRecommendationRepository.lastAttempt?.toLocal();
    if (lastAttempt != null &&
        now.difference(lastAttempt) < const Duration(hours: 2)) {
      return;
    }

    _isRunning = true;
    try {
      await AiRecommendationService().refresh();
    } catch (error) {
      if (kDebugMode) debugPrint('AI recommendation refresh failed: $error');
    } finally {
      _isRunning = false;
    }
  }

  static bool _isSameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;
}
