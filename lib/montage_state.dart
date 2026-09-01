import 'dart:math' as math;

import 'api.dart';
import 'montage.dart';

/// O estado da montagem, inteiro e imutável, mais o histórico que o desfaz.
///
/// Na V1 a tela guardava uma `List<TimelineClip>` e a alterava no lugar, em
/// trinta pontos diferentes. Funcionava para seis operações e não sobreviveria
/// a vinte: não havia como desfazer nada, porque não havia "antes" — o estado
/// anterior era sobrescrito a cada mexida.
///
/// Aqui toda operação recebe um estado e devolve **outro**. Guardar o anterior
/// vira empilhar uma referência, e desfazer vira trocar de referência. A conta
/// que decide *onde* um bloco pode cair continua em `montage.dart`, testada
/// sozinha; este arquivo só cuida de quem é quem e do que veio antes.

/// Gerador dos ids locais dos blocos. Um contador basta: eles só precisam ser
/// únicos dentro de uma sessão de edição, e nunca saem do app.
int _proximoId = 0;
String novoIdDeCorte() => 'c${_proximoId++}';

/// A montagem num instante do tempo.
class MontageState {
  MontageState({
    required List<Layer> layers,
    Set<String>? selecao,
    this.camadaAtiva = 0,
    this.title = '',
    this.beatOffsetS = 0,
    this.beatMultiplier = 1,
    this.beatBar = 1,
    this.musicVolume = 1,
    this.gameVolume = 0,
    this.export = const ExportSpec(),
  }) : layers = List.unmodifiable(
         (layers.isEmpty ? const [Layer()] : layers).map(
           // a garantia tem de alcançar os clipes: `clips` é um getter que
           // devolve lista nova, e travar só ele deixaria a lista de dentro
           // aberta a quem tivesse a camada na mão
           (l) => l.copyWith(clips: List.unmodifiable(l.clips)),
         ),
       ),
       selecao = Set.unmodifiable(selecao ?? const <String>{});

  static MontageState vazio() => MontageState(layers: const [Layer()]);

  /// As camadas, da de baixo para a de cima. Nunca vazia: uma montagem sem
  /// camada nenhuma não teria onde receber o primeiro clipe.
  final List<Layer> layers;

  /// Onde os clipes novos entram.
  final int camadaAtiva;

  /// Quem está selecionado, por id de clipe. Vários, porque operações em lote
  /// são metade do que faz um editor ser um editor.
  final Set<String> selecao;

  final String title;

  /// Correções à grade de batidas — o ímã da tela, não o vídeo.
  final double beatOffsetS;
  final double beatMultiplier;
  final int beatBar;

  /// Volume da música e do som do jogo na mistura final.
  final double musicVolume;
  final double gameVolume;

  /// Como o vídeo final é escrito. Não muda a montagem — muda a janela.
  final ExportSpec export;

  /// Todos os clipes, de todas as camadas, de baixo para cima.
  List<TimelineClip> get clips => [for (final l in layers) ...l.clips];

  /// O que o monitor mostra: os clipes das camadas visíveis, com a de cima
  /// ganhando de quem está embaixo no mesmo instante.
  ///
  /// O preview não compõe — ele mostra um quadro. Então quando duas camadas se
  /// cobrem, o que vale é a de cima, que é o que o servidor vai desenhar por
  /// último.
  List<TimelineClip> get clipesVisiveis {
    final visiveis = <TimelineClip>[];
    for (final l in layers) {
      // uma camada de som não desenha nada: o monitor não tem o que mostrar de
      // um bloco de música, e considerá-lo apagaria o vídeo que está por baixo
      if (l.hidden || l.isAudio) continue;
      for (final c in l.clips) {
        visiveis.removeWhere(
          (v) => c.atS < v.untilS - 1e-6 && v.atS < c.untilS - 1e-6,
        );
        visiveis.add(c);
      }
    }
    return visiveis..sort((a, b) => a.atS.compareTo(b.atS));
  }

  bool get vazia => clips.isEmpty;

  MontageState copyWith({
    List<Layer>? layers,
    Set<String>? selecao,
    int? camadaAtiva,
    String? title,
    double? beatOffsetS,
    double? beatMultiplier,
    int? beatBar,
    double? musicVolume,
    double? gameVolume,
    ExportSpec? export,
  }) => MontageState(
    layers: layers ?? this.layers,
    selecao: selecao ?? this.selecao,
    camadaAtiva: camadaAtiva ?? this.camadaAtiva,
    title: title ?? this.title,
    beatOffsetS: beatOffsetS ?? this.beatOffsetS,
    beatMultiplier: beatMultiplier ?? this.beatMultiplier,
    beatBar: beatBar ?? this.beatBar,
    musicVolume: musicVolume ?? this.musicVolume,
    gameVolume: gameVolume ?? this.gameVolume,
    export: export ?? this.export,
  );

  /// Em que camada, e em que posição dela, está o clipe.
  ///
  /// `null` quando ele não existe mais — o que acontece o tempo todo depois de
  /// um desfazer, e é por isso que toda operação pergunta antes de agir.
  (int, int)? localizar(String id) {
    for (var c = 0; c < layers.length; c++) {
      final i = layers[c].clips.indexWhere((k) => k.id == id);
      if (i >= 0) return (c, i);
    }
    return null;
  }

  TimelineClip? clipe(String id) {
    final onde = localizar(id);
    return onde == null ? null : layers[onde.$1].clips[onde.$2];
  }

  List<TimelineClip> get selecionados => [
    for (final c in clips)
      if (selecao.contains(c.id)) c,
  ];

  /// Troca um clipe pelo seu sucessor, na camada onde ele está.
  MontageState comClipe(int camada, int indice, TimelineClip novo) {
    final lista = [...layers[camada].clips];
    lista[indice] = novo;
    return comCamada(camada, layers[camada].copyWith(clips: lista));
  }

  MontageState comCamada(int indice, Layer nova) {
    final lista = [...layers];
    lista[indice] = nova;
    return copyWith(layers: lista);
  }

  Montage paraEnvio() => Montage(
    title: title,
    layers: layers,
    beatOffsetS: beatOffsetS,
    beatMultiplier: beatMultiplier,
    beatBar: beatBar,
    musicVolume: musicVolume,
    gameVolume: gameVolume,
    export: export,
  );
}

/// Reconstrói o estado a partir do rascunho que voltou do servidor.
///
/// É aqui que os clipes ganham id: o servidor não guarda nenhum, porque para
/// ele um clipe é só um trecho com hora marcada.
MontageState montagemDoRascunho(Montage draft) => MontageState(
  layers: [
    for (final l in draft.layers)
      l.copyWith(
        clips: [for (final c in l.clips) c.copyWith(id: novoIdDeCorte())],
      ),
    // a faixa contínua de antes vira um bloco de música que cobre o vídeo: era
    // exatamente isso que ela fazia, e agora ela tem pontas para pegar
    ...?_aTrilhaViraBloco(draft),
  ],
  title: draft.title,
  beatOffsetS: draft.beatOffsetS,
  beatMultiplier: draft.beatMultiplier,
  beatBar: draft.beatBar,
  musicVolume: draft.musicVolume,
  gameVolume: draft.gameVolume,
  export: draft.export,
);

/// A camada de som que uma montagem antiga ganha ao ser aberta.
///
/// Houve dois jeitos de ter música: a faixa contínua, que tocava por baixo de
/// tudo e não se cortava, e o bloco na régua. Sobrou o segundo. Quem converte o
/// formato velho é o código que lê — o servidor faz o mesmo, na mesma regra.
List<Layer>? _aTrilhaViraBloco(Montage draft) {
  final id = draft.trackId;
  if (id == null || id.isEmpty) return null;
  final ate = duracaoDoVideo([for (final l in draft.layers) ...l.clips]);
  if (ate < kMinCutS) return null;
  return [
    Layer(
      kind: 'audio',
      name: 'Música',
      clips: [
        TimelineClip(
          id: novoIdDeCorte(),
          atS: 0,
          durationS: ate,
          startS: draft.musicStartS,
          source: 'media',
          mediaId: id,
        ),
      ],
    ),
  ];
}

// ─────────────────────────────── operações ──────────────────────────────────
//
// Todas recebem um estado e devolvem outro. A colisão é **por camada**: dois
// clipes no mesmo instante em camadas diferentes é justamente o que camada
// serve para fazer.

/// Põe um clipe novo na camada ativa, empurrando-o para a primeira vaga livre.
MontageState adicionar(
  MontageState s,
  TimelineClip clip, {
  required List<double> beats,
  required bool snap,
}) {
  final camada = s.camadaAtiva.clamp(0, s.layers.length - 1);
  final vaga = proximaVaga(s.layers[camada].clips, clip.atS, clip.durationS);
  final novo = clip.copyWith(
    id: novoIdDeCorte(),
    atS: snap ? math.max(0, snapToBeat(vaga, beats)) : vaga,
  );
  return s
      .comCamada(
        camada,
        s.layers[camada].copyWith(clips: [...s.layers[camada].clips, novo]),
      )
      .copyWith(selecao: {novo.id});
}

MontageState moverBloco(
  MontageState s,
  String id,
  double atS, {
  required List<double> beats,
  required bool snap,
}) {
  final onde = s.localizar(id);
  if (onde == null) return s;
  final (camada, i) = onde;
  return s.comClipe(
    camada,
    i,
    mover(s.layers[camada].clips, i, atS, beats: beats, snap: snap),
  );
}

MontageState esticarBloco(
  MontageState s,
  String id,
  double duracao, {
  required List<double> beats,
  required bool snap,
  double? sourceDurationS,
}) {
  final onde = s.localizar(id);
  if (onde == null) return s;
  final (camada, i) = onde;
  return s.comClipe(
    camada,
    i,
    esticar(
      s.layers[camada].clips,
      i,
      duracao,
      beats: beats,
      snap: snap,
      sourceDurationS: sourceDurationS,
    ),
  );
}

MontageState apararBloco(
  MontageState s,
  String id,
  double atS, {
  required List<double> beats,
  required bool snap,
}) {
  final onde = s.localizar(id);
  if (onde == null) return s;
  final (camada, i) = onde;
  return s.comClipe(
    camada,
    i,
    aparar(s.layers[camada].clips, i, atS, beats: beats, snap: snap),
  );
}

/// Muda um efeito do clipe: velocidade, cor ou fade.
///
/// Todos entram pelo mesmo caminho porque todos são a mesma coisa do ponto de
/// vista do estado — trocar um clipe pelo seu sucessor.
/// Move o conteúdo do clipe dentro do quadro.
///
/// [x] e [y] são deslocamentos do centro normalizados pela metade do quadro —
/// -1 encosta na borda esquerda/de cima, +1 na direita/de baixo. É a mesma
/// conta que o servidor usa, então arrastar o texto no monitor põe a frase
/// exatamente onde ela vai sair.
///
/// Fica no intervalo de -1 a 1: além disso o conteúdo sai do quadro, e um
/// clipe que não aparece é indistinguível de um clipe que sumiu.
MontageState posicionarNoQuadro(
  MontageState s,
  String id, {
  double? x,
  double? y,
  double? escala,
}) {
  final onde = s.localizar(id);
  if (onde == null) return s;
  final (camada, i) = onde;
  final c = s.layers[camada].clips[i];
  final t = c.transform;
  return s.comClipe(
    camada,
    i,
    c.copyWith(
      transform: ClipTransform(
        scale: (escala ?? t.scale).clamp(0.1, 4.0),
        x: (x ?? t.x).clamp(-1.0, 1.0),
        y: (y ?? t.y).clamp(-1.0, 1.0),
        opacity: t.opacity,
      ),
    ),
  );
}

/// Põe a **jogada** de um bloco em [alvoS] do vídeo, de um jeito ou de outro.
///
/// Não é o mesmo que mover o bloco para o cursor: o corte começa antes da
/// jogada, para dar embalo, e é a jogada — a eliminação, o dardo, a pedrada —
/// que precisa cair na batida. Alinhar pela borda deixaria o impacto meio
/// segundo depois dela.
///
/// Há dois jeitos de conseguir isso, e eles mudam coisas diferentes:
///
/// * **andar com o bloco** muda *quando* a cena aparece, e mantém o
///   enquadramento — quanto de embalo há antes da jogada. É o preferido;
/// * **deslizar o conteúdo dentro do bloco** mantém o bloco no lugar e troca
///   *qual* trecho da gravação aparece ali. É o que sobra quando os vizinhos
///   não deixam o bloco andar — o caso comum numa montagem de blocos colados.
///
/// O resultado diz qual dos dois aconteceu, para a tela poder contar.
({MontageState estado, bool deslizou})? alinharMomento(
  MontageState s,
  String id,
  double alvoS, {
  required double sourceDurationS,
}) {
  final onde = s.localizar(id);
  if (onde == null) return null;
  final (camada, i) = onde;
  final c = s.layers[camada].clips[i];
  final marca = momentoNoVideo(c);
  if (marca == null) return null;

  // 1) andar com o bloco
  final destino = math.max(0.0, c.atS + (alvoS - marca));
  final movido = mover(
    s.layers[camada].clips,
    i,
    destino,
    beats: const [],
    snap: false,
  );
  // "moveu" é o bloco ter mudado de lugar, e não `mover` ter devolvido outro
  // objeto: encostado no primeiro quadro, ele devolve o mesmo instante — e aí
  // o alinhamento ainda não aconteceu
  if ((movido.atS - c.atS).abs() > 1e-6) {
    return (estado: s.comClipe(camada, i, movido), deslizou: false);
  }

  // 2) deslizar o conteúdo: a jogada vem até o cursor sem tocar em vizinho
  final limite = math.max(0.0, sourceDurationS - c.durationS);
  final inicio = (c.sourceT - (alvoS - c.atS)).clamp(0.0, limite);
  final deslizado = c.copyWith(startS: inicio);
  if ((inicio - c.startS).abs() < 1e-6 || marcaDoMomento(deslizado) == null) {
    return null;
  }
  return (estado: s.comClipe(camada, i, deslizado), deslizou: true);
}

/// Troca a ordem das camadas — que é a ordem em que o servidor as desenha.
///
/// A de baixo é o fundo, a de cima ganha de quem está embaixo no mesmo
/// instante. Trocar a ordem é, portanto, uma edição de verdade: muda o que
/// aparece.
MontageState reordenarCamadas(MontageState s, int de, int para) {
  if (de == para) return s;
  if (de < 0 || de >= s.layers.length) return s;
  if (para < 0 || para >= s.layers.length) return s;

  final lista = [...s.layers];
  final movida = lista.removeAt(de);
  lista.insert(para, movida);
  return s.copyWith(layers: lista, camadaAtiva: para);
}

MontageState ajustarEfeito(
  MontageState s,
  String id, {
  double? speed,
  ClipColor? color,
  ClipFade? fade,
  List<ZoomKey>? zoom,
  bool? freeze,
  bool? reverse,
}) {
  final onde = s.localizar(id);
  if (onde == null) return s;
  final (camada, i) = onde;
  final c = s.layers[camada].clips[i];

  // um fade maior que o clipe é recusado pelo servidor; apará-lo aqui evita
  // descobrir isso só na hora de gerar
  var novoFade = fade ?? c.fade;
  final soma = novoFade.inS + novoFade.outS;
  if (soma > c.durationS) {
    final escala = c.durationS / soma;
    novoFade = ClipFade(
      inS: novoFade.inS * escala,
      outS: novoFade.outS * escala,
    );
  }

  // congelar e inverter ao mesmo tempo o servidor recusa; aqui um desliga o
  // outro, que é o que a pessoa quis dizer ao ligar o segundo
  final vaiCongelar = freeze ?? c.freeze;
  final vaiInverter = reverse ?? c.reverse;

  return s.comClipe(
    camada,
    i,
    c.copyWith(
      speed: speed?.clamp(0.1, 10.0),
      color: color,
      fade: novoFade,
      zoom: zoom,
      freeze: freeze ?? (vaiInverter ? false : vaiCongelar),
      reverse: reverse ?? (vaiCongelar ? false : vaiInverter),
    ),
  );
}

/// Muda o que está escrito num clipe de texto, ou como.
MontageState trocarTexto(
  MontageState s,
  String id, {
  String? texto,
  ClipTextStyle? estilo,
}) {
  final onde = s.localizar(id);
  if (onde == null) return s;
  final (camada, i) = onde;
  final c = s.layers[camada].clips[i];
  if (!c.isText) return s;

  // o servidor recusa texto vazio, e um clipe invisível na régua seria pior do
  // que um espaço em branco
  final novo = (texto ?? c.text).trim().isEmpty ? c.text : (texto ?? c.text);
  return s.comClipe(camada, i, c.copyWith(text: novo, textStyle: estilo));
}

/// O *punch*: a lente fecha rápido e afrouxa até o fim do clipe.
///
/// Dois movimentos resolvem o efeito mais usado numa montagem de gameplay, e é
/// melhor oferecê-lo pronto do que um editor de curvas que ninguém vai abrir.
List<ZoomKey> punch({double ate = 1.6, double quando = 0.25}) => [
  const ZoomKey(t: 0, scale: 1),
  ZoomKey(t: quando, scale: ate),
  ZoomKey(t: 1, scale: 1 + (ate - 1) * 0.4),
];

/// Move o conteúdo dentro do clipe sem mexer no clipe — o ajuste fino do
/// enquadramento.
MontageState deslocarConteudo(
  MontageState s,
  String id,
  double delta, {
  required double sourceDurationS,
}) {
  final onde = s.localizar(id);
  if (onde == null) return s;
  final (camada, i) = onde;
  final c = s.layers[camada].clips[i];
  final limite = math.max(0.0, sourceDurationS - c.durationS);
  return s.comClipe(
    camada,
    i,
    c.copyWith(startS: (c.startS + delta).clamp(0, limite)),
  );
}

/// Tira os clipes escolhidos da montagem, de onde quer que estejam.
MontageState remover(MontageState s, Set<String> ids) {
  if (ids.isEmpty) return s;
  return s.copyWith(
    layers: [
      for (final l in s.layers)
        l.copyWith(
          clips: [
            for (final c in l.clips)
              if (!ids.contains(c.id)) c,
          ],
        ),
    ],
    selecao: const {},
  );
}

/// Move vários clipes de uma vez, mantendo a distância entre eles.
///
/// O grupo anda junto ou não anda: se qualquer um fosse parar em cima de um que
/// ficou parado — na camada dele —, ou antes do primeiro quadro, o movimento
/// inteiro é recusado. Mover metade de uma seleção desmancharia um arranjo que
/// o usuário já tinha feito.
MontageState moverSelecao(
  MontageState s,
  double delta, {
  required List<double> beats,
  required bool snap,
}) {
  if (s.selecao.isEmpty || delta == 0) return s;

  var passo = delta;
  if (snap) {
    // gruda o grupo pela borda do primeiro clipe: é a referência visível
    final primeiro = s.selecionados
        .map((c) => c.atS)
        .reduce((a, b) => a < b ? a : b);
    passo = snapToBeat(primeiro + delta, beats) - primeiro;
  }

  final novas = <Layer>[];
  for (final l in s.layers) {
    final indices = <int>{
      for (var i = 0; i < l.clips.length; i++)
        if (s.selecao.contains(l.clips[i].id)) i,
    };
    if (indices.isEmpty) {
      novas.add(l);
      continue;
    }
    final lista = [...l.clips];
    for (final i in indices) {
      final destino = lista[i].atS + passo;
      if (!cabeIgnorando(l.clips, destino, lista[i].durationS, indices)) {
        return s;
      }
      lista[i] = lista[i].copyWith(atS: destino);
    }
    novas.add(l.copyWith(clips: lista));
  }
  return s.copyWith(layers: novas);
}

/// Corta um clipe em dois no ponto pedido.
///
/// O que estava enquadrado continua enquadrado: a metade da direita começa na
/// gravação exatamente onde a da esquerda parou, então a emenda é invisível até
/// alguém mexer numa das duas.
MontageState dividir(MontageState s, String id, double atS) {
  final onde = s.localizar(id);
  if (onde == null) return s;
  final (camada, i) = onde;
  final c = s.layers[camada].clips[i];

  final esquerda = atS - c.atS;
  final direita = c.untilS - atS;
  if (esquerda < kMinCutS || direita < kMinCutS) return s;

  final a = c.copyWith(durationS: esquerda);
  final b = c.copyWith(
    id: novoIdDeCorte(),
    atS: atS,
    durationS: direita,
    startS: c.startS + esquerda,
  );
  final lista = [...s.layers[camada].clips]
    ..[i] = a
    ..insert(i + 1, b);
  return s
      .comCamada(camada, s.layers[camada].copyWith(clips: lista))
      .copyWith(selecao: {b.id});
}

/// Duplica os clipes escolhidos, pondo as cópias depois do fim da montagem.
MontageState duplicar(MontageState s, Set<String> ids) {
  final originais = [
    for (final c in s.clips)
      if (ids.contains(c.id)) c,
  ]..sort((a, b) => a.atS.compareTo(b.atS));
  if (originais.isEmpty) return s;
  return colar(s, originais, duracaoDoVideo(s.clips));
}

/// Põe uma cópia de [area] a partir de [atS], na camada ativa.
///
/// Se não couber ali, o grupo inteiro vai para depois do último clipe da
/// camada: é mais previsível do que espalhar as cópias pelos buracos.
MontageState colar(MontageState s, List<TimelineClip> area, double atS) {
  if (area.isEmpty) return s;
  final camada = s.camadaAtiva.clamp(0, s.layers.length - 1);
  final destinoClips = s.layers[camada].clips;
  final base = area.map((c) => c.atS).reduce(math.min);

  var destino = math.max(0.0, atS);
  final cabeAli = area.every(
    (c) => cabe(destinoClips, destino + (c.atS - base), c.durationS),
  );
  if (!cabeAli) destino = duracaoDoVideo(destinoClips);

  final copias = [
    for (final c in area)
      c.copyWith(id: novoIdDeCorte(), atS: destino + (c.atS - base)),
  ];
  return s
      .comCamada(
        camada,
        s.layers[camada].copyWith(clips: [...destinoClips, ...copias]),
      )
      .copyWith(selecao: {for (final c in copias) c.id});
}

// ── as camadas em si ────────────────────────────────────────────────────────

/// Acrescenta uma camada por cima de todas, e passa a trabalhar nela.
MontageState adicionarCamada(MontageState s, {String nome = ''}) {
  final nova = Layer(
    name: nome.isEmpty ? 'Camada ${s.layers.length + 1}' : nome,
  );
  return s.copyWith(
    layers: [...s.layers, nova],
    camadaAtiva: s.layers.length,
    selecao: const {},
  );
}

/// Tira uma camada e tudo o que está nela.
///
/// A última não sai: uma montagem sem camada nenhuma não teria onde receber o
/// próximo clipe.
MontageState removerCamada(MontageState s, int indice) {
  if (s.layers.length <= 1 || indice < 0 || indice >= s.layers.length) return s;
  final lista = [...s.layers]..removeAt(indice);
  return s.copyWith(
    layers: lista,
    camadaAtiva: s.camadaAtiva.clamp(0, lista.length - 1),
    selecao: const {},
  );
}

/// Muda mudo, escondida ou travada de uma camada.
MontageState ajustarCamada(
  MontageState s,
  int indice, {
  bool? muted,
  bool? hidden,
  bool? locked,
  String? name,
}) {
  if (indice < 0 || indice >= s.layers.length) return s;
  return s.comCamada(
    indice,
    s.layers[indice].copyWith(
      muted: muted,
      hidden: hidden,
      locked: locked,
      name: name,
    ),
  );
}

/// Leva um clipe para outra camada, no mesmo instante do vídeo.
///
/// Recusa quando o lugar já está ocupado lá: empurrar o clipe para outro
/// instante seria mudar duas coisas quando se pediu uma.
MontageState moverParaCamada(MontageState s, String id, int destino) {
  final onde = s.localizar(id);
  if (onde == null || destino < 0 || destino >= s.layers.length) return s;
  final (origem, i) = onde;
  if (origem == destino) return s;

  // som não sobe para camada de imagem, nem imagem desce para camada de som:
  // o servidor recusaria os dois, e recusar aqui explica melhor
  if (s.layers[origem].isAudio != s.layers[destino].isAudio) return s;

  final clip = s.layers[origem].clips[i];
  if (!cabe(s.layers[destino].clips, clip.atS, clip.durationS)) return s;

  final lista = [...s.layers];
  lista[origem] = lista[origem].copyWith(
    clips: [...lista[origem].clips]..removeAt(i),
  );
  lista[destino] = lista[destino].copyWith(
    clips: [...lista[destino].clips, clip],
  );
  return s.copyWith(layers: lista, camadaAtiva: destino);
}

/// Abre uma camada só de som.
///
/// Ela não entra no empilhamento visual — não desenha nada. Serve para o que a
/// faixa contínua nunca soube fazer: cortar a música, deixar um trecho em
/// silêncio, trocar de faixa no meio do vídeo.
MontageState adicionarCamadaDeMusica(MontageState s, {String nome = 'Música'}) {
  final nova = Layer(kind: 'audio', name: nome);
  return s.copyWith(
    layers: [...s.layers, nova],
    camadaAtiva: s.layers.length,
    selecao: const {},
  );
}

/// Põe um pedaço de uma música na régua.
///
/// Sem duração pedida, entra o que sobra da faixa a partir de [startS] — o caso
/// comum é querer a música inteira e aparar depois, não calcular o tamanho
/// antes de ouvir.
MontageState porMusica(
  MontageState s,
  Track musica, {
  required double atS,
  double? durationS,
  double startS = 0,
}) {
  if (!musica.isReady) return s;

  var destino = s.camadaAtiva;
  var base = s;
  if (destino >= s.layers.length || !s.layers[destino].isAudio) {
    // sem camada de som escolhida, a primeira que houver; senão, uma nova
    final existente = base.layers.indexWhere((l) => l.isAudio);
    if (existente >= 0) {
      destino = existente;
    } else {
      base = adicionarCamadaDeMusica(base);
      destino = base.layers.length - 1;
    }
  }

  final sobra = math.max(0.0, musica.durationS - startS);
  var dura = durationS ?? sobra;
  if (sobra > 0) dura = math.min(dura, sobra);
  if (dura < kMinCutS) return s;

  // não empurra nada: onde já há música, a nova entra depois do que está lá
  final onde = cabe(base.layers[destino].clips, atS, dura)
      ? atS
      : base.layers[destino].durationS;

  final bloco = TimelineClip(
    id: novoIdDeCorte(),
    atS: onde,
    durationS: dura,
    startS: startS,
    source: 'media',
    mediaId: musica.id,
  );
  return base
      .comCamada(
        destino,
        base.layers[destino].copyWith(
          clips: [...base.layers[destino].clips, bloco]
            ..sort((a, b) => a.atS.compareTo(b.atS)),
        ),
      )
      .copyWith(selecao: {bloco.id}, camadaAtiva: destino);
}

// ─────────────────────────────── histórico ──────────────────────────────────

/// A pilha do desfazer, com agrupamento por gesto.
///
/// Um arrasto produz um estado novo por quadro. Empilhar todos faria "desfazer"
/// andar um pixel de cada vez — inútil. Por isso um gesto é aberto no começo do
/// arrasto e fechado ao soltar: enquanto ele está aberto, o topo da pilha é
/// substituído em vez de crescer, e o passo que fica é o arrasto inteiro.
class MontageHistory {
  MontageHistory(this._atual);

  MontageState _atual;
  final List<MontageState> _passado = [];
  final List<MontageState> _futuro = [];

  /// Teto de passos guardados. Cada estado é uma lista de blocos — barato —,
  /// mas uma sessão longa não precisa de memória infinita.
  static const int maxPassos = 200;

  bool _emGesto = false;
  bool _mudouNoGesto = false;

  MontageState get atual => _atual;
  bool get podeDesfazer => _passado.isNotEmpty;
  bool get podeRefazer => _futuro.isNotEmpty;

  /// Troca o estado, guardando o anterior.
  void aplicar(MontageState novo) {
    if (identical(novo, _atual)) return;
    if (_emGesto && _mudouNoGesto) {
      // o gesto já empilhou o "antes"; daqui em diante só o topo se atualiza
      _atual = novo;
      return;
    }
    _passado.add(_atual);
    if (_passado.length > maxPassos) _passado.removeAt(0);
    _futuro.clear();
    _atual = novo;
    if (_emGesto) _mudouNoGesto = true;
  }

  /// Troca o estado **sem** criar um passo — para o que não é edição
  /// (selecionar, por exemplo, que desfazer não deveria reverter).
  void substituir(MontageState novo) => _atual = novo;

  /// Joga a memória fora, ficando com o estado que se passar.
  ///
  /// Usado ao trocar de montagem: o histórico é a memória de uma sessão de
  /// trabalho **numa** montagem, e desfazer para dentro de outra apagaria o
  /// que se acabou de abrir.
  void limpar() {
    _passado.clear();
    _futuro.clear();
    _emGesto = false;
    _mudouNoGesto = false;
  }

  void abrirGesto() {
    _emGesto = true;
    _mudouNoGesto = false;
  }

  void fecharGesto() {
    _emGesto = false;
    _mudouNoGesto = false;
  }

  MontageState desfazer() {
    if (_passado.isEmpty) return _atual;
    _futuro.add(_atual);
    _atual = _passado.removeLast();
    return _atual;
  }

  MontageState refazer() {
    if (_futuro.isEmpty) return _atual;
    _passado.add(_atual);
    _atual = _futuro.removeLast();
    return _atual;
  }
}
