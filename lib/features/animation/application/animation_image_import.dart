import 'dart:typed_data';

import '../../imaging/data/image_decoder.dart';
import '../../imaging/domain/import_rules.dart';
import '../domain/animation_model.dart';
import '../domain/image_codecs.dart';

/// The six ways a picture can enter the Animation Studio.
enum AnimImportMode {
  background('Background', 'Sits under every frame and is exported.'),
  layer('Animation layer', 'Stays on screen over a range of frames and is exported.'),
  frameContent('Current frame content', 'Belongs to the selected frame only and is exported.'),
  reference('Reference image', 'For you only. Never exported.'),
  character('Character artwork', 'A layer you can place for a range of frames. Exported.'),
  sequence('Image sequence', 'Each picture becomes its own frame, in natural name order.');

  const AnimImportMode(this.label, this.description);
  final String label, description;
}

/// An image decoded, size-checked and re-encoded as PNG, ready to be stored
/// as an asset. Nothing is registered in the document until [commit].
class PreparedAnimImage {
  PreparedAnimImage(this.name, this.width, this.height, this.png, this.warnings);
  final String name;
  final int width, height;
  final Uint8List png;
  final List<String> warnings;
}

abstract final class AnimationImageImport {
  /// Longest side stored for an animation picture. Larger pictures are scaled
  /// down while decoding so a phone never holds a huge bitmap per asset.
  static const maxAssetSide = 2048;
  static const maxFileBytes = 25 * 1024 * 1024;

  static Future<PreparedAnimImage> prepare(Uint8List bytes, String name) async {
    final (pixels, plan) = await decodeImageBytes(
      bytes,
      fileName: name,
      maxDecodeSide: maxAssetSide,
      limits: const ImportLimits(maxFileBytes: maxFileBytes),
    );
    final png = PngCodec.encode(pixels.width, pixels.height, pixels.rgba);
    return PreparedAnimImage(name, pixels.width, pixels.height, png, plan.warnings);
  }

  /// Placement of the picture inside the animation canvas. Aspect ratio is
  /// always preserved; [FitMode.fill] is used for backgrounds.
  static AnimImage place(AnimationDocument doc, PreparedAnimImage p, String assetId, {FitMode fit = FitMode.fit, double opacity = 1}) {
    final m = ImagePlacement(fit: fit).toAffine(doc.width, doc.height, p.width, p.height);
    return AnimImage(assetId: assetId, matrix: [m.a, m.b, m.c, m.d, m.e, m.f], opacity: opacity);
  }

  /// Applies one prepared picture to the document for a single-picture mode.
  /// Returns the asset id. Throws [AnimationException] on limit errors.
  static String commit(AnimationDocument doc, PreparedAnimImage p, AnimImportMode mode, {required int frameIndex}) {
    switch (mode) {
      case AnimImportMode.background:
        final a = doc.addAsset(p.name, p.width, p.height);
        doc.backgroundImage = place(doc, p, a.id, fit: FitMode.fill);
        return a.id;
      case AnimImportMode.layer:
      case AnimImportMode.character:
        if (doc.layers.length >= AnimationDocument.maxLayers) throw const AnimationException('Too many image layers.');
        final a = doc.addAsset(p.name, p.width, p.height);
        doc.layers.add(AnimLayer(
          id: 'L${DateTime.now().microsecondsSinceEpoch}',
          name: p.name,
          image: place(doc, p, a.id),
          startFrame: frameIndex,
          role: mode == AnimImportMode.character ? 'character' : 'layer',
        ));
        return a.id;
      case AnimImportMode.frameContent:
        final f = doc.frames[frameIndex];
        if (f.images.length >= AnimFrame.maxImages) throw const AnimationException('This frame has too many pictures.');
        final a = doc.addAsset(p.name, p.width, p.height);
        f.images.add(place(doc, p, a.id));
        return a.id;
      case AnimImportMode.reference:
        if (doc.references.length >= AnimationDocument.maxReferences) throw const AnimationException('Too many reference images.');
        final a = doc.addAsset(p.name, p.width, p.height);
        doc.references.add(place(doc, p, a.id, opacity: 0.5));
        return a.id;
      case AnimImportMode.sequence:
        throw StateError('Use commitSequence for image sequences.');
    }
  }

  /// Adds each picture as its own frame after [afterIndex]. Frames are
  /// created only if all pictures fit within the frame limit.
  static List<String> commitSequence(AnimationDocument doc, List<PreparedAnimImage> pics, {required int afterIndex}) {
    if (doc.frames.length + pics.length > AnimationDocument.maxFrames) {
      throw AnimationException('A sequence of ${pics.length} would exceed the ${AnimationDocument.maxFrames} frame limit.');
    }
    if (doc.assets.length + pics.length > AnimationDocument.maxAssets) {
      throw const AnimationException('Too many imported images in this animation.');
    }
    final ids = <String>[];
    var at = afterIndex;
    for (final p in pics) {
      final f = doc.addFrame(after: at);
      at = doc.frames.indexOf(f);
      final a = doc.addAsset(p.name, p.width, p.height);
      f.images.add(place(doc, p, a.id));
      ids.add(a.id);
    }
    return ids;
  }

  /// Sorts picked files for a sequence: "frame2" before "frame10".
  static List<T> sortNatural<T>(List<T> items, String Function(T) name) =>
      [...items]..sort((a, b) => ImportRules.naturalCompare(name(a), name(b)));
}
