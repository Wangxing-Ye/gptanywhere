import 'package:flutter/foundation.dart';

import '../domain/app_settings.dart';

class MemorySettingsStore implements SettingsStore {
  MemorySettingsStore({AppSettings initial = AppSettings.defaults})
    : _current = initial;

  final _revisions = ValueNotifier<int>(0);
  AppSettings _current;

  @override
  ValueListenable<int> get revisions => _revisions;

  @override
  Future<AppSettings> load() async => _current;

  @override
  Future<void> save(AppSettings settings) async {
    _current = settings;
    _revisions.value++;
  }
}
