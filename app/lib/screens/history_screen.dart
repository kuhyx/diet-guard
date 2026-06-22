/// Read-only list of every logged meal, newest first.
library;

import 'dart:async';
import 'dart:io';

import 'package:diet_guard_app/models/food_entry.dart';
import 'package:diet_guard_app/screens/photo_viewer_screen.dart';
import 'package:diet_guard_app/services/log_storage_service.dart';
import 'package:flutter/material.dart';

/// Shows every non-deleted logged entry across all days, so the user can
/// confirm what was actually logged (including whether a photo attached).
///
/// Deliberately minimal: no editing, filtering, or pagination -- just
/// enough to answer "did this get logged, and with what photo?"
class HistoryScreen extends StatefulWidget {
  /// Creates a [HistoryScreen].
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  List<FoodEntry>? _entries;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final entries = await LogStorageService.instance.allEntriesNewestFirst();
    if (!mounted) return;
    setState(() => _entries = entries);
  }

  @override
  Widget build(BuildContext context) {
    final entries = _entries;
    return Scaffold(
      appBar: AppBar(title: const Text('History')),
      body: entries == null
          ? const Center(child: CircularProgressIndicator())
          : entries.isEmpty
          ? const Center(child: Text('Nothing logged yet.'))
          : ListView.builder(
              itemCount: entries.length,
              itemBuilder: (context, index) {
                final entry = entries[index];
                return ListTile(
                  leading: _Thumbnail(imagePath: entry.imagePath),
                  title: Text(entry.desc),
                  subtitle: Text('${entry.time}  •  ${entry.source}'),
                  trailing: Text('${entry.kcal.toStringAsFixed(0)} kcal'),
                );
              },
            ),
    );
  }
}

class _Thumbnail extends StatelessWidget {
  const _Thumbnail({required this.imagePath});

  final String? imagePath;

  @override
  Widget build(BuildContext context) {
    final path = imagePath;
    if (path == null) {
      return const SizedBox(
        width: 40,
        height: 40,
        child: Icon(Icons.restaurant),
      );
    }
    return GestureDetector(
      onTap: () => Navigator.of(context).push<void>(
        MaterialPageRoute(builder: (_) => PhotoViewerScreen(path: path)),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: Image.file(
          File(path),
          width: 40,
          height: 40,
          fit: BoxFit.cover,
          errorBuilder: (context, error, stackTrace) => const SizedBox(
            width: 40,
            height: 40,
            child: Icon(Icons.broken_image),
          ),
        ),
      ),
    );
  }
}
