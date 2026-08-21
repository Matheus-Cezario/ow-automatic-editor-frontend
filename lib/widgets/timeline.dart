import 'package:flutter/material.dart';

import '../api.dart';
import 'highlight_style.dart';

/// Linha do tempo da partida: cada evento detectado vira um traço na posição
/// em que aconteceu. É o jeito mais direto de o usuário conferir se a detecção
/// bateu com o que ele lembra da partida.
class EventTimeline extends StatelessWidget {
  const EventTimeline({
    super.key,
    required this.events,
    required this.durationS,
  });

  final List<DetectionEvent> events;
  final double durationS;

  @override
  Widget build(BuildContext context) {
    if (durationS <= 0) return const SizedBox.shrink();

    // uma faixa por tipo, na ordem em que os tipos aparecem
    final kinds = <String>[];
    for (final e in events) {
      if (!kinds.contains(e.kind)) kinds.add(e.kind);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final kind in kinds)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              children: [
                SizedBox(
                  width: 108,
                  child: Row(
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: EventStyle.of(kind).color,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          EventStyle.of(kind).label,
                          style: Theme.of(context).textTheme.bodySmall,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: _Track(
                    color: EventStyle.of(kind).color,
                    positions: events
                        .where((e) => e.kind == kind)
                        .map((e) => (e.t / durationS).clamp(0.0, 1.0))
                        .toList(),
                  ),
                ),
              ],
            ),
          ),
        const SizedBox(height: 2),
        Row(
          children: [
            const SizedBox(width: 108),
            Text('00:00', style: Theme.of(context).textTheme.labelSmall),
            const Spacer(),
            Text(formatClock(durationS),
                style: Theme.of(context).textTheme.labelSmall),
          ],
        ),
      ],
    );
  }
}

class _Track extends StatelessWidget {
  const _Track({required this.color, required this.positions});

  final Color color;
  final List<double> positions;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, constraints) => SizedBox(
          height: 18,
          child: Stack(
            children: [
              Align(
                alignment: Alignment.center,
                child: Container(
                  height: 2,
                  decoration: BoxDecoration(
                    color: Theme.of(context).dividerColor,
                    borderRadius: BorderRadius.circular(1),
                  ),
                ),
              ),
              for (final p in positions)
                Positioned(
                  left: (p * (constraints.maxWidth - 3)).clamp(
                      0.0, constraints.maxWidth - 3),
                  top: 3,
                  child: Container(
                    width: 3,
                    height: 12,
                    decoration: BoxDecoration(
                      color: color,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
}
