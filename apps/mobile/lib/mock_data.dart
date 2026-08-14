import 'models.dart';

final initialTasks = <AgentTask>[
  AgentTask(
    id: 'task_041',
    title: '构建移动端任务历史',
    prompt: '构建带筛选和产物入口的移动端任务历史页。',
    status: TaskStatus.running,
    updatedAt: '刚刚',
    summary: '已改动 3 个文件，正在优化状态筛选。',
    files: const [
      'lib/features/tasks/task_history.dart',
      'lib/models/task.dart',
      'test/task_history_test.dart'
    ],
  ),
  AgentTask(
    id: 'task_040',
    title: '修复 WebSocket 重连',
    prompt: '排查手机网络变化后的重连问题。',
    status: TaskStatus.completed,
    updatedAt: '12 分钟前',
    summary: '已按顺序恢复 7 条缺失输出事件。',
    files: const ['bridge/src/realtime/reconnect.ts'],
  ),
  AgentTask(
    id: 'task_039',
    title: '解释 bridge/auth.ts',
    prompt: '解释认证模块中的令牌刷新和设备签名逻辑。',
    status: TaskStatus.completed,
    updatedAt: '35 分钟前',
    summary: '已补充认证流程和边界条件说明。',
  ),
  AgentTask(
    id: 'task_038',
    title: '运行 Bridge 集成测试',
    prompt: '运行 Bridge 集成测试并总结失败项。',
    status: TaskStatus.failed,
    updatedAt: '昨天 18:20',
    summary: 'Bridge 未就绪时设备认证超时。',
  ),
];

const workspaceTree = <WorkspaceFile>[
  WorkspaceFile('src', 'src', FileKind.folder, children: [
    WorkspaceFile('bridge', 'src/bridge', FileKind.folder, children: [
      WorkspaceFile('auth.ts', 'src/bridge/auth.ts', FileKind.typescript),
      WorkspaceFile('server.ts', 'src/bridge/server.ts', FileKind.typescript),
    ]),
    WorkspaceFile('mobile', 'src/mobile', FileKind.folder, children: [
      WorkspaceFile('app.dart', 'src/mobile/app.dart', FileKind.dart),
      WorkspaceFile(
          'task_page.dart', 'src/mobile/task_page.dart', FileKind.dart),
    ]),
  ]),
  WorkspaceFile('docs', 'docs', FileKind.folder, children: [
    WorkspaceFile('protocol.md', 'docs/protocol.md', FileKind.markdown),
  ]),
  WorkspaceFile('README.md', 'README.md', FileKind.markdown),
  WorkspaceFile('package.json', 'package.json', FileKind.json),
];

const devices = <Device>[
  Device(
      name: 'Windows-PC',
      host: '192.168.1.8:4310',
      isOnline: true,
      lastSeen: '当前在线',
      workspaces: 3),
  Device(
      name: 'Studio-Desktop',
      host: '192.168.1.16:4310',
      isOnline: false,
      lastSeen: '上次在线：昨天 21:15',
      workspaces: 1),
];
