import 'dart:io';

import 'package:PiliPlus/features/ai_recommendation/model.dart';
import 'package:PiliPlus/features/ai_recommendation/settings_page.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory storageDirectory;

  setUpAll(() async {
    storageDirectory = await Directory.systemTemp.createTemp('ai-settings-test-');
    Hive.init(storageDirectory.path);
    GStorage.setting = await Hive.openBox<dynamic>('setting');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (_) async => '',
        );
  });

  tearDownAll(() async {
    await Hive.close();
    await storageDirectory.delete(recursive: true);
  });

  for (final mode in AiRecommendationMode.values) {
    testWidgets('AI settings render and accept input in ${mode.name} mode', (
      tester,
    ) async {
      await tester.runAsync(
        () => GStorage.setting.put(SettingBoxKey.aiRcmdMode, mode.name),
      );
      tester.view.physicalSize = const Size(1280, 2000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      // Match the Material library used by the actual GetMaterialApp.
      await tester.pumpWidget(
        const MaterialApp(home: AiRecommendationSettingsPage()),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byType(ErrorWidget), findsNothing);

      final field = find.byType(TextFormField).first;
      await tester.enterText(
        field,
        mode == AiRecommendationMode.vps
            ? 'https://example.com/feed.json'
            : 'https://example.com/v1',
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.byType(ErrorWidget), findsNothing);
    });
  }
}
