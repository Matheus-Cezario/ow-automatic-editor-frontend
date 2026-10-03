/// The monitor's picture: the pieces of a [Frame] stacked on screen.
///
/// On the web it is a single DOM element holding one `<video>` or `<img>` per
/// piece, placed with CSS — the browser composites them on the GPU, the same
/// stacking the server does with `overlay`. Off the web (the widget tests) a
/// stand-in draws plain boxes, enough to check which pieces are on screen.
library;

export 'monitor_picture_stub.dart'
    if (dart.library.js_interop) 'monitor_picture_web.dart';
