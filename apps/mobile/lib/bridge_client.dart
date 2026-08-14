import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'models.dart';

enum BridgeConnection { connecting, connected, reconnecting, offline }

class BridgeEvent {
  const BridgeEvent({required this.type, required this.payload});

  final String type;
  final Map<String, dynamic> payload;

  factory BridgeEvent.fromJson(Map<String, dynamic> json) {
    final nested = json['data'];
    return BridgeEvent(
      type: json['type'] as String? ?? 'unknown',
      payload: nested is Map ? Map<String, dynamic>.from(nested) : json,
    );
  }
}

class BridgePairingConfig {
  const BridgePairingConfig({required this.uri, this.token});
  final Uri uri;
  final String? token;
}

class BridgeException implements Exception {
  const BridgeException(this.message, {this.statusCode});
  final String message;
  final int? statusCode;
  @override
  String toString() => message;
}

class BridgeClient {
  BridgeClient({Uri? baseUri, String? token})
      : baseUri = baseUri ??
            Uri.parse(const String.fromEnvironment('BRIDGE_URL',
                defaultValue: 'http://10.0.2.2:4317')),
        authToken = token ?? const String.fromEnvironment('BRIDGE_TOKEN');

  Uri baseUri;
  String authToken;
  final HttpClient _http = HttpClient()
    ..connectionTimeout = const Duration(seconds: 5);
  final StreamController<BridgeEvent> _events = StreamController.broadcast();
  final StreamController<BridgeConnection> _connections =
      StreamController.broadcast();
  WebSocket? _socket;
  Timer? _reconnectTimer;
  var _attempt = 0;
  var _closed = false;
  var _connection = BridgeConnection.offline;

  Stream<BridgeEvent> get events => _events.stream;
  Stream<BridgeConnection> get connections => _connections.stream;
  BridgeConnection get connection => _connection;
  String get baseUrl => trimBridgeUrl(baseUri.toString());

  Future<Map<String, dynamic>> health() => _request('GET', '/v1/health');

  Future<List<Workspace>> listWorkspaces() async {
    final body = await _request('GET', '/v1/workspaces');
    return _mapList(body['workspaces']).map(Workspace.fromJson).toList();
  }

  Future<Workspace> createWorkspace(String name, {String? rootPath}) async {
    final payload = <String, dynamic>{'name': name};
    if (rootPath != null && rootPath.trim().isNotEmpty) {
      payload['rootPath'] = rootPath.trim();
    }
    final body = await _request('POST', '/v1/workspaces', body: payload);
    return Workspace.fromJson(_map(body['workspace']));
  }

  Future<List<WorkspaceFile>> workspaceTree(String workspaceId) async {
    final body = await _request(
        'GET', '/v1/workspaces/${Uri.encodeComponent(workspaceId)}/tree');
    return _mapList(body['entries']).map(WorkspaceFile.fromJson).toList();
  }

  Future<WorkspaceFilePreview> readWorkspaceFile(
      String workspaceId, String path) async {
    final body = await _request(
        'GET', '/v1/workspaces/${Uri.encodeComponent(workspaceId)}/file',
        query: {'path': path});
    return WorkspaceFilePreview.fromJson(_map(body['file']));
  }

  Future<List<AgentSession>> listSessions() async {
    final body = await _request('GET', '/v1/sessions');
    return _mapList(body['sessions']).map(AgentSession.fromJson).toList();
  }

  Future<List<CodexHistorySession>> listCodexHistory() async {
    final body = await _request('GET', '/v1/codex/history');
    return _mapList(body['sessions'])
        .map(CodexHistorySession.fromJson)
        .toList();
  }

  Future<List<CodexTranscriptMessage>> readCodexTranscript(
      String sessionId) async {
    final body = await _request('GET',
        '/v1/codex/history/${Uri.encodeComponent(sessionId)}/transcript');
    return _mapList(body['messages'])
        .map(CodexTranscriptMessage.fromJson)
        .toList();
  }

  Future<AgentSession> createSession(String workspaceId,
      {String title = '手机端会话', String? codexSessionId}) async {
    final payload = <String, dynamic>{
      'workspaceId': workspaceId,
      'title': title
    };
    if (codexSessionId != null) payload['codexSessionId'] = codexSessionId;
    final body = await _request('POST', '/v1/sessions', body: payload);
    return AgentSession.fromJson(_map(body['session']));
  }

  Future<List<AgentTask>> listTasks() async {
    final body = await _request('GET', '/v1/tasks');
    return _mapList(body['tasks']).map(AgentTask.fromJson).toList();
  }

  Future<AgentTask> createTask(String sessionId, String prompt,
      {String agentId = 'codex',
      String mode = 'project',
      String controlMode = 'auto',
      String model = 'gpt-5.6-sol',
      String reasoningEffort = 'medium',
      bool allowDesktopTakeover = true,
      bool restoreForegroundWindow = true,
      bool requireIdleForDesktopTakeover = false}) async {
    final body = await _request('POST', '/v1/tasks', body: {
      'sessionId': sessionId,
      'agentId': agentId,
      'mode': mode,
      'controlMode': controlMode,
      'model': model,
      'reasoningEffort': reasoningEffort,
      'allowDesktopTakeover': allowDesktopTakeover,
      'restoreForegroundWindow': restoreForegroundWindow,
      'requireIdleForDesktopTakeover': requireIdleForDesktopTakeover,
      'prompt': prompt
    });
    return AgentTask.fromJson(_map(body['task']));
  }

  Future<AgentTask> cancelTask(String taskId) async {
    final body = await _request(
        'POST', '/v1/tasks/${Uri.encodeComponent(taskId)}/cancel');
    return AgentTask.fromJson(_map(body['task']));
  }

  Uri artifactPreviewUri(String taskId) => baseUri.replace(
      path: '/v1/artifacts/${Uri.encodeComponent(taskId)}/preview.html',
      query: null,
      fragment: null);

  Uri resolvePreviewUri(String previewUrl) {
    final parsed = Uri.parse(previewUrl);
    return parsed.hasScheme ? parsed : baseUri.resolve(previewUrl);
  }

  Future<void> useBaseUri(Uri uri, {bool reconnect = true}) async {
    baseUri = uri;
    await _resetSocket(reconnect: reconnect);
  }

  Future<void> useAuthToken(String token, {bool reconnect = true}) async {
    authToken = token.trim();
    await _resetSocket(reconnect: reconnect);
  }

  Future<void> _resetSocket({required bool reconnect}) async {
    _attempt = 0;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    final socket = _socket;
    _socket = null;
    await socket?.close();
    if (reconnect && !_closed) await connectEvents();
  }

  Future<void> connectEvents() async {
    if (_closed || _socket != null) return;
    _setConnection(_attempt == 0
        ? BridgeConnection.connecting
        : BridgeConnection.reconnecting);
    final scheme = baseUri.scheme == 'https' ? 'wss' : 'ws';
    final uri = baseUri.replace(
        scheme: scheme, path: '/v1/events', query: null, fragment: null);
    try {
      _socket = await WebSocket.connect(uri.toString(),
              headers: authToken.isEmpty
                  ? null
                  : {'Authorization': 'Bearer $authToken'})
          .timeout(const Duration(seconds: 5));
      _attempt = 0;
      _setConnection(BridgeConnection.connected);
      _socket!.listen(_onMessage,
          onError: (_) => _onDisconnected(),
          onDone: _onDisconnected,
          cancelOnError: true);
    } catch (_) {
      _socket = null;
      _setConnection(BridgeConnection.offline);
      _scheduleReconnect();
    }
  }

  void _onMessage(dynamic raw) {
    try {
      final decoded = jsonDecode(raw as String);
      if (decoded is Map) {
        _events.add(BridgeEvent.fromJson(Map<String, dynamic>.from(decoded)));
      }
    } catch (_) {
      // A malformed event is isolated so the socket remains usable.
    }
  }

  void _onDisconnected() {
    _socket = null;
    if (_closed) return;
    _setConnection(BridgeConnection.offline);
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_closed || _reconnectTimer?.isActive == true) return;
    final exponent = _attempt > 5 ? 5 : _attempt;
    final seconds = 1 << exponent;
    _attempt += 1;
    _reconnectTimer = Timer(Duration(seconds: seconds), connectEvents);
  }

  void _setConnection(BridgeConnection value) {
    _connection = value;
    if (!_connections.isClosed) _connections.add(value);
  }

  Future<Map<String, dynamic>> _request(String method, String path,
      {Map<String, dynamic>? body, Map<String, String>? query}) async {
    final uri = baseUri.replace(
        path: path,
        queryParameters: query == null || query.isEmpty ? null : query,
        fragment: null);
    try {
      final request =
          await _http.openUrl(method, uri).timeout(const Duration(seconds: 5));
      request.headers.set(HttpHeaders.acceptHeader, ContentType.json.mimeType);
      if (authToken.isNotEmpty) {
        request.headers
            .set(HttpHeaders.authorizationHeader, 'Bearer $authToken');
      }
      if (body != null) {
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(body));
      }
      final response =
          await request.close().timeout(const Duration(seconds: 8));
      final text = await utf8.decoder.bind(response).join();
      final decoded = text.isEmpty ? <String, dynamic>{} : jsonDecode(text);
      final result = decoded is Map
          ? Map<String, dynamic>.from(decoded)
          : <String, dynamic>{};
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw BridgeException(result['error'] as String? ?? 'Bridge 请求失败',
            statusCode: response.statusCode);
      }
      return result;
    } on BridgeException {
      rethrow;
    } catch (error) {
      throw BridgeException('Bridge 连接异常：$error');
    }
  }

  static Map<String, dynamic> _map(Object? value) =>
      value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{};
  static List<Map<String, dynamic>> _mapList(Object? value) => value is List
      ? value
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList()
      : const [];

  Future<void> close() async {
    _closed = true;
    _reconnectTimer?.cancel();
    await _socket?.close();
    _http.close(force: true);
    await _events.close();
    await _connections.close();
  }
}

Uri normalizeBridgeUri(String raw) {
  final trimmed = raw.trim();
  final withScheme = trimmed.contains('://') ? trimmed : 'http://$trimmed';
  final uri = Uri.parse(withScheme);
  if ((uri.scheme != 'http' && uri.scheme != 'https') || uri.host.isEmpty) {
    throw const FormatException('请输入有效的 Bridge 地址');
  }
  return uri.replace(path: '', query: null, fragment: null);
}

BridgePairingConfig? bridgeConfigFromPairingPayload(String raw) {
  final value = raw.trim();
  if (value.isEmpty) return null;
  try {
    final decoded = jsonDecode(value);
    if (decoded is Map && decoded['url'] is String) {
      return BridgePairingConfig(
          uri: normalizeBridgeUri(decoded['url'] as String),
          token: decoded['token'] as String?);
    }
    if (decoded is Map && decoded['bridgeUrl'] is String) {
      return BridgePairingConfig(
          uri: normalizeBridgeUri(decoded['bridgeUrl'] as String),
          token: decoded['token'] as String?);
    }
  } catch (_) {
    // Not JSON; continue with URI parsing.
  }
  try {
    final uri = Uri.parse(value);
    if (uri.scheme == 'agentlink' && uri.host == 'bridge') {
      final url = uri.queryParameters['url'];
      return url == null
          ? null
          : BridgePairingConfig(
              uri: normalizeBridgeUri(url),
              token: uri.queryParameters['token']);
    }
    return BridgePairingConfig(uri: normalizeBridgeUri(value));
  } catch (_) {
    return null;
  }
}

Uri? bridgeUriFromPairingPayload(String raw) =>
    bridgeConfigFromPairingPayload(raw)?.uri;

String trimBridgeUrl(String value) =>
    value.endsWith('/') ? value.substring(0, value.length - 1) : value;
