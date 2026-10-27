import 'dart:async';

import 'package:butterfly/renderers/renderer.dart';
import 'package:butterfly/renderers/foregrounds/select.dart';
import 'package:butterfly/embed/mathink.dart';
import 'package:butterfly/handlers/handler.dart';
import 'package:butterfly/bloc/document_bloc.dart';
import 'package:butterfly/cubits/editor_controller.dart';
import 'package:butterfly/cubits/transform.dart';
import 'package:butterfly/cubits/settings.dart';
import 'package:butterfly_api/butterfly_api.dart';
import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _Context extends Mock implements EventContext {}

class _Controller extends Mock implements EditorController {}

class _Bloc extends Mock implements DocumentBloc {}

class _Success extends Mock implements DocumentLoadSuccess {}

class _Renderers extends Mock implements RendererCubit {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    registerFallbackValue(const ElementsRemoved([]));
    registerFallbackValue(<Offset>[]);
  });
  test('uniform native ink scaling scales stroke width and preserves pressure samples', () {
    final source = PenElement(
      id: 'source',
      points: [PathPoint(10, 20, .25), PathPoint(20, 30, .8)],
      property: const PenProperty(strokeWidth: 3),
    );
    final renderer = PenRenderer(
      source,
      null,
      const Rect.fromLTWH(10, 20, 10, 10),
    );
    final scaled = renderer.transform(scaleX: 2, scaleY: 2) as PenRenderer;
    expect(scaled.element.property.strokeWidth, 6);
    expect(scaled.element.points.map((point) => point.pressure), [.25, .8]);
    expect(scaled.element.points.last.x - scaled.element.points.first.x, 20);
    expect(source.property.strokeWidth, 3);
  });

  test(
    'mixed selections reject rather than upload a silently filtered pen subset',
    () {
      final ink = Renderer<PadElement>.fromInstance(PenElement(id: 'ink'));
      final formula = Renderer<PadElement>.fromInstance(
        MarkdownElement(id: 'math', text: r'$x$', extra: {'mathink': {}}),
      );
      expect(mathInkSelectedPens([ink]), [ink]);
      expect(
        () => mathInkSelectedPens([formula]),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'code',
            'FORMULA_SELECTION',
          ),
        ),
      );
      expect(
        () => mathInkSelectedPens([ink, formula]),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'code',
            'MIXED_SELECTION',
          ),
        ),
      );
    },
  );

  test('host transform controls scale proportionally, retain movement and clamp against crossing the axis', () {
    final manager = RectSelectionForegroundManager(
      enableRotation: false,
      forceProportional: true,
    );
    manager.select(const Rect.fromLTWH(10, 20, 100, 50));
    manager.startTransformWithCorner(
      SelectionTransformCorner.bottomRight,
      const Offset(110, 70),
    );
    manager.updateCurrentPosition(const Offset(160, 170));
    final stretched = manager.getTransform()!;
    expect(stretched.scaleX, stretched.scaleY);
    expect(stretched.rotation, 0);
    manager.updateCurrentPosition(const Offset(-500, -500));
    expect(manager.getTransform()!.scaleX, .05);
    manager.select(const Rect.fromLTWH(10, 20, 100, 50));
    manager.startTransformWithCorner(null, const Offset(50, 40));
    manager.updateCurrentPosition(const Offset(80, 90));
    expect(manager.getTransform()!.position, const Offset(30, 50));
  });

  test(
    'native math display size is an independent persistent element property',
    () {
      final formula = MarkdownElement(
        id: 'formula',
        text: r'$x^2$',
        scale: 2,
        extra: {
          'mathink': {'latex': 'x^2'},
        },
      );
      final result = MarkdownRenderer(
        formula,
      ).transform(scaleX: 3, scaleY: 3) as MarkdownRenderer;
      expect(result.element.scale, 6);
      expect(result.element.text, formula.text);
      expect(formula.scale, 2);
      expect(PadElement.fromJson(result.element.toJson()), result.element);
    },
  );

  test('history reports the native pages whose actual contents change', () {
    final first = DocumentPage(
      layers: [
        DocumentLayer(
          id: 'layer',
          content: [PenElement(id: 'ink')],
        ),
      ],
      extra: {
        'mathinkPage': {'id': 'source'},
      },
    );
    final before = NoteData(Archive()).setPage(first, 'first').$1;
    final after = before
        .setPage(first.copyWith(layers: []), before.getPages(true).first)
        .$1;
    expect(mathInkAffectedPages(before, after), ['source']);
    final metadata = before
        .setPage(
          first.copyWith(
            extra: {
              ...first.extra,
              'mathinkOperations': {'receipt': 'kept'},
            },
          ),
          before.getPages(true).first,
        )
        .$1;
    expect(mathInkAffectedPages(before, metadata), isEmpty);
  });

  for (final cancel in [false, true]) {
    test(
      cancel
          ? 'cancelling a native transform restores original geometry with no history event'
          : 'many pointer updates commit one uniform native history event and retain selected objects',
      () async {
        final bloc = _Bloc(), controller = _Controller(), context = _Context();
        final camera = TransformCubit(1);
        addTearDown(camera.close);
        final handler = SelectHandler(
          SelectTool(mode: .lasso),
          hostManaged: true,
        );
        final source = PenElement(
          id: 'ink',
          points: [PathPoint(10, 20, .25), PathPoint(20, 30, .8)],
          property: const PenProperty(strokeWidth: 3),
        );
        final ink = PenRenderer(
          source,
          null,
          const Rect.fromLTWH(10, 20, 10, 10),
          const Rect.fromLTWH(10, 20, 10, 10),
        );
        final events = <DocumentEvent>[];
        when(() => bloc.state).thenReturn(_Success());
        when(() => bloc.editorController).thenReturn(controller);
        when(() => controller.transformCubit).thenReturn(camera);
        when(() => bloc.refresh(allowBake: any(named: 'allowBake')))
            .thenAnswer((_) async {});
        when(() => bloc.add(any())).thenAnswer((invocation) {
          events.add(invocation.positionalArguments.single as DocumentEvent);
        });
        when(() => context.getCameraTransform()).thenReturn(camera.state);
        when(() => context.getViewState()).thenReturn(const EditorViewState());
        when(() => context.getDocumentBloc()).thenReturn(bloc);
        when(() => context.isShiftPressed).thenReturn(false);
        when(() => context.isAltPressed).thenReturn(false);
        when(() => context.isCtrlPressed).thenReturn(false);
        when(() => context.refreshForegrounds()).thenAnswer((_) async {});
        handler.transform(
          bloc,
          SelectionTransformCorner.bottomRight,
          next: [ink],
          position: const Offset(20, 30),
        );
        handler.onScaleUpdate(
          ScaleUpdateDetails(
            localFocalPoint: const Offset(25, 40),
            pointerCount: 1,
          ),
          context,
        );
        handler.onScaleUpdate(
          ScaleUpdateDetails(
            localFocalPoint: const Offset(30, 50),
            pointerCount: 1,
          ),
          context,
        );
        expect(events, isEmpty);
        if (cancel) handler.cancelTransform(bloc);
        await handler.onScaleEnd(ScaleEndDetails(), context);
        if (cancel) {
          expect(events, isEmpty);
          expect(handler.selectedRenderers.single.element, source);
        } else {
          expect(events, hasLength(1));
          expect(events.single, isA<ElementsChanged>());
          final changed =
              (events.single as ElementsChanged).elements['ink']!.single
                  as PenElement;
          expect(changed.property.strokeWidth, 9);
          expect(changed.points.map((point) => point.pressure), [.25, .8]);
          expect(handler.selectedRenderers.single.element, changed);
        }
      },
    );
  }

  for (final axis in ['horizontal', 'vertical', 'point']) {
    test(
      'a selected $axis pen moves through the real gesture hit test',
      () async {
        final bloc = _Bloc(), controller = _Controller(), context = _Context();
        final renderers = _Renderers();
        final camera = TransformCubit(1);
        addTearDown(camera.close);
        final handler = SelectHandler(
          SelectTool(mode: .lasso),
          hostManaged: true,
        );
        final start = const Offset(100, 100);
        final end = switch (axis) {
          'horizontal' => const Offset(200, 100),
          'vertical' => const Offset(100, 200),
          _ => start,
        };
        final source = PenElement(
          id: 'degenerate-ink',
          points: [
            PathPoint(start.dx, start.dy, .25),
            if (axis != 'point') PathPoint(end.dx, end.dy, .8),
          ],
          property: const PenProperty(strokeWidth: 3),
        );
        final lineBounds = Rect.fromPoints(start, end);
        final ink = PenRenderer(
          source,
          null,
          lineBounds,
          lineBounds.inflate(3),
        );
        final events = <DocumentEvent>[];
        when(() => bloc.state).thenReturn(_Success());
        when(() => bloc.editorController).thenReturn(controller);
        when(() => controller.transformCubit).thenReturn(camera);
        when(() => controller.rendererCubit).thenReturn(renderers);
        when(() => renderers.renderers).thenReturn([ink]);
        when(() => bloc.refresh(allowBake: any(named: 'allowBake')))
            .thenAnswer((_) async {});
        when(() => bloc.refreshForegrounds()).thenAnswer((_) async {});
        when(() => bloc.add(any())).thenAnswer((invocation) {
          events.add(invocation.positionalArguments.single as DocumentEvent);
        });
        when(() => context.getCameraTransform()).thenReturn(camera.state);
        when(() => context.getDocumentBloc()).thenReturn(bloc);
        when(() => context.getToolState())
            .thenReturn(ToolRuntimeState(handler: handler));
        when(() => context.getInputState())
            .thenReturn(const EditorInputState());
        when(() => context.getViewState()).thenReturn(const EditorViewState());
        when(() => context.getSettings()).thenReturn(const ButterflySettings());
        when(() => context.isShiftPressed).thenReturn(false);
        when(() => context.isAltPressed).thenReturn(false);
        when(() => context.isCtrlPressed).thenReturn(false);
        when(() => context.refresh()).thenAnswer((_) async {});
        when(() => context.refreshForegrounds()).thenAnswer((_) async {});

        handler.selectAll(bloc);
        expect(handler.selectedRenderers.single.element, source);
        final focalPoint = lineBounds.center;
        expect(
          handler.onScaleStart(
            ScaleStartDetails(localFocalPoint: focalPoint),
            context,
          ),
          isTrue,
        );
        const movement = Offset(30, 40);
        handler.onScaleUpdate(
          ScaleUpdateDetails(
            localFocalPoint: focalPoint + movement,
            pointerCount: 1,
          ),
          context,
        );
        expect(events, isEmpty);
        await handler.onScaleEnd(ScaleEndDetails(), context);

        expect(events, hasLength(1));
        final changed =
            (events.single as ElementsChanged)
                    .elements['degenerate-ink']!
                    .single
                as PenElement;
        for (var index = 0; index < source.points.length; index++) {
          expect(changed.points[index].x, source.points[index].x + movement.dx);
          expect(changed.points[index].y, source.points[index].y + movement.dy);
          expect(changed.points[index].pressure, source.points[index].pressure);
        }
        expect(changed.property.strokeWidth, source.property.strokeWidth);
        expect(handler.selectedRenderers.single.element, changed);
      },
    );
  }

  for (final invalidate in ['resetInput', 'pageChange']) {
    test(
      'a delayed lasso result cannot restore selection after $invalidate',
      () async {
        final bloc = _Bloc(), controller = _Controller(), context = _Context();
        final camera = TransformCubit(1);
        addTearDown(camera.close);
        final handler = SelectHandler(
          SelectTool(mode: .lasso),
          hostManaged: true,
        );
        final oldState = _Success(), nextState = _Success();
        var activeState = oldState;
        when(() => oldState.pageName).thenReturn('old-page');
        when(() => nextState.pageName).thenReturn('new-page');
        when(() => bloc.state).thenAnswer((_) => activeState);
        when(() => bloc.editorController).thenReturn(controller);
        when(() => controller.transformCubit).thenReturn(camera);
        when(() => bloc.refresh(allowBake: any(named: 'allowBake')))
            .thenAnswer((_) async {});
        when(() => context.getCameraTransform()).thenReturn(camera.state);
        when(() => context.getDocumentBloc()).thenReturn(bloc);
        when(() => context.getToolState())
            .thenReturn(ToolRuntimeState(handler: handler));
        when(() => context.getInputState())
            .thenReturn(const EditorInputState());
        when(() => context.getViewState()).thenReturn(const EditorViewState());
        when(() => context.getSettings()).thenReturn(const ButterflySettings());
        when(() => context.isCtrlPressed).thenReturn(false);
        when(() => context.refresh()).thenAnswer((_) async {});
        when(() => context.refreshForegrounds()).thenAnswer((_) async {});
        final raycast = Completer<Set<Renderer<PadElement>>>();
        var requested = false;
        when(
          () => bloc.rayCastPolygon(
            any(),
            useCollection: any(named: 'useCollection'),
            useLayer: any(named: 'useLayer'),
            hitElementMode: any(named: 'hitElementMode'),
          ),
        ).thenAnswer((_) {
          requested = true;
          return raycast.future;
        });
        handler.onScaleStart(
          ScaleStartDetails(localFocalPoint: const Offset(10, 10)),
          context,
        );
        for (final point in [
          const Offset(10, 10),
          const Offset(100, 10),
          const Offset(100, 100),
        ]) {
          handler.onScaleUpdate(
            ScaleUpdateDetails(localFocalPoint: point, pointerCount: 1),
            context,
          );
        }
        final finishing = handler.onScaleEnd(ScaleEndDetails(), context);
        expect(requested, isTrue);
        if (invalidate == 'resetInput') {
          await handler.resetInput(bloc);
        } else {
          activeState = nextState;
          handler.onDocumentUpdated(nextState, oldState);
        }
        expect(handler.selectedRenderers, isEmpty);
        raycast.complete({
          PenRenderer(
            PenElement(id: 'old-page-ink'),
            null,
            const Rect.fromLTWH(20, 20, 10, 10),
            const Rect.fromLTWH(17, 17, 16, 16),
          ),
        });
        await finishing;
        expect(handler.selectedRenderers, isEmpty);
      },
    );
  }
}
