// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_model_test/main.dart';

void main() {
  testWidgets('Camera toggle button switches between views', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ModelViewerHomePage(
          viewerBuilder: (context, cameraOrbit, backgroundColor) {
            return ColoredBox(
              key: ValueKey<String>('viewer-$cameraOrbit'),
              color: backgroundColor,
            );
          },
        ),
      ),
    );

    expect(find.text('Switch to top view'), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('viewer-0deg 65deg auto')),
        findsOneWidget);

    await tester.tap(find.text('Switch to top view'));
    await tester.pumpAndSettle();

    expect(find.text('Switch to front view'), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('viewer-0deg 90deg auto')),
        findsOneWidget);
  });
}
