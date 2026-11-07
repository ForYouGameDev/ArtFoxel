import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../data/sketch_storage.dart';

/// Sketch documents live next to the app's private documents, one folder per
/// project id.
final sketchStorageProvider = FutureProvider<SketchStorage>((ref) async {
  final documents = await getApplicationDocumentsDirectory();
  return SketchStorage(Directory('${documents.path}/artfoxel/sketches'));
});
