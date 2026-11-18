import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gptanywhere/app/app_theme.dart';

void main() {
  test('bars use the blue primary and selection uses a light blue', () {
    final theme = buildAppTheme();
    expect(theme.colorScheme.primary, appPrimary);
    expect(theme.colorScheme.secondary, appSecondary);
    expect(theme.appBarTheme.backgroundColor, appPrimary);
    expect(theme.appBarTheme.foregroundColor, appOnPrimary);
    expect(theme.appBarTheme.systemOverlayStyle?.statusBarColor, appPrimary);
    expect(
      theme.appBarTheme.systemOverlayStyle?.statusBarIconBrightness,
      Brightness.light,
    );
    expect(theme.navigationBarTheme.indicatorColor, appSelection);
    expect(theme.navigationRailTheme.indicatorColor, appSelection);
    final focused =
        theme.inputDecorationTheme.focusedBorder! as OutlineInputBorder;
    expect(focused.borderSide.color, appPrimary);
  });

  testWidgets('the title bar paints the same blue as the status bar', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(
          appBar: AppBar(title: const Text('GPTAnywhere')),
          bottomNavigationBar: NavigationBar(
            selectedIndex: 1,
            destinations: const [
              NavigationDestination(
                icon: Icon(Icons.chat_bubble_outline),
                label: 'Chat',
              ),
              NavigationDestination(
                icon: Icon(Icons.notes_outlined),
                label: 'Text',
              ),
            ],
          ),
        ),
      ),
    );

    final material = tester.widget<Material>(
      find
          .descendant(of: find.byType(AppBar), matching: find.byType(Material))
          .first,
    );
    expect(material.color, appPrimary);

    final overlay = tester.widget<AnnotatedRegion<SystemUiOverlayStyle>>(
      find.descendant(
        of: find.byType(AppBar),
        matching: find.byType(AnnotatedRegion<SystemUiOverlayStyle>),
      ),
    );
    expect(overlay.value.statusBarColor, appPrimary);
    expect(overlay.value.statusBarIconBrightness, Brightness.light);

    final title = tester.element(find.text('GPTAnywhere'));
    expect(DefaultTextStyle.of(title).style.color, appOnPrimary);

    final barTheme = NavigationBarTheme.of(
      tester.element(find.byType(NavigationBar)),
    );
    expect(barTheme.indicatorColor, appSelection);
    expect(
      barTheme.iconTheme?.resolve(const {WidgetState.selected})?.color,
      appPrimary,
    );
    expect(
      barTheme.labelTextStyle?.resolve(const {WidgetState.selected})?.color,
      appPrimary,
    );
  });
}
