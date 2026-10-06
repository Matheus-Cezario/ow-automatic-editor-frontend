import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ow_editor/undo_store.dart';

/// Where the undo history waits out a reload. On the web it is the browser's
/// storage (`flutter test --platform chrome`); off it there is no reload to
/// wait out, and nothing is kept.
void main() {
  test('what is written comes back, on the web only', () {
    final kept = writeUndo('job.montage', '{"v":1}');
    expect(kept, kIsWeb);
    expect(readUndo('job.montage'), kIsWeb ? '{"v":1}' : isNull);
  });

  test('a montage never written has no history', () {
    expect(readUndo('job.never-written'), isNull);
  });
}
