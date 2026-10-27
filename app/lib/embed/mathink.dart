// MathInk integration for Linwood Butterfly; original editor remains AGPL-3.0.
import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:butterfly/bloc/document_bloc.dart';
import 'package:butterfly/cubits/settings.dart';
import 'package:butterfly/cubits/editor_controller.dart';
import 'package:butterfly/cubits/transform.dart';
import 'package:butterfly/handlers/handler.dart';
import 'package:butterfly/models/viewport.dart';
import 'package:butterfly/renderers/renderer.dart';
import 'package:butterfly/services/asset.dart';
import 'package:butterfly_api/butterfly_api.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:go_router/go_router.dart';

import 'action.dart';
import 'mathink_navigation.dart';

final _mathInkBridges = Expando<MathInkEmbedBridge>();
MathInkEmbedBridge? mathInkHostBridge(DocumentBloc bloc) =>
    _mathInkBridges[bloc];

Rect mathInkPageGeometry(DocumentPage page) =>
    mathInkPaperRect(mathInkPageMetadata(page)['geometry']);

/// Build a new archive transaction without touching the live editor or history.
NoteData mathInkPreparePdfPages(
  NoteData original,
  List<Map<String, dynamic>> pages, {
  int? index,
  String? afterPage,
  bool replaceEmptyFirst = false,
}) {
  if (pages.isEmpty || pages.length > 300) {
    throw const FormatException('INVALID_PDF_PAGE_COUNT');
  }
  var data = mathInkEnsurePageIds(original);
  final existing = mathInkPageDirectory(data);
  if (index != null && (index < 0 || index > existing.length)) {
    throw const FormatException('INVALID_PAGE_INDEX');
  }
  final ids = existing.map((p) => p['id']).toSet();
  for (final spec in pages) {
    final id = spec['id'];
    if (id is! String || id.isEmpty || id.length > 160 || !ids.add(id)) {
      throw const FormatException('INVALID_PAGE_ID');
    }
    mathInkPaperRect(spec);
  }
  var rank =
      index ??
      (afterPage == null
          ? existing.length
          : existing.indexWhere((p) => p['id'] == afterPage) + 1);
  if (index == null && afterPage != null && rank == 0) {
    throw const FormatException('SOURCE_PAGE_MISSING');
  }
  String? remove;
  if (replaceEmptyFirst) {
    if (existing.length != 1) throw const FormatException('NOT_EMPTY_NOTEBOOK');
    final page = data.getPage(existing.first['name'] as String)!;
    if (page.content.isNotEmpty || page.extra['mathinkPdf'] != null) {
      throw const FormatException('NOT_EMPTY_NOTEBOOK');
    }
    remove = existing.first['id'] as String;
    rank = 0;
  }
  for (final spec in pages) {
    final geometry = mathInkPaperRect(spec);
    final page = DocumentPage(
      backgrounds: mathInkPaperBackgrounds('blank'),
      layers: [DocumentLayer(id: createUniqueId())],
      extra: {
        'mathinkPage': {
          'id': spec['id'],
          'paper': 'blank',
          'aliases': <String>[],
          'geometry': {'width': geometry.width, 'height': geometry.height},
        },
        'mathinkPdf': {
          'resourceId': spec['resourceId'],
          'pageIndex': spec['pageIndex'],
          'rotation': spec['rotation'] ?? 0,
        },
      },
    );
    data = data
        .setPage(
          page,
          spec['id'] as String,
          mathInkInsertionIndex(data, rank++),
        )
        .$1;
  }
  if (remove != null) {
    final raw = mathInkResolvePage(data, remove, includeDeleted: true)!;
    data = data.removePage(raw);
  }
  return data;
}

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

/// Never silently turn a mixed visual selection into a smaller OCR request.
List<Renderer<PadElement>> mathInkSelectedPens(
  Iterable<Renderer<PadElement>> selection,
) {
  final selected = selection.toList();
  if (selected.any((renderer) => renderer.element is! PenElement)) {
    final onlyMath = selected.every(
      (renderer) =>
          renderer.element is MarkdownElement &&
          renderer.element.extra['mathink'] is Map,
    );
    throw FormatException(onlyMath ? 'FORMULA_SELECTION' : 'MIXED_SELECTION');
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

/// Whole-page transcription also depends on text, images and layout.
/// Keep the ink-only revision above stable for existing formula links.
String mathInkPageRevision(DocumentPage page) {
  final json = page.toJson();
  // Navigation, operation receipts and stable identity do not alter source ink.
  json['extra'] = Map<String, dynamic>.from(page.extra)
    ..remove('mathinkPage')
    ..remove('mathinkOperations');
  return sha256.convert(utf8.encode(jsonEncode(json))).toString();
}

Map<String, dynamic> mathInkPageMetadata(DocumentPage page) =>
    page.extra['mathinkPage'] is Map
    ? Map<String, dynamic>.from(page.extra['mathinkPage'] as Map)
    : <String, dynamic>{};

String mathInkStablePageId(DocumentPage page, String rawName) =>
    mathInkPageMetadata(page)['id'] as String? ?? rawName;

bool mathInkPageDeleted(DocumentPage page) =>
    mathInkPageMetadata(page)['deleted'] == true;

String mathInkPaper(DocumentPage page) {
  final paper = mathInkPageMetadata(page)['paper'];
  if (['blank', 'lined', 'grid'].contains(paper)) return paper as String;
  for (final background in page.backgrounds) {
    if (background is TextureBackground &&
        background.texture is PatternTexture) {
      final texture = background.texture as PatternTexture;
      if (texture.boxHeight > 0 && texture.boxWidth > 0) return 'grid';
      if (texture.boxHeight > 0) return 'lined';
    }
  }
  return 'blank';
}

List<Background> mathInkPaperBackgrounds(String paper) {
  final template = switch (paper) {
    'blank' => PatternTemplate.plain,
    'lined' => PatternTemplate.ruled,
    'grid' => PatternTemplate.quad,
    _ => throw const FormatException('INVALID_PAPER'),
  };
  return [Background.texture(texture: template.create())];
}

/// Enumerates the archive, never the subset previously visited by the host.
List<Map<String, dynamic>> mathInkPageDirectory(NoteData data) {
  return data.getPages(true).indexed.map((entry) {
    final (index, name) = entry;
    final page = data.getPage(name);
    if (page == null) throw const FormatException('INVALID_NATIVE_PAGE');
    return <String, dynamic>{
      'id': mathInkStablePageId(page, name),
      'name': name,
      'title': name.replaceFirst(RegExp(r'^\d+\.'), ''),
      'index': index,
      'paper': mathInkPaper(page),
      'deleted': mathInkPageDeleted(page),
      'revision': mathInkRevision(page),
      'pageRevision': mathInkPageRevision(page),
      'geometry': {
        'width': mathInkPageGeometry(page).width,
        'height': mathInkPageGeometry(page).height,
      },
      if (page.extra['mathinkPdf'] is Map) 'pdf': page.extra['mathinkPdf'],
    };
  }).toList();
}

NoteData mathInkEnsurePageIds(NoteData data) {
  final seen = <String>{};
  for (final name in data.getPages(true)) {
    final page = data.getPage(name);
    if (page == null) throw const FormatException('INVALID_NATIVE_PAGE');
    final id = mathInkStablePageId(page, name);
    if (!seen.add(id)) throw const FormatException('DUPLICATE_PAGE_ID');
    final metadata = mathInkPageMetadata(page);
    if (metadata['id'] == null) {
      data = data
          .setPage(
            page.copyWith(
              extra: {
                ...page.extra,
                'mathinkPage': {
                  ...metadata,
                  'id': id,
                  'aliases': [name],
                },
              },
            ),
            name,
          )
          .$1;
    }
  }
  return data;
}

String? mathInkResolvePage(
  NoteData data,
  String id, {
  bool includeDeleted = false,
}) {
  // Stable IDs take priority over current ordinal file names, which can be
  // reused by another page after a native reorder.
  for (final name in data.getPages(true)) {
    final page = data.getPage(name)!;
    if (mathInkStablePageId(page, name) == id) {
      return includeDeleted || !mathInkPageDeleted(page) ? name : null;
    }
  }
  return null;
}

DocumentPage mathInkClonePage(DocumentPage original, String id) =>
    original.copyWith(
      layers: original.layers
          .map(
            (layer) => layer.copyWith(
              id: createUniqueId(),
              content: layer.content
                  .map(
                    (e) => PadElement.fromJson({
                      ...e.toJson(),
                      'id': createUniqueId(),
                    }),
                  )
                  .toList(),
            ),
          )
          .toList(),
      extra: {
        ...original.extra,
        'mathinkPage': {
          'id': id,
          'aliases': <String>[],
          'paper': mathInkPaper(original),
          if (mathInkPageMetadata(original)['geometry'] != null)
            'geometry': mathInkPageMetadata(original)['geometry'],
        },
        'mathinkOperations': <String, dynamic>{},
      },
    );

/// Native filenames can have gaps after deletion/reordering. Host positions
/// are ordinal ranks, whereas the native API accepts the numeric prefix.
int mathInkInsertionIndex(NoteData data, int rank) {
  final pages = data.getPages(true);
  if (rank < 0 || rank > pages.length) {
    throw const FormatException('INVALID_PAGE_INDEX');
  }
  if (rank == pages.length) {
    return pages.isEmpty ? 0 : (data.getPageIndex(pages.last) ?? 0) + 1;
  }
  return data.getPageIndex(pages[rank]) ?? rank;
}

List<Renderer<PadElement>> mathInkPageRenderers(
  Iterable<Renderer<PadElement>> renderers,
) {
  final all = renderers.toList();
  if (all.any((renderer) => renderer.expandedRect == null)) {
    throw const FormatException('PAGE_CONTENT_NOT_READY');
  }
  return all;
}

List<String> mathInkAffectedPages(NoteData before, NoteData after) {
  Map<String, String> catalog(NoteData document) => {
    for (final page in mathInkPageDirectory(document))
      page['id'] as String: jsonEncode([
        page['index'],
        page['deleted'],
        page['pageRevision'],
      ]),
  };
  final previous = catalog(before), current = catalog(after);
  return {
    ...previous.keys,
    ...current.keys,
  }.where((id) => previous[id] != current[id]).toList();
}

/// Correlated host requests. A PNG is rendered from selected pen renderers,
/// never by cropping a screenshot which could include unrelated handwriting.
class MathInkEmbedBridge {
  final BuildContext context;
  final DocumentBloc bloc;
  EventListener? _listener;
  Future<void> _requestQueue = Future.value();
  final Map<String, Map<String, dynamic>> _operationReceipts = {};
  String? _noteId, _selectionSignature;
  int _selectionGeneration = 0;
  SelectHandler? _observedSelection;
  StreamSubscription? _toolSubscription;
  StreamSubscription? _viewSubscription, _viewportSubscription;
  String? _hostSession, _hostPage;
  Rect _geometry = const Rect.fromLTWH(0, 0, 1000, 1414);
  bool _navigationLocked = true, _allowSwipe = false, _fingerWriting = false;
  String _hostTool = 'pen';
  Tool? _hostSelectedTool;
  int _hostGeneration = 0;
  final Set<int> _hostPointers = {};
  final MathInkPageGesture _pageGesture = MathInkPageGesture();
  Map<String, dynamic>? _viewAtDown;
  Size? _lastViewport;
  bool _settingHostView = false, _autoFitWidth = false;
  String? _fitSignature;
  int? _tapPointer;
  Offset? _tapStart, _lastTap;
  Duration? _tapBegan, _lastTapTime;
  bool _tapBlocked = true;
  String? _pdfPage;
  ImageBackgroundRenderer? _pdfBackground;
  PenElement? _pendingMouseDot;
  String? _pendingDotPage;
  Offset? _pendingDotPosition;
  Duration? _pendingDotTime;
  int? _doubleClickPointer;
  Timer? _mouseDotTimer;

  MathInkEmbedBridge(this.context, this.bloc);

  bool get hostInteractionReady {
    final state = bloc.state;
    return state is DocumentLoadSuccess &&
        _hostSession != null &&
        _hostPage == _pageId(state);
  }

  Size get _viewportSize {
    final measured =
        _lastViewport ??
        bloc.editorController.rendererCubit.state.cameraViewport.viewportSize;
    if (measured != null && measured.width > 0 && measured.height > 0) {
      return measured;
    }
    return MediaQuery.sizeOf(context);
  }

  Map<String, dynamic> _hostEvent([Map<String, dynamic> extra = const {}]) => {
    'noteId': _noteId,
    'pageId': _hostPage,
    'sessionId': _hostSession,
    'generation': _hostGeneration,
    'view': _view(),
    'geometry': {'width': _geometry.width, 'height': _geometry.height},
    'viewport': {'width': _viewportSize.width, 'height': _viewportSize.height},
    'busy': _hostPointers.isNotEmpty,
    'tool': switch (bloc.editorController.toolCubit.getHandler().data) {
      PenTool() => 'pen',
      EraserTool() => 'eraser',
      SelectTool() => 'lasso',
      HandTool() => 'pan',
      _ => 'other',
    },
    ...extra,
  };

  void _emitHost(String name, [Map<String, dynamic> extra = const {}]) {
    if (!hostInteractionReady) return;
    _hostGeneration++;
    sendEmbedMessage(name, _hostEvent(extra));
  }

  void _clampView() {
    if (!hostInteractionReady || _settingHostView) return;
    final cubit = bloc.editorController.transformCubit, view = cubit.state;
    final size = _viewportSize,
        width = size.width / view.size,
        height = size.height / view.size;
    final x = _geometry.width <= width
        ? (_geometry.width - width) / 2
        : view.position.dx.clamp(0.0, _geometry.width - width);
    final y = _geometry.height <= height
        ? (_geometry.height - height) / 2
        : view.position.dy.clamp(
            -24 / view.size,
            _geometry.height - height + 24 / view.size,
          );
    if ((x - view.position.dx).abs() > .01 ||
        (y - view.position.dy).abs() > .01 ||
        view.rotation != 0) {
      _settingHostView = true;
      cubit.teleport(Offset(x.toDouble(), y.toDouble()), view.size, 0);
      _settingHostView = false;
    }
  }

  Map<String, dynamic> _fitHostPage(String mode) {
    if (!['width', '100'].contains(mode)) {
      throw const FormatException('INVALID_FIT_MODE');
    }
    final state = _state;
    final paper = hostInteractionReady
        ? _geometry
        : mathInkPageGeometry(state.page);
    final fitted = mathInkFitView(
      paper,
      _viewportSize,
      widthOnly: mode == 'width',
    );
    _autoFitWidth = mode == 'width';
    _settingHostView = true;
    bloc.editorController.transformCubit.teleport(
      fitted.position,
      fitted.zoom,
      0,
    );
    _fitSignature = jsonEncode(_view());
    _settingHostView = false;
    _emitHost('mathinkViewChanged');
    return _view();
  }

  void hostPointerDown(PointerDownEvent event, Size viewport) {
    if (!hostInteractionReady) return;
    _lastViewport = viewport;
    if (_pendingMouseDot != null) {
      if (event.kind == PointerDeviceKind.mouse &&
          _pendingDotPage == _pageId(_state) &&
          _pendingDotPosition != null &&
          _pendingDotTime != null &&
          (event.localPosition - _pendingDotPosition!).distance < 24 &&
          (event.timeStamp - _pendingDotTime!).inMilliseconds < 350) {
        _mouseDotTimer?.cancel();
        _mouseDotTimer = null;
        _pendingMouseDot = null;
        _doubleClickPointer = event.pointer;
      } else {
        unawaited(_flushMouseDot());
      }
    }
    _hostPointers.add(event.pointer);
    if (_hostPointers.length == 1) _viewAtDown = _view();
    final camera = bloc.editorController.transformCubit.state;
    _pageGesture.down(
      event,
      paper: _geometry,
      viewport: viewport,
      camera: camera.position,
      zoom: camera.size,
      allowed:
          _allowSwipe &&
          !_navigationLocked &&
          !_fingerWriting &&
          _hostTool == 'pan',
      pointerCount: _hostPointers.length,
    );
    if (_hostPointers.length == 1 &&
        !_navigationLocked &&
        !_fingerWriting &&
        (event.kind == PointerDeviceKind.touch ||
            event.kind == PointerDeviceKind.mouse &&
                ['pan', 'pen'].contains(_hostTool)) &&
        _hostTool != 'lasso') {
      _tapPointer = event.pointer;
      _tapStart = event.localPosition;
      _tapBegan = event.timeStamp;
      _tapBlocked = false;
    } else {
      _tapBlocked = true;
      _lastTap = null;
      _lastTapTime = null;
    }
    _emitHost('mathinkInputState');
  }

  void hostPointerMove(PointerMoveEvent event) {
    if (_tapPointer == event.pointer &&
        _tapStart != null &&
        (event.localPosition - _tapStart!).distance > 12) {
      _tapBlocked = true;
    }
  }

  void hostPointerUp(PointerUpEvent event) {
    if (!hostInteractionReady) return;
    final direction = _navigationLocked ? null : _pageGesture.up(event);
    _hostPointers.remove(event.pointer);
    if (direction != null && _viewAtDown != null) {
      _settingHostView = true;
      _setView(_viewAtDown!);
      _settingHostView = false;
    }
    if (!_tapBlocked &&
        _hostPointers.isEmpty &&
        _tapPointer == event.pointer &&
        _tapBegan != null &&
        (event.timeStamp - _tapBegan!).inMilliseconds < 400) {
      final world = bloc.editorController.transformCubit.state.localToGlobal(
        event.localPosition,
      );
      final empty = !bloc.editorController.rendererCubit.renderers.any(
        (r) => r.expandedRect?.contains(world) ?? true,
      );
      if (empty &&
          _lastTap != null &&
          _lastTapTime != null &&
          (event.timeStamp - _lastTapTime!).inMilliseconds < 350 &&
          (event.localPosition - _lastTap!).distance < 24) {
        _fitHostPage('100');
        _lastTap = null;
        _lastTapTime = null;
      } else if (empty) {
        _lastTap = event.localPosition;
        _lastTapTime = event.timeStamp;
      }
    }
    _emitHost('mathinkInputState');
    if (direction != null) {
      _emitHost('mathinkPageIntent', {
        'direction': direction,
        'gestureGeneration': _pageGesture.generation,
      });
    }
    if (_hostPointers.isEmpty) {
      _pageGesture.reset();
      _viewAtDown = null;
    }
  }

  void hostPointerCancel(PointerEvent event) {
    _hostPointers.remove(event.pointer);
    _pageGesture.cancel();
    _tapBlocked = true;
    _lastTap = null;
    _lastTapTime = null;
    _emitHost('mathinkInputState');
  }

  /// Only mouse dots on non-interactive blank paper wait for a possible
  /// double click. Real pens and actual mouse strokes keep their usual timing.
  bool deferMouseDot(PointerUpEvent event, Handler handler) {
    if (!hostInteractionReady ||
        event.kind != PointerDeviceKind.mouse ||
        handler is! PenHandler ||
        _hostTool != 'pen') {
      return false;
    }
    if (_doubleClickPointer == event.pointer) {
      handler.detachUnsubmittedPointer(event.pointer);
      _doubleClickPointer = null;
      _lastTap = null;
      _lastTapTime = null;
      _fitHostPage('100');
      unawaited(bloc.refresh(allowBake: false));
      return true;
    }
    final candidate = handler.elements[event.pointer];
    final position = bloc.editorController.transformCubit.state.localToGlobal(
      event.localPosition,
    );
    final blank = !bloc.editorController.rendererCubit.renderers.any(
      (r) => r.expandedRect?.contains(position) ?? true,
    );
    if (_navigationLocked ||
        _fingerWriting ||
        _tapBlocked ||
        candidate == null ||
        candidate.points.length != 1 ||
        !blank) {
      return false;
    }
    final dot = handler.detachUnsubmittedPointer(event.pointer);
    if (dot == null) return false;
    _pendingMouseDot = dot;
    _pendingDotPage = _pageId(_state);
    _pendingDotPosition = event.localPosition;
    _pendingDotTime = event.timeStamp;
    _mouseDotTimer?.cancel();
    _mouseDotTimer = Timer(
      const Duration(milliseconds: 250),
      () => unawaited(_flushMouseDot()),
    );
    return true;
  }

  Future<void> _flushMouseDot() async {
    final dot = _pendingMouseDot, page = _pendingDotPage;
    _mouseDotTimer?.cancel();
    _mouseDotTimer = null;
    _pendingMouseDot = null;
    if (dot == null) return;
    final state = bloc.state;
    if (state is! DocumentLoadSuccess || _pageId(state) != page) return;
    final completed = bloc.stream.firstWhere(
      (s) =>
          s is DocumentLoadSuccess && s.page.content.any((e) => e.id == dot.id),
    );
    bloc.add(ElementsCreated([dot]));
    await completed.timeout(const Duration(seconds: 10));
  }

  String _revision(DocumentLoadSuccess state) => mathInkRevision(state.page);

  DocumentLoadSuccess get _state {
    final current = bloc.state;
    if (current is! DocumentLoadSuccess) {
      throw const FormatException('DOCUMENT_NOT_READY');
    }
    return current;
  }

  String _pageId(DocumentLoadSuccess state) =>
      mathInkStablePageId(state.page, state.pageName);

  void _bindSelectionNote(Map<String, dynamic> payload) {
    final note = payload['noteId'];
    if (note == null) return;
    if (note is! String || note.isEmpty || note.length > 160) {
      throw const FormatException('INVALID_NOTE');
    }
    if (_noteId != null && note != _noteId) {
      throw const FormatException('NOTE_MISMATCH');
    }
    _noteId = note;
  }

  Map<String, dynamic> _selectionState() {
    final current = _state;
    final handler = bloc.editorController.toolCubit.getHandler();
    final selected = handler is SelectHandler
        ? handler.selectedRenderers
        : <Renderer<PadElement>>[];
    final bounds = handler is SelectHandler ? handler.getSelectionRect() : null;
    final signature = jsonEncode([
      _noteId,
      _pageId(current),
      mathInkPageRevision(current.page),
      handler is SelectHandler ? 'lasso' : 'other',
      handler is SelectHandler ? handler.selectionEpoch : 0,
      selected.map((renderer) => renderer.element.toJson()).toList(),
    ]);
    if (signature != _selectionSignature) {
      _selectionSignature = signature;
      _selectionGeneration++;
    }
    return {
      'noteId': _noteId,
      'pageId': _pageId(current),
      'objectIds': selected.map((r) => r.element.id).nonNulls.toList(),
      'inkIds': selected
          .where((r) => r.element is PenElement)
          .map((r) => r.element.id)
          .nonNulls
          .toList(),
      'mathIds': selected
          .where(
            (r) =>
                r.element is MarkdownElement &&
                r.element.extra['mathink'] is Map,
          )
          .map((r) => r.element.id)
          .nonNulls
          .toList(),
      'otherIds': selected
          .where(
            (r) =>
                r.element is! PenElement &&
                !(r.element is MarkdownElement &&
                    r.element.extra['mathink'] is Map),
          )
          .map((r) => r.element.id)
          .nonNulls
          .toList(),
      'bounds': bounds == null
          ? null
          : {
              'x': bounds.left,
              'y': bounds.top,
              'width': bounds.width,
              'height': bounds.height,
            },
      'revision': mathInkPageRevision(current.page),
      'inkRevision': _revision(current),
      'generation': _selectionGeneration,
      'tool': handler is SelectHandler ? 'lasso' : 'other',
    };
  }

  void _emitSelection() {
    try {
      final previous = _selectionGeneration;
      final selection = _selectionState();
      if (previous != _selectionGeneration) {
        sendEmbedMessage('mathinkSelectionChanged', selection);
      }
    } on FormatException {
      // A disposed/rebuilding document has no transferable selection.
    }
  }

  void _observeSelection(SelectHandler handler) {
    if (_observedSelection != handler) {
      _observedSelection?.mathInkSelectionChanged = null;
      _observedSelection = handler;
      handler.mathInkSelectionChanged = _emitSelection;
    }
  }

  void _validateSelectionToken(Map<String, dynamic> payload) {
    _bindSelectionNote(payload);
    final selection = _selectionState();
    final page = payload['pageId'] ?? payload['page'];
    if (page != null && page != selection['pageId'] ||
        payload['generation'] != null &&
            payload['generation'] != selection['generation']) {
      throw const FormatException('STALE_SELECTION');
    }
  }

  Future<void> _waitRenderers() async {
    await bloc.waitForStateEffects();
    for (var attempt = 0; attempt < 150; attempt++) {
      final active = _state;
      final expected = {
        for (final e in active.page.content) e.id: jsonEncode(e.toJson()),
      };
      final actual = {
        for (final r in bloc.editorController.rendererCubit.renderers)
          r.element.id: jsonEncode(r.element.toJson()),
      };
      if (expected.length == actual.length &&
          expected.entries.every((e) => actual[e.key] == e.value)) {
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    throw const FormatException('PAGE_VIEW_NOT_READY');
  }

  Future<void> _replaceData(NoteData data) async {
    final token = createUniqueId();
    final tagged = data.setAsset(
      'MATHINK/bridge-operation.txt',
      utf8.encode(token),
    );
    final completed = bloc.stream.firstWhere(
      (next) =>
          next is DocumentLoadSuccess &&
          utf8.decode(
                next.data.getAsset('MATHINK/bridge-operation.txt') ?? [],
              ) ==
              token,
    );
    bloc.add(DocumentRebuilt(tagged.exportAsBytes()));
    await completed.timeout(const Duration(seconds: 10));
    await _waitRenderers();
  }

  Future<void> _ensureIds() async {
    final state = _state;
    final data = await state.saveData();
    final normalized = mathInkEnsurePageIds(data);
    for (final name in normalized.getPages(true)) {
      final page = normalized.getPage(name)!;
      final id = mathInkStablePageId(page, name);
      final receipts = page.extra['mathinkOperations'] is Map
          ? Map<String, dynamic>.from(page.extra['mathinkOperations'] as Map)
          : <String, dynamic>{};
      final known = _operationReceipts.putIfAbsent(id, () => {});
      known.addAll(receipts);
    }
    if (data
        .getPages(true)
        .every(
          (name) => mathInkPageMetadata(data.getPage(name)!)['id'] != null,
        )) {
      return;
    }
    if (bloc.state != state) throw const FormatException('SOURCE_PAGE_CHANGED');
    await _replaceData(normalized);
  }

  /// Bookkeeping is exported into an immutable archive copy. It must not add
  /// DocumentRebuilt entries to the user's native undo/redo timeline.
  Future<NoteData> _savedDocument() async {
    var saved = await _state.saveData();
    for (final name in saved.getPages(true)) {
      final page = saved.getPage(name)!;
      final known = _operationReceipts[mathInkStablePageId(page, name)];
      if (known == null || known.isEmpty) continue;
      final receipts = page.extra['mathinkOperations'] is Map
          ? Map<String, dynamic>.from(page.extra['mathinkOperations'] as Map)
          : <String, dynamic>{};
      receipts.addAll(known);
      saved = saved
          .setPage(
            page.copyWith(
              extra: {...page.extra, 'mathinkOperations': receipts},
            ),
            name,
          )
          .$1;
    }
    return saved;
  }

  Future<void> _switch(String id) async {
    await _ensureIds();
    final current = _state;
    final name = mathInkResolvePage(current.data, id);
    if (name == null) throw const FormatException('SOURCE_PAGE_MISSING');
    if (name != current.pageName) {
      await bloc.editorController.toolCubit.resetInput(
        bloc,
        bloc.editorController.inputCubit,
      );
      final changed = bloc.stream.firstWhere(
        (next) => next is DocumentLoadSuccess && next.pageName == name,
      );
      bloc.add(PageChanged(name));
      await changed.timeout(const Duration(seconds: 10));
    }
    await _waitRenderers();
  }

  Map<String, dynamic> _view() {
    final view = bloc.editorController.transformCubit.state;
    return {'x': view.position.dx, 'y': view.position.dy, 'zoom': view.size};
  }

  Future<void> _activateHostTool(Tool tool, String name) async {
    final controller = bloc.editorController;
    final previous = controller.toolCubit.getHandler();
    if (name == 'lasso' &&
        previous is SelectHandler &&
        previous.hostManaged &&
        previous.data.mode == .lasso) {
      _observeSelection(previous);
    } else {
      if (previous is SelectHandler) previous.clearSelection(bloc);
      final next = name == 'lasso'
          ? SelectHandler(tool as SelectTool, hostManaged: true)
          : Handler.fromTool(tool);
      if (next is SelectHandler) _observeSelection(next);
      await controller.toolCubit.changeTool(controller, bloc, handler: next);
    }
    _hostTool = name;
    _hostSelectedTool = tool;
    if (name != 'pan') _pageGesture.cancel();
    final input = controller.inputCubit;
    if (controller.saveCubit.state.embedding?.fullScreen.queryValue ==
            'forced' &&
        input.state.hideUi != .keyboard) {
      if (input.state.hideUi == .touch) input.exitHideUI();
      input.toggleKeyboardHideUI();
    }
    _emitSelection();
  }

  void _setView(Map<String, dynamic> payload) {
    final x = payload['x'], y = payload['y'], zoom = payload['zoom'];
    if (x is! num ||
        y is! num ||
        zoom is! num ||
        !x.isFinite ||
        !y.isFinite ||
        !zoom.isFinite ||
        x.abs() > 10000000 ||
        y.abs() > 10000000 ||
        zoom < .1 ||
        zoom > 10) {
      throw const FormatException('INVALID_VIEW');
    }
    bloc.editorController.transformCubit.teleport(
      Offset(x.toDouble(), y.toDouble()),
      zoom.toDouble(),
      0,
    );
  }

  Map<String, dynamic> _pageState() {
    final current = _state;
    return {
      'page': _pageId(current),
      'nativeName': current.pageName,
      'revision': _revision(current),
      'pageRevision': mathInkPageRevision(current.page),
      'view': _view(),
    };
  }

  Future<void> _reorder(List<String> order) async {
    for (var index = 0; index < order.length; index++) {
      final current = _state;
      final real = mathInkResolvePage(
        current.data,
        order[index],
        includeDeleted: true,
      )!;
      if (current.data.getPages(true).indexOf(real) == index) continue;
      final completed = bloc.stream.firstWhere(
        (next) =>
            next is DocumentLoadSuccess &&
            mathInkPageDirectory(next.data)[index]['id'] == order[index],
      );
      bloc.add(PageReordered(real, mathInkInsertionIndex(current.data, index)));
      await completed.timeout(const Duration(seconds: 10));
    }
    await _waitRenderers();
  }

  Map<String, dynamic> _map(Object? input) {
    if (input is! Map) throw const FormatException('Expected an object');
    return input.cast<String, dynamic>();
  }

  List<Renderer<PadElement>> _selection(
    DocumentLoadSuccess state,
    Map<String, dynamic> payload,
  ) {
    _validateSelectionToken(payload);
    final expected = payload['revision'];
    if (expected != null && expected != _revision(state)) {
      throw const FormatException('STALE_SELECTION');
    }
    final handler = bloc.editorController.toolCubit.getHandler();
    final actual = handler is SelectHandler
        ? mathInkSelectedPens(handler.selectedRenderers)
        : <Renderer<PadElement>>[];
    final requested = payload['strokeIds'];
    if (requested is List) {
      return resolveMathInkPens(
        bloc.editorController.rendererCubit.renderers,
        requested.cast<String>(),
      );
    }
    return actual;
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
    'page': _pageId(state),
    'revision': _revision(state),
    'strokeIds': selected.map((renderer) => renderer.element.id).toList(),
    'bounds': {
      'x': bounds.left,
      'y': bounds.top,
      'width': bounds.width,
      'height': bounds.height,
    },
  };

  Future<Map<String, dynamic>> _renderFrozen(
    NoteData data,
    String id,
    Map<String, dynamic> payload, {
    Background? presentation,
  }) async {
    final name = mathInkResolvePage(data, id);
    if (name == null) throw const FormatException('SOURCE_PAGE_MISSING');
    var page = data.getPage(name)!;
    final canonical = page, geometry = mathInkPageGeometry(page);
    final annotationsOnly = payload['annotationsOnly'] == true;
    if (annotationsOnly) {
      page = page.copyWith(backgrounds: []);
    } else if (presentation != null) {
      page = page.copyWith(backgrounds: [presentation]);
    }
    final assets = AssetService(), transform = TransformCubit(1);
    EditorController? controller;
    List<Renderer<Background>> backgrounds = [];
    try {
      final viewport = await CameraViewport.build(
        transform,
        data,
        assets,
        page,
      );
      backgrounds = viewport.backgrounds;
      controller = EditorController(
        bloc.editorController.settingsCubit,
        transform,
        viewport,
      );
      final loaded = DocumentLoadSuccess(
        data,
        page: page,
        pageName: name,
        fileSystem: _state.fileSystem,
        windowCubit: _state.windowCubit,
        assetService: assets,
        info: data.getInfo() ?? _state.info,
      );
      final all = mathInkPageRenderers(viewport.unbakedElements);
      Rect bounds = geometry;
      if (payload['bounds'] is Map) {
        final value = _map(payload['bounds']);
        final x = value['x'],
            y = value['y'],
            width = value['width'],
            height = value['height'];
        if ([x, y, width, height].any((n) => n is! num || !n.isFinite) ||
            (width as num) <= 0 ||
            (height as num) <= 0) {
          throw const FormatException('INVALID_RENDER_BOUNDS');
        }
        bounds = Rect.fromLTWH(
          (x as num).toDouble(),
          (y as num).toDouble(),
          width.toDouble(),
          height.toDouble(),
        );
      } else {
        for (final r in all) {
          final rect = r.expandedRect!;
          bounds = bounds.expandToInclude(rect.inflate(12));
        }
      }
      final quality = payload['quality'] ?? 2.0,
          maxDimension =
              payload['maxDimension'] ??
              (payload['quality'] == null ? 2048 : 8192);
      if (quality is! num ||
          !quality.isFinite ||
          quality <= 0 ||
          quality > 4 ||
          maxDimension is! num ||
          !maxDimension.isFinite ||
          maxDimension < 32 ||
          maxDimension > 8192 ||
          bounds.width > 100000 ||
          bounds.height > 100000) {
        throw const FormatException('INVALID_RENDER_QUALITY');
      }
      final scale = min(
        quality.toDouble(),
        min(
          maxDimension / max(bounds.width, bounds.height),
          sqrt(32000000 / (bounds.width * bounds.height)),
        ),
      );
      final png = await controller.rendererCubit.render(
        controller,
        data,
        page,
        loaded.info,
        ImageExportOptions(
          width: bounds.width,
          height: bounds.height,
          x: bounds.left,
          y: bounds.top,
          scale: 1,
          quality: scale,
          renderBackground: !annotationsOnly,
        ),
        cameraViewport: viewport,
        docState: loaded,
      );
      if (png == null) throw const FormatException('RENDER_FAILED');
      final bytes = png.buffer.asUint8List(
            png.offsetInBytes,
            png.lengthInBytes,
          ),
          header = ByteData.sublistView(bytes),
          encoded = base64Encode(bytes);
      final revision = mathInkPageRevision(canonical);
      return {
        'page': id,
        'revision': revision,
        'fullRevision': revision,
        'inkRevision': mathInkRevision(canonical),
        'strokeIds': all
            .where((r) => r.element is PenElement)
            .map((r) => r.element.id)
            .toList(),
        'bounds': {
          'x': bounds.left,
          'y': bounds.top,
          'width': bounds.width,
          'height': bounds.height,
        },
        'transform': {
          'offsetX': bounds.left,
          'offsetY': bounds.top,
          'scaleX': header.getUint32(16) / bounds.width,
          'scaleY': header.getUint32(20) / bounds.height,
        },
        'geometry': {'width': geometry.width, 'height': geometry.height},
        'contentEmpty':
            all.isEmpty &&
            (annotationsOnly ||
                canonical.extra['mathinkPdf'] == null && presentation == null),
        'pngBase64': encoded,
        'imageBase64': encoded,
        'imageUrl': 'data:image/png;base64,$encoded',
      };
    } finally {
      await controller?.close();
      for (final renderer in backgrounds) {
        renderer.dispose();
      }
      await assets.dispose();
      await transform.close();
    }
  }

  Future<void> _setPdfPresentation(Map<String, dynamic> payload) async {
    _bindSelectionNote(payload);
    final state = _state, id = payload['page'];
    if (id != _pageId(state)) {
      throw const FormatException('SOURCE_PAGE_CHANGED');
    }
    final geometry = mathInkPaperRect(payload), encoded = payload['pngBase64'];
    if (encoded is! String || encoded.length > 48000000) {
      throw const FormatException('INVALID_PDF_IMAGE');
    }
    final bytes = base64Decode(encoded);
    if (bytes.length < 24 || bytes.length > 32000000) {
      throw const FormatException('INVALID_PDF_IMAGE');
    }
    final header = ByteData.sublistView(bytes),
        width = header.getUint32(16),
        height = header.getUint32(20);
    if (header.getUint32(0) != 0x89504e47 ||
        header.getUint32(12) != 0x49484452 ||
        width < 1 ||
        height < 1 ||
        width > 8192 ||
        height > 8192 ||
        width * height > 32000000) {
      throw const FormatException('INVALID_PDF_IMAGE');
    }
    final expected = mathInkPageMetadata(state.page)['geometry'];
    if (expected != null && mathInkPaperRect(expected) != geometry) {
      throw const FormatException('PDF_GEOMETRY_MISMATCH');
    }
    final original = state.page.extra['mathinkPdf'];
    if (original is Map &&
        original['resourceId'] != null &&
        original['resourceId'] != payload['resourceId']) {
      throw const FormatException('PDF_RESOURCE_MISMATCH');
    }
    final background = ImageBackgroundRenderer(
      Background.image(
        source: 'data:image/png;base64,$encoded',
        width: width.toDouble(),
        height: height.toDouble(),
        scaleX: geometry.width / width,
        scaleY: geometry.height / height,
        extra: {'mathinkPdf': true},
      ) as ImageBackground,
    );
    await background.setup(
      bloc.editorController.transformCubit,
      state.data,
      state.assetService,
      state.page,
    );
    if (background.image == null) {
      background.dispose();
      throw const FormatException('PDF_IMAGE_LOAD_FAILED');
    }
    if (bloc.state != state) {
      background.dispose();
      throw const FormatException('SOURCE_PAGE_CHANGED');
    }
    final old = _pdfBackground;
    _pdfPage = id as String;
    _pdfBackground = background;
    final renderers = bloc.editorController.rendererCubit;
    renderers.setViewport(
      renderers.state.cameraViewport.unbake(
        backgrounds: [background],
        unbakedElements: renderers.renderers,
      ),
    );
    old?.dispose();
  }

  Future<Map<String, dynamic>> _run(
    String method,
    Map<String, dynamic> payload,
  ) async {
    final state = bloc.state;
    if (state is! DocumentLoadSuccess) {
      throw const FormatException('DOCUMENT_NOT_READY');
    }
    if ({
          'createPage',
          'duplicatePage',
          'reorderPages',
          'deletePage',
          'restorePage',
          'setPaper',
          'insertMath',
          'updateMath',
          'removeMath',
          'undo',
          'redo',
        }.contains(method) &&
        bloc.editorController.saveCubit.state.embedding?.editable == false) {
      throw const FormatException('READ_ONLY');
    }
    switch (method) {
      case 'getCapabilities':
        return {
          'pages': true,
          'paper': true,
          'view': true,
          'tools': true,
          'history': true,
          'placement': true,
          'fingerWriting': true,
          'stablePageIds': true,
          'operationIdempotency': true,
          'selection': true,
          'selectionTransform': true,
          'pdfBackground': true,
          'frozenPageRender': true,
          'liveView': true,
          'pageGestures': true,
        };
      case 'preparePdfPages':
        {
          final raw = payload['data'];
          if (raw != null &&
              (raw is! List ||
                  raw.isEmpty ||
                  !raw.every((n) => n is int && n >= 0 && n <= 255))) {
            throw const FormatException('INVALID_DOCUMENT');
          }
          final original = raw == null
              ? await _savedDocument()
              : NoteData.fromData(
                  Uint8List.fromList((raw as List).cast<int>()),
                );
          final pages = payload['pages'];
          if (pages is! List) {
            throw const FormatException('INVALID_PDF_PAGE_COUNT');
          }
          final index = payload['index'];
          if (index != null && index is! int) {
            throw const FormatException('INVALID_PAGE_INDEX');
          }
          final prepared = mathInkPreparePdfPages(
            original,
            pages.map(_map).toList(),
            index: index as int?,
            afterPage: payload['afterPage'] as String?,
            replaceEmptyFirst: payload['replaceEmptyFirst'] == true,
          );
          final catalog = mathInkPageDirectory(prepared),
              id =
                  catalog.firstWhere((p) => p['deleted'] != true)['id']
                      as String;
          final selected = prepared.getPage(mathInkResolvePage(prepared, id)!)!;
          return {
            'data': prepared.exportAsBytes().toList(),
            'pages': catalog,
            'page': id,
            'currentPage': id,
            'revision': mathInkRevision(selected),
            'pageRevision': mathInkPageRevision(selected),
          };
        }
      case 'inspectFrozenDocument':
        {
          final raw = payload['data'];
          if (raw is! List ||
              raw.isEmpty ||
              raw.length > 150000000 ||
              !raw.every((n) => n is int && n >= 0 && n <= 255)) {
            throw const FormatException('INVALID_DOCUMENT');
          }
          final frozen = NoteData.fromData(Uint8List.fromList(raw.cast<int>()));
          final catalog = mathInkPageDirectory(frozen);
          return {
            'pages': catalog.map((p) {
              final page = frozen.getPage(p['name'] as String)!;
              return {
                ...p,
                'contentEmpty':
                    page.content.isEmpty && page.extra['mathinkPdf'] == null,
              };
            }).toList(),
            'currentPage': catalog.firstWhere(
              (p) => p['deleted'] != true,
            )['id'],
          };
        }
      case 'renderFrozenPage':
        {
          final raw = payload['data'], id = payload['page'];
          if (raw is! List ||
              raw.isEmpty ||
              raw.length > 150000000 ||
              !raw.every((n) => n is int && n >= 0 && n <= 255) ||
              id is! String) {
            throw const FormatException('INVALID_DOCUMENT');
          }
          return _renderFrozen(
            NoteData.fromData(Uint8List.fromList(raw.cast<int>())),
            id,
            payload,
          );
        }
      case 'setPdfBackground':
        await _setPdfPresentation(payload);
        return {'ready': true, 'page': _pageId(_state), 'persisted': false};
      case 'configureHostInteraction':
        {
          _bindSelectionNote(payload);
          final session = payload['sessionId'], page = payload['pageId'];
          if (session is! String ||
              session.isEmpty ||
              session.length > 160 ||
              page != _pageId(_state) ||
              payload['navigationLocked'] is! bool) {
            throw const FormatException('INVALID_HOST_INTERACTION');
          }
          final changed = _hostSession != session || _hostPage != page;
          if (changed) {
            _hostPointers.clear();
            _pageGesture.reset();
            _lastTap = null;
            _lastTapTime = null;
          }
          _hostSession = session;
          _hostPage = page as String;
          _geometry = mathInkPaperRect(payload['geometry']);
          _navigationLocked = payload['navigationLocked'] as bool;
          _allowSwipe = payload['allowSwipe'] == true;
          _fingerWriting = payload['fingerWriting'] == true;
          if (_navigationLocked) _pageGesture.cancel();
          if (_pdfPage != _hostPage) {
            _pdfBackground?.dispose();
            _pdfBackground = null;
            _pdfPage = null;
          }
          _emitHost('mathinkViewChanged');
          _emitHost('mathinkInputState');
          return _hostEvent();
        }
      case 'getViewport':
        return _hostEvent();
      case 'fitPage':
        return _fitHostPage(payload['mode'] as String? ?? 'width');
      case 'getSelection':
        _bindSelectionNote(payload);
        await _waitRenderers();
        final activeHandler = bloc.editorController.toolCubit.getHandler();
        if (activeHandler is SelectHandler) _observeSelection(activeHandler);
        return _selectionState();
      case 'selectAll':
        {
          _bindSelectionNote(payload);
          await _waitRenderers();
          var handler = bloc.editorController.toolCubit.getHandler();
          if (handler is! SelectHandler) {
            handler = SelectHandler(
              SelectTool(mode: .lasso),
              hostManaged: true,
            );
            await bloc.editorController.toolCubit.changeTool(
              bloc.editorController,
              bloc,
              handler: handler,
            );
          }
          final selection = handler;
          _observeSelection(selection);
          selection.selectAll(
            bloc,
            (renderer) => !_state.invisibleLayers.contains(renderer.layer),
          );
          return _selectionState();
        }
      case 'clearSelection':
        {
          _bindSelectionNote(payload);
          final selection = _selectionState();
          if (payload['pageId'] != null &&
                  payload['pageId'] != selection['pageId'] ||
              payload['generation'] != null &&
                  payload['generation'] != selection['generation']) {
            return {...selection, 'cleared': false};
          }
          final handler = bloc.editorController.toolCubit.getHandler();
          if (handler is SelectHandler) handler.clearSelection(bloc);
          _emitSelection();
          return {..._selectionState(), 'cleared': true};
        }
      case 'listPages':
        {
          await _ensureIds();
          final current = _state;
          final data = await current.saveData();
          return {
            'pages': mathInkPageDirectory(data),
            'currentPage': _pageId(current),
          };
        }
      case 'switchPage':
        {
          final page = payload['page'];
          if (page is! String) throw const FormatException('INVALID_PAGE');
          await _switch(page);
          if (payload['view'] is Map) _setView(_map(payload['view']));
          return _pageState();
        }
      case 'createPage':
      case 'duplicatePage':
        {
          await _ensureIds();
          final before = _state;
          final id = payload['id'] ?? createUniqueId();
          if (id is! String ||
              id.isEmpty ||
              id.length > 160 ||
              mathInkResolvePage(before.data, id, includeDeleted: true) !=
                  null) {
            throw const FormatException('INVALID_PAGE_ID');
          }
          final duplicate = method == 'duplicatePage';
          DocumentPage page;
          if (duplicate) {
            final source = payload['page'];
            final name = source is String
                ? mathInkResolvePage(before.data, source)
                : null;
            if (name == null) {
              throw const FormatException('SOURCE_PAGE_MISSING');
            }
            final original = name == before.pageName
                ? before.page
                : before.data.getPage(name)!;
            page = mathInkClonePage(original, id);
          } else {
            final paper = payload['paper'] as String? ?? 'blank';
            page = DocumentPage(
              backgrounds: mathInkPaperBackgrounds(paper),
              extra: {
                'mathinkPage': {
                  'id': id,
                  'aliases': <String>[],
                  'paper': paper,
                },
              },
            );
          }
          final index = payload['index'];
          if (index != null &&
              (index is! int ||
                  index < 0 ||
                  index > before.data.getPages(true).length)) {
            throw const FormatException('INVALID_PAGE_INDEX');
          }
          final completed = bloc.stream.firstWhere(
            (next) =>
                next is DocumentLoadSuccess &&
                mathInkStablePageId(next.page, next.pageName) == id,
          );
          bloc.add(
            PagesAdded([
              PageAddedDetails(
                page: page,
                name: id,
                addNumber: false,
                index: mathInkInsertionIndex(
                  before.data,
                  index as int? ?? before.data.getPages(true).length,
                ),
              ),
            ]),
          );
          await completed.timeout(const Duration(seconds: 10));
          await _waitRenderers();
          return {
            ..._pageState(),
            'id': id,
            'pages': mathInkPageDirectory(await _state.saveData()),
          };
        }
      case 'reorderPages':
        {
          await _ensureIds();
          final requested = payload['pages'];
          final all = mathInkPageDirectory(_state.data);
          final active = all
              .where((p) => p['deleted'] != true)
              .map((p) => p['id'] as String)
              .toSet();
          if (requested is! List ||
              requested.any((id) => id is! String) ||
              requested.toSet().length != active.length ||
              requested.length != active.length ||
              !active.containsAll(requested)) {
            throw const FormatException('INVALID_PAGE_ORDER');
          }
          final order = [
            ...requested.cast<String>(),
            ...all
                .where((p) => p['deleted'] == true)
                .map((p) => p['id'] as String),
          ];
          await _reorder(order);
          return {
            'pages': mathInkPageDirectory(await _state.saveData()),
            'currentPage': _pageId(_state),
          };
        }
      case 'deletePage':
      case 'restorePage':
        {
          await _ensureIds();
          final before = _state;
          final id = payload['page'];
          final real = id is String
              ? mathInkResolvePage(before.data, id, includeDeleted: true)
              : null;
          if (real == null) throw const FormatException('SOURCE_PAGE_MISSING');
          final removing = method == 'deletePage';
          final all = mathInkPageDirectory(await before.saveData());
          final existing = all.firstWhere((row) => row['id'] == id);
          if (existing['deleted'] == removing) {
            return {'pages': all, 'currentPage': _pageId(before)};
          }
          if (removing && all.where((p) => p['deleted'] != true).length <= 1) {
            throw const FormatException('LAST_PAGE');
          }
          var data = await before.saveData();
          final page = data.getPage(real)!;
          final meta = mathInkPageMetadata(page);
          final requestedIndex = payload['index'];
          if (requestedIndex != null &&
              (requestedIndex is! int ||
                  requestedIndex < 0 ||
                  requestedIndex >
                      all.where((p) => p['deleted'] != true).length)) {
            throw const FormatException('INVALID_PAGE_INDEX');
          }
          data = data
              .setPage(
                page.copyWith(
                  extra: {
                    ...page.extra,
                    'mathinkPage': {
                      ...meta,
                      'deleted': removing,
                      if (removing)
                        'deletedIndex': all
                            .where((p) => p['deleted'] != true)
                            .toList()
                            .indexWhere((p) => p['id'] == id),
                    },
                  },
                ),
                real,
              )
              .$1;
          await _replaceData(data);
          if (removing && _pageId(_state) == id) {
            final next = mathInkPageDirectory(_state.data)
                .firstWhere((p) => p['deleted'] != true);
            await _switch(next['id'] as String);
          }
          if (!removing) {
            final directory = mathInkPageDirectory(_state.data);
            final active = directory
                .where((p) => p['deleted'] != true && p['id'] != id)
                .map((p) => p['id'] as String)
                .toList();
            final rank =
                requestedIndex as int? ??
                (meta['deletedIndex'] is int
                    ? meta['deletedIndex'] as int
                    : active.length);
            active.insert(rank.clamp(0, active.length).toInt(), id as String);
            await _reorder([
              ...active,
              ...directory
                  .where((p) => p['deleted'] == true)
                  .map((p) => p['id'] as String),
            ]);
          }
          return {
            'pages': mathInkPageDirectory(await _state.saveData()),
            'currentPage': _pageId(_state),
          };
        }
      case 'setPaper':
        {
          await _ensureIds();
          final before = _state;
          final id = payload['page'] ?? _pageId(before);
          final real = id is String
              ? mathInkResolvePage(before.data, id)
              : null;
          if (real == null) throw const FormatException('SOURCE_PAGE_MISSING');
          final paper = payload['paper'];
          if (paper is! String) throw const FormatException('INVALID_PAPER');
          var data = await before.saveData();
          final page = data.getPage(real)!;
          data = data
              .setPage(
                page.copyWith(
                  backgrounds: mathInkPaperBackgrounds(paper),
                  extra: {
                    ...page.extra,
                    'mathinkPage': {
                      ...mathInkPageMetadata(page),
                      'paper': paper,
                    },
                  },
                ),
                real,
              )
              .$1;
          await _replaceData(data);
          return {
            ..._pageState(),
            'pages': mathInkPageDirectory(await _state.saveData()),
          };
        }
      case 'getView':
        return _view();
      case 'finishInput':
        {
          await _flushMouseDot();
          final controller = bloc.editorController;
          final handler = controller.toolCubit.getHandler();
          final pendingIds = handler is PenHandler
              ? handler.elements.values.map((e) => e.id).toSet()
              : <String?>{};
          final completed = pendingIds.isEmpty
              ? null
              : bloc.stream.firstWhere(
                  (next) =>
                      next is DocumentLoadSuccess &&
                      pendingIds.every(
                        (id) => next.page.content.any((e) => e.id == id),
                      ),
                );
          await controller.toolCubit.resetInput(bloc, controller.inputCubit);
          if (completed != null) {
            await completed.timeout(const Duration(seconds: 10));
          }
          await _waitRenderers();
          return _pageState();
        }
      case 'setView':
        _autoFitWidth = false;
        _setView(payload);
        return _view();
      case 'setTool':
        {
          await _flushMouseDot();
          _bindSelectionNote(payload);
          final name = payload['tool'];
          final width = payload['width'] as num? ?? 3;
          if (!width.isFinite || width < .1 || width > 100) {
            throw const FormatException('INVALID_TOOL');
          }
          final rawColor = payload['color'];
          var color = 0xff000000;
          if (rawColor != null) {
            if (rawColor is! String ||
                !RegExp(r'^#[a-fA-F0-9]{6}$').hasMatch(rawColor)) {
              throw const FormatException('INVALID_COLOR');
            }
            color = 0xff000000 | int.parse(rawColor.substring(1), radix: 16);
          }
          final Tool tool = switch (name) {
            'pen' => PenTool(
              property: PenProperty(
                strokeWidth: width.toDouble(),
                paint: ElementPaint.fromJson({'type': 'solid', 'color': color}),
              ),
            ),
            'eraser' => EraserTool(strokeWidth: width.toDouble()),
            'lasso' => SelectTool(mode: SelectMode.lasso),
            'pan' => HandTool(),
            _ => throw const FormatException('UNSUPPORTED_TOOL'),
          };
          await _activateHostTool(tool, name as String);
          return {'tool': name};
        }
      case 'setFingerWriting':
        {
          final enabled = payload['enabled'];
          if (enabled is! bool) {
            throw const FormatException('INVALID_INPUT_MODE');
          }
          final settings = _state.settingsCubit;
          _fingerWriting = enabled;
          if (enabled) _pageGesture.cancel();
          await settings.changeInputConfiguration(
            settings.state.inputConfiguration.copyWith(
              touch: InputMapping(
                enabled
                    ? InputMapping.activeToolValue
                    : InputMapping.handToolValue,
              ),
            ),
          );
          return {'enabled': enabled};
        }
      case 'undo':
      case 'redo':
        {
          final before = await _state.saveData();
          final beforePage = _pageId(_state);
          if (method == 'undo') {
            bloc.sendUndo();
          } else {
            bloc.sendRedo();
          }
          await _waitRenderers();
          final after = await _state.saveData();
          final affected = mathInkAffectedPages(before, after);
          if (beforePage != _pageId(_state)) {
            for (final id in [beforePage, _pageId(_state)]) {
              if (!affected.contains(id)) affected.add(id);
            }
          }
          _emitSelection();
          return {..._pageState(), 'affectedPageIds': affected};
        }
      case 'renderPage':
        {
          await _waitRenderers();
          final state = _state;
          final expectedPage = payload['page'];
          if (expectedPage != null && expectedPage != _pageId(state)) {
            throw const FormatException('SOURCE_PAGE_CHANGED');
          }
          if (state.page.extra['mathinkPdf'] != null ||
              payload['annotationsOnly'] == true) {
            if (payload['annotationsOnly'] != true &&
                (_pdfPage != _pageId(state) || _pdfBackground == null)) {
              throw const FormatException('PDF_BACKGROUND_NOT_READY');
            }
            return _renderFrozen(
              await _savedDocument(),
              _pageId(state),
              payload,
              presentation: payload['annotationsOnly'] == true
                  ? null
                  : _pdfBackground?.element,
            );
          }
          final revision = mathInkPageRevision(state.page);
          final all = mathInkPageRenderers(
            bloc.editorController.rendererCubit.renderers.where(
              (renderer) => !state.invisibleLayers.contains(renderer.layer),
            ),
          );
          final bounds = _bounds(all);
          final options = mathInkImageOptions(bounds);
          final png = await bloc.editorController.rendererCubit.render(
            bloc.editorController,
            state.data,
            state.page,
            state.info,
            options,
            cameraViewport: CameraViewport.unbaked(
              unbakedElements: all,
              visibleElements: all,
              visibleUnbakedElements: all,
            ),
            docState: state,
            invisibleLayers: state.invisibleLayers,
          );
          final current = bloc.state;
          if (current is! DocumentLoadSuccess ||
              current.pageName != state.pageName ||
              mathInkPageRevision(current.page) != revision) {
            throw const FormatException('SOURCE_PAGE_CHANGED');
          }
          if (png == null) throw const FormatException('RENDER_FAILED');
          final bytes = png.buffer.asUint8List(
            png.offsetInBytes,
            png.lengthInBytes,
          );
          // Read the actual raster dimensions from the PNG header.
          final header = ByteData.sublistView(bytes);
          final width = header.getUint32(16);
          final height = header.getUint32(20);
          return {
            'pngBase64': base64Encode(bytes),
            'page': _pageId(state),
            'revision': revision,
            'inkRevision': _revision(state),
            'strokeIds': all
                .where((renderer) => renderer.element is PenElement)
                .map((renderer) => renderer.element.id)
                .toList(),
            'bounds': {
              'x': bounds.left,
              'y': bounds.top,
              'width': bounds.width,
              'height': bounds.height,
            },
            'transform': {
              'offsetX': bounds.left,
              'offsetY': bounds.top,
              'scaleX': width / bounds.width,
              'scaleY': height / bounds.height,
            },
          };
        }
      case 'getSelectedInk':
        await _waitRenderers();
        final selected = _selection(_state, payload);
        return _source(_state, selected, _bounds(selected));
      case 'renderSelectedInk':
        await _waitRenderers();
        final active = _state;
        final selected = _selection(active, payload);
        final bounds = _bounds(selected);
        final source = _source(active, selected, bounds);
        final png = await bloc.editorController.rendererCubit.render(
          bloc.editorController,
          active.data,
          active.page,
          active.info,
          mathInkImageOptions(bounds),
          cameraViewport: CameraViewport.unbaked(
            unbakedElements: selected,
            visibleElements: selected,
            visibleUnbakedElements: selected,
          ),
          docState: active,
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
        await _ensureIds();
        final requestedPage = payload['page'];
        if (requestedPage != null) {
          if (requestedPage is! String) {
            throw const FormatException('INVALID_PAGE');
          }
          await _switch(requestedPage);
        }
        final active = _state;
        final position = payload['position'] is Map
            ? _map(payload['position'])
            : const <String, dynamic>{};
        final operationId = payload['operationId'];
        if (operationId != null &&
            (operationId is! String ||
                operationId.isEmpty ||
                operationId.length > 160)) {
          throw const FormatException('INVALID_OPERATION_ID');
        }
        final placed = operationId != null && position.isNotEmpty;
        final selected = placed
            ? <Renderer<PadElement>>[]
            : _selection(active, payload);
        final bounds = placed ? null : _bounds(selected);
        final x = (position['x'] as num?)?.toDouble() ?? bounds?.left;
        final y =
            (position['y'] as num?)?.toDouble() ??
            (bounds == null ? null : bounds.bottom + 24);
        if (x == null ||
            y == null ||
            !x.isFinite ||
            !y.isFinite ||
            x.abs() > 10000000 ||
            y.abs() > 10000000) {
          throw const FormatException('INVALID_PLACEMENT');
        }
        final signature = sha256
            .convert(
              utf8.encode(jsonEncode({'latex': latex.trim(), 'x': x, 'y': y})),
            )
            .toString();
        final operations = active.page.extra['mathinkOperations'] is Map
            ? Map<String, dynamic>.from(
                active.page.extra['mathinkOperations'] as Map,
              )
            : <String, dynamic>{};
        operations.addAll(_operationReceipts[_pageId(active)] ?? {});
        final receipt = operations[operationId];
        if (operationId != null && receipt is Map) {
          if (receipt['signature'] != signature) {
            throw const FormatException('OPERATION_MISMATCH');
          }
          final id = receipt['elementId'];
          final present = active.page.content.any(
            (element) => element.id == id,
          );
          return {
            'id': id,
            'elementId': id,
            'operationId': operationId,
            ..._pageState(),
            'inserted': false,
            'duplicate': true,
            'removed': !present,
          };
        }
        final id = createUniqueId();
        final element = PadElement.markdown(
          id: id,
          text: '\$${latex.trim()}\$',
          position: Point<double>(x, y),
          extra: {
            'mathink': {
              if (bounds != null) ..._source(active, selected, bounds),
              if (payload['source'] is Map) 'source': _map(payload['source']),
              'operationId': ?operationId,
              'latex': latex,
            },
          },
        );
        if (operationId != null) {
          if (operations.length >= 10000) {
            throw const FormatException('OPERATION_HISTORY_FULL');
          }
          // Consume once, including after undo. getDocument merges this table
          // into the exported copy without adding a second native history row.
          operations[operationId] = {'elementId': id, 'signature': signature};
          _operationReceipts.putIfAbsent(
            _pageId(active),
            () => {},
          )[operationId as String] = operations[operationId];
        }
        final completed = bloc.stream.firstWhere(
          (next) =>
              next is DocumentLoadSuccess &&
              next.page.content.any((item) => item.id == id),
        );
        bloc.add(ElementsCreated([element]));
        final updated = await completed.timeout(const Duration(seconds: 10));
        await _waitRenderers();
        return {
          'id': id,
          'elementId': id,
          'operationId': ?operationId,
          'page': _pageId(updated as DocumentLoadSuccess),
          'inserted': true,
          'revision': _revision(updated),
          'pageRevision': mathInkPageRevision(updated.page),
        };
      case 'updateMath':
      case 'removeMath':
        {
          final page = payload['page'];
          if (page is! String) throw const FormatException('INVALID_PAGE');
          await _switch(page);
          final current = _state;
          final id = payload['elementId'];
          final matches = current.page.content.where((e) => e.id == id);
          if (matches.isEmpty) {
            if (method == 'removeMath') {
              return {..._pageState(), 'removed': false};
            }
            throw const FormatException('MATH_INSTANCE_MISSING');
          }
          final element = matches.first;
          if (element is! MarkdownElement || element.extra['mathink'] is! Map) {
            throw const FormatException('NOT_A_MATH_INSTANCE');
          }
          if (method == 'removeMath') {
            final completed = bloc.stream.firstWhere(
              (next) =>
                  next is DocumentLoadSuccess &&
                  next.page.content.every((e) => e.id != id),
            );
            bloc.add(ElementsRemoved([id as String]));
            await completed.timeout(const Duration(seconds: 10));
            return {..._pageState(), 'removed': true};
          }
          final latex =
              payload['latex'] ?? _map(element.extra['mathink'])['latex'];
          if (latex is! String ||
              latex.trim().isEmpty ||
              latex.length > 20000) {
            throw const FormatException('INVALID_LATEX');
          }
          final position = payload['position'] is Map
              ? _map(payload['position'])
              : null;
          var targetPosition = element.position;
          if (position != null) {
            final x = position['x'], y = position['y'];
            if (x is! num ||
                y is! num ||
                !x.isFinite ||
                !y.isFinite ||
                x.abs() > 10000000 ||
                y.abs() > 10000000) {
              throw const FormatException('INVALID_PLACEMENT');
            }
            targetPosition = Point(x.toDouble(), y.toDouble());
          }
          final next = element.copyWith(
            text: '\$${latex.trim()}\$',
            position: targetPosition,
            extra: {
              ...element.extra,
              'mathink': {..._map(element.extra['mathink']), 'latex': latex},
            },
          );
          final completed = bloc.stream.firstWhere(
            (state) =>
                state is DocumentLoadSuccess &&
                state.page.content.any(
                  (e) =>
                      e.id == id &&
                      jsonEncode(e.toJson()) == jsonEncode(next.toJson()),
                ),
          );
          bloc.add(
            ElementsChanged({
              id as String: [next],
            }),
          );
          await completed.timeout(const Duration(seconds: 10));
          return {..._pageState(), 'elementId': id};
        }
      case 'getDocument':
        {
          await _flushMouseDot();
          await _ensureIds();
          final current = _state;
          final saved = await _savedDocument();
          return {
            'data': saved.exportAsBytes().toList(),
            'revision': _revision(current),
            'pageRevision': mathInkPageRevision(current.page),
            'page': _pageId(current),
            'nativeName': current.pageName,
            'pages': mathInkPageDirectory(saved),
            'view': _view(),
          };
        }
      case 'locateInk':
        final page = payload['page'];
        if (page is! String) {
          throw const FormatException('SOURCE_PAGE_MISSING');
        }
        await _switch(page);
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
          var handler = controller.toolCubit.getHandler();
          if (handler is! SelectHandler || handler.data.mode != .lasso) {
            handler = SelectHandler(
              SelectTool(mode: .lasso),
              hostManaged: true,
            );
            await controller.toolCubit.changeTool(
              controller,
              bloc,
              handler: handler,
            );
          }
          _observeSelection(handler);
          handler.selectAll(
            bloc,
            (renderer) =>
                renderer.element is PenElement &&
                ids.contains(renderer.element.id),
          );
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

  Future<Map<String, dynamic>> _enqueue(
    String method,
    Map<String, dynamic> payload,
  ) {
    final result = _requestQueue.then((_) async {
      final value = await _run(method, payload);
      // Reloads select document toolbar index zero. Host tools are independent
      // of that toolbar, and must be restored before the frame becomes ready.
      if (_hostSelectedTool != null &&
          {
            'switchPage',
            'createPage',
            'duplicatePage',
            'deletePage',
            'restorePage',
            'reorderPages',
            'setPaper',
            'undo',
            'redo',
          }.contains(method)) {
        await _waitRenderers();
        final active = bloc.editorController.toolCubit.getHandler();
        if (active.data != _hostSelectedTool ||
            _hostTool == 'lasso' &&
                (active is! SelectHandler || !active.hostManaged)) {
          await _activateHostTool(_hostSelectedTool!, _hostTool);
        }
      }
      return value;
    });
    _requestQueue = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  void register() {
    _mathInkBridges[bloc] = this;
    bloc.editorController.mathInkBackgrounds = (page) =>
        mathInkPageMetadata(page)['id'] == _pdfPage && _pdfBackground != null
        ? [_pdfBackground!]
        : null;
    _viewSubscription ??= bloc.editorController.transformCubit.stream.listen((
      _,
    ) {
      if (!hostInteractionReady) return;
      if (!_settingHostView && jsonEncode(_view()) != _fitSignature) {
        _autoFitWidth = false;
      }
      _clampView();
      _emitHost('mathinkViewChanged');
    });
    _viewportSubscription ??= bloc.editorController.rendererCubit.stream.listen(
      (state) {
        final size = state.cameraViewport.viewportSize;
        if (size == null ||
            size.width <= 0 ||
            size.height <= 0 ||
            size == _lastViewport) {
          return;
        }
        _lastViewport = size;
        if (hostInteractionReady) {
          if (_autoFitWidth) {
            _fitHostPage('width');
          } else {
            _emitHost('mathinkViewChanged');
          }
        }
      },
    );
    _toolSubscription ??= bloc.editorController.toolCubit.stream.listen((_) {
      final handler = bloc.editorController.toolCubit.getHandler();
      if (handler is SelectHandler) {
        _observeSelection(handler);
      } else {
        _observedSelection?.mathInkSelectionChanged = null;
        _observedSelection = null;
      }
      _emitSelection();
    });
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
        final result = await _enqueue(method, _map(request['payload'] ?? {}));
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
    _mouseDotTimer?.cancel();
    _mouseDotTimer = null;
    _pendingMouseDot = null;
    _mathInkBridges[bloc] = null;
    _viewSubscription?.cancel();
    _viewSubscription = null;
    _viewportSubscription?.cancel();
    _viewportSubscription = null;
    bloc.editorController.mathInkBackgrounds = null;
    _pdfBackground?.dispose();
    _pdfBackground = null;
    _pdfPage = null;
    _hostPointers.clear();
    _pageGesture.reset();
    _toolSubscription?.cancel();
    _toolSubscription = null;
    _observedSelection?.mathInkSelectionChanged = null;
    _observedSelection = null;
    _operationReceipts.clear();
    if (_listener != null) removeEmbedMessageListener(_listener!);
    _listener = null;
  }
}
