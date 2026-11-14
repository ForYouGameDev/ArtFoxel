import 'dart:convert';
import 'dart:typed_data';

import '../../../core/io/zip_codec.dart';
import '../../studio/domain/layer_blend.dart';

/// OpenRaster (.ora) is the layered interchange fallback: PSD is a closed,
/// very large format and is NOT implemented. ORA is an open ZIP format that
/// Krita, GIMP, MyPaint and others open.
///
/// What is preserved: layer order, groups, names, visibility, opacity and
/// the common blend modes, per-layer pixels at document size.
/// What is NOT: layer masks (baked into the layer pixels), non-destructive
/// filters (baked), clipping to the layer below (baked approximation is not
/// possible, so clipped layers are flagged in their name), vector strokes and
/// shapes (rasterised), brush settings, references and drawing aids.
class OraNode {
  OraNode.layer({
    required this.name,
    required this.png,
    this.opacity = 1,
    this.visible = true,
    this.blend = LayerBlend.normal,
  }) : children = const [];

  OraNode.group({
    required this.name,
    required this.children,
    this.opacity = 1,
    this.visible = true,
    this.blend = LayerBlend.normal,
  }) : png = null;

  final String name;
  final Uint8List? png;
  final List<OraNode> children;
  final double opacity;
  final bool visible;
  final LayerBlend blend;
  bool get isGroup => png == null;
}

abstract final class OraWriter {
  static const _composite = {
    LayerBlend.normal: 'svg:src-over',
    LayerBlend.multiply: 'svg:multiply',
    LayerBlend.screen: 'svg:screen',
    LayerBlend.overlay: 'svg:overlay',
    LayerBlend.darken: 'svg:darken',
    LayerBlend.lighten: 'svg:lighten',
    LayerBlend.colorDodge: 'svg:color-dodge',
    LayerBlend.colorBurn: 'svg:color-burn',
    LayerBlend.linearDodge: 'svg:plus',
    LayerBlend.difference: 'svg:difference',
    LayerBlend.exclusion: 'svg:exclusion',
    LayerBlend.softLight: 'svg:soft-light',
    LayerBlend.hardLight: 'svg:hard-light',
    LayerBlend.hue: 'svg:hue',
    LayerBlend.saturation: 'svg:saturation',
    LayerBlend.color: 'svg:color',
    LayerBlend.luminosity: 'svg:luminosity',
  };

  static String compositeOp(LayerBlend b) => _composite[b] ?? 'svg:src-over';

  static String _esc(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;')
      .replaceAll(RegExp(r'[\u0000-\u0008\u000B\u000C\u000E-\u001F]'), '');

  /// [nodes] are listed top-most first (the ORA convention).
  static Uint8List build({
    required int width,
    required int height,
    required List<OraNode> nodes,
    required Uint8List mergedPng,
    Uint8List? thumbnailPng,
  }) {
    if (width < 1 || height < 1) throw ArgumentError('size');
    final zip = ZipWriter();
    // `mimetype` must be first and stored uncompressed.
    zip.add('mimetype', ascii.encode('image/openraster'), compress: false);
    final files = <String, Uint8List>{};
    var counter = 0;

    String stack(List<OraNode> list, String indent) {
      final b = StringBuffer();
      for (final n in list) {
        final common = 'name="${_esc(n.name)}" opacity="${n.opacity.clamp(0.0, 1.0).toStringAsFixed(4)}" '
            'visibility="${n.visible ? 'visible' : 'hidden'}" composite-op="${compositeOp(n.blend)}"';
        if (n.isGroup) {
          b
            ..writeln('$indent<stack $common>')
            ..write(stack(n.children, '$indent  '))
            ..writeln('$indent</stack>');
        } else {
          counter++;
          final path = 'data/layer${counter.toString().padLeft(3, '0')}.png';
          files[path] = n.png!;
          b.writeln('$indent<layer $common src="$path" x="0" y="0"/>');
        }
      }
      return b.toString();
    }

    final body = stack(nodes, '    ');
    final xml = '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<image version="0.0.3" w="$width" h="$height" xres="72" yres="72">\n'
        '  <stack>\n$body  </stack>\n</image>\n';
    zip.add('stack.xml', utf8.encode(xml));
    for (final f in files.entries) {
      zip.add(f.key, f.value, compress: false);
    }
    zip.add('mergedimage.png', mergedPng, compress: false);
    if (thumbnailPng != null) zip.add('Thumbnails/thumbnail.png', thumbnailPng, compress: false);
    return zip.finish();
  }
}
