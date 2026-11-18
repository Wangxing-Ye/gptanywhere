import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const appPrimary = Color(0xFF1F4B99);
const appOnPrimary = Color(0xFFFFFFFF);
const appSecondary = Color(0xFFD97706);
const appOnSecondary = Color(0xFF1F1408);
const appSelection = Color(0xFFD6E3F8);

ThemeData buildAppTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: appPrimary,
    primary: appPrimary,
    onPrimary: appOnPrimary,
    secondary: appSecondary,
    onSecondary: appOnSecondary,
  );
  const radius = BorderRadius.all(Radius.circular(16));
  const border = OutlineInputBorder(borderRadius: radius);
  final labelGray = TextStyle(color: scheme.onSurfaceVariant);
  const selectedIcon = IconThemeData(color: appPrimary, size: 24);
  final idleIcon = IconThemeData(color: scheme.onSurfaceVariant, size: 24);
  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    appBarTheme: const AppBarTheme(
      backgroundColor: appPrimary,
      foregroundColor: appOnPrimary,
      surfaceTintColor: appPrimary,
      elevation: 0,
      scrolledUnderElevation: 0,
      iconTheme: IconThemeData(color: appOnPrimary),
      actionsIconTheme: IconThemeData(color: appOnPrimary),
      systemOverlayStyle: SystemUiOverlayStyle(
        statusBarColor: appPrimary,
        statusBarIconBrightness: Brightness.light,
        statusBarBrightness: Brightness.dark,
        systemStatusBarContrastEnforced: false,
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      indicatorColor: appSelection,
      iconTheme: WidgetStateProperty.resolveWith((states) {
        return states.contains(WidgetState.selected) ? selectedIcon : idleIcon;
      }),
      labelTextStyle: WidgetStateProperty.resolveWith((states) {
        final selected = states.contains(WidgetState.selected);
        return TextStyle(
          color: selected ? appPrimary : scheme.onSurfaceVariant,
          fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
        );
      }),
    ),
    navigationRailTheme: NavigationRailThemeData(
      indicatorColor: appSelection,
      selectedIconTheme: selectedIcon,
      unselectedIconTheme: idleIcon,
      selectedLabelTextStyle: const TextStyle(
        color: appPrimary,
        fontWeight: FontWeight.w600,
      ),
      unselectedLabelTextStyle: TextStyle(color: scheme.onSurfaceVariant),
    ),
    inputDecorationTheme: InputDecorationTheme(
      labelStyle: labelGray,
      floatingLabelStyle: labelGray,
      border: border,
      enabledBorder: border,
      focusedBorder: border.copyWith(
        borderSide: BorderSide(color: scheme.primary, width: 2),
      ),
      errorBorder: border.copyWith(borderSide: BorderSide(color: scheme.error)),
      focusedErrorBorder: border.copyWith(
        borderSide: BorderSide(color: scheme.error, width: 2),
      ),
    ),
  );
}
