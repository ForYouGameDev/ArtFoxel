import 'sketch_document_data.dart';

/// Why a layer operation was refused (shown to the user as-is).
class LayerOpException implements Exception {
  const LayerOpException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Structural layer operations on a [SketchDocumentData].
///
/// `doc.layers` is stored flat, bottom to top, with groups followed by their
/// descendants. Ids never change and are never reused within a document, so
/// selection, history and saved files can refer to a layer safely after any
/// reorder, rename or regroup.
abstract final class LayerOps {
  // ---- tree helpers ----------------------------------------------------------

  /// Siblings under [parentId] (null = top level), bottom to top.
  static List<SketchLayerData> children(
    SketchDocumentData doc,
    String? parentId,
  ) =>
      [
        for (final layer in doc.layers)
          if (layer.parentId == parentId) layer,
      ];

  static List<SketchLayerData> descendants(
    SketchDocumentData doc,
    String groupId,
  ) {
    final out = <SketchLayerData>[];
    void walk(String id) {
      for (final child in children(doc, id)) {
        out.add(child);
        if (child.isGroup) walk(child.id);
      }
    }

    walk(groupId);
    return out;
  }

  static int depthOf(SketchDocumentData doc, SketchLayerData layer) {
    var depth = 0;
    var parent = layer.parentId;
    while (parent != null) {
      depth++;
      parent = doc.layerById(parent)?.parentId;
    }
    return depth;
  }

  /// Visible only if the layer and every ancestor group are visible.
  static bool isEffectivelyVisible(SketchDocumentData doc, SketchLayerData layer) {
    SketchLayerData? current = layer;
    while (current != null) {
      if (!current.visible) return false;
      final parent = current.parentId;
      current = parent == null ? null : doc.layerById(parent);
    }
    return true;
  }

  /// Locked if the layer or any ancestor group is locked.
  static bool isEffectivelyLocked(SketchDocumentData doc, SketchLayerData layer) {
    SketchLayerData? current = layer;
    while (current != null) {
      if (current.locked) return true;
      final parent = current.parentId;
      current = parent == null ? null : doc.layerById(parent);
    }
    return false;
  }

  /// Rewrites `doc.layers` so groups are followed by their descendants.
  static void _flatten(
    SketchDocumentData doc,
    Map<String?, List<SketchLayerData>> tree,
  ) {
    final out = <SketchLayerData>[];
    void walk(String? parent) {
      for (final layer in tree[parent] ?? const <SketchLayerData>[]) {
        out.add(layer);
        if (layer.isGroup) walk(layer.id);
      }
    }

    walk(null);
    doc.layers
      ..clear()
      ..addAll(out);
  }

  static Map<String?, List<SketchLayerData>> _tree(SketchDocumentData doc) {
    final tree = <String?, List<SketchLayerData>>{};
    for (final layer in doc.layers) {
      tree.putIfAbsent(layer.parentId, () => []).add(layer);
    }
    return tree;
  }

  // ---- ids and names ----------------------------------------------------------

  /// A new id that has never been used in [doc] (ids are `layer-<n>`).
  static String newId(SketchDocumentData doc) {
    var highest = 0;
    for (final layer in doc.layers) {
      final match = RegExp(r'^layer-(\d+)$').firstMatch(layer.id);
      if (match != null) {
        final n = int.parse(match.group(1)!);
        if (n > highest) highest = n;
      }
    }
    var candidate = highest + 1;
    while (doc.layerById('layer-$candidate') != null) {
      candidate++;
    }
    return 'layer-$candidate';
  }

  static String _uniqueName(SketchDocumentData doc, String base) {
    final names = {for (final l in doc.layers) l.name.toLowerCase()};
    if (!names.contains(base.toLowerCase())) return base;
    for (var n = 2;; n++) {
      final candidate = '$base $n';
      if (!names.contains(candidate.toLowerCase())) return candidate;
    }
  }

  static String sanitizeName(String name) {
    final clean = name.replaceAll(RegExp(r'[\u0000-\u001F]'), ' ').trim();
    if (clean.isEmpty) throw const LayerOpException('A layer needs a name.');
    return clean.length > 40 ? clean.substring(0, 40) : clean;
  }

  static void _requireRoom(SketchDocumentData doc, [int needed = 1]) {
    if (doc.layers.length + needed > SketchDocumentData.maxLayers) {
      throw LayerOpException(
        'A project can have at most ${SketchDocumentData.maxLayers} layers '
        'and groups.',
      );
    }
  }

  static SketchLayerData _require(SketchDocumentData doc, String id) {
    final layer = doc.layerById(id);
    if (layer == null) throw const LayerOpException('That layer no longer exists.');
    return layer;
  }

  // ---- create ---------------------------------------------------------------------

  /// Inserts [layer] directly above [aboveId] (in its group), or at the top of
  /// [parentId] when [aboveId] is null.
  static SketchLayerData insert(
    SketchDocumentData doc,
    SketchLayerData layer, {
    String? aboveId,
  }) {
    _requireRoom(doc);
    final tree = _tree(doc);
    String? parent = layer.parentId;
    if (aboveId != null) {
      final above = _require(doc, aboveId);
      parent = above.parentId;
      layer.parentId = parent;
      final siblings = tree.putIfAbsent(parent, () => []);
      siblings.insert(siblings.indexOf(above) + 1, layer);
    } else {
      tree.putIfAbsent(parent, () => []).add(layer);
    }
    _flatten(doc, tree);
    return layer;
  }

  static SketchLayerData addPaintLayer(SketchDocumentData doc, {String? aboveId}) {
    return insert(
      doc,
      SketchLayerData(
        id: newId(doc),
        name: _uniqueName(doc, 'Layer ${doc.layers.where((l) => !l.isGroup).length + 1}'),
      ),
      aboveId: aboveId,
    );
  }

  static SketchLayerData addGroup(SketchDocumentData doc, {String? aboveId}) {
    return insert(
      doc,
      SketchLayerData(
        id: newId(doc),
        name: _uniqueName(doc, 'Group ${doc.layers.where((l) => l.isGroup).length + 1}'),
        kind: LayerKind.group,
      ),
      aboveId: aboveId,
    );
  }

  /// Puts [ids] (which must share a parent) into a new group placed where the
  /// top-most of them was.
  static SketchLayerData groupLayers(SketchDocumentData doc, List<String> ids) {
    if (ids.isEmpty) throw const LayerOpException('Select a layer to group.');
    final selected = [for (final id in ids) _require(doc, id)];
    final parent = selected.first.parentId;
    if (selected.any((l) => l.parentId != parent)) {
      throw const LayerOpException('Only layers in the same group can be grouped together.');
    }
    _requireRoom(doc);
    final tree = _tree(doc);
    final siblings = tree[parent]!;
    final top = selected.map(siblings.indexOf).reduce((a, b) => a > b ? a : b);
    final insertAt = siblings.sublist(0, top + 1).where((l) => !selected.contains(l)).length;
    final group = SketchLayerData(
      id: newId(doc),
      name: _uniqueName(doc, 'Group ${doc.layers.where((l) => l.isGroup).length + 1}'),
      kind: LayerKind.group,
      parentId: parent,
    );
    final members = [for (final l in siblings) if (selected.contains(l)) l];
    siblings.removeWhere(selected.contains);
    siblings.insert(insertAt, group);
    for (final member in members) {
      member.parentId = group.id;
    }
    // Clipping to "the layer below" must not reach out of the new group.
    if (members.isNotEmpty) members.first.clipToBelow = false;
    tree[group.id] = members;
    _flatten(doc, tree);
    return group;
  }

  /// Dissolves a group; its children take its place in the parent.
  static void ungroup(SketchDocumentData doc, String groupId) {
    final group = _require(doc, groupId);
    if (!group.isGroup) throw const LayerOpException('That layer is not a group.');
    final tree = _tree(doc);
    final kids = tree.remove(groupId) ?? [];
    final siblings = tree[group.parentId]!;
    final at = siblings.indexOf(group);
    siblings.removeAt(at);
    for (final kid in kids) {
      kid.parentId = group.parentId;
    }
    siblings.insertAll(at, kids);
    _flatten(doc, tree);
  }

  // ---- duplicate / delete -----------------------------------------------------------

  /// Duplicates a layer (or a group with everything in it) above the original.
  /// Returns the new top layer of the copy.
  static SketchLayerData duplicate(SketchDocumentData doc, String id) {
    final source = _require(doc, id);
    final subtree = source.isGroup ? descendants(doc, id) : const <SketchLayerData>[];
    _requireRoom(doc, 1 + subtree.length);
    final tree = _tree(doc);
    final idMap = <String, String>{};
    var counter = int.parse(newId(doc).substring(6));
    String fresh() => 'layer-${counter++}';

    final root = source.copy(id: fresh(), name: _uniqueName(doc, '${source.name} copy'));
    idMap[source.id] = root.id;
    final siblings = tree[source.parentId]!;
    siblings.insert(siblings.indexOf(source) + 1, root);

    void cloneChildren(String oldParent) {
      final newParent = idMap[oldParent]!;
      for (final child in tree[oldParent] ?? const <SketchLayerData>[]) {
        final clone = child.copy(id: fresh());
        clone.parentId = newParent;
        idMap[child.id] = clone.id;
        tree.putIfAbsent(newParent, () => []).add(clone);
        if (child.isGroup) cloneChildren(child.id);
      }
    }

    if (source.isGroup) cloneChildren(source.id);
    _flatten(doc, tree);
    return root;
  }

  /// Deletes a layer and (for groups) everything inside it. The document
  /// always keeps at least one paint layer; a blank one is added if needed.
  /// Returns the id that should become the selected layer.
  static String delete(SketchDocumentData doc, String id) {
    final layer = _require(doc, id);
    final tree = _tree(doc);
    final siblings = tree[layer.parentId]!;
    final index = siblings.indexOf(layer);
    final doomed = {id, if (layer.isGroup) ...descendants(doc, id).map((l) => l.id)};
    doc.layers.removeWhere((l) => doomed.contains(l.id));
    if (!doc.layers.any((l) => l.isPaint)) {
      final blank = SketchLayerData(id: newId(doc), name: 'Layer 1');
      doc.layers.add(blank);
      return blank.id;
    }
    final remaining = children(doc, layer.parentId);
    if (remaining.isNotEmpty) {
      return remaining[index.clamp(0, remaining.length - 1)].id;
    }
    return layer.parentId ?? doc.layers.firstWhere((l) => l.isPaint).id;
  }

  // ---- reorder ---------------------------------------------------------------------------

  /// Moves a layer one step up (+1) or down (-1) among its siblings.
  /// Returns false when it is already at that end.
  static bool nudge(SketchDocumentData doc, String id, int direction) {
    final layer = _require(doc, id);
    final tree = _tree(doc);
    final siblings = tree[layer.parentId]!;
    final from = siblings.indexOf(layer);
    final to = from + direction;
    if (to < 0 || to >= siblings.length) return false;
    siblings
      ..removeAt(from)
      ..insert(to, layer);
    _flatten(doc, tree);
    return true;
  }

  /// Moves [id] into [newParentId] (null = top level) at [index] among that
  /// parent's children (0 = bottom).
  static void moveTo(
    SketchDocumentData doc,
    String id, {
    required String? newParentId,
    required int index,
  }) {
    final layer = _require(doc, id);
    if (newParentId != null) {
      final target = _require(doc, newParentId);
      if (!target.isGroup) throw const LayerOpException('Layers can only be moved into groups.');
      if (newParentId == id || descendants(doc, id).any((l) => l.id == newParentId)) {
        throw const LayerOpException('A group cannot be moved into itself.');
      }
    }
    final tree = _tree(doc);
    tree[layer.parentId]!.remove(layer);
    layer.parentId = newParentId;
    final siblings = tree.putIfAbsent(newParentId, () => []);
    siblings.insert(index.clamp(0, siblings.length), layer);
    _flatten(doc, tree);
  }

  /// True when [layer] is clipped to a usable layer below it.
  static bool hasClipBase(SketchDocumentData doc, SketchLayerData layer) {
    if (!layer.clipToBelow) return false;
    final siblings = children(doc, layer.parentId);
    final i = siblings.indexOf(layer);
    return i > 0;
  }
}
