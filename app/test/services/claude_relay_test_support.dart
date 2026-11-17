/// An in-memory [RelayNodes] for the relay client tests.
library;

import 'package:diet_guard_app/services/claude_relay_rtdb.dart';

class MemoryNodes implements RelayNodes {
  final Map<String, Object?> data = {};
  final List<String> deleted = [];
  int failReads = 0;
  bool failPut = false;

  @override
  Future<Object?> get(String path) async => data[path];

  @override
  Future<Set<String>> keys(String path) async {
    if (failReads > 0) {
      failReads--;
      throw const RelayTransportError('offline');
    }
    return {
      for (final key in data.keys)
        if (key.startsWith('$path/'))
          key.substring(path.length + 1).split('/').first,
    };
  }

  @override
  Future<void> put(String path, Object value) async {
    if (failPut) throw const RelayTransportError('offline');
    data[path] = value;
  }

  @override
  Future<void> delete(String path) async {
    deleted.add(path);
    data.removeWhere((key, _) => key == path || key.startsWith('$path/'));
  }

  @override
  Future<bool> deleteUnclaimed(String path) async {
    if (data.containsKey('$path/claim') || data.containsKey('$path/result')) {
      return false;
    }
    await delete(path);
    return true;
  }
}
