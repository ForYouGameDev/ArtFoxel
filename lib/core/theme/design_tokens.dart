import 'package:flutter/material.dart';

class ArtFoxelColors {
  ArtFoxelColors._();

  static const midnight = Color(0xFF090B14);
  static const navy = Color(0xFF111629);
  static const panel = Color(0xFF171D32);
  static const violet = Color(0xFF8A6CFF);
  static const blue = Color(0xFF438BFF);
  static const cyan = Color(0xFF35D5E8);
  static const magenta = Color(0xFFE45AD7);
  static const orange = Color(0xFFFF8B3D);
  static const pale = Color(0xFFF4F2FF);
}

class ArtFoxelSpacing {
  ArtFoxelSpacing._();

  static const xxs = 4.0;
  static const xs = 8.0;
  static const sm = 12.0;
  static const md = 16.0;
  static const lg = 24.0;
  static const xl = 32.0;
  static const xxl = 48.0;
}

class ArtFoxelRadius {
  ArtFoxelRadius._();

  static const sm = 12.0;
  static const md = 18.0;
  static const lg = 26.0;
  static const pill = 100.0;
}

class ArtFoxelMotion {
  ArtFoxelMotion._();

  static const fast = Duration(milliseconds: 160);
  static const standard = Duration(milliseconds: 240);
}

class ArtFoxelGradients {
  ArtFoxelGradients._();

  static const primary = LinearGradient(
    colors: [ArtFoxelColors.blue, ArtFoxelColors.violet, ArtFoxelColors.magenta],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );
  static const sketch = LinearGradient(
    colors: [Color(0xFF2478D8), Color(0xFF7556E8)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );
  static const animation = LinearGradient(
    colors: [Color(0xFF714CDE), Color(0xFFCE55C8)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );
  static const surfaceGlow = LinearGradient(
    colors: [Color(0xFF22213D), Color(0xFF141A2E)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );
}
