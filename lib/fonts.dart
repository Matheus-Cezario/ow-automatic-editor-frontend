/// The server's text fonts, loaded into the app so the monitor draws text
/// with the face the render will use.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'api.dart';

/// The Flutter family a catalogue font is registered under.
String fontFamilyFor(String id) => 'ow-$id';

/// The fonts on offer, and which of them are ready to draw with.
///
/// Loading is lazy and fails quietly: without a font file the monitor falls
/// back to the default face — the text still shows where it will be, only in
/// another letter.
class FontLibrary extends ChangeNotifier {
  FontLibrary(this._api);

  final ApiClient _api;
  List<FontInfo> fonts = const [];
  final Set<String> _ready = {};
  final Set<String> _asked = {};

  /// The id used when a text names none.
  String get defaultId =>
      fonts.where((f) => f.isDefault).firstOrNull?.id ?? '';

  Future<void> start() async {
    try {
      fonts = await _api.listFonts();
      notifyListeners();
      final d = defaultId;
      if (d.isNotEmpty) await ensure(d);
    } catch (_) {
      // no catalogue: the default face it is
    }
  }

  /// The family to draw [id] with now, or `null` when it is not loaded (yet).
  String? familyFor(String id) {
    final wanted = id.isEmpty ? defaultId : id;
    if (_ready.contains(wanted)) return fontFamilyFor(wanted);
    if (wanted.isNotEmpty) ensure(wanted);
    return null;
  }

  Future<void> ensure(String id) async {
    if (_ready.contains(id) || !_asked.add(id)) return;
    final info = fonts.where((f) => f.id == id).firstOrNull;
    if (info == null) return;
    try {
      final bytes = await _api.fontBytes(info.url);
      await (FontLoader(fontFamilyFor(id))
            ..addFont(Future.value(ByteData.sublistView(bytes))))
          .load();
      _ready.add(id);
      notifyListeners();
    } catch (_) {
      _asked.remove(id); // try again next time it is needed
    }
  }
}
