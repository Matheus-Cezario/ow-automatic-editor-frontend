import 'package:flutter/material.dart';

/// Linha de escolha de arquivo — a mesma no upload da gravação e na hora de
/// pôr uma trilha num vídeo.
class FileTile extends StatelessWidget {
  const FileTile({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.chosen,
    required this.onTap,
    this.onClear,
    this.dense = false,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool chosen;
  final VoidCallback? onTap;
  final VoidCallback? onClear;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final lado = dense ? 34.0 : 44.0;
    return Card(
      margin: EdgeInsets.zero,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.all(dense ? 10 : 14),
          child: Row(
            children: [
              Container(
                width: lado,
                height: lado,
                decoration: BoxDecoration(
                  color: (chosen ? scheme.primary : scheme.onSurface)
                      .withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(dense ? 9 : 12),
                ),
                child: Icon(icon,
                    size: dense ? 18 : 24,
                    color: chosen ? scheme.primary : scheme.onSurfaceVariant),
              ),
              SizedBox(width: dense ? 10 : 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: dense
                            ? Theme.of(context).textTheme.bodyMedium
                            : Theme.of(context).textTheme.titleSmall),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: Theme.of(context).hintColor),
                    ),
                  ],
                ),
              ),
              if (onClear != null)
                IconButton(
                  onPressed: onClear,
                  icon: const Icon(Icons.close),
                  tooltip: 'Remover',
                )
              else
                Icon(chosen ? Icons.check_circle : Icons.chevron_right,
                    size: dense ? 20 : 24,
                    color: chosen ? scheme.primary : null),
            ],
          ),
        ),
      ),
    );
  }
}
