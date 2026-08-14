enum TaskStatus { running, queued, completed, failed, cancelled }

const controlModeOptions = ['auto', 'cli', 'desktop'];
const deliveryStateOptions = [
  'created',
  'sent',
  'running',
  'delivered',
  'refreshable',
  'completed',
  'failed',
  'cancelled'
];

extension TaskStatusLabel on TaskStatus {
  String get label => switch (this) {
        TaskStatus.running => '运行中',
        TaskStatus.queued => '排队中',
        TaskStatus.completed => '已完成',
        TaskStatus.failed => '失败',
        TaskStatus.cancelled => '已取消',
      };
}

class AgentTask {
  AgentTask({
    required this.id,
    required this.title,
    required this.prompt,
    required this.status,
    required this.updatedAt,
    required this.summary,
    this.sessionId,
    this.createdAt = '',
    this.workspaceId,
    this.mode = 'project',
    this.controlMode = 'auto',
    this.effectiveControlMode,
    this.controlModeDetail,
    this.desktopMayStealFocus = false,
    this.deliveryState = 'created',
    this.model = 'gpt-5.6-sol',
    this.reasoningEffort = 'medium',
    this.outputLog = '',
    this.artifactName,
    this.artifactUrl,
    this.files = const [],
  });

  final String id;
  final String? sessionId;
  final String title;
  final String prompt;
  TaskStatus status;
  String createdAt;
  String updatedAt;
  String summary;
  String? workspaceId;
  String mode;
  String controlMode;
  String? effectiveControlMode;
  String? controlModeDetail;
  bool desktopMayStealFocus;
  String deliveryState;
  String model;
  String reasoningEffort;
  String outputLog;
  String? artifactName;
  String? artifactUrl;
  final List<String> files;

  factory AgentTask.fromJson(Map<String, dynamic> json) {
    final prompt = json['prompt'] as String? ?? '未命名任务';
    final outputLog = _cleanOutput(json['outputLog'] is List
        ? (json['outputLog'] as List).join()
        : json['outputLog'] as String? ?? '');
    final artifacts = json['artifacts'];
    final artifact = artifacts is List && artifacts.isNotEmpty
        ? Map<String, dynamic>.from(artifacts.last as Map)
        : const <String, dynamic>{};
    final files = json['files'] is List
        ? (json['files'] as List).whereType<String>().toList()
        : const <String>[];
    return AgentTask(
      id: json['id'] as String? ?? 'task_unknown',
      sessionId: json['sessionId'] as String?,
      title: prompt.length > 48 ? '${prompt.substring(0, 48)}...' : prompt,
      prompt: prompt,
      status: taskStatusFromJson(json['status']),
      createdAt: json['createdAt'] as String? ?? '',
      updatedAt: _relativeTime(json['createdAt'] as String?),
      summary: json['summary'] as String? ?? '任务已从 Bridge 同步。',
      workspaceId: json['workspaceId'] as String?,
      mode: json['mode'] as String? ?? 'project',
      controlMode: json['controlMode'] as String? ?? 'auto',
      effectiveControlMode: json['effectiveControlMode'] as String?,
      controlModeDetail: json['controlModeDetail'] as String?,
      desktopMayStealFocus: json['desktopMayStealFocus'] as bool? ?? false,
      deliveryState: json['deliveryState'] as String? ??
          _deliveryStateFromStatus(json['status']),
      model: json['model'] as String? ?? 'gpt-5.6-sol',
      reasoningEffort: json['reasoningEffort'] as String? ?? 'medium',
      outputLog: outputLog,
      artifactName: artifact['name'] as String?,
      artifactUrl: (artifact['previewUrl'] ?? artifact['url']) as String?,
      files: files,
    );
  }

  String get controlModeLabel => controlModeLabelOf(controlMode);
  String get effectiveControlModeLabel => effectiveControlMode == null
      ? '未开始'
      : controlModeLabelOf(effectiveControlMode!);
  String get deliveryLabel => deliveryStateLabelOf(deliveryState, status);
}

String _deliveryStateFromStatus(Object? status) => switch (status) {
      'queued' => 'created',
      'running' => 'running',
      'completed' => 'completed',
      'failed' => 'failed',
      'cancelled' => 'cancelled',
      _ => 'created',
    };

String controlModeLabelOf(String value) => switch (value) {
      'auto' => '自动',
      'cli' => '后台 Codex',
      'desktop' => '桌面接管',
      _ => value,
    };

String deliveryStateLabelOf(String value, TaskStatus status) => switch (value) {
      'created' => '已发送',
      'sent' => '已投递',
      'running' => 'Codex 运行中',
      'delivered' => '已投递，电脑端运行中',
      'refreshable' => '历史可刷新',
      'completed' => '已完成',
      'failed' => '失败',
      'cancelled' => '已取消',
      _ => status.label,
    };

String _cleanOutput(String value) => value
    .split('\n')
    .where((line) => line.trim() != 'Reading additional input from stdin...')
    .join('\n')
    .trimLeft();

TaskStatus taskStatusFromJson(Object? value) => switch (value) {
      'queued' => TaskStatus.queued,
      'running' => TaskStatus.running,
      'completed' => TaskStatus.completed,
      'failed' => TaskStatus.failed,
      'cancelled' => TaskStatus.cancelled,
      _ => TaskStatus.failed,
    };

String _relativeTime(String? value) {
  final timestamp = DateTime.tryParse(value ?? '');
  if (timestamp == null) return '最近';
  final minutes = DateTime.now().difference(timestamp.toLocal()).inMinutes;
  if (minutes < 1) return '刚刚';
  if (minutes < 60) return '$minutes 分钟前';
  return '${minutes ~/ 60} 小时前';
}

class Workspace {
  const Workspace(
      {required this.id,
      required this.name,
      required this.path,
      this.createdAt,
      this.updatedAt});

  final String id;
  final String name;
  final String path;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  factory Workspace.fromJson(Map<String, dynamic> json) => Workspace(
        id: json['id'] as String? ?? 'unknown',
        name: json['name'] as String? ?? '未命名工作区',
        path: (json['path'] ?? json['rootPath']) as String? ?? '',
        createdAt: DateTime.tryParse(json['createdAt'] as String? ?? ''),
        updatedAt: DateTime.tryParse(json['updatedAt'] as String? ?? ''),
      );
}

class AgentSession {
  const AgentSession(
      {required this.id,
      required this.workspaceId,
      this.title = 'Codex 会话',
      this.createdAt = '',
      this.codexSessionId});

  final String id;
  final String workspaceId;
  final String title;
  final String createdAt;
  final String? codexSessionId;

  factory AgentSession.fromJson(Map<String, dynamic> json) => AgentSession(
        id: json['id'] as String? ?? '',
        workspaceId: json['workspaceId'] as String? ?? '',
        title: json['title'] as String? ?? 'Codex 会话',
        createdAt: json['createdAt'] as String? ?? '',
        codexSessionId: json['codexSessionId'] as String?,
      );
}

class CodexHistorySession {
  const CodexHistorySession(
      {required this.id,
      required this.title,
      required this.updatedAt,
      this.cwd});

  final String id;
  final String title;
  final String updatedAt;
  final String? cwd;

  factory CodexHistorySession.fromJson(Map<String, dynamic> json) =>
      CodexHistorySession(
        id: json['id'] as String? ?? '',
        title: json['title'] as String? ?? 'Codex 会话',
        updatedAt: json['updatedAt'] as String? ?? '',
        cwd: json['cwd'] as String?,
      );
}

class CodexTranscriptMessage {
  const CodexTranscriptMessage({
    required this.id,
    required this.role,
    required this.text,
    required this.timestamp,
  });

  final String id;
  final String role;
  final String text;
  final String timestamp;

  factory CodexTranscriptMessage.fromJson(Map<String, dynamic> json) =>
      CodexTranscriptMessage(
        id: json['id'] as String? ?? '',
        role: json['role'] as String? ?? 'assistant',
        text: json['text'] as String? ?? '',
        timestamp: json['timestamp'] as String? ?? '',
      );
}

class Device {
  const Device({
    required this.name,
    required this.host,
    required this.isOnline,
    required this.lastSeen,
    required this.workspaces,
  });

  final String name;
  final String host;
  final bool isOnline;
  final String lastSeen;
  final int workspaces;
}

class WorkspaceFile {
  const WorkspaceFile(this.name, this.path, this.kind,
      {this.children = const []});

  final String name;
  final String path;
  final FileKind kind;
  final List<WorkspaceFile> children;

  factory WorkspaceFile.fromJson(Map<String, dynamic> json,
      [String parent = '']) {
    final name = json['name'] as String? ?? 'unknown';
    final path = parent.isEmpty ? name : '$parent/$name';
    final rawChildren = json['children'];
    final children = rawChildren is List
        ? rawChildren
            .whereType<Map>()
            .map((item) =>
                WorkspaceFile.fromJson(Map<String, dynamic>.from(item), path))
            .toList()
        : const <WorkspaceFile>[];
    return WorkspaceFile(
        name,
        path,
        children.isNotEmpty || json['type'] == 'directory'
            ? FileKind.folder
            : fileKindFromName(name),
        children: children);
  }
}

class WorkspaceFilePreview {
  const WorkspaceFilePreview({
    required this.name,
    required this.path,
    required this.kind,
    required this.mimeType,
    required this.size,
    this.content = '',
    this.truncated = false,
  });

  final String name;
  final String path;
  final String kind;
  final String mimeType;
  final int size;
  final String content;
  final bool truncated;

  factory WorkspaceFilePreview.fromJson(Map<String, dynamic> json) =>
      WorkspaceFilePreview(
        name: json['name'] as String? ?? 'unknown',
        path: json['path'] as String? ?? '',
        kind: json['kind'] as String? ?? 'text',
        mimeType: json['mimeType'] as String? ?? 'text/plain',
        size: json['size'] as int? ?? 0,
        content: json['content'] as String? ?? '',
        truncated: json['truncated'] as bool? ?? false,
      );
}

enum FileKind { folder, dart, typescript, markdown, json, image }

FileKind fileKindFromName(String name) {
  final extension =
      name.contains('.') ? name.split('.').last.toLowerCase() : '';
  return switch (extension) {
    'dart' => FileKind.dart,
    'ts' || 'tsx' => FileKind.typescript,
    'md' => FileKind.markdown,
    'json' => FileKind.json,
    'png' || 'jpg' || 'jpeg' || 'webp' => FileKind.image,
    _ => FileKind.markdown,
  };
}
