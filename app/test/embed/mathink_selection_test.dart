import 'package:butterfly/embed/mathink.dart';
import 'package:butterfly/cubits/transform.dart';
import 'package:butterfly/renderers/renderer.dart';
import 'package:butterfly_api/butterfly_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';

void main() {
  final selected = Renderer<PadElement>.fromInstance(
    PadElement.pen(id: 'formula'),
  );
  final unrelated = Renderer<PadElement>.fromInstance(
    PadElement.pen(id: 'private-note'),
  );
  final label = Renderer<PadElement>.fromInstance(
    PadElement.markdown(id: 'label', text: 'private context'),
  );
  final renderers = [selected, unrelated, label];
  test('OCR export never includes neighboring private strokes or labels', () {
    expect(resolveMathInkPens(renderers, ['formula']), [selected]);
  });
  test(
    'a removed source stroke invalidates export rather than widening it',
    () {
      expect(
        () => resolveMathInkPens(renderers, ['formula', 'deleted']),
        throwsFormatException,
      );
    },
  );
  test('a text object cannot be exported as a source ink stroke', () {
    expect(
      () => resolveMathInkPens(renderers, ['label']),
      throwsFormatException,
    );
  });
  test('an offset source selection remains inside the exported image', () {
    const bounds = Rect.fromLTWH(500, 700, 120, 90);
    final options = mathInkImageOptions(bounds);
    final camera = CameraTransform(
      1,
      Offset(options.x, options.y),
      options.scale,
    );
    final local = camera.globalToLocal(bounds.center);
    expect(
      (Offset.zero & Size(options.width, options.height)).contains(local),
      isTrue,
    );
    expect(camera.globalToLocal(bounds.topLeft), Offset.zero);
  });
  test('inserting a confirmed formula preserves the source ink revision', () {
    final ink = PadElement.pen(id: 'source');
    final layer = DocumentLayer(id: 'page-layer', content: [ink]);
    final before = DocumentPage(layers: [layer]);
    final after = before.copyWith(
      layers: [
        layer.copyWith(
          content: [
            ink,
            PadElement.markdown(id: 'result', text: r'$x^2$'),
          ],
        ),
      ],
    );
    expect(mathInkRevision(after), mathInkRevision(before));
    final edited = before.copyWith(
      layers: [
        layer.copyWith(
          content: [
            ink,
            PadElement.pen(id: 'new-ink'),
          ],
        ),
      ],
    );
    expect(mathInkRevision(edited), isNot(mathInkRevision(before)));
  });
}
