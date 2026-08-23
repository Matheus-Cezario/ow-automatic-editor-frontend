import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ow_editor/api.dart';
import 'package:ow_editor/screens/timeline_screen.dart';
import 'package:ow_editor/widgets/music_timeline.dart';
import 'package:ow_editor/widgets/preview_player.dart';

/// A tela de montagem, sem servidor nenhum.
///
/// O que se verifica é o caminho de quem chega nela: os momentos da partida
/// aparecem, tocar num deles põe um bloco, e a tela passa a dizer que vídeo vai
/// sair. Nada aqui toca a rede — a partida vem montada à mão.
/// Uma música já analisada, com batida a cada meio segundo.
///
/// Serve para exercitar o ímã: é justamente com ele ligado que o arrasto
/// quebrava.
Map<String, dynamic> musicaPronta() => {
  'id': 'm1',
  'kind': 'audio',
  'status': 'ready',
  'name': 'musica.mp3',
  'duration_s': 120.0,
  'bpm': 120.0,
  'beats': [for (var i = 0; i < 240; i++) i * 0.5],
  'peaks': [for (var i = 0; i < 400; i++) 0.5],
  'audio_url': '/api/tracks/m1/audio',
};

Map<String, dynamic> jobJson({bool comMusica = false}) => {
  // no servidor a música é mídia de áudio da biblioteca, e aparece nas duas
  // listas: `media` é a biblioteca inteira, `tracks` é o recorte de áudio
  if (comMusica) 'tracks': [musicaPronta()],
  if (comMusica) 'media': [musicaPronta()],
  // sem a gravação não há monitor: é dela que o preview busca os quadros
  'video_url': '/api/jobs/j1/video',
  'id': 'j1',
  'status': 'ready',
  'stage': 'escolha o que gerar',
  'progress': 1.0,
  'video_name': 'partida.mp4',
  'duration_s': 600.0,
  'width': 1920,
  'height': 1080,
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
};

Job jobComMomentos({bool comMusica = false}) =>
    Job.fromJson(jobJson(comMusica: comMusica));

void main() {
  Future<void> abrir(WidgetTester tester, {bool comMusica = false}) async {
    // A tela é uma lista comprida, e a `ListView` só constrói o que caberia na
    // viewport. Numa janela de teste padrão (800x600) o botão de gerar nem
    // existiria no widget tree, e o teste falharia por um motivo que não é o
    // dele. Uma janela alta põe a tela inteira à vista.
    await tester.binding.setSurfaceSize(const Size(1000, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        home: TimelineScreen(job: jobComMomentos(comMusica: comMusica)),
      ),
    );
    await tester.pump();
  }

  /// Os clipes de todas as camadas, na ordem em que o vídeo os mostra.
  List<TimelineClip> cortes(WidgetTester tester) => [
    for (final l
        in tester.widget<MusicTimeline>(find.byType(MusicTimeline)).layers)
      ...l.clips,
  ];

  TimelineClip primeiroCorte(WidgetTester tester) => cortes(tester).first;

  /// Põe a cabeça de leitura em [segundos] clicando na régua.
  ///
  /// A conta desconta a coluna de cabeçalhos, que fica fora da rolagem: sem
  /// isso o toque cai uns dois segundos e meio antes do pretendido.
  Future<void> cursorEm(WidgetTester tester, double segundos) async {
    final regua = tester.getRect(find.byType(MusicTimeline));
    await tester.tapAt(
      Offset(
        regua.left + MusicTimeline.larguraDosCabecalhos + 1 + segundos * 60,
        regua.top + 20,
      ),
    );
    await tester.pump();
  }

  /// Troca para a aba da lateral, dando tempo à animação.
  /// Deixa a tela reagir sem esperar que ela pare de todo.
  ///
  /// `pumpAndSettle` não serve aqui: o monitor mantém temporizadores vivos e a
  /// tela nunca "assenta".
  Future<void> assentar(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> aba(WidgetTester tester, String nome) async {
    await tester.tap(find.text(nome));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  /// O bloco na régua, pela ordem em que está na montagem.
  ///
  /// A chave é o id do bloco, que é gerado em tempo de execução — então o teste
  /// pergunta ao widget quem está lá em vez de tentar adivinhar.
  Finder bloco(WidgetTester tester, int i) =>
      find.byKey(ValueKey('bloco-${cortes(tester)[i].id}'));

  /// O item na prateleira de momentos, pelo instante em que aconteceu.
  Finder momento(double t) => find.byKey(ValueKey('momento-$t'));

  testWidgets('oferece os momentos da partida, e só os que viram corte', (
    tester,
  ) async {
    await abrir(tester);

    expect(momento(30.0), findsOneWidget);
    expect(momento(75.0), findsOneWidget);
    expect(momento(120.0), findsOneWidget);
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

  testWidgets('tocar num momento põe um corte e o vídeo passa a existir', (
    tester,
  ) async {
    await abrir(tester);
    await tester.tap(momento(30.0));
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
    await tester.tap(momento(30.0));
    await tester.pump();
    await tester.tap(momento(30.0));
    await tester.pump();

    expect(find.textContaining('2 corte(s)'), findsOneWidget);
  });

  testWidgets('o bloco escolhido mostra de onde saiu e onde entra', (
    tester,
  ) async {
    await abrir(tester);
    await tester.tap(momento(75.0));
    await tester.pump();

    expect(find.textContaining('Dardo no alvo de 01:15'), findsOneWidget);
    expect(find.textContaining('entra em 00:00 do vídeo'), findsOneWidget);
    expect(find.text('Duração'), findsOneWidget);
    expect(find.text('Enquadramento'), findsOneWidget);
  });

  testWidgets('a música vem pela Biblioteca, e só por ela', (tester) async {
    // havia dois jeitos de pôr som, e eles não funcionavam igual. Sobrou um: a
    // música é mídia de fora da partida como qualquer outra
    await abrir(tester, comMusica: true);

    expect(find.text('Sem música'), findsNothing);
    expect(find.text('Pôr na régua'), findsNothing);

    await aba(tester, 'Biblioteca');
    expect(find.byKey(const ValueKey('midia-m1')), findsOneWidget);
    expect(find.textContaining('120 BPM'), findsOneWidget);
  });

  // ── arrastar ──────────────────────────────────────────────────────────────
  //
  // O bloco de testes que faltava quando o arrasto não funcionava. Aplicando
  // `delta.dx` quadro a quadro, cada passo de 3px virava 0,05s e o ímã grudava
  // de volta na mesma batida: o bloco não saía do lugar. O gesto agora acumula
  // desde onde partiu, e é isso que estes testes travam.

  /// O reconhecedor de gestos só aceita o arrasto depois de vencer o
  /// `kTouchSlop` (18px), e o que o dedo andou até lá não conta. Em passos de
  /// 3px isso come 21px — sem descontá-los, as contas dos testes abaixo erram
  /// por um terço de segundo.
  const comidoPeloSlop = 21.0;
  const px = 60.0; // o zoom padrão da tela

  /// Arrasta em passos pequenos, como um dedo andando devagar.
  ///
  /// É esta a forma que importa: `tester.drag` entrega o movimento em dois
  /// saltos grandes, e com saltos grandes até o código quebrado funcionava. O
  /// bug só aparecia no arrasto lento, em que cada quadro anda poucos pixels.
  Future<void> arrastarDevagar(
    WidgetTester tester,
    Finder alvo,
    double total, {
    double passo = 3,
  }) async {
    final gesto = await tester.startGesture(tester.getCenter(alvo));
    for (var andou = 0.0; andou < total.abs(); andou += passo) {
      await gesto.moveBy(Offset(total.isNegative ? -passo : passo, 0));
      await tester.pump();
    }
    await gesto.up();
    await tester.pump();
  }

  testWidgets('arrastar devagar move o bloco, com o ímã ligado', (
    tester,
  ) async {
    // Com o ímã ligado e o bloco já em cima de uma batida, cada passo de 3px
    // vale 0,05s — dentro da tolerância do ímã. Aplicando passo a passo, ele
    // grudava de volta e o bloco não saía do lugar por mais que se arrastasse.
    await abrir(tester, comMusica: true);
    await tester.tap(momento(30.0));
    await tester.pump();
    expect(primeiroCorte(tester).atS, 0);

    await arrastarDevagar(tester, bloco(tester, 0), 120);

    expect(
      primeiroCorte(tester).atS,
      closeTo((120 - comidoPeloSlop) / px, 0.05),
    );
  });

  testWidgets('arrastar para perto de uma batida gruda nela', (tester) async {
    await abrir(tester, comMusica: true);
    await tester.tap(momento(75.0));
    await tester.pump();
    // a grade vem da música que está tocando ali: sem música na régua não há
    // batida a que grudar
    await aba(tester, 'Biblioteca');
    await tester.tap(find.byKey(const ValueKey('midia-m1')));
    await assentar(tester);
    await aba(tester, 'Momentos');

    // Solto a 1,55s: 0,05 depois da batida de 1,5s, dentro da tolerância do
    // ímã. Sem ímã pararia em 1,55; com ímã tem de cair exatamente na batida.
    const solto = 1.55;
    await arrastarDevagar(
      tester,
      bloco(tester, 0),
      solto * px + comidoPeloSlop,
    );

    expect(primeiroCorte(tester).atS, closeTo(1.5, 1e-9));
  });

  testWidgets('arrastar não deixa o bloco sair pela esquerda', (tester) async {
    await abrir(tester, comMusica: true);
    await tester.tap(momento(30.0));
    await tester.pump();

    await arrastarDevagar(tester, bloco(tester, 0), -200);

    expect(primeiroCorte(tester).atS, 0);
  });

  testWidgets('arrastar a alça direita estica o corte', (tester) async {
    await abrir(tester, comMusica: true);
    await tester.tap(momento(30.0));
    await tester.pump();

    final antes = primeiroCorte(tester).durationS;

    // a alça fica na borda direita do bloco selecionado
    final caixa = tester.getRect(bloco(tester, 0));
    await tester.dragFrom(
      Offset(caixa.right - 8, caixa.center.dy),
      const Offset(60, 0),
    );
    await tester.pump();

    final depois = primeiroCorte(tester);
    expect(depois.durationS, greaterThan(antes));
    expect(depois.atS, 0, reason: 'esticar não move o bloco');
  });

  testWidgets('o monitor avisa quando a cabeça de leitura está no vazio', (
    tester,
  ) async {
    await abrir(tester);
    expect(find.text('sem cortes ainda'), findsOneWidget);
  });

  // ── a prateleira e o monitor ──────────────────────────────────────────────

  testWidgets('cada momento aparece com o quadro dele', (tester) async {
    // sem imagem, escolher entre trinta eliminações é escolher entre trinta
    // relógios iguais
    await abrir(tester);

    final imagem = tester.widget<Image>(
      find.descendant(of: momento(30.0), matching: find.byType(Image)),
    );
    final rede = imagem.image as NetworkImage;
    expect(rede.url, contains('/api/jobs/j1/frame'));
    expect(rede.url, contains('t=30.00'));
  });

  testWidgets('numa tela larga a prateleira fica na lateral', (tester) async {
    await abrir(tester); // a janela de teste tem 1000px
    final lateral = tester.getTopLeft(momento(30.0));
    final regua = tester.getTopLeft(find.byType(MusicTimeline));

    expect(
      lateral.dx,
      lessThan(regua.dx),
      reason: 'a prateleira tem de estar à esquerda da régua',
    );
  });

  testWidgets('numa tela estreita ela volta para baixo da régua', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(500, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(home: TimelineScreen(job: jobComMomentos())),
    );
    await tester.pump();

    expect(
      tester.getTopLeft(momento(30.0)).dy,
      greaterThan(tester.getTopLeft(find.byType(MusicTimeline)).dy),
    );
  });

  testWidgets('a alça arrasta a altura do monitor', (tester) async {
    await abrir(tester);
    final antes = tester.getSize(find.byType(PreviewPlayer)).height;

    await tester.drag(
      find.byKey(const Key('alca-monitor')),
      const Offset(0, 120),
    );
    await tester.pump();

    expect(
      tester.getSize(find.byType(PreviewPlayer)).height,
      greaterThan(antes),
    );
  });

  testWidgets('o monitor não encolhe além do mínimo', (tester) async {
    await abrir(tester);

    await tester.drag(
      find.byKey(const Key('alca-monitor')),
      const Offset(0, -900),
    );
    await tester.pump();

    expect(
      tester.getSize(find.byType(PreviewPlayer)).height,
      greaterThanOrEqualTo(120.0),
    );
  });

  // ── o rascunho ────────────────────────────────────────────────────────────
  //
  // Recarregar a página custava a montagem inteira. Agora ela vive no servidor
  // e volta junto com a partida.

  testWidgets('a montagem de antes volta ao abrir a tela', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final job = Job.fromJson({
      ...jobJson(comMusica: true),
      'draft': {
        'title': 'Minha montagem de ontem',
        'track_id': 'm1',
        'music_start_s': 8.0,
        'cuts': [
          {
            'source_t': 30.0,
            'start_s': 29.0,
            'duration_s': 1.5,
            'at_s': 0.0,
            'kind': 'kill',
          },
          {
            'source_t': 75.0,
            'start_s': 74.0,
            'duration_s': 1.0,
            'at_s': 2.0,
            'kind': 'sleep',
          },
        ],
      },
    });

    await tester.pumpWidget(MaterialApp(home: TimelineScreen(job: job)));
    await tester.pump();

    final cuts = cortes(tester);
    // dois cortes e o bloco de música em que a faixa contínua se converteu
    final daGravacao = cuts.where((c) => c.source == 'recording').toList();
    expect(daGravacao, hasLength(2));
    expect(daGravacao[0].sourceT, 30.0);
    expect(daGravacao[1].atS, 2.0);
    expect(find.textContaining('2 corte(s)'), findsOneWidget);

    // o nome sobrevive, e a música de antes volta como bloco na régua: ela
    // entrava aos 8s da faixa e cobria o vídeo inteiro
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'Minha montagem de ontem',
    );
    final musica = cuts.singleWhere((c) => c.source == 'media');
    expect(musica.mediaId, 'm1');
    expect(musica.atS, 0);
    expect(musica.startS, 8.0);
    expect(musica.durationS, closeTo(3.0, 1e-6));
  });

  testWidgets('sem rascunho, a tela abre vazia', (tester) async {
    await abrir(tester);
    expect(cortes(tester), isEmpty);
  });

  // ── o que a Fase 1 trouxe ─────────────────────────────────────────────────
  //
  // A V1 não tinha nada disto: cada mexida sobrescrevia a anterior, e um bloco
  // era o único que dava para tocar de cada vez.

  /// Aperta uma tecla, com os modificadores que vierem.
  Future<void> teclar(
    WidgetTester tester,
    LogicalKeyboardKey tecla, {
    bool ctrl = false,
    bool shift = false,
  }) async {
    if (ctrl) await tester.sendKeyDownEvent(LogicalKeyboardKey.control);
    if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shift);
    await tester.sendKeyEvent(tecla);
    if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shift);
    if (ctrl) await tester.sendKeyUpEvent(LogicalKeyboardKey.control);
    await tester.pump();
  }

  /// Os clipes de todas as camadas, na ordem em que o vídeo os mostra.
  testWidgets('Ctrl+Z desfaz um arrasto inteiro, não pixel a pixel', (
    tester,
  ) async {
    await abrir(tester, comMusica: true);
    await tester.tap(momento(30.0));
    await tester.pump();
    expect(cortes(tester).first.atS, 0);

    await arrastarDevagar(tester, bloco(tester, 0), 120);
    expect(cortes(tester).first.atS, greaterThan(1.0));

    await teclar(tester, LogicalKeyboardKey.keyZ, ctrl: true);

    expect(cortes(tester).first.atS, 0, reason: 'um passo devolveu tudo');
  });

  testWidgets('Ctrl+Shift+Z refaz o que foi desfeito', (tester) async {
    await abrir(tester, comMusica: true);
    await tester.tap(momento(30.0));
    await tester.pump();
    await arrastarDevagar(tester, bloco(tester, 0), 120);
    final depoisDoArrasto = cortes(tester).first.atS;

    await teclar(tester, LogicalKeyboardKey.keyZ, ctrl: true);
    await teclar(tester, LogicalKeyboardKey.keyZ, ctrl: true, shift: true);

    expect(cortes(tester).first.atS, depoisDoArrasto);
  });

  testWidgets('desfazer também volta um bloco recém-posto', (tester) async {
    await abrir(tester, comMusica: true);
    await tester.tap(momento(30.0));
    await tester.pump();
    expect(cortes(tester), hasLength(1));

    await teclar(tester, LogicalKeyboardKey.keyZ, ctrl: true);

    expect(cortes(tester), isEmpty);
    expect(find.text('Ponha ao menos um corte'), findsOneWidget);
  });

  testWidgets(
    'os botões de desfazer só ficam ativos quando há o que desfazer',
    (tester) async {
      await abrir(tester, comMusica: true);
      IconButton botao(IconData icone) =>
          tester.widget<IconButton>(find.widgetWithIcon(IconButton, icone));

      expect(botao(Icons.undo).onPressed, isNull);
      expect(botao(Icons.redo).onPressed, isNull);

      await tester.tap(momento(30.0));
      await tester.pump();

      expect(botao(Icons.undo).onPressed, isNotNull);
      expect(botao(Icons.redo).onPressed, isNull);
    },
  );

  testWidgets('S divide o corte sob a cabeça de leitura', (tester) async {
    await abrir(tester, comMusica: true);
    await tester.tap(momento(30.0));
    await tester.pump();
    final original = cortes(tester).first;

    // leva o cursor para o meio do bloco e corta
    await cursorEm(tester, original.durationS / 2);
    await teclar(tester, LogicalKeyboardKey.keyS);

    final depois = cortes(tester);
    expect(depois, hasLength(2));
    // a emenda é invisível: a segunda metade continua de onde a primeira parou
    expect(depois[1].startS, closeTo(depois[0].endS, 1e-6));
    expect(depois[1].untilS, closeTo(original.untilS, 1e-6));
  });

  testWidgets('dividir fora de um corte avisa em vez de não fazer nada', (
    tester,
  ) async {
    await abrir(tester, comMusica: true);
    await teclar(tester, LogicalKeyboardKey.keyS);

    expect(find.textContaining('em cima de um corte'), findsOneWidget);
  });

  testWidgets('Delete tira os cortes escolhidos', (tester) async {
    await abrir(tester, comMusica: true);
    await tester.tap(momento(30.0));
    await tester.pump();

    await teclar(tester, LogicalKeyboardKey.delete);

    expect(cortes(tester), isEmpty);
  });

  testWidgets('Ctrl+D duplica o que está selecionado', (tester) async {
    await abrir(tester, comMusica: true);
    await tester.tap(momento(30.0));
    await tester.pump();

    await teclar(tester, LogicalKeyboardKey.keyD, ctrl: true);

    final depois = cortes(tester);
    expect(depois, hasLength(2));
    expect(depois[1].atS, closeTo(depois[0].untilS, 1e-6));
    expect(depois[0].id, isNot(depois[1].id));
  });

  testWidgets('copiar e colar põe a cópia onde o cursor estiver', (
    tester,
  ) async {
    await abrir(tester, comMusica: true);
    await tester.tap(momento(30.0));
    await tester.pump();

    await teclar(tester, LogicalKeyboardKey.keyC, ctrl: true);
    await cursorEm(tester, 5);
    await teclar(tester, LogicalKeyboardKey.keyV, ctrl: true);

    final depois = cortes(tester);
    expect(depois, hasLength(2));
    expect(depois[1].atS, closeTo(5.0, 0.3));
  });

  testWidgets('shift+clique soma à seleção, e o painel de lote aparece', (
    tester,
  ) async {
    await abrir(tester, comMusica: true);
    await tester.tap(momento(30.0));
    await tester.pump();
    await tester.tap(momento(75.0));
    await tester.pump();

    // só o último posto está selecionado
    expect(find.textContaining('cortes selecionados'), findsNothing);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shift);
    await tester.tap(bloco(tester, 0));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shift);
    await tester.pump();

    expect(find.text('2 cortes selecionados'), findsOneWidget);
  });

  testWidgets('Ctrl+A seleciona tudo e Delete leva todos', (tester) async {
    await abrir(tester, comMusica: true);
    for (final t in [30.0, 75.0, 120.0]) {
      await tester.tap(momento(t));
      await tester.pump();
    }
    expect(cortes(tester), hasLength(3));

    await teclar(tester, LogicalKeyboardKey.keyA, ctrl: true);
    expect(find.text('3 cortes selecionados'), findsOneWidget);

    await teclar(tester, LogicalKeyboardKey.delete);
    expect(cortes(tester), isEmpty);
  });

  testWidgets('Shift+seta empurra a seleção sem mexer no cursor', (
    tester,
  ) async {
    await abrir(tester, comMusica: true);
    await tester.tap(momento(30.0));
    await tester.pump();
    final antes = cortes(tester).first.atS;

    await teclar(tester, LogicalKeyboardKey.arrowRight, shift: true);

    expect(cortes(tester).first.atS, closeTo(antes + 0.1, 1e-6));
  });

  testWidgets('a lista de atalhos está ao alcance', (tester) async {
    await abrir(tester, comMusica: true);
    // `pumpAndSettle` não serve aqui: sem plugin de vídeo nos testes, o monitor
    // fica com um indicador girando para sempre e a árvore nunca "assenta".
    await tester.tap(find.byKey(const Key('menu-da-tela')));
    // a rota do menu entra animando, e enquanto anima ela absorve o toque
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.tap(
      find.widgetWithText(PopupMenuItem<String>, 'Atalhos do teclado'),
    );
    // o menu fecha, só então o `onSelected` dispara, e só então o diálogo abre:
    // são três quadros de animação, não um
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }

    expect(find.text('dividir o corte sob o cursor'), findsOneWidget);
  });

  // ── camadas ───────────────────────────────────────────────────────────────

  testWidgets('a tela abre com uma camada, e o botão cria outra', (
    tester,
  ) async {
    await abrir(tester, comMusica: true);
    MusicTimeline regua() =>
        tester.widget<MusicTimeline>(find.byType(MusicTimeline));

    expect(regua().layers, hasLength(1));

    await tester.tap(find.byTooltip('Nova camada'));
    await tester.pump();

    expect(regua().layers, hasLength(2));
    expect(regua().camadaAtiva, 1, reason: 'passa-se a trabalhar na nova');
  });

  testWidgets('a última camada não pode ser tirada', (tester) async {
    await abrir(tester, comMusica: true);
    final botao = tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.layers_clear_outlined),
    );
    expect(botao.onPressed, isNull);
  });

  testWidgets('o clipe novo entra na camada ativa', (tester) async {
    await abrir(tester, comMusica: true);
    await tester.tap(find.byTooltip('Nova camada'));
    await tester.pump();
    await tester.tap(momento(30.0));
    await tester.pump();

    final regua = tester.widget<MusicTimeline>(find.byType(MusicTimeline));
    expect(regua.layers[0].clips, isEmpty);
    expect(regua.layers[1].clips, hasLength(1));
  });

  testWidgets('esconder uma camada tira os clipes dela da régua', (
    tester,
  ) async {
    await abrir(tester, comMusica: true);
    await tester.tap(momento(30.0));
    await tester.pump();
    expect(bloco(tester, 0), findsOneWidget);

    await tester.tap(find.byTooltip('esconder'));
    await tester.pump();

    // o clipe continua na montagem, mas some do desenho
    final regua = tester.widget<MusicTimeline>(find.byType(MusicTimeline));
    expect(regua.layers.first.clips, hasLength(1));
    expect(regua.layers.first.hidden, isTrue);
    expect(
      find.byKey(ValueKey('bloco-${regua.layers.first.clips.first.id}')),
      findsNothing,
    );
  });

  testWidgets('desfazer volta o esconder', (tester) async {
    // mexer numa camada é edição como qualquer outra
    await abrir(tester, comMusica: true);
    await tester.tap(momento(30.0));
    await tester.pump();
    await tester.tap(find.byTooltip('esconder'));
    await tester.pump();

    await teclar(tester, LogicalKeyboardKey.keyZ, ctrl: true);

    expect(
      tester
          .widget<MusicTimeline>(find.byType(MusicTimeline))
          .layers
          .first
          .hidden,
      isFalse,
    );
  });

  testWidgets('camada travada não deixa arrastar o clipe', (tester) async {
    await abrir(tester, comMusica: true);
    await tester.tap(momento(30.0));
    await tester.pump();
    await tester.tap(find.byTooltip('travar'));
    await tester.pump();

    await arrastarDevagar(tester, bloco(tester, 0), 120);

    expect(primeiroCorte(tester).atS, 0, reason: 'travada é travada');
  });

  // ── biblioteca de mídia ───────────────────────────────────────────────────

  testWidgets('a lateral tem as duas prateleiras', (tester) async {
    await abrir(tester, comMusica: true);

    expect(find.text('Momentos'), findsOneWidget);
    expect(find.text('Biblioteca'), findsOneWidget);
  });

  testWidgets('biblioteca vazia diz que está vazia', (tester) async {
    // sem `comMusica` a partida não tem mídia nenhuma -- a música mora aqui
    await abrir(tester);
    await aba(tester, 'Biblioteca');

    expect(find.text('Nada aqui ainda.'), findsOneWidget);
    expect(find.text('Trazer'), findsOneWidget);
  });

  testWidgets('um item da biblioteca vira clipe na régua', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final job = Job.fromJson({
      ...jobJson(comMusica: true),
      'media': [
        {
          'id': 'm1',
          'kind': 'image',
          'status': 'ready',
          'name': 'selo.png',
          'width': 320,
          'height': 180,
          'duration_s': 0.0,
        },
      ],
    });
    await tester.pumpWidget(MaterialApp(home: TimelineScreen(job: job)));
    await tester.pump();

    await aba(tester, 'Biblioteca');
    // o nome aparece na biblioteca e também na lista de marcas d'água da saída
    expect(find.text('selo.png'), findsWidgets);
    expect(find.byKey(const ValueKey('midia-m1')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('midia-m1')));
    await tester.pump();

    final clip = cortes(tester).single;
    expect(clip.source, 'media');
    expect(clip.mediaId, 'm1');
    expect(clip.durationS, greaterThan(0));
  });

  testWidgets('não deixa tirar da biblioteca o que está na montagem', (
    tester,
  ) async {
    // um clipe apontando para ela ficaria órfão, e o pedido seria recusado
    await tester.binding.setSurfaceSize(const Size(1000, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final job = Job.fromJson({
      ...jobJson(comMusica: true),
      'media': [
        {
          'id': 'm1',
          'kind': 'image',
          'status': 'ready',
          'name': 'selo.png',
          'width': 320,
          'height': 180,
        },
      ],
    });
    await tester.pumpWidget(MaterialApp(home: TimelineScreen(job: job)));
    await tester.pump();
    await aba(tester, 'Biblioteca');
    await tester.tap(find.byKey(const ValueKey('midia-m1')));
    await tester.pump();

    await tester.tap(find.byTooltip('Tirar da biblioteca'));
    await tester.pump();

    expect(find.textContaining('está na montagem'), findsOneWidget);
    expect(find.byKey(const ValueKey('midia-m1')), findsOneWidget);
  });

  // ── efeitos ───────────────────────────────────────────────────────────────

  testWidgets('o painel de efeitos abre no bloco escolhido', (tester) async {
    await abrir(tester, comMusica: true);
    await tester.tap(momento(30.0));
    await tester.pump();

    expect(find.text('Efeitos'), findsOneWidget);

    await tester.tap(find.text('Efeitos'));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(find.text('Velocidade'), findsOneWidget);
    expect(find.text('Entrada'), findsOneWidget);
    expect(find.text('Cor'), findsOneWidget);
    expect(find.text('Aproximar'), findsOneWidget);
    expect(find.text('Congelar'), findsOneWidget);
  });

  testWidgets('o punch entra pronto, num toque', (tester) async {
    await abrir(tester, comMusica: true);
    await tester.tap(momento(30.0));
    await tester.pump();
    await tester.tap(find.text('Efeitos'));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    await tester.tap(find.text('médio'));
    await tester.pump();

    final clip = primeiroCorte(tester);
    expect(clip.zoom, hasLength(3));
    expect(clip.zoom[1].scale, 1.6);
    // e dá para tirar
    await tester.tap(find.text('tirar'));
    await tester.pump();
    expect(primeiroCorte(tester).zoom, isEmpty);
  });

  testWidgets('a mistura aparece quando há música na régua', (tester) async {
    // ter a música na biblioteca não é ter música no vídeo: só há o que
    // equilibrar depois que ela entra na régua
    await abrir(tester, comMusica: true);
    expect(find.text('Mistura'), findsNothing);

    await aba(tester, 'Biblioteca');
    await tester.tap(find.byKey(const ValueKey('midia-m1')));
    await assentar(tester);
    await aba(tester, 'Momentos');

    expect(find.text('Mistura'), findsOneWidget);
    expect(find.textContaining('o tiro aparece por baixo'), findsOneWidget);
  });

  testWidgets('sem música não há mistura a fazer', (tester) async {
    await abrir(tester);
    expect(find.text('Mistura'), findsNothing);
  });

  // ── texto ─────────────────────────────────────────────────────────────────

  /// Abre o menu de escrever na tela e escolhe um item.
  Future<void> escrever(WidgetTester tester, String item) async {
    await tester.tap(find.byTooltip('Escrever na tela'));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.tap(find.text(item));
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }
  }

  testWidgets('texto livre entra numa camada nova, por cima', (tester) async {
    await abrir(tester, comMusica: true);
    await tester.tap(momento(30.0));
    await tester.pump();

    await escrever(tester, 'Texto livre');

    final regua = tester.widget<MusicTimeline>(find.byType(MusicTimeline));
    expect(regua.layers, hasLength(2), reason: 'texto vai por cima da imagem');
    expect(regua.layers[1].clips.single.isText, isTrue);
    expect(regua.layers[1].clips.single.text, 'TEXTO');
  });

  testWidgets('o contador de eliminações se escreve sozinho', (tester) async {
    await abrir(tester, comMusica: true);
    // duas eliminações na montagem
    await tester.tap(momento(30.0));
    await tester.pump();
    await tester.tap(momento(30.0));
    await tester.pump();

    await escrever(tester, 'Contador de eliminações');

    final regua = tester.widget<MusicTimeline>(find.byType(MusicTimeline));
    final textos = [
      for (final l in regua.layers)
        for (final c in l.clips)
          if (c.isText) c.text,
    ];
    expect(textos, ['1', '2']);
  });

  testWidgets('sem eliminação, o contador avisa em vez de não fazer nada', (
    tester,
  ) async {
    await abrir(tester, comMusica: true);
    await tester.tap(momento(75.0)); // um dardo, não uma eliminação
    await tester.pump();

    await escrever(tester, 'Contador de eliminações');

    expect(find.textContaining('Não há'), findsOneWidget);
  });

  testWidgets('o clipe de texto se edita pelo inspetor', (tester) async {
    await abrir(tester, comMusica: true);
    await escrever(tester, 'Texto livre');

    expect(find.text('O que está escrito'), findsOneWidget);
    await tester.enterText(
      find.widgetWithText(TextField, 'O que está escrito'),
      'GG',
    );
    await tester.pump();

    final regua = tester.widget<MusicTimeline>(find.byType(MusicTimeline));
    expect(regua.layers.last.clips.single.text, 'GG');
  });

  group('painel de saída', () {
    /// O resumo é a única coisa da tela que diz o que vai sair de verdade.
    String resumo(WidgetTester tester) =>
        tester.widget<Text>(find.textContaining(RegExp(r'^\d+x\d+'))).data!;

    testWidgets('sem escolher nada, sai no tamanho da gravação', (
      tester,
    ) async {
      await abrir(tester);
      await tester.tap(momento(30.0));
      await tester.pump();

      expect(resumo(tester), startsWith('1920x1080'));
      // e não há o que desfazer: o botão de voltar ao padrão nem aparece
      expect(find.text('Padrão'), findsNothing);
    });

    testWidgets('escolher vertical muda a saída, e só ela', (tester) async {
      await abrir(tester);
      await tester.tap(momento(30.0));
      await tester.pump();
      final antes = cortes(tester).single;

      await tester.tap(find.text('Vertical'));
      await tester.pump();

      expect(resumo(tester), startsWith('1080x1920'));
      // a montagem não se mexeu: é uma janela, não uma edição
      final depois = cortes(tester).single;
      expect(depois.atS, antes.atS);
      expect(depois.durationS, antes.durationS);
      expect(depois.startS, antes.startS);
    });

    testWidgets('a escolha entre cortar e caber só aparece quando importa', (
      tester,
    ) async {
      await abrir(tester);
      await tester.tap(momento(30.0));
      await tester.pump();

      // 720p de uma gravação 16:9 tem a mesma proporção: não há o que decidir
      await tester.tap(find.text('720p'));
      await tester.pump();
      expect(find.text('Preencher'), findsNothing);

      await tester.tap(find.text('Vertical'));
      await tester.pump();
      expect(find.text('Preencher'), findsOneWidget);
      expect(find.text('Caber'), findsOneWidget);
    });

    testWidgets('dá para voltar ao padrão de uma vez', (tester) async {
      await abrir(tester);
      await tester.tap(momento(30.0));
      await tester.pump();

      await tester.tap(find.text('Vertical'));
      await tester.pump();
      await tester.tap(find.text('Leve'));
      await tester.pump();
      expect(resumo(tester), startsWith('1080x1920'));

      await tester.tap(find.text('Padrão'));
      await tester.pump();
      expect(resumo(tester), startsWith('1920x1080'));
      expect(find.text('Padrão'), findsNothing);
    });

    testWidgets('mudar a saída se desfaz como qualquer outra edição', (
      tester,
    ) async {
      await abrir(tester);
      await tester.tap(momento(30.0));
      await tester.pump();

      await tester.tap(find.text('Vertical'));
      await tester.pump();
      expect(resumo(tester), startsWith('1080x1920'));

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();

      expect(resumo(tester), startsWith('1920x1080'));
      expect(cortes(tester), hasLength(1), reason: 'o corte continua lá');
    });

    testWidgets('sem seleção não dá para exportar só a seleção', (
      tester,
    ) async {
      // um corte recém-posto entra selecionado, então o caso a testar é o
      // da montagem em branco — e o de quem acabou de limpar a seleção
      await abrir(tester);

      final chip = tester.widget<ChoiceChip>(
        find.ancestor(
          of: find.text('Só a seleção'),
          matching: find.byType(ChoiceChip),
        ),
      );
      expect(chip.onSelected, isNull);
    });

    testWidgets('exportar a seleção recorta o tempo sem apagar nada', (
      tester,
    ) async {
      await abrir(tester);
      await tester.tap(momento(30.0));
      await tester.tap(momento(75.0));
      await tester.pump();

      // o segundo corte fica selecionado ao entrar; basta pedir o recorte
      await tester.tap(find.text('Só a seleção'));
      await tester.pump();

      expect(cortes(tester), hasLength(2), reason: 'nada foi apagado');
      // a duração anunciada passa a ser a do trecho, não a do vídeo inteiro
      final duracao = cortes(tester)[1].durationS;
      expect(resumo(tester), contains('0:0${duracao.round()}'));
    });
  });

  group('montagens da partida', () {
    Map<String, dynamic> montagemJson({
      required String id,
      required String nome,
      double at = 0,
      String titulo = '',
      int versions = 0,
    }) => {
      'id': id,
      'job_id': 'j1',
      'name': nome,
      'n_clips': 1,
      'duration_s': 2.0,
      'has_music': false,
      'n_versions': versions,
      'created_at': DateTime.now().toIso8601String(),
      'updated_at': DateTime.now().toIso8601String(),
      'data': {
        'title': titulo,
        'layers': [
          {
            'clips': [
              {'at_s': at, 'duration_s': 2.0, 'start_s': 30.0, 'kind': 'kill'},
            ],
          },
        ],
      },
    };

    Future<void> abrirCom(
      WidgetTester tester,
      List<Map<String, dynamic>> montagens,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1000, 2400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final job = Job.fromJson({...jobJson(), 'montages': montagens});
      await tester.pumpWidget(MaterialApp(home: TimelineScreen(job: job)));
      await tester.pump();
    }

    testWidgets('abre a mais recente, e diz qual é', (tester) async {
      // é a que se estava editando, e é a que se quer de volta
      await abrirCom(tester, [
        montagemJson(id: 'm1', nome: 'vertical curta', at: 4),
        montagemJson(id: 'm2', nome: 'a longa'),
      ]);

      expect(find.text('vertical curta'), findsOneWidget);
      expect(cortes(tester).single.atS, 4.0);
    });

    testWidgets('sem montagem nenhuma, a tela abre em branco', (tester) async {
      await abrirCom(tester, const []);

      expect(find.text('Montagem'), findsOneWidget);
      expect(cortes(tester), isEmpty);
    });

    testWidgets('o seletor lista as outras, com o tamanho de cada uma', (
      tester,
    ) async {
      await abrirCom(tester, [
        montagemJson(id: 'm1', nome: 'vertical curta'),
        montagemJson(id: 'm2', nome: 'a longa'),
      ]);

      await tester.tap(find.byKey(const Key('seletor-de-montagem')));
      await assentar(tester);

      expect(find.byKey(const ValueKey('abrir-m1')), findsOneWidget);
      expect(find.byKey(const ValueKey('abrir-m2')), findsOneWidget);
      expect(find.textContaining('1 corte(s)'), findsWidgets);
      expect(find.text('Nova montagem'), findsOneWidget);
    });

    testWidgets('trocar de montagem troca os cortes na régua', (tester) async {
      await abrirCom(tester, [
        montagemJson(id: 'm1', nome: 'primeira', at: 0),
        montagemJson(id: 'm2', nome: 'segunda', at: 9),
      ]);
      expect(cortes(tester).single.atS, 0.0);

      await tester.tap(find.byKey(const Key('seletor-de-montagem')));
      await assentar(tester);
      await tester.tap(find.byKey(const ValueKey('abrir-m2')));
      await assentar(tester);

      expect(cortes(tester).single.atS, 9.0);
      expect(find.text('segunda'), findsOneWidget);
    });

    testWidgets('o desfazer não atravessa a troca de montagem', (tester) async {
      // ele é a memória de uma sessão de trabalho *numa* montagem; desfazer
      // para dentro de outra apagaria o que se acabou de abrir
      await abrirCom(tester, [
        montagemJson(id: 'm1', nome: 'primeira', at: 0),
        montagemJson(id: 'm2', nome: 'segunda', at: 9),
      ]);

      await tester.tap(momento(30.0));
      await tester.pump();
      expect(cortes(tester), hasLength(2));

      await tester.tap(find.byKey(const Key('seletor-de-montagem')));
      await assentar(tester);
      await tester.tap(find.byKey(const ValueKey('abrir-m2')));
      await assentar(tester);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();

      expect(cortes(tester).single.atS, 9.0, reason: 'a segunda continua lá');
    });

    testWidgets('o menu oferece duplicar, versões e predefinições', (
      tester,
    ) async {
      await abrirCom(tester, [montagemJson(id: 'm1', nome: 'uma')]);

      await tester.tap(find.byKey(const Key('menu-da-tela')));
      await assentar(tester);

      expect(find.text('Duplicar esta montagem'), findsOneWidget);
      expect(find.text('Renomear'), findsOneWidget);
      expect(find.text('Histórico de versões…'), findsOneWidget);
      expect(find.text('Aplicar predefinição…'), findsOneWidget);
      expect(find.text('Salvar como predefinição…'), findsOneWidget);
    });

    testWidgets('o título salvo na montagem volta no campo de nome', (
      tester,
    ) async {
      await abrirCom(tester, [
        montagemJson(id: 'm1', nome: 'uma', titulo: 'Ana carregando'),
      ]);

      expect(find.widgetWithText(TextField, 'Ana carregando'), findsOneWidget);
    });
  });

  group('música na régua', () {
    /// A camada de som da montagem que está na tela, se já houver uma.
    Layer? camadaDeSom(WidgetTester tester) => tester
        .widget<MusicTimeline>(find.byType(MusicTimeline))
        .layers
        .where((l) => l.isAudio)
        .firstOrNull;

    /// Põe a música na régua pelo caminho de verdade: a Biblioteca.
    Future<void> porNaRegua(WidgetTester tester) async {
      await aba(tester, 'Biblioteca');
      await tester.tap(find.byKey(const ValueKey('midia-m1')));
      await assentar(tester);
      await aba(tester, 'Momentos');
    }

    testWidgets('o botão abre uma camada só de som', (tester) async {
      await abrir(tester, comMusica: true);

      await tester.tap(find.byKey(const Key('nova-camada-de-musica')));
      await assentar(tester);

      expect(camadaDeSom(tester), isNotNull);
      expect(camadaDeSom(tester)!.clips, isEmpty);
    });

    testWidgets('a música da biblioteca abre a camada de som sozinha', (
      tester,
    ) async {
      // pedir música e receber um pedido de camada seria burocracia
      await abrir(tester, comMusica: true);
      await tester.tap(momento(30.0));
      await tester.pump();

      await porNaRegua(tester);

      final bloco = camadaDeSom(tester)!.clips.single;
      expect(bloco.mediaId, 'm1');
      expect(bloco.source, 'media');
      expect(bloco.atS, 0);
    });

    testWidgets('pôr na régua entra na cabeça de leitura', (tester) async {
      await abrir(tester, comMusica: true);
      await tester.tap(momento(30.0));
      await tester.pump();
      await cursorEm(tester, 3.2);

      await porNaRegua(tester);

      final bloco = camadaDeSom(tester)!.clips.single;
      expect(bloco.mediaId, 'm1');
      expect(bloco.atS, closeTo(3.2, 0.2));
    });

    testWidgets('duas músicas cabem na mesma camada, uma depois da outra', (
      tester,
    ) async {
      await abrir(tester, comMusica: true);
      await tester.tap(momento(30.0));
      await tester.pump();

      await porNaRegua(tester);
      await porNaRegua(tester);

      // a segunda não empurra a primeira: entra depois do que já está lá
      final blocos = camadaDeSom(tester)!.clips;
      expect(blocos, hasLength(2));
      expect(blocos.last.atS, closeTo(blocos.first.untilS, 1e-6));
    });

    /// Arrasta um bloco até soltá-lo **exatamente** em [destinoS].
    ///
    /// `arrastarDevagar` anda em passos de 3px e passa do ponto pedido: para
    /// medir onde o ímã grudou é preciso saber de onde ele partiu, senão a
    /// sobra do último passo responde pelo ímã.
    Future<void> arrastarAte(
      WidgetTester tester,
      Finder alvo,
      double destinoS,
      double partiuS,
    ) async {
      final total = (destinoS - partiuS) * px + comidoPeloSlop;
      final gesto = await tester.startGesture(tester.getCenter(alvo));
      var andou = 0.0;
      while (andou < total) {
        final passo = total - andou < 3 ? total - andou : 3.0;
        await gesto.moveBy(Offset(passo, 0));
        await tester.pump();
        andou += passo;
      }
      await gesto.up();
      await tester.pump();
    }

    testWidgets('o painel de um vídeo da biblioteca diz de que arquivo saiu', (
      tester,
    ) async {
      // "Evento de 00:00" é rótulo de momento da partida; um clipe importado
      // não veio de momento nenhum
      await tester.binding.setSurfaceSize(const Size(1000, 2400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final job = Job.fromJson({
        ...jobJson(),
        'media': [
          {
            'id': 'v1',
            'kind': 'video',
            'status': 'ready',
            'name': 'vinheta.mp4',
            'duration_s': 4.0,
            'width': 1920,
            'height': 1080,
          },
        ],
      });
      await tester.pumpWidget(MaterialApp(home: TimelineScreen(job: job)));
      await tester.pump();

      await aba(tester, 'Biblioteca');
      await tester.tap(find.byKey(const ValueKey('midia-v1')));
      await assentar(tester);

      expect(find.text('vinheta.mp4'), findsWidgets);
      expect(find.textContaining('Evento de'), findsNothing);
      // imagem tem efeitos: o que não os tem é som
      expect(find.text('Efeitos'), findsOneWidget);
      expect(find.text('Enquadramento'), findsOneWidget);
    });

    testWidgets('o painel do bloco fala de música, não de evento', (
      tester,
    ) async {
      // o bloco não veio de um momento da partida, e não desenha nada: dizer
      // "Evento de 00:00" e oferecer zoom seria mentir duas vezes
      await abrir(tester, comMusica: true);
      await tester.tap(momento(30.0));
      await tester.pump();
      await porNaRegua(tester);

      expect(find.text('musica.mp3'), findsWidgets);
      expect(
        find.textContaining('a partir de 00:00 da música'),
        findsOneWidget,
      );
      expect(find.text('Trecho da música'), findsOneWidget);
      expect(find.text('Enquadramento'), findsNothing);
      expect(find.text('Efeitos'), findsNothing);
    });

    testWidgets('o ímã passa a seguir a música que está tocando', (
      tester,
    ) async {
      // é o motivo de a grade ser por bloco: um vídeo com duas faixas tem dois
      // andamentos, e grudar na batida da outra seria pior do que não grudar
      await abrir(tester, comMusica: true);
      await tester.tap(momento(30.0));
      await tester.pump();
      await cursorEm(tester, 3.2);
      await porNaRegua(tester);

      // a música entrou fora da grade de meio em meio segundo da faixa
      // contínua, e é a partir da entrada dela que a grade passa a contar
      final entrada = camadaDeSom(tester)!.clips.single.atS;
      expect(entrada % 0.5, closeTo(0.2, 1e-6));

      // solto 0,04s antes de uma batida *da música na régua* — que na grade
      // antiga não é batida nenhuma, e ficaria onde foi solto
      await arrastarAte(
        tester,
        bloco(tester, 0),
        entrada + 0.46,
        primeiroCorte(tester).atS,
      );

      expect(primeiroCorte(tester).atS, closeTo(entrada + 0.5, 1e-6));
    });
  });

  // ── arrastar da prateleira para a régua ───────────────────────────────────
  //
  // Clicar põe na cabeça de leitura, que serve para quem está montando na
  // ordem. Arrastar é para quem já sabe onde quer a coisa — e é o gesto que
  // qualquer editor tem.

  group('soltar na régua', () {
    /// Arrasta [origem] até [segundos] da régua, na **pista** [linha].
    ///
    /// Pista é o que se vê: a de cima é a linha 0. A camada correspondente é a
    /// conta inversa — a lista de camadas vai da de baixo para a de cima.
    Future<void> arrastarPara(
      WidgetTester tester,
      Finder origem,
      double segundos, {
      int linha = 0,
    }) async {
      final regua = tester.getRect(find.byType(MusicTimeline));
      final destino = Offset(
        regua.left + MusicTimeline.larguraDosCabecalhos + 1 + segundos * 60,
        regua.top +
            MusicTimeline.waveHeight +
            linha * MusicTimeline.blockHeight +
            MusicTimeline.blockHeight / 2,
      );
      final gesto = await tester.startGesture(tester.getCenter(origem));
      // passos pequenos: o `Draggable` só nasce depois de vencer o slop, e é
      // andando que o alvo recebe o `onWillAccept`
      final de = tester.getCenter(origem);
      for (var i = 1; i <= 20; i++) {
        await gesto.moveTo(Offset.lerp(de, destino, i / 20)!);
        await tester.pump();
      }
      await gesto.up();
      await assentar(tester);
    }

    testWidgets('um momento largado na régua vira bloco onde caiu', (
      tester,
    ) async {
      await abrir(tester);

      await arrastarPara(tester, momento(30.0), 4.0);

      expect(cortes(tester), hasLength(1));
      expect(cortes(tester).single.sourceT, 30.0);
      expect(cortes(tester).single.atS, closeTo(4.0, 0.2));
    });

    testWidgets('a cabeça de leitura não se mexe com o arrasto', (
      tester,
    ) async {
      // largar num ponto é dizer onde o bloco entra, e não onde o vídeo está
      await abrir(tester);
      await cursorEm(tester, 1);

      await arrastarPara(tester, momento(30.0), 6.0);

      expect(cortes(tester).single.atS, closeTo(6.0, 0.2));
      expect(find.text('00:01'), findsOneWidget);
    });

    testWidgets('largar na pista de cima põe o bloco na camada de cima', (
      tester,
    ) async {
      await abrir(tester);
      await tester.tap(find.byTooltip('Nova camada'));
      await assentar(tester);

      // pista 0 é a de cima na tela, e a de cima é a última da lista
      await arrastarPara(tester, momento(30.0), 2.0);

      final camadas = tester
          .widget<MusicTimeline>(find.byType(MusicTimeline))
          .layers;
      expect(camadas[0].clips, isEmpty);
      expect(camadas[1].clips, hasLength(1));
    });

    testWidgets('uma música da biblioteca largada na régua vira bloco', (
      tester,
    ) async {
      await abrir(tester, comMusica: true);
      await tester.tap(momento(30.0));
      await tester.pump();
      await aba(tester, 'Biblioteca');

      await arrastarPara(tester, find.byKey(const ValueKey('midia-m1')), 3.0);

      final som = tester
          .widget<MusicTimeline>(find.byType(MusicTimeline))
          .layers
          .where((l) => l.isAudio)
          .single;
      expect(som.clips.single.mediaId, 'm1');
      expect(som.clips.single.atS, closeTo(3.0, 0.2));
    });

    testWidgets('um momento largado na camada de som é recusado', (
      tester,
    ) async {
      // uma camada desenha ou toca; o servidor recusaria, e recusar aqui
      // explica melhor
      await abrir(tester, comMusica: true);
      await tester.tap(find.byKey(const Key('nova-camada-de-musica')));
      await assentar(tester);

      // a camada de som nasce por último, e por isso fica na pista de cima
      await arrastarPara(tester, momento(30.0), 2.0);

      expect(cortes(tester), isEmpty);
      expect(find.textContaining('camada é de som'), findsOneWidget);
    });
  });

  // ── o relógio ─────────────────────────────────────────────────────────────

  group('tocar', () {
    testWidgets('sem nada montado não há o que tocar', (tester) async {
      await abrir(tester);
      final botao = tester.widget<IconButton>(
        find.ancestor(
          of: find.byIcon(Icons.play_arrow),
          matching: find.byType(IconButton),
        ),
      );
      expect(botao.onPressed, isNull);
    });

    testWidgets('tocar anda a cabeça de leitura pelo vídeo', (tester) async {
      // o relógio é o vídeo, e não a música: um vídeo sem trilha nenhuma
      // continua sendo um vídeo a rever
      await abrir(tester);
      await tester.tap(momento(30.0));
      await tester.pump();

      await tester.tap(find.byIcon(Icons.play_arrow));
      await tester.pump();
      expect(find.byIcon(Icons.pause), findsOneWidget);

      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      final regua = tester.widget<MusicTimeline>(find.byType(MusicTimeline));
      expect(regua.playheadS, greaterThan(0.3), reason: 'a cabeça andou');

      await tester.tap(find.byIcon(Icons.pause));
      await tester.pump();
      expect(find.byIcon(Icons.play_arrow), findsOneWidget);
    });

    testWidgets('no fim do vídeo ele para sozinho', (tester) async {
      await abrir(tester);
      await tester.tap(momento(30.0));
      await tester.pump();

      await tester.tap(find.byIcon(Icons.play_arrow));
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }

      expect(find.byIcon(Icons.play_arrow), findsOneWidget);
    });
  });

  // ── o texto no monitor ────────────────────────────────────────────────────
  //
  // O texto existia na régua e no vídeo gerado, e em lugar nenhum entre os
  // dois: para saber onde a frase ia parar era preciso gerar o vídeo.

  group('texto no monitor', () {
    /// O clipe de texto que está na montagem.
    TimelineClip textoNaRegua(WidgetTester tester) =>
        cortes(tester).firstWhere((c) => c.isText);

    testWidgets('a frase aparece por cima da imagem', (tester) async {
      await abrir(tester);
      await tester.tap(momento(30.0));
      await tester.pump();
      await escrever(tester, 'Texto livre');

      expect(
        find.byKey(ValueKey('texto-no-quadro-${textoNaRegua(tester).id}')),
        findsOneWidget,
      );
    });

    testWidgets('some quando a cabeça de leitura sai de cima dele', (
      tester,
    ) async {
      // o monitor mostra o que vai sair naquele instante, e nada mais
      await abrir(tester);
      await tester.tap(momento(30.0));
      await tester.pump();
      await escrever(tester, 'Texto livre');
      final id = textoNaRegua(tester).id;

      await cursorEm(tester, 6);

      expect(find.byKey(ValueKey('frase-$id')), findsNothing);
    });

    testWidgets('arrastar a frase no monitor a reposiciona no quadro', (
      tester,
    ) async {
      await abrir(tester);
      await tester.tap(momento(30.0));
      await tester.pump();
      await escrever(tester, 'Texto livre');
      final id = textoNaRegua(tester).id;
      expect(textoNaRegua(tester).transform.x, 0);

      final antes = textoNaRegua(tester);
      final alvo = find.byKey(ValueKey('frase-$id'));
      final monitor = tester.getSize(find.byType(PreviewPlayer));
      await tester.drag(alvo, Offset(monitor.width / 3, 0));
      await assentar(tester);

      final depois = textoNaRegua(tester);
      // para a direita e só para a direita — `y` não se mexe num arrasto
      // horizontal, e o bloco não sai do lugar na régua
      expect(depois.transform.x, greaterThan(0.2));
      expect(depois.transform.y, closeTo(antes.transform.y, 0.01));
      expect(depois.atS, antes.atS);
    });

    testWidgets('a frase não sai do quadro', (tester) async {
      await abrir(tester);
      await tester.tap(momento(30.0));
      await tester.pump();
      await escrever(tester, 'Texto livre');
      final id = textoNaRegua(tester).id;

      // um arrasto que passa da borda: a frase encosta e para
      final alvo = find.byKey(ValueKey('frase-$id'));
      final monitor = tester.getSize(find.byType(PreviewPlayer));
      await tester.drag(
        alvo,
        Offset(monitor.width * 0.8, monitor.height * 0.8),
      );
      await assentar(tester);

      expect(textoNaRegua(tester).transform.x, 1.0);
      expect(textoNaRegua(tester).transform.y, 1.0);
    });

    testWidgets('reposicionar entra no desfazer', (tester) async {
      await abrir(tester);
      await tester.tap(momento(30.0));
      await tester.pump();
      await escrever(tester, 'Texto livre');
      final id = textoNaRegua(tester).id;

      final monitor = tester.getSize(find.byType(PreviewPlayer));
      await tester.drag(
        find.byKey(ValueKey('frase-$id')),
        Offset(monitor.width / 3, 0),
      );
      await assentar(tester);
      expect(textoNaRegua(tester).transform.x, greaterThan(0.2));

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();

      expect(textoNaRegua(tester).transform.x, 0);
    });
  });

  // ── a ordem das camadas ───────────────────────────────────────────────────

  group('reordenar camadas', () {
    testWidgets('arrastar um cabeçalho sobre o outro troca a ordem', (
      tester,
    ) async {
      await abrir(tester);
      await tester.tap(momento(30.0));
      await tester.pump();
      // uma segunda camada, com um bloco que a identifique
      await tester.tap(find.byTooltip('Nova camada'));
      await assentar(tester);
      await cursorEm(tester, 8);
      await tester.tap(momento(75.0));
      await tester.pump();

      List<double> deCada(WidgetTester t) => [
        for (final l
            in t.widget<MusicTimeline>(find.byType(MusicTimeline)).layers)
          if (l.clips.isNotEmpty) l.clips.first.sourceT else -1,
      ];
      expect(deCada(tester), [30.0, 75.0]);

      final de = tester.getCenter(find.byKey(const ValueKey('cabecalho-0')));
      final para = tester.getCenter(find.byKey(const ValueKey('cabecalho-1')));
      final gesto = await tester.startGesture(de);
      // toque longo, que é o caminho do dedo; no ponteiro há a alça, que
      // arrasta na hora
      await tester.pump(const Duration(milliseconds: 400));
      for (var i = 1; i <= 10; i++) {
        await gesto.moveTo(Offset.lerp(de, para, i / 10)!);
        await tester.pump();
      }
      await gesto.up();
      await assentar(tester);

      expect(deCada(tester), [75.0, 30.0], reason: 'a de baixo subiu');
    });

    testWidgets('a alça arrasta na hora, sem esperar toque longo', (
      tester,
    ) async {
      // no desktop ninguém segura o botão do mouse para arrastar uma pista
      await abrir(tester);
      await tester.tap(momento(30.0));
      await tester.pump();
      await tester.tap(find.byTooltip('Nova camada'));
      await assentar(tester);

      expect(
        find.byTooltip('Arraste para mudar a ordem das camadas'),
        findsNWidgets(2),
      );

      final de = tester.getCenter(
        find.descendant(
          of: find.byKey(const ValueKey('cabecalho-0')),
          matching: find.byTooltip('Arraste para mudar a ordem das camadas'),
        ),
      );
      final para = tester.getCenter(find.byKey(const ValueKey('cabecalho-1')));
      final gesto = await tester.startGesture(de);
      for (var i = 1; i <= 10; i++) {
        await gesto.moveTo(Offset.lerp(de, para, i / 10)!);
        await tester.pump();
      }
      await gesto.up();
      await assentar(tester);

      final camadas = tester
          .widget<MusicTimeline>(find.byType(MusicTimeline))
          .layers;
      expect(camadas[1].clips, hasLength(1), reason: 'a de baixo subiu');
    });
  });

  // ── mover entre camadas ───────────────────────────────────────────────────

  group('levar um bloco para outra camada', () {
    testWidgets('arrastar para cima leva o bloco para a camada de cima', (
      tester,
    ) async {
      await abrir(tester);
      await tester.tap(momento(30.0));
      await tester.pump();
      await tester.tap(find.byTooltip('Nova camada'));
      await assentar(tester);

      final id = cortes(tester).first.id;
      // para cima na tela: uma pista acima é uma camada acima na pilha
      await tester.drag(
        find.byKey(ValueKey('bloco-$id')),
        const Offset(0, -MusicTimeline.blockHeight),
      );
      await assentar(tester);

      final camadas = tester
          .widget<MusicTimeline>(find.byType(MusicTimeline))
          .layers;
      expect(camadas[0].clips, isEmpty);
      expect(camadas[1].clips.single.id, id);
    });

    testWidgets('para a camada de som, ele explica em vez de só recusar', (
      tester,
    ) async {
      // recusar em silêncio é o pior dos dois mundos: o bloco volta e quem
      // arrastou não sabe se o gesto não pegou ou se não era possível
      await abrir(tester, comMusica: true);
      await tester.tap(momento(30.0));
      await tester.pump();
      await tester.tap(find.byKey(const Key('nova-camada-de-musica')));
      await assentar(tester);

      final id = cortes(tester).first.id;
      await tester.drag(
        find.byKey(ValueKey('bloco-$id')),
        const Offset(0, -MusicTimeline.blockHeight),
      );
      await assentar(tester);

      expect(find.textContaining('camada é de som'), findsOneWidget);
      final camadas = tester
          .widget<MusicTimeline>(find.byType(MusicTimeline))
          .layers;
      expect(camadas[0].clips.single.id, id, reason: 'ficou onde estava');
    });
  });

  // ── o teclado e os campos de texto ────────────────────────────────────────
  //
  // Os atalhos são de uma tecla só: "S" divide o corte, Delete apaga o bloco.
  // Sobre um campo de texto isso é desastre — foi o que apareceu ao renomear a
  // montagem: o nome não recebia o "s" e apagar comia um bloco da régua.

  group('atalhos e campos de texto', () {
    /// Põe a cabeça de leitura no meio do primeiro bloco, onde dividir vale.
    Future<void> comUmBlocoEOCursorNoMeio(WidgetTester tester) async {
      await abrir(tester);
      await tester.tap(momento(30.0));
      await tester.pump();
      await cursorEm(tester, 0.6);
    }

    testWidgets('com o foco na régua, "S" continua dividindo', (tester) async {
      await comUmBlocoEOCursorNoMeio(tester);
      expect(cortes(tester), hasLength(1));

      await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
      await tester.pump();

      expect(cortes(tester), hasLength(2));
    });

    /// Os atalhos registrados agora.
    ///
    /// Um atalho que "trata" a tecla sem fazer nada é pior do que não existir:
    /// o `CallbackShortcuts` marca a tecla como tratada assim que algum atalho
    /// a aceita, e no navegador tecla tratada vira `preventDefault` — a letra
    /// não chega ao campo. Por isso a correção é **não registrar** atalho
    /// nenhum enquanto alguém escreve.
    Map<ShortcutActivator, VoidCallback> atalhos(WidgetTester tester) => tester
        .widget<CallbackShortcuts>(find.byType(CallbackShortcuts))
        .bindings;

    testWidgets('escrevendo no nome do vídeo, "S" é a letra s', (tester) async {
      await comUmBlocoEOCursorNoMeio(tester);
      expect(atalhos(tester), isNotEmpty);

      final campo = find.widgetWithText(TextField, 'Minha montagem');
      await tester.tap(campo);
      await assentar(tester);

      expect(atalhos(tester), isEmpty, reason: 'a tecla vai para o campo');

      await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
      await tester.pump();
      expect(cortes(tester), hasLength(1), reason: 'não dividiu nada');
    });

    testWidgets('tocar na régua devolve os atalhos', (tester) async {
      // sem isto, tocar no campo uma vez matava os atalhos para sempre: nada
      // tira o foco de um `TextField`, e "S" nunca mais dividia nada
      await comUmBlocoEOCursorNoMeio(tester);
      await tester.tap(find.widgetWithText(TextField, 'Minha montagem'));
      await assentar(tester);
      expect(atalhos(tester), isEmpty);

      await cursorEm(tester, 0.6);
      await assentar(tester);

      expect(atalhos(tester), isNotEmpty);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
      await tester.pump();
      expect(cortes(tester), hasLength(2), reason: '"S" voltou a dividir');
    });

    testWidgets('escrevendo no nome do vídeo, apagar não come um bloco', (
      tester,
    ) async {
      await comUmBlocoEOCursorNoMeio(tester);
      final campo = find.widgetWithText(TextField, 'Minha montagem');
      await tester.tap(campo);
      await assentar(tester);

      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.delete);
      await tester.pump();

      expect(cortes(tester), hasLength(1));
    });

    testWidgets('nem Ctrl+Z desfaz a montagem enquanto se escreve', (
      tester,
    ) async {
      // o campo tem o desfazer dele, e é o dele que a pessoa quer ali
      await comUmBlocoEOCursorNoMeio(tester);
      final campo = find.widgetWithText(TextField, 'Minha montagem');
      await tester.tap(campo);
      await assentar(tester);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();

      expect(cortes(tester), hasLength(1), reason: 'o bloco continua lá');
    });

    testWidgets('o diálogo de renomear recebe o que se digita', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 2400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final job = Job.fromJson({
        ...jobJson(),
        'montages': [
          {
            'id': 'm1',
            'job_id': 'j1',
            'name': 'vertical curta',
            'n_clips': 1,
            'duration_s': 2.0,
            'has_music': false,
            'n_versions': 0,
            'created_at': DateTime.now().toIso8601String(),
            'updated_at': DateTime.now().toIso8601String(),
            'data': {
              'layers': [
                {
                  'clips': [
                    {'at_s': 0.0, 'duration_s': 2.0, 'start_s': 30.0},
                  ],
                },
              ],
            },
          },
        ],
      });
      await tester.pumpWidget(MaterialApp(home: TimelineScreen(job: job)));
      await tester.pump();

      await tester.tap(find.byKey(const Key('menu-da-tela')));
      await assentar(tester);
      await tester.tap(find.text('Renomear'));
      await assentar(tester);

      final noDialogo = find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      );
      expect(noDialogo, findsOneWidget);

      await tester.enterText(noDialogo, 'shorts');
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      await tester.pump();

      // apagar apaga uma letra do nome — e não um bloco da régua, que é o que
      // acontecia quando os atalhos da tela alcançavam quem está escrevendo
      expect(tester.widget<TextField>(noDialogo).controller?.text, 'short');
      expect(cortes(tester), hasLength(1));
    });
  });
}
