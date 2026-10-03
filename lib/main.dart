import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'screens/jobs_screen.dart';

void main() {
  // the editor has its own right-click menus (the layers'); the browser's
  // would open on top of them
  if (kIsWeb) BrowserContextMenu.disableContextMenu();
  runApp(const OwEditorApp());
}

/// A dark, sober palette — the content is game video, so the interface stays
/// out of the way.
const _seed = Color(0xFFFF7A18);

class OwEditorApp extends StatelessWidget {
  const OwEditorApp({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(
      seedColor: _seed,
      brightness: Brightness.dark,
    );
    return MaterialApp(
      title: 'OW Editor',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: scheme,
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFF101216),
        cardTheme: CardThemeData(
          color: const Color(0xFF181B21),
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          clipBehavior: Clip.antiAlias,
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF101216),
          surfaceTintColor: Colors.transparent,
          centerTitle: false,
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            minimumSize: const Size.fromHeight(52),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
          ),
        ),
        snackBarTheme: const SnackBarThemeData(
          behavior: SnackBarBehavior.floating,
        ),
      ),
      home: const JobsScreen(),
    );
  }
}

/// Mobile-first, but the app also runs on the web: in a wide window the
/// content stops stretching and stays centred, instead of becoming one giant
/// line.
class PhoneWidth extends StatelessWidget {
  const PhoneWidth({super.key, required this.child, this.maxWidth = 640});

  final Widget child;
  final double maxWidth;

  @override
  Widget build(BuildContext context) => Center(
    child: ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: child,
    ),
  );
}
