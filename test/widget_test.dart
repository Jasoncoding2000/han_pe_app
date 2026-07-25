// Basic smoke test: the app builds and shows the screener page title.

import 'package:flutter_test/flutter_test.dart';

import 'package:han_pe_app/main.dart';

void main() {
  testWidgets('App builds and shows title', (WidgetTester tester) async {
    await tester.pumpWidget(const HanPeApp());
    expect(find.text('hanPE Screener'), findsOneWidget);
  });
}
