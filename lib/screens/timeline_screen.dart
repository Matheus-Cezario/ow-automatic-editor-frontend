import 'dart:async';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import '../api.dart';
import '../montage.dart';
import '../exportacao.dart';
import '../montage_state.dart';
import '../receita.dart';
import '../rotulos.dart';
import '../widgets/highlight_style.dart';
import '../widgets/music_timeline.dart';
import '../widgets/preview_player.dart';

/// Montar o vídeo à mão: ouvir a música e pôr cada momento onde se quiser.
///
/// É a outra metade do sistema. A análise diz *quando* cada coisa aconteceu —
/// eliminação, dardo, pedrada — e para por aí; aqui é o usuário que decide
/// quais entram, em que ponto da música cada um cai e quanto tempo dura.
///
/// A música sobe antes de existir vídeo nenhum, justamente porque não dá para
/// decidir nada disso sem ouvi-la. O que a tela desenha — onda, batidas,
/// duração — vem do servidor junto com ela.
///
/// Em cima fica o monitor: ele abre a gravação original e busca o instante que
/// a cabeça de leitura pede, então dá para ver o corte antes de mandar gerar.
/// Nada é renderizado enquanto se edita.
class TimelineScreen extends StatefulWidget {
  const TimelineScreen({super.key, required this.job});

  final Job job;

  @override
  State<TimelineScreen> createState() => _TimelineScreenState();
}

/// Eventos que valem um bloco. `death` e `low_hp` ficam de fora: são o contexto
/// que faz uma jogada valer, não a jogada.
///
/// `headshot` e `ability_kill` entram porque são exatamente o que se procura
/// numa montagem — o tiro na cabeça e a eliminação com habilidade são a jogada,
/// não o contexto dela. Ficaram de fora enquanto o editor era só um plano B da
/// geração automática, e o resultado era o pior dos dois mundos: o detector
/// achava os momentos, a lista de propostas os anunciava, e quem abria a
/// montagem manual não os encontrava em lugar nenhum.
///
/// Esta lista tem de casar com `THUMB_KINDS` no servidor: é ela que decide de
/// que instantes se extrai miniatura. Um tipo aqui que falte lá vira cartão sem
/// quadro.
const _momentosUteis = {
  'kill',
  'headshot',
  'ability_kill',
  'sleep',
  'stun',
  'ult_negated',
  'escape',
};

class _TimelineScreenState extends State<TimelineScreen> {
  final _api = ApiClient();
  final _scroll = ScrollController();
  final _titulo = TextEditingController(text: 'Minha montagem');

  /// A montagem e tudo o que veio antes dela.
  ///
  /// Toda edição passa por aqui — é o que torna o desfazer possível, e é por
  /// isso que a tela não guarda mais nenhuma lista de blocos por conta própria.
  late final MontageHistory _historia = MontageHistory(MontageState.vazio());
  MontageState get _estado => _historia.atual;

  /// O que foi copiado, esperando um Ctrl+V.
  List<TimelineClip> _areaDeCopia = const [];

  /// A biblioteca de mídia da partida. Começa com o que veio do servidor e
  /// cresce conforme o usuário traz arquivos.
  late List<Media> _biblioteca = [...widget.job.media];
  bool _importando = false;
  String? _erroImportar;

  /// O player da música que está tocando agora — o do bloco sob a cabeça de
  /// leitura, e nenhum outro. Trocar de faixa custa rede, então ele só troca
  /// quando o bloco troca.
  VideoPlayerController? _audio;
  String? _audioDe;
  String? _blocoNoPlayer;
  bool _ajustandoOAudio = false;
  String? _erroMusica;

  /// Alguém está escrevendo num campo agora? Guardado em estado, porque a
  /// resposta muda o conjunto de atalhos registrados — e isso exige
  /// reconstruir a tela.
  bool _escrevendo = false;

  /// O foco da montagem. É dele que os atalhos valem — e é para ele que o foco
  /// volta assim que alguém toca na régua.
  final FocusNode _foco = FocusNode(debugLabel: 'montagem');

  /// O relógio do vídeo. Nulo quando está parado — é ele que responde se está
  /// tocando.
  Timer? _relogio;

  /// Zoom da régua. 60 px/s mostra uns 10 segundos num celular — perto o
  /// bastante para encaixar na batida sem precisar de precisão de cirurgião.
  double _px = 60;
  bool _ima = true;
  double _cursor = 0;

  /// O que o dedo está fazendo agora, para a tela dizer em número o que o
  /// arrasto está fazendo em pixels.
  String? _arrastando;

  /// Altura do monitor, arrastável pela alça abaixo dele.
  double _monitorH = 200;

  /// Estado do salvamento automático, para a tela poder dizer que o trabalho
  /// está guardado.
  /// As montagens desta partida, e qual delas está na tela.
  ///
  /// Uma partida rende mais de um vídeo — o corte vertical e a montagem longa
  /// são trabalhos diferentes sobre o mesmo material.
  late List<SavedMontage> _montagens = [...widget.job.montages];
  String? _montagemId;

  Timer? _debounce;
  bool _salvando = false;
  DateTime? _salvoEm;
  String? _erroSalvar;

  bool _enviando = false;
  String? _erro;

  @override
  void initState() {
    super.initState();
    // a mais recente e a que se estava editando -- e a que se quer de volta
    final atual = _montagens.firstOrNull;
    final draft = atual?.montage ?? widget.job.draft;
    _montagemId = atual?.id;
    if (draft != null) {
      // havia uma montagem em andamento: continua-se de onde parou. A música,
      // se houver, está nos blocos dela -- não há trilha a retomar
      _historia.substituir(montagemDoRascunho(draft));
      if (draft.title.isNotEmpty) _titulo.text = draft.title;
    } else {
      _historia.substituir(_estado.copyWith(title: _titulo.text));
    }
    // jobs analisados antes das miniaturas existirem não têm nenhuma; pedir é
    // barato e o serviço pula o que já está lá
    _api.requestFrames(widget.job.id).ignore();
    FocusManager.instance.addListener(_conferirOFoco);
  }

  /// Alguém está escrevendo num campo?
  ///
  /// O foco primário de um `TextField` fica num `Focus` **dentro** do
  /// `EditableText`, e não nele; por isso a busca é pelo estado ancestral.
  bool get _alguemEscrevendo {
    final ctx = FocusManager.instance.primaryFocus?.context;
    if (ctx == null) return false;
    return ctx.findAncestorStateOfType<EditableTextState>() != null;
  }

  void _conferirOFoco() {
    final agora = _alguemEscrevendo;
    if (agora != _escrevendo && mounted) {
      setState(() => _escrevendo = agora);
    }
  }

  @override
  void dispose() {
    FocusManager.instance.removeListener(_conferirOFoco);
    _foco.dispose();
    _debounce?.cancel();
    _relogio?.cancel();
    _audio?.dispose();
    _scroll.dispose();
    _titulo.dispose();
    super.dispose();
  }

  // ── edição ────────────────────────────────────────────────────────────────

  /// Aplica uma edição: vira estado novo, entra no histórico e agenda o salvamento.
  void _editar(MontageState novo) {
    if (identical(novo, _estado)) return;
    setState(() => _historia.aplicar(novo));
    _agendarSalvamento();
  }

  /// Muda o estado **sem** criar um passo de desfazer — seleção e título, que
  /// não são edições do vídeo.
  void _semHistorico(MontageState novo) {
    setState(() => _historia.substituir(novo));
  }

  void _desfazer() {
    if (!_historia.podeDesfazer) return;
    setState(_historia.desfazer);
    _sincronizarTitulo();
    _agendarSalvamento();
  }

  void _refazer() {
    if (!_historia.podeRefazer) return;
    setState(_historia.refazer);
    _sincronizarTitulo();
    _agendarSalvamento();
  }

  void _sincronizarTitulo() {
    if (_titulo.text != _estado.title) _titulo.text = _estado.title;
  }

  void _selecionar(String? id, {bool alternar = false}) {
    if (id == null) {
      _semHistorico(_estado.copyWith(selecao: const {}));
      return;
    }
    final nova = <String>{..._estado.selecao};
    if (alternar) {
      // shift-clique tira quem já estava, para dar e desfazer com o mesmo gesto
      if (!nova.remove(id)) nova.add(id);
    } else {
      nova
        ..clear()
        ..add(id);
    }
    _semHistorico(_estado.copyWith(selecao: nova));
  }

  // ── operações sobre os blocos ─────────────────────────────────────────────

  void _adicionar(DetectionEvent e) {
    _editar(
      adicionar(
        _estado,
        cutForMoment(
          e,
          atS: _cursor,
          beats: _batidas,
          sourceDurationS: widget.job.durationS,
        ),
        beats: _batidas,
        snap: _ima,
      ),
    );
  }

  void _mover(String id, double atS) =>
      _editar(moverBloco(_estado, id, atS, beats: _batidas, snap: _ima));

  void _aparar(String id, double atS) =>
      _editar(apararBloco(_estado, id, atS, beats: _batidas, snap: _ima));

  void _esticar(String id, double duracao) => _editar(
    esticarBloco(
      _estado,
      id,
      duracao,
      beats: _batidas,
      snap: _ima,
      sourceDurationS: widget.job.durationS,
    ),
  );

  void _deslocar(String id, double delta) => _editar(
    deslocarConteudo(_estado, id, delta, sourceDurationS: widget.job.durationS),
  );

  void _apagarSelecao() => _editar(remover(_estado, _estado.selecao));

  // ── texto ─────────────────────────────────────────────────────────────────

  /// Põe um texto onde a música estiver, na camada de cima.
  ///
  /// Texto quase sempre vai por cima de imagem, então uma camada nova é o
  /// palpite certo quando só existe uma.
  void _texto(String conteudo) {
    var novo = _estado;
    if (novo.layers.length == 1) novo = adicionarCamada(novo, nome: 'Texto');
    _editar(
      adicionar(
        novo,
        rotulo(conteudo, atS: _cursor),
        beats: _batidas,
        snap: _ima,
      ),
    );
  }

  /// Escreve na montagem o que o sistema já sabe da partida.
  void _gerarRotulos(List<TimelineClip> novos, String oQue) {
    if (novos.isEmpty) {
      _avisar('Não há $oQue para rotular nesta montagem.');
      return;
    }
    var s = _estado;
    if (s.layers.length == 1) s = adicionarCamada(s, nome: 'Texto');
    for (final r in novos) {
      s = adicionar(s, r, beats: const [], snap: false);
    }
    _editar(s.copyWith(selecao: const {}));
    _avisar('${novos.length} rótulo(s) escritos.');
  }

  void _efeito(
    String id, {
    double? speed,
    ClipColor? color,
    ClipFade? fade,
    List<ZoomKey>? zoom,
    bool? freeze,
    bool? reverse,
  }) => _editar(
    ajustarEfeito(
      _estado,
      id,
      speed: speed,
      color: color,
      fade: fade,
      zoom: zoom,
      freeze: freeze,
      reverse: reverse,
    ),
  );

  // ── biblioteca de mídia ───────────────────────────────────────────────────

  Future<void> _importar() async {
    final picked = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: const [
        'mp4',
        'mov',
        'mkv',
        'webm',
        'm4v',
        'png',
        'jpg',
        'jpeg',
        'webp',
        'gif',
        'mp3',
        'wav',
        'm4a',
        'aac',
        'ogg',
        'flac',
      ],
    );
    if (picked == null) return;
    setState(() {
      _importando = true;
      _erroImportar = null;
    });
    try {
      final enviado = await _api.uploadMedia(
        jobId: widget.job.id,
        file: picked,
      );
      final pronto = await _api.waitForMedia(enviado.id);
      if (!mounted) return;
      setState(() {
        _biblioteca = [..._biblioteca, pronto];
        if (pronto.isFailed) {
          _erroImportar = pronto.error ?? 'não consegui ler esse arquivo';
        }
      });
    } catch (e) {
      if (mounted) setState(() => _erroImportar = '$e');
    } finally {
      if (mounted) setState(() => _importando = false);
    }
  }

  /// Põe um item da biblioteca na régua, na cabeça de leitura.
  ///
  /// Música vai para uma camada de som — se não houver, ela nasce. É o único
  /// jeito de trazer música para uma montagem, e é o mesmo caminho do vídeo e
  /// da imagem: a biblioteca é a porta de entrada de tudo o que vem de fora.
  void _usarMidia(Media item, {double? atS, int? camada}) {
    final onde = atS ?? _cursor;
    if (item.isAudio) {
      _porMusicaNaRegua(item, atS: onde, camada: camada);
      return;
    }
    var base = _estado;
    if (camada != null && camada >= 0 && camada < base.layers.length) {
      if (base.layers[camada].isAudio) {
        _avisar('Essa camada é de som: imagem não entra nela.');
        return;
      }
      base = base.copyWith(camadaAtiva: camada);
    }
    _editar(
      adicionar(
        base,
        clipeDeMidia(
          item,
          atS: onde,
          beats: _batidas,
        ).copyWith(mediaId: item.id),
        beats: _batidas,
        snap: _ima,
      ),
    );
  }

  Future<void> _tirarDaBiblioteca(Media item) async {
    // um clipe que apontasse para ela ficaria órfão, e o pedido seria recusado
    final emUso = _estado.clips.any((c) => c.mediaId == item.id);
    if (emUso) {
      _avisar('Este item está na montagem. Tire os cortes dele primeiro.');
      return;
    }
    setState(
      () => _biblioteca = [
        for (final m in _biblioteca)
          if (m.id != item.id) m,
      ],
    );
    try {
      await _api.deleteMedia(item.id);
    } catch (e) {
      if (mounted) setState(() => _erroImportar = '$e');
    }
  }

  void _selecionarTudo() => _semHistorico(
    _estado.copyWith(selecao: {for (final c in _estado.clips) c.id}),
  );

  void _copiar() {
    if (_estado.selecao.isEmpty) return;
    setState(() => _areaDeCopia = _estado.selecionados);
    _avisar('${_areaDeCopia.length} corte(s) copiado(s)');
  }

  void _colar() {
    if (_areaDeCopia.isEmpty) return;
    _editar(colar(_estado, _areaDeCopia, _cursor));
  }

  void _duplicar() => _editar(duplicar(_estado, _estado.selecao));

  /// Leva a jogada de um bloco para debaixo da cabeça de leitura.
  ///
  /// O bloco anda; a jogada é que fica onde se pediu. É o gesto de encaixar a
  /// eliminação na batida sem contar de cabeça quanto embalo há antes dela.
  void _alinharMomentoAoCursor([String? id]) {
    final alvo =
        id ?? (_estado.selecao.length == 1 ? _estado.selecao.first : null);
    if (alvo == null) {
      _avisar('Escolha um bloco para alinhar a jogada dele.');
      return;
    }
    if (momentoNoVideo(_estado.clipe(alvo)!) == null) {
      _avisar('Este bloco não tem jogada marcada.');
      return;
    }
    final feito = alinharMomento(
      _estado,
      alvo,
      _cursor,
      sourceDurationS: widget.job.durationS,
    );
    if (feito == null) {
      _avisar('A jogada não alcança este ponto: a gravação acaba antes.');
      return;
    }
    _editar(feito.estado);
    if (feito.deslizou) {
      // o usuário precisa saber *o que* mudou: o bloco ficou onde estava e o
      // trecho da gravação é que andou
      _avisar(
        'Os vizinhos não deixaram o bloco andar, então o trecho é que '
        'deslizou dentro dele.',
      );
    }
  }

  /// Corta em dois o bloco que estiver sob a cabeça de leitura.
  void _dividirNoCursor() {
    final at = _cursor;
    final i = blocoEm(_estado.clips, at);
    if (i == null) {
      _avisar('Ponha o cursor em cima de um corte para dividi-lo.');
      return;
    }
    final antes = _estado.clips.length;
    _editar(dividir(_estado, _estado.clips[i].id, at));
    if (_estado.clips.length == antes) {
      _avisar('Perto demais da borda: sobraria um pedaço invisível.');
    }
  }

  /// Anda um quadro da gravação, para o ajuste que o segundo não alcança.
  ///
  /// O passo sai do fps da própria partida: num vídeo a 30 fps são 33 ms, e é
  /// esse o menor movimento que muda alguma coisa na tela.
  void _passoDeQuadro(int quantos) {
    final fps = widget.job.fps > 0 ? widget.job.fps : 30.0;
    _irPara(_cursor + quantos / fps);
  }

  /// Empurra a seleção pelo teclado, para o ajuste que o dedo não acerta.
  void _empurrar(double delta) {
    if (_estado.selecao.isEmpty) return;
    _editar(moverSelecao(_estado, delta, beats: _batidas, snap: false));
  }

  /// Apara a borda do bloco selecionado até a cabeça de leitura.
  void _apararNoCursor({required bool inicio}) {
    if (_estado.selecao.length != 1) return;
    final c = _estado.clipe(_estado.selecao.first)!;
    final at = _cursor;
    if (at <= c.atS || at >= c.untilS) return;
    _editar(
      inicio
          ? apararBloco(_estado, c.id, at, beats: _batidas, snap: false)
          : esticarBloco(
              _estado,
              c.id,
              at - c.atS,
              beats: _batidas,
              snap: false,
              sourceDurationS: widget.job.durationS,
            ),
    );
  }

  void _avisar(String texto) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(texto)));
  }

  // ── salvamento ────────────────────────────────────────────────────────────

  /// Guarda a montagem no servidor, com folga entre um salvamento e outro.
  ///
  /// Chamado a cada mexida. O que importa é não perder o trabalho, não
  /// registrar cada pixel de um arrasto — daí o segundo e meio de espera: um
  /// arrasto inteiro vira um salvamento só.
  void _agendarSalvamento() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 1500), _salvar);
  }

  Future<void> _salvar() async {
    if (!mounted) return;
    setState(() {
      _salvando = true;
      _erroSalvar = null;
    });
    try {
      final montagem = _estado.paraEnvio();
      var id = _montagemId;
      if (id == null) {
        // a primeira montagem so nasce quando ha o que guardar: abrir o editor
        // e fecha-lo sem mexer em nada nao deixa lixo na lista
        final nova = await _api.createMontage(
          widget.job.id,
          name: _titulo.text.trim(),
          montage: montagem,
        );
        id = nova.id;
        if (mounted) {
          setState(() {
            _montagemId = id;
            _montagens = [nova, ..._montagens];
          });
        }
      } else {
        await _api.saveMontage(widget.job.id, id, montage: montagem);
      }
      if (mounted) {
        setState(() {
          _salvoEm = DateTime.now();
          _salvando = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _erroSalvar = '$e';
          _salvando = false;
        });
      }
    }
  }

  // ── música ────────────────────────────────────────────────────────────────

  List<DetectionEvent> get _momentosDaPartida =>
      widget.job.events.where((e) => _momentosUteis.contains(e.kind)).toList();

  /// As batidas em tempo de **vídeo**: é nelas que os blocos grudam, porque a
  /// posição de um bloco é medida a partir do início do vídeo, não da música.
  List<double> get _batidas {
    // Com blocos de música na régua, a grade é a da música que está tocando
    // sob a cabeça de leitura: um vídeo com duas faixas tem dois andamentos, e
    // grudar na batida da outra seria pior do que não grudar em nada.
    final aqui = _musicaEm(_cursor);
    if (aqui != null) {
      final ajustada = gradeAjustada(
        aqui.musica.beats,
        offsetS: _estado.beatOffsetS,
        multiplicador: _estado.beatMultiplier,
        compasso: _estado.beatBar,
      );
      // as batidas da música são medidas nela; o bloco as traz para o tempo do
      // vídeo, descontando o pedaço da faixa que ficou de fora
      final desloca = aqui.bloco.atS - aqui.bloco.startS;
      return [
        for (final b in ajustada)
          if (b >= aqui.bloco.startS && b <= aqui.bloco.endS) b + desloca,
      ];
    }

    // sem bloco nenhum sob a cabeça de leitura não há grade: o ímã não tem a
    // que grudar, e inventar uma batida seria pior do que não ter nenhuma
    return const [];
  }

  // ── música na régua ───────────────────────────────────────────────────────

  /// As músicas da partida, por id — é delas que sai a onda de cada bloco.
  ///
  /// Saem da **biblioteca**, que é a porta de entrada de tudo o que vem de
  /// fora: uma música enviada agora já está aqui, e não só no retrato que veio
  /// com a partida.
  Map<String, Track> get _musicas => {
    for (final m in _biblioteca)
      if (m.isAudio && m.isReady) m.id: m.comoMusica,
  };

  /// O bloco de música que está tocando em [t] segundos de vídeo, se houver.
  ({TimelineClip bloco, Track musica})? _musicaEm(double t) {
    for (final camada in _estado.layers) {
      if (!camada.isAudio || camada.muted) continue;
      for (final c in camada.clips) {
        if (t < c.atS - 1e-6 || t >= c.untilS - 1e-6) continue;
        final m = _musicas[c.mediaId];
        if (m != null) return (bloco: c, musica: m);
      }
    }
    return null;
  }

  /// O item da biblioteca de que um bloco saiu, se ele veio de um.
  ///
  /// É o que faz o painel de baixo falar do arquivo em vez de falar de evento:
  /// um bloco de mídia não veio de um momento da partida, e um de música não
  /// desenha nada.
  Media? _midiaDoBloco(String id) {
    final clip = _estado.clipe(id);
    if (clip == null || clip.mediaId == null) return null;
    return _biblioteca.where((m) => m.id == clip.mediaId).firstOrNull;
  }

  /// Abre uma camada só de som e leva o foco para ela.
  void _novaCamadaDeMusica() {
    _editar(adicionarCamadaDeMusica(_estado));
    _avisar('Arraste uma música da Biblioteca para esta camada.');
  }

  /// Leva um bloco para outra camada — e, quando não dá, diz por quê.
  ///
  /// Recusar em silêncio é o pior dos dois mundos: o bloco volta para o lugar
  /// e quem arrastou fica sem saber se o gesto não pegou ou se a operação não
  /// era possível.
  void _trocarDeCamada(String id, int destino) {
    if (destino < 0 || destino >= _estado.layers.length) {
      _avisar('Não há camada aí. Abra uma nova para levar o bloco.');
      return;
    }
    final onde = _estado.localizar(id);
    if (onde == null) return;
    final origem = _estado.layers[onde.$1];
    final alvo = _estado.layers[destino];

    if (origem.isAudio != alvo.isAudio) {
      _avisar(
        origem.isAudio
            ? 'Música só entra em camada de som.'
            : 'Essa camada é de som: imagem não entra nela.',
      );
      return;
    }
    if (alvo.locked) {
      _avisar('A camada "${alvo.name}" está travada.');
      return;
    }
    final novo = moverParaCamada(_estado, id, destino);
    if (identical(novo, _estado)) {
      _avisar('Já há um bloco nesse instante da outra camada.');
      return;
    }
    _editar(novo);
  }

  /// Os clipes de texto que o monitor desenha por cima da imagem.
  ///
  /// Camada escondida não entra: o monitor mostra o que vai sair, e o que está
  /// escondido não vai.
  List<TimelineClip> get _textosVisiveis => [
    for (final l in _estado.layers)
      if (!l.hidden && !l.isAudio)
        for (final c in l.clips)
          if (c.isText) c,
  ];

  /// A montagem tem música? É o que decide se a mistura tem o que equilibrar.
  bool get _temMusica =>
      _estado.layers.any((l) => l.isAudio && l.clips.isNotEmpty);

  /// O que caiu na régua, e onde.
  ///
  /// Arrastar é o caminho de quem já sabe onde quer a coisa; clicar continua
  /// pondo na cabeça de leitura. As duas portas levam à mesma operação.
  void _soltarNaRegua(ArrastoParaARegua o, double atS, int camada) {
    final media = o.media;
    if (media != null) {
      _usarMidia(media, atS: atS, camada: camada);
      return;
    }
    final evento = o.evento!;
    if (camada >= 0 &&
        camada < _estado.layers.length &&
        _estado.layers[camada].isAudio) {
      _avisar('Essa camada é de som: um momento da partida não entra nela.');
      return;
    }
    var base = _estado;
    if (camada >= 0 && camada < base.layers.length) {
      base = base.copyWith(camadaAtiva: camada);
    }
    _editar(
      adicionar(
        base,
        cutForMoment(
          evento,
          atS: atS,
          beats: _batidas,
          sourceDurationS: widget.job.durationS,
        ),
        beats: _batidas,
        snap: _ima,
      ),
    );
  }

  /// Põe uma música da biblioteca na régua.
  ///
  /// Sem camada de som escolhida ela abre uma — pedir música e receber um
  /// pedido de camada seria burocracia.
  void _porMusicaNaRegua(Media item, {double? atS, int? camada}) {
    final musica = _musicas[item.id];
    if (musica == null) {
      _avisar(
        item.isFailed
            ? 'Não consegui ouvir esse arquivo.'
            : 'Ainda estou ouvindo essa música.',
      );
      return;
    }
    var base = _estado;
    // a camada sob o dedo só manda se for de som; largar música numa pista de
    // imagem quer dizer "põe aqui neste instante", e não "desenha isto"
    if (camada != null &&
        camada >= 0 &&
        camada < base.layers.length &&
        base.layers[camada].isAudio) {
      base = base.copyWith(camadaAtiva: camada);
    }
    final antes = base.clips.length;
    final novo = porMusica(base, musica, atS: atS ?? _cursor);
    _editar(novo);
    if (novo.clips.length == antes) {
      _avisar('Não coube: já há música nesse ponto.');
    }
  }

  // ── transporte ────────────────────────────────────────────────────────────
  //
  // O relógio é o **vídeo**, e não a música. Enquanto a faixa era contínua o
  // player dela podia mandar no tempo — havia um som tocando do primeiro ao
  // último quadro. Com blocos que entram e saem não há player nenhum tocando o
  // vídeo inteiro, então a cabeça de leitura ganhou relógio próprio e a música
  // passou a segui-la: o bloco que estiver sob ela toca, no ponto dele que
  // corresponde àquele instante.

  bool get _tocando => _relogio != null;

  /// De quanto em quanto a cabeça de leitura anda enquanto toca.
  static const _passoDoRelogio = Duration(milliseconds: 33);

  void _tocarOuPausar() => _tocando ? _pausar() : _tocar();

  void _tocar() {
    if (_estado.vazia) return;
    // no fim, tocar recomeça: parar no último quadro e não fazer nada seria
    // deixar o botão sem efeito
    final fim = duracaoDoVideo(_estado.clips);
    setState(() {
      if (_cursor >= fim - 0.05) _cursor = 0;
      _relogio = Timer.periodic(_passoDoRelogio, (_) => _correr());
    });
    _acertarAMusica();
  }

  void _pausar() {
    _relogio?.cancel();
    _audio?.pause();
    if (mounted) setState(() => _relogio = null);
  }

  /// Um passo do relógio.
  ///
  /// Enquanto há música tocando, **ela** é o relógio: a posição do player vira
  /// a posição da cabeça de leitura. É o som que o usuário está ouvindo, e
  /// puxá-lo de volta a cada deriva daria um soluço audível a cada poucos
  /// segundos. Nos trechos sem música, o passo do timer basta.
  void _correr() {
    final fim = duracaoDoVideo(_estado.clips);
    var t = _cursor + _passoDoRelogio.inMilliseconds / 1000.0;

    final aqui = _musicaEm(_cursor);
    final c = _audio;
    if (aqui != null &&
        c != null &&
        c.value.isInitialized &&
        c.value.isPlaying &&
        _blocoNoPlayer == aqui.bloco.id) {
      final pela =
          aqui.bloco.atS +
          (c.value.position.inMilliseconds / 1000.0 - aqui.bloco.startS);
      // o player engasga de vez em quando; quando ele se perde de vez, o
      // relógio segue sem ele em vez de pular a cabeça de leitura para longe
      if ((pela - t).abs() < 0.5) t = pela;
    }

    if (t >= fim) {
      setState(() => _cursor = fim);
      _pausar();
      return;
    }
    setState(() => _cursor = t);
    _seguirCursor(t);
    _acertarAMusica();
  }

  /// Põe o player no ponto da música que corresponde ao cursor.
  ///
  /// Trocar de faixa custa uma carga de rede, então só se troca quando o bloco
  /// sob a cabeça de leitura muda. Fora isso corrige-se a deriva: o relógio do
  /// vídeo e o do elemento de áudio andam separados, e num vídeo longo eles se
  /// afastam o suficiente para a batida sair do lugar.
  Future<void> _acertarAMusica() async {
    if (_ajustandoOAudio) return;
    _ajustandoOAudio = true;
    try {
      final aqui = _musicaEm(_cursor);
      if (aqui == null) {
        // silêncio é a falta de bloco, e não um bloco de silêncio
        if (_audio?.value.isPlaying ?? false) await _audio?.pause();
        _blocoNoPlayer = null;
        return;
      }
      if (_blocoNoPlayer != aqui.bloco.id || _audioDe != aqui.musica.id) {
        _blocoNoPlayer = aqui.bloco.id;
        if (_audioDe != aqui.musica.id) await _abrirAudio(aqui.musica);
      }
      final c = _audio;
      if (c == null || !c.value.isInitialized) return;

      final onde = aqui.bloco.startS + (_cursor - aqui.bloco.atS);
      final agora = c.value.position.inMilliseconds / 1000.0;
      if ((agora - onde).abs() > 0.2) {
        await c.seekTo(Duration(milliseconds: (onde * 1000).round()));
      }
      if (_tocando && !c.value.isPlaying) {
        await c.play();
      } else if (!_tocando && c.value.isPlaying) {
        await c.pause();
      }
    } finally {
      _ajustandoOAudio = false;
    }
  }

  Future<void> _abrirAudio(Track musica) async {
    final antigo = _audio;
    _audio = null;
    _audioDe = null;
    await antigo?.dispose();

    final controller = VideoPlayerController.networkUrl(
      Uri.parse(musica.audioUrl),
    );
    try {
      await controller.initialize();
    } catch (e) {
      // sem player a montagem continua possível: a onda e as batidas já estão
      // desenhadas, e é por elas que se encaixa o corte
      await controller.dispose();
      if (mounted) setState(() => _erroMusica = 'não consigo tocar aqui ($e)');
      return;
    }
    if (!mounted) {
      await controller.dispose();
      return;
    }
    setState(() {
      _audio = controller;
      _audioDe = musica.id;
      _erroMusica = null;
    });
  }

  /// Mantém a cabeça de leitura na tela enquanto o vídeo corre.
  void _seguirCursor(double t) {
    if (!_scroll.hasClients) return;
    final x = t * _px;
    final janela = _scroll.position.viewportDimension;
    final inicio = _scroll.offset;
    if (x < inicio + 40 || x > inicio + janela - 80) {
      _scroll.jumpTo(
        (x - janela / 3).clamp(0.0, _scroll.position.maxScrollExtent),
      );
    }
  }

  Future<void> _irPara(double s) async {
    // não se limita ao fim da montagem: pôr a cabeça depois do último bloco é
    // justamente como se põe o próximo
    final t = math.max(0.0, s);
    setState(() => _cursor = t);
    await _acertarAMusica();
  }

  // ── pedido e descarte ─────────────────────────────────────────────────────

  Future<void> _gerar() async {
    setState(() {
      _enviando = true;
      _erro = null;
    });
    try {
      await _salvar();
      await _api.createRender(
        jobId: widget.job.id,
        montages: [_estado.paraEnvio()],
      );
      // o que saiu foi *isto*: guardar a foto aqui e o que torna o historico
      // util sem encher o banco a cada salvamento automatico
      final id = _montagemId;
      if (id != null) {
        await _api
            .createVersion(widget.job.id, id, label: 'gerou o video')
            .catchError((_) => false);
      }
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _erro = '$e';
          _enviando = false;
        });
      }
    }
  }

  // ── montagens da partida ──────────────────────────────────────────────────

  SavedMontage? get _montagemAtual =>
      _montagens.where((m) => m.id == _montagemId).firstOrNull;

  String get _nomeDaMontagem => _montagemAtual?.name ?? 'Montagem';

  /// Põe uma montagem na tela, guardando antes a que estava.
  ///
  /// O histórico de desfazer **não** atravessa a troca: ele é a memória de uma
  /// sessão de trabalho numa montagem, e desfazer para dentro de outra seria
  /// apagar o que se acabou de abrir.
  Future<void> _abrir(SavedMontage m) async {
    if (m.id == _montagemId) return;
    _debounce?.cancel();
    await _salvar();
    if (!mounted) return;

    setState(() {
      _montagemId = m.id;
      _titulo.text = m.montage.title;
    });
    _historia.limpar();
    _historia.substituir(montagemDoRascunho(m.montage));
    // a outra montagem tem a música dela, nos blocos dela
    _blocoNoPlayer = null;
    await _acertarAMusica();
  }

  Future<void> _recarregarMontagens({String? abrir}) async {
    try {
      final lista = await _api.listMontages(widget.job.id);
      if (!mounted) return;
      setState(() => _montagens = lista);
      if (abrir != null) {
        final nova = lista.where((m) => m.id == abrir).firstOrNull;
        if (nova != null) await _abrir(nova);
      }
    } catch (e) {
      if (mounted) setState(() => _erroSalvar = '$e');
    }
  }

  Future<void> _novaMontagem() async {
    _debounce?.cancel();
    await _salvar();
    try {
      final nova = await _api.createMontage(widget.job.id);
      if (!mounted) return;
      setState(() {
        _montagens = [nova, ..._montagens];
        _montagemId = nova.id;
        _titulo.text = '';
      });
      _historia.limpar();
      _historia.substituir(MontageState.vazio());
    } catch (e) {
      if (mounted) setState(() => _erroSalvar = '$e');
    }
  }

  Future<void> _duplicarMontagem() async {
    final atual = _montagemId;
    if (atual == null) return;
    _debounce?.cancel();
    await _salvar();
    try {
      final copia = await _api.duplicateMontage(widget.job.id, atual);
      await _recarregarMontagens(abrir: copia.id);
    } catch (e) {
      if (mounted) setState(() => _erroSalvar = '$e');
    }
  }

  Future<void> _renomearMontagem() async {
    final atual = _montagemAtual;
    if (atual == null) return;
    final nome = await _pedirNome('Renomear', inicial: atual.name);
    if (nome == null || !mounted) return;
    try {
      await _api.saveMontage(widget.job.id, atual.id, name: nome);
      await _recarregarMontagens();
    } catch (e) {
      if (mounted) setState(() => _erroSalvar = '$e');
    }
  }

  Future<void> _apagarMontagem() async {
    final atual = _montagemAtual;
    if (atual == null) return;
    final ok = await _confirmar(
      'Apagar "${atual.name}"?',
      'Os cortes desta montagem somem. As outras montagens desta partida '
          'ficam como estão.',
    );
    if (!ok || !mounted) return;

    _debounce?.cancel();
    try {
      await _api.deleteMontage(widget.job.id, atual.id);
      final restantes = [..._montagens]..removeWhere((m) => m.id == atual.id);
      if (!mounted) return;
      setState(() {
        _montagens = restantes;
        _montagemId = null;
      });
      _historia.limpar();
      if (restantes.isNotEmpty) {
        await _abrir(restantes.first);
      } else {
        _historia.substituir(MontageState.vazio());
        setState(() => _titulo.text = '');
      }
    } catch (e) {
      if (mounted) setState(() => _erroSalvar = '$e');
    }
  }

  Future<String?> _pedirNome(String titulo, {String inicial = ''}) {
    final campo = TextEditingController(text: inicial);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(titulo),
        content: TextField(
          controller: campo,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Nome'),
          onSubmitted: (v) => Navigator.of(ctx).pop(v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(campo.text.trim()),
            child: const Text('Salvar'),
          ),
        ],
      ),
    ).then((v) => (v == null || v.isEmpty) ? null : v);
  }

  Future<bool> _confirmar(String titulo, String texto) async {
    final r = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(titulo),
        content: Text(texto),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Apagar'),
          ),
        ],
      ),
    );
    return r ?? false;
  }

  // ── histórico de versões ──────────────────────────────────────────────────

  Future<void> _marcarVersao() async {
    final atual = _montagemId;
    if (atual == null) return;
    _debounce?.cancel();
    await _salvar();
    try {
      final houve = await _api.createVersion(
        widget.job.id,
        atual,
        label: 'marcada a mão',
      );
      if (!mounted) return;
      _avisar(
        houve ? 'Versão marcada.' : 'Nada mudou desde a última versão marcada.',
      );
      await _recarregarMontagens();
    } catch (e) {
      if (mounted) setState(() => _erroSalvar = '$e');
    }
  }

  Future<void> _verHistorico() async {
    final atual = _montagemId;
    if (atual == null) return;
    _debounce?.cancel();
    await _salvar();

    List<MontageVersion> fotos;
    try {
      fotos = await _api.listVersions(widget.job.id, atual);
    } catch (e) {
      if (mounted) setState(() => _erroSalvar = '$e');
      return;
    }
    if (!mounted) return;

    final escolhida = await showDialog<MontageVersion>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Histórico'),
        content: SizedBox(
          width: 420,
          child: fotos.isEmpty
              ? const Text(
                  'Ainda não há versões. Uma é guardada a cada vídeo gerado, '
                  'e dá para marcar uma agora pelo menu.',
                )
              : ListView(
                  shrinkWrap: true,
                  children: [
                    for (final v in fotos)
                      ListTile(
                        key: ValueKey('versao-${v.id}'),
                        title: Text(v.label.isEmpty ? 'sem rótulo' : v.label),
                        subtitle: Text(
                          '${v.nClips} corte(s) · '
                          '${formatDuration(v.durationS)} · '
                          '${_quando(v.createdAt)}',
                        ),
                        trailing: const Icon(Icons.restore),
                        onTap: () => Navigator.of(ctx).pop(v),
                      ),
                  ],
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Fechar'),
          ),
        ],
      ),
    );
    if (escolhida == null || !mounted) return;

    try {
      final volta = await _api.restoreVersion(
        widget.job.id,
        atual,
        escolhida.id,
      );
      if (!mounted) return;
      _historia.limpar();
      _historia.substituir(montagemDoRascunho(volta.montage));
      setState(() => _titulo.text = volta.montage.title);
      _avisar(
        'Voltou para "${escolhida.label}". O que estava na frente virou '
        'uma versão também.',
      );
      await _recarregarMontagens();
    } catch (e) {
      if (mounted) setState(() => _erroSalvar = '$e');
    }
  }

  static String _quando(DateTime t) {
    final d = t.toLocal();
    String dois(int n) => n.toString().padLeft(2, '0');
    return '${dois(d.day)}/${dois(d.month)} ${dois(d.hour)}:${dois(d.minute)}';
  }

  // ── predefinições ─────────────────────────────────────────────────────────

  Future<void> _salvarPredefinicao() async {
    final nome = await _pedirNome('Salvar como predefinição');
    if (nome == null || !mounted) return;
    try {
      await _api.createPreset(
        nome,
        receitaDaMontagem(_estado, beatsPerCut: _batidasPorCorte),
      );
      if (mounted) {
        _avisar('"$nome" vale para qualquer partida agora.');
      }
    } catch (e) {
      if (mounted) setState(() => _erroSalvar = '$e');
    }
  }

  /// Quantas batidas cada corte ocupa, se é que ocupa um número redondo delas.
  ///
  /// É o que distingue "cortes de 1,8 s" de "cortes de duas batidas": a
  /// segunda leitura sobrevive a uma música de outro andamento, e a primeira
  /// não.
  double? get _batidasPorCorte {
    final grade = _batidas;
    if (grade.length < 3 || _estado.clips.isEmpty) return null;
    var soma = 0.0;
    for (var i = 1; i < grade.length; i++) {
      soma += grade[i] - grade[i - 1];
    }
    final compasso = soma / (grade.length - 1);
    if (compasso <= 0) return null;

    final duracoes = [
      for (final c in _estado.clips)
        if (!c.isText) c.durationS,
    ];
    if (duracoes.isEmpty) return null;
    final media = duracoes.reduce((a, b) => a + b) / duracoes.length;
    final quantas = media / compasso;
    final redondo = quantas.roundToDouble();
    // longe de um número inteiro de batidas, a montagem não é de ritmo
    if (redondo < 1 || (quantas - redondo).abs() > 0.15) return null;
    return redondo;
  }

  Future<void> _aplicarPredefinicao() async {
    List<Preset> presets;
    try {
      presets = await _api.listPresets();
    } catch (e) {
      if (mounted) setState(() => _erroSalvar = '$e');
      return;
    }
    if (!mounted) return;

    final escolhido = await showDialog<Preset>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Predefinições'),
        content: SizedBox(
          width: 420,
          child: presets.isEmpty
              ? const Text(
                  'Nenhuma ainda. Monte um vídeo do jeito que gosta e use '
                  '"Salvar como predefinição" — daí em diante a próxima '
                  'partida sai pronta.',
                )
              : ListView(
                  shrinkWrap: true,
                  children: [
                    for (final p in presets)
                      ListTile(
                        key: ValueKey('preset-${p.id}'),
                        title: Text(p.name),
                        subtitle: Text(_descreverReceita(p.receita)),
                        onTap: () => Navigator.of(ctx).pop(p),
                      ),
                  ],
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Fechar'),
          ),
        ],
      ),
    );
    if (escolhido == null || !mounted) return;

    if (!_estado.vazia) {
      final ok = await _confirmar(
        'Aplicar "${escolhido.name}"?',
        'Os cortes que estão na tela são substituídos. Dá para desfazer '
            'com Ctrl+Z.',
      );
      if (!ok || !mounted) return;
    }

    _editar(
      aplicarReceita(
        escolhido.receita,
        eventos: _momentosDaPartida,
        sourceDurationS: widget.job.durationS,
        batidas: _batidas,
        base: _estado,
      ),
    );
    _avisar('"${escolhido.name}" aplicada: ${_estado.clips.length} corte(s).');
  }

  String _descreverReceita(Receita r) {
    final tamanho = r.beatsPerCut > 0
        ? '${r.beatsPerCut.toStringAsFixed(0)} batida(s) por corte'
        : '${r.durationS.toStringAsFixed(1)}s por corte';
    final extras = [
      if (r.zoom) 'zoom',
      if (r.counter) 'contador',
      if (r.streaks) 'rajadas',
      if (r.export.width > 0) '${r.export.width}x${r.export.height}',
    ];
    return '${r.kinds.join(', ')} · $tamanho'
        '${extras.isEmpty ? '' : ' · ${extras.join(' · ')}'}';
  }

  // ── teclado ───────────────────────────────────────────────────────────────

  /// Devolve o foco à montagem — e com ele os atalhos.
  ///
  /// Chamado pelos campos quando o toque cai **fora** deles. Nada tira o foco
  /// de um `TextField` por conta própria no Flutter: sem isto, tocar no campo
  /// de nome uma vez deixava "S" e Delete mortos para o resto da sessão.
  void _devolverOFoco() {
    if (mounted) _foco.requestFocus();
  }

  /// Os atalhos, com Ctrl e Cmd valendo igual.
  Map<ShortcutActivator, VoidCallback> get _atalhos {
    final b = <ShortcutActivator, VoidCallback>{
      const SingleActivator(LogicalKeyboardKey.space): _tocarOuPausar,
      const SingleActivator(LogicalKeyboardKey.keyK): _tocarOuPausar,
      const SingleActivator(LogicalKeyboardKey.keyL): () {
        if (!_tocando) _tocar();
      },
      const SingleActivator(LogicalKeyboardKey.keyJ): () =>
          _irPara(_cursor - 2),
      const SingleActivator(LogicalKeyboardKey.keyS): _dividirNoCursor,
      const SingleActivator(LogicalKeyboardKey.keyM): _alinharMomentoAoCursor,
      // vírgula e ponto andam um quadro, como em qualquer editor. As setas
      // ficam com o passo grosso, de um segundo — os dois têm uso.
      const SingleActivator(LogicalKeyboardKey.comma): () => _passoDeQuadro(-1),
      const SingleActivator(LogicalKeyboardKey.period): () => _passoDeQuadro(1),
      const SingleActivator(LogicalKeyboardKey.delete): _apagarSelecao,
      const SingleActivator(LogicalKeyboardKey.backspace): _apagarSelecao,
      const SingleActivator(LogicalKeyboardKey.escape): () => _selecionar(null),
      const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
          _irPara(_cursor - 1),
      const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
          _irPara(_cursor + 1),
      const SingleActivator(LogicalKeyboardKey.arrowLeft, shift: true): () =>
          _empurrar(-0.1),
      const SingleActivator(LogicalKeyboardKey.arrowRight, shift: true): () =>
          _empurrar(0.1),
      const SingleActivator(LogicalKeyboardKey.bracketLeft): () =>
          _apararNoCursor(inicio: true),
      const SingleActivator(LogicalKeyboardKey.bracketRight): () =>
          _apararNoCursor(inicio: false),
    };

    // Ctrl no Windows/Linux, Cmd no Mac: o mesmo atalho registrado duas vezes
    // custa uma linha e evita um "por que não funciona aqui".
    void comando(
      LogicalKeyboardKey tecla,
      VoidCallback acao, {
      bool shift = false,
    }) {
      b[SingleActivator(tecla, control: true, shift: shift)] = acao;
      b[SingleActivator(tecla, meta: true, shift: shift)] = acao;
    }

    comando(LogicalKeyboardKey.keyZ, _desfazer);
    comando(LogicalKeyboardKey.keyZ, _refazer, shift: true);
    comando(LogicalKeyboardKey.keyY, _refazer);
    comando(LogicalKeyboardKey.keyC, _copiar);
    comando(LogicalKeyboardKey.keyV, _colar);
    comando(LogicalKeyboardKey.keyD, _duplicar);
    comando(LogicalKeyboardKey.keyA, _selecionarTudo);

    return b;
  }

  // ── tela ──────────────────────────────────────────────────────────────────

  /// Abaixo desta largura a barra lateral não cabe, e a tela vira uma coluna
  /// só — o app continua sendo usável num celular.
  static const double _larguraDeEditor = 900;

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      // Enquanto alguém escreve, **não há atalho registrado** — e isso é bem
      // diferente de haver um que não faz nada: o `CallbackShortcuts` marca a
      // tecla como tratada assim que algum atalho a aceita, e no navegador
      // tecla tratada vira `preventDefault`. A letra deixaria de chegar ao
      // campo, que foi o estado intermediário desta correção.
      bindings: _escrevendo
          ? const <ShortcutActivator, VoidCallback>{}
          : _atalhos,
      child: Focus(
        focusNode: _foco,
        autofocus: true,
        child: Scaffold(
          appBar: AppBar(
            title: _SeletorDeMontagem(
              nome: _nomeDaMontagem,
              montagens: _montagens,
              atual: _montagemId,
              onAbrir: _abrir,
              onNova: _novaMontagem,
            ),
            actions: [
              _EstadoDoRascunho(
                salvando: _salvando,
                salvoEm: _salvoEm,
                erro: _erroSalvar,
                onTentarDeNovo: _salvar,
              ),
              IconButton(
                tooltip: 'Desfazer (Ctrl+Z)',
                onPressed: _historia.podeDesfazer ? _desfazer : null,
                icon: const Icon(Icons.undo),
              ),
              IconButton(
                tooltip: 'Refazer (Ctrl+Shift+Z)',
                onPressed: _historia.podeRefazer ? _refazer : null,
                icon: const Icon(Icons.redo),
              ),
              IconButton(
                tooltip: _ima ? 'ímã ligado: gruda na batida' : 'ímã desligado',
                onPressed: () => setState(() => _ima = !_ima),
                icon: Icon(_ima ? Icons.grid_on : Icons.grid_off),
              ),
              PopupMenuButton<String>(
                key: const Key('menu-da-tela'),
                onSelected: (v) {
                  if (v == 'descartar') _apagarMontagem();
                  if (v == 'atalhos') _mostrarAtalhos();
                  if (v == 'renomear') _renomearMontagem();
                  if (v == 'duplicar') _duplicarMontagem();
                  if (v == 'marcar') _marcarVersao();
                  if (v == 'historico') _verHistorico();
                  if (v == 'aplicar-preset') _aplicarPredefinicao();
                  if (v == 'salvar-preset') _salvarPredefinicao();
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'renomear', child: Text('Renomear')),
                  PopupMenuItem(
                    value: 'duplicar',
                    child: Text('Duplicar esta montagem'),
                  ),
                  PopupMenuDivider(),
                  PopupMenuItem(
                    value: 'aplicar-preset',
                    child: Text('Aplicar predefinição…'),
                  ),
                  PopupMenuItem(
                    value: 'salvar-preset',
                    child: Text('Salvar como predefinição…'),
                  ),
                  PopupMenuDivider(),
                  PopupMenuItem(
                    value: 'marcar',
                    child: Text('Marcar esta versão'),
                  ),
                  PopupMenuItem(
                    value: 'historico',
                    child: Text('Histórico de versões…'),
                  ),
                  PopupMenuDivider(),
                  PopupMenuItem(
                    value: 'atalhos',
                    child: Text('Atalhos do teclado'),
                  ),
                  PopupMenuItem(
                    value: 'descartar',
                    child: Text('Apagar esta montagem'),
                  ),
                ],
              ),
            ],
          ),
          body: LayoutBuilder(
            builder: (context, restricoes) {
              final cabeLateral = restricoes.maxWidth >= _larguraDeEditor;
              if (!cabeLateral) {
                return _principal(encaixarMomentos: true);
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(width: 300, child: _lateral()),
                  const VerticalDivider(width: 1),
                  Expanded(child: _principal(encaixarMomentos: false)),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  void _mostrarAtalhos() {
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Atalhos'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: const [
              _Atalho('Espaço / K', 'tocar ou pausar'),
              _Atalho('J / L', 'voltar 2s / tocar'),
              _Atalho('← →', 'mover a cabeça de leitura (1s)'),
              _Atalho(', / .', 'andar um quadro'),
              _Atalho('Shift + ← →', 'empurrar os cortes selecionados'),
              _Atalho('S', 'dividir o corte sob o cursor'),
              _Atalho('M', 'alinhar a jogada do bloco escolhido ao cursor'),
              _Atalho('[ / ]', 'aparar o começo / o fim até o cursor'),
              _Atalho('Delete', 'tirar da montagem'),
              _Atalho('Ctrl+Z / Ctrl+Shift+Z', 'desfazer / refazer'),
              _Atalho('Ctrl+C / Ctrl+V', 'copiar / colar'),
              _Atalho('Ctrl+D', 'duplicar'),
              _Atalho('Ctrl+A', 'selecionar tudo'),
              _Atalho('Shift + clique', 'somar à seleção'),
              _Atalho('arrastar ↑ ↓', 'levar o corte para outra camada'),
              _Atalho('Esc', 'limpar a seleção'),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Fechar'),
          ),
        ],
      ),
    );
  }

  /// A lateral: o que o sistema achou e o que o usuário trouxe, lado a lado —
  /// as duas respondem à mesma pergunta, "o que eu ponho agora?".
  Widget _lateral() => DefaultTabController(
    length: 2,
    child: Column(
      children: [
        const TabBar(
          tabs: [
            Tab(text: 'Momentos'),
            Tab(text: 'Biblioteca'),
          ],
        ),
        Expanded(
          child: TabBarView(
            children: [
              _momentos(encaixado: false),
              _biblioteca_(encaixado: false),
            ],
          ),
        ),
      ],
    ),
  );

  Widget _biblioteca_({required bool encaixado}) => _Biblioteca(
    itens: _biblioteca,
    enviando: _importando,
    erro: _erroImportar,
    enabled: !_enviando,
    encaixado: encaixado,
    onImportar: _importar,
    onUsar: _usarMidia,
    onTirar: _tirarDaBiblioteca,
  );

  Widget _momentos({required bool encaixado}) => _Momentos(
    jobId: widget.job.id,
    momentos: _momentosDaPartida,
    usados: {for (final c in _estado.clips) chaveDoMomento(c.kind, c.sourceT)},
    enabled: !_enviando,
    encaixado: encaixado,
    onAdicionar: _adicionar,
  );

  Widget _principal({required bool encaixarMomentos}) {
    final theme = Theme.of(context);
    final duracao = duracaoDoVideo(_estado.clips);
    final preto = duracaoEmPreto(_estado.clips);
    final selecao = _estado.selecao;

    return ListView(
      padding: const EdgeInsets.fromLTRB(0, 8, 0, 32),
      children: [
        // ── o monitor, com a alça de altura ─────────────────────────────────
        if (widget.job.monitorUrl != null) ...[
          SizedBox(
            height: _monitorH,
            child: Center(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: PreviewPlayer(
                  // o proxy quando houver; nas partidas antigas, a gravação
                  videoUrl: widget.job.monitorUrl!,
                  cuts: _estado.clipesVisiveis,
                  atS: _cursor,
                  playing: _tocando,
                  // o texto é desenhado por cima da imagem, e arrastá-lo ali é
                  // como se decide onde ele fica: a alternativa era digitar
                  // dois números e gerar o vídeo para conferir
                  textos: _textosVisiveis,
                  selecao: _estado.selecao,
                  onSelecionarTexto: _selecionar,
                  onMoverTexto: (id, x, y) =>
                      _editar(posicionarNoQuadro(_estado, id, x: x, y: y)),
                  onArrastando: (t) => setState(() => _arrastando = t),
                ),
              ),
            ),
          ),
          _AlcaDeAltura(
            key: const Key('alca-monitor'),
            onArrastar: (dy) => setState(
              () => _monitorH = (_monitorH + dy).clamp(120.0, 560.0),
            ),
          ),
        ],

        // ── transporte ──────────────────────────────────────────────────────
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
          child: Row(
            children: [
              IconButton.filledTonal(
                // depende de haver o que tocar, e não de haver música: um
                // vídeo sem trilha nenhuma continua sendo um vídeo a rever
                onPressed: _estado.vazia ? null : _tocarOuPausar,
                icon: Icon(_tocando ? Icons.pause : Icons.play_arrow),
              ),
              const SizedBox(width: 10),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    formatClock(_cursor),
                    style: theme.textTheme.titleMedium,
                  ),
                  // a régua é o tempo do vídeo que vai sair, e nada mais: a
                  // música mora nele, e não ele nela
                  Text(
                    'de ${formatClock(duracaoDoVideo(_estado.clips))}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.hintColor,
                    ),
                  ),
                ],
              ),
              // Numa tela estreita estes controles não cabem ao lado do
              // relógio. `reverse` os mantém encostados à direita quando cabem,
              // e rolando quando não — em vez de estourar o layout.
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  reverse: true,
                  child: Row(
                    children: [
                      IconButton(
                        tooltip: 'Dividir no cursor (S)',
                        onPressed: _estado.vazia ? null : _dividirNoCursor,
                        icon: const Icon(Icons.content_cut),
                      ),
                      PopupMenuButton<String>(
                        tooltip: 'Escrever na tela',
                        icon: const Icon(Icons.title),
                        onSelected: (v) => switch (v) {
                          'livre' => _texto('TEXTO'),
                          'contador' => _gerarRotulos(
                            contadorDeEliminacoes(_estado.clips),
                            'eliminações',
                          ),
                          'rajada' => _gerarRotulos(
                            rotulosDeRajada(_estado.clips),
                            'rajadas',
                          ),
                          _ => null,
                        },
                        itemBuilder: (_) => const [
                          PopupMenuItem(
                            value: 'livre',
                            child: Text('Texto livre'),
                          ),
                          PopupMenuDivider(),
                          PopupMenuItem(
                            value: 'contador',
                            child: Text('Contador de eliminações'),
                          ),
                          PopupMenuItem(
                            value: 'rajada',
                            child: Text('Rótulos de rajada'),
                          ),
                        ],
                      ),
                      IconButton(
                        tooltip: 'Nova camada',
                        onPressed: () => _editar(adicionarCamada(_estado)),
                        icon: const Icon(Icons.layers_outlined),
                      ),
                      IconButton(
                        key: const Key('nova-camada-de-musica'),
                        tooltip: 'Nova camada de música',
                        onPressed: _novaCamadaDeMusica,
                        icon: const Icon(Icons.queue_music_outlined),
                      ),
                      IconButton(
                        tooltip: _estado.layers.length > 1
                            ? 'Tirar a camada ativa'
                            : 'A última camada não sai',
                        onPressed: _estado.layers.length > 1
                            ? () => _editar(
                                removerCamada(_estado, _estado.camadaAtiva),
                              )
                            : null,
                        icon: const Icon(Icons.layers_clear_outlined),
                      ),
                      const Icon(Icons.zoom_out, size: 18),
                      SizedBox(
                        width: 120,
                        child: Slider(
                          value: _px,
                          min: 20,
                          max: 220,
                          onChanged: (v) => setState(() => _px = v),
                        ),
                      ),
                      const Icon(Icons.zoom_in, size: 18),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),

        // ── a régua da música com os blocos ─────────────────────────────────
        MusicTimeline(
          musicas: _musicas,
          batidas: _batidas,
          layers: _estado.layers,
          camadaAtiva: _estado.camadaAtiva,
          selecao: selecao,
          pxPerSecond: _px,
          playheadS: _cursor,
          scroll: _scroll,
          onSeek: _irPara,
          onSelect: _selecionar,
          onMove: _mover,
          onTrim: _aparar,
          onStretch: _esticar,
          onDragLabel: (texto) => setState(() => _arrastando = texto),
          onGestoInicio: _historia.abrirGesto,
          onGestoFim: _historia.fecharGesto,
          onTrocarDeCamada: _trocarDeCamada,
          onCamadaAtiva: (i) => _semHistorico(_estado.copyWith(camadaAtiva: i)),
          onReordenarCamadas: (de, para) =>
              _editar(reordenarCamadas(_estado, de, para)),
          onAjustarCamada: (i, {muted, hidden, locked}) => _editar(
            ajustarCamada(
              _estado,
              i,
              muted: muted,
              hidden: hidden,
              locked: locked,
            ),
          ),
          ondaDaPartida: widget.job.waveform,
          duracaoDaPartida: widget.job.durationS,
          onSoltar: _soltarNaRegua,
        ),

        Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
          child: Text(
            _arrastando ??
                (_erroMusica ??
                    'Arraste um momento ou um item da Biblioteca para a régua.'),
            style: theme.textTheme.bodySmall?.copyWith(
              color: _arrastando != null
                  ? theme.colorScheme.primary
                  : _erroMusica != null
                  ? theme.colorScheme.error
                  : theme.hintColor,
            ),
          ),
        ),

        if (selecao.length == 1) ...[
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: _BlocoSelecionado(
              cut: _estado.clipe(selecao.first)!,
              midia: _midiaDoBloco(selecao.first),
              onSpeed: (v) => _efeito(selecao.first, speed: v),
              onColor: (v) => _efeito(selecao.first, color: v),
              onFade: (v) => _efeito(selecao.first, fade: v),
              onZoom: (v) => _efeito(selecao.first, zoom: v),
              onFreeze: (v) => _efeito(selecao.first, freeze: v),
              onReverse: (v) => _efeito(selecao.first, reverse: v),
              onTexto: (v) =>
                  _editar(trocarTexto(_estado, selecao.first, texto: v)),
              onEstilo: (v) =>
                  _editar(trocarTexto(_estado, selecao.first, estilo: v)),
              onSairDoCampo: _devolverOFoco,
              onDuracao: (d) => _esticar(selecao.first, d),
              onDeslocar: (d) => _deslocar(selecao.first, d),
              onParaOCursor: () => _mover(selecao.first, _cursor),
              onMomentoNoCursor: () => _alinharMomentoAoCursor(selecao.first),
              onApagar: _apagarSelecao,
              onDividir: _dividirNoCursor,
              onDuplicar: _duplicar,
            ),
          ),
        ] else if (selecao.length > 1) ...[
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: _SelecaoMultipla(
              quantos: selecao.length,
              onApagar: _apagarSelecao,
              onDuplicar: _duplicar,
              onLimpar: () => _selecionar(null),
            ),
          ),
        ],

        if (_temMusica) ...[
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: _Mistura(
              musicVolume: _estado.musicVolume,
              gameVolume: _estado.gameVolume,
              temMusica: true,
              onMudou: (musica, jogo) => _editar(
                _estado.copyWith(musicVolume: musica, gameVolume: jogo),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: _GradeDeBatidas(
              offsetS: _estado.beatOffsetS,
              multiplicador: _estado.beatMultiplier,
              compasso: _estado.beatBar,
              quantas: _batidas.length,
              onMudou: (offset, mult, compasso) => _editar(
                _estado.copyWith(
                  beatOffsetS: offset,
                  beatMultiplier: mult,
                  beatBar: compasso,
                ),
              ),
            ),
          ),
        ],

        if (encaixarMomentos) ...[
          const SizedBox(height: 18),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: _momentos(encaixado: true),
          ),
          const SizedBox(height: 18),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: _biblioteca_(encaixado: true),
          ),
        ],

        const SizedBox(height: 14),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: _Exportacao(
            spec: _estado.export,
            duracaoS: duracao,
            largura: widget.job.width,
            altura: widget.job.height,
            temSelecao: selecao.isNotEmpty,
            imagens: [
              for (final m in _biblioteca)
                if (m.kind == 'image' && m.isReady) m,
            ],
            enabled: !_enviando,
            onMudou: (e) => _editar(_estado.copyWith(export: e)),
            onExportarSelecao: () => _editar(exportarSelecao(_estado)),
            onExportarTudo: () => _editar(exportarTudo(_estado)),
          ),
        ),

        const SizedBox(height: 20),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _titulo,
                enabled: !_enviando,
                // Tocar fora devolve o foco à montagem, e com ele os atalhos.
                // Nada tira o foco de um `TextField` por conta própria: sem
                // isto, um toque aqui matava o "S" e o Delete para sempre.
                onTapOutside: (_) => _devolverOFoco(),
                onChanged: (v) => _semHistorico(_estado.copyWith(title: v)),
                decoration: const InputDecoration(
                  labelText: 'Nome do vídeo',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                _estado.vazia
                    ? 'Escolha um momento para pôr o primeiro corte onde a '
                          'cabeça de leitura estiver.'
                    // um bloco de música não é um corte: quem conta cortes
                    // quer saber quantas cenas o vídeo tem
                    : '${_estado.clipesVisiveis.length} corte(s)'
                          '${_temMusica ? '  ·  com música' : ''}'
                          '  ·  vídeo de ${formatDuration(duracao)}'
                          '${preto > 0.05 ? '  ·  ${formatDuration(preto)} de tela preta' : ''}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.hintColor,
                ),
              ),
              if (preto > 0.05)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    'Os espaços vazios entre os blocos ficam pretos, com a '
                    'música tocando.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.hintColor,
                    ),
                  ),
                ),
              if (_erro != null) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.error.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    _erro!,
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                ),
              ],
              const SizedBox(height: 16),
              if (_enviando)
                const Center(child: CircularProgressIndicator())
              else
                FilledButton.icon(
                  onPressed: _estado.vazia ? null : _gerar,
                  icon: const Icon(Icons.movie_creation_outlined),
                  label: Text(
                    _estado.vazia
                        ? 'Ponha ao menos um corte'
                        : 'Gerar este vídeo',
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// O nome da montagem aberta, e a porta para as outras.
///
/// Fica no lugar do título da tela de propósito: numa partida com três
/// montagens, saber **qual** está aberta importa mais do que ler "Montar
/// vídeo" pela décima vez.
class _SeletorDeMontagem extends StatelessWidget {
  const _SeletorDeMontagem({
    required this.nome,
    required this.montagens,
    required this.atual,
    required this.onAbrir,
    required this.onNova,
  });

  final String nome;
  final List<SavedMontage> montagens;
  final String? atual;
  final ValueChanged<SavedMontage> onAbrir;
  final VoidCallback onNova;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PopupMenuButton<String>(
      key: const Key('seletor-de-montagem'),
      tooltip: 'Montagens desta partida',
      onSelected: (v) {
        if (v == '+') {
          onNova();
          return;
        }
        final m = montagens.where((x) => x.id == v).firstOrNull;
        if (m != null) onAbrir(m);
      },
      itemBuilder: (_) => [
        for (final m in montagens)
          PopupMenuItem(
            value: m.id,
            key: ValueKey('abrir-${m.id}'),
            child: Row(
              children: [
                Icon(
                  m.id == atual ? Icons.check : Icons.movie_outlined,
                  size: 18,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(m.name, overflow: TextOverflow.ellipsis),
                      Text(
                        m.isEmpty
                            ? 'vazia'
                            : '${m.nClips} corte(s) · '
                                  '${formatDuration(m.durationS)}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.hintColor,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        if (montagens.isNotEmpty) const PopupMenuDivider(),
        const PopupMenuItem(
          value: '+',
          child: Row(
            children: [
              Icon(Icons.add, size: 18),
              SizedBox(width: 8),
              Text('Nova montagem'),
            ],
          ),
        ),
      ],
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(child: Text(nome, overflow: TextOverflow.ellipsis)),
          const Icon(Icons.arrow_drop_down),
        ],
      ),
    );
  }
}

/// Uma linha da lista de atalhos.
class _Atalho extends StatelessWidget {
  const _Atalho(this.tecla, this.oQueFaz);

  final String tecla;
  final String oQueFaz;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      children: [
        SizedBox(
          width: 170,
          child: Text(tecla, style: const TextStyle(fontFeatures: [])),
        ),
        Expanded(
          child: Text(
            oQueFaz,
            style: TextStyle(color: Theme.of(context).hintColor),
          ),
        ),
      ],
    ),
  );
}

/// O controle da grade de batidas.
///
/// O detector de ritmo acerta o andamento quase sempre e erra de duas maneiras
/// previsíveis: pega o contratempo, ou conta o dobro/metade das batidas.
/// Nenhuma das duas se conserta arrastando bloco por bloco — quem está errada é
/// a régua, e endireitá-la conserta todos de uma vez.
class _GradeDeBatidas extends StatelessWidget {
  const _GradeDeBatidas({
    required this.offsetS,
    required this.multiplicador,
    required this.compasso,
    required this.quantas,
    required this.onMudou,
  });

  final double offsetS;
  final double multiplicador;
  final int compasso;
  final int quantas;

  /// (deslocamento, multiplicador, compasso)
  final void Function(double, double, int) onMudou;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ajustada = offsetS != 0 || multiplicador != 1 || compasso != 1;

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.straighten, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Grade de batidas',
                    style: theme.textTheme.titleSmall,
                  ),
                ),
                Text(
                  '$quantas no vídeo',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.hintColor,
                  ),
                ),
                if (ajustada)
                  TextButton(
                    onPressed: () => onMudou(0, 1, 1),
                    child: const Text('Como veio'),
                  ),
              ],
            ),
            Text(
              'Se o ímã estiver grudando fora do tempo, é aqui que se conserta '
              '— e conserta para todos os cortes de uma vez.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.hintColor,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                const Expanded(child: Text('Densidade')),
                SegmentedButton<double>(
                  showSelectedIcon: false,
                  style: const ButtonStyle(
                    visualDensity: VisualDensity.compact,
                  ),
                  segments: const [
                    ButtonSegment(value: 0.5, label: Text('½')),
                    ButtonSegment(value: 1.0, label: Text('1×')),
                    ButtonSegment(value: 2.0, label: Text('2×')),
                  ],
                  selected: {multiplicador},
                  onSelectionChanged: (v) =>
                      onMudou(offsetS, v.first, compasso),
                ),
              ],
            ),
            Row(
              children: [
                const Expanded(child: Text('Grudar no')),
                SegmentedButton<int>(
                  showSelectedIcon: false,
                  style: const ButtonStyle(
                    visualDensity: VisualDensity.compact,
                  ),
                  segments: const [
                    ButtonSegment(value: 1, label: Text('tempo')),
                    ButtonSegment(value: 2, label: Text('2')),
                    ButtonSegment(value: 4, label: Text('compasso')),
                  ],
                  selected: {compasso},
                  onSelectionChanged: (v) =>
                      onMudou(offsetS, multiplicador, v.first),
                ),
              ],
            ),
            Row(
              children: [
                Expanded(
                  child: Text(
                    offsetS == 0
                        ? 'Deslocamento'
                        : 'Deslocamento ${offsetS > 0 ? '+' : ''}'
                              '${offsetS.toStringAsFixed(2)}s',
                  ),
                ),
                _Passo(
                  onMenos: () =>
                      onMudou(offsetS - 0.02, multiplicador, compasso),
                  onMais: () =>
                      onMudou(offsetS + 0.02, multiplicador, compasso),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// O painel de quando há mais de um bloco escolhido.
class _SelecaoMultipla extends StatelessWidget {
  const _SelecaoMultipla({
    required this.quantos,
    required this.onApagar,
    required this.onDuplicar,
    required this.onLimpar,
  });

  final int quantos;
  final VoidCallback onApagar;
  final VoidCallback onDuplicar;
  final VoidCallback onLimpar;

  @override
  Widget build(BuildContext context) => Card(
    margin: EdgeInsets.zero,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
      child: Row(
        children: [
          Expanded(child: Text('$quantos cortes selecionados')),
          IconButton(
            tooltip: 'Duplicar (Ctrl+D)',
            onPressed: onDuplicar,
            icon: const Icon(Icons.copy_all_outlined),
          ),
          IconButton(
            tooltip: 'Tirar da montagem (Delete)',
            onPressed: onApagar,
            icon: const Icon(Icons.delete_outline),
          ),
          IconButton(
            tooltip: 'Limpar a seleção (Esc)',
            onPressed: onLimpar,
            icon: const Icon(Icons.deselect),
          ),
        ],
      ),
    ),
  );
}

/// A alça que muda a altura do monitor.
///
/// Um editor divide a tela entre ver o quadro e ver o ritmo, e a divisão certa
/// muda a cada minuto de trabalho — então quem decide é quem está editando.
class _AlcaDeAltura extends StatelessWidget {
  const _AlcaDeAltura({super.key, required this.onArrastar});

  final ValueChanged<double> onArrastar;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return MouseRegion(
      cursor: SystemMouseCursors.resizeUpDown,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onVerticalDragUpdate: (d) => onArrastar(d.delta.dy),
        child: SizedBox(
          height: 16,
          child: Center(
            child: Container(
              width: 46,
              height: 4,
              decoration: BoxDecoration(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.25),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _BlocoSelecionado extends StatelessWidget {
  const _BlocoSelecionado({
    required this.cut,
    required this.midia,
    required this.onDuracao,
    required this.onDeslocar,
    required this.onParaOCursor,
    required this.onMomentoNoCursor,
    required this.onApagar,
    required this.onDividir,
    required this.onDuplicar,
    required this.onSpeed,
    required this.onColor,
    required this.onFade,
    required this.onZoom,
    required this.onFreeze,
    required this.onReverse,
    required this.onTexto,
    required this.onEstilo,
    this.onSairDoCampo,
  });

  final TimelineClip cut;

  /// O arquivo de onde o bloco saiu, quando ele veio da biblioteca. Um bloco
  /// de música fala do som, e não da imagem — que ele não tem.
  final Media? midia;

  final ValueChanged<double> onDuracao;
  final ValueChanged<double> onDeslocar;
  final VoidCallback onParaOCursor;

  /// Leva a jogada deste bloco para debaixo da cabeça de leitura.
  final VoidCallback onMomentoNoCursor;
  final VoidCallback onApagar;
  final VoidCallback onDividir;
  final VoidCallback onDuplicar;
  final ValueChanged<double> onSpeed;
  final ValueChanged<ClipColor> onColor;
  final ValueChanged<ClipFade> onFade;
  final ValueChanged<List<ZoomKey>> onZoom;
  final ValueChanged<bool> onFreeze;
  final ValueChanged<bool> onReverse;
  final ValueChanged<String> onTexto;
  final ValueChanged<ClipTextStyle> onEstilo;

  /// Repassado ao campo de texto: toque fora dele devolve os atalhos.
  final VoidCallback? onSairDoCampo;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = EventStyle.of(cut.kind);
    final m = midia;
    final som = m?.isAudio ?? false;

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  som
                      ? Icons.music_note
                      : m != null
                      ? Icons.movie_outlined
                      : Icons.crop_free,
                  size: 16,
                  color: m == null ? style.color : theme.colorScheme.primary,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    m == null
                        ? '${style.label} de ${formatClock(cut.sourceT)}'
                        : m.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
                IconButton(
                  tooltip: 'Dividir no cursor (S)',
                  visualDensity: VisualDensity.compact,
                  onPressed: onDividir,
                  icon: const Icon(Icons.content_cut),
                ),
                IconButton(
                  tooltip: 'Duplicar (Ctrl+D)',
                  visualDensity: VisualDensity.compact,
                  onPressed: onDuplicar,
                  icon: const Icon(Icons.copy_all_outlined),
                ),
                IconButton(
                  tooltip: 'Tirar da montagem (Delete)',
                  visualDensity: VisualDensity.compact,
                  onPressed: onApagar,
                  icon: const Icon(Icons.delete_outline),
                ),
              ],
            ),
            Text(
              'entra em ${formatClock(cut.atS)} do vídeo  ·  '
              '${cut.durationS.toStringAsFixed(2)}s'
              // de que ponto da faixa este pedaço saiu: é o que diz se o
              // bloco pegou o refrão ou a introdução
              '${som ? '  ·  a partir de ${formatClock(cut.startS)} da música' : ''}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.hintColor,
              ),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                const Expanded(child: Text('Duração')),
                _Passo(
                  onMenos: () => onDuracao(cut.durationS - 0.1),
                  onMais: () => onDuracao(cut.durationS + 0.1),
                ),
              ],
            ),
            Row(
              children: [
                Expanded(
                  child: Text(som ? 'Trecho da música' : 'Enquadramento'),
                ),
                _Passo(
                  onMenos: () => onDeslocar(-0.2),
                  onMais: () => onDeslocar(0.2),
                ),
              ],
            ),
            Align(
              alignment: Alignment.centerRight,
              child: Wrap(
                alignment: WrapAlignment.end,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  // Alinhar pela **jogada**, e não pela borda: o corte começa
                  // antes dela para dar embalo, e é ela que precisa cair na
                  // batida. Só aparece quando há jogada dentro do bloco.
                  if (momentoNoVideo(cut) != null)
                    TextButton.icon(
                      key: const Key('alinhar-momento'),
                      onPressed: onMomentoNoCursor,
                      icon: const Icon(Icons.center_focus_strong, size: 18),
                      label: const Text('Alinhar a jogada ao cursor'),
                    ),
                  TextButton.icon(
                    onPressed: onParaOCursor,
                    icon: const Icon(Icons.vertical_align_center, size: 18),
                    label: const Text('Mover para o cursor'),
                  ),
                ],
              ),
            ),
            if (cut.isText)
              _TextoDoClipe(
                cut: cut,
                onTexto: onTexto,
                onEstilo: onEstilo,
                onSairDoCampo: onSairDoCampo,
              ),
            // um bloco de música não desenha nada: zoom, cor e congelar não
            // teriam sobre o que agir
            if (!som)
              _Efeitos(
                cut: cut,
                onSpeed: onSpeed,
                onColor: onColor,
                onFade: onFade,
                onZoom: onZoom,
                onFreeze: onFreeze,
                onReverse: onReverse,
              ),
          ],
        ),
      ),
    );
  }
}

class _Passo extends StatelessWidget {
  const _Passo({required this.onMenos, required this.onMais});

  final VoidCallback onMenos;
  final VoidCallback onMais;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      IconButton(
        visualDensity: VisualDensity.compact,
        onPressed: onMenos,
        icon: const Icon(Icons.remove_circle_outline),
      ),
      IconButton(
        visualDensity: VisualDensity.compact,
        onPressed: onMais,
        icon: const Icon(Icons.add_circle_outline),
      ),
    ],
  );
}

/// A prateleira de momentos: o que dá para pôr no vídeo.
///
/// Cada item traz o quadro daquele instante da partida. Sem imagem, escolher
/// entre trinta eliminações é escolher entre trinta relógios — e a diferença
/// entre a jogada que vale e as outras está justamente no que se vê.
///
/// Um momento não se gasta ao ser usado: o item continua ali, marcado, porque
/// o mesmo instante pode entrar duas vezes na mesma montagem.
class _Momentos extends StatelessWidget {
  const _Momentos({
    required this.jobId,
    required this.momentos,
    required this.usados,
    required this.enabled,
    required this.encaixado,
    required this.onAdicionar,
  });

  final String jobId;
  final List<DetectionEvent> momentos;

  /// Os momentos que já estão na régua, por [chaveDoMomento].
  ///
  /// Por tipo **e** instante, e não só pelo instante: uma eliminação na cabeça
  /// acende os dois detectores quase junto, e marcar pelo tempo faria pôr a
  /// eliminação riscar o headshot que ainda não entrou.
  final Set<String> usados;
  final bool enabled;

  /// `true` quando a lista mora dentro da coluna principal (tela estreita) e
  /// portanto não pode ter rolagem própria.
  final bool encaixado;
  final ValueChanged<DetectionEvent> onAdicionar;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (momentos.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Text(
          'A análise não achou nenhum momento nesta partida.',
          style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
        ),
      );
    }

    final cabecalho = Padding(
      padding: EdgeInsets.fromLTRB(encaixado ? 0 : 14, 12, 14, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Momentos da partida', style: theme.textTheme.titleSmall),
          const SizedBox(height: 4),
          Text(
            'Clique para pôr o corte onde a música estiver. O mesmo momento '
            'pode entrar mais de uma vez.',
            style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
          ),
        ],
      ),
    );

    final itens = [
      for (final e in momentos)
        _MomentoTile(
          // tipo + instante: dois detectores podem cair no mesmo tempo, e duas
          // chaves iguais na mesma lista derrubam a tela
          key: ValueKey('momento-${chaveDoMomento(e.kind, e.t)}'),
          jobId: jobId,
          evento: e,
          usado: usados.contains(chaveDoMomento(e.kind, e.t)),
          enabled: enabled,
          onAdicionar: () => onAdicionar(e),
        ),
    ];

    if (encaixado) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [cabecalho, ...itens],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        cabecalho,
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 24),
            children: itens,
          ),
        ),
      ],
    );
  }
}

/// O que fica sob o dedo enquanto se arrasta para a régua.
///
/// Um retângulo do tamanho e da cor do bloco que vai nascer: o gesto mostra o
/// resultado antes de acontecer.
class _Fantasma extends StatelessWidget {
  const _Fantasma({required this.rotulo, required this.cor});

  final String rotulo;
  final Color cor;

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.transparent,
    child: Container(
      width: 140,
      height: 44,
      alignment: Alignment.centerLeft,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: cor.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        rotulo,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: Colors.white, fontSize: 12),
      ),
    ),
  );
}

class _MomentoTile extends StatelessWidget {
  const _MomentoTile({
    super.key,
    required this.jobId,
    required this.evento,
    required this.usado,
    required this.enabled,
    required this.onAdicionar,
  });

  final String jobId;
  final DetectionEvent evento;
  final bool usado;
  final bool enabled;
  final VoidCallback onAdicionar;

  /// O nome que este momento leva no cartão e no fantasma.
  ///
  /// Uma eliminação com habilidade diz **qual** — "Orisa: Energy Javelin" e não
  /// "Morte por habilidade". Numa partida com cinco habilidades diferentes, o
  /// rótulo genérico daria cinco cartões idênticos, e escolher entre eles seria
  /// escolher no escuro.
  String get _rotulo {
    final ability = evento.ability;
    return ability != null ? nomeDaHabilidade(ability) : EventStyle.of(evento.kind).label;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = EventStyle.of(evento.kind);

    // `affinity: horizontal` deixa a prateleira continuar rolando na vertical:
    // o arrasto que interessa é o que sai dela em direção à régua
    return Draggable<ArrastoParaARegua>(
      data: ArrastoParaARegua.momento(evento),
      affinity: Axis.horizontal,
      // o fantasma pendurado no dedo, e não no ponto do cartão em que se
      // pegou: é o dedo que diz onde o bloco cai, e a régua faz essa conta com
      // o canto do fantasma
      dragAnchorStrategy: pointerDragAnchorStrategy,
      maxSimultaneousDrags: enabled ? 1 : 0,
      feedback: _Fantasma(rotulo: _rotulo, cor: style.color),
      childWhenDragging: Opacity(
        opacity: 0.4,
        child: _cartao(context, theme, style),
      ),
      child: _cartao(context, theme, style),
    );
  }

  Widget _cartao(BuildContext context, ThemeData theme, EventStyle style) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        onTap: enabled ? onAdicionar : null,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: _Frame(
                  url: frameUrl(jobId, evento.t),
                  cor: style.color,
                  largura: 104,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _rotulo,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: style.color,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      formatClock(evento.t),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.hintColor,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                usado ? Icons.check_circle : Icons.add_circle_outline,
                size: 20,
                color: usado ? style.color : theme.hintColor,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// O quadro de um momento, com paciência para esperá-lo existir.
///
/// As miniaturas são extraídas por um worker depois da análise, então numa
/// partida recém-aberta elas ainda podem não estar lá — e uma partida antiga
/// só ganha as suas quando o editor pede. Em vez de mostrar um erro definitivo,
/// o quadro tenta de novo algumas vezes e vai aparecendo sozinho.
class _Frame extends StatefulWidget {
  const _Frame({required this.url, required this.cor, required this.largura});

  final String url;
  final Color cor;
  final double largura;

  @override
  State<_Frame> createState() => _FrameState();
}

class _FrameState extends State<_Frame> {
  static const _maxTentativas = 6;
  int _tentativa = 0;
  Timer? _proxima;

  @override
  void dispose() {
    _proxima?.cancel();
    super.dispose();
  }

  void _tentarDeNovo() {
    if (_tentativa >= _maxTentativas || _proxima != null) return;
    _proxima = Timer(const Duration(seconds: 3), () async {
      _proxima = null;
      // sem despejar, o Flutter guarda o 404 e nunca mais busca esta URL
      await NetworkImage(widget.url).evict();
      if (mounted) setState(() => _tentativa++);
    });
  }

  @override
  Widget build(BuildContext context) {
    final altura = widget.largura * 9 / 16;
    return SizedBox(
      width: widget.largura,
      height: altura,
      child: Image.network(
        widget.url,
        key: ValueKey('${widget.url}#$_tentativa'),
        fit: BoxFit.cover,
        errorBuilder: (context, _, _) {
          _tentarDeNovo();
          return ColoredBox(
            color: widget.cor.withValues(alpha: 0.18),
            child: Center(
              child: Icon(
                Icons.image_outlined,
                size: 18,
                color: widget.cor.withValues(alpha: 0.7),
              ),
            ),
          );
        },
        loadingBuilder: (context, child, progresso) => progresso == null
            ? child
            : ColoredBox(color: widget.cor.withValues(alpha: 0.10)),
      ),
    );
  }
}

/// Diz, discretamente, que o trabalho está guardado.
///
/// Existe porque a montagem passou a viver no servidor: sem um sinal, o
/// usuário não teria como saber que pode fechar a aba — e foi justamente
/// perder tudo num F5 que motivou o salvamento automático.
class _EstadoDoRascunho extends StatelessWidget {
  const _EstadoDoRascunho({
    required this.salvando,
    required this.salvoEm,
    required this.erro,
    required this.onTentarDeNovo,
  });

  final bool salvando;
  final DateTime? salvoEm;
  final String? erro;
  final VoidCallback onTentarDeNovo;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (erro != null) {
      return TextButton.icon(
        onPressed: onTentarDeNovo,
        icon: Icon(Icons.cloud_off, size: 16, color: theme.colorScheme.error),
        label: Text(
          'não salvou',
          style: TextStyle(color: theme.colorScheme.error, fontSize: 12),
        ),
      );
    }
    if (salvando) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Center(
          child: Text(
            'salvando…',
            style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
          ),
        ),
      );
    }
    if (salvoEm == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Center(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_done_outlined, size: 15, color: theme.hintColor),
            const SizedBox(width: 5),
            Text(
              'salvo',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.hintColor,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A biblioteca de mídia da partida: o que o usuário trouxe de fora.
///
/// Fica ao lado da prateleira de momentos porque as duas respondem à mesma
/// pergunta — "o que eu ponho agora?". A diferença é que os momentos o sistema
/// achou, e isto aqui o usuário trouxe.
class _Biblioteca extends StatelessWidget {
  const _Biblioteca({
    required this.itens,
    required this.enviando,
    required this.erro,
    required this.enabled,
    required this.encaixado,
    required this.onImportar,
    required this.onUsar,
    required this.onTirar,
  });

  final List<Media> itens;
  final bool enviando;
  final String? erro;
  final bool enabled;
  final bool encaixado;
  final VoidCallback onImportar;
  final ValueChanged<Media> onUsar;
  final ValueChanged<Media> onTirar;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final cabecalho = Padding(
      padding: EdgeInsets.fromLTRB(encaixado ? 0 : 14, 12, 14, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text('Biblioteca', style: theme.textTheme.titleSmall),
              ),
              if (enviando)
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                TextButton.icon(
                  onPressed: enabled ? onImportar : null,
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Trazer'),
                ),
            ],
          ),
          Text(
            'Vídeo, imagem ou música de fora da partida — é por aqui que a '
            'música entra. Clique para pôr na cabeça de leitura, ou arraste '
            'para a régua.',
            style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
          ),
          if (erro != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                erro!,
                style: TextStyle(color: theme.colorScheme.error, fontSize: 12),
              ),
            ),
        ],
      ),
    );

    // a música mora aqui junto com o resto: ela é mídia de fora da partida como
    // qualquer outra, e ter uma segunda porta só para ela era o que fazia
    // parecer que havia dois jeitos de pôr som no vídeo
    final visuais = itens;

    final lista = visuais.isEmpty
        ? [
            Padding(
              padding: EdgeInsets.fromLTRB(encaixado ? 0 : 14, 0, 14, 12),
              child: Text(
                'Nada aqui ainda.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.hintColor,
                ),
              ),
            ),
          ]
        : [
            for (final m in visuais)
              _ItemDaBiblioteca(
                key: ValueKey('midia-${m.id}'),
                item: m,
                enabled: enabled,
                onUsar: () => onUsar(m),
                onTirar: () => onTirar(m),
              ),
          ];

    if (encaixado) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [cabecalho, ...lista],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        cabecalho,
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 24),
            children: lista,
          ),
        ),
      ],
    );
  }
}

class _ItemDaBiblioteca extends StatelessWidget {
  const _ItemDaBiblioteca({
    super.key,
    required this.item,
    required this.enabled,
    required this.onUsar,
    required this.onTirar,
  });

  final Media item;
  final bool enabled;
  final VoidCallback onUsar;
  final VoidCallback onTirar;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pronto = item.isReady;

    return Draggable<ArrastoParaARegua>(
      data: ArrastoParaARegua.midia(item),
      affinity: Axis.horizontal,
      dragAnchorStrategy: pointerDragAnchorStrategy,
      maxSimultaneousDrags: enabled && pronto ? 1 : 0,
      feedback: _Fantasma(
        rotulo: item.name,
        cor: item.isAudio
            ? theme.colorScheme.primary
            : theme.colorScheme.secondary,
      ),
      childWhenDragging: Opacity(opacity: 0.4, child: _cartao(theme, pronto)),
      child: _cartao(theme, pronto),
    );
  }

  Widget _cartao(ThemeData theme, bool pronto) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        onTap: enabled && pronto ? onUsar : null,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: SizedBox(
                  width: 72,
                  height: 41,
                  child: item.thumbUrl == null
                      ? ColoredBox(
                          color: theme.colorScheme.primary.withValues(
                            alpha: 0.15,
                          ),
                          child: Icon(
                            item.isAudio
                                ? Icons.music_note
                                : item.isImage
                                ? Icons.image_outlined
                                : Icons.movie_outlined,
                            size: 18,
                            color: item.isAudio
                                ? theme.colorScheme.primary
                                : theme.hintColor,
                          ),
                        )
                      : Image.network(item.thumbUrl!, fit: BoxFit.cover),
                  // som não tem miniatura: o ícone é o que diz o que é
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      item.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelMedium,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      item.isFailed
                          ? (item.error ?? 'não consegui ler este arquivo')
                          : item.isPending
                          ? 'analisando…'
                          : [
                              item.isImage
                                  ? 'imagem'
                                  : formatDuration(item.durationS),
                              if (item.width > 0)
                                '${item.width}×${item.height}',
                              // de música o que importa é o andamento: é por
                              // ele que se decide o tamanho do corte
                              if (item.isAudio && item.bpm > 0)
                                '${item.bpm.round()} BPM',
                            ].join('  ·  '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: item.isFailed
                            ? theme.colorScheme.error
                            : theme.hintColor,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Tirar da biblioteca',
                visualDensity: VisualDensity.compact,
                onPressed: enabled ? onTirar : null,
                icon: const Icon(Icons.close, size: 18),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Os efeitos do clipe escolhido.
///
/// Fica recolhido por padrão: a maioria das montagens é corte seco, e um painel
/// sempre aberto empurraria a régua para fora da tela.
class _Efeitos extends StatelessWidget {
  const _Efeitos({
    required this.cut,
    required this.onSpeed,
    required this.onColor,
    required this.onFade,
    required this.onZoom,
    required this.onFreeze,
    required this.onReverse,
  });

  final TimelineClip cut;
  final ValueChanged<double> onSpeed;
  final ValueChanged<ClipColor> onColor;
  final ValueChanged<ClipFade> onFade;
  final ValueChanged<List<ZoomKey>> onZoom;
  final ValueChanged<bool> onFreeze;
  final ValueChanged<bool> onReverse;

  /// Quantos efeitos estão em uso — para o título dizer que há algo ali sem
  /// precisar abrir.
  int get _ativos =>
      (cut.speed != 1 ? 1 : 0) +
      (cut.color.neutra ? 0 : 1) +
      (cut.fade.neutro ? 0 : 1) +
      (cut.zoom.isEmpty ? 0 : 1) +
      (cut.freeze ? 1 : 0) +
      (cut.reverse ? 1 : 0);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      childrenPadding: const EdgeInsets.only(bottom: 8),
      title: Row(
        children: [
          const Icon(Icons.auto_fix_high, size: 16),
          const SizedBox(width: 8),
          Text('Efeitos', style: theme.textTheme.labelLarge),
          if (_ativos > 0) ...[
            const SizedBox(width: 8),
            Text(
              '$_ativos em uso',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
          ],
        ],
      ),
      children: [
        // O zoom vem pronto: dois pontos resolvem o efeito mais usado numa
        // montagem, e é melhor isso do que um editor de curvas que ninguém abre.
        Row(
          children: [
            const SizedBox(width: 92, child: Text('Aproximar')),
            Expanded(
              child: Wrap(
                spacing: 6,
                children: [
                  for (final (rotulo, ate) in const [
                    ('leve', 1.3),
                    ('médio', 1.6),
                    ('forte', 2.2),
                  ])
                    ChoiceChip(
                      label: Text(rotulo),
                      selected:
                          cut.zoom.isNotEmpty &&
                          (cut.zoom[1].scale - ate).abs() < 0.01,
                      onSelected: (_) => onZoom(punch(ate: ate)),
                    ),
                  if (cut.zoom.isNotEmpty)
                    ActionChip(
                      avatar: const Icon(Icons.close, size: 14),
                      label: const Text('tirar'),
                      onPressed: () => onZoom(const []),
                    ),
                ],
              ),
            ),
          ],
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          value: cut.freeze,
          onChanged: onFreeze,
          title: const Text('Congelar'),
          subtitle: const Text('a imagem para; o bloco dura o mesmo'),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          value: cut.reverse,
          onChanged: onReverse,
          title: const Text('De trás para frente'),
        ),
        _Deslizante(
          rotulo: 'Velocidade',
          valor: cut.speed,
          minimo: 0.25,
          maximo: 4,
          // a duração no vídeo não muda: o que muda é quanto da gravação entra
          legenda: cut.speed == 1
              ? 'normal'
              : '${cut.speed.toStringAsFixed(2)}×  ·  come '
                    '${cut.fonteConsumidaS.toStringAsFixed(1)}s da gravação',
          onChanged: onSpeed,
          onZerar: cut.speed == 1 ? null : () => onSpeed(1),
        ),
        _Deslizante(
          rotulo: 'Entrada',
          valor: cut.fade.inS,
          minimo: 0,
          maximo: 2,
          legenda: cut.fade.inS == 0
              ? 'corte seco'
              : 'aparece em ${cut.fade.inS.toStringAsFixed(2)}s',
          onChanged: (v) => onFade(cut.fade.copyWith(inS: v)),
          onZerar: cut.fade.inS == 0
              ? null
              : () => onFade(cut.fade.copyWith(inS: 0)),
        ),
        _Deslizante(
          rotulo: 'Saída',
          valor: cut.fade.outS,
          minimo: 0,
          maximo: 2,
          legenda: cut.fade.outS == 0
              ? 'corte seco'
              : 'some em ${cut.fade.outS.toStringAsFixed(2)}s',
          onChanged: (v) => onFade(cut.fade.copyWith(outS: v)),
          onZerar: cut.fade.outS == 0
              ? null
              : () => onFade(cut.fade.copyWith(outS: 0)),
        ),
        _Deslizante(
          rotulo: 'Brilho',
          valor: cut.color.brightness,
          minimo: -0.5,
          maximo: 0.5,
          onChanged: (v) => onColor(cut.color.copyWith(brightness: v)),
          onZerar: cut.color.brightness == 0
              ? null
              : () => onColor(cut.color.copyWith(brightness: 0)),
        ),
        _Deslizante(
          rotulo: 'Contraste',
          valor: cut.color.contrast,
          minimo: 0.5,
          maximo: 2,
          onChanged: (v) => onColor(cut.color.copyWith(contrast: v)),
          onZerar: cut.color.contrast == 1
              ? null
              : () => onColor(cut.color.copyWith(contrast: 1)),
        ),
        _Deslizante(
          rotulo: 'Cor',
          valor: cut.color.saturation,
          minimo: 0,
          maximo: 2,
          legenda: cut.color.saturation == 0 ? 'preto e branco' : null,
          onChanged: (v) => onColor(cut.color.copyWith(saturation: v)),
          onZerar: cut.color.saturation == 1
              ? null
              : () => onColor(cut.color.copyWith(saturation: 1)),
        ),
      ],
    );
  }
}

class _Deslizante extends StatelessWidget {
  const _Deslizante({
    required this.rotulo,
    required this.valor,
    required this.minimo,
    required this.maximo,
    required this.onChanged,
    this.legenda,
    this.onZerar,
  });

  final String rotulo;
  final double valor;
  final double minimo;
  final double maximo;
  final String? legenda;
  final ValueChanged<double> onChanged;

  /// `null` quando já está no valor neutro — não há o que desfazer.
  final VoidCallback? onZerar;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        SizedBox(
          width: 92,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(rotulo, style: theme.textTheme.bodyMedium),
              if (legenda != null)
                Text(
                  legenda!,
                  maxLines: 2,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.hintColor,
                    fontSize: 10,
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child: Slider(
            value: valor.clamp(minimo, maximo),
            min: minimo,
            max: maximo,
            onChanged: onChanged,
          ),
        ),
        IconButton(
          tooltip: 'Voltar ao normal',
          visualDensity: VisualDensity.compact,
          onPressed: onZerar,
          icon: const Icon(Icons.restart_alt, size: 18),
        ),
      ],
    );
  }
}

/// A mistura de áudio da montagem inteira.
class _Mistura extends StatelessWidget {
  const _Mistura({
    required this.musicVolume,
    required this.gameVolume,
    required this.temMusica,
    required this.onMudou,
  });

  final double musicVolume;
  final double gameVolume;
  final bool temMusica;

  /// (volume da música, volume do jogo)
  final void Function(double, double) onMudou;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.graphic_eq, size: 18),
                const SizedBox(width: 8),
                Text('Mistura', style: theme.textTheme.titleSmall),
              ],
            ),
            Text(
              temMusica
                  ? 'Com o jogo em zero, a música toca sozinha. Acima disso o '
                        'tiro aparece por baixo dela.'
                  : 'Sem trilha, o vídeo fica com o áudio da partida.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.hintColor,
              ),
            ),
            const SizedBox(height: 6),
            _Deslizante(
              rotulo: 'Música',
              valor: musicVolume,
              minimo: 0,
              maximo: 2,
              onChanged: temMusica ? (v) => onMudou(v, gameVolume) : (_) {},
              onZerar: musicVolume == 1 ? null : () => onMudou(1, gameVolume),
            ),
            _Deslizante(
              rotulo: 'Jogo',
              valor: gameVolume,
              minimo: 0,
              maximo: 2,
              legenda: gameVolume == 0 && temMusica ? 'mudo' : null,
              onChanged: temMusica ? (v) => onMudou(musicVolume, v) : (_) {},
              onZerar: gameVolume == 0 ? null : () => onMudou(musicVolume, 0),
            ),
          ],
        ),
      ),
    );
  }
}

/// O que sai quando se aperta "gerar".
///
/// Fica separado do resto do inspetor de propósito: nada aqui muda a montagem.
/// Trocar 16:9 por 9:16 não move um clipe sequer — muda a janela por onde se
/// olha para o mesmo trabalho, e dá para voltar atrás sem desfazer nada.
class _Exportacao extends StatelessWidget {
  const _Exportacao({
    required this.spec,
    required this.duracaoS,
    required this.largura,
    required this.altura,
    required this.temSelecao,
    required this.imagens,
    required this.enabled,
    required this.onMudou,
    required this.onExportarSelecao,
    required this.onExportarTudo,
  });

  final ExportSpec spec;
  final double duracaoS;
  final int largura;
  final int altura;
  final bool temSelecao;

  /// A biblioteca, filtrada: só imagem serve de marca d'água.
  final List<Media> imagens;
  final bool enabled;
  final ValueChanged<ExportSpec> onMudou;
  final VoidCallback onExportarSelecao;
  final VoidCallback onExportarTudo;

  /// A saída pede corte ou barras? Só então a escolha entre os dois importa.
  bool get _mudaProporcao {
    if (spec.width == 0 || largura == 0 || altura == 0) return false;
    return ((spec.width / spec.height) - (largura / altura)).abs() > 0.01;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final trecho = trechoDe(spec, duracaoS);
    final recortado = trecho.fim - trecho.inicio < duracaoS - 0.05;

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.aspect_ratio, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('Saída', style: theme.textTheme.titleSmall),
                ),
                if (!spec.padrao)
                  TextButton(
                    onPressed: enabled
                        ? () => onMudou(const ExportSpec())
                        : null,
                    child: const Text('Padrão'),
                  ),
              ],
            ),
            Text(
              resumoDaExportacao(
                spec,
                duracaoS: duracaoS,
                largura: largura == 0 ? 1920 : largura,
                altura: altura == 0 ? 1080 : altura,
              ),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.hintColor,
              ),
            ),

            const SizedBox(height: 8),
            _LinhaDeOpcoes(
              rotulo: 'Formato',
              children: [
                for (final f in formatosDeSaida)
                  ChoiceChip(
                    label: Text(f.nome),
                    tooltip: f.nota,
                    selected: f.combina(spec),
                    onSelected: enabled
                        ? (_) => onMudou(
                            spec.copyWith(width: f.width, height: f.height),
                          )
                        : null,
                  ),
              ],
            ),

            if (_mudaProporcao)
              _LinhaDeOpcoes(
                rotulo: 'Enquadrar',
                children: [
                  ChoiceChip(
                    label: const Text('Preencher'),
                    tooltip: 'corta as sobras dos lados',
                    selected: spec.fit == 'cover',
                    onSelected: enabled
                        ? (_) => onMudou(spec.copyWith(fit: 'cover'))
                        : null,
                  ),
                  ChoiceChip(
                    label: const Text('Caber'),
                    tooltip: 'mostra o quadro inteiro, com barras',
                    selected: spec.fit == 'contain',
                    onSelected: enabled
                        ? (_) => onMudou(spec.copyWith(fit: 'contain'))
                        : null,
                  ),
                ],
              ),

            _LinhaDeOpcoes(
              rotulo: 'Quadros',
              children: [
                for (final f in fpsDeSaida)
                  ChoiceChip(
                    label: Text(f == 0 ? 'Original' : f.toStringAsFixed(0)),
                    selected: spec.fps == f,
                    onSelected: enabled
                        ? (_) => onMudou(spec.copyWith(fps: f))
                        : null,
                  ),
              ],
            ),

            _LinhaDeOpcoes(
              rotulo: 'Qualidade',
              children: [
                for (final q in qualidades)
                  ChoiceChip(
                    label: Text(q.nome),
                    tooltip: q.nota,
                    selected: qualidadeDe(spec).crf == q.crf,
                    onSelected: enabled
                        ? (_) => onMudou(spec.copyWith(crf: q.crf))
                        : null,
                  ),
              ],
            ),

            _LinhaDeOpcoes(
              rotulo: 'Trecho',
              children: [
                ChoiceChip(
                  label: const Text('Tudo'),
                  selected: !recortado,
                  onSelected: enabled ? (_) => onExportarTudo() : null,
                ),
                ChoiceChip(
                  label: const Text('Só a seleção'),
                  tooltip: temSelecao
                      ? 'exporta do primeiro ao último bloco escolhido'
                      : 'escolha blocos na linha do tempo',
                  selected: recortado,
                  onSelected: enabled && temSelecao
                      ? (_) => onExportarSelecao()
                      : null,
                ),
                if (recortado)
                  Text(
                    '${formatDuration(trecho.inicio)} → '
                    '${formatDuration(trecho.fim)}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.hintColor,
                    ),
                  ),
              ],
            ),

            _LinhaDeOpcoes(
              rotulo: 'Marca',
              children: [
                ChoiceChip(
                  label: const Text('Nenhuma'),
                  selected: spec.watermarkId == null,
                  onSelected: enabled
                      ? (_) => onMudou(spec.copyWith(limparMarca: true))
                      : null,
                ),
                for (final m in imagens)
                  ChoiceChip(
                    label: Text(m.name, overflow: TextOverflow.ellipsis),
                    selected: spec.watermarkId == m.id,
                    onSelected: enabled
                        ? (_) => onMudou(spec.copyWith(watermarkId: m.id))
                        : null,
                  ),
                if (imagens.isEmpty)
                  Text(
                    'importe uma imagem na biblioteca',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.hintColor,
                    ),
                  ),
              ],
            ),

            if (spec.watermarkId != null) ...[
              _LinhaDeOpcoes(
                rotulo: 'Canto',
                children: [
                  for (final canto in kCantosDaMarca)
                    ChoiceChip(
                      label: Text(canto.nome),
                      selected:
                          (spec.watermarkX > 0) == (canto.x > 0) &&
                          (spec.watermarkY > 0) == (canto.y > 0),
                      onSelected: enabled
                          ? (_) => onMudou(
                              spec.copyWith(
                                watermarkX: canto.x,
                                watermarkY: canto.y,
                              ),
                            )
                          : null,
                    ),
                ],
              ),
              _Deslizante(
                rotulo: 'Tamanho',
                valor: spec.watermarkScale,
                minimo: 0.03,
                maximo: 0.5,
                onChanged: (v) => onMudou(spec.copyWith(watermarkScale: v)),
                onZerar: spec.watermarkScale == 0.12
                    ? null
                    : () => onMudou(spec.copyWith(watermarkScale: 0.12)),
              ),
              _Deslizante(
                rotulo: 'Opacidade',
                valor: spec.watermarkOpacity,
                minimo: 0.05,
                maximo: 1,
                onChanged: (v) => onMudou(spec.copyWith(watermarkOpacity: v)),
                onZerar: spec.watermarkOpacity == 0.65
                    ? null
                    : () => onMudou(spec.copyWith(watermarkOpacity: 0.65)),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Um rótulo à esquerda e as opções à direita, quebrando quando não cabem.
class _LinhaDeOpcoes extends StatelessWidget {
  const _LinhaDeOpcoes({required this.rotulo, required this.children});

  final String rotulo;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          SizedBox(
            width: 74,
            child: Text(rotulo, style: theme.textTheme.bodyMedium),
          ),
          Expanded(
            child: Wrap(
              spacing: 6,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: children,
            ),
          ),
        ],
      ),
    );
  }
}

/// O que está escrito num clipe de texto, e como.
class _TextoDoClipe extends StatefulWidget {
  const _TextoDoClipe({
    required this.cut,
    required this.onTexto,
    required this.onEstilo,
    this.onSairDoCampo,
  });

  final TimelineClip cut;
  final ValueChanged<String> onTexto;
  final ValueChanged<ClipTextStyle> onEstilo;

  /// Avisa que o toque caiu fora do campo — é o sinal de que os atalhos da
  /// montagem podem voltar a valer.
  final VoidCallback? onSairDoCampo;

  @override
  State<_TextoDoClipe> createState() => _TextoDoClipeState();
}

class _TextoDoClipeState extends State<_TextoDoClipe> {
  late final TextEditingController _c = TextEditingController(
    text: widget.cut.text,
  );

  @override
  void didUpdateWidget(_TextoDoClipe old) {
    super.didUpdateWidget(old);
    // trocar de clipe tem de trocar o que está no campo; digitar, não
    if (old.cut.id != widget.cut.id) _c.text = widget.cut.text;
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  /// As cores que servem a um rótulo sobre gameplay. Uma paleta pequena vale
  /// mais que um seletor: o que importa é o texto aparecer.
  static const _cores = ['white', 'yellow', 'orange', 'red', 'cyan', 'black'];

  static const _paraTela = {
    'white': Colors.white,
    'yellow': Color(0xFFFFD54F),
    'orange': Color(0xFFFF9800),
    'red': Color(0xFFFF5252),
    'cyan': Color(0xFF4DD0E1),
    'black': Colors.black,
  };

  @override
  Widget build(BuildContext context) {
    final estilo = widget.cut.textStyle;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _c,
          onTapOutside: (_) => widget.onSairDoCampo?.call(),
          onChanged: widget.onTexto,
          decoration: const InputDecoration(
            labelText: 'O que está escrito',
            border: OutlineInputBorder(),
            isDense: true,
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            const SizedBox(width: 92, child: Text('Cor')),
            Expanded(
              child: Wrap(
                spacing: 6,
                children: [
                  for (final cor in _cores)
                    GestureDetector(
                      onTap: () => widget.onEstilo(estilo.copyWith(color: cor)),
                      child: Container(
                        width: 26,
                        height: 26,
                        decoration: BoxDecoration(
                          color: _paraTela[cor],
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: estilo.color == cor
                                ? Theme.of(context).colorScheme.primary
                                : Colors.white24,
                            width: estilo.color == cor ? 3 : 1,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
        _Deslizante(
          rotulo: 'Tamanho',
          valor: estilo.size,
          minimo: 0.03,
          maximo: 0.3,
          legenda: '${(estilo.size * 100).round()}% da altura',
          onChanged: (v) => widget.onEstilo(estilo.copyWith(size: v)),
          onZerar: estilo.size == 0.08
              ? null
              : () => widget.onEstilo(estilo.copyWith(size: 0.08)),
        ),
        _Deslizante(
          rotulo: 'Contorno',
          valor: estilo.outline,
          minimo: 0,
          maximo: 0.4,
          legenda: estilo.outline == 0
              ? 'sem contorno — some em cena clara'
              : null,
          onChanged: (v) => widget.onEstilo(estilo.copyWith(outline: v)),
          onZerar: estilo.outline == 0.12
              ? null
              : () => widget.onEstilo(estilo.copyWith(outline: 0.12)),
        ),
      ],
    );
  }
}
