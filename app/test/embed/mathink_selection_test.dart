import 'package:butterfly/embed/mathink.dart';
import 'package:butterfly/cubits/transform.dart';
import 'package:butterfly/renderers/renderer.dart';
import 'package:butterfly_api/butterfly_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:archive/archive.dart';

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
    expect(mathInkPageRevision(after), isNot(mathInkPageRevision(before)));
  });

  test(
    'whole page export includes source text and ink independent of selection',
    () {
      final ink = Renderer<PadElement>.fromInstance(
        PadElement.pen(id: 'offscreen-ink'),
      );
      final text = Renderer<PadElement>.fromInstance(
        PadElement.markdown(id: 'paragraph', text: '中文 English'),
      );
      final all = mathInkPageRenderers([ink, text]);
      expect(all, [ink, text]);
      final layer = DocumentLayer(
        id: 'layer',
        content: [PadElement.markdown(id: 'text', text: 'before')],
      );
      final before = DocumentPage(layers: [layer]);
      final after = before.copyWith(
        layers: [
          layer.copyWith(
            content: [PadElement.markdown(id: 'text', text: 'after')],
          ),
        ],
      );
      expect(mathInkRevision(before), mathInkRevision(after));
      expect(mathInkPageRevision(before), isNot(mathInkPageRevision(after)));
    },
  );

  NoteData pagesDocument() {
    var data = NoteData(
      Archive(),
    ).setMetadata(FileMetadata(type: NoteFileType.document, fileVersion: 13));
    for (final name in ['first', 'never-opened', 'last']) {
      data = data
          .setPage(
            DocumentPage(
              layers: [
                DocumentLayer(
                  id: 'layer-$name',
                  content: [PadElement.pen(id: 'ink-$name')],
                ),
              ],
            ),
            name,
          )
          .$1;
    }
    return data;
  }

  test(
    'native directory includes all archived pages even when never visited',
    () {
      final data = mathInkEnsurePageIds(pagesDocument());
      final directory = mathInkPageDirectory(data);
      expect(directory.length, 3);
      expect(directory[1]['title'], 'never-opened');
      expect(directory.map((p) => p['id']).toSet().length, 3);
      expect(directory.every((p) => p['deleted'] == false), true);
    },
  );

  test('native reorder changes ordinal file names without changing source identity', () {
    var data = mathInkEnsurePageIds(pagesDocument());
    final before = mathInkPageDirectory(data);
    final id = before.last['id'] as String;
    final ink = data.getPage(mathInkResolvePage(data, id)!)!.content.first.id;
    final revision = before.last['pageRevision'];
    data = data.reorderPage(before.last['name'] as String, 0);
    final after = mathInkPageDirectory(data);
    expect(after.first['id'], id);
    expect(after.first['pageRevision'], revision);
    expect(data.getPage(mathInkResolvePage(data, id)!)!.content.first.id, ink);
    for (final old in before) {
      expect(mathInkResolvePage(data, old['id'] as String), isNotNull);
    }
  });

  test('page clone creates independent layer and element IDs without reusing placement receipts', () {
    final source = DocumentPage(
      layers: [
        DocumentLayer(
          id: 'layer',
          content: [PadElement.markdown(id: 'formula', text: r'$x^2$')],
        ),
      ],
      extra: {
        'mathinkPage': {'id': 'source', 'paper': 'lined'},
        'mathinkOperations': {
          'already-inserted': {'elementId': 'formula'},
        },
      },
    );
    final copied = mathInkClonePage(source, 'copy');
    expect(mathInkStablePageId(copied, '1.copy'), 'copy');
    expect(copied.layers.first.id, isNot(source.layers.first.id));
    expect(copied.content.first.id, isNot(source.content.first.id));
    expect((copied.content.first as MarkdownElement).text, r'$x^2$');
    expect(copied.extra['mathinkOperations'], isEmpty);
    expect(mathInkPaper(copied), 'lined');
  });

  test('deleted native pages remain recoverable and are never resolved as another ordinal page', () {
    var data = mathInkEnsurePageIds(pagesDocument());
    final row = mathInkPageDirectory(data)[1];
    final name = row['name'] as String, id = row['id'] as String;
    final page = data.getPage(name)!;
    final metadata = mathInkPageMetadata(page);
    data = data
        .setPage(
          page.copyWith(
            extra: {
              ...page.extra,
              'mathinkPage': {...metadata, 'deleted': true},
            },
          ),
          name,
        )
        .$1;
    expect(mathInkResolvePage(data, id), isNull);
    expect(mathInkResolvePage(data, id, includeDeleted: true), name);
    expect(data.getPage(name)!.content.first.id, page.content.first.id);
    data = data.setPage(page, name).$1;
    expect(mathInkResolvePage(data, id), name);
  });

  test(
    'identity and placement bookkeeping do not stale a visual source revision',
    () {
      const before = DocumentPage(extra: {'external': 'preserved'});
      final metadataOnly = before.copyWith(
        extra: {
          ...before.extra,
          'mathinkPage': {'id': 'stable', 'deleted': false, 'paper': 'blank'},
          'mathinkOperations': {
            'op': {'elementId': 'instance'},
          },
        },
      );
      expect(mathInkPageRevision(metadataOnly), mathInkPageRevision(before));
      final changed = metadataOnly.copyWith(
        backgrounds: mathInkPaperBackgrounds('grid'),
      );
      expect(mathInkPageRevision(changed), isNot(mathInkPageRevision(before)));
      expect(mathInkRevision(changed), mathInkRevision(before));
    },
  );

  test('blank, ruled and grid paper use real native texture backgrounds', () {
    for (final paper in ['blank', 'lined', 'grid']) {
      final page = DocumentPage(backgrounds: mathInkPaperBackgrounds(paper));
      expect(mathInkPaper(page), paper);
      expect(page.backgrounds.single, isA<TextureBackground>());
    }
    expect(() => mathInkPaperBackgrounds('unsupported'), throwsFormatException);
  });

  test('stable page catalog survives a complete native archive round trip', () {
    final original = mathInkEnsurePageIds(pagesDocument());
    final restored = NoteData.fromData(original.exportAsBytes());
    expect(mathInkPageDirectory(restored), mathInkPageDirectory(original));
  });

  test('host page insertion uses ordinal positions even after native prefixes develop gaps', () {
    var data = mathInkEnsurePageIds(pagesDocument());
    final first = data.getPages(true).first;
    data = data.reorderPage(first, 3);
    final old = mathInkPageDirectory(data).map((p) => p['id']).toList();
    final newPage = DocumentPage(
      extra: {
        'mathinkPage': {'id': 'inserted'},
      },
    );
    data = data.setPage(newPage, 'inserted', mathInkInsertionIndex(data, 1)).$1;
    expect(mathInkPageDirectory(data).map((p) => p['id']).toList(), [
      old[0],
      'inserted',
      old[1],
      old[2],
    ]);
    final append = mathInkInsertionIndex(data, data.getPages(true).length);
    expect(append, greaterThan(data.getPageIndex(data.getPages(true).last)!));
  });

  test('ordered host identities survive native reorder with noncontiguous numeric filenames', () {
    var data = mathInkEnsurePageIds(pagesDocument());
    data = data.reorderPage(data.getPages(true).first, 3);
    final original = mathInkPageDirectory(data)
        .map((p) => p['id'] as String)
        .toList();
    final wanted = [original[0], original[2], original[1]];
    for (var rank = 0; rank < wanted.length; rank++) {
      final real = mathInkResolvePage(data, wanted[rank])!;
      if (data.getPages(true).indexOf(real) != rank) {
        data = data.reorderPage(real, mathInkInsertionIndex(data, rank));
      }
    }
    expect(mathInkPageDirectory(data).map((p) => p['id']).toList(), wanted);
  });
}
