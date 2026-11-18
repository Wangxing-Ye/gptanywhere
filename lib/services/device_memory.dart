import 'package:flutter/services.dart';

abstract class DeviceMemory {
  const DeviceMemory();

  /// Total physical memory, or null when the platform does not answer.
  Future<int?> totalBytes();
}

class UnavailableDeviceMemory extends DeviceMemory {
  const UnavailableDeviceMemory();

  @override
  Future<int?> totalBytes() async => null;
}

class FixedDeviceMemory extends DeviceMemory {
  const FixedDeviceMemory(this.bytes);

  final int? bytes;

  @override
  Future<int?> totalBytes() async => bytes;
}

class PlatformDeviceMemory extends DeviceMemory {
  PlatformDeviceMemory({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(_name);

  static const _name = 'dev.local.gptanywhere/device';
  final MethodChannel _channel;

  @override
  Future<int?> totalBytes() async {
    try {
      final value = await _channel.invokeMethod<int>('totalMemoryBytes');
      if (value == null || value <= 0) return null;
      return value;
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }
}
