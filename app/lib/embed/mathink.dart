// MathInk integration for Linwood Butterfly; original editor remains AGPL-3.0.
import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:butterfly/bloc/document_bloc.dart';
import 'package:butterfly/cubits/settings.dart';
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

/// Correlated host requests. A PNG is rendered from selected pen renderers,
/// never by cropping a screenshot which could include unrelated handwriting.
class MathInkEmbedBridge {
  final BuildContext context;
  final DocumentBloc bloc;
  EventListener? _listener;
  Future<void> _requestQueue = Future.value();
  final Map<String, Map<String, dynamic>> _operationReceipts = {};

  MathInkEmbedBridge(this.context, this.bloc);

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
    var normalized = mathInkEnsurePageIds(data);
    var changed = false;
    for (final name in normalized.getPages(true)) {
      final page = normalized.getPage(name)!;
      final id = mathInkStablePageId(page, name);
      final receipts = page.extra['mathinkOperations'] is Map
          ? Map<String, dynamic>.from(page.extra['mathinkOperations'] as Map)
          : <String, dynamic>{};
      final known = _operationReceipts.putIfAbsent(id, () => {});
      known.addAll(receipts);
      if (known.isNotEmpty && jsonEncode(known) != jsonEncode(receipts)) {
        normalized = normalized
            .setPage(
              page.copyWith(
                extra: {
                  ...page.extra,
                  'mathinkOperations': Map<String, dynamic>.from(known),
                },
              ),
              name,
            )
            .$1;
        changed = true;
      }
    }
    if (!changed &&
        data
            .getPages(true)
            .every(
              (name) => mathInkPageMetadata(data.getPage(name)!)['id'] != null,
            )) {
      return;
    }
    if (bloc.state != state) throw const FormatException('SOURCE_PAGE_CHANGED');
    await _replaceData(normalized);
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
        };
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
        _setView(payload);
        return _view();
      case 'setTool':
        {
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
          await bloc.editorController.toolCubit.changeTool(
            bloc.editorController,
            bloc,
            handler: Handler.fromTool(tool),
          );
          final controller = bloc.editorController;
          final input = controller.inputCubit;
          if (controller.saveCubit.state.embedding?.fullScreen.queryValue ==
                  'forced' &&
              input.state.hideUi != .keyboard) {
            // A touch-hidden UI toggles back to visible first; normalize it so
            // forced embeds keep the host's toolbar as the only tool surface.
            if (input.state.hideUi == .touch) input.exitHideUI();
            input.toggleKeyboardHideUI();
          }
          return {'tool': name};
        }
      case 'setFingerWriting':
        {
          final enabled = payload['enabled'];
          if (enabled is! bool) {
            throw const FormatException('INVALID_INPUT_MODE');
          }
          final settings = _state.settingsCubit;
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
          if (method == 'undo') {
            bloc.sendUndo();
          } else {
            bloc.sendRedo();
          }
          await _waitRenderers();
          return _pageState();
        }
      case 'renderPage':
        {
          await _waitRenderers();
          final state = _state;
          final expectedPage = payload['page'];
          if (expectedPage != null && expectedPage != _pageId(state)) {
            throw const FormatException('SOURCE_PAGE_CHANGED');
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
          // Keep the receipt in the pre-insertion history state. Native undo
          // removes the instance, never the consumed operation identity.
          operations[operationId] = {'elementId': id, 'signature': signature};
          _operationReceipts.putIfAbsent(
            _pageId(active),
            () => {},
          )[operationId as String] = operations[operationId];
          final saved = await active.saveData();
          await _replaceData(
            saved
                .setPage(
                  active.page.copyWith(
                    extra: {
                      ...active.page.extra,
                      'mathinkOperations': operations,
                    },
                  ),
                  active.pageName,
                )
                .$1,
          );
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
          await _ensureIds();
          final current = _state;
          final saved = await current.saveData();
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

  Future<Map<String, dynamic>> _enqueue(
    String method,
    Map<String, dynamic> payload,
  ) {
    final result = _requestQueue.then((_) => _run(method, payload));
    _requestQueue = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
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
    if (_listener != null) removeEmbedMessageListener(_listener!);
    _listener = null;
  }
}
