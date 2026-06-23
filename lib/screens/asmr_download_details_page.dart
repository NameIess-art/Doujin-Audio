import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/asmr_download_manager.dart';

class AsmrDownloadDetailsPage extends StatelessWidget {
  const AsmrDownloadDetailsPage({super.key, required this.workId});

  final int workId;

  @override
  Widget build(BuildContext context) {
    final manager = context.watch<AsmrDownloadManager>();
    final task = manager.getTask(workId);

    if (task == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Download Details')),
        body: const Center(child: Text('Task not found or completed')),
      );
    }

    final fileDownloadedBytes = task.fileDownloadedBytes;
    final fileTotalBytes = task.fileTotalBytes;
    final filePaths = fileTotalBytes.keys.toList()..sort();

    return Scaffold(
      appBar: AppBar(
        title: Text(task.work.title),
      ),
      body: ListView.builder(
        itemCount: filePaths.length,
        itemBuilder: (context, index) {
          final path = filePaths[index];
          final total = fileTotalBytes[path] ?? 0;
          final downloaded = fileDownloadedBytes[path] ?? 0;

          double progress = 0.0;
          if (total > 0) {
            progress = (downloaded / total).clamp(0.0, 1.0);
          }

          return ListTile(
            title: Text(path, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 4),
                LinearProgressIndicator(value: progress),
                const SizedBox(height: 4),
                Text('${_formatBytes(downloaded)} / ${_formatBytes(total)}'),
              ],
            ),
          );
        },
      ),
    );
  }

  String _formatBytes(int bytes) {
    if (bytes <= 0) return '0 B';
    const units = ['B', 'KB', 'MB', 'GB'];
    var value = bytes.toDouble();
    var unitIndex = 0;
    while (value >= 1024 && unitIndex < units.length - 1) {
      value /= 1024;
      unitIndex++;
    }
    return '${value.toStringAsFixed(value >= 10 ? 0 : 1)} ${units[unitIndex]}';
  }
}
