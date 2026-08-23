import 'package:flutter_test/flutter_test.dart';
import 'package:ow_editor/api.dart';
import 'package:ow_editor/rotulos.dart';

/// O texto que o sistema escreve sozinho, a partir do que aconteceu na partida.
///
/// É o diferencial do editor, e ele não está no ffmpeg: está em o editor saber
/// o que aconteceu no vídeo. Para qualquer outro, o vídeo é um retângulo de
/// pixels sem história.
void main() {
  TimelineClip kill(double at, {double dur = 1}) => TimelineClip(
    atS: at,
    durationS: dur,
    startS: 10,
    kind: 'kill',
    sourceT: 10,
  );

  TimelineClip outro(double at) =>
      TimelineClip(atS: at, durationS: 1, startS: 10, kind: 'sleep');

  group('contador de eliminações', () {
    test('sobe a cada corte, e cada número dura até o próximo', () {
      final r = contadorDeEliminacoes([kill(0), kill(2), kill(5)], fimS: 8);

      expect(r.map((c) => c.text), ['1', '2', '3']);
      expect(r[0].atS, 0);
      expect(r[0].durationS, 2.0, reason: 'até a próxima eliminação');
      expect(r[1].durationS, 3.0);
      expect(r[2].durationS, 3.0, reason: 'o último vai até o fim do vídeo');
    });

    test('conta só eliminação — dardo e pedrada não somam', () {
      final r = contadorDeEliminacoes([kill(0), outro(1), kill(3)], fimS: 5);
      expect(r.map((c) => c.text), ['1', '2']);
    });

    test('sem eliminação, não há o que contar', () {
      expect(contadorDeEliminacoes([outro(0)]), isEmpty);
    });

    test('sai como clipe de texto comum, que se move e se edita', () {
      final r = contadorDeEliminacoes([kill(0)], fimS: 3).single;

      expect(r.source, 'text');
      expect(r.isText, isTrue);
      expect(r.toJson()['text'], '1');
      // o gerador é um atalho, não uma entidade nova
      expect(r.toJson().containsKey('text_style'), isTrue);
    });

    test('a ordem dos cortes na lista não importa', () {
      final r = contadorDeEliminacoes([kill(5), kill(0), kill(2)], fimS: 8);
      expect(r.map((c) => c.text), ['1', '2', '3']);
      expect(r.map((c) => c.atS), [0.0, 2.0, 5.0]);
    });
  });

  group('rótulos de rajada', () {
    test('usa os nomes do jogo, não uma contagem', () {
      // "3 KILLS" onde cabe "TRIPLE KILL" soa a planilha
      expect(nomeDaRajada(2), 'DOUBLE KILL');
      expect(nomeDaRajada(3), 'TRIPLE KILL');
      expect(nomeDaRajada(4), 'QUAD KILL');
      expect(nomeDaRajada(7), 'TEAM KILL');
    });

    test('uma eliminação sozinha não é rajada', () {
      expect(nomeDaRajada(1), isNull);
      expect(rotulosDeRajada([kill(0), kill(20)]), isEmpty);
    });

    test('agrupa o que o espectador vê seguido', () {
      // três coladas, depois um intervalo, depois duas
      final r = rotulosDeRajada([
        kill(0),
        kill(1.2),
        kill(2.4),
        kill(20),
        kill(21.2),
      ]);

      expect(r.map((c) => c.text), ['TRIPLE KILL', 'DOUBLE KILL']);
    });

    test('o rótulo entra na última eliminação da rajada', () {
      // é ali que ela se fecha, e é ali que faz sentido anunciá-la
      final r = rotulosDeRajada([kill(0), kill(1.2), kill(2.4)]).single;
      expect(r.atS, 2.4);
    });

    test('o intervalo é medido do fim de um corte ao começo do outro', () {
      // dois cortes longos e colados são uma rajada; o vão entre eles é zero
      final juntos = rotulosDeRajada([kill(0, dur: 3), kill(3, dur: 3)]);
      expect(juntos, hasLength(1));

      final separados = rotulosDeRajada([kill(0, dur: 1), kill(10, dur: 1)]);
      expect(separados, isEmpty);
    });
  });

  group('rótulo solto', () {
    test('nasce visível: com contorno e sumindo nas pontas', () {
      final r = rotulo('TEXTO', atS: 3);

      expect(r.text, 'TEXTO');
      expect(r.atS, 3);
      // sem contorno, texto branco some em cena clara
      expect(r.textStyle.outline, greaterThan(0));
      expect(r.fade.neutro, isFalse);
      // e fica na parte de cima, longe da mira
      expect(r.transform.y, lessThan(0));
    });
  });
}
