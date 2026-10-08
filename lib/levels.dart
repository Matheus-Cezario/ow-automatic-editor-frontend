import 'dart:math' as math;

import 'api.dart';
import 'montage.dart';
import 'montage_state.dart';

/// How loud the mix is around [t], estimated from the waveforms the app
/// already has — the songs' envelopes and the match's — through the same
/// volumes, curves, fades and ducking the server applies.
///
/// It is a level meter, not a loudness meter: the envelopes are peaks, so
/// this is how close the mix comes to full scale (1.0), which is what the
/// eye needs while editing — above 1 the sources add up past what the file
/// can hold, and the render's loudness target is what fixes the rest.
double mixLevelAt(
  MontageState s,
  double t, {
  required Map<String, Track> tracks,
  required List<double> matchWave,
  required double matchDurationS,
  Map<String, (List<double>, double)> otherMatches = const {},
  double windowS = 0.1,
}) {
  // an effect is not music: it does not turn the game down
  final hasMusic = s.layers.any(
    (l) => l.isAudio && l.clips.any((c) => c.isMusic),
  );
  final duck = s.duckPlays
      ? duckAt(playTimes(s.layers), t) * (1 - s.duckLevel)
      : 0.0;
  // under a voice-over the music and the game step back to the duck level
  final voice = voiceDipAt(voiceSpans(s.layers), t) * (1 - s.duckLevel);
  // the game sound: alone, at full; under music, its volume, pushed up to
  // full at the plays when ducking
  final gameGain = (!hasMusic
          ? 1.0
          : s.gameVolume + (math.max(s.gameVolume, 1.0) - s.gameVolume) * duck) *
      (1 - voice);

  var level = 0.0;
  for (final l in s.layers) {
    if (l.muted || (l.hidden && !l.isAudio)) continue;
    for (final c in l.clips) {
      if (t < c.atS || t >= c.untilS) continue;
      final local = t - c.atS;
      final own = gainAt(c, local);
      if (own <= 0) continue;
      if (l.isAudio) {
        final song = tracks[c.mediaId];
        if (song == null) continue;
        final at = c.startS + local;
        // an effect has its own level; the music volume and the dip at the
        // plays are the song's
        level += (!c.isMusic ? 1.0 : s.musicVolume * (1 - math.max(duck, voice))) *
            own *
            _peak(song.peaks, song.durationS, at, windowS);
      } else if (c.source == 'recording' && gameGain > 0) {
        final at = c.startS + c.sourceOffsetAt(local);
        // a moment brought from another match sounds like that match
        final (wave, waveS) = c.jobId == null
            ? (matchWave, matchDurationS)
            : otherMatches[c.jobId] ?? (const <double>[], 0.0);
        level += gameGain * own * _peak(wave, waveS, at, windowS);
      }
    }
  }
  return level;
}

/// The largest envelope value in [atS] ± half a [windowS].
double _peak(List<double> wave, double durationS, double atS, double windowS) {
  if (wave.isEmpty || durationS <= 0) return 0;
  final perS = wave.length / durationS;
  final from = ((atS - windowS / 2) * perS).floor().clamp(0, wave.length - 1);
  final to = ((atS + windowS / 2) * perS).ceil().clamp(0, wave.length - 1);
  var most = 0.0;
  for (var i = from; i <= to; i++) {
    if (wave[i] > most) most = wave[i];
  }
  return most;
}

/// A level as dBFS, for the meter's caption: 1.0 is 0 dB.
String dbfs(double level) {
  if (level <= 0.001) return '−∞ dB';
  final db = 20 * math.log(level) / math.ln10;
  return '${db >= 0 ? '+' : '−'}${db.abs().toStringAsFixed(1)} dB';
}
