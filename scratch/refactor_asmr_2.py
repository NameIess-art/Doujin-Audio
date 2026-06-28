import re
import os

path = r'e:\MyProjects\AudioPlayer\lib\services\asmr_download_manager.dart'

with open(path, 'r', encoding='utf-8') as f:
    content = f.read()

# 1. Update AsmrDownloadTaskSnapshot
snapshot_pattern = r'''class AsmrDownloadTaskSnapshot \{
  const AsmrDownloadTaskSnapshot\(\{
(.*?)
  \}\);

(.*?)
  final String\? error;
'''

def snapshot_repl(m):
    constructor_args = m.group(1)
    fields = m.group(2)
    
    new_constructor = constructor_args + '''
    this.fileDownloadedBytes = const {},
    this.fileTotalBytes = const {},'''
    
    new_fields = fields + '''
  final String? error;
  final Map<String, int> fileDownloadedBytes;
  final Map<String, int> fileTotalBytes;'''
    
    return f'''class AsmrDownloadTaskSnapshot {{
  const AsmrDownloadTaskSnapshot({{
{new_constructor}
  }});

{new_fields}
'''
content = re.sub(snapshot_pattern, snapshot_repl, content, flags=re.DOTALL)

# Also update copyWith
copywith_pattern = r'''  AsmrDownloadTaskSnapshot copyWith\(\{
(.*?)
  \}\) \{
    return AsmrDownloadTaskSnapshot\(
(.*?)
      error: error \?\? this\.error,
    \);
  \}'''

def copywith_repl(m):
    args = m.group(1)
    returns = m.group(2)
    
    new_args = args + '''
    Map<String, int>? fileDownloadedBytes,
    Map<String, int>? fileTotalBytes,'''
    
    new_returns = returns + '''
      error: error ?? this.error,
      fileDownloadedBytes: fileDownloadedBytes ?? this.fileDownloadedBytes,
      fileTotalBytes: fileTotalBytes ?? this.fileTotalBytes,'''
      
    return f'''  AsmrDownloadTaskSnapshot copyWith({{
{new_args}
  }}) {{
    return AsmrDownloadTaskSnapshot(
{new_returns}
    );
  }}'''
content = re.sub(copywith_pattern, copywith_repl, content, flags=re.DOTALL)

# 2. Update state in AsmrDownloadManager
state_pattern = r'''  AsmrDownloadTaskSnapshot\? _currentTask;
  String\? _defaultDestinationRoot;
  bool _initialized = false;
  bool _running = false;
  bool _cancelRequested = false;
  Completer<void>\? _downloadCompletion;
  Timer\? _deferredProgressNotifyTimer;
  DateTime\? _lastProgressNotifyAt;
  int _lastProgressNotifyBytes = 0;'''

new_state = '''  final Map<String, AsmrDownloadTaskSnapshot> _tasks = {};
  final List<String> _queue = [];
  final Set<String> _activeTasks = {};
  final Map<String, bool> _cancelRequested = {};
  final Map<String, Completer<void>> _downloadCompletions = {};

  static const int _maxConcurrentDownloads = 3;

  String? _defaultDestinationRoot;
  bool _initialized = false;
  Timer? _deferredProgressNotifyTimer;
  DateTime? _lastProgressNotifyAt;
  int _lastProgressNotifyBytes = 0;'''

content = content.replace(state_pattern, new_state)

# 3. Update getters
getters_pattern = r'''  AsmrDownloadTaskSnapshot\? get currentTask => _currentTask;
  bool get hasLiveTask => _currentTask\?\.isActive \?\? false;
  String\? get defaultDestinationRoot => _defaultDestinationRoot;
  AsmrDownloadButtonViewState get buttonViewState =>
      AsmrDownloadButtonViewState\(
        visible: hasLiveTask && _currentTask != null,
        progress: _currentTask\?\.progress,
      \);
  AsmrDownloadTaskShellViewState get taskShellViewState =>
      AsmrDownloadTaskShellViewState\(
        hasTask: _currentTask != null,
        isActive: _currentTask\?\.isActive \?\? false,
      \);
  AsmrDownloadTaskHeaderViewState\? get taskHeaderViewState \{
    final task = _currentTask;
    if \(task == null\) \{
      return null;
    \}
    return AsmrDownloadTaskHeaderViewState\(
      title: task\.work\.title,
      status: task\.status,
      currentItemPath: task\.currentItemPath,
      error: task\.error,
      failedFiles: task\.failedFiles,
      completedFiles: task\.completedFiles,
    \);
  \}

  AsmrDownloadTaskProgressViewState\? get taskProgressViewState \{
    final task = _currentTask;
    if \(task == null\) \{
      return null;
    \}
    return AsmrDownloadTaskProgressViewState\(
      progress: task\.progress,
      status: task\.status,
      completedFiles: task\.completedFiles,
      totalFiles: task\.totalFiles,
      skippedFiles: task\.skippedFiles,
      failedFiles: task\.failedFiles,
      downloadedBytes: task\.downloadedBytes,
      totalBytes: task\.totalBytes,
    \);
  \}'''

new_getters = '''  List<AsmrDownloadTaskSnapshot> get tasks => _tasks.values.toList();
  AsmrDownloadTaskSnapshot? getTask(String workId) => _tasks[workId];
  bool get hasLiveTask => _activeTasks.isNotEmpty || _queue.isNotEmpty;

  String? get defaultDestinationRoot => _defaultDestinationRoot;

  AsmrDownloadButtonViewState get buttonViewState {
    if (_tasks.isEmpty) return const AsmrDownloadButtonViewState(visible: false, progress: null);
    int totalBytes = 0;
    int downloadedBytes = 0;
    for (final t in _tasks.values) {
      if (t.isActive) {
        totalBytes += t.totalBytes;
        downloadedBytes += t.downloadedBytes;
      }
    }
    double? progress;
    if (totalBytes > 0) {
      progress = (downloadedBytes / totalBytes).clamp(0.0, 1.0);
    }
    return AsmrDownloadButtonViewState(visible: true, progress: progress);
  }

  AsmrDownloadTaskShellViewState get taskShellViewState =>
      AsmrDownloadTaskShellViewState(
        hasTask: _tasks.isNotEmpty,
        isActive: hasLiveTask,
      );'''

content = re.sub(getters_pattern, new_getters, content, flags=re.DOTALL)

with open(path, 'w', encoding='utf-8') as f:
    f.write(content)
