import 'package:flutter_test/flutter_test.dart';
import 'package:ow_editor/api.dart';
import 'package:ow_editor/exportacao.dart';
import 'package:ow_editor/montage_state.dart';

/// A exportação é uma janela sobre a montagem, e não uma edição dela.
void main() {
  TimelineClip clipe(String id, double at, double dur) =>
      TimelineClip(id: id, atS: at, durationS: dur, startS: 10);

  MontageState estado(List<TimelineClip> clips, {Set<String> selecao = const {}}) =>
      MontageState(layers: [Layer(clips: clips)], selecao: selecao);

  group('trecho', () {
    test('sem recorte, sai a montagem inteira', () {
      final t = trechoDe(const ExportSpec(), 12.0);
      expect(t.inicio, 0);
      expect(t.fim, 12.0);
      expect(duracaoExportada(const ExportSpec(), 12.0), 12.0);
    });

    test('o fim aberto se resolve contra a duração de agora', () {
      // a especificação não sabe quanto dura a montagem; quem chama sabe
      const e = ExportSpec(fromS: 4);
      expect(duracaoExportada(e, 12.0), 8.0);
      expect(duracaoExportada(e, 20.0), 16.0);
    });

    test('um recorte que passou do fim é aparado, não estourado', () {
      // acontece sozinho: recorta-se a seleção e depois se apagam clipes
      const e = ExportSpec(fromS: 2, toS: 30);
      expect(duracaoExportada(e, 10.0), 8.0);
    });

    test('recorte que ficou todo fora da montagem volta a ser tudo', () {
      const e = ExportSpec(fromS: 50, toS: 60);
      expect(duracaoExportada(e, 10.0), 10.0);
    });
  });

  group('exportar a seleção', () {
    test('a janela vai do primeiro ao último quadro do que está escolhido', () {
      final s = exportarSelecao(
        estado([
          clipe('a', 0, 2),
          clipe('b', 5, 3),
          clipe('c', 20, 1),
        ], selecao: {'b', 'c'}),
      );

      expect(s.export.fromS, 5);
      expect(s.export.toS, 21);
    });

    test('não mexe na montagem — só na janela', () {
      final antes = estado([clipe('a', 0, 2), clipe('b', 5, 3)], selecao: {'b'});
      final depois = exportarSelecao(antes);

      expect(depois.clips.map((c) => c.atS), antes.clips.map((c) => c.atS));
      expect(depois.clips, hasLength(2), reason: 'nada foi apagado');
    });

    test('sem seleção, nada muda', () {
      final antes = estado([clipe('a', 0, 2)]);
      expect(exportarSelecao(antes).export.toS, isNull);
    });

    test('dá para voltar atrás e exportar tudo', () {
      var s = exportarSelecao(estado([clipe('a', 4, 2)], selecao: {'a'}));
      expect(s.export.fromS, 4);

      s = exportarTudo(s);
      expect(s.export.fromS, 0);
      expect(s.export.toS, isNull);
    });
  });

  group('formatos', () {
    test('o original não fixa tamanho nenhum', () {
      final original = formatosDeSaida.first;
      expect(original.width, 0);
      expect(original.proporcao, isNull);
      expect(original.combina(const ExportSpec()), isTrue);
    });

    test('o vertical é 9:16 de verdade', () {
      final v = formatosDeSaida.firstWhere((f) => f.nome == 'Vertical');
      expect(v.proporcao, closeTo(9 / 16, 0.001));
    });

    test('reconhece o formato que já está escolhido', () {
      const e = ExportSpec(width: 1080, height: 1920);
      final achado = formatosDeSaida.where((f) => f.combina(e));
      expect(achado.single.nome, 'Vertical');
    });
  });

  group('qualidade', () {
    test('o padrão do sistema é o do meio', () {
      expect(qualidadeDe(const ExportSpec()).nome, 'Boa');
    });

    test('um crf digitado à mão cai no padrão sem quebrar', () {
      expect(qualidadeDe(const ExportSpec(crf: 23)).nome, 'Boa');
    });

    test('melhor qualidade é crf menor', () {
      final alta = qualidades.firstWhere((q) => q.nome == 'Alta');
      final leve = qualidades.firstWhere((q) => q.nome == 'Leve');
      expect(alta.crf, lessThan(leve.crf));
    });
  });

  group('estimativa de tamanho', () {
    double mb(ExportSpec e) =>
        tamanhoEstimadoMB(e, duracaoS: 30, largura: 1920, altura: 1080);

    test('responde a ordem de grandeza, que é o que se pergunta', () {
      // 30s de 1080p30 na qualidade padrão: dezenas de MB, não centenas
      final r = mb(const ExportSpec());
      expect(r, greaterThan(5));
      expect(r, lessThan(80));
    });

    test('metade dos pixels, metade do arquivo', () {
      final cheio = mb(const ExportSpec(width: 1920, height: 1080));
      final meio = mb(const ExportSpec(width: 1280, height: 720));
      expect(meio, lessThan(cheio));
      expect(meio / cheio, closeTo((1280 * 720) / (1920 * 1080), 0.01));
    });

    test('cada +6 de crf corta o arquivo mais ou menos pela metade', () {
      final a = mb(const ExportSpec(crf: 20));
      final b = mb(const ExportSpec(crf: 26));
      expect(b / a, closeTo(0.5, 0.05));
    });

    test('um trecho pesa só o trecho', () {
      final tudo = mb(const ExportSpec());
      final trecho = mb(const ExportSpec(fromS: 0, toS: 15));
      expect(trecho / tudo, closeTo(0.5, 0.01));
    });
  });

  test('o resumo diz tamanho, duração e peso', () {
    final r = resumoDaExportacao(
      const ExportSpec(width: 1080, height: 1920, fps: 60, fromS: 0, toS: 65),
      duracaoS: 120,
      largura: 1920,
      altura: 1080,
    );

    expect(r, contains('1080x1920'));
    expect(r, contains('60fps'));
    expect(r, contains('1:05'));
    expect(r, contains('MB'));
  });

  test('o formato viaja com o rascunho', () {
    // trocar de máquina e continuar não pode devolver o vídeo ao 16:9
    const e = ExportSpec(width: 1080, height: 1920, crf: 26, fit: 'contain');
    final ida = Montage(export: e).toJson();
    final volta = Montage.fromJson(ida).export;

    expect(volta.width, 1080);
    expect(volta.height, 1920);
    expect(volta.crf, 26);
    expect(volta.fit, 'contain');
  });
}
