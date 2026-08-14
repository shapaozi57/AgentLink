import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'bridge_client.dart';
import 'mock_data.dart';
import 'models.dart';

const _seed = Color(0xff0b6e69);
const _bridgeUrlKey = 'agentlink.bridgeUrl';
const _bridgeTokenKey = 'agentlink.bridgeToken';
const _selectedWorkspaceIdKey = 'agentlink.selectedWorkspaceId';
const _selectedSessionIdKey = 'agentlink.selectedSessionId';
const _projectOrderIdsKey = 'agentlink.projectOrderIds';
const _sessionOrderPrefix = 'agentlink.sessionOrderIds.';
const _selectedModelKey = 'agentlink.selectedModel';
const _selectedReasoningKey = 'agentlink.selectedReasoning';
const _selectedControlModeKey = 'agentlink.selectedControlMode';
const _allowDesktopTakeoverKey = 'agentlink.allowDesktopTakeover';
const _restoreForegroundWindowKey = 'agentlink.restoreForegroundWindow';
const _requireIdleForDesktopTakeoverKey =
    'agentlink.requireIdleForDesktopTakeover';

const _modelOptions = ['gpt-5.6-sol', 'gpt-5.6-terra', 'gpt-5.5'];
const _reasoningOptions = ['low', 'medium', 'high', 'xhigh'];

enum TaskTargetMode { project, chat }

class TaskTargetSelection {
  const TaskTargetSelection(
      {required this.mode,
      this.workspace,
      this.session,
      this.historySession,
      this.createNewSession = false});
  final TaskTargetMode mode;
  final Workspace? workspace;
  final AgentSession? session;
  final CodexHistorySession? historySession;
  final bool createNewSession;
}

class AgentLinkApp extends StatefulWidget {
  const AgentLinkApp({super.key, this.enableBridge = true});

  final bool enableBridge;

  @override
  State<AgentLinkApp> createState() => _AgentLinkAppState();
}

class _AgentLinkAppState extends State<AgentLinkApp> {
  ThemeMode _themeMode = ThemeMode.system;

  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'AgentLink',
        themeMode: _themeMode,
        theme: _theme(Brightness.light),
        darkTheme: _theme(Brightness.dark),
        home: HomeScreen(
          themeMode: _themeMode,
          onThemeModeChanged: (mode) => setState(() => _themeMode = mode),
          enableBridge: widget.enableBridge,
        ),
      );
}

ThemeData _theme(Brightness brightness) {
  final scheme = ColorScheme.fromSeed(seedColor: _seed, brightness: brightness);
  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    scaffoldBackgroundColor: scheme.surface,
    appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface, surfaceTintColor: Colors.transparent),
    cardTheme: CardThemeData(
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surfaceContainerHighest.withValues(alpha: .6),
      border: OutlineInputBorder(
          borderSide: BorderSide.none, borderRadius: BorderRadius.circular(8)),
    ),
  );
}

class HomeScreen extends StatefulWidget {
  const HomeScreen(
      {super.key,
      required this.themeMode,
      required this.onThemeModeChanged,
      required this.enableBridge});
  final ThemeMode themeMode;
  final ValueChanged<ThemeMode> onThemeModeChanged;
  final bool enableBridge;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  var _index = 0;
  final _client = BridgeClient();
  StreamSubscription<BridgeEvent>? _eventSubscription;
  StreamSubscription<BridgeConnection>? _connectionSubscription;
  BridgeConnection _connection = BridgeConnection.connecting;
  List<Workspace> _workspaces = const [];
  List<WorkspaceFile> _workspaceFiles = workspaceTree;
  List<AgentSession> _sessions = const [];
  List<CodexHistorySession> _codexHistory = const [];
  Workspace? _selectedWorkspace;
  String? _selectedWorkspaceId;
  String? _selectedSessionId;
  List<String> _projectOrderIds = const [];
  Map<String, List<String>> _sessionOrderIdsByWorkspace = const {};
  TaskTargetMode _taskTargetMode = TaskTargetMode.project;
  String _selectedModel = 'gpt-5.6-sol';
  String _selectedReasoning = 'medium';
  String _selectedControlMode = 'auto';
  bool _allowDesktopTakeover = true;
  bool _restoreForegroundWindow = true;
  bool _requireIdleForDesktopTakeover = false;
  AgentSession? _session;
  String? _bridgeError;
  String _bridgeUrl = '';
  String _bridgeToken = '';
  var _testingBridge = false;
  var _loading = true;
  final _tasks = initialTasks
      .map((task) => AgentTask(
            id: task.id,
            title: task.title,
            prompt: task.prompt,
            status: task.status,
            updatedAt: task.updatedAt,
            summary: task.summary,
            workspaceId: task.workspaceId,
            mode: task.mode,
            controlMode: task.controlMode,
            effectiveControlMode: task.effectiveControlMode,
            controlModeDetail: task.controlModeDetail,
            desktopMayStealFocus: task.desktopMayStealFocus,
            deliveryState: task.deliveryState,
            model: task.model,
            reasoningEffort: task.reasoningEffort,
            outputLog: task.outputLog,
            artifactName: task.artifactName,
            artifactUrl: task.artifactUrl,
            files: task.files,
          ))
      .toList();

  @override
  void initState() {
    super.initState();
    _bridgeUrl = _client.baseUrl;
    _eventSubscription = _client.events.listen(_onBridgeEvent);
    _connectionSubscription = _client.connections.listen((connection) {
      if (!mounted) return;
      final shouldRefresh =
          connection == BridgeConnection.connected && _bridgeError != null;
      setState(() => _connection = connection);
      if (shouldRefresh) _refreshBridge();
    });
    if (widget.enableBridge) {
      _loadBridgeSettings();
    } else {
      _loading = false;
      _connection = BridgeConnection.offline;
    }
  }

  Future<void> _loadBridgeSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_bridgeUrlKey);
    final savedToken = prefs.getString(_bridgeTokenKey) ?? '';
    _bridgeToken = savedToken;
    await _client.useAuthToken(savedToken, reconnect: false);
    _selectedWorkspaceId = prefs.getString(_selectedWorkspaceIdKey);
    _selectedSessionId = prefs.getString(_selectedSessionIdKey);
    _projectOrderIds = prefs.getStringList(_projectOrderIdsKey) ?? const [];
    _sessionOrderIdsByWorkspace = {
      for (final key in prefs.getKeys())
        if (key.startsWith(_sessionOrderPrefix))
          key.substring(_sessionOrderPrefix.length):
              prefs.getStringList(key) ?? const <String>[]
    };
    _selectedModel = prefs.getString(_selectedModelKey) ?? _selectedModel;
    _selectedReasoning =
        prefs.getString(_selectedReasoningKey) ?? _selectedReasoning;
    _selectedControlMode =
        prefs.getString(_selectedControlModeKey) ?? _selectedControlMode;
    _allowDesktopTakeover =
        prefs.getBool(_allowDesktopTakeoverKey) ?? _allowDesktopTakeover;
    _restoreForegroundWindow =
        prefs.getBool(_restoreForegroundWindowKey) ?? _restoreForegroundWindow;
    _requireIdleForDesktopTakeover =
        prefs.getBool(_requireIdleForDesktopTakeoverKey) ??
            _requireIdleForDesktopTakeover;
    if (saved != null && saved.trim().isNotEmpty) {
      final uri = normalizeBridgeUri(saved);
      await _client.useBaseUri(uri, reconnect: false);
      if (!mounted) return;
      setState(() => _bridgeUrl = _client.baseUrl);
    }
    await _refreshBridge();
    await _client.connectEvents();
  }

  Future<void> _saveBridgeConnection(String raw, String token) async {
    final uri = normalizeBridgeUri(raw);
    final normalizedToken = token.trim();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_bridgeUrlKey, trimBridgeUrl(uri.toString()));
    await prefs.setString(_bridgeTokenKey, normalizedToken);
    if (!mounted) return;
    setState(() {
      _bridgeUrl = trimBridgeUrl(uri.toString());
      _bridgeToken = normalizedToken;
      _bridgeError = null;
      _loading = true;
    });
    await _client.useAuthToken(normalizedToken, reconnect: false);
    await _client.useBaseUri(uri);
    await _refreshBridge();
  }

  Future<bool> _testBridgeConnection(String raw, String token) async {
    final uri = normalizeBridgeUri(raw);
    final probe = BridgeClient(baseUri: uri, token: token.trim());
    if (mounted) setState(() => _testingBridge = true);
    try {
      await probe.health();
      return true;
    } finally {
      await probe.close();
      if (mounted) setState(() => _testingBridge = false);
    }
  }

  Future<BridgePairingConfig?> _scanBridgeConfig() async {
    final config = await Navigator.of(context).push<BridgePairingConfig>(
        MaterialPageRoute(
            builder: (_) => const BridgeQrScannerPage(),
            fullscreenDialog: true));
    return config;
  }

  Future<void> _refreshBridge() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _bridgeError = null;
      });
    }
    try {
      await _client.health();
      final results = await Future.wait([
        _client.listWorkspaces(),
        _client.listSessions(),
        _client.listTasks(),
        _client.listCodexHistory()
      ]);
      final workspaces = _applyWorkspaceOrder(results[0] as List<Workspace>);
      final sessions = results[1] as List<AgentSession>;
      final tasks = results[2] as List<AgentTask>;
      final codexHistory = results[3] as List<CodexHistorySession>;
      final selectedWorkspace = _resolveSelectedWorkspace(workspaces);
      final selectedSession =
          _resolveSelectedSession(sessions, selectedWorkspace);
      var files = _workspaceFiles;
      if (selectedWorkspace != null) {
        files = await _client.workspaceTree(selectedWorkspace.id);
      }
      if (!mounted) return;
      setState(() {
        _workspaces = workspaces;
        _sessions = sessions;
        _codexHistory = codexHistory;
        _selectedWorkspace = selectedWorkspace;
        _selectedWorkspaceId = selectedWorkspace?.id;
        _selectedSessionId = selectedSession?.id;
        _workspaceFiles = files;
        _session = selectedSession;
        _tasks
          ..clear()
          ..addAll(tasks);
        _loading = false;
        _bridgeError = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _bridgeError = '$error';
        if (_tasks.isEmpty) _tasks.addAll(initialTasks);
        if (_workspaceFiles.isEmpty) _workspaceFiles = workspaceTree;
      });
    }
  }

  Workspace? _resolveSelectedWorkspace(List<Workspace> workspaces) {
    if (workspaces.isEmpty) return null;
    final wanted = _selectedWorkspaceId ?? _selectedWorkspace?.id;
    if (wanted != null) {
      for (final workspace in workspaces) {
        if (workspace.id == wanted) return workspace;
      }
    }
    return workspaces.first;
  }

  AgentSession? _resolveSelectedSession(
      List<AgentSession> sessions, Workspace? workspace) {
    if (workspace == null) return null;
    final workspaceSessions = sessions
        .where((session) => session.workspaceId == workspace.id)
        .toList();
    if (workspaceSessions.isEmpty) return null;
    final wanted = _selectedSessionId ?? _session?.id;
    if (wanted != null) {
      for (final session in workspaceSessions) {
        if (session.id == wanted) return session;
      }
    }
    return workspaceSessions.first;
  }

  List<Workspace> _applyWorkspaceOrder(List<Workspace> workspaces) {
    final order = _projectOrderIds;
    if (order.isEmpty) return workspaces;
    final indexById = <String, int>{
      for (var i = 0; i < order.length; i++) order[i]: i
    };
    final sorted = [...workspaces]..sort((a, b) {
        final ai = indexById[a.id];
        final bi = indexById[b.id];
        if (ai != null && bi != null) return ai.compareTo(bi);
        if (ai != null) return -1;
        if (bi != null) return 1;
        final at = a.createdAt?.millisecondsSinceEpoch ?? 0;
        final bt = b.createdAt?.millisecondsSinceEpoch ?? 0;
        return bt.compareTo(at);
      });
    return sorted;
  }

  Future<void> _reorderWorkspaces(List<Workspace> ordered) async {
    final ids = ordered.map((workspace) => workspace.id).toList();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_projectOrderIdsKey, ids);
    if (!mounted) return;
    setState(() {
      _projectOrderIds = ids;
      _workspaces = _applyWorkspaceOrder(_workspaces);
    });
  }

  Future<void> _reorderSessions(
      Workspace workspace, List<String> orderedKeys) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
        '$_sessionOrderPrefix${workspace.id}', orderedKeys);
    if (!mounted) return;
    setState(() {
      _sessionOrderIdsByWorkspace = {
        ..._sessionOrderIdsByWorkspace,
        workspace.id: orderedKeys,
      };
    });
  }

  Future<List<CodexTranscriptMessage>> _loadCodexTranscript(String sessionId) =>
      _client.readCodexTranscript(sessionId);

  Future<void> _selectModelSettings(
      {required String model, required String reasoningEffort}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_selectedModelKey, model);
    await prefs.setString(_selectedReasoningKey, reasoningEffort);
    if (!mounted) return;
    setState(() {
      _selectedModel = model;
      _selectedReasoning = reasoningEffort;
    });
  }

  Future<void> _selectControlMode(String controlMode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_selectedControlModeKey, controlMode);
    if (!mounted) return;
    setState(() => _selectedControlMode = controlMode);
  }

  Future<void> _saveDesktopSafetySettings(
      {required bool allowDesktopTakeover,
      required bool restoreForegroundWindow,
      required bool requireIdleForDesktopTakeover}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_allowDesktopTakeoverKey, allowDesktopTakeover);
    await prefs.setBool(_restoreForegroundWindowKey, restoreForegroundWindow);
    await prefs.setBool(
        _requireIdleForDesktopTakeoverKey, requireIdleForDesktopTakeover);
    if (!mounted) return;
    setState(() {
      _allowDesktopTakeover = allowDesktopTakeover;
      _restoreForegroundWindow = restoreForegroundWindow;
      _requireIdleForDesktopTakeover = requireIdleForDesktopTakeover;
      if (!_allowDesktopTakeover && _selectedControlMode == 'desktop') {
        _selectedControlMode = 'cli';
        unawaited(
            prefs.setString(_selectedControlModeKey, _selectedControlMode));
      }
    });
  }

  Future<void> _selectWorkspace(Workspace workspace,
      {bool openProjectsTab = true}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_selectedWorkspaceIdKey, workspace.id);
    if (mounted) {
      setState(() {
        _selectedWorkspace = workspace;
        _selectedWorkspaceId = workspace.id;
        _loading = true;
        _bridgeError = null;
      });
    }
    try {
      final results = await Future.wait([
        _client.workspaceTree(workspace.id),
        _client.listSessions(),
      ]);
      final files = results[0] as List<WorkspaceFile>;
      final sessions = results[1] as List<AgentSession>;
      final selectedSession = _resolveSelectedSession(sessions, workspace);
      if (!mounted) return;
      setState(() {
        _sessions = sessions;
        _workspaceFiles = files;
        _session = selectedSession;
        _selectedSessionId = selectedSession?.id;
        _loading = false;
        if (openProjectsTab) _index = 1;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _bridgeError = '$error';
      });
    }
  }

  Future<AgentSession?> _selectTaskTarget(TaskTargetSelection selection) async {
    if (selection.mode == TaskTargetMode.chat) {
      setState(() => _taskTargetMode = TaskTargetMode.chat);
      return _session;
    }
    final workspace = selection.workspace;
    if (workspace == null) return null;
    setState(() => _taskTargetMode = TaskTargetMode.project);
    await _selectWorkspace(workspace, openProjectsTab: false);
    final selected = await _materializeSessionSelection(selection, workspace);
    return selected;
  }

  Future<AgentSession?> _materializeSessionSelection(
      TaskTargetSelection selection, Workspace workspace) async {
    AgentSession? selected = selection.session;
    final history = selection.historySession;
    if (history != null) {
      selected = _sessions
          .where((session) =>
              session.workspaceId == workspace.id &&
              session.codexSessionId == history.id)
          .firstOrNull;
      selected ??= await _client.createSession(workspace.id,
          title: history.title, codexSessionId: history.id);
    } else if (selection.createNewSession) {
      selected = await _client.createSession(workspace.id,
          title: '手机端会话 ${DateTime.now().month}/${DateTime.now().day}');
    } else if (selected == null || selected.workspaceId != workspace.id) {
      selected = _sessions
          .where((session) => session.workspaceId == workspace.id)
          .firstOrNull;
    }

    final selectedSession = selected;
    if (selectedSession == null) return null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_selectedSessionIdKey, selectedSession.id);
    if (!mounted) return selectedSession;
    setState(() {
      _selectedWorkspace = workspace;
      _selectedWorkspaceId = workspace.id;
      _selectedSessionId = selectedSession.id;
      _session = selectedSession;
      if (_sessions.indexWhere((session) => session.id == selectedSession.id) <
          0) {
        _sessions = [selectedSession, ..._sessions];
      }
    });
    return selectedSession;
  }

  Future<Workspace> _createWorkspace(String name) async {
    final workspace = await _client.createWorkspace(name);
    final prefs = await SharedPreferences.getInstance();
    final ids = [
      workspace.id,
      ..._projectOrderIds.where((id) => id != workspace.id),
    ];
    await prefs.setStringList(_projectOrderIdsKey, ids);
    if (mounted) setState(() => _projectOrderIds = ids);
    await _selectWorkspace(workspace, openProjectsTab: false);
    await _refreshBridge();
    return workspace;
  }

  Future<WorkspaceFilePreview> _loadWorkspaceFilePreview(
      WorkspaceFile file) async {
    final workspace = _selectedWorkspace;
    if (workspace == null) {
      throw const BridgeException('请先选择一个项目。');
    }
    return _client.readWorkspaceFile(workspace.id, file.path);
  }

  Future<void> _addTask(String prompt) async {
    try {
      var session = _session;
      final workspace = _selectedWorkspace ??
          (_workspaces.isEmpty ? null : _workspaces.first);
      if (workspace == null) {
        throw const BridgeException('没有可用的 Bridge 工作区。');
      }
      if (session == null || session.workspaceId != workspace.id) {
        session = await _client.createSession(workspace.id);
      }
      final task = await _client.createTask(session.id, prompt,
          mode: _taskTargetMode == TaskTargetMode.chat ? 'chat' : 'project',
          controlMode: _selectedControlMode,
          model: _selectedModel,
          reasoningEffort: _selectedReasoning,
          allowDesktopTakeover: _allowDesktopTakeover,
          restoreForegroundWindow: _restoreForegroundWindow,
          requireIdleForDesktopTakeover: _requireIdleForDesktopTakeover);
      if (!mounted) return;
      final activeSession = session;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_selectedSessionIdKey, activeSession.id);
      setState(() {
        _session = activeSession;
        _selectedSessionId = activeSession.id;
        if (_sessions.indexWhere((item) => item.id == activeSession.id) < 0) {
          _sessions = [activeSession, ..._sessions];
        }
        _tasks.removeWhere((item) => item.id == task.id);
        _tasks.insert(0, task);
        _index = 0;
        _bridgeError = null;
      });
    } catch (error) {
      final task = AgentTask(
        id: 'local_${DateTime.now().millisecondsSinceEpoch}',
        sessionId: _session?.id,
        title: prompt.length > 28 ? '${prompt.substring(0, 28)}...' : prompt,
        prompt: prompt,
        status: TaskStatus.queued,
        updatedAt: '刚刚',
        summary: 'Bridge 离线时已保存到本地。',
        workspaceId: _taskTargetMode == TaskTargetMode.chat
            ? null
            : _selectedWorkspace?.id,
        mode: _taskTargetMode == TaskTargetMode.chat ? 'chat' : 'project',
        controlMode: _selectedControlMode,
        deliveryState: 'created',
        model: _selectedModel,
        reasoningEffort: _selectedReasoning,
      );
      if (mounted) {
        setState(() {
          _tasks.insert(0, task);
          _bridgeError = '$error';
        });
      }
    }
  }

  Future<void> _cancelTask(AgentTask task) async {
    if (task.id.startsWith('local_')) {
      setState(() => task.status = TaskStatus.cancelled);
      return;
    }
    try {
      final cancelled = await _client.cancelTask(task.id);
      if (mounted) setState(() => task.status = cancelled.status);
    } catch (error) {
      if (mounted) setState(() => _bridgeError = '$error');
    }
  }

  void _onBridgeEvent(BridgeEvent event) {
    if (event.type == 'session.updated') {
      unawaited(_refreshBridge());
      return;
    }
    final taskId = event.payload['taskId'] as String?;
    if (taskId == null || !mounted) return;
    final index = _tasks.indexWhere((task) => task.id == taskId);
    if (index < 0) {
      _refreshBridge();
      return;
    }
    setState(() {
      final task = _tasks[index];
      if (event.type == 'task.status') {
        task.status = taskStatusFromJson(event.payload['status']);
        task.deliveryState =
            event.payload['deliveryState'] as String? ?? task.deliveryState;
        task.controlMode =
            event.payload['controlMode'] as String? ?? task.controlMode;
        task.effectiveControlMode =
            event.payload['effectiveControlMode'] as String? ??
                task.effectiveControlMode;
        task.controlModeDetail =
            event.payload['controlModeDetail'] as String? ??
                task.controlModeDetail;
        task.desktopMayStealFocus =
            event.payload['desktopMayStealFocus'] as bool? ??
                task.desktopMayStealFocus;
        task.updatedAt = '刚刚';
      } else if (event.type == 'task.output') {
        final chunk =
            (event.payload['text'] ?? event.payload['chunk']) as String? ?? '';
        final cleaned = _cleanRuntimeOutput(chunk);
        if (cleaned.isNotEmpty) {
          task.outputLog = '${task.outputLog}$cleaned';
          task.summary = cleaned.trim();
        }
      } else if (event.type == 'artifact.ready') {
        final artifact = event.payload['artifact'];
        final artifactName =
            artifact is Map ? artifact['name'] : event.payload['name'];
        final artifactUrl =
            artifact is Map ? artifact['url'] : event.payload['url'];
        task.artifactName = artifactName as String?;
        task.artifactUrl = artifactUrl as String?;
        task.summary = '产物已就绪：${artifactName ?? '预览'}';
      } else if (event.type == 'task.error') {
        final error = event.payload['error'];
        final message = error is Map ? error['message'] : error;
        final details = error is Map ? error['details'] : null;
        final stderr = details is Map ? details['stderr'] as String? : null;
        final hint = details is Map ? details['hint'] as String? : null;
        task.status = TaskStatus.failed;
        task.summary = '${message ?? '任务执行失败'}';
        task.outputLog = [task.outputLog, task.summary, hint, stderr]
            .whereType<String>()
            .where((line) => line.trim().isNotEmpty)
            .join('\n\n');
      }
    });
  }

  @override
  void dispose() {
    _eventSubscription?.cancel();
    _connectionSubscription?.cancel();
    _client.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pages = [
      TasksPage(
          tasks: _tasks,
          connection: _connection,
          workspaces: _workspaces,
          sessions: _sessions,
          codexHistory: _codexHistory,
          sessionOrderIdsByWorkspace: _sessionOrderIdsByWorkspace,
          selectedWorkspace: _selectedWorkspace,
          selectedSession: _session,
          targetMode: _taskTargetMode,
          selectedControlMode: _selectedControlMode,
          selectedModel: _selectedModel,
          selectedReasoning: _selectedReasoning,
          error: _bridgeError,
          loading: _loading,
          onRefresh: _refreshBridge,
          onAddTask: _addTask,
          onCancelTask: _cancelTask,
          onTargetSelected: _selectTaskTarget,
          onControlModeSelected: _selectControlMode,
          onModelSettingsSelected: _selectModelSettings,
          onWorkspaceOrderChanged: _reorderWorkspaces,
          onSessionOrderChanged: _reorderSessions,
          onCodexTranscriptRequested: _loadCodexTranscript,
          onCreateWorkspace: _createWorkspace,
          onOpenPreview: () => setState(() => _index = 2)),
      ProjectsPage(
          workspaces: _workspaces,
          files: _workspaceFiles,
          workspace: _selectedWorkspace,
          connection: _connection,
          error: _bridgeError,
          loading: _loading,
          onRefresh: _refreshBridge,
          onWorkspaceSelected: _selectWorkspace,
          onWorkspaceCreated: _createWorkspace,
          onFilePreviewRequested: _loadWorkspaceFilePreview),
      PreviewPage(tasks: _tasks, client: _client),
      const DevicesPage(),
      SettingsPage(
          themeMode: widget.themeMode,
          onThemeModeChanged: widget.onThemeModeChanged,
          bridgeUrl: _bridgeUrl,
          bridgeToken: _bridgeToken,
          connection: _connection,
          testingBridge: _testingBridge,
          selectedControlMode: _selectedControlMode,
          allowDesktopTakeover: _allowDesktopTakeover,
          restoreForegroundWindow: _restoreForegroundWindow,
          requireIdleForDesktopTakeover: _requireIdleForDesktopTakeover,
          onBridgeConnectionSaved: _saveBridgeConnection,
          onBridgeConnectionTested: _testBridgeConnection,
          onBridgeQrScanned: _scanBridgeConfig,
          onControlModeSelected: _selectControlMode,
          onDesktopSafetySettingsSaved: _saveDesktopSafetySettings),
    ];
    return Scaffold(
      body: SafeArea(child: IndexedStack(index: _index, children: pages)),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (value) => setState(() => _index = value),
        destinations: const [
          NavigationDestination(
              icon: Icon(Icons.format_list_bulleted),
              selectedIcon: Icon(Icons.playlist_play),
              label: '任务'),
          NavigationDestination(
              icon: Icon(Icons.folder_outlined),
              selectedIcon: Icon(Icons.folder),
              label: '项目'),
          NavigationDestination(
              icon: Icon(Icons.preview_outlined),
              selectedIcon: Icon(Icons.preview),
              label: '预览'),
          NavigationDestination(
              icon: Icon(Icons.devices_outlined),
              selectedIcon: Icon(Icons.devices),
              label: '设备'),
          NavigationDestination(
              icon: Icon(Icons.tune_outlined),
              selectedIcon: Icon(Icons.tune),
              label: '设置'),
        ],
      ),
    );
  }
}

class TasksPage extends StatefulWidget {
  const TasksPage(
      {super.key,
      required this.tasks,
      required this.connection,
      required this.workspaces,
      required this.sessions,
      required this.codexHistory,
      required this.sessionOrderIdsByWorkspace,
      required this.selectedWorkspace,
      required this.selectedSession,
      required this.targetMode,
      required this.selectedControlMode,
      required this.selectedModel,
      required this.selectedReasoning,
      required this.error,
      required this.loading,
      required this.onRefresh,
      required this.onAddTask,
      required this.onCancelTask,
      required this.onTargetSelected,
      required this.onControlModeSelected,
      required this.onModelSettingsSelected,
      required this.onWorkspaceOrderChanged,
      required this.onSessionOrderChanged,
      required this.onCodexTranscriptRequested,
      required this.onCreateWorkspace,
      required this.onOpenPreview});
  final List<AgentTask> tasks;
  final BridgeConnection connection;
  final List<Workspace> workspaces;
  final List<AgentSession> sessions;
  final List<CodexHistorySession> codexHistory;
  final Map<String, List<String>> sessionOrderIdsByWorkspace;
  final Workspace? selectedWorkspace;
  final AgentSession? selectedSession;
  final TaskTargetMode targetMode;
  final String selectedControlMode;
  final String selectedModel;
  final String selectedReasoning;
  final String? error;
  final bool loading;
  final Future<void> Function() onRefresh;
  final Future<void> Function(String) onAddTask;
  final Future<void> Function(AgentTask) onCancelTask;
  final Future<AgentSession?> Function(TaskTargetSelection selection)
      onTargetSelected;
  final Future<void> Function(String controlMode) onControlModeSelected;
  final Future<void> Function(
      {required String model,
      required String reasoningEffort}) onModelSettingsSelected;
  final Future<void> Function(List<Workspace> ordered) onWorkspaceOrderChanged;
  final Future<void> Function(Workspace workspace, List<String> orderedKeys)
      onSessionOrderChanged;
  final Future<List<CodexTranscriptMessage>> Function(String sessionId)
      onCodexTranscriptRequested;
  final Future<Workspace> Function(String name) onCreateWorkspace;
  final VoidCallback onOpenPreview;
  @override
  State<TasksPage> createState() => _TasksPageState();
}

class _TasksPageState extends State<TasksPage> {
  final _controller = TextEditingController();
  final Map<String, String> _drafts = {};
  TaskStatus? _filter;

  @override
  void initState() {
    super.initState();
    _controller.addListener(() {
      _drafts[_draftKeyFor(widget)] = _controller.text;
    });
  }

  @override
  void didUpdateWidget(covariant TasksPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldKey = _draftKeyFor(oldWidget);
    final newKey = _draftKeyFor(widget);
    if (oldKey != newKey) {
      _drafts[oldKey] = _controller.text;
      final nextDraft = _drafts[newKey] ?? '';
      if (_controller.text != nextDraft) {
        _controller.value = TextEditingValue(
            text: nextDraft,
            selection: TextSelection.collapsed(offset: nextDraft.length));
      }
    }
  }

  String _draftKeyFor(TasksPage page) {
    if (page.targetMode == TaskTargetMode.chat) return 'chat';
    return 'workspace:${page.selectedWorkspace?.id ?? 'none'}:'
        'session:${page.selectedSession?.id ?? 'none'}';
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final filtered = widget.tasks
        .where((task) => _filter == null || task.status == _filter)
        .toList();
    final projects = _buildTaskProjects(
        filtered,
        widget.workspaces,
        widget.sessions,
        widget.codexHistory,
        widget.sessionOrderIdsByWorkspace,
        widget.selectedWorkspace,
        widget.selectedSession,
        widget.targetMode,
        includeEmptyProjects: _filter == null);
    return Column(children: [
      _TopBar(
          title: 'AgentLink',
          subtitle: 'Windows 电脑 | ${_connectionLabel(widget.connection)}',
          online: widget.connection == BridgeConnection.connected),
      if (widget.error != null)
        _ErrorBanner(message: widget.error!, onRetry: widget.onRefresh),
      if (widget.loading) const LinearProgressIndicator(minHeight: 2),
      Expanded(child: _buildMessageList(projects)),
      _TaskComposer(
          controller: _controller,
          workspaces: widget.workspaces,
          sessions: widget.sessions,
          codexHistory: widget.codexHistory,
          sessionOrderIdsByWorkspace: widget.sessionOrderIdsByWorkspace,
          selectedWorkspace: widget.selectedWorkspace,
          selectedSession: widget.selectedSession,
          targetMode: widget.targetMode,
          selectedControlMode: widget.selectedControlMode,
          selectedModel: widget.selectedModel,
          selectedReasoning: widget.selectedReasoning,
          onTargetSelected: widget.onTargetSelected,
          onControlModeSelected: widget.onControlModeSelected,
          onModelSettingsSelected: widget.onModelSettingsSelected,
          onCreateWorkspace: widget.onCreateWorkspace,
          onSend: () {
            final value = _controller.text.trim();
            if (value.isEmpty) return;
            widget.onAddTask(value);
            _controller.clear();
            _drafts[_draftKeyFor(widget)] = '';
            FocusScope.of(context).unfocus();
          }),
    ]);
  }

  Widget _buildMessageList(List<_TaskProject> projects) => RefreshIndicator(
      onRefresh: widget.onRefresh,
      child: ReorderableListView.builder(
          buildDefaultDragHandles: false,
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          header:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Text('消息', style: Theme.of(context).textTheme.titleLarge),
              const Spacer(),
              Text(
                  '${widget.tasks.where((t) => t.status == TaskStatus.running).length} 个运行中',
                  style: Theme.of(context).textTheme.labelMedium),
            ]),
            const SizedBox(height: 12),
            SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(children: [
                  _FilterChip(
                      label: '全部',
                      selected: _filter == null,
                      onSelected: () => setState(() => _filter = null)),
                  ...TaskStatus.values.map((status) => _FilterChip(
                      label: status.label,
                      selected: _filter == status,
                      onSelected: () => setState(() => _filter = status))),
                ])),
            const SizedBox(height: 14),
            if (projects.isEmpty)
              _EmptyConversationHint(onCreate: () async {
                final workspace = await _showCreateWorkspaceDialog();
                if (workspace != null) {
                  await widget.onTargetSelected(TaskTargetSelection(
                      mode: TaskTargetMode.project,
                      workspace: workspace,
                      createNewSession: true));
                }
              }),
          ]),
          footer: const SizedBox(height: 84),
          itemCount: projects.length,
          onReorderItem: (oldIndex, newIndex) {
            _reorderProjects(projects, oldIndex, newIndex);
          },
          itemBuilder: (context, index) {
            final project = projects[index];
            return _ProjectRow(
                key: ValueKey(project.key),
                index: index,
                project: project,
                onTap: () => _openProject(project));
          }));

  Future<void> _reorderProjects(
      List<_TaskProject> projects, int oldIndex, int newIndex) async {
    if (oldIndex < 0 || oldIndex >= projects.length) return;
    final ordered = [...projects];
    final moved = ordered.removeAt(oldIndex);
    ordered.insert(newIndex.clamp(0, ordered.length).toInt(), moved);
    await widget.onWorkspaceOrderChanged(ordered
        .where((project) => project.workspace != null)
        .map((project) => project.workspace!)
        .toList());
  }

  Future<Workspace?> _showCreateWorkspaceDialog() =>
      showCreateWorkspaceDialog(context, widget.onCreateWorkspace);

  Future<void> _openProject(_TaskProject project) async {
    if (project.mode == TaskTargetMode.chat) {
      await widget.onTargetSelected(
          const TaskTargetSelection(mode: TaskTargetMode.chat));
      if (!mounted) return;
      final conversation = project.conversations.firstOrNull ??
          _AgentConversation(
              key: 'chat',
              title: '仅对话',
              subtitle: '不写入项目文件',
              updatedAt: '',
              tasks: project.tasks);
      await _showConversation(conversation);
      return;
    }
    if (project.workspace == null) {
      await _showConversation(_AgentConversation(
          key: project.key,
          title: project.title,
          subtitle: project.subtitle,
          updatedAt: project.lastTask?.updatedAt ?? '',
          tasks: project.tasks));
      return;
    }

    final selection = await showModalBottomSheet<TaskTargetSelection>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (context) => _ProjectSessionsSheet(
            project: project,
            onConversationOrderChanged: (orderedKeys) =>
                widget.onSessionOrderChanged(project.workspace!, orderedKeys)));
    if (selection == null) return;
    final session = await widget.onTargetSelected(selection);
    if (!mounted) return;
    final conversation =
        _conversationFromSelection(project, selection, session);
    await _showConversation(conversation);
  }

  _AgentConversation _conversationFromSelection(_TaskProject project,
      TaskTargetSelection selection, AgentSession? materializedSession) {
    if (materializedSession != null) {
      final existing = project.conversations
          .where((conversation) =>
              conversation.session?.id == materializedSession.id ||
              conversation.historySession?.id ==
                  materializedSession.codexSessionId)
          .firstOrNull;
      if (existing != null) return existing.withSession(materializedSession);
      return _AgentConversation(
          key: 'session:${materializedSession.id}',
          title: materializedSession.title,
          subtitle: materializedSession.codexSessionId == null
              ? '手机端新会话，后续消息共享这一段记忆'
              : '已连接电脑端 Codex 历史记忆',
          updatedAt: _relativeIso(materializedSession.createdAt),
          workspace: project.workspace,
          session: materializedSession,
          tasks: const []);
    }
    return project.conversations.firstWhere(
        (conversation) =>
            conversation.session?.id == selection.session?.id ||
            conversation.historySession?.id == selection.historySession?.id,
        orElse: () => project.conversations.first);
  }

  Future<void> _showConversation(_AgentConversation conversation) =>
      showModalBottomSheet<void>(
          context: context,
          isScrollControlled: true,
          showDragHandle: true,
          builder: (context) => _SessionDetailSheet(
              conversation: conversation,
              onCodexTranscriptRequested: widget.onCodexTranscriptRequested,
              onSendPrompt: (prompt) async {
                await widget.onTargetSelected(conversation.selection);
                await widget.onAddTask(prompt);
              },
              onTaskTap: (task) {
                Navigator.pop(context);
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted) _showTask(task);
                });
              }));

  void _showTask(AgentTask task) => showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => _TaskDetail(
          task: task,
          onOpenPreview: () {
            Navigator.pop(context);
            widget.onOpenPreview();
          },
          onCancel: () {
            widget.onCancelTask(task);
            Navigator.pop(context);
          }));
}

class _TaskProject {
  const _TaskProject({
    required this.key,
    required this.title,
    required this.subtitle,
    required this.mode,
    this.workspace,
    this.tasks = const [],
    this.conversations = const [],
  });

  final String key;
  final String title;
  final String subtitle;
  final TaskTargetMode mode;
  final Workspace? workspace;
  final List<AgentTask> tasks;
  final List<_AgentConversation> conversations;

  AgentTask? get lastTask => tasks.isEmpty ? null : tasks.first;
  int get runningCount =>
      tasks.where((task) => task.status == TaskStatus.running).length;
  int get conversationCount => conversations.length;
}

class _AgentConversation {
  const _AgentConversation({
    required this.key,
    required this.title,
    required this.subtitle,
    required this.updatedAt,
    this.workspace,
    this.session,
    this.historySession,
    this.tasks = const [],
  });

  final String key;
  final String title;
  final String subtitle;
  final String updatedAt;
  final Workspace? workspace;
  final AgentSession? session;
  final CodexHistorySession? historySession;
  final List<AgentTask> tasks;

  AgentTask? get lastTask => tasks.isEmpty ? null : tasks.first;
  int get runningCount =>
      tasks.where((task) => task.status == TaskStatus.running).length;
  bool get isHistoryOnly => session == null && historySession != null;

  TaskTargetSelection get selection => TaskTargetSelection(
      mode: workspace == null ? TaskTargetMode.chat : TaskTargetMode.project,
      workspace: workspace,
      session: session,
      historySession: historySession);

  _AgentConversation withSession(AgentSession value) => _AgentConversation(
      key: 'session:${value.id}',
      title: title,
      subtitle: value.codexSessionId == null ? subtitle : '已连接电脑端 Codex 历史记忆',
      updatedAt: updatedAt,
      workspace: workspace,
      session: value,
      historySession: historySession,
      tasks: tasks);
}

List<_TaskProject> _buildTaskProjects(
  List<AgentTask> tasks,
  List<Workspace> workspaces,
  List<AgentSession> sessions,
  List<CodexHistorySession> codexHistory,
  Map<String, List<String>> sessionOrderIdsByWorkspace,
  Workspace? selectedWorkspace,
  AgentSession? selectedSession,
  TaskTargetMode targetMode, {
  required bool includeEmptyProjects,
}) {
  final workspaceById = {
    for (final workspace in workspaces) workspace.id: workspace
  };
  final grouped = <String, List<AgentTask>>{};
  final chatTasks = <AgentTask>[];
  for (final task in tasks) {
    if (task.mode == 'chat') {
      chatTasks.add(task);
      continue;
    }
    final workspaceId = task.workspaceId ?? selectedWorkspace?.id ?? 'unknown';
    grouped.putIfAbsent(workspaceId, () => []).add(task);
  }

  final result = <_TaskProject>[];
  if (chatTasks.isNotEmpty || targetMode == TaskTargetMode.chat) {
    result.add(_TaskProject(
        key: 'chat',
        title: '仅对话',
        subtitle: '不写入项目文件',
        mode: TaskTargetMode.chat,
        tasks: chatTasks,
        conversations: [
          _AgentConversation(
              key: 'chat',
              title: '仅对话',
              subtitle: '不写入项目文件',
              updatedAt: chatTasks.firstOrNull?.updatedAt ?? '',
              tasks: chatTasks)
        ]));
  }

  final projectIds = <String>[];
  for (final workspace in workspaces) {
    final hasTasks = grouped.containsKey(workspace.id);
    final hasSessions =
        sessions.any((session) => session.workspaceId == workspace.id);
    final hasHistory = codexHistory
        .any((history) => _historyBelongsToWorkspace(history, workspace));
    if (includeEmptyProjects ||
        hasTasks ||
        hasSessions ||
        hasHistory ||
        workspace.id == selectedWorkspace?.id ||
        workspace.id == selectedSession?.workspaceId) {
      projectIds.add(workspace.id);
    }
  }
  for (final id in grouped.keys) {
    if (!workspaceById.containsKey(id)) projectIds.add(id);
  }
  if (selectedWorkspace != null && !projectIds.contains(selectedWorkspace.id)) {
    projectIds.add(selectedWorkspace.id);
  }

  final seen = <String>{};
  for (final id in projectIds) {
    if (!seen.add(id)) continue;
    final workspace = workspaceById[id] ??
        (id == selectedWorkspace?.id ? selectedWorkspace : null);
    final projectTasks = grouped[id] ?? const <AgentTask>[];
    final conversations = workspace == null
        ? const <_AgentConversation>[]
        : _buildSessionConversations(workspace, projectTasks, sessions,
            codexHistory, sessionOrderIdsByWorkspace[workspace.id] ?? const []);
    result.add(_TaskProject(
        key: id,
        title: workspace?.name ?? '未归属项目',
        subtitle: workspace?.path ?? '旧任务或本地任务',
        mode: TaskTargetMode.project,
        workspace: workspace,
        tasks: projectTasks,
        conversations: conversations));
  }
  return result;
}

List<_AgentConversation> _buildSessionConversations(
    Workspace workspace,
    List<AgentTask> tasks,
    List<AgentSession> sessions,
    List<CodexHistorySession> codexHistory,
    [List<String> orderKeys = const []]) {
  final tasksBySession = <String, List<AgentTask>>{};
  final legacyTasks = <AgentTask>[];
  for (final task in tasks) {
    final sessionId = task.sessionId;
    if (sessionId == null || sessionId.isEmpty) {
      legacyTasks.add(task);
    } else {
      tasksBySession.putIfAbsent(sessionId, () => []).add(task);
    }
  }

  final workspaceSessions =
      sessions.where((session) => session.workspaceId == workspace.id).toList();
  final seenCodexIds = <String>{};
  final conversations = <_AgentConversation>[];

  for (final session in workspaceSessions) {
    if (session.codexSessionId != null) {
      seenCodexIds.add(session.codexSessionId!);
    }
    final sessionTasks = tasksBySession[session.id] ?? const <AgentTask>[];
    conversations.add(_AgentConversation(
        key: 'session:${session.id}',
        title: session.title,
        subtitle: session.codexSessionId == null
            ? '手机端会话，继续发送会共享这一段记忆'
            : '已连接电脑端 Codex 历史记忆',
        updatedAt: sessionTasks.firstOrNull?.updatedAt ??
            _relativeIso(session.createdAt),
        workspace: workspace,
        session: session,
        tasks: sessionTasks));
  }

  for (final entry in tasksBySession.entries) {
    if (workspaceSessions.any((session) => session.id == entry.key)) continue;
    conversations.add(_AgentConversation(
        key: 'unknown:${entry.key}',
        title: '历史任务记录',
        subtitle: entry.key,
        updatedAt: entry.value.firstOrNull?.updatedAt ?? '',
        workspace: workspace,
        tasks: entry.value));
  }

  if (legacyTasks.isNotEmpty) {
    conversations.add(_AgentConversation(
        key: 'legacy:${workspace.id}',
        title: '旧任务记录',
        subtitle: '升级前创建的任务，没有独立会话 ID',
        updatedAt: legacyTasks.first.updatedAt,
        workspace: workspace,
        tasks: legacyTasks));
  }

  final histories = codexHistory
      .where((history) =>
          history.id.isNotEmpty &&
          !seenCodexIds.contains(history.id) &&
          _historyBelongsToWorkspace(history, workspace))
      .toList();
  for (final history in histories) {
    conversations.add(_AgentConversation(
        key: 'history:${history.id}',
        title: history.title,
        subtitle: '电脑端 Codex 历史，可点开接着聊',
        updatedAt: _relativeIso(history.updatedAt),
        workspace: workspace,
        historySession: history));
  }

  conversations.sort((a, b) {
    final ai = orderKeys.indexOf(a.key);
    final bi = orderKeys.indexOf(b.key);
    if (ai >= 0 && bi >= 0) return ai.compareTo(bi);
    if (ai >= 0) return -1;
    if (bi >= 0) return 1;
    return _conversationScore(b).compareTo(_conversationScore(a));
  });
  return conversations;
}

int _conversationScore(_AgentConversation conversation) {
  final taskTime = conversation.tasks.firstOrNull?.createdAt;
  final raw = taskTime?.isNotEmpty == true
      ? taskTime
      : conversation.session?.createdAt ??
          conversation.historySession?.updatedAt;
  return DateTime.tryParse(raw ?? '')?.millisecondsSinceEpoch ?? 0;
}

bool _historyBelongsToWorkspace(
    CodexHistorySession history, Workspace workspace) {
  final cwd = _normalizePath(history.cwd);
  final root = _normalizePath(workspace.path);
  if (cwd.isEmpty || root.isEmpty) return false;
  return cwd == root || cwd.startsWith('$root/');
}

String _normalizePath(String? path) => (path ?? '')
    .replaceAll('\\', '/')
    .replaceAll(RegExp(r'/+'), '/')
    .replaceAll(RegExp(r'/$'), '')
    .toLowerCase();

String _relativeIso(String? value) {
  final timestamp = DateTime.tryParse(value ?? '');
  if (timestamp == null) return '';
  final minutes = DateTime.now().difference(timestamp.toLocal()).inMinutes;
  if (minutes < 1) return '刚刚';
  if (minutes < 60) return '$minutes 分钟前';
  if (minutes < 60 * 24) return '${minutes ~/ 60} 小时前';
  return '${minutes ~/ (60 * 24)} 天前';
}

class _ProjectRow extends StatelessWidget {
  const _ProjectRow(
      {super.key,
      required this.index,
      required this.project,
      required this.onTap});
  final int index;
  final _TaskProject project;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final lastTask = project.lastTask;
    final hasRunning = project.runningCount > 0;
    final subtitle = lastTask == null
        ? (project.mode == TaskTargetMode.chat
            ? '点这里切换到仅对话'
            : '点进项目后先选择一个 agent 会话')
        : lastTask.summary;
    return ReorderableDelayedDragStartListener(
        index: index,
        child: Card(
            margin: const EdgeInsets.only(bottom: 8),
            child: ListTile(
                minVerticalPadding: 12,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
                leading: CircleAvatar(
                    backgroundColor:
                        Theme.of(context).colorScheme.surfaceContainerHighest,
                    child: Icon(project.mode == TaskTargetMode.chat
                        ? Icons.chat_bubble_outline
                        : Icons.folder_outlined)),
                title: Row(children: [
                  Expanded(
                      child: Text(project.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleMedium)),
                  const SizedBox(width: 8),
                  Text(lastTask?.updatedAt ?? '',
                      style: Theme.of(context).textTheme.labelSmall)
                ]),
                subtitle: Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Row(children: [
                      Expanded(
                          child: Text(subtitle,
                              maxLines: 1, overflow: TextOverflow.ellipsis)),
                      if (project.conversationCount > 0) ...[
                        const SizedBox(width: 8),
                        Text('${project.conversationCount} 个会话',
                            style: Theme.of(context).textTheme.labelSmall)
                      ]
                    ])),
                trailing: hasRunning
                    ? const _SpinningStatusIcon(color: Colors.blue)
                    : const Icon(Icons.chevron_right),
                onTap: onTap)));
  }
}

class _ProjectSessionsSheet extends StatefulWidget {
  const _ProjectSessionsSheet(
      {required this.project, required this.onConversationOrderChanged});
  final _TaskProject project;
  final Future<void> Function(List<String> orderedKeys)
      onConversationOrderChanged;

  @override
  State<_ProjectSessionsSheet> createState() => _ProjectSessionsSheetState();
}

class _ProjectSessionsSheetState extends State<_ProjectSessionsSheet> {
  late final List<_AgentConversation> _conversations = [
    ...widget.project.conversations
  ];

  @override
  Widget build(BuildContext context) => SafeArea(
      child: SizedBox(
          height: MediaQuery.sizeOf(context).height * .78,
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 14),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(widget.project.title,
                          style: Theme.of(context).textTheme.headlineSmall),
                      const SizedBox(height: 4),
                      Text('选择会话后，底部输入框会继续发到这个会话里；长按会话可调整位置。',
                          style: Theme.of(context).textTheme.bodySmall),
                      const SizedBox(height: 12),
                      Card(
                          child: ListTile(
                              leading: const Icon(Icons.add_comment_outlined),
                              title: const Text('新建会话'),
                              subtitle: const Text('在此项目里开一段新的 Codex 记忆'),
                              trailing: const Icon(Icons.add_circle_outline),
                              onTap: () => Navigator.pop(
                                  context,
                                  TaskTargetSelection(
                                      mode: TaskTargetMode.project,
                                      workspace: widget.project.workspace,
                                      createNewSession: true))))
                    ])),
            const Divider(height: 1),
            Expanded(
                child: _conversations.isEmpty
                    ? Center(
                        child: Text('还没有会话，可以先新建一个。',
                            style: Theme.of(context).textTheme.bodyMedium))
                    : ReorderableListView.builder(
                        buildDefaultDragHandles: false,
                        padding: const EdgeInsets.all(12),
                        itemCount: _conversations.length,
                        onReorderItem: _reorder,
                        itemBuilder: (context, index) {
                          final conversation = _conversations[index];
                          return ReorderableDelayedDragStartListener(
                              key: ValueKey(conversation.key),
                              index: index,
                              child: _SessionConversationTile(
                                  conversation: conversation,
                                  onTap: () => Navigator.pop(
                                      context, conversation.selection)));
                        }))
          ])));

  Future<void> _reorder(int oldIndex, int newIndex) async {
    if (oldIndex < 0 || oldIndex >= _conversations.length) return;
    setState(() {
      final moved = _conversations.removeAt(oldIndex);
      _conversations.insert(
          newIndex.clamp(0, _conversations.length).toInt(), moved);
    });
    await widget.onConversationOrderChanged(
        _conversations.map((conversation) => conversation.key).toList());
  }
}

class _SessionConversationTile extends StatelessWidget {
  const _SessionConversationTile(
      {required this.conversation, required this.onTap});
  final _AgentConversation conversation;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final hasRunning = conversation.runningCount > 0;
    final subtitle = conversation.lastTask?.summary ?? conversation.subtitle;
    return Card(
        margin: const EdgeInsets.only(bottom: 8),
        child: ListTile(
            leading: CircleAvatar(
                backgroundColor:
                    Theme.of(context).colorScheme.surfaceContainerHighest,
                child: const Icon(Icons.smart_toy_outlined)),
            title: Row(children: [
              Expanded(
                  child: Text(conversation.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium)),
              const SizedBox(width: 8),
              Text(conversation.updatedAt,
                  style: Theme.of(context).textTheme.labelSmall)
            ]),
            subtitle:
                Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
            trailing: hasRunning
                ? const _SpinningStatusIcon(color: Colors.blue)
                : const Icon(Icons.chevron_right),
            onTap: onTap));
  }
}

class _EmptyConversationHint extends StatelessWidget {
  const _EmptyConversationHint({required this.onCreate});
  final Future<void> Function() onCreate;

  @override
  Widget build(BuildContext context) => Card(
      child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(children: [
            Icon(Icons.forum_outlined,
                size: 42, color: Theme.of(context).colorScheme.outline),
            const SizedBox(height: 10),
            Text('还没有项目会话', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 6),
            Text('新建项目后，任务栏会按“项目 → 会话 → 输入输出”三级展示。',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 12),
            FilledButton.icon(
                onPressed: onCreate,
                icon: const Icon(Icons.create_new_folder_outlined),
                label: const Text('新建项目'))
          ])));
}

class _SessionDetailSheet extends StatefulWidget {
  const _SessionDetailSheet(
      {required this.conversation,
      required this.onCodexTranscriptRequested,
      required this.onSendPrompt,
      required this.onTaskTap});
  final _AgentConversation conversation;
  final Future<List<CodexTranscriptMessage>> Function(String sessionId)
      onCodexTranscriptRequested;
  final Future<void> Function(String prompt) onSendPrompt;
  final ValueChanged<AgentTask> onTaskTap;

  @override
  State<_SessionDetailSheet> createState() => _SessionDetailSheetState();
}

class _SessionDetailSheetState extends State<_SessionDetailSheet> {
  final _scrollController = ScrollController();
  final _composerController = TextEditingController();
  final List<AgentTask> _localEchoTasks = [];
  Timer? _pollTimer;
  String? _codexSessionId;
  List<CodexTranscriptMessage> _messages = const [];
  bool _loadingTranscript = false;
  bool _sendingPrompt = false;
  bool _didInitialScroll = false;
  String? _transcriptError;

  @override
  void initState() {
    super.initState();
    _codexSessionId = widget.conversation.historySession?.id ??
        widget.conversation.session?.codexSessionId;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _scrollToLatest(force: true);
    });
    _reloadTranscript(showLoading: true);
    _pollTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      _reloadTranscript(showLoading: false);
    });
  }

  @override
  void didUpdateWidget(covariant _SessionDetailSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.conversation.key != widget.conversation.key) {
      _codexSessionId = widget.conversation.historySession?.id ??
          widget.conversation.session?.codexSessionId;
      _messages = const [];
      _localEchoTasks.clear();
      _transcriptError = null;
      _didInitialScroll = false;
      unawaited(_reloadTranscript(showLoading: true));
    }
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _scrollController.dispose();
    _composerController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SafeArea(
      child: SizedBox(
          height: MediaQuery.sizeOf(context).height * .86,
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 14),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        Expanded(
                            child: Text(widget.conversation.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style:
                                    Theme.of(context).textTheme.headlineSmall)),
                        IconButton(
                            tooltip: '刷新会话',
                            onPressed: () => _reloadTranscript(),
                            icon: _loadingTranscript
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2))
                                : const Icon(Icons.refresh))
                      ]),
                      const SizedBox(height: 4),
                      Text(widget.conversation.subtitle,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall),
                    ])),
            const Divider(height: 1),
            Expanded(child: _buildConversation(context)),
            const Divider(height: 1),
            _SessionPromptComposer(
                controller: _composerController,
                sending: _sendingPrompt,
                onSend: _sendPrompt),
          ])));

  Widget _buildConversation(BuildContext context) {
    final items = _conversationItems();
    if (_loadingTranscript && items.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (items.isEmpty) {
      return Center(
          child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(_transcriptError ?? '这个会话还没有消息。直接在底部输入框发送即可。',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium)));
    }
    return ListView.builder(
        controller: _scrollController,
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 18),
        itemCount: items.length + (_transcriptError == null ? 0 : 1),
        itemBuilder: (context, index) {
          if (_transcriptError != null && index == 0) {
            return Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _InlineWarning(message: _transcriptError!));
          }
          final item = items[index - (_transcriptError == null ? 0 : 1)];
          return _ConversationBubble(
              item: item,
              onTap: item.task == null
                  ? null
                  : () => widget.onTaskTap(item.task!));
        });
  }

  List<_ConversationItem> _conversationItems() {
    final items = <_ConversationItem>[];
    final transcriptUserTexts = <String>{};
    final transcriptAssistantTexts = <String>{};
    for (var index = 0; index < _messages.length; index += 1) {
      final message = _messages[index];
      final normalized = _normalizeChatText(message.text);
      if (normalized.isEmpty) continue;
      if (message.role == 'user') {
        transcriptUserTexts.add(normalized);
      } else if (message.role == 'assistant') {
        transcriptAssistantTexts.add(normalized);
      }
      items.add(_ConversationItem(
          id: 'msg:${message.id.isEmpty ? index : message.id}',
          role: message.role == 'user' ? 'user' : 'assistant',
          label: message.role == 'user' ? '我' : 'Codex',
          text: message.text,
          timestamp: DateTime.tryParse(message.timestamp),
          sequence: index * 10));
    }

    final taskIds = <String>{};
    final tasks = <AgentTask>[];
    for (final task in [...widget.conversation.tasks, ..._localEchoTasks]) {
      if (!taskIds.add(task.id)) continue;
      tasks.add(task);
    }
    for (var index = 0; index < tasks.length; index += 1) {
      final task = tasks[index];
      final timestamp = DateTime.tryParse(task.createdAt);
      final sequence = 100000 + index * 10;
      final promptText = task.prompt.trim();
      final promptKey = _normalizeChatText(promptText);
      if (promptText.isNotEmpty && !transcriptUserTexts.contains(promptKey)) {
        items.add(_ConversationItem(
            id: 'task:${task.id}:prompt',
            role: 'user',
            label: '我',
            text: promptText,
            timestamp: timestamp,
            sequence: sequence,
            task: task));
      }
      final responseText = _taskResponseText(task);
      final responseKey = _normalizeChatText(responseText ?? '');
      if (responseText != null &&
          responseKey.isNotEmpty &&
          !transcriptAssistantTexts.contains(responseKey)) {
        items.add(_ConversationItem(
            id: 'task:${task.id}:status',
            role: 'assistant',
            label: task.status == TaskStatus.failed ? 'Bridge' : 'Codex',
            text: responseText,
            timestamp: timestamp?.add(const Duration(milliseconds: 1)),
            sequence: sequence + 1,
            task: task,
            statusLabel: task.deliveryLabel,
            spinning: task.status == TaskStatus.running));
      }
    }

    items.sort((a, b) {
      final at = a.timestamp?.millisecondsSinceEpoch;
      final bt = b.timestamp?.millisecondsSinceEpoch;
      if (at != null && bt != null && at != bt) return at.compareTo(bt);
      if (at != null && bt == null) return -1;
      if (at == null && bt != null) return 1;
      return a.sequence.compareTo(b.sequence);
    });
    return items;
  }

  String? _taskResponseText(AgentTask task) {
    if (task.status == TaskStatus.failed) {
      final text = task.outputLog.trim().isNotEmpty
          ? task.outputLog.trim()
          : task.summary.trim();
      return text.isEmpty ? '发送失败，请点开查看详情。' : text;
    }
    if (task.status == TaskStatus.cancelled) return '这条消息已取消。';
    if (task.status == TaskStatus.running || task.deliveryState == 'running') {
      return task.summary.trim().isEmpty ? 'Codex 正在处理…' : task.summary.trim();
    }
    final output = task.outputLog.trim();
    if (output.isNotEmpty && !_isDeliveryOnlyOutput(output)) return output;
    if (task.deliveryState == 'refreshable' ||
        task.deliveryState == 'delivered') {
      return '已发到电脑端，等待 Codex 回复同步到聊天记录。';
    }
    if (task.summary.trim().isNotEmpty && task.status != TaskStatus.completed) {
      return task.summary.trim();
    }
    return null;
  }

  bool _isDeliveryOnlyOutput(String value) {
    final text = value.trim();
    if (text.isEmpty) return true;
    final markers = [
      '手机端投递已完成',
      '正在电脑端 Codex 新建会话',
      '正在把消息发送到电脑端 Codex',
      '检测到该 Codex 会话正在电脑端打开',
      'Codex CLI 不可用，已自动切换',
      '已自动切换为桌面同步模式',
    ];
    return markers.any(text.contains);
  }

  Future<void> _reloadTranscript({bool showLoading = true}) async {
    final sessionId = _codexSessionId;
    if (sessionId == null || sessionId.isEmpty) {
      if (!_didInitialScroll) _scrollToLatest(force: true);
      return;
    }
    final wasNearBottom = _isNearBottom;
    final oldSignature = _messagesSignature(_messages);
    if (showLoading && mounted) setState(() => _loadingTranscript = true);
    try {
      final messages = await widget.onCodexTranscriptRequested(sessionId);
      if (!mounted) return;
      final newSignature = _messagesSignature(messages);
      setState(() {
        _messages = messages;
        _transcriptError = null;
        _loadingTranscript = false;
      });
      if (!_didInitialScroll ||
          (wasNearBottom && oldSignature != newSignature)) {
        _scrollToLatest(force: !_didInitialScroll, animated: _didInitialScroll);
        _didInitialScroll = true;
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _transcriptError = '历史记录暂时还没同步：$error';
        _loadingTranscript = false;
      });
      if (!_didInitialScroll) _scrollToLatest(force: true);
    }
  }

  Future<void> _sendPrompt() async {
    final prompt = _composerController.text.trim();
    if (prompt.isEmpty || _sendingPrompt) return;
    final now = DateTime.now().toUtc().toIso8601String();
    final localTask = AgentTask(
        id: 'local_send_${DateTime.now().microsecondsSinceEpoch}',
        sessionId: widget.conversation.session?.id,
        title: prompt.length > 48 ? '${prompt.substring(0, 48)}...' : prompt,
        prompt: prompt,
        status: TaskStatus.running,
        createdAt: now,
        updatedAt: '刚刚',
        summary: '正在发送到 Codex…',
        workspaceId: widget.conversation.workspace?.id,
        mode: widget.conversation.workspace == null ? 'chat' : 'project',
        deliveryState: 'running');
    setState(() {
      _sendingPrompt = true;
      _localEchoTasks.add(localTask);
    });
    _composerController.clear();
    _scrollToLatest(force: true, animated: true);
    try {
      await widget.onSendPrompt(prompt);
      if (!mounted) return;
      setState(() {
        localTask.status = TaskStatus.completed;
        localTask.deliveryState = 'refreshable';
        localTask.summary = '已发送，等待回复同步到聊天记录。';
      });
      await _reloadTranscript(showLoading: false);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        localTask.status = TaskStatus.failed;
        localTask.deliveryState = 'failed';
        localTask.summary = '发送失败：$error';
        localTask.outputLog = '$error';
      });
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('发送失败：$error')));
    } finally {
      if (mounted) setState(() => _sendingPrompt = false);
      _scrollToLatest(animated: true);
    }
  }

  String _messagesSignature(List<CodexTranscriptMessage> messages) => messages
      .map((message) => '${message.id}|${message.role}|${message.text.length}')
      .join('¦');

  bool get _isNearBottom {
    if (!_scrollController.hasClients) return true;
    final position = _scrollController.position;
    return position.maxScrollExtent - position.pixels < 160;
  }

  void _scrollToLatest({bool force = false, bool animated = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      if (!force && !_isNearBottom) return;
      final target = _scrollController.position.maxScrollExtent;
      if (animated) {
        _scrollController.animateTo(target,
            duration: const Duration(milliseconds: 220), curve: Curves.easeOut);
      } else {
        _scrollController.jumpTo(target);
      }
    });
  }
}

class _ConversationItem {
  const _ConversationItem({
    required this.id,
    required this.role,
    required this.label,
    required this.text,
    required this.sequence,
    this.timestamp,
    this.task,
    this.statusLabel,
    this.spinning = false,
  });

  final String id;
  final String role;
  final String label;
  final String text;
  final int sequence;
  final DateTime? timestamp;
  final AgentTask? task;
  final String? statusLabel;
  final bool spinning;
}

String _normalizeChatText(String value) =>
    value.trim().replaceAll(RegExp(r'\s+'), ' ');

class _SessionPromptComposer extends StatelessWidget {
  const _SessionPromptComposer(
      {required this.controller, required this.sending, required this.onSend});
  final TextEditingController controller;
  final bool sending;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) => Padding(
      padding: EdgeInsets.only(
          left: 12,
          right: 12,
          top: 8,
          bottom: 8 + MediaQuery.viewInsetsOf(context).bottom),
      child: Container(
          padding: const EdgeInsets.only(left: 14, right: 5, top: 3, bottom: 3),
          decoration: BoxDecoration(
              color: Theme.of(context)
                  .colorScheme
                  .surfaceContainerHighest
                  .withValues(alpha: .7),
              borderRadius: BorderRadius.circular(24)),
          child: Row(children: [
            Expanded(
                child: TextField(
                    controller: controller,
                    minLines: 1,
                    maxLines: 4,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => onSend(),
                    decoration: const InputDecoration.collapsed(
                        hintText: '继续给这个会话发消息…'))),
            const SizedBox(width: 6),
            IconButton.filled(
                visualDensity: VisualDensity.compact,
                onPressed: sending ? null : onSend,
                tooltip: '发送到当前会话',
                icon: sending
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.arrow_upward))
          ])));
}

class _InlineWarning extends StatelessWidget {
  const _InlineWarning({required this.message});
  final String message;
  @override
  Widget build(BuildContext context) => Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
          color: Theme.of(context)
              .colorScheme
              .errorContainer
              .withValues(alpha: .6),
          borderRadius: BorderRadius.circular(8)),
      child: Row(children: [
        const Icon(Icons.info_outline, size: 18),
        const SizedBox(width: 8),
        Expanded(
            child: Text(message, style: Theme.of(context).textTheme.bodySmall))
      ]));
}

class _ConversationBubble extends StatelessWidget {
  const _ConversationBubble({required this.item, this.onTap});
  final _ConversationItem item;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final isUser = item.role == 'user';
    final scheme = Theme.of(context).colorScheme;
    final bubble = Container(
        constraints:
            BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * .78),
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
            color: isUser
                ? scheme.primaryContainer
                : scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.only(
                topLeft: const Radius.circular(16),
                topRight: const Radius.circular(16),
                bottomLeft: Radius.circular(isUser ? 16 : 4),
                bottomRight: Radius.circular(isUser ? 4 : 16))),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(mainAxisSize: MainAxisSize.min, children: [
            Text(item.label, style: Theme.of(context).textTheme.labelSmall),
            if (item.spinning) ...[
              const SizedBox(width: 6),
              SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color:
                          isUser ? scheme.onPrimaryContainer : scheme.primary))
            ],
            if (item.statusLabel != null && item.statusLabel!.isNotEmpty) ...[
              const SizedBox(width: 8),
              Flexible(
                  child: Text(item.statusLabel!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color:
                              Theme.of(context).colorScheme.onSurfaceVariant)))
            ]
          ]),
          const SizedBox(height: 4),
          SelectableText(item.text,
              style: Theme.of(context).textTheme.bodyMedium),
        ]));
    return Align(
        alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
        child: onTap == null
            ? bubble
            : InkWell(
                borderRadius: BorderRadius.circular(16),
                onTap: onTap,
                child: bubble));
  }
}

class _TaskDetail extends StatelessWidget {
  const _TaskDetail(
      {required this.task,
      required this.onCancel,
      required this.onOpenPreview});
  final AgentTask task;
  final VoidCallback onCancel;
  final VoidCallback onOpenPreview;
  @override
  Widget build(BuildContext context) => SafeArea(
      child: SizedBox(
          height: MediaQuery.sizeOf(context).height * .78,
          child: Column(children: [
            Expanded(
                child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(children: [
                            _StatusDot(status: task.status),
                            const SizedBox(width: 8),
                            Text(task.deliveryLabel),
                            const SizedBox(width: 8),
                            Expanded(
                                child: Text(task.id,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    textAlign: TextAlign.end,
                                    style: Theme.of(context)
                                        .textTheme
                                        .labelMedium))
                          ]),
                          const SizedBox(height: 16),
                          Text(task.title,
                              style: Theme.of(context).textTheme.headlineSmall),
                          const SizedBox(height: 10),
                          Wrap(spacing: 8, runSpacing: 8, children: [
                            Chip(label: Text(task.model)),
                            Chip(
                                avatar: const Icon(Icons.psychology_outlined,
                                    size: 18),
                                label: Text(
                                    _reasoningLabel(task.reasoningEffort))),
                            Chip(
                                avatar:
                                    const Icon(Icons.route_outlined, size: 18),
                                label: Text(
                                    '${task.controlModeLabel} → ${task.effectiveControlModeLabel}')),
                            if (task.desktopMayStealFocus)
                              const Chip(
                                  avatar: Icon(Icons.desktop_windows_outlined,
                                      size: 18),
                                  label: Text('可能短暂接管桌面')),
                          ]),
                          if (task.controlModeDetail?.isNotEmpty == true) ...[
                            const SizedBox(height: 8),
                            Text(task.controlModeDetail!,
                                style: Theme.of(context).textTheme.bodySmall),
                          ],
                          const SizedBox(height: 16),
                          Text('任务详情',
                              style: Theme.of(context).textTheme.titleSmall),
                          const SizedBox(height: 6),
                          Text(task.prompt),
                          const SizedBox(height: 18),
                          Text('实时输出',
                              style: Theme.of(context).textTheme.titleSmall),
                          const SizedBox(height: 8),
                          Container(
                              width: double.infinity,
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .surfaceContainerHighest,
                                  borderRadius: BorderRadius.circular(8)),
                              child: SelectableText(
                                  task.outputLog.trim().isEmpty
                                      ? task.summary
                                      : task.outputLog,
                                  style: const TextStyle(
                                      fontFamily: 'monospace', fontSize: 12))),
                          if (task.files.isNotEmpty) ...[
                            const SizedBox(height: 18),
                            Text('相关文件',
                                style: Theme.of(context).textTheme.titleSmall),
                            const SizedBox(height: 6),
                            ...task.files.map((file) => ListTile(
                                contentPadding: EdgeInsets.zero,
                                dense: true,
                                leading: const Icon(Icons.description_outlined),
                                title: Text(file,
                                    overflow: TextOverflow.ellipsis)))
                          ],
                        ]))),
            if (task.artifactUrl != null || task.status == TaskStatus.running)
              Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                  child: Row(children: [
                    if (task.artifactUrl != null)
                      Expanded(
                          child: FilledButton.icon(
                              onPressed: onOpenPreview,
                              icon: const Icon(Icons.preview_outlined),
                              label: const Text('打开预览'))),
                    if (task.artifactUrl != null &&
                        task.status == TaskStatus.running)
                      const SizedBox(width: 10),
                    if (task.status == TaskStatus.running)
                      Expanded(
                          child: FilledButton.tonalIcon(
                              onPressed: onCancel,
                              icon: const Icon(Icons.stop_circle_outlined),
                              label: const Text('取消任务'))),
                  ]))
          ])));
}

class ProjectsPage extends StatefulWidget {
  const ProjectsPage(
      {super.key,
      required this.workspaces,
      required this.files,
      required this.workspace,
      required this.connection,
      required this.error,
      required this.loading,
      required this.onRefresh,
      required this.onWorkspaceSelected,
      required this.onWorkspaceCreated,
      required this.onFilePreviewRequested});
  final List<Workspace> workspaces;
  final List<WorkspaceFile> files;
  final Workspace? workspace;
  final BridgeConnection connection;
  final String? error;
  final bool loading;
  final Future<void> Function() onRefresh;
  final Future<void> Function(Workspace workspace) onWorkspaceSelected;
  final Future<Workspace> Function(String name) onWorkspaceCreated;
  final Future<WorkspaceFilePreview> Function(WorkspaceFile file)
      onFilePreviewRequested;
  @override
  State<ProjectsPage> createState() => _ProjectsPageState();
}

class _ProjectsPageState extends State<ProjectsPage> {
  String _query = '';
  final Set<String> _expanded = {'src', 'src/mobile'};
  @override
  Widget build(BuildContext context) => Column(children: [
        _TopBar(
            title: '项目',
            subtitle: widget.workspace == null
                ? '模拟工作区'
                : '${widget.workspace!.name} | ${widget.workspace!.path}',
            online: widget.connection == BridgeConnection.connected),
        if (widget.error != null)
          _ErrorBanner(message: widget.error!, onRetry: widget.onRefresh),
        if (widget.loading) const LinearProgressIndicator(minHeight: 2),
        Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Card(
                child: ListTile(
                    leading: const Icon(Icons.folder_open_outlined),
                    title: Text(widget.workspace?.name ?? '请选择项目'),
                    subtitle: Text(widget.workspace?.path ?? '从电脑端项目列表选择一个工作区',
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                      IconButton(
                          onPressed: _createWorkspace,
                          tooltip: '新建项目',
                          icon: const Icon(Icons.create_new_folder_outlined)),
                      FilledButton.tonal(
                          onPressed: _showWorkspacePicker,
                          child: const Text('切换')),
                    ]),
                    onTap: _showWorkspacePicker))),
        Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: TextField(
                onChanged: (value) =>
                    setState(() => _query = value.toLowerCase()),
                decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search), hintText: '搜索文件'))),
        Expanded(
            child: RefreshIndicator(
                onRefresh: widget.onRefresh,
                child: ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    children: [
                      Text('文件树',
                          style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: 8),
                      ...widget.files.map((file) => _FileTree(
                          file: file,
                          depth: 0,
                          expanded: _expanded,
                          query: _query,
                          onToggle: (path) => setState(() =>
                              _expanded.contains(path)
                                  ? _expanded.remove(path)
                                  : _expanded.add(path)),
                          onPreview: _previewFile)),
                      const Divider(height: 28),
                      Text('最近变更',
                          style: Theme.of(context).textTheme.titleMedium),
                      const ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(Icons.code),
                          title: Text('src/mobile/task_page.dart'),
                          subtitle: Text('2 分钟前'),
                          trailing: Icon(Icons.chevron_right)),
                      const ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(Icons.description_outlined),
                          title: Text('docs/protocol.md'),
                          subtitle: Text('18 分钟前'),
                          trailing: Icon(Icons.chevron_right)),
                    ]))),
      ]);

  Future<void> _showWorkspacePicker() async {
    final selected = await showModalBottomSheet<Workspace>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (context) => WorkspacePickerSheet(
            workspaces: widget.workspaces,
            selected: widget.workspace,
            onCreateWorkspace: widget.onWorkspaceCreated));
    if (selected == null) return;
    await widget.onWorkspaceSelected(selected);
  }

  Future<void> _createWorkspace() async {
    final workspace =
        await showCreateWorkspaceDialog(context, widget.onWorkspaceCreated);
    if (workspace != null) await widget.onWorkspaceSelected(workspace);
  }

  Future<void> _previewFile(WorkspaceFile file) async {
    try {
      final preview = await widget.onFilePreviewRequested(file);
      if (!mounted) return;
      await showModalBottomSheet<void>(
          context: context,
          isScrollControlled: true,
          showDragHandle: true,
          builder: (context) => _FilePreviewSheet(preview: preview));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('预览失败：$error')));
    }
  }
}

class WorkspacePickerSheet extends StatefulWidget {
  const WorkspacePickerSheet(
      {super.key,
      required this.workspaces,
      required this.onCreateWorkspace,
      this.selected});
  final List<Workspace> workspaces;
  final Future<Workspace> Function(String name) onCreateWorkspace;
  final Workspace? selected;

  @override
  State<WorkspacePickerSheet> createState() => _WorkspacePickerSheetState();
}

class _WorkspacePickerSheetState extends State<WorkspacePickerSheet> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final filtered = widget.workspaces
        .where((workspace) =>
            _query.isEmpty ||
            workspace.name.toLowerCase().contains(_query) ||
            workspace.path.toLowerCase().contains(_query))
        .toList();
    return SafeArea(
        child: SizedBox(
            height: MediaQuery.sizeOf(context).height * .82,
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('选择项目',
                            style: Theme.of(context).textTheme.headlineSmall),
                        const SizedBox(height: 6),
                        Text('选择后，新任务会在该项目目录中运行 Codex。',
                            style: Theme.of(context).textTheme.bodySmall),
                        const SizedBox(height: 12),
                        Card(
                            child: ListTile(
                                leading: const Icon(
                                    Icons.create_new_folder_outlined),
                                title: const Text('新建项目'),
                                subtitle: const Text('创建完成后会自动选中并排在上方'),
                                trailing: const Icon(Icons.add_circle_outline),
                                onTap: _createWorkspace)),
                        const SizedBox(height: 12),
                        TextField(
                            onChanged: (value) =>
                                setState(() => _query = value.toLowerCase()),
                            decoration: const InputDecoration(
                                prefixIcon: Icon(Icons.search),
                                hintText: '搜索项目名称或路径')),
                      ])),
              Expanded(
                  child: ListView.builder(
                      itemCount: filtered.length,
                      itemBuilder: (context, index) {
                        final workspace = filtered[index];
                        return ListTile(
                            leading: const Icon(Icons.folder_outlined),
                            title: Text(workspace.name,
                                maxLines: 1, overflow: TextOverflow.ellipsis),
                            subtitle: Text(workspace.path,
                                maxLines: 1, overflow: TextOverflow.ellipsis),
                            trailing: workspace.id == widget.selected?.id
                                ? const Text('当前')
                                : const Icon(Icons.chevron_right),
                            onTap: () => Navigator.pop(context, workspace));
                      })),
            ])));
  }

  Future<void> _createWorkspace() async {
    final workspace =
        await showCreateWorkspaceDialog(context, widget.onCreateWorkspace);
    if (workspace == null || !mounted) return;
    Navigator.pop(context, workspace);
  }
}

class _FileTree extends StatelessWidget {
  const _FileTree(
      {required this.file,
      required this.depth,
      required this.expanded,
      required this.query,
      required this.onToggle,
      required this.onPreview});
  final WorkspaceFile file;
  final int depth;
  final Set<String> expanded;
  final String query;
  final ValueChanged<String> onToggle;
  final ValueChanged<WorkspaceFile> onPreview;
  @override
  Widget build(BuildContext context) {
    final matches = query.isEmpty ||
        file.name.toLowerCase().contains(query) ||
        file.children.any((child) => child.name.toLowerCase().contains(query));
    if (!matches) return const SizedBox.shrink();
    final isFolder = file.kind == FileKind.folder;
    final open = expanded.contains(file.path);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      ListTile(
          dense: true,
          contentPadding: EdgeInsets.only(left: depth * 18.0),
          leading: Icon(
              isFolder
                  ? (open ? Icons.folder_open : Icons.folder_outlined)
                  : _fileIcon(file.kind),
              size: 20),
          title: Text(file.name),
          trailing: isFolder
              ? Icon(
                  open ? Icons.keyboard_arrow_down : Icons.keyboard_arrow_right)
              : null,
          onTap: isFolder ? () => onToggle(file.path) : () => onPreview(file)),
      if (isFolder && open)
        ...file.children.map((child) => _FileTree(
            file: child,
            depth: depth + 1,
            expanded: expanded,
            query: query,
            onToggle: onToggle,
            onPreview: onPreview)),
    ]);
  }
}

Future<Workspace?> showCreateWorkspaceDialog(BuildContext context,
    Future<Workspace> Function(String name) onCreate) async {
  final controller = TextEditingController();
  try {
    return await showModalBottomSheet<Workspace>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (sheetContext) {
          var creating = false;
          return StatefulBuilder(builder: (context, setState) {
            Future<void> submit() async {
              final name = controller.text.trim();
              if (name.isEmpty || creating) return;
              setState(() => creating = true);
              try {
                final workspace = await onCreate(name);
                if (sheetContext.mounted) {
                  Navigator.pop(sheetContext, workspace);
                }
              } catch (error) {
                setState(() => creating = false);
                if (sheetContext.mounted) {
                  ScaffoldMessenger.of(sheetContext)
                      .showSnackBar(SnackBar(content: Text('新建项目失败：$error')));
                }
              }
            }

            return SafeArea(
                child: Padding(
                    padding: EdgeInsets.fromLTRB(20, 4, 20,
                        20 + MediaQuery.viewInsetsOf(context).bottom),
                    child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(children: [
                            CircleAvatar(
                                backgroundColor: Theme.of(context)
                                    .colorScheme
                                    .primaryContainer,
                                child: const Icon(
                                    Icons.create_new_folder_outlined)),
                            const SizedBox(width: 12),
                            Expanded(
                                child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                  Text('新建项目',
                                      style: Theme.of(context)
                                          .textTheme
                                          .headlineSmall),
                                  const SizedBox(height: 3),
                                  Text('会在电脑端 Documents/ChatGPT 下创建项目文件夹。',
                                      style:
                                          Theme.of(context).textTheme.bodySmall)
                                ]))
                          ]),
                          const SizedBox(height: 18),
                          TextField(
                              controller: controller,
                              autofocus: true,
                              textInputAction: TextInputAction.done,
                              onSubmitted: (_) => submit(),
                              decoration: const InputDecoration(
                                  labelText: '项目名称',
                                  hintText: '例如 agentlink-demo',
                                  prefixIcon: Icon(Icons.folder_outlined))),
                          const SizedBox(height: 16),
                          Row(children: [
                            Expanded(
                                child: OutlinedButton(
                                    onPressed: creating
                                        ? null
                                        : () => Navigator.pop(sheetContext),
                                    child: const Text('取消'))),
                            const SizedBox(width: 10),
                            Expanded(
                                child: FilledButton.icon(
                                    onPressed: creating ? null : submit,
                                    icon: creating
                                        ? const SizedBox(
                                            width: 16,
                                            height: 16,
                                            child: CircularProgressIndicator(
                                                strokeWidth: 2))
                                        : const Icon(Icons.check),
                                    label: Text(creating ? '创建中' : '创建')))
                          ])
                        ])));
          });
        });
  } finally {
    controller.dispose();
  }
}

class _FilePreviewSheet extends StatelessWidget {
  const _FilePreviewSheet({required this.preview});
  final WorkspaceFilePreview preview;

  @override
  Widget build(BuildContext context) => SafeArea(
      child: SizedBox(
          height: MediaQuery.sizeOf(context).height * .86,
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            ListTile(
                leading: Icon(_previewIcon(preview.kind)),
                title: Text(preview.name,
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text(
                    '${preview.path} · ${_formatBytes(preview.size)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis)),
            const Divider(height: 1),
            if (preview.kind == 'binary' || preview.kind == 'image')
              Expanded(
                  child: Center(
                      child: Text('当前文件类型暂只显示元数据。',
                          style: Theme.of(context).textTheme.bodyMedium)))
            else
              Expanded(
                  child: SingleChildScrollView(
                      padding: const EdgeInsets.all(16),
                      child: SelectableText(_displayPreviewContent(preview),
                          style: const TextStyle(
                              fontFamily: 'monospace', fontSize: 13))))
          ])));
}

String _displayPreviewContent(WorkspaceFilePreview preview) {
  var content = preview.content;
  if (preview.kind == 'json') {
    try {
      content = const JsonEncoder.withIndent('  ').convert(jsonDecode(content));
    } catch (_) {
      // Keep original text if JSON is incomplete or invalid.
    }
  }
  if (preview.truncated) {
    return '$content\n\n--- 文件超过预览上限，已截断 ---';
  }
  return content.isEmpty ? '空文件' : content;
}

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
}

IconData _previewIcon(String kind) => switch (kind) {
      'json' => Icons.data_object,
      'markdown' => Icons.article_outlined,
      'image' => Icons.image_outlined,
      'binary' => Icons.insert_drive_file_outlined,
      _ => Icons.description_outlined,
    };

class PreviewPage extends StatefulWidget {
  const PreviewPage({super.key, required this.tasks, required this.client});
  final List<AgentTask> tasks;
  final BridgeClient client;
  @override
  State<PreviewPage> createState() => _PreviewPageState();
}

class _PreviewPageState extends State<PreviewPage> {
  var _preview = 0;
  String? _loadedUrl;
  late final WebViewController _webViewController = WebViewController()
    ..setJavaScriptMode(JavaScriptMode.unrestricted);

  List<AgentTask> get _previewableTasks =>
      widget.tasks.where((task) => task.artifactUrl != null).toList();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadCurrentPreview());
  }

  @override
  void didUpdateWidget(covariant PreviewPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadCurrentPreview());
  }

  void _loadCurrentPreview() {
    if (!mounted) return;
    final tasks = _previewableTasks;
    if (tasks.isEmpty) return;
    final index = _preview < tasks.length ? _preview : 0;
    final url =
        widget.client.resolvePreviewUri(tasks[index].artifactUrl!).toString();
    if (_loadedUrl == url) return;
    _loadedUrl = url;
    _webViewController.loadRequest(Uri.parse(url));
  }

  @override
  Widget build(BuildContext context) {
    final tasks = _previewableTasks;
    if (tasks.isEmpty) return _buildEmptyPreview(context);
    final selected = _preview < tasks.length ? _preview : 0;
    final task = tasks[selected];
    return Column(children: [
      _TopBar(
          title: '预览',
          subtitle: '${tasks.length} 个 Bridge 产物可预览',
          online: true),
      Padding(
          padding: const EdgeInsets.all(16),
          child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SegmentedButton<int>(
                  segments: List.generate(
                      tasks.length,
                      (i) => ButtonSegment(
                          value: i,
                          label: Text(tasks[i].artifactName ?? '产物 ${i + 1}'))),
                  selected: {selected},
                  onSelectionChanged: (value) {
                    setState(() => _preview = value.first);
                    _loadCurrentPreview();
                  }))),
      Expanded(
          child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Card(
                  clipBehavior: Clip.antiAlias,
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        ListTile(
                            leading: const Icon(Icons.language_outlined),
                            title: Text(task.title,
                                maxLines: 1, overflow: TextOverflow.ellipsis),
                            subtitle: Text(task.artifactUrl ?? ''),
                            trailing: IconButton(
                                onPressed: _loadCurrentPreview,
                                tooltip: '刷新',
                                icon: const Icon(Icons.refresh))),
                        const Divider(height: 1),
                        Expanded(
                            child:
                                WebViewWidget(controller: _webViewController))
                      ]))))
    ]);
  }

  Widget _buildEmptyPreview(BuildContext context) => Column(children: [
        const _TopBar(title: '预览', subtitle: '暂无 Bridge 产物', online: false),
        Expanded(
            child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: Center(
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.preview_outlined,
                      size: 42, color: Theme.of(context).colorScheme.outline),
                  const SizedBox(height: 12),
                  Text('没有可预览产物',
                      style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 6),
                  Text('普通问答只显示文字返回；以后生成 HTML / 文档时会出现在这里。',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodySmall),
                ]))))
      ]);
}

class DevicesPage extends StatefulWidget {
  const DevicesPage({super.key});
  @override
  State<DevicesPage> createState() => _DevicesPageState();
}

class _DevicesPageState extends State<DevicesPage> {
  var _paired = false;
  @override
  Widget build(BuildContext context) => Column(children: [
        const _TopBar(title: '设备', subtitle: '局域网配对与连接状态', online: true),
        Expanded(
            child: ListView(padding: const EdgeInsets.all(16), children: [
          Text('已配对设备', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 10),
          ...devices.map((device) => Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Card(
                  child: ListTile(
                      contentPadding: const EdgeInsets.all(14),
                      leading: CircleAvatar(
                          backgroundColor: device.isOnline
                              ? Colors.green.withValues(alpha: .16)
                              : Colors.grey.withValues(alpha: .18),
                          child: Icon(Icons.desktop_windows_outlined,
                              color: device.isOnline
                                  ? Colors.green
                                  : Colors.grey)),
                      title: Text(device.name),
                      subtitle: Text(
                          '${device.host}\n${device.lastSeen} | ${device.workspaces} 个工作区'),
                      isThreeLine: true,
                      trailing: device.isOnline
                          ? const _OnlineBadge()
                          : const Icon(Icons.more_vert),
                      onTap: () => ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('${device.name} 详情'))))))),
          if (_paired)
            const Card(
                child: ListTile(
                    leading: Icon(Icons.check_circle, color: Colors.green),
                    title: Text('新设备已添加'),
                    subtitle: Text('等待首次连接'))),
          const SizedBox(height: 14),
          OutlinedButton.icon(
              onPressed: _pair,
              icon: const Icon(Icons.qr_code_scanner),
              label: const Text('扫描二维码配对')),
          const SizedBox(height: 20),
          Text('连接说明', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Text('这里只显示本局域网内已验证的 Windows Bridge 设备。',
              style: Theme.of(context).textTheme.bodySmall),
        ])),
      ]);
  void _pair() => showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
              title: const Text('模拟二维码配对'),
              content: const Text('已读取局域网 Bridge 配对数据。确认后保存设备身份。'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('取消')),
                FilledButton(
                    onPressed: () {
                      setState(() => _paired = true);
                      Navigator.pop(context);
                    },
                    child: const Text('确认配对'))
              ]));
}

class BridgeQrScannerPage extends StatefulWidget {
  const BridgeQrScannerPage({super.key});

  @override
  State<BridgeQrScannerPage> createState() => _BridgeQrScannerPageState();
}

class _BridgeQrScannerPageState extends State<BridgeQrScannerPage> {
  final _controller = MobileScannerController();
  var _handled = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('扫码导入 Bridge')),
        body: Stack(children: [
          MobileScanner(controller: _controller, onDetect: _onDetect),
          Align(
              alignment: Alignment.bottomCenter,
              child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(18),
                  color: Colors.black.withValues(alpha: .55),
                  child: const Text('扫描电脑端 Bridge 启动后显示的二维码，或打开电脑端 /pair 页面扫码。',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white))))
        ]),
      );

  void _onDetect(BarcodeCapture capture) {
    if (_handled) return;
    for (final barcode in capture.barcodes) {
      final raw = barcode.rawValue;
      if (raw == null) continue;
      final config = bridgeConfigFromPairingPayload(raw);
      if (config == null) continue;
      _handled = true;
      Navigator.of(context).pop(config);
      return;
    }
  }
}

class SettingsPage extends StatefulWidget {
  const SettingsPage(
      {super.key,
      required this.themeMode,
      required this.onThemeModeChanged,
      required this.bridgeUrl,
      required this.bridgeToken,
      required this.connection,
      required this.testingBridge,
      required this.selectedControlMode,
      required this.allowDesktopTakeover,
      required this.restoreForegroundWindow,
      required this.requireIdleForDesktopTakeover,
      required this.onBridgeConnectionSaved,
      required this.onBridgeConnectionTested,
      required this.onBridgeQrScanned,
      required this.onControlModeSelected,
      required this.onDesktopSafetySettingsSaved});
  final ThemeMode themeMode;
  final ValueChanged<ThemeMode> onThemeModeChanged;
  final String bridgeUrl;
  final String bridgeToken;
  final BridgeConnection connection;
  final bool testingBridge;
  final String selectedControlMode;
  final bool allowDesktopTakeover;
  final bool restoreForegroundWindow;
  final bool requireIdleForDesktopTakeover;
  final Future<void> Function(String url, String token) onBridgeConnectionSaved;
  final Future<bool> Function(String url, String token)
      onBridgeConnectionTested;
  final Future<BridgePairingConfig?> Function() onBridgeQrScanned;
  final Future<void> Function(String controlMode) onControlModeSelected;
  final Future<void> Function(
          {required bool allowDesktopTakeover,
          required bool restoreForegroundWindow,
          required bool requireIdleForDesktopTakeover})
      onDesktopSafetySettingsSaved;
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  var _notifications = true;
  var _autoReconnect = true;
  late bool _allowDesktopTakeover;
  late bool _restoreForegroundWindow;
  late bool _requireIdleForDesktopTakeover;
  late final TextEditingController _bridgeController;
  late final TextEditingController _tokenController;

  @override
  void initState() {
    super.initState();
    _bridgeController = TextEditingController(text: widget.bridgeUrl);
    _tokenController = TextEditingController(text: widget.bridgeToken);
    _allowDesktopTakeover = widget.allowDesktopTakeover;
    _restoreForegroundWindow = widget.restoreForegroundWindow;
    _requireIdleForDesktopTakeover = widget.requireIdleForDesktopTakeover;
  }

  @override
  void didUpdateWidget(covariant SettingsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.bridgeUrl != widget.bridgeUrl &&
        _bridgeController.text != widget.bridgeUrl) {
      _bridgeController.text = widget.bridgeUrl;
    }
    if (oldWidget.bridgeToken != widget.bridgeToken &&
        _tokenController.text != widget.bridgeToken) {
      _tokenController.text = widget.bridgeToken;
    }
    if (oldWidget.allowDesktopTakeover != widget.allowDesktopTakeover ||
        oldWidget.restoreForegroundWindow != widget.restoreForegroundWindow ||
        oldWidget.requireIdleForDesktopTakeover !=
            widget.requireIdleForDesktopTakeover) {
      _allowDesktopTakeover = widget.allowDesktopTakeover;
      _restoreForegroundWindow = widget.restoreForegroundWindow;
      _requireIdleForDesktopTakeover = widget.requireIdleForDesktopTakeover;
    }
  }

  @override
  void dispose() {
    _bridgeController.dispose();
    _tokenController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(children: [
        _TopBar(
            title: '设置',
            subtitle:
                'AgentLink Android 客户端 | ${_connectionLabel(widget.connection)}',
            online: widget.connection == BridgeConnection.connected),
        Expanded(
            child: ListView(padding: const EdgeInsets.all(16), children: [
          Text('外观', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Card(
              child: ListTile(
                  leading: const Icon(Icons.dark_mode_outlined),
                  title: const Text('主题'),
                  trailing: DropdownButton<ThemeMode>(
                      value: widget.themeMode,
                      underline: const SizedBox(),
                      items: const [
                        DropdownMenuItem(
                            value: ThemeMode.system, child: Text('跟随系统')),
                        DropdownMenuItem(
                            value: ThemeMode.light, child: Text('浅色')),
                        DropdownMenuItem(
                            value: ThemeMode.dark, child: Text('深色'))
                      ],
                      onChanged: (value) {
                        if (value != null) widget.onThemeModeChanged(value);
                      }))),
          const SizedBox(height: 20),
          Text('连接', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Card(
              child: Column(children: [
            Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
                child: TextField(
                    controller: _bridgeController,
                    keyboardType: TextInputType.url,
                    decoration: const InputDecoration(
                        labelText: 'Bridge / Relay 地址',
                        hintText: 'https://agentlink-relay.onrender.com',
                        prefixIcon: Icon(Icons.link)))),
            Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: TextField(
                    controller: _tokenController,
                    obscureText: true,
                    decoration: const InputDecoration(
                        labelText: '访问令牌（云中继需要）',
                        hintText: 'AGENTLINK_RELAY_SECRET',
                        prefixIcon: Icon(Icons.key_outlined)))),
            Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Wrap(spacing: 8, runSpacing: 8, children: [
                  FilledButton.icon(
                      onPressed: () => _saveBridgeUrl(context),
                      icon: const Icon(Icons.save_outlined),
                      label: const Text('保存并连接')),
                  OutlinedButton.icon(
                      onPressed: widget.testingBridge
                          ? null
                          : () => _testBridgeUrl(context),
                      icon: widget.testingBridge
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.wifi_find_outlined),
                      label: const Text('测试连接')),
                  OutlinedButton.icon(
                      onPressed: () => _scanBridgeUrl(context),
                      icon: const Icon(Icons.qr_code_scanner),
                      label: const Text('扫码导入')),
                ])),
            ListTile(
                leading: Icon(widget.connection == BridgeConnection.connected
                    ? Icons.cloud_done_outlined
                    : Icons.cloud_off_outlined),
                title: const Text('当前连接状态'),
                subtitle: Text(_connectionLabel(widget.connection)),
                trailing: _OnlineBadge(
                    online: widget.connection == BridgeConnection.connected)),
            const Divider(height: 1),
            SwitchListTile(
                secondary: const Icon(Icons.sync),
                title: const Text('自动重连'),
                subtitle: const Text('网络恢复后同步缺失事件'),
                value: _autoReconnect,
                onChanged: (value) => setState(() => _autoReconnect = value)),
            const Divider(height: 1),
            ListTile(
                leading: const Icon(Icons.verified_user_outlined),
                title: const Text('设备身份'),
                subtitle: Text(_tokenController.text.trim().isEmpty
                    ? '未配置访问令牌，适合局域网或测试 Relay'
                    : '访问令牌已保存，可连接云中继'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => ScaffoldMessenger.of(context)
                    .showSnackBar(const SnackBar(content: Text('设备身份详情'))))
          ])),
          const SizedBox(height: 20),
          Text('控制', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Card(
              child: Column(children: [
            ListTile(
                leading: const Icon(Icons.route_outlined),
                title: const Text('默认控制模式'),
                subtitle: Text(controlModeLabelOf(widget.selectedControlMode)),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _selectControlMode(context)),
            const Divider(height: 1),
            SwitchListTile(
                secondary: const Icon(Icons.desktop_windows_outlined),
                title: const Text('允许桌面接管'),
                subtitle: const Text('后台冲突或手动选择桌面模式时，允许短暂切到 Codex 窗口'),
                value: _allowDesktopTakeover,
                onChanged: (value) => _saveDesktopSafety(
                    allowDesktopTakeover: value,
                    restoreForegroundWindow: _restoreForegroundWindow,
                    requireIdleForDesktopTakeover:
                        _requireIdleForDesktopTakeover)),
            const Divider(height: 1),
            SwitchListTile(
                secondary: const Icon(Icons.keyboard_return_outlined),
                title: const Text('接管后恢复原窗口'),
                subtitle: const Text('发送后尽量切回你原本正在使用的窗口'),
                value: _restoreForegroundWindow,
                onChanged: _allowDesktopTakeover
                    ? (value) => _saveDesktopSafety(
                        allowDesktopTakeover: _allowDesktopTakeover,
                        restoreForegroundWindow: value,
                        requireIdleForDesktopTakeover:
                            _requireIdleForDesktopTakeover)
                    : null),
            const Divider(height: 1),
            SwitchListTile(
                secondary: const Icon(Icons.hourglass_bottom_outlined),
                title: const Text('仅在电脑空闲时接管'),
                subtitle: const Text('电脑 30 秒无输入时才允许桌面接管，减少打断当前操作'),
                value: _requireIdleForDesktopTakeover,
                onChanged: _allowDesktopTakeover
                    ? (value) => _saveDesktopSafety(
                        allowDesktopTakeover: _allowDesktopTakeover,
                        restoreForegroundWindow: _restoreForegroundWindow,
                        requireIdleForDesktopTakeover: value)
                    : null),
          ])),
          const SizedBox(height: 20),
          Text('通知', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Card(
              child: SwitchListTile(
                  secondary: const Icon(Icons.notifications_outlined),
                  title: const Text('任务完成提醒'),
                  subtitle: const Text('任务完成或失败时通知'),
                  value: _notifications,
                  onChanged: (value) =>
                      setState(() => _notifications = value))),
          const SizedBox(height: 20),
          Text('关于', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          const Card(
              child: ListTile(
                  leading: Icon(Icons.info_outline),
                  title: Text('AgentLink'),
                  subtitle: Text('0.1.0 | Flutter UI 原型'))),
        ])),
      ]);

  Future<void> _selectControlMode(BuildContext context) async {
    final selected = await showModalBottomSheet<String>(
        context: context,
        showDragHandle: true,
        builder: (context) =>
            ControlModeSheet(selectedMode: widget.selectedControlMode));
    if (selected == null || !context.mounted) return;
    await widget.onControlModeSelected(selected);
  }

  Future<void> _saveDesktopSafety(
      {required bool allowDesktopTakeover,
      required bool restoreForegroundWindow,
      required bool requireIdleForDesktopTakeover}) async {
    setState(() {
      _allowDesktopTakeover = allowDesktopTakeover;
      _restoreForegroundWindow = restoreForegroundWindow;
      _requireIdleForDesktopTakeover = requireIdleForDesktopTakeover;
    });
    await widget.onDesktopSafetySettingsSaved(
        allowDesktopTakeover: allowDesktopTakeover,
        restoreForegroundWindow: restoreForegroundWindow,
        requireIdleForDesktopTakeover: requireIdleForDesktopTakeover);
  }

  Future<void> _saveBridgeUrl(BuildContext context) async {
    try {
      await widget.onBridgeConnectionSaved(
          _bridgeController.text, _tokenController.text);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Bridge / Relay 连接已保存')));
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('保存失败：$error')));
    }
  }

  Future<void> _testBridgeUrl(BuildContext context) async {
    try {
      final ok = await widget.onBridgeConnectionTested(
          _bridgeController.text, _tokenController.text);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(ok ? '连接测试成功' : '连接测试失败')));
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('测试失败：$error')));
    }
  }

  Future<void> _scanBridgeUrl(BuildContext context) async {
    final config = await widget.onBridgeQrScanned();
    if (config == null) return;
    _bridgeController.text = trimBridgeUrl(config.uri.toString());
    if (config.token?.isNotEmpty == true) _tokenController.text = config.token!;
    if (!context.mounted) return;
    await _saveBridgeUrl(context);
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar(
      {required this.title, required this.subtitle, required this.online});
  final String title;
  final String subtitle;
  final bool online;
  @override
  Widget build(BuildContext context) => Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
      child: Row(children: [
        Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 3),
          Text(subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall)
        ])),
        const SizedBox(width: 12),
        _OnlineBadge(online: online)
      ]));
}

class _OnlineBadge extends StatelessWidget {
  const _OnlineBadge({this.online = true});
  final bool online;
  @override
  Widget build(BuildContext context) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
          color: (online ? Colors.green : Colors.grey).withValues(alpha: .14),
          borderRadius: BorderRadius.circular(6)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(online ? Icons.circle : Icons.circle_outlined,
            size: 9, color: online ? Colors.green : Colors.grey),
        const SizedBox(width: 5),
        Text(online ? '在线' : '离线',
            style: Theme.of(context).textTheme.labelSmall)
      ]));
}

class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.status});
  final TaskStatus status;
  @override
  Widget build(BuildContext context) {
    final color = switch (status) {
      TaskStatus.running => Colors.blue,
      TaskStatus.queued => Colors.orange,
      TaskStatus.completed => Colors.green,
      TaskStatus.failed => Colors.red,
      TaskStatus.cancelled => Colors.grey
    };
    if (status == TaskStatus.running) return _SpinningStatusIcon(color: color);
    return Icon(Icons.circle, color: color, size: 14);
  }
}

class _SpinningStatusIcon extends StatefulWidget {
  const _SpinningStatusIcon({required this.color});
  final Color color;

  @override
  State<_SpinningStatusIcon> createState() => _SpinningStatusIconState();
}

class _SpinningStatusIconState extends State<_SpinningStatusIcon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 900))
    ..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RotationTransition(
      turns: _controller,
      child: Icon(Icons.sync, color: widget.color, size: 16));
}

class _FilterChip extends StatelessWidget {
  const _FilterChip(
      {required this.label, required this.selected, required this.onSelected});
  final String label;
  final bool selected;
  final VoidCallback onSelected;
  @override
  Widget build(BuildContext context) => Padding(
      padding: const EdgeInsets.only(right: 8),
      child: FilterChip(
          label: Text(label),
          selected: selected,
          onSelected: (_) => onSelected()));
}

class _TaskComposer extends StatelessWidget {
  const _TaskComposer(
      {required this.controller,
      required this.workspaces,
      required this.sessions,
      required this.codexHistory,
      required this.sessionOrderIdsByWorkspace,
      required this.selectedWorkspace,
      required this.selectedSession,
      required this.targetMode,
      required this.selectedControlMode,
      required this.selectedModel,
      required this.selectedReasoning,
      required this.onTargetSelected,
      required this.onControlModeSelected,
      required this.onModelSettingsSelected,
      required this.onCreateWorkspace,
      required this.onSend});
  final TextEditingController controller;
  final List<Workspace> workspaces;
  final List<AgentSession> sessions;
  final List<CodexHistorySession> codexHistory;
  final Map<String, List<String>> sessionOrderIdsByWorkspace;
  final Workspace? selectedWorkspace;
  final AgentSession? selectedSession;
  final TaskTargetMode targetMode;
  final String selectedControlMode;
  final String selectedModel;
  final String selectedReasoning;
  final Future<AgentSession?> Function(TaskTargetSelection selection)
      onTargetSelected;
  final Future<void> Function(String controlMode) onControlModeSelected;
  final Future<void> Function(
      {required String model,
      required String reasoningEffort}) onModelSettingsSelected;
  final Future<Workspace> Function(String name) onCreateWorkspace;
  final VoidCallback onSend;
  @override
  Widget build(BuildContext context) => Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
      decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          border:
              Border(top: BorderSide(color: Theme.of(context).dividerColor))),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Row(children: [
          Expanded(
              child: ActionChip(
                  avatar: Icon(
                      targetMode == TaskTargetMode.chat
                          ? Icons.chat_bubble_outline
                          : Icons.folder_outlined,
                      size: 18),
                  label: SizedBox(
                      width: double.infinity,
                      child: Text(_targetLabel,
                          maxLines: 1, overflow: TextOverflow.ellipsis)),
                  onPressed: () => _showTargetPicker(context))),
          const SizedBox(width: 8),
          ActionChip(
              avatar: const Icon(Icons.route_outlined, size: 18),
              label: Text(controlModeLabelOf(selectedControlMode)),
              onPressed: () => _showControlModeSettings(context)),
        ]),
        const SizedBox(height: 8),
        Container(
            padding:
                const EdgeInsets.only(left: 14, right: 5, top: 3, bottom: 3),
            decoration: BoxDecoration(
                color: Theme.of(context)
                    .colorScheme
                    .surfaceContainerHighest
                    .withValues(alpha: .65),
                borderRadius: BorderRadius.circular(24)),
            child: Row(children: [
              Expanded(
                  child: TextField(
                      controller: controller,
                      minLines: 1,
                      maxLines: 4,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => onSend(),
                      decoration: const InputDecoration.collapsed(
                          hintText: '给 Codex 描述一个任务……'))),
              const SizedBox(width: 6),
              InkWell(
                  borderRadius: BorderRadius.circular(18),
                  onTap: () => _showModelSettings(context),
                  child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 9, vertical: 7),
                      decoration: BoxDecoration(
                          color: Theme.of(context)
                              .colorScheme
                              .surface
                              .withValues(alpha: .75),
                          borderRadius: BorderRadius.circular(18)),
                      child: Text(
                          '${_modelShortLabel(selectedModel)} · '
                          '${_reasoningShortLabel(selectedReasoning)}',
                          style: Theme.of(context).textTheme.labelSmall))),
              const SizedBox(width: 6),
              IconButton.filled(
                  visualDensity: VisualDensity.compact,
                  onPressed: onSend,
                  tooltip: '发送任务',
                  icon: const Icon(Icons.arrow_upward))
            ]))
      ]));

  String get _targetLabel => targetMode == TaskTargetMode.chat
      ? '仅对话 · 不写入文件'
      : '项目 · ${selectedWorkspace?.name ?? '请选择项目'}'
          '${selectedSession == null ? ' / 请选择会话' : ' / ${selectedSession!.title}'}';

  Future<void> _showTargetPicker(BuildContext context) async {
    final selected = await showModalBottomSheet<TaskTargetSelection>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (context) => TaskTargetPickerSheet(
            workspaces: workspaces,
            sessions: sessions,
            codexHistory: codexHistory,
            sessionOrderIdsByWorkspace: sessionOrderIdsByWorkspace,
            selectedWorkspace: selectedWorkspace,
            selectedSession: selectedSession,
            targetMode: targetMode,
            onCreateWorkspace: onCreateWorkspace));
    if (selected != null) await onTargetSelected(selected);
  }

  Future<void> _showControlModeSettings(BuildContext context) async {
    final selected = await showModalBottomSheet<String>(
        context: context,
        showDragHandle: true,
        builder: (context) =>
            ControlModeSheet(selectedMode: selectedControlMode));
    if (selected != null) await onControlModeSelected(selected);
  }

  Future<void> _showModelSettings(BuildContext context) async {
    final selected = await showModalBottomSheet<ModelSettingsSelection>(
        context: context,
        showDragHandle: true,
        builder: (context) => ModelSettingsSheet(
            selectedModel: selectedModel,
            selectedReasoning: selectedReasoning));
    if (selected != null) {
      await onModelSettingsSelected(
          model: selected.model, reasoningEffort: selected.reasoningEffort);
    }
  }
}

class ModelSettingsSelection {
  const ModelSettingsSelection(
      {required this.model, required this.reasoningEffort});
  final String model;
  final String reasoningEffort;
}

class ControlModeSheet extends StatelessWidget {
  const ControlModeSheet({super.key, required this.selectedMode});
  final String selectedMode;

  @override
  Widget build(BuildContext context) => SafeArea(
      child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
          child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('控制模式', style: Theme.of(context).textTheme.headlineSmall),
                const SizedBox(height: 6),
                Text('自动模式会先走后台 Codex；只有遇到冲突时才接管桌面。',
                    style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(height: 16),
                ...controlModeOptions.map((mode) => Card(
                    child: ListTile(
                        selected: selectedMode == mode,
                        leading: Icon(_controlModeIcon(mode)),
                        title: Text(controlModeLabelOf(mode)),
                        subtitle: Text(_controlModeDescription(mode)),
                        trailing: selectedMode == mode
                            ? const Icon(Icons.check_circle)
                            : const Icon(Icons.chevron_right),
                        onTap: () => Navigator.pop(context, mode)))),
              ])));
}

String _controlModeDescription(String mode) => switch (mode) {
      'auto' => '推荐：不冲突时后台执行，冲突时切换到电脑端当前会话。',
      'cli' => '只走后台 Codex，不打扰电脑；遇到打开中的同一会话会提示失败。',
      'desktop' => '直接操作电脑端 Codex 当前窗口，会短暂切换焦点。',
      _ => mode,
    };

IconData _controlModeIcon(String mode) => switch (mode) {
      'auto' => Icons.auto_mode,
      'cli' => Icons.terminal,
      'desktop' => Icons.desktop_windows_outlined,
      _ => Icons.route_outlined,
    };

class ModelSettingsSheet extends StatefulWidget {
  const ModelSettingsSheet(
      {super.key,
      required this.selectedModel,
      required this.selectedReasoning});
  final String selectedModel;
  final String selectedReasoning;

  @override
  State<ModelSettingsSheet> createState() => _ModelSettingsSheetState();
}

class _ModelSettingsSheetState extends State<ModelSettingsSheet> {
  late String _model = widget.selectedModel;
  late String _reasoning = widget.selectedReasoning;

  @override
  Widget build(BuildContext context) => SafeArea(
      child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
          child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('模型和思考等级',
                    style: Theme.of(context).textTheme.headlineSmall),
                const SizedBox(height: 6),
                Text('这里会随任务一起传给电脑端 Codex。',
                    style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(height: 18),
                Text('模型', style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 8),
                Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: _modelOptions
                        .map((model) => ChoiceChip(
                            label: Text(_modelShortLabel(model)),
                            selected: _model == model,
                            onSelected: (_) => setState(() => _model = model)))
                        .toList()),
                const SizedBox(height: 18),
                Text('思考等级', style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 8),
                Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: _reasoningOptions
                        .map((reasoning) => ChoiceChip(
                            label: Text(_reasoningLabel(reasoning)),
                            selected: _reasoning == reasoning,
                            onSelected: (_) =>
                                setState(() => _reasoning = reasoning)))
                        .toList()),
                const SizedBox(height: 20),
                SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                        onPressed: () => Navigator.pop(
                            context,
                            ModelSettingsSelection(
                                model: _model, reasoningEffort: _reasoning)),
                        child: const Text('保存选择')))
              ])));
}

class TaskTargetPickerSheet extends StatefulWidget {
  const TaskTargetPickerSheet(
      {super.key,
      required this.workspaces,
      required this.sessions,
      required this.codexHistory,
      required this.sessionOrderIdsByWorkspace,
      required this.selectedWorkspace,
      required this.selectedSession,
      required this.targetMode,
      required this.onCreateWorkspace});
  final List<Workspace> workspaces;
  final List<AgentSession> sessions;
  final List<CodexHistorySession> codexHistory;
  final Map<String, List<String>> sessionOrderIdsByWorkspace;
  final Workspace? selectedWorkspace;
  final AgentSession? selectedSession;
  final TaskTargetMode targetMode;
  final Future<Workspace> Function(String name) onCreateWorkspace;

  @override
  State<TaskTargetPickerSheet> createState() => _TaskTargetPickerSheetState();
}

class _TaskTargetPickerSheetState extends State<TaskTargetPickerSheet> {
  String _query = '';
  Workspace? _drillWorkspace;

  @override
  Widget build(BuildContext context) {
    final workspace = _drillWorkspace;
    return SafeArea(
        child: SizedBox(
            height: MediaQuery.sizeOf(context).height * .78,
            child: workspace == null
                ? _buildProjectStep(context)
                : _buildSessionStep(context, workspace)));
  }

  Widget _buildProjectStep(BuildContext context) {
    final filtered = widget.workspaces
        .where((workspace) =>
            _query.isEmpty ||
            workspace.name.toLowerCase().contains(_query) ||
            workspace.path.toLowerCase().contains(_query))
        .toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('发送到哪里？', style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 6),
            Text('先选项目，再选会话；也可以选择仅对话。',
                style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 12),
            Card(
                child: ListTile(
                    leading: const Icon(Icons.chat_bubble_outline),
                    title: const Text('仅对话'),
                    subtitle: const Text('只回答问题，不写入项目文件'),
                    onTap: () => Navigator.pop(context,
                        const TaskTargetSelection(mode: TaskTargetMode.chat)))),
            const SizedBox(height: 12),
            Card(
                child: ListTile(
                    leading: const Icon(Icons.create_new_folder_outlined),
                    title: const Text('新建项目'),
                    subtitle: const Text('创建后继续选择会话'),
                    trailing: const Icon(Icons.add_circle_outline),
                    onTap: _createWorkspace)),
            const SizedBox(height: 12),
            TextField(
                onChanged: (value) =>
                    setState(() => _query = value.toLowerCase()),
                decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search), hintText: '搜索项目')),
          ])),
      Expanded(
          child: ListView.builder(
              itemCount: filtered.length,
              itemBuilder: (context, index) {
                final workspace = filtered[index];
                return ListTile(
                    leading: const Icon(Icons.folder_outlined),
                    title: Text(workspace.name,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text(workspace.path,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => setState(() => _drillWorkspace = workspace));
              }))
    ]);
  }

  Widget _buildSessionStep(BuildContext context, Workspace workspace) {
    final projectTasks = <AgentTask>[];
    final conversations = _buildSessionConversations(
        workspace,
        projectTasks,
        widget.sessions,
        widget.codexHistory,
        widget.sessionOrderIdsByWorkspace[workspace.id] ?? const []);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
          padding: const EdgeInsets.fromLTRB(8, 4, 20, 12),
          child: Row(children: [
            IconButton(
                onPressed: () => setState(() => _drillWorkspace = null),
                icon: const Icon(Icons.arrow_back)),
            Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  Text(workspace.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.headlineSmall),
                  const SizedBox(height: 4),
                  Text('选择要继续的 agent 会话，或新建会话',
                      style: Theme.of(context).textTheme.bodySmall),
                ]))
          ])),
      Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Card(
              child: ListTile(
                  leading: const Icon(Icons.add_comment_outlined),
                  title: const Text('新建会话'),
                  subtitle: const Text('在此项目里开一段新的 Codex 记忆'),
                  trailing: const Icon(Icons.add_circle_outline),
                  onTap: () => Navigator.pop(
                      context,
                      TaskTargetSelection(
                          mode: TaskTargetMode.project,
                          workspace: workspace,
                          createNewSession: true))))),
      const SizedBox(height: 8),
      Expanded(
          child: conversations.isEmpty
              ? Center(
                  child: Text('还没有历史会话，可以先新建一个。',
                      style: Theme.of(context).textTheme.bodyMedium))
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  itemCount: conversations.length,
                  itemBuilder: (context, index) {
                    final conversation = conversations[index];
                    return _SessionConversationTile(
                        conversation: conversation,
                        onTap: () =>
                            Navigator.pop(context, conversation.selection));
                  }))
    ]);
  }

  Future<void> _createWorkspace() async {
    final workspace =
        await showCreateWorkspaceDialog(context, widget.onCreateWorkspace);
    if (workspace == null || !mounted) return;
    setState(() => _drillWorkspace = workspace);
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message, required this.onRetry});
  final String message;
  final Future<void> Function() onRetry;
  @override
  Widget build(BuildContext context) => Material(
      color: Theme.of(context).colorScheme.errorContainer,
      child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
          child: Row(children: [
            Icon(Icons.cloud_off_outlined,
                size: 18,
                color: Theme.of(context).colorScheme.onErrorContainer),
            const SizedBox(width: 8),
            Expanded(
                child: Text('正在使用本地数据。$message',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall)),
            IconButton(
                onPressed: onRetry,
                tooltip: '重试 Bridge',
                icon: const Icon(Icons.refresh))
          ])));
}

String _connectionLabel(BridgeConnection connection) => switch (connection) {
      BridgeConnection.connecting => '连接中',
      BridgeConnection.connected => 'Bridge 已连接',
      BridgeConnection.reconnecting => '重连中',
      BridgeConnection.offline => '离线模式'
    };
String _modelShortLabel(String model) => switch (model) {
      'gpt-5.6-sol' => 'Sol',
      'gpt-5.6-terra' => 'Terra',
      'gpt-5.5' => '5.5',
      _ => model,
    };
String _reasoningLabel(String value) => switch (value) {
      'low' => '低',
      'medium' => '中',
      'high' => '高',
      'xhigh' => '超高',
      _ => value,
    };
String _reasoningShortLabel(String value) => switch (value) {
      'low' => '低',
      'medium' => '中',
      'high' => '高',
      'xhigh' => '超',
      _ => value,
    };
String _cleanRuntimeOutput(String value) => value
    .split('\n')
    .where((line) => line.trim() != 'Reading additional input from stdin...')
    .join('\n');
IconData _fileIcon(FileKind kind) => switch (kind) {
      FileKind.dart => Icons.code,
      FileKind.typescript => Icons.javascript,
      FileKind.markdown => Icons.article_outlined,
      FileKind.json => Icons.data_object,
      FileKind.image => Icons.image_outlined,
      FileKind.folder => Icons.folder_outlined
    };
