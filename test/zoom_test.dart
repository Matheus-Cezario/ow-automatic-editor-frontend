import 'package:flutter_test/flutter_test.dart';
import 'package:ow_editor/zoom.dart';

void main() {
  test('fitting puts the whole montage in the window, with room after', () {
    expect(fitZoom(100, 1050), closeTo(10, 1e-9));
    // a tiny montage does not zoom past the limit
    expect(fitZoom(0.2, 1000), kMaxPxPerSecond);
    // a very long one stops at the widest view
    expect(fitZoom(3600, 800), kMinPxPerSecond);
  });

  test('the anchored instant stays where it was in the window', () {
    // 10 s was 300 px into the window; at 120 px/s the ruler scrolls to 900
    expect(anchoredOffset(10, 300, 120), 900);
    expect(anchoredOffset(1, 300, 60), 0, reason: 'never before the start');
  });

  test('the slider runs on a log scale and back', () {
    expect(zoomToSlider(kMinPxPerSecond), closeTo(0, 1e-9));
    expect(zoomToSlider(kMaxPxPerSecond), closeTo(1, 1e-9));
    expect(zoomToSlider(40), closeTo(0.5, 1e-9), reason: 'the geometric middle');
    for (final px in [4.0, 25.0, 60.0, 333.0]) {
      expect(sliderToZoom(zoomToSlider(px)), closeTo(px, 1e-6));
    }
  });
}
