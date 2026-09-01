import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:http/http.dart' as http;

import 'upload.dart';

/// Base da API. Quando o app Flutter é servido pelo próprio gateway, fica
/// vazia e as chamadas viram relativas — assim funciona em qualquer host sem
/// recompilar. Em desenvolvimento o app roda numa porta e a API em outra.
const String kApiBase = String.fromEnvironment(
  'API_BASE',
  defaultValue: 'http://localhost:8000',
);

/// Transforma o caminho devolvido pela API numa URL absoluta.
///
/// Em produção o app é compilado com [kApiBase] vazio para chamar a API em
/// caminho relativo — o que funciona para `fetch` e para a tag `<video>`, que o
/// navegador resolve sozinho. Mas quem abre um download precisa de URL
/// absoluta: `Uri.parse('/api/...')` não tem esquema nem host, e o
/// `url_launcher` recusa. `Uri.base` é o endereço da página, então resolver
/// contra ele dá a URL completa em qualquer host.
String absoluteUrl(String pathOrUrl) {
  final uri = Uri.parse(pathOrUrl);
  if (uri.hasScheme) return pathOrUrl;
  return Uri.base.resolve(pathOrUrl).toString();
}

/// A miniatura de um instante da partida.
///
/// O `.toStringAsFixed(2)` não é cosmético: a chave do arquivo no servidor sai
/// do instante arredondado em centésimos, então pedir com outra precisão é
/// pedir um arquivo que não existe.
String frameUrl(String jobId, double t) =>
    absoluteUrl('$kApiBase/api/jobs/$jobId/frame?t=${t.toStringAsFixed(2)}');

class ApiException implements Exception {
  ApiException(this.message, [this.statusCode]);
  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

// ─────────────────────────────── modelos ────────────────────────────────────

/// Parâmetros da **análise**: como ler a partida.
///
/// Valem para a partida inteira e são decididos no upload. Já foram muitos
/// mais — quantas eliminações faziam uma rajada, quantas faziam um "sozinho
/// contra todos" — porque a análise terminava propondo vídeos prontos. Ela não
/// propõe mais: entrega os momentos, e agrupá-los é trabalho de quem edita.
class JobParams {
  const JobParams({this.ultNegateWindowS = 6});

  /// Uma ultimate inimiga seguida de eliminação dentro desta janela conta
  /// como ultimate anulada — a única leitura que precisa de dois detectores.
  final double ultNegateWindowS;

  Map<String, dynamic> toJson() => {'ult_negate_window_s': ultNegateWindowS};

  JobParams copyWith({double? ultNegateWindowS}) =>
      JobParams(ultNegateWindowS: ultNegateWindowS ?? this.ultNegateWindowS);
}

/// Uma música enviada para a partida, já ouvida pelo sistema.
///
/// Ela sobe **antes** de existir vídeo nenhum: é ouvindo a música, com as
/// batidas e a forma de onda desenhadas, que o usuário decide onde cada corte
/// cai. Por isso ela é da partida, e não de um pedido — a mesma trilha serve a
/// quantas montagens ele quiser.
class Track {
  Track({
    required this.id,
    required this.status,
    required this.name,
    required this.durationS,
    required this.bpm,
    required this.beats,
    required this.peaks,
    required this.audioUrl,
    this.error,
  });

  factory Track.fromJson(Map<String, dynamic> j) => Track(
    id: j['id'] as String,
    status: j['status'] as String,
    name: j['name'] as String? ?? '',
    durationS: (j['duration_s'] as num?)?.toDouble() ?? 0,
    bpm: (j['bpm'] as num?)?.toDouble() ?? 0,
    beats: ((j['beats'] as List?) ?? [])
        .map((e) => (e as num).toDouble())
        .toList(),
    peaks: ((j['peaks'] as List?) ?? [])
        .map((e) => (e as num).toDouble())
        .toList(),
    audioUrl: absoluteUrl('$kApiBase${j['audio_url']}'),
    error: j['error'] as String?,
  );

  final String id;
  final String status;
  final String name;
  final double durationS;
  final double bpm;

  /// Instantes das batidas. É o que o ímã usa para grudar os cortes.
  final List<double> beats;

  /// Envelope da música em 0..1, já reduzido pelo servidor: o app desenha a
  /// onda sem baixar o áudio inteiro só para isso.
  final List<double> peaks;
  final String audioUrl;
  final String? error;

  bool get isReady => status == 'ready';
  bool get isFailed => status == 'failed';
  bool get isPending => status == 'pending';
}

/// Onde e de que tamanho o clipe aparece no quadro.
///
/// Chama-se `ClipTransform` e não `Transform` porque o Flutter já tem um widget
/// com esse nome, e as duas coisas se encontram em toda tela que desenha a
/// régua.
///
/// [x] e [y] são deslocamentos do centro normalizados pela metade do quadro:
/// -1 encosta na borda esquerda/superior, +1 na direita/inferior. Assim a mesma
/// montagem vale em qualquer resolução — o que importa é a proporção.
class ClipTransform {
  const ClipTransform({
    this.scale = 1,
    this.x = 0,
    this.y = 0,
    this.opacity = 1,
  });

  factory ClipTransform.fromJson(Map<String, dynamic> j) => ClipTransform(
    scale: (j['scale'] as num?)?.toDouble() ?? 1,
    x: (j['x'] as num?)?.toDouble() ?? 0,
    y: (j['y'] as num?)?.toDouble() ?? 0,
    opacity: (j['opacity'] as num?)?.toDouble() ?? 1,
  );

  final double scale;
  final double x;
  final double y;
  final double opacity;

  /// O clipe entra do jeito que veio, sem nada por cima.
  bool get neutra => scale == 1 && x == 0 && y == 0 && opacity == 1;

  ClipTransform copyWith({
    double? scale,
    double? x,
    double? y,
    double? opacity,
  }) => ClipTransform(
    scale: scale ?? this.scale,
    x: x ?? this.x,
    y: y ?? this.y,
    opacity: opacity ?? this.opacity,
  );

  Map<String, dynamic> toJson() => {
    'scale': scale,
    'x': x,
    'y': y,
    'opacity': opacity,
  };
}

/// O som do próprio clipe — que não é a trilha do vídeo.
class ClipAudio {
  const ClipAudio({
    this.volume = 1,
    this.mute = false,
    this.fadeInS = 0,
    this.fadeOutS = 0,
  });

  factory ClipAudio.fromJson(Map<String, dynamic> j) => ClipAudio(
    volume: (j['volume'] as num?)?.toDouble() ?? 1,
    mute: j['mute'] as bool? ?? false,
    fadeInS: (j['fade_in_s'] as num?)?.toDouble() ?? 0,
    fadeOutS: (j['fade_out_s'] as num?)?.toDouble() ?? 0,
  );

  final double volume;
  final bool mute;
  final double fadeInS;
  final double fadeOutS;

  bool get neutro => volume == 1 && !mute && fadeInS == 0 && fadeOutS == 0;

  ClipAudio copyWith({
    double? volume,
    bool? mute,
    double? fadeInS,
    double? fadeOutS,
  }) => ClipAudio(
    volume: volume ?? this.volume,
    mute: mute ?? this.mute,
    fadeInS: fadeInS ?? this.fadeInS,
    fadeOutS: fadeOutS ?? this.fadeOutS,
  );

  Map<String, dynamic> toJson() => {
    'volume': volume,
    'mute': mute,
    'fade_in_s': fadeInS,
    'fade_out_s': fadeOutS,
  };
}

/// Uma camada da linha do tempo.
///
/// Chama-se camada, e não faixa, porque `Track` neste sistema já é a música que
/// o usuário enviou. A ordem na lista é a ordem de empilhamento: a primeira é o
/// fundo, a última fica por cima.
class Layer {
  const Layer({
    this.kind = 'video',
    this.name = '',
    this.muted = false,
    this.hidden = false,
    this.locked = false,
    this.clips = const [],
  });

  factory Layer.fromJson(Map<String, dynamic> j) => Layer(
    kind: j['kind'] as String? ?? 'video',
    name: j['name'] as String? ?? '',
    muted: j['muted'] as bool? ?? false,
    hidden: j['hidden'] as bool? ?? false,
    locked: j['locked'] as bool? ?? false,
    clips: ((j['clips'] as List?) ?? [])
        .map((e) => TimelineClip.fromJson(e as Map<String, dynamic>))
        .toList(),
  );

  /// `video` ou `audio`. Uma camada desenha ou toca — não as duas coisas.
  final String kind;

  bool get isAudio => kind == 'audio';

  final String name;
  final bool muted;
  final bool hidden;

  /// Travada não muda nada no vídeo — é o app que recusa editar.
  final bool locked;
  final List<TimelineClip> clips;

  double get durationS => clips.fold(0, (m, c) => c.untilS > m ? c.untilS : m);

  Layer copyWith({
    String? kind,
    String? name,
    bool? muted,
    bool? hidden,
    bool? locked,
    List<TimelineClip>? clips,
  }) => Layer(
    kind: kind ?? this.kind,
    name: name ?? this.name,
    muted: muted ?? this.muted,
    hidden: hidden ?? this.hidden,
    locked: locked ?? this.locked,
    clips: clips ?? this.clips,
  );

  Map<String, dynamic> toJson() => {
    'kind': kind,
    'name': name,
    'muted': muted,
    'hidden': hidden,
    'locked': locked,
    'clips': [for (final c in clips) c.toJson()],
  };
}

/// Ajuste de cor do clipe.
///
/// Os três que resolvem quase tudo numa montagem de gameplay: gravação escura,
/// gravação lavada, gravação sem cor.
class ClipColor {
  const ClipColor({
    this.brightness = 0,
    this.contrast = 1,
    this.saturation = 1,
  });

  factory ClipColor.fromJson(Map<String, dynamic> j) => ClipColor(
    brightness: (j['brightness'] as num?)?.toDouble() ?? 0,
    contrast: (j['contrast'] as num?)?.toDouble() ?? 1,
    saturation: (j['saturation'] as num?)?.toDouble() ?? 1,
  );

  final double brightness;
  final double contrast;
  final double saturation;

  bool get neutra => brightness == 0 && contrast == 1 && saturation == 1;

  ClipColor copyWith({
    double? brightness,
    double? contrast,
    double? saturation,
  }) => ClipColor(
    brightness: brightness ?? this.brightness,
    contrast: contrast ?? this.contrast,
    saturation: saturation ?? this.saturation,
  );

  Map<String, dynamic> toJson() => {
    'brightness': brightness,
    'contrast': contrast,
    'saturation': saturation,
  };
}

/// Entrada e saída do clipe, em segundos.
///
/// São transições de e para o **fundo** — que numa montagem em camadas é preto.
/// A transição *entre dois clipes* é outra coisa, e não cabe no formato de
/// sobreposição.
class ClipFade {
  const ClipFade({this.inS = 0, this.outS = 0});

  factory ClipFade.fromJson(Map<String, dynamic> j) => ClipFade(
    inS: (j['in_s'] as num?)?.toDouble() ?? 0,
    outS: (j['out_s'] as num?)?.toDouble() ?? 0,
  );

  final double inS;
  final double outS;

  bool get neutro => inS == 0 && outS == 0;

  ClipFade copyWith({double? inS, double? outS}) =>
      ClipFade(inS: inS ?? this.inS, outS: outS ?? this.outS);

  Map<String, dynamic> toJson() => {'in_s': inS, 'out_s': outS};
}

/// Como o texto aparece.
///
/// Chama-se `ClipTextStyle` e não `TextStyle` porque o Flutter já tem uma
/// classe com esse nome, e as duas se encontram em toda tela que desenha texto.
///
/// Tamanho e contorno são **frações da altura do quadro**, não pixels: a mesma
/// montagem tem de sair igual em 720p e em 4K.
class ClipTextStyle {
  const ClipTextStyle({
    this.size = 0.08,
    this.color = 'white',
    this.outline = 0.12,
    this.outlineColor = 'black',
  });

  factory ClipTextStyle.fromJson(Map<String, dynamic> j) => ClipTextStyle(
    size: (j['size'] as num?)?.toDouble() ?? 0.08,
    color: j['color'] as String? ?? 'white',
    outline: (j['outline'] as num?)?.toDouble() ?? 0.12,
    outlineColor: j['outline_color'] as String? ?? 'black',
  );

  final double size;
  final String color;

  /// Contorno não é enfeite: sem ele, texto branco some em cena clara.
  final double outline;
  final String outlineColor;

  ClipTextStyle copyWith({
    double? size,
    String? color,
    double? outline,
    String? outlineColor,
  }) => ClipTextStyle(
    size: size ?? this.size,
    color: color ?? this.color,
    outline: outline ?? this.outline,
    outlineColor: outlineColor ?? this.outlineColor,
  );

  Map<String, dynamic> toJson() => {
    'size': size,
    'color': color,
    'outline': outline,
    'outline_color': outlineColor,
  };
}

/// Um ponto da animação de zoom, dentro do clipe.
///
/// [t] vai de 0 a 1 — é a fração do clipe, não segundos. Assim a animação
/// sobrevive a esticar ou aparar o bloco: um zoom que fecha no fim continua
/// fechando no fim.
class ZoomKey {
  const ZoomKey({required this.t, this.scale = 1, this.x = 0, this.y = 0});

  factory ZoomKey.fromJson(Map<String, dynamic> j) => ZoomKey(
    t: (j['t'] as num).toDouble(),
    scale: (j['scale'] as num?)?.toDouble() ?? 1,
    x: (j['x'] as num?)?.toDouble() ?? 0,
    y: (j['y'] as num?)?.toDouble() ?? 0,
  );

  final double t;
  final double scale;
  final double x;
  final double y;

  Map<String, dynamic> toJson() => {'t': t, 'scale': scale, 'x': x, 'y': y};
}

/// Um item da biblioteca de mídia da partida.
///
/// Começou como "a música do job" e virou a biblioteca — porque era a mesma
/// coisa: um arquivo sobe, um worker o analisa e o gateway o entrega com
/// `Range`. Uma música é um item de tipo `audio`, com batidas por cima.
class Media {
  Media({
    required this.id,
    required this.kind,
    required this.status,
    required this.name,
    required this.durationS,
    this.width = 0,
    this.height = 0,
    this.fps = 0,
    this.thumbUrl,
    this.proxyUrl,
    this.error,
    this.bpm = 0,
    this.beats = const [],
    this.peaks = const [],
    this.audioUrl = '',
  });

  factory Media.fromJson(Map<String, dynamic> j) => Media(
    id: j['id'] as String,
    kind: j['kind'] as String? ?? 'audio',
    status: j['status'] as String? ?? 'pending',
    name: j['name'] as String? ?? '',
    durationS: (j['duration_s'] as num?)?.toDouble() ?? 0,
    width: (j['width'] as num?)?.toInt() ?? 0,
    height: (j['height'] as num?)?.toInt() ?? 0,
    fps: (j['fps'] as num?)?.toDouble() ?? 0,
    thumbUrl: j['thumb_url'] == null
        ? null
        : absoluteUrl('$kApiBase${j['thumb_url']}'),
    proxyUrl: j['proxy_url'] == null
        ? null
        : absoluteUrl('$kApiBase${j['proxy_url']}'),
    error: j['error'] as String?,
    bpm: (j['bpm'] as num?)?.toDouble() ?? 0,
    beats: ((j['beats'] as List?) ?? const [])
        .map((e) => (e as num).toDouble())
        .toList(),
    peaks: ((j['peaks'] as List?) ?? const [])
        .map((e) => (e as num).toDouble())
        .toList(),
    audioUrl: j['audio_url'] == null
        ? ''
        : absoluteUrl('$kApiBase${j['audio_url']}'),
  );

  final String id;

  /// `audio`, `video` ou `image`.
  final String kind;
  final String status;
  final String name;
  final double durationS;
  final int width;
  final int height;
  final double fps;
  final String? thumbUrl;
  final String? proxyUrl;
  final String? error;

  /// Só de áudio: o que a régua precisa para desenhar a música e grudar os
  /// cortes na batida. Vem no mesmo item da biblioteca — pedir de novo por
  /// outra rota seria uma viagem à toa.
  final double bpm;
  final List<double> beats;
  final List<double> peaks;
  final String audioUrl;

  bool get isReady => status == 'ready';
  bool get isFailed => status == 'failed';
  bool get isPending => status == 'pending';
  bool get isAudio => kind == 'audio';
  bool get isImage => kind == 'image';

  /// A mesma música, vista como faixa.
  ///
  /// `Track` e `Media` de áudio são a mesma linha no banco; o app tem os dois
  /// nomes porque a régua fala de música e a biblioteca fala de arquivo.
  Track get comoMusica => Track(
    id: id,
    status: status,
    name: name,
    durationS: durationS,
    bpm: bpm,
    beats: beats,
    peaks: peaks,
    audioUrl: audioUrl,
    error: error,
  );

  /// Quanto um clipe deste item dura por padrão.
  ///
  /// Imagem não tem duração própria — quanto ela fica na tela é escolha da
  /// montagem —, e de um vídeo longo se usa um pedaço, não ele inteiro.
  double get duracaoSugerida =>
      isImage ? 2.0 : (durationS > 0 ? math.min(durationS, 3.0) : 2.0);
}

/// Um bloco na linha do tempo: um pedaço da gravação posto num ponto do vídeo.
///
/// [startS] e [durationS] dizem *o que* entra (na gravação); [atS] diz *onde*
/// (no vídeo que vai sair). São independentes — o mesmo momento pode aparecer
/// duas vezes, em pontos diferentes da música e com durações diferentes.
class TimelineClip {
  const TimelineClip({
    required this.startS,
    required this.durationS,
    required this.atS,
    this.sourceT = 0,
    this.kind = '',
    this.id = '',
    this.source = 'recording',
    this.mediaId,
    this.transform = const ClipTransform(),
    this.audio = const ClipAudio(),
    this.color = const ClipColor(),
    this.fade = const ClipFade(),
    this.speed = 1,
    this.zoom = const [],
    this.freeze = false,
    this.reverse = false,
    this.text = '',
    this.textStyle = const ClipTextStyle(),
  });

  /// Identidade do bloco **dentro do editor**. Não vai para o servidor e não
  /// tem significado nenhum lá.
  ///
  /// Existe porque índice não serve de identidade: apagar um bloco desloca
  /// todos os seguintes, e uma seleção múltipla ou um passo de "desfazer"
  /// passariam a apontar para o vizinho. Com id, quem é quem não depende de
  /// onde está na lista.
  final String id;

  /// Instante do momento que originou o bloco. Não afeta o corte: serve para
  /// rotular e para recalcular o enquadramento quando a duração muda.
  final double sourceT;
  final double startS;
  final double durationS;
  final double atS;
  final String kind;

  /// De onde sai a imagem: `recording` ou `media`. `text` chega com a fase que
  /// o desenha.
  final String source;

  /// Qual item da biblioteca, quando [source] é `media`.
  final String? mediaId;
  final ClipTransform transform;
  final ClipAudio audio;
  final ClipColor color;
  final ClipFade fade;

  /// Quanto mais rápido o clipe corre. 2 = dobro, 0.5 = câmera lenta.
  ///
  /// Muda quanto da fonte ele consome, não quanto ele ocupa no vídeo — isso é
  /// [durationS], que é o que se arrasta na régua.
  final double speed;

  /// Animação de zoom dentro do clipe. Vazia = sem animação.
  ///
  /// É o *punch* na batida. Zoom é coisa do conteúdo — olhar mais de perto o
  /// que está ali — e não se confunde com [ClipTransform.scale], que é o
  /// tamanho do clipe dentro do quadro.
  final List<ZoomKey> zoom;

  /// Congela em vez de correr. A duração continua sendo a do bloco.
  final bool freeze;
  final bool reverse;

  /// O que está escrito, quando [source] é `text`.
  final String text;
  final ClipTextStyle textStyle;

  bool get isText => source == 'text';

  /// Quanto da gravação este clipe come. A 2×, dois segundos de vídeo comem
  /// quatro de gravação — e um congelado come um quadro só.
  double get fonteConsumidaS => freeze ? 0.05 : durationS * speed;

  /// O clipe entra do jeito que veio, sem camada nem ajuste — é o que o
  /// caminho de corte-e-emenda do servidor dá conta de montar.
  bool get simples =>
      source == 'recording' &&
      transform.neutra &&
      audio.neutro &&
      color.neutra &&
      fade.neutro &&
      speed == 1 &&
      zoom.isEmpty &&
      !freeze &&
      !reverse;

  /// Onde o corte termina na gravação.
  double get endS => startS + durationS;

  /// Onde o bloco termina no vídeo.
  double get untilS => atS + durationS;

  TimelineClip copyWith({
    double? sourceT,
    double? startS,
    double? durationS,
    double? atS,
    String? kind,
    String? id,
    String? source,
    String? mediaId,
    ClipTransform? transform,
    ClipAudio? audio,
    ClipColor? color,
    ClipFade? fade,
    double? speed,
    List<ZoomKey>? zoom,
    bool? freeze,
    bool? reverse,
    String? text,
    ClipTextStyle? textStyle,
  }) => TimelineClip(
    sourceT: sourceT ?? this.sourceT,
    startS: startS ?? this.startS,
    durationS: durationS ?? this.durationS,
    atS: atS ?? this.atS,
    kind: kind ?? this.kind,
    id: id ?? this.id,
    source: source ?? this.source,
    mediaId: mediaId ?? this.mediaId,
    transform: transform ?? this.transform,
    audio: audio ?? this.audio,
    color: color ?? this.color,
    fade: fade ?? this.fade,
    speed: speed ?? this.speed,
    zoom: zoom ?? this.zoom,
    freeze: freeze ?? this.freeze,
    reverse: reverse ?? this.reverse,
    text: text ?? this.text,
    textStyle: textStyle ?? this.textStyle,
  );

  /// O `id` não vem do servidor: ele é atribuído ao carregar, por
  /// `montagemDoRascunho`.
  factory TimelineClip.fromJson(Map<String, dynamic> j) => TimelineClip(
    sourceT: (j['source_t'] as num?)?.toDouble() ?? 0,
    startS: (j['start_s'] as num).toDouble(),
    durationS: (j['duration_s'] as num).toDouble(),
    atS: (j['at_s'] as num).toDouble(),
    kind: j['kind'] as String? ?? '',
    source: j['source'] as String? ?? 'recording',
    mediaId: j['media_id'] as String?,
    transform: ClipTransform.fromJson(
      (j['transform'] as Map?)?.cast<String, dynamic>() ?? const {},
    ),
    audio: ClipAudio.fromJson(
      (j['audio'] as Map?)?.cast<String, dynamic>() ?? const {},
    ),
    color: ClipColor.fromJson(
      (j['color'] as Map?)?.cast<String, dynamic>() ?? const {},
    ),
    fade: ClipFade.fromJson(
      (j['fade'] as Map?)?.cast<String, dynamic>() ?? const {},
    ),
    speed: (j['speed'] as num?)?.toDouble() ?? 1,
    zoom: ((j['zoom'] as List?) ?? [])
        .map((e) => ZoomKey.fromJson(e as Map<String, dynamic>))
        .toList(),
    freeze: j['freeze'] as bool? ?? false,
    reverse: j['reverse'] as bool? ?? false,
    text: j['text'] as String? ?? '',
    textStyle: ClipTextStyle.fromJson(
      (j['text_style'] as Map?)?.cast<String, dynamic>() ?? const {},
    ),
  );

  Map<String, dynamic> toJson() => {
    'source_t': sourceT,
    'start_s': startS,
    'duration_s': durationS,
    'at_s': atS,
    'kind': kind,
    'source': source,
    if (mediaId != null) 'media_id': mediaId,
    if (!transform.neutra) 'transform': transform.toJson(),
    if (!audio.neutro) 'audio': audio.toJson(),
    if (!color.neutra) 'color': color.toJson(),
    if (!fade.neutro) 'fade': fade.toJson(),
    if (speed != 1) 'speed': speed,
    if (zoom.isNotEmpty) 'zoom': [for (final k in zoom) k.toJson()],
    if (freeze) 'freeze': true,
    if (reverse) 'reverse': true,
    if (isText) 'text': text,
    if (isText) 'text_style': textStyle.toJson(),
  };
}

/// Como o vídeo final é escrito.
///
/// Separado da montagem de propósito: a mesma montagem vira um 16:9 para o
/// YouTube e um 9:16 para os Shorts sem que nada dela mude. O que muda é a
/// janela por onde se olha.
class ExportSpec {
  const ExportSpec({
    this.width = 0,
    this.height = 0,
    this.fps = 0,
    this.crf = 20,
    this.fit = 'cover',
    this.fromS = 0,
    this.toS,
    this.watermarkId,
    this.watermarkScale = 0.12,
    this.watermarkX = 0.82,
    this.watermarkY = -0.82,
    this.watermarkOpacity = 0.65,
  });

  factory ExportSpec.fromJson(Map<String, dynamic> j) => ExportSpec(
    width: (j['width'] as num?)?.toInt() ?? 0,
    height: (j['height'] as num?)?.toInt() ?? 0,
    fps: (j['fps'] as num?)?.toDouble() ?? 0,
    crf: (j['crf'] as num?)?.toInt() ?? 20,
    fit: j['fit'] as String? ?? 'cover',
    fromS: (j['from_s'] as num?)?.toDouble() ?? 0,
    toS: (j['to_s'] as num?)?.toDouble(),
    watermarkId: j['watermark_id'] as String?,
    watermarkScale: (j['watermark_scale'] as num?)?.toDouble() ?? 0.12,
    watermarkX: (j['watermark_x'] as num?)?.toDouble() ?? 0.82,
    watermarkY: (j['watermark_y'] as num?)?.toDouble() ?? -0.82,
    watermarkOpacity: (j['watermark_opacity'] as num?)?.toDouble() ?? 0.65,
  );

  /// `0` nos dois = o tamanho da gravação.
  final int width;
  final int height;
  final double fps;

  /// Qualidade do H.264: menor é melhor.
  final int crf;

  /// `cover` preenche e corta as sobras; `contain` mostra tudo e deixa barras.
  final String fit;

  final double fromS;
  final double? toS;

  /// Item da biblioteca desenhado por cima de tudo.
  final String? watermarkId;

  /// Tamanho da marca em fração da largura, e o canto onde ela fica, medido
  /// do centro: `(1, -1)` é o canto superior direito.
  final double watermarkScale;
  final double watermarkX;
  final double watermarkY;
  final double watermarkOpacity;

  bool get padrao =>
      width == 0 &&
      fps == 0 &&
      crf == 20 &&
      fit == 'cover' &&
      fromS == 0 &&
      toS == null &&
      watermarkId == null;

  ExportSpec copyWith({
    int? width,
    int? height,
    double? fps,
    int? crf,
    String? fit,
    double? fromS,
    double? toS,
    bool limparTo = false,
    String? watermarkId,
    bool limparMarca = false,
    double? watermarkScale,
    double? watermarkX,
    double? watermarkY,
    double? watermarkOpacity,
  }) => ExportSpec(
    width: width ?? this.width,
    height: height ?? this.height,
    fps: fps ?? this.fps,
    crf: crf ?? this.crf,
    fit: fit ?? this.fit,
    fromS: fromS ?? this.fromS,
    toS: limparTo ? null : (toS ?? this.toS),
    watermarkId: limparMarca ? null : (watermarkId ?? this.watermarkId),
    watermarkScale: watermarkScale ?? this.watermarkScale,
    watermarkX: watermarkX ?? this.watermarkX,
    watermarkY: watermarkY ?? this.watermarkY,
    watermarkOpacity: watermarkOpacity ?? this.watermarkOpacity,
  );

  Map<String, dynamic> toJson() => {
    'width': width,
    'height': height,
    'fps': fps,
    'crf': crf,
    'fit': fit,
    'from_s': fromS,
    if (toS != null) 'to_s': toS,
    if (watermarkId != null) 'watermark_id': watermarkId,
    'watermark_scale': watermarkScale,
    'watermark_x': watermarkX,
    'watermark_y': watermarkY,
    'watermark_opacity': watermarkOpacity,
  };
}

/// Um vídeo montado à mão: as camadas e os blocos que o formam.
class Montage {
  const Montage({
    this.title = '',
    this.trackId,
    this.musicStartS = 0,
    this.layers = const [],
    this.beatOffsetS = 0,
    this.beatMultiplier = 1,
    this.beatBar = 1,
    this.musicVolume = 1,
    this.gameVolume = 0,
    this.export = const ExportSpec(),
  });

  final String title;

  /// **Formato antigo**: a faixa contínua que tocava por baixo de tudo e não se
  /// cortava. Continua sendo lida — vira um bloco na camada de som ao abrir —,
  /// e nunca mais é escrita.
  final String? trackId;

  /// De que ponto da música a faixa contínua entrava.
  final double musicStartS;

  /// As camadas, da de baixo para a de cima.
  final List<Layer> layers;

  /// Todos os clipes, de todas as camadas. Serve a quem só quer saber o que o
  /// vídeo mostra — o monitor, a duração, o resumo.
  List<TimelineClip> get clips => [for (final l in layers) ...l.clips];

  /// Correções à grade de batidas. Não mudam o vídeo — o corte guarda
  /// instantes absolutos —, mas mudam onde o ímã gruda, então valem ser
  /// lembradas entre uma sessão e outra.
  final double beatOffsetS;
  final double beatMultiplier;
  final int beatBar;

  /// Volume da música e do som do jogo. Com [gameVolume] em 0 a música
  /// substitui o áudio; acima disso os dois se misturam. Sem bloco de música
  /// nenhum, o áudio dos cortes vale por si.
  final double musicVolume;
  final double gameVolume;

  /// Como o vídeo final é escrito. Não muda a montagem — muda a janela.
  final ExportSpec export;

  /// Reconstrói a montagem que ficou salva no servidor.
  ///
  /// É o que faz um F5 no meio do trabalho não custar a montagem inteira.
  /// Lê os dois formatos.
  ///
  /// Um rascunho salvo antes das camadas existirem chega com `cuts`, e vira uma
  /// camada só — a mesma conversão que o servidor faz na leitura dele.
  factory Montage.fromJson(Map<String, dynamic> j) {
    final camadas = (j['layers'] as List?) ?? const [];
    final velhos = (j['cuts'] as List?) ?? const [];
    return Montage(
      title: j['title'] as String? ?? '',
      trackId: j['track_id'] as String?,
      musicStartS: (j['music_start_s'] as num?)?.toDouble() ?? 0,
      layers: camadas.isNotEmpty
          ? camadas
                .map((e) => Layer.fromJson(e as Map<String, dynamic>))
                .toList()
          : [
              if (velhos.isNotEmpty)
                Layer(
                  clips: velhos
                      .map(
                        (e) => TimelineClip.fromJson(e as Map<String, dynamic>),
                      )
                      .toList(),
                ),
            ],
      beatOffsetS: (j['beat_offset_s'] as num?)?.toDouble() ?? 0,
      beatMultiplier: (j['beat_multiplier'] as num?)?.toDouble() ?? 1,
      beatBar: (j['beat_bar'] as num?)?.toInt() ?? 1,
      musicVolume: (j['music_volume'] as num?)?.toDouble() ?? 1,
      gameVolume: (j['game_volume'] as num?)?.toDouble() ?? 0,
      export: ExportSpec.fromJson(
        (j['export'] as Map?)?.cast<String, dynamic>() ?? const {},
      ),
    );
  }

  bool get isEmpty => clips.isEmpty;

  Map<String, dynamic> toJson() => {
    'title': title,
    // `track_id` e `music_start_s` não vão: quem os tinha já os converteu em
    // bloco ao abrir, e mandá-los de volta criaria uma segunda música
    'layers': [for (final l in layers) l.toJson()],
    'beat_offset_s': beatOffsetS,
    'beat_multiplier': beatMultiplier,
    'beat_bar': beatBar,
    'music_volume': musicVolume,
    'game_volume': gameVolume,
    'export': export.toJson(),
  };
}

/// Uma montagem nomeada de uma partida.
///
/// Até a Fase 8 havia uma só, e era preciso escolher entre o corte de 30 s para
/// o Shorts e a montagem longa. São trabalhos diferentes sobre o mesmo
/// material, e agora cada um tem o seu nome.
class SavedMontage {
  const SavedMontage({
    required this.id,
    required this.name,
    required this.montage,
    required this.nClips,
    required this.durationS,
    required this.hasMusic,
    required this.nVersions,
    required this.updatedAt,
  });

  factory SavedMontage.fromJson(Map<String, dynamic> j) => SavedMontage(
    id: j['id'] as String,
    name: j['name'] as String? ?? '',
    montage: Montage.fromJson(
      (j['data'] as Map?)?.cast<String, dynamic>() ?? const {},
    ),
    nClips: (j['n_clips'] as num?)?.toInt() ?? 0,
    durationS: (j['duration_s'] as num?)?.toDouble() ?? 0,
    hasMusic: j['has_music'] as bool? ?? false,
    nVersions: (j['n_versions'] as num?)?.toInt() ?? 0,
    updatedAt: DateTime.parse(j['updated_at'] as String),
  );

  final String id;
  final String name;

  /// O conteúdo. Vem vazio nas respostas que só trazem o resumo.
  final Montage montage;

  final int nClips;
  final double durationS;
  final bool hasMusic;
  final int nVersions;
  final DateTime updatedAt;

  bool get isEmpty => nClips == 0;
}

/// Uma foto de uma montagem, guardada para se poder voltar a ela.
///
/// Não é o desfazer — esse vive na tela e morre com a aba. São marcos: "o que
/// eu gerei" e "estava bom assim".
class MontageVersion {
  const MontageVersion({
    required this.id,
    required this.label,
    required this.nClips,
    required this.durationS,
    required this.createdAt,
  });

  factory MontageVersion.fromJson(Map<String, dynamic> j) => MontageVersion(
    id: j['id'] as String,
    label: j['label'] as String? ?? '',
    nClips: (j['n_clips'] as num?)?.toInt() ?? 0,
    durationS: (j['duration_s'] as num?)?.toDouble() ?? 0,
    createdAt: DateTime.parse(j['created_at'] as String),
  );

  final String id;
  final String label;
  final int nClips;
  final double durationS;
  final DateTime createdAt;
}

/// Como montar um vídeo a partir do que aconteceu numa partida.
///
/// Uma predefinição não guarda cortes — guarda o **jeito** de cortar. "Dois
/// segundos por eliminação, encaixado na batida, com zoom" vale para qualquer
/// partida, enquanto uma lista de cortes só vale para aquela.
class Receita {
  const Receita({
    this.kinds = const ['kill', 'sleep', 'stun'],
    this.leadS = 1.0,
    this.durationS = 2.0,
    this.beatsPerCut = 0,
    this.gapS = 0,
    this.maxCuts = 0,
    this.zoom = false,
    this.fadeS = 0,
    this.speed = 1.0,
    this.counter = false,
    this.streaks = false,
    this.musicVolume = 1,
    this.gameVolume = 0,
    this.export = const ExportSpec(),
  });

  factory Receita.fromJson(Map<String, dynamic> j) => Receita(
    kinds: [
      for (final k in (j['kinds'] as List?) ?? const ['kill', 'sleep', 'stun'])
        k as String,
    ],
    leadS: (j['lead_s'] as num?)?.toDouble() ?? 1.0,
    durationS: (j['duration_s'] as num?)?.toDouble() ?? 2.0,
    beatsPerCut: (j['beats_per_cut'] as num?)?.toDouble() ?? 0,
    gapS: (j['gap_s'] as num?)?.toDouble() ?? 0,
    maxCuts: (j['max_cuts'] as num?)?.toInt() ?? 0,
    zoom: j['zoom'] as bool? ?? false,
    fadeS: (j['fade_s'] as num?)?.toDouble() ?? 0,
    speed: (j['speed'] as num?)?.toDouble() ?? 1.0,
    counter: j['counter'] as bool? ?? false,
    streaks: j['streaks'] as bool? ?? false,
    musicVolume: (j['music_volume'] as num?)?.toDouble() ?? 1,
    gameVolume: (j['game_volume'] as num?)?.toDouble() ?? 0,
    export: ExportSpec.fromJson(
      (j['export'] as Map?)?.cast<String, dynamic>() ?? const {},
    ),
  );

  /// Que eventos viram corte.
  final List<String> kinds;

  /// Quanto tempo antes do evento o corte começa — o momento precisa de
  /// embalo, senão a eliminação aparece no primeiro quadro.
  final double leadS;

  /// Tamanho de cada corte. Ignorado quando [beatsPerCut] manda.
  final double durationS;

  /// Com trilha, cada corte dura N batidas em vez de [durationS].
  final double beatsPerCut;

  final double gapS;

  /// `0` = todos os momentos que houver.
  final int maxCuts;

  final bool zoom;
  final double fadeS;
  final double speed;

  /// Texto que o sistema escreve sozinho.
  final bool counter;
  final bool streaks;

  final double musicVolume;
  final double gameVolume;
  final ExportSpec export;

  Receita copyWith({
    List<String>? kinds,
    double? leadS,
    double? durationS,
    double? beatsPerCut,
    double? gapS,
    int? maxCuts,
    bool? zoom,
    double? fadeS,
    double? speed,
    bool? counter,
    bool? streaks,
    double? musicVolume,
    double? gameVolume,
    ExportSpec? export,
  }) => Receita(
    kinds: kinds ?? this.kinds,
    leadS: leadS ?? this.leadS,
    durationS: durationS ?? this.durationS,
    beatsPerCut: beatsPerCut ?? this.beatsPerCut,
    gapS: gapS ?? this.gapS,
    maxCuts: maxCuts ?? this.maxCuts,
    zoom: zoom ?? this.zoom,
    fadeS: fadeS ?? this.fadeS,
    speed: speed ?? this.speed,
    counter: counter ?? this.counter,
    streaks: streaks ?? this.streaks,
    musicVolume: musicVolume ?? this.musicVolume,
    gameVolume: gameVolume ?? this.gameVolume,
    export: export ?? this.export,
  );

  Map<String, dynamic> toJson() => {
    'kinds': kinds,
    'lead_s': leadS,
    'duration_s': durationS,
    'beats_per_cut': beatsPerCut,
    'gap_s': gapS,
    'max_cuts': maxCuts,
    'zoom': zoom,
    'fade_s': fadeS,
    'speed': speed,
    'counter': counter,
    'streaks': streaks,
    'music_volume': musicVolume,
    'game_volume': gameVolume,
    'export': export.toJson(),
  };
}

/// Uma predefinição salva: a receita com um nome.
class Preset {
  const Preset({required this.id, required this.name, required this.receita});

  factory Preset.fromJson(Map<String, dynamic> j) => Preset(
    id: j['id'] as String,
    name: j['name'] as String? ?? '',
    receita: Receita.fromJson(
      (j['data'] as Map?)?.cast<String, dynamic>() ?? const {},
    ),
  );

  final String id;
  final String name;
  final Receita receita;
}

class DetectionEvent {
  DetectionEvent({
    required this.kind,
    required this.t,
    required this.confidence,
    this.meta = const {},
  });

  factory DetectionEvent.fromJson(Map<String, dynamic> j) => DetectionEvent(
    kind: j['kind'] as String,
    t: (j['t'] as num).toDouble(),
    confidence: (j['confidence'] as num?)?.toDouble() ?? 1.0,
    meta: (j['meta'] as Map?)?.cast<String, dynamic>() ?? const {},
  );

  final String kind;
  final double t;
  final double confidence;

  /// O que o detector viu além do instante. Varia por tipo: um `ability_kill`
  /// traz `ability` (`"orisa/energy_javelin"`), uma `ult_negated` traz de quem
  /// era a ultimate e quanto demorou.
  final Map<String, dynamic> meta;

  /// A habilidade que matou, quando o evento é de habilidade.
  ///
  /// Vem no formato do arquivo do ícone — `heroi/habilidade` — porque é dali
  /// que o detector a reconhece.
  String? get ability {
    final a = meta['ability'];
    return a is String && a.isNotEmpty ? a : null;
  }
}

class DetectorReport {
  DetectorReport({
    required this.detector,
    required this.ok,
    required this.nEvents,
    this.error,
  });

  factory DetectorReport.fromJson(Map<String, dynamic> j) => DetectorReport(
    detector: j['detector'] as String,
    ok: j['ok'] as bool? ?? true,
    nEvents: j['n_events'] as int? ?? 0,
    error: j['error'] as String?,
  );

  final String detector;
  final bool ok;
  final int nEvents;
  final String? error;
}

class Clip {
  Clip({
    required this.id,
    required this.kind,
    required this.title,
    required this.startS,
    required this.endS,
    required this.score,
    this.renderId,
    this.videoUrl,
    this.thumbUrl,
    this.segmentsZipUrl,
    this.meta = const {},
  });

  factory Clip.fromJson(Map<String, dynamic> j) => Clip(
    id: j['id'] as String,
    kind: j['kind'] as String,
    title: j['title'] as String? ?? '',
    startS: (j['start_s'] as num).toDouble(),
    endS: (j['end_s'] as num).toDouble(),
    score: (j['score'] as num).toDouble(),
    renderId: j['render_id'] as String?,
    videoUrl: j['video_url'] == null
        ? null
        : absoluteUrl('$kApiBase${j['video_url']}'),
    thumbUrl: j['thumb_url'] == null
        ? null
        : absoluteUrl('$kApiBase${j['thumb_url']}'),
    segmentsZipUrl: j['segments_zip_url'] == null
        ? null
        : absoluteUrl('$kApiBase${j['segments_zip_url']}'),
    meta: (j['meta'] as Map?)?.cast<String, dynamic>() ?? const {},
  );

  final String id;
  final String kind;
  final String title;
  final double startS;
  final double endS;
  final double score;
  final String? renderId;

  /// Nulo quando a montagem falhou: sobraram só os cortes.
  final String? videoUrl;
  final String? thumbUrl;

  /// Zip com os cortes individuais da montagem, quando existem.
  final String? segmentsZipUrl;
  final Map<String, dynamic> meta;

  double get durationS =>
      (meta['duration_s'] as num?)?.toDouble() ?? (endS - startS);

  bool get isBeatSynced => meta['beat_synced'] == true;
  int get segments => (meta['segments'] as int?) ?? 1;
  bool get isLooped => meta['looped'] == true;
  num? get bpm => meta['bpm'] as num?;
  String? get musicName => meta['music_name'] as String?;

  /// Sem trilha escolhida, o vídeo ficou com o som da partida.
  bool get keepsOriginalAudio => meta['original_audio'] == true;

  /// A montagem falhou mas os cortes ficaram disponíveis.
  bool get onlyCuts => videoUrl == null && segmentsZipUrl != null;
  String? get renderError => meta['render_error'] as String?;
}

/// Um pedido de geração: as montagens mandadas para o servidor de uma vez.
/// Uma partida acumula quantos pedidos o usuário quiser.
class Render {
  Render({
    required this.id,
    required this.status,
    required this.stage,
    required this.progress,
    required this.createdAt,
    this.error,
    this.clips = const [],
  });

  factory Render.fromJson(Map<String, dynamic> j) => Render(
    id: j['id'] as String,
    status: j['status'] as String,
    stage: j['stage'] as String? ?? '',
    progress: (j['progress'] as num?)?.toDouble() ?? 0,
    createdAt: DateTime.parse(j['created_at'] as String),
    error: j['error'] as String?,
    clips: ((j['clips'] as List?) ?? [])
        .map((e) => Clip.fromJson(e as Map<String, dynamic>))
        .toList(),
  );

  final String id;
  final String status;
  final String stage;
  final double progress;
  final DateTime createdAt;
  final String? error;
  final List<Clip> clips;

  /// Nomes das músicas usadas neste pedido, sem repetir.
  ///
  /// Saem dos **clipes gerados**, e não do pedido: a trilha de uma montagem é
  /// um bloco na régua dela, e é o editor que sabe qual acabou tocando. Já
  /// vinha das `selections` do pedido, quando a música era escolhida à parte
  /// do vídeo — com aquele campo removido, ler dali dava sempre vazio, e todo
  /// vídeo aparecia na lista como se tivesse saído com o áudio da partida.
  List<String> get musicNames => {
    for (final c in clips)
      if (c.meta['music_name'] case final String nome) nome,
  }.toList();

  bool get isActive => status == 'pending' || status == 'rendering';
  bool get isFailed => status == 'failed';
}

class Job {
  Job({
    required this.id,
    required this.status,
    required this.stage,
    required this.progress,
    required this.videoName,
    required this.durationS,
    required this.createdAt,
    required this.nClips,
    this.fps = 0,
    this.width = 0,
    this.height = 0,
    this.videoUrl,
    this.proxyUrl,
    this.waveform = const [],
    this.nRenders = 0,
    this.zipUrl,
    this.hasCuts = false,
    this.hasActiveRender = false,
    this.error,
    this.events = const [],
    this.renders = const [],
    this.clips = const [],
    this.detectors = const [],
    this.tracks = const [],
    this.media = const [],
    this.draft,
    this.montages = const [],
  });

  factory Job.fromJson(Map<String, dynamic> j) => Job(
    id: j['id'] as String,
    status: j['status'] as String,
    stage: j['stage'] as String? ?? '',
    progress: (j['progress'] as num?)?.toDouble() ?? 0,
    videoName: j['video_name'] as String? ?? '',
    durationS: (j['duration_s'] as num?)?.toDouble() ?? 0,
    fps: (j['fps'] as num?)?.toDouble() ?? 0,
    width: (j['width'] as num?)?.toInt() ?? 0,
    height: (j['height'] as num?)?.toInt() ?? 0,
    createdAt: DateTime.parse(j['created_at'] as String),
    nClips: j['n_clips'] as int? ?? 0,
    videoUrl: j['video_url'] == null
        ? null
        : absoluteUrl('$kApiBase${j['video_url']}'),
    proxyUrl: j['proxy_url'] == null
        ? null
        : absoluteUrl('$kApiBase${j['proxy_url']}'),
    waveform: ((j['waveform'] as List?) ?? [])
        .map((e) => (e as num).toDouble())
        .toList(),
    nRenders: j['n_renders'] as int? ?? 0,
    zipUrl: j['zip_url'] == null
        ? null
        : absoluteUrl('$kApiBase${j['zip_url']}'),
    hasCuts: j['has_cuts'] as bool? ?? false,
    hasActiveRender: j['has_active_render'] as bool? ?? false,
    error: j['error'] as String?,
    events: ((j['events'] as List?) ?? [])
        .map((e) => DetectionEvent.fromJson(e as Map<String, dynamic>))
        .toList(),
    renders: ((j['renders'] as List?) ?? [])
        .map((e) => Render.fromJson(e as Map<String, dynamic>))
        .toList(),
    clips: ((j['clips'] as List?) ?? [])
        .map((e) => Clip.fromJson(e as Map<String, dynamic>))
        .toList(),
    detectors: ((j['detectors'] as List?) ?? [])
        .map((e) => DetectorReport.fromJson(e as Map<String, dynamic>))
        .toList(),
    tracks: ((j['tracks'] as List?) ?? [])
        .map((e) => Track.fromJson(e as Map<String, dynamic>))
        .toList(),
    media: ((j['media'] as List?) ?? [])
        .map((e) => Media.fromJson(e as Map<String, dynamic>))
        .toList(),
    montages: [
      for (final m in (j['montages'] as List?) ?? const [])
        SavedMontage.fromJson(m as Map<String, dynamic>),
    ],
    draft: (j['draft'] as Map?)?.isEmpty ?? true
        ? null
        : Montage.fromJson((j['draft'] as Map).cast<String, dynamic>()),
  );

  final String id;
  final String status;
  final String stage;
  final double progress;
  final String videoName;
  final double durationS;

  /// Quadros por segundo da gravação. É o que dá sentido ao passo de um quadro
  /// no editor — 33 ms num vídeo a 30 fps, 16 ms num a 60.
  final double fps;

  /// Tamanho da gravação. É o padrão de exportação — e o que deixa o editor
  /// dizer se a saída pedida corta o quadro ou deixa barras.
  final int width;
  final int height;

  final DateTime createdAt;
  final int nClips;

  /// A gravação original, servida com `Range`. É de onde saem os cortes.
  final String? videoUrl;

  /// A cópia reduzida da gravação. É o que o monitor abre: buscar dentro do
  /// arquivo original dezenas de vezes por segundo chegou a derrubar o
  /// elemento de vídeo do navegador.
  ///
  /// Nulo nas partidas analisadas antes de o proxy existir — aí o monitor cai
  /// na gravação original, como fazia antes.
  final String? proxyUrl;

  /// Forma de onda do áudio da partida: é nela que se vê o tiro e a explosão,
  /// para casar o corte com o som do jogo.
  final List<double> waveform;

  /// O que o monitor deve abrir.
  String? get monitorUrl => proxyUrl ?? videoUrl;
  final int nRenders;

  /// Pacote da partida inteira: vídeos finais e cortes avulsos.
  final String? zipUrl;
  final bool hasCuts;

  /// Algum pedido de geração ainda em andamento. Vem da API porque a listagem
  /// não carrega os pedidos inteiros.
  final bool hasActiveRender;
  final String? error;
  final List<DetectionEvent> events;
  final List<Render> renders;
  final List<Clip> clips;
  final List<DetectorReport> detectors;

  /// Músicas já enviadas para esta partida, prontas para montar em cima.
  ///
  /// São os itens de [media] do tipo áudio — a lista existe à parte porque é
  /// ela que o seletor de trilha usa.
  final List<Track> tracks;

  /// A biblioteca inteira: música, clipe e imagem que o usuário trouxe.
  final List<Media> media;

  /// A montagem em andamento, se houver. É o que a tela de montagem carrega ao
  /// abrir — recarregar a página não custa mais o trabalho todo.
  final Montage? draft;

  /// As montagens desta partida. Uma partida rende mais de um vídeo: o corte
  /// vertical para o Shorts e a montagem longa são trabalhos diferentes sobre
  /// o mesmo material.
  final List<SavedMontage> montages;

  /// A análise ainda está rodando.
  bool get isAnalyzing => status != 'ready' && status != 'failed';

  /// A análise terminou: dá para escolher o que gerar.
  bool get isReady => status == 'ready';
  bool get isFailed => status == 'failed';

  /// Vale continuar consultando o servidor.
  bool get isActive =>
      isAnalyzing || hasActiveRender || renders.any((r) => r.isActive);

  /// Quanto ainda falta para a análise terminar, ou nulo quando não dá para
  /// dizer com honestidade.
  ///
  /// A conta é a mais simples que existe — o que já andou, na velocidade com
  /// que andou — e ela só se sustenta porque a barra do servidor passou a ser
  /// proporcional ao *tempo* de cada fase, e não ao número de fases. Enquanto
  /// o recorte, que é três quartos do trabalho, ocupava um décimo da barra,
  /// qualquer estimativa daqui mentiria por minutos.
  ///
  /// Nulo abaixo de 3%: com pouco andado, o erro da estimativa é maior que ela.
  Duration? get restante {
    if (!isAnalyzing || progress < 0.03) return null;
    final decorrido = DateTime.now().toUtc().difference(createdAt.toUtc());
    if (decorrido <= Duration.zero) return null;
    final total = decorrido.inMilliseconds / progress;
    final falta = total - decorrido.inMilliseconds;
    if (falta <= 0 || falta > const Duration(hours: 3).inMilliseconds) {
      return null;
    }
    return Duration(milliseconds: falta.round());
  }
}

/// "~6 min", "~40 s" — grosso de propósito. Uma estimativa ao segundo daria
/// uma precisão que ela não tem, e ficaria pulando a cada recarga.
String? formatRestante(Duration? d) {
  if (d == null) return null;
  final s = d.inSeconds;
  if (s < 45) return 'menos de 1 min';
  final min = (s / 60).round();
  if (min < 60) return '~$min min';
  final h = d.inHours;
  return '~${h}h${(d.inMinutes % 60).toString().padLeft(2, '0')}';
}

// ─────────────────────────────── cliente ────────────────────────────────────

class ApiClient {
  ApiClient({this.baseUrl = kApiBase});

  final String baseUrl;

  Future<List<Job>> listJobs() async {
    final r = await http.get(Uri.parse('$baseUrl/api/jobs'));
    _check(r);
    final body = jsonDecode(r.body) as Map<String, dynamic>;
    return (body['jobs'] as List)
        .map((e) => Job.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<Job> getJob(String id) async {
    final r = await http.get(Uri.parse('$baseUrl/api/jobs/$id'));
    _check(r);
    return Job.fromJson(jsonDecode(r.body) as Map<String, dynamic>);
  }

  Future<void> deleteJob(String id) async {
    final r = await http.delete(Uri.parse('$baseUrl/api/jobs/$id'));
    if (r.statusCode != 204) _check(r);
  }

  Future<Render> getRender(String id) async {
    final r = await http.get(Uri.parse('$baseUrl/api/renders/$id'));
    _check(r);
    return Render.fromJson(jsonDecode(r.body) as Map<String, dynamic>);
  }

  Future<void> deleteRender(String id) async {
    final r = await http.delete(Uri.parse('$baseUrl/api/renders/$id'));
    if (r.statusCode != 204) _check(r);
  }

  /// Envia a gravação. `onProgress` recebe 0..1 conforme os bytes saem — em
  /// vídeo de partida isso importa: o arquivo costuma ter centenas de
  /// megabytes.
  ///
  /// O arquivo é lido em streaming, nunca inteiro na memória: uma gravação de
  /// partida não caberia na RAM de um celular.
  Future<String> createJob({
    required PlatformFile video,
    JobParams params = const JobParams(),
    void Function(double sent)? onProgress,
  }) async {
    final total = await video.length();
    final r = await uploadFile(
      url: Uri.parse('$baseUrl/api/jobs'),
      field: 'video',
      file: video,
      length: total,
      // o tamanho vai junto para o servidor conferir o que chegou: envio
      // truncado nao se parece com erro nenhum do lado de la
      fields: {'params': jsonEncode(params.toJson()), 'size': '$total'},
      onProgress: onProgress,
    );
    _check(r);
    return (jsonDecode(r.body) as Map<String, dynamic>)['id'] as String;
  }

  /// Envia uma música para a partida e manda o sistema ouvi-la.
  ///
  /// Volta na hora, com a música ainda `pending` — a análise (duração, BPM,
  /// batidas e forma de onda) roda no servidor. Use [waitForTrack] para
  /// esperar por ela.
  Future<Track> uploadTrack({
    required String jobId,
    required PlatformFile audio,
    void Function(double sent)? onProgress,
  }) async {
    final total = await audio.length();
    final r = await uploadFile(
      url: Uri.parse('$baseUrl/api/jobs/$jobId/tracks'),
      field: 'audio',
      file: audio,
      length: total,
      fields: {'size': '$total'},
      onProgress: onProgress,
    );
    _check(r);
    final id = (jsonDecode(r.body) as Map<String, dynamic>)['id'] as String;
    return getTrack(id);
  }

  /// Guarda a montagem em andamento.
  ///
  /// Chamada sozinha pelo editor enquanto se edita, com folga entre uma e
  /// outra: o que importa é não perder o trabalho, não registrar cada pixel.
  Future<void> saveDraft(String jobId, Montage draft) async {
    final r = await http.put(
      Uri.parse('$baseUrl/api/jobs/$jobId/draft'),
      headers: const {'content-type': 'application/json'},
      body: jsonEncode(draft.toJson()),
    );
    _check(r);
  }

  Future<void> deleteDraft(String jobId) async {
    final r = await http.delete(Uri.parse('$baseUrl/api/jobs/$jobId/draft'));
    if (r.statusCode != 204) _check(r);
  }

  // ── montagens nomeadas ─────────────────────────────────────────────────────

  Future<List<SavedMontage>> listMontages(String jobId) async {
    final r = await http.get(Uri.parse('$baseUrl/api/jobs/$jobId/montages'));
    _check(r);
    final j = jsonDecode(r.body) as Map<String, dynamic>;
    return [
      for (final m in (j['items'] as List))
        SavedMontage.fromJson(m as Map<String, dynamic>),
    ];
  }

  Future<SavedMontage> createMontage(
    String jobId, {
    String name = '',
    Montage? montage,
  }) async {
    final r = await http.post(
      Uri.parse('$baseUrl/api/jobs/$jobId/montages'),
      headers: const {'content-type': 'application/json'},
      body: jsonEncode({
        if (name.isNotEmpty) 'name': name,
        if (montage != null) 'data': montage.toJson(),
      }),
    );
    _check(r);
    return SavedMontage.fromJson(jsonDecode(r.body) as Map<String, dynamic>);
  }

  /// Guarda a montagem. Chamada sozinha pelo editor enquanto se edita, com
  /// folga entre uma e outra: o que importa é não perder o trabalho, não
  /// registrar cada pixel de um arrasto.
  Future<void> saveMontage(
    String jobId,
    String montageId, {
    Montage? montage,
    String? name,
  }) async {
    final r = await http.put(
      Uri.parse('$baseUrl/api/jobs/$jobId/montages/$montageId'),
      headers: const {'content-type': 'application/json'},
      body: jsonEncode({
        if (montage != null) 'data': montage.toJson(),
        'name': ?name,
      }),
    );
    _check(r);
  }

  Future<SavedMontage> duplicateMontage(String jobId, String montageId) async {
    final r = await http.post(
      Uri.parse('$baseUrl/api/jobs/$jobId/montages/$montageId/duplicate'),
    );
    _check(r);
    return SavedMontage.fromJson(jsonDecode(r.body) as Map<String, dynamic>);
  }

  Future<void> deleteMontage(String jobId, String montageId) async {
    final r = await http.delete(
      Uri.parse('$baseUrl/api/jobs/$jobId/montages/$montageId'),
    );
    if (r.statusCode != 204) _check(r);
  }

  // ── histórico ──────────────────────────────────────────────────────────────

  Future<List<MontageVersion>> listVersions(
    String jobId,
    String montageId,
  ) async {
    final r = await http.get(
      Uri.parse('$baseUrl/api/jobs/$jobId/montages/$montageId/versions'),
    );
    _check(r);
    final j = jsonDecode(r.body) as Map<String, dynamic>;
    return [
      for (final v in (j['items'] as List))
        MontageVersion.fromJson(v as Map<String, dynamic>),
    ];
  }

  /// Marca a montagem como ela está.
  ///
  /// Devolve `false` quando não havia nada de novo para marcar — o servidor
  /// recusa fotos idênticas à última, e isso não é erro: gerar o mesmo vídeo
  /// duas vezes seguidas não produziu versão nenhuma.
  Future<bool> createVersion(
    String jobId,
    String montageId, {
    String label = '',
  }) async {
    final r = await http.post(
      Uri.parse('$baseUrl/api/jobs/$jobId/montages/$montageId/versions'),
      headers: const {'content-type': 'application/json'},
      body: jsonEncode({'label': label}),
    );
    if (r.statusCode == 409) return false;
    _check(r);
    return true;
  }

  Future<SavedMontage> restoreVersion(
    String jobId,
    String montageId,
    String versionId,
  ) async {
    final r = await http.post(
      Uri.parse(
        '$baseUrl/api/jobs/$jobId/montages/$montageId/versions/$versionId/restore',
      ),
    );
    _check(r);
    return SavedMontage.fromJson(jsonDecode(r.body) as Map<String, dynamic>);
  }

  // ── predefinições ──────────────────────────────────────────────────────────

  Future<List<Preset>> listPresets() async {
    final r = await http.get(Uri.parse('$baseUrl/api/presets'));
    _check(r);
    final j = jsonDecode(r.body) as Map<String, dynamic>;
    return [
      for (final p in (j['items'] as List))
        Preset.fromJson(p as Map<String, dynamic>),
    ];
  }

  Future<Preset> createPreset(String name, Receita receita) async {
    final r = await http.post(
      Uri.parse('$baseUrl/api/presets'),
      headers: const {'content-type': 'application/json'},
      body: jsonEncode({'name': name, 'data': receita.toJson()}),
    );
    _check(r);
    return Preset.fromJson(jsonDecode(r.body) as Map<String, dynamic>);
  }

  Future<void> deletePreset(String presetId) async {
    final r = await http.delete(Uri.parse('$baseUrl/api/presets/$presetId'));
    if (r.statusCode != 204) _check(r);
  }

  /// Traz um arquivo para a biblioteca da partida.
  ///
  /// Volta na hora, ainda `pending`: a análise (dimensões, miniatura, proxy;
  /// batidas quando for áudio) roda no servidor.
  Future<Media> uploadMedia({
    required String jobId,
    required PlatformFile file,
    void Function(double sent)? onProgress,
  }) async {
    final total = await file.length();
    final r = await uploadFile(
      url: Uri.parse('$baseUrl/api/jobs/$jobId/media'),
      field: 'file',
      file: file,
      length: total,
      fields: {'size': '$total'},
      onProgress: onProgress,
    );
    _check(r);
    final id = (jsonDecode(r.body) as Map<String, dynamic>)['id'] as String;
    return getMedia(id);
  }

  Future<Media> getMedia(String id) async {
    final r = await http.get(Uri.parse('$baseUrl/api/media/$id'));
    _check(r);
    return Media.fromJson(jsonDecode(r.body) as Map<String, dynamic>);
  }

  Future<void> deleteMedia(String id) async {
    final r = await http.delete(Uri.parse('$baseUrl/api/media/$id'));
    if (r.statusCode != 204) _check(r);
  }

  /// Espera o item ficar pronto, consultando de tempos em tempos.
  Future<Media> waitForMedia(
    String id, {
    Duration timeout = const Duration(minutes: 3),
    Duration every = const Duration(seconds: 1),
  }) async {
    final limite = DateTime.now().add(timeout);
    var item = await getMedia(id);
    while (item.isPending && DateTime.now().isBefore(limite)) {
      await Future<void>.delayed(every);
      item = await getMedia(id);
    }
    return item;
  }

  /// Manda extrair as miniaturas que faltam nesta partida.
  ///
  /// Jobs novos já saem com elas; isto cobre os antigos e as que falharam. O
  /// serviço pula o que já está no lugar, então chamar à toa é barato.
  Future<void> requestFrames(String jobId) async {
    final r = await http.post(Uri.parse('$baseUrl/api/jobs/$jobId/frames'));
    if (r.statusCode != 202) _check(r);
  }

  Future<Track> getTrack(String id) async {
    final r = await http.get(Uri.parse('$baseUrl/api/tracks/$id'));
    _check(r);
    return Track.fromJson(jsonDecode(r.body) as Map<String, dynamic>);
  }

  Future<void> deleteTrack(String id) async {
    final r = await http.delete(Uri.parse('$baseUrl/api/tracks/$id'));
    if (r.statusCode != 204) _check(r);
  }

  /// Espera a música ficar pronta, consultando de tempos em tempos.
  ///
  /// Uma música de 3 minutos leva alguns segundos para ser ouvida; a tela de
  /// montagem não tem o que desenhar antes disso. Desiste depois de [timeout]
  /// devolvendo a música como está — quem chamou decide o que dizer ao usuário.
  Future<Track> waitForTrack(
    String id, {
    Duration timeout = const Duration(minutes: 3),
    Duration every = const Duration(seconds: 1),
  }) async {
    final limite = DateTime.now().add(timeout);
    var track = await getTrack(id);
    while (track.isPending && DateTime.now().isBefore(limite)) {
      await Future<void>.delayed(every);
      track = await getTrack(id);
    }
    return track;
  }

  /// Pede a geração das montagens.
  ///
  /// Elas já trazem os blocos posicionados e apontam para músicas que **já
  /// subiram** pela biblioteca, então o pedido não leva arquivo nenhum.
  ///
  /// Já houve um segundo caminho aqui: as propostas escolhidas, cada uma com a
  /// sua música num campo `music_<proposal_id>`. Não há mais propostas.
  Future<String> createRender({
    required String jobId,
    required List<Montage> montages,
  }) async {
    final r = await http.post(
      Uri.parse('$baseUrl/api/jobs/$jobId/renders'),
      headers: {'content-type': 'application/x-www-form-urlencoded'},
      body: {
        'timelines': jsonEncode([for (final m in montages) m.toJson()]),
      },
    );
    _check(r);
    return (jsonDecode(r.body) as Map<String, dynamic>)['id'] as String;
  }

  void _check(http.Response r) {
    if (r.statusCode >= 400) {
      String detail = r.body;
      try {
        final decoded = jsonDecode(r.body);
        if (decoded is Map && decoded['detail'] != null) {
          detail = decoded['detail'].toString();
        }
      } catch (_) {}
      throw ApiException(detail, r.statusCode);
    }
  }
}
