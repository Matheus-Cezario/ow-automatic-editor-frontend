import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:http/http.dart' as http;

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

class ApiException implements Exception {
  ApiException(this.message, [this.statusCode]);
  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

// ─────────────────────────────── modelos ────────────────────────────────────

/// Parâmetros da **análise**: o que conta como momento importante.
///
/// Valem para a partida inteira e são decididos no upload. Nada de música aqui
/// — ela só aparece na hora de gerar cada vídeo, em [ClipOptions].
class JobParams {
  const JobParams({
    this.multikillMin = 3,
    this.multikillWindowS = 10,
    this.soloWipeMin = 4,
    this.escapeMinEvents = 2,
    this.makeBeatMontage = true,
  });

  final int multikillMin;
  final double multikillWindowS;
  final int soloWipeMin;
  final int escapeMinEvents;
  final bool makeBeatMontage;

  Map<String, dynamic> toJson() => {
        'multikill_min': multikillMin,
        'multikill_window_s': multikillWindowS,
        'solo_wipe_min': soloWipeMin,
        'escape_min_events': escapeMinEvents,
        'make_beat_montage': makeBeatMontage,
      };

  JobParams copyWith({
    int? multikillMin,
    double? multikillWindowS,
    int? soloWipeMin,
    int? escapeMinEvents,
    bool? makeBeatMontage,
  }) =>
      JobParams(
        multikillMin: multikillMin ?? this.multikillMin,
        multikillWindowS: multikillWindowS ?? this.multikillWindowS,
        soloWipeMin: soloWipeMin ?? this.soloWipeMin,
        escapeMinEvents: escapeMinEvents ?? this.escapeMinEvents,
        makeBeatMontage: makeBeatMontage ?? this.makeBeatMontage,
      );
}

/// Escolhas de **um** vídeo, na hora de gerar. Cada vídeo tem as suas — é
/// assim que músicas diferentes convivem na mesma partida.
class ClipOptions {
  const ClipOptions({
    this.montageClipBeats = 2,
    this.musicStartS = 0,
    this.musicEndS,
    this.montageLoop = false,
  });

  final int montageClipBeats;

  /// Trecho da música usado na montagem. Com [musicEndS] definido, o vídeo tem
  /// exatamente essa duração quando [montageLoop] está ligado, e no máximo
  /// essa duração quando está desligado.
  final double musicStartS;
  final double? musicEndS;
  final bool montageLoop;

  bool get janelaValida => musicEndS == null || musicEndS! > musicStartS;

  Map<String, dynamic> toJson() => {
        'montage_clip_beats': montageClipBeats,
        'music_start_s': musicStartS,
        if (musicEndS != null) 'music_end_s': musicEndS,
        'montage_loop': montageLoop,
      };

  ClipOptions copyWith({
    int? montageClipBeats,
    double? musicStartS,
    double? musicEndS,
    bool clearMusicEnd = false,
    bool? montageLoop,
  }) =>
      ClipOptions(
        montageClipBeats: montageClipBeats ?? this.montageClipBeats,
        musicStartS: musicStartS ?? this.musicStartS,
        musicEndS: clearMusicEnd ? null : (musicEndS ?? this.musicEndS),
        montageLoop: montageLoop ?? this.montageLoop,
      );
}

/// Uma proposta escolhida, pronta para virar pedido de geração.
class Selection {
  const Selection({
    required this.proposalId,
    this.options = const ClipOptions(),
    this.music,
  });

  final String proposalId;
  final ClipOptions options;

  /// Sem música o vídeo sai com o **áudio original** da partida.
  final PlatformFile? music;

  Selection copyWith({
    ClipOptions? options,
    PlatformFile? music,
    bool clearMusic = false,
  }) =>
      Selection(
        proposalId: proposalId,
        options: options ?? this.options,
        music: clearMusic ? null : (music ?? this.music),
      );

  Map<String, dynamic> toJson() =>
      {'proposal_id': proposalId, 'options': options.toJson()};
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

/// Um bloco na linha do tempo: um pedaço da gravação posto num ponto do vídeo.
///
/// [startS] e [durationS] dizem *o que* entra (na gravação); [atS] diz *onde*
/// (no vídeo que vai sair). São independentes — o mesmo momento pode aparecer
/// duas vezes, em pontos diferentes da música e com durações diferentes.
class TimelineCut {
  const TimelineCut({
    required this.startS,
    required this.durationS,
    required this.atS,
    this.sourceT = 0,
    this.kind = '',
  });

  /// Instante do momento que originou o bloco. Não afeta o corte: serve para
  /// rotular e para recalcular o enquadramento quando a duração muda.
  final double sourceT;
  final double startS;
  final double durationS;
  final double atS;
  final String kind;

  /// Onde o corte termina na gravação.
  double get endS => startS + durationS;

  /// Onde o bloco termina no vídeo.
  double get untilS => atS + durationS;

  TimelineCut copyWith({
    double? sourceT,
    double? startS,
    double? durationS,
    double? atS,
    String? kind,
  }) =>
      TimelineCut(
        sourceT: sourceT ?? this.sourceT,
        startS: startS ?? this.startS,
        durationS: durationS ?? this.durationS,
        atS: atS ?? this.atS,
        kind: kind ?? this.kind,
      );

  Map<String, dynamic> toJson() => {
        'source_t': sourceT,
        'start_s': startS,
        'duration_s': durationS,
        'at_s': atS,
        'kind': kind,
      };
}

/// Um vídeo montado à mão: os blocos e a música por baixo deles.
class Montage {
  const Montage({
    this.title = '',
    this.trackId,
    this.musicStartS = 0,
    this.cuts = const [],
  });

  final String title;

  /// Sem música o vídeo sai com o **áudio original** dos cortes.
  final String? trackId;

  /// De que ponto da música o vídeo começa a tocar.
  final double musicStartS;
  final List<TimelineCut> cuts;

  Map<String, dynamic> toJson() => {
        'title': title,
        if (trackId != null) 'track_id': trackId,
        'music_start_s': musicStartS,
        'cuts': [for (final c in cuts) c.toJson()],
      };
}

class DetectionEvent {
  DetectionEvent({
    required this.kind,
    required this.t,
    required this.confidence,
  });

  factory DetectionEvent.fromJson(Map<String, dynamic> j) => DetectionEvent(
        kind: j['kind'] as String,
        t: (j['t'] as num).toDouble(),
        confidence: (j['confidence'] as num?)?.toDouble() ?? 1.0,
      );

  final String kind;
  final double t;
  final double confidence;
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

/// Um vídeo que o sistema **pode** gerar com os momentos encontrados.
///
/// Fica disponível para sempre: gerar um vídeo com um momento não o consome,
/// então a mesma proposta pode virar quantos vídeos o usuário quiser.
class Proposal {
  Proposal({
    required this.id,
    required this.kind,
    required this.title,
    required this.startS,
    required this.endS,
    required this.score,
    required this.nMoments,
    required this.acceptsMusic,
    this.moments = const [],
  });

  factory Proposal.fromJson(Map<String, dynamic> j) => Proposal(
        id: j['id'] as String,
        kind: j['kind'] as String,
        title: j['title'] as String? ?? '',
        startS: (j['start_s'] as num).toDouble(),
        endS: (j['end_s'] as num).toDouble(),
        score: (j['score'] as num).toDouble(),
        nMoments: j['n_moments'] as int? ?? 0,
        acceptsMusic: j['accepts_music'] as bool? ?? false,
        moments: ((j['moments'] as List?) ?? [])
            .map((e) => (e as num).toDouble())
            .toList(),
      );

  final String id;
  final String kind;
  final String title;
  final double startS;
  final double endS;
  final double score;
  final int nMoments;

  /// Montagens são cortadas no ritmo e aceitam trilha; um trecho corrido da
  /// partida sai sempre com o áudio do jogo.
  final bool acceptsMusic;
  final List<double> moments;

  double get durationS => endS - startS;
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
    this.proposalId,
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
        proposalId: j['proposal_id'] as String?,
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
  final String? proposalId;

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

/// Um pedido de geração: as propostas escolhidas de uma vez, cada uma com a
/// sua música. Uma partida acumula quantos pedidos o usuário quiser.
class Render {
  Render({
    required this.id,
    required this.status,
    required this.stage,
    required this.progress,
    required this.createdAt,
    this.error,
    this.clips = const [],
    this.musicNames = const [],
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
        musicNames: ((j['selections'] as List?) ?? [])
            .map((e) => (e as Map)['music_name'] as String?)
            .whereType<String>()
            .toSet()
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
  final List<String> musicNames;

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
    this.nProposals = 0,
    this.nRenders = 0,
    this.zipUrl,
    this.hasCuts = false,
    this.hasActiveRender = false,
    this.error,
    this.events = const [],
    this.proposals = const [],
    this.renders = const [],
    this.clips = const [],
    this.detectors = const [],
    this.tracks = const [],
  });

  factory Job.fromJson(Map<String, dynamic> j) => Job(
        id: j['id'] as String,
        status: j['status'] as String,
        stage: j['stage'] as String? ?? '',
        progress: (j['progress'] as num?)?.toDouble() ?? 0,
        videoName: j['video_name'] as String? ?? '',
        durationS: (j['duration_s'] as num?)?.toDouble() ?? 0,
        createdAt: DateTime.parse(j['created_at'] as String),
        nClips: j['n_clips'] as int? ?? 0,
        nProposals: j['n_proposals'] as int? ?? 0,
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
        proposals: ((j['proposals'] as List?) ?? [])
            .map((e) => Proposal.fromJson(e as Map<String, dynamic>))
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
      );

  final String id;
  final String status;
  final String stage;
  final double progress;
  final String videoName;
  final double durationS;
  final DateTime createdAt;
  final int nClips;
  final int nProposals;
  final int nRenders;

  /// Pacote da partida inteira: vídeos finais e cortes avulsos.
  final String? zipUrl;
  final bool hasCuts;

  /// Algum pedido de geração ainda em andamento. Vem da API porque a listagem
  /// não carrega os pedidos inteiros.
  final bool hasActiveRender;
  final String? error;
  final List<DetectionEvent> events;
  final List<Proposal> proposals;
  final List<Render> renders;
  final List<Clip> clips;
  final List<DetectorReport> detectors;

  /// Músicas já enviadas para esta partida, prontas para montar em cima.
  final List<Track> tracks;

  /// A análise ainda está rodando.
  bool get isAnalyzing => status != 'ready' && status != 'failed';

  /// A análise terminou: dá para escolher o que gerar.
  bool get isReady => status == 'ready';
  bool get isFailed => status == 'failed';

  /// Vale continuar consultando o servidor.
  bool get isActive =>
      isAnalyzing || hasActiveRender || renders.any((r) => r.isActive);
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
    var sent = 0;
    void bump(int n) {
      sent += n;
      onProgress?.call(total == 0 ? 0 : sent / total);
    }

    final request =
        http.MultipartRequest('POST', Uri.parse('$baseUrl/api/jobs'))
          ..fields['params'] = jsonEncode(params.toJson())
          ..files.add(_part('video', video, total, bump));

    final streamed = await request.send();
    final r = await http.Response.fromStream(streamed);
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
    var sent = 0;
    void bump(int n) {
      sent += n;
      onProgress?.call(total == 0 ? 1 : sent / total);
    }

    final request = http.MultipartRequest(
      'POST',
      Uri.parse('$baseUrl/api/jobs/$jobId/tracks'),
    )..files.add(_part('audio', audio, total, bump));

    final streamed = await request.send();
    final r = await http.Response.fromStream(streamed);
    _check(r);
    final id = (jsonDecode(r.body) as Map<String, dynamic>)['id'] as String;
    return getTrack(id);
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

  /// Pede a geração dos vídeos escolhidos.
  ///
  /// Cada escolha leva a sua própria música no campo `music_<proposal_id>` —
  /// é assim que dois vídeos da mesma partida saem com trilhas diferentes.
  /// Escolha sem música vira vídeo com o áudio original.
  ///
  /// [montages] são os vídeos montados à mão: eles já trazem os blocos
  /// posicionados e apontam para uma música que **já subiu**, então não levam
  /// arquivo nenhum. Os dois convivem no mesmo pedido.
  Future<String> createRender({
    required String jobId,
    List<Selection> selections = const [],
    List<Montage> montages = const [],
    void Function(double sent)? onProgress,
  }) async {
    var total = 0;
    for (final sel in selections) {
      if (sel.music != null) total += await sel.music!.length();
    }
    var sent = 0;
    void bump(int n) {
      sent += n;
      onProgress?.call(total == 0 ? 1 : sent / total);
    }

    final request = http.MultipartRequest(
      'POST',
      Uri.parse('$baseUrl/api/jobs/$jobId/renders'),
    )
      ..fields['selections'] =
          jsonEncode([for (final s in selections) s.toJson()])
      ..fields['timelines'] =
          jsonEncode([for (final m in montages) m.toJson()]);

    for (final sel in selections) {
      final music = sel.music;
      if (music == null) continue;
      request.files.add(
        _part('music_${sel.proposalId}', music, await music.length(), bump),
      );
    }

    final streamed = await request.send();
    final r = await http.Response.fromStream(streamed);
    _check(r);
    return (jsonDecode(r.body) as Map<String, dynamic>)['id'] as String;
  }

  http.MultipartFile _part(
    String field,
    PlatformFile file,
    int length,
    void Function(int) onBytes,
  ) {
    Stream<List<int>> counting() async* {
      await for (final chunk in file.readAsByteStream()) {
        onBytes(chunk.length);
        yield chunk;
      }
    }

    return http.MultipartFile(field, counting(), length, filename: file.name);
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
