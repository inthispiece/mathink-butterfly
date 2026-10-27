import 'package:butterfly/embed/mathink_navigation.dart';
import 'package:butterfly/embed/mathink.dart';
import 'package:butterfly_api/butterfly_api.dart';
import 'package:archive/archive.dart';
import 'package:butterfly/handlers/handler.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const paper = Rect.fromLTWH(0, 0, 1000, 1414), viewport = Size(800, 1000);
  PointerDownEvent down(
    int id,
    double x, {
    PointerDeviceKind kind = PointerDeviceKind.touch,
  }) => PointerDownEvent(
    pointer: id,
    kind: kind,
    position: Offset(x, 150),
    timeStamp: const Duration(milliseconds: 10),
  );
  PointerUpEvent up(int id, double x, {double y = 150}) => PointerUpEvent(
    pointer: id,
    kind: PointerDeviceKind.touch,
    position: Offset(x, y),
    timeStamp: const Duration(milliseconds: 310),
  );
  test('fit width and logical 100 percent have independent geometry', () {
    final fitted = mathInkFitView(paper, viewport, widthOnly: true),
        actual = mathInkFitView(paper, viewport, widthOnly: false);
    expect(fitted.zoom, .752);
    expect(actual.zoom, 1);
    expect(actual.position.dx, 100);
    expect(
      () => mathInkPaperRect({'width': double.nan, 'height': 20}),
      throwsFormatException,
    );
  });
  test('a fit-width single touch flips at most one page only on deliberate horizontal end', () {
    final g = MathInkPageGesture();
    g.down(
      down(1, 500),
      paper: paper,
      viewport: viewport,
      camera: Offset.zero,
      zoom: .7,
      allowed: true,
      pointerCount: 1,
    );
    expect(g.up(up(1, 200)), 'next');
    g.reset();
    expect(g.up(up(1, 200)), isNull);
    g.down(
      down(1, 500),
      paper: paper,
      viewport: viewport,
      camera: Offset.zero,
      zoom: .7,
      allowed: true,
      pointerCount: 1,
    );
    expect(g.up(up(1, 490, y: 500)), isNull);
  });
  test('zoomed page must already be at the outward edge on a new gesture', () {
    final g = MathInkPageGesture();
    g.down(
      down(1, 500),
      paper: paper,
      viewport: viewport,
      camera: const Offset(100, 0),
      zoom: 2,
      allowed: true,
      pointerCount: 1,
    );
    expect(g.up(up(1, 200)), isNull);
    g.down(
      down(1, 500),
      paper: paper,
      viewport: viewport,
      camera: const Offset(600, 0),
      zoom: 2,
      allowed: true,
      pointerCount: 1,
    );
    expect(g.up(up(1, 200)), 'next');
    expect(g.up(up(1, 700)), isNull);
  });
  test('pen, content locks, edge back area, second fingers and cancellation cannot flip', () {
    for (final sample in [
      down(1, 500, kind: PointerDeviceKind.stylus),
      down(1, 10),
    ]) {
      final g = MathInkPageGesture();
      g.down(
        sample,
        paper: paper,
        viewport: viewport,
        camera: Offset.zero,
        zoom: .7,
        allowed: true,
        pointerCount: 1,
      );
      expect(g.up(up(1, 200)), isNull);
    }
    final g = MathInkPageGesture();
    g.down(
      down(1, 500),
      paper: paper,
      viewport: viewport,
      camera: Offset.zero,
      zoom: .7,
      allowed: false,
      pointerCount: 1,
    );
    expect(g.up(up(1, 200)), isNull);
    g.down(
      down(1, 500),
      paper: paper,
      viewport: viewport,
      camera: Offset.zero,
      zoom: .7,
      allowed: true,
      pointerCount: 1,
    );
    g.down(
      down(2, 550),
      paper: paper,
      viewport: viewport,
      camera: Offset.zero,
      zoom: .7,
      allowed: true,
      pointerCount: 2,
    );
    expect(g.up(up(1, 200)), isNull);
    g.down(
      down(1, 500),
      paper: paper,
      viewport: viewport,
      camera: Offset.zero,
      zoom: .7,
      allowed: true,
      pointerCount: 1,
    );
    g.cancel();
    expect(g.up(up(1, 200)), isNull);
  });
  test('prepared PDF page archives are atomic immutable manifests and preserve page geometry on copy', () {
    final original = NoteData(Archive())
        .setPage(
          DocumentPage(
            layers: [DocumentLayer(id: 'ink-layer')],
            extra: {
              'mathinkPage': {'id': 'original'},
            },
          ),
          'original',
        )
        .$1;
    final prepared = mathInkPreparePdfPages(original, [
      {
        'id': 'pdf-a',
        'width': 600,
        'height': 800,
        'resourceId': 'pdf-r',
        'pageIndex': 0,
      },
      {
        'id': 'pdf-b',
        'width': 800,
        'height': 600,
        'resourceId': 'pdf-r',
        'pageIndex': 1,
      },
    ], afterPage: 'original');
    expect(original.getPages(true).length, 1);
    expect(prepared.getPages(true).length, 3);
    final page = prepared.getPage(mathInkResolvePage(prepared, 'pdf-b')!)!;
    expect(mathInkPageGeometry(page).width, 800);
    expect(mathInkPageGeometry(mathInkClonePage(page, 'copy')).width, 800);
    expect(page.content, isEmpty);
    expect(page.extra['mathinkPdf']['resourceId'], 'pdf-r');
    final replaced = mathInkPreparePdfPages(original, [
      {'id': 'pdf-a', 'width': 600, 'height': 800},
    ], replaceEmptyFirst: true);
    expect(mathInkPageDirectory(replaced).map((p) => p['id']), ['pdf-a']);
    expect(
      () => mathInkPreparePdfPages(original, [
        {'id': 'pdf-a', 'width': 600, 'height': 800},
        {'id': 'pdf-a', 'width': 600, 'height': 800},
      ]),
      throwsFormatException,
    );
    expect(original.getPages(true).length, 1);
  });
  test('prepared PDF index inserts before or between native pages around host-only typeset pages', () {
    final original = NoteData(Archive())
        .setPage(
          DocumentPage(
            extra: {
              'mathinkPage': {'id': 'handwriting-a'},
            },
          ),
          'handwriting-a',
        )
        .$1
        .setPage(
          DocumentPage(
            extra: {
              'mathinkPage': {'id': 'handwriting-b'},
            },
          ),
          'handwriting-b',
        )
        .$1;
    final beforeTypeset = mathInkPreparePdfPages(
      original,
      [
        {'id': 'pdf-prepend', 'width': 600, 'height': 800},
      ],
      index: 0,
      afterPage: 'host-only-typeset-page',
    );
    expect(mathInkPageDirectory(beforeTypeset).map((p) => p['id']), [
      'pdf-prepend',
      'handwriting-a',
      'handwriting-b',
    ]);
    final afterTypeset = mathInkPreparePdfPages(
      original,
      [
        {'id': 'pdf-middle-a', 'width': 600, 'height': 800},
        {'id': 'pdf-middle-b', 'width': 800, 'height': 600},
      ],
      index: 1,
      afterPage: 'host-only-typeset-page',
    );
    expect(mathInkPageDirectory(afterTypeset).map((p) => p['id']), [
      'handwriting-a',
      'pdf-middle-a',
      'pdf-middle-b',
      'handwriting-b',
    ]);
    final append = mathInkPreparePdfPages(original, [
      {'id': 'pdf-last', 'width': 600, 'height': 800},
    ], index: 2);
    expect(mathInkPageDirectory(append).last['id'], 'pdf-last');
    for (final index in [-1, 3]) {
      expect(
        () => mathInkPreparePdfPages(original, [
          {'id': 'pdf-invalid', 'width': 600, 'height': 800},
        ], index: index),
        throwsFormatException,
      );
    }
    expect(mathInkPageDirectory(original).map((p) => p['id']), [
      'handwriting-a',
      'handwriting-b',
    ]);
  });
  test('detaching an unsubmitted mouse dot preserves identity and pressure without emitting history', () {
    final handler = PenHandler(PenTool()),
        dot = PenElement(id: 'dot', points: [PathPoint(10, 20, .7)]);
    handler.elements[3] = dot;
    handler.lastPosition[3] = const Offset(10, 20);
    handler.isDrawing = true;
    final detached = handler.detachUnsubmittedPointer(3);
    expect(detached, dot);
    expect(handler.elements, isEmpty);
    expect(handler.lastPosition, isEmpty);
    expect(handler.isDrawing, false);
    expect(handler.detachUnsubmittedPointer(3), isNull);
  });
}
