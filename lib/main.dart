import 'package:flutter/material.dart';

import 'screens/jobs_screen.dart';

void main() => runApp(const OwEditorApp());

/// Paleta escura e sóbria — o conteúdo é vídeo de jogo, então a interface
/// fica fora do caminho.
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

/// Mobile-first, mas o app também roda na web: numa janela larga o conteúdo
/// para de esticar e fica centralizado, em vez de virar uma linha gigante.
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
