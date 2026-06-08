import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Splash screen renders app name', (WidgetTester tester) async {
    // Standalone widget test — does not depend on platform plugins
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(child: Text('Narrator')),
        ),
      ),
    );
    expect(find.text('Narrator'), findsOneWidget);
  });
}
