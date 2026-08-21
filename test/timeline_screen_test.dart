import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ow_editor/api.dart';
import 'package:ow_editor/screens/timeline_screen.dart';

/// A tela de montagem, sem servidor nenhum.
///
/// O que se verifica é o caminho de quem chega nela: os momentos da partida
/// aparecem, tocar num deles põe um bloco, e a tela passa a dizer que vídeo vai
/// sair. Nada aqui toca a rede — a partida vem montada à mão.
Job jobComMomentos() => Job.fromJson({
      'id': 'j1',
      'status': 'ready',
      'stage': 'escolha o que gerar',
      'progress': 1.0,
      'video_name': 'partida.mp4',
      'duration_s': 600.0,
      'created_at': DateTime.now().toIso8601String(),
      'n_clips': 0,
      'events': [
        {'kind': 'kill', 't': 30.0, 'confidence': 1.0},
        {'kind': 'sleep', 't': 75.0, 'confidence': 1.0},
        {'kind': 'stun', 't': 120.0, 'confidence': 1.0},
        // contexto, não jogada: não deve virar bloco
        {'kind': 'death', 't': 200.0, 'confidence': 1.0},
        {'kind': 'low_hp', 't': 210.0, 'confidence': 1.0},
      ],
    });

void main() {
  Future<void> abrir(WidgetTester tester) async {
    // A tela é uma lista comprida, e a `ListView` só constrói o que caberia na
    // viewport. Numa janela de teste padrão (800x600) o botão de gerar nem
    // existiria no widget tree, e o teste falharia por um motivo que não é o
    // dele. Uma janela alta põe a tela inteira à vista.
    await tester.binding.setSurfaceSize(const Size(1000, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(home: TimelineScreen(job: jobComMomentos())),
    );
    await tester.pump();
  }

  testWidgets('oferece os momentos da partida, e só os que viram corte',
      (tester) async {
    await abrir(tester);

    expect(find.textContaining('Eliminação 00:30'), findsOneWidget);
    expect(find.textContaining('Dardo no alvo 01:15'), findsOneWidget);
    expect(find.textContaining('Pedrada certeira 02:00'), findsOneWidget);
    // vida baixa e interrupção são o contexto da jogada, não a jogada
    expect(find.textContaining('Interrupção'), findsNothing);
    expect(find.textContaining('Vida baixa'), findsNothing);
  });

  testWidgets('sem cortes, não há o que gerar', (tester) async {
    await abrir(tester);

    expect(find.text('Ponha ao menos um corte'), findsOneWidget);
    final botao = tester.widget<FilledButton>(find.byType(FilledButton));
    expect(botao.onPressed, isNull);
  });

  testWidgets('tocar num momento põe um corte e o vídeo passa a existir',
      (tester) async {
    await abrir(tester);
    await tester.tap(find.textContaining('Eliminação 00:30'));
    await tester.pump();

    expect(find.textContaining('1 corte(s)'), findsOneWidget);
    expect(find.text('Gerar este vídeo'), findsOneWidget);
    final botao = tester.widget<FilledButton>(find.byType(FilledButton));
    expect(botao.onPressed, isNotNull);
  });

  testWidgets('o mesmo momento pode entrar mais de uma vez', (tester) async {
    // usar um momento num vídeo não o consome — é a mesma promessa das
    // propostas, e vale igual na montagem manual
    await abrir(tester);
    await tester.tap(find.textContaining('Eliminação 00:30'));
    await tester.pump();
    await tester.tap(find.textContaining('Eliminação 00:30'));
    await tester.pump();

    expect(find.textContaining('2 corte(s)'), findsOneWidget);
  });

  testWidgets('o bloco escolhido mostra de onde saiu e onde entra',
      (tester) async {
    await abrir(tester);
    await tester.tap(find.textContaining('Dardo no alvo 01:15'));
    await tester.pump();

    expect(find.textContaining('Dardo no alvo de 01:15'), findsOneWidget);
    expect(find.textContaining('entra em 00:00 do vídeo'), findsOneWidget);
    expect(find.text('Duração'), findsOneWidget);
    expect(find.text('Enquadramento'), findsOneWidget);
  });

  testWidgets('sem música, a tela diz que o vídeo fica com o áudio da partida',
      (tester) async {
    await abrir(tester);

    expect(find.text('Sem música'), findsOneWidget);
    expect(
      find.text('sem música o vídeo sai com o áudio da partida'),
      findsOneWidget,
    );
  });
}
