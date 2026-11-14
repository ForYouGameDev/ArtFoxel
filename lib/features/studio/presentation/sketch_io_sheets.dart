import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../imaging/application/export_service.dart';
import '../../imaging/data/timelapse_store.dart';
import '../../imaging/domain/export_model.dart';
import '../../imaging/domain/image_sniffer.dart';
import '../../imaging/domain/import_rules.dart';
import '../../imaging/domain/ora_writer.dart';
import '../../imaging/domain/timelapse.dart';
import '../../project/data/project_files.dart';
import '../../project/domain/artfoxel_package.dart';
import '../../projects/domain/art_project.dart';
import '../application/sketch_controller.dart';

void _snack(BuildContext c, String m) {
  if (!c.mounted) return;
  ScaffoldMessenger.of(c)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(m)));
}

enum SketchImportMode { newLayer, replaceLayer, reference }

/// Import without leaving Sketch Studio: new layer, replace the selected
/// image layer, or add to the reference board (never exported).
Future<void> showSketchImportSheet(BuildContext context, SketchController controller) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (c) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        ListTile(
          leading: const Icon(Icons.add_photo_alternate_outlined),
          title: const Text('Import as new layer'),
          subtitle: const Text('One or several images. Aspect ratio is kept.'),
          onTap: () {
            Navigator.pop(c);
            runSketchImport(context, controller, SketchImportMode.newLayer);
          },
        ),
        ListTile(
          leading: const Icon(Icons.swap_horiz),
          title: const Text('Replace selected image layer'),
          subtitle: const Text('Keeps name, blend mode, opacity and mask.'),
          enabled: controller.activeLayer.isImage,
          onTap: () {
            Navigator.pop(c);
            runSketchImport(context, controller, SketchImportMode.replaceLayer);
          },
        ),
        ListTile(
          leading: const Icon(Icons.push_pin_outlined),
          title: const Text('Add as reference'),
          subtitle: const Text('Stays outside the artwork and every export.'),
          onTap: () {
            Navigator.pop(c);
            runSketchImport(context, controller, SketchImportMode.reference);
          },
        ),
        const Padding(padding: EdgeInsets.all(12), child: Text('PNG, JPG, WebP and GIF (first frame). HEIC is not supported yet.')),
      ]),
    ),
  );
}

Future<void> runSketchImport(BuildContext context, SketchController controller, SketchImportMode mode) async {
  try {
    final r = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ImportRules.pickerExtensions,
      withData: true,
      allowMultiple: mode != SketchImportMode.replaceLayer,
    );
    if (r == null || r.files.isEmpty) return;
    final files = [for (final f in r.files) if (f.bytes != null) f];
    if (files.isEmpty) {
      _snack(context, 'The selected files could not be read.');
      return;
    }
    var done = 0;
    // A single image gets the placement dialog; several are fitted.
    if (files.length == 1 && mode != SketchImportMode.reference) {
      final bytes = files.first.bytes!;
      final plan = ImportRules.plan(bytes, fileName: files.first.name);
      if (!context.mounted) return;
      final placement = await showPlacementDialog(context, controller.data.width, controller.data.height, plan.info.width, plan.info.height);
      if (placement == null) return;
      final ok = mode == SketchImportMode.replaceLayer
          ? await controller.replaceImageLayer(controller.activeLayerId, bytes, files.first.name, placement: placement)
          : await controller.importImageAsLayer(bytes, files.first.name, placement: placement);
      if (ok) done++;
    } else {
      for (final f in files) {
        final ok = mode == SketchImportMode.reference
            ? await controller.importImageAsReference(f.bytes!, f.name)
            : await controller.importImageAsLayer(f.bytes!, f.name);
        if (ok) done++;
      }
    }
    if (done > 0) {
      // Straight into Move / Resize so the picture can be sized with fingers.
      controller.setTool(SketchTool.draw);
      controller.setTool(SketchTool.move);
    }
    if (context.mounted && done > 0) _snack(context, 'Imported $done of ${files.length} image(s). Drag, pinch or use the handles to resize.');
  } on ImageImportException catch (e) {
    _snack(context, e.message);
  } catch (_) {
    _snack(context, 'The image picker or import failed.');
  }
}

/// Fit, scale, rotation, offset, flip and crop with a live outline preview.
Future<ImagePlacement?> showPlacementDialog(BuildContext context, int docW, int docH, int imgW, int imgH) {
  return showDialog<ImagePlacement>(
    context: context,
    builder: (c) => _PlacementDialog(docW: docW, docH: docH, imgW: imgW, imgH: imgH),
  );
}

class _PlacementDialog extends StatefulWidget {
  const _PlacementDialog({required this.docW, required this.docH, required this.imgW, required this.imgH});
  final int docW, docH, imgW, imgH;
  @override
  State<_PlacementDialog> createState() => _PlacementDialogState();
}

class _PlacementDialogState extends State<_PlacementDialog> {
  ImagePlacement p = const ImagePlacement();

  @override
  Widget build(BuildContext context) {
    final crop = p.crop;
    Widget slider(String label, double v, double min, double max, void Function(double) on) => Row(children: [
          SizedBox(width: 74, child: Text(label, style: Theme.of(context).textTheme.labelSmall)),
          Expanded(child: Slider(value: v.clamp(min, max), min: min, max: max, onChanged: (x) => setState(() => on(x)))),
        ]);
    return AlertDialog(
      title: const Text('Place image'),
      content: SizedBox(
        width: 360,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            AspectRatio(
              aspectRatio: widget.docW / widget.docH,
              child: CustomPaint(painter: _PlacementPainter(p, widget.docW, widget.docH, widget.imgW, widget.imgH, Theme.of(context).colorScheme.primary)),
            ),
            const SizedBox(height: 8),
            SegmentedButton<FitMode>(
              segments: const [
                ButtonSegment(value: FitMode.fit, label: Text('Fit')),
                ButtonSegment(value: FitMode.fill, label: Text('Fill')),
                ButtonSegment(value: FitMode.original, label: Text('1:1')),
                ButtonSegment(value: FitMode.stretch, label: Text('Stretch')),
              ],
              selected: {p.fit},
              onSelectionChanged: (s) => setState(() => p = p.copyWith(fit: s.first)),
            ),
            slider('Scale', p.scale, 0.1, 4, (v) => p = p.copyWith(scale: v)),
            slider('Rotate', p.rotationDeg, -180, 180, (v) => p = p.copyWith(rotationDeg: v.roundToDouble())),
            slider('Move X', p.dx, -widget.docW.toDouble(), widget.docW.toDouble(), (v) => p = p.copyWith(dx: v)),
            slider('Move Y', p.dy, -widget.docH.toDouble(), widget.docH.toDouble(), (v) => p = p.copyWith(dy: v)),
            slider('Crop left', crop.left, 0, 0.9, (v) => p = p.copyWith(crop: CropRect(left: v, top: crop.top, width: crop.width, height: crop.height).clamped())),
            slider('Crop top', crop.top, 0, 0.9, (v) => p = p.copyWith(crop: CropRect(left: crop.left, top: v, width: crop.width, height: crop.height).clamped())),
            slider('Crop width', crop.width, 0.05, 1, (v) => p = p.copyWith(crop: CropRect(left: crop.left, top: crop.top, width: v, height: crop.height).clamped())),
            slider('Crop height', crop.height, 0.05, 1, (v) => p = p.copyWith(crop: CropRect(left: crop.left, top: crop.top, width: crop.width, height: v).clamped())),
            Row(children: [
              FilterChip(label: const Text('Flip H'), selected: p.flipH, onSelected: (v) => setState(() => p = p.copyWith(flipH: v))),
              const SizedBox(width: 8),
              FilterChip(label: const Text('Flip V'), selected: p.flipV, onSelected: (v) => setState(() => p = p.copyWith(flipV: v))),
              const Spacer(),
              TextButton(onPressed: () => setState(() => p = const ImagePlacement()), child: const Text('Reset')),
            ]),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(context, p), child: const Text('Import')),
      ],
    );
  }
}

class _PlacementPainter extends CustomPainter {
  _PlacementPainter(this.p, this.docW, this.docH, this.imgW, this.imgH, this.color);
  final ImagePlacement p;
  final int docW, docH, imgW, imgH;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFFF2F2F2));
    final k = size.width / docW;
    final cw = imgW * p.crop.width, ch = imgH * p.crop.height;
    final m = p.toAffine(docW, docH, imgW, imgH);
    Offset pt(double x, double y) => Offset((m.a * x + m.c * y + m.e) * k, (m.b * x + m.d * y + m.f) * k);
    final path = Path()
      ..moveTo(pt(0, 0).dx, pt(0, 0).dy)
      ..lineTo(pt(cw, 0).dx, pt(cw, 0).dy)
      ..lineTo(pt(cw, ch).dx, pt(cw, ch).dy)
      ..lineTo(pt(0, ch).dx, pt(0, ch).dy)
      ..close();
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    canvas.drawPath(path, Paint()..color = color.withOpacity(0.25));
    canvas.drawPath(path, Paint()..color = color..style = PaintingStyle.stroke..strokeWidth = 2);
    canvas.restore();
    canvas.drawRect((Offset.zero & size).deflate(0.5), Paint()..color = Colors.black38..style = PaintingStyle.stroke);
  }

  @override
  bool shouldRepaint(covariant _PlacementPainter old) => old.p != p;
}

// ------------------------------------------------------------------- export

Future<void> showSketchExportSheet(
  BuildContext context,
  SketchController controller, {
  required String projectName,
  String? projectId,
  ProjectFiles? files,
}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (c) => _ExportSheet(host: context, controller: controller, projectName: projectName, projectId: projectId, files: files),
  );
}

class _ExportSheet extends StatefulWidget {
  const _ExportSheet({required this.host, required this.controller, required this.projectName, this.projectId, this.files});
  final BuildContext host;
  final SketchController controller;
  final String projectName;
  final String? projectId;
  final ProjectFiles? files;
  @override
  State<_ExportSheet> createState() => _ExportSheetState();
}

class _ExportSheetState extends State<_ExportSheet> {
  ExportOptions o = const ExportOptions();
  double scale = 1;
  bool busy = false;
  String? status;

  ExportOptions get _effective {
    final w = (widget.controller.data.width * scale).round();
    return o.copyWith(width: w, height: null);
  }

  Future<void> _save(Uint8List bytes, String name) async {
    final path = await FilePicker.platform.saveFile(dialogTitle: 'Save export', fileName: name, bytes: bytes);
    if (path != null && !Platform.isAndroid && !Platform.isIOS) {
      await File(path).writeAsBytes(bytes, flush: true);
    }
  }

  Future<void> _run(Future<String> Function() job) async {
    setState(() {
      busy = true;
      status = 'Working…';
    });
    try {
      final s = await job();
      if (mounted) setState(() => status = s);
    } on ExportException catch (e) {
      if (mounted) setState(() => status = e.message);
    } catch (_) {
      if (mounted) setState(() => status = 'The export failed. Nothing was saved as a finished file.');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<String> _image() async {
    final r = await ExportService.exportSketch(widget.controller, _effective, widget.projectName);
    await _save(r.bytes, r.fileName);
    return r.summary;
  }

  Future<String> _ora() async {
    final c = widget.controller;
    final merged = await ExportService.exportSketch(c, const ExportOptions(), widget.projectName);
    final nodes = await c.renderLayerNodes();
    final bytes = OraWriter.build(width: c.data.width, height: c.data.height, nodes: nodes, mergedPng: merged.bytes);
    await _save(bytes, '${widget.projectName.replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_')}.ora');
    return 'OpenRaster layered file written (${(bytes.length / 1024).toStringAsFixed(0)} KB). Layers, groups, opacity, visibility and blend modes are kept; masks and filters are baked in.';
  }

  Future<String> _artfoxel() async {
    final id = widget.projectId, files = widget.files;
    if (id == null || files == null) throw const ExportException('Save this drawing as a project first.');
    await widget.controller.saveNow();
    final bytes = await files.exportPackage(ArtProject(id: id, name: widget.projectName, kind: ProjectKind.sketch.label, updatedAt: DateTime.now()));
    await _save(bytes, '${widget.projectName.replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_')}.artfoxel');
    return 'Project backup package written and checked (${(bytes.length / 1024).toStringAsFixed(0)} KB).';
  }

  Future<String> _timelapse({required bool gif}) async {
    final id = widget.projectId, files = widget.files;
    if (id == null || files == null) throw const ExportException('Timelapse needs a saved project.');
    final store = TimelapseStore(Directory('${files.dir(ProjectKind.sketch, id).path}/timelapse'));
    final frames = await store.readAll();
    if (frames.length < 2) throw const ExportException('Not enough drawing has been recorded yet. Draw a bit more and try again.');
    if (gif) {
      final bytes = TimelapseExporter.buildGif(frames);
      await _save(bytes, '${widget.projectName.replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_')}_timelapse.gif');
      return 'Timelapse GIF from ${frames.length} drawing steps, checked OK. MP4 is not available on this build.';
    }
    final dir = await FilePicker.platform.getDirectoryPath(dialogTitle: 'Folder for the PNG frames');
    if (dir == null) return 'Cancelled.';
    for (var i = 0; i < frames.length; i++) {
      await File('$dir/frame_${(i + 1).toString().padLeft(5, '0')}.png').writeAsBytes(frames[i], flush: true);
    }
    return '${frames.length} PNG frames written to the chosen folder.';
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final size = ExportPlanner.size(c.data.width, c.data.height, _effective.copyWith(width: (c.data.width * scale).round()));
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Text('Export', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          SegmentedButton<ExportFormat>(
            segments: [for (final f in ExportFormat.values) ButtonSegment(value: f, label: Text(f.label))],
            selected: {o.format},
            onSelectionChanged: (s) => setState(() => o = o.copyWith(format: s.first)),
          ),
          if (o.format.supportsAlpha)
            SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Transparent background'), value: o.transparent, onChanged: (v) => setState(() => o = o.copyWith(transparent: v)))
          else
            const Padding(padding: EdgeInsets.symmetric(vertical: 6), child: Text('JPEG has no transparency; the canvas background colour is used.')),
          if (o.format.lossy)
            Row(children: [
              const Text('Quality'),
              Expanded(child: Slider(value: o.quality.toDouble(), min: 1, max: 100, divisions: 99, label: '${o.quality}', onChanged: (v) => setState(() => o = o.copyWith(quality: v.round())))),
            ]),
          Row(children: [
            const Text('Size'),
            Expanded(child: Slider(value: scale, min: 0.25, max: 4, divisions: 15, label: '×${scale.toStringAsFixed(2)}', onChanged: (v) => setState(() => scale = v))),
            Text('${size.width}×${size.height}'),
          ]),
          SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Include reference images'), subtitle: const Text('Off by default: references are not artwork.'), value: o.includeReferences, onChanged: (v) => setState(() => o = o.copyWith(includeReferences: v))),
          const SizedBox(height: 4),
          FilledButton.icon(onPressed: busy ? null : () => _run(_image), icon: const Icon(Icons.image_outlined), label: Text('Export ${o.format.label}')),
          const Divider(height: 24),
          Text('Layered & backup', style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 6),
          Wrap(spacing: 8, runSpacing: 8, children: [
            OutlinedButton(onPressed: busy ? null : () => _run(_ora), child: const Text('Layered file (.ora)')),
            OutlinedButton(onPressed: busy ? null : () => _run(_artfoxel), child: const Text('Project backup (.artfoxel)')),
            OutlinedButton(onPressed: busy ? null : () => _run(() => _timelapse(gif: true)), child: const Text('Timelapse GIF')),
            OutlinedButton(onPressed: busy ? null : () => _run(() => _timelapse(gif: false)), child: const Text('Timelapse PNG frames')),
          ]),
          const SizedBox(height: 8),
          const Text('PSD is not supported: no verified PSD writer is available. The .ora file opens in Krita, GIMP and MyPaint and keeps layers. Timelapse MP4 is not offered.', style: TextStyle(fontSize: 12)),
          if (status != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(status!)),
          if (busy) const Padding(padding: EdgeInsets.only(top: 8), child: LinearProgressIndicator()),
        ]),
      ),
    );
  }
}

// ----------------------------------------------------------------- versions

Future<void> showVersionsDialog(BuildContext context, ProjectFiles files, String projectId, SketchController controller) {
  return showDialog<void>(context: context, builder: (c) => _VersionsDialog(files: files, id: projectId, controller: controller, host: context));
}

class _VersionsDialog extends StatefulWidget {
  const _VersionsDialog({required this.files, required this.id, required this.controller, required this.host});
  final ProjectFiles files;
  final String id;
  final SketchController controller;
  final BuildContext host;
  @override
  State<_VersionsDialog> createState() => _VersionsDialogState();
}

class _VersionsDialogState extends State<_VersionsDialog> {
  List<VersionInfo>? list;
  String? error;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    try {
      final l = await widget.files.listVersions(ProjectKind.sketch, widget.id);
      if (mounted) setState(() => list = l);
    } catch (_) {
      if (mounted) setState(() => error = 'Restore points could not be read.');
    }
  }

  Future<void> _create() async {
    await widget.controller.saveNow();
    try {
      await widget.files.createVersion(ProjectKind.sketch, widget.id, 'Checkpoint ${DateTime.now().toIso8601String().substring(0, 16).replaceAll('T', ' ')}');
      await _reload();
    } on ProjectFileException catch (e) {
      if (mounted) setState(() => error = e.message);
    }
  }

  Future<void> _restore(VersionInfo v) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Restore this version?'),
        content: const Text('Your current drawing is saved as a restore point first, then replaced. Close and reopen the drawing to see it.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Restore')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await widget.controller.saveNow();
      await widget.files.createVersion(ProjectKind.sketch, widget.id, 'Before restore');
      await widget.files.restoreVersion(ProjectKind.sketch, widget.id, v.id);
      if (mounted) Navigator.pop(context);
      _snack(widget.host, 'Restored. Reopen the drawing from the library to continue from that version.');
    } on ProjectFileException catch (e) {
      if (mounted) setState(() => error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = list;
    return AlertDialog(
      title: const Text('Restore points'),
      content: SizedBox(
        width: 360,
        child: l == null
            ? const SizedBox(height: 80, child: Center(child: CircularProgressIndicator()))
            : Column(mainAxisSize: MainAxisSize.min, children: [
                if (error != null) Text(error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                if (l.isEmpty) const Text('No restore points yet.'),
                Flexible(
                  child: ListView(shrinkWrap: true, children: [
                    for (final v in l)
                      ListTile(
                        dense: true,
                        title: Text(v.auto ? 'Automatic' : v.label),
                        subtitle: Text(v.createdAt.toLocal().toString().substring(0, 16)),
                        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                          IconButton(tooltip: 'Restore', icon: const Icon(Icons.restore), onPressed: () => _restore(v)),
                          IconButton(tooltip: 'Delete', icon: const Icon(Icons.delete_outline), onPressed: () async {
                            await widget.files.deleteVersion(ProjectKind.sketch, widget.id, v.id);
                            await _reload();
                          }),
                        ]),
                      ),
                  ]),
                ),
              ]),
      ),
      actions: [
        TextButton(onPressed: _create, child: const Text('New restore point')),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
      ],
    );
  }
}
