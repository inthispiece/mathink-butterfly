// MathInk integration for Linwood Butterfly; original editor remains AGPL-3.0.
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:butterfly/bloc/document_bloc.dart';
import 'package:butterfly/handlers/handler.dart';
import 'package:butterfly/models/viewport.dart';
import 'package:butterfly/renderers/renderer.dart';
import 'package:butterfly_api/butterfly_api.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'action.dart';

/// Resolve exactly the requested pen IDs. Reject missing IDs and non-ink IDs
/// rather than widening the export to whatever happens to occupy the bounds.
List<Renderer<PadElement>> resolveMathInkPens(
  Iterable<Renderer<PadElement>> renderers,
  List<String> requested,
) {
  final ids = requested.toSet();
  final selected = renderers
      .where(
        (renderer) =>
            renderer.element is PenElement && ids.contains(renderer.element.id),
      )
      .toList();
  if (selected.length != ids.length) {
    throw const FormatException('STALE_SELECTION');
  }
  return selected;
}

ImageExportOptions mathInkImageOptions(Rect bounds) => ImageExportOptions(
  width: bounds.width,
  height: bounds.height,
  x: bounds.left,
  y: bounds.top,
  scale: 1,
  quality: min(2.0, 2048 / max(bounds.width, bounds.height)),
  renderBackground: false,
);

String mathInkRevision(DocumentPage page) => sha256
    .convert(
      utf8.encode(
        jsonEncode(
          page.content
              .whereType<PenElement>()
              .map((ink) => ink.toJson())
              .toList(),
        ),
      ),
    )
    .toString();

/// Correlated host requests. A PNG is rendered from selected pen renderers,
/// never by cropping a screenshot which could include unrelated handwriting.
class MathInkEmbedBridge {
  final BuildContext context;
  final DocumentBloc bloc;
  EventListener? _listener;

  MathInkEmbedBridge(this.context, this.bloc);

  String _revision(DocumentLoadSuccess state) => mathInkRevision(state.page);

  Map<String, dynamic> _map(Object? input) {
    if (input is! Map) throw const FormatException('Expected an object');
    return input.cast<String, dynamic>();
  }

  List<Renderer<PadElement>> _selection(
    DocumentLoadSuccess state,
    Map<String, dynamic> payload,
  ) {
    final expected = payload['revision'];
    if (expected != null && expected != _revision(state)) {
      throw const FormatException('STALE_SELECTION');
    }
    final requested = payload['strokeIds'];
    if (requested is List) {
      return resolveMathInkPens(
        bloc.editorController.rendererCubit.renderers,
        requested.cast<String>(),
      );
    }
    final handler = bloc.editorController.toolCubit.getHandler();
    if (handler is! SelectHandler) return [];
    return handler.selectedRenderers
        .where((renderer) => renderer.element is PenElement)
        .toList();
  }

  Rect _bounds(List<Renderer<PadElement>> selected) {
    Rect? bounds;
    for (final renderer in selected) {
      final rect = renderer.expandedRect;
      if (rect != null) bounds = bounds?.expandToInclude(rect) ?? rect;
    }
    if (bounds == null || bounds.isEmpty) {
      throw const FormatException('EMPTY_SELECTION');
    }
    return bounds.inflate(12);
  }

  Map<String, dynamic> _source(
    DocumentLoadSuccess state,
    List<Renderer<PadElement>> selected,
    Rect bounds,
  ) => {
    'page': state.pageName,
    'revision': _revision(state),
    'strokeIds': selected.map((renderer) => renderer.element.id).toList(),
    'bounds': {
      'x': bounds.left,
      'y': bounds.top,
      'width': bounds.width,
      'height': bounds.height,
    },
  };

  Future<Map<String, dynamic>> _run(
    String method,
    Map<String, dynamic> payload,
  ) async {
    final state = bloc.state;
    if (state is! DocumentLoadSuccess) {
      throw const FormatException('DOCUMENT_NOT_READY');
    }
    switch (method) {
      case 'getSelectedInk':
        final selected = _selection(state, payload);
        return _source(state, selected, _bounds(selected));
      case 'renderSelectedInk':
        final selected = _selection(state, payload);
        final bounds = _bounds(selected);
        final source = _source(state, selected, bounds);
        final png = await bloc.editorController.rendererCubit.render(
          bloc.editorController,
          state.data,
          state.page,
          state.info,
          mathInkImageOptions(bounds),
          cameraViewport: CameraViewport.unbaked(
            unbakedElements: selected,
            visibleElements: selected,
            visibleUnbakedElements: selected,
          ),
          docState: state,
        );
        if (png == null) throw const FormatException('RENDER_FAILED');
        return {
          ...source,
          'pngBase64': base64Encode(
            png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes),
          ),
        };
      case 'insertMath':
        if (bloc.editorController.saveCubit.state.embedding?.editable ==
            false) {
          throw const FormatException('READ_ONLY');
        }
        final latex = payload['latex'];
        if (latex is! String || latex.trim().isEmpty || latex.length > 20000) {
          throw const FormatException('INVALID_LATEX');
        }
        final selected = _selection(state, payload);
        final bounds = _bounds(selected);
        final position = payload['position'] is Map
            ? _map(payload['position'])
            : const <String, dynamic>{};
        final id = createUniqueId();
        final element = PadElement.markdown(
          id: id,
          text: '\$${latex.trim()}\$',
          position: Point<double>(
            (position['x'] as num?)?.toDouble() ?? bounds.left,
            (position['y'] as num?)?.toDouble() ?? bounds.bottom + 24,
          ),
          extra: {
            'mathink': {..._source(state, selected, bounds), 'latex': latex},
          },
        );
        final completed = bloc.stream.firstWhere(
          (next) =>
              next is DocumentLoadSuccess &&
              next.page.content.any((item) => item.id == id),
        );
        bloc.add(ElementsCreated([element]));
        final updated = await completed.timeout(const Duration(seconds: 10));
        return {
          'id': id,
          'revision': _revision(updated as DocumentLoadSuccess),
        };
      case 'getDocument':
        return {
          'data': (await state.saveData()).exportAsBytes().toList(),
          'revision': _revision(state),
          'page': state.pageName,
        };
      case 'locateInk':
        final page = payload['page'];
        if (page is! String || state.data.getPage(page) == null) {
          throw const FormatException('SOURCE_PAGE_MISSING');
        }
        if (page != state.pageName) {
          final changed = bloc.stream.firstWhere(
            (next) => next is DocumentLoadSuccess && next.pageName == page,
          );
          bloc.add(PageChanged(page));
          await changed.timeout(const Duration(seconds: 5));
        }
        final active = bloc.state;
        if (active is! DocumentLoadSuccess) {
          throw const FormatException('DOCUMENT_NOT_READY');
        }
        final pageIds = active.page.content
            .map((element) => element.id)
            .toSet();
        final controller = bloc.editorController;
        // PageChanged emits before the renderer reload finishes. Wait for the
        // new page's renderer set rather than selecting stale page renderers.
        for (var attempt = 0; attempt < 150; attempt++) {
          final renderedIds = controller.rendererCubit.renderers
              .map((renderer) => renderer.element.id)
              .toSet();
          if (renderedIds.length == pageIds.length &&
              renderedIds.containsAll(pageIds)) {
            break;
          }
          if (attempt == 149) {
            throw const FormatException('PAGE_VIEW_NOT_READY');
          }
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        final ids =
            (payload['strokeIds'] as List?)?.cast<String>().toSet() ??
            <String>{};
        final selected = controller.rendererCubit.renderers
            .where(
              (renderer) =>
                  renderer.element is PenElement &&
                  ids.contains(renderer.element.id),
            )
            .toList();
        Rect? bounds;
        if (selected.isNotEmpty) bounds = _bounds(selected);
        final saved = payload['bounds'];
        if (bounds == null && saved is Map) {
          final box = _map(saved);
          bounds = Rect.fromLTWH(
            (box['x'] as num).toDouble(),
            (box['y'] as num).toDouble(),
            (box['width'] as num).toDouble(),
            (box['height'] as num).toDouble(),
          );
        }
        if (bounds == null || bounds.isEmpty) {
          throw const FormatException('SOURCE_INK_MISSING');
        }
        final viewport =
            controller.rendererCubit.state.cameraViewport.viewportSize ??
            MediaQuery.sizeOf(context);
        final scale = min(
          viewport.width / bounds.width,
          viewport.height / bounds.height,
        ).clamp(0.05, 4.0).toDouble();
        controller.transformCubit.teleport(
          bounds.center - viewport.center(Offset.zero) / scale,
          scale,
          0,
        );
        if (controller.saveCubit.state.embedding?.editable != false) {
          final handler = await controller.toolCubit.changeTool(
            controller,
            bloc,
            handler: SelectHandler(SelectTool()),
          );
          if (handler is SelectHandler) {
            handler.selectAll(
              bloc,
              (renderer) =>
                  renderer.element is PenElement &&
                  ids.contains(renderer.element.id),
            );
          }
        }
        return {
          'page': page,
          'revision': _revision(active),
          'foundStrokeIds': selected
              .map((renderer) => renderer.element.id)
              .toList(),
          'sourceMissing': selected.length != ids.length,
        };
      case 'setDocument':
        final raw = payload['data'];
        if (raw is! List) throw const FormatException('INVALID_DOCUMENT');
        final bytes = Uint8List.fromList(
          raw.cast<num>().map((number) => number.toInt()).toList(),
        );
        final document = NoteData.fromData(bytes);
        if (!document.isValid) throw const FormatException('INVALID_DOCUMENT');
        // Reply before routing disposes this handler. The host waits for ready.
        Future.microtask(() {
          if (context.mounted) {
            GoRouter.of(context)
                .go(GoRouterState.of(context).uri.toString(), extra: bytes);
          }
        });
        return {'accepted': true};
      default:
        throw const FormatException('UNKNOWN_METHOD');
    }
  }

  void register() {
    _listener ??= onEmbedMessage('mathink', (message) async {
      String? requestId;
      String? method;
      try {
        final request = _map(message);
        requestId = request['requestId'] as String?;
        method = request['method'] as String?;
        if (requestId == null || method == null) {
          throw const FormatException('INVALID_REQUEST');
        }
        final result = await _run(method, _map(request['payload'] ?? {}));
        sendEmbedMessage('mathink', {
          'requestId': requestId,
          'method': method,
          'ok': true,
          'result': result,
        });
      } catch (error) {
        sendEmbedMessage('mathink', {
          'requestId': requestId,
          'method': method,
          'ok': false,
          'error': error is FormatException ? error.message : 'BRIDGE_FAILED',
        });
      }
    });
    sendEmbedMessage('mathinkReady', {'version': 1});
  }

  void unregister() {
    if (_listener != null) removeEmbedMessageListener(_listener!);
    _listener = null;
  }
}
