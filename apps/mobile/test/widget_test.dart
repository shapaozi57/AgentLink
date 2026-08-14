import 'package:agentlink_mobile/app.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('渲染 AgentLink 外壳并使用离线数据', (WidgetTester tester) async {
    await tester.pumpWidget(const AgentLinkApp(enableBridge: false));
    await tester.pump();

    expect(find.text('AgentLink'), findsOneWidget);
    expect(find.text('任务'), findsOneWidget);
    expect(find.byType(NavigationBar), findsOneWidget);

    await tester.pump(const Duration(seconds: 6));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}
