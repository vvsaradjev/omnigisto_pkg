# omnigisto_pkg

A lightweight, fast, and memory-efficient Dart & Flutter library for reading Aperio SVS (Whole Slide Image / WSI) files. It enables positional metadata parsing, pyramid resolution level inspection, on-demand tile extraction, and associated image retrieval (thumbnail, label, macro) without loading multi-gigabyte files into RAM.

---

## Features

- **Memory-Efficient & Fast**: Uses `RandomAccessFile` and `ByteData` to stream and read TIFF/SVS headers and tile offsets positionally without loading the entire multi-gigabyte image into memory.
- **Full Pyramid Inspection**: Retrieve dimensions, tile configurations, compression formats, and resolution levels for the whole slide pyramid.
- **On-Demand Tile Extraction**: Extract specific image tiles by level and tile grid coordinates (`tileX`, `tileY`) as raw compressed image bytes (`Uint8List`).
- **Associated Images**: Extract non-tiled associated images such as `thumbnail`, `label` (slide barcode/label), and `macro` (full slide preview).
- **Aperio Metadata Parser**: Automatically parses Aperio header properties, compression quality (`Q`), microns-per-pixel (`MPPS`), scan dimensions, and custom key-value pairs.
- **Cross-Platform**: Works across all platforms supported by Dart `dart:io` (Flutter for Android, iOS, macOS, Windows, Linux).

---

## Getting Started

### 1. Add dependency

Add `omnigisto_pkg` to your `pubspec.yaml`:

```yaml
dependencies:
  omnigisto_pkg:
    path: ../omnigisto_pkg # or from pub.dev / git
```

Then run:

```bash
flutter pub get
# or for pure Dart projects:
dart pub get
```

### 2. Import package

```dart
import 'package:omnigisto_pkg/metadata_read.dart';
import 'package:omnigisto_pkg/types/types.dart';
```

---

## Usage

### 1. Opening an SVS File

Open the SVS file handle using `openSvsFile`. Always close the handle when finished (or use a `try`/`finally` block).

```dart
import 'package:omnigisto_pkg/metadata_read.dart';

void main() async {
  final svs = await openSvsFile('/path/to/slide.svs');
  if (svs == null) {
    print('Failed to open SVS file: invalid file path or format');
    return;
  }

  try {
    // Perform operations...
  } finally {
    await svs.close();
  }
}
```

---

### 2. Reading Basic Metadata

To quickly read primary image dimensions and parsed Aperio properties:

```dart
final metadata = await readSvsMetadata(svs);
if (metadata != null) {
  print('Width: ${metadata.width}, Height: ${metadata.height}');
  print('Tile Size: ${metadata.tileWidth}x${metadata.tileHeight}');
  print('Compression: ${metadata.compression}');
  print('App Properties: ${metadata.properties}');
  print('MPP: ${metadata.properties['MPP']}');
}
```

---

### 3. Reading Full Pyramid Metadata & Levels

To inspect all resolution pyramid layers and associated images:

```dart
final fullMeta = await readFullSvsMetadata(svs);
if (fullMeta != null) {
  print('Pyramid Levels: ${fullMeta.levels.length}');
  for (int i = 0; i < fullMeta.levels.length; i++) {
    final level = fullMeta.levels[i];
    print('Level $i: ${level.width}x${level.height}, Tile: ${level.tileWidth}x${level.tileHeight}');
  }

  print('Associated images: ${fullMeta.associations.keys.toList()}');
  fullMeta.associations.forEach((key, info) {
    print('$key: ${info.width}x${info.height}');
  });
}
```

---

### 4. Extracting Associated Images (Thumbnail, Label, Macro)

Extract raw bytes for preview images and display them directly in Flutter:

```dart
import 'dart:typed_data';
import 'package:flutter/material.dart';

// Extract thumbnail, label, or macro
final Uint8List? thumbBytes = await extractSvsImage(svs, 'thumbnail');
final Uint8List? labelBytes = await extractSvsImage(svs, 'label');
final Uint8List? macroBytes = await extractSvsImage(svs, 'macro');

// Example Flutter Widget rendering
Widget buildImage(Uint8List? bytes) {
  if (bytes == null) return const Text('Image not available');
  return Image.memory(bytes);
}
```

---

### 5. Extracting Individual Tiles

Extract specific tiles on demand for viewport rendering or deep-zoom viewers:

```dart
final fullMeta = await readFullSvsMetadata(svs);
if (fullMeta != null && fullMeta.levels.isNotEmpty) {
  const int levelIndex = 0; // 0 = highest resolution baseline
  final level = fullMeta.levels[levelIndex];

  if (level.tileWidth != null && level.tileHeight != null) {
    int totalCols = (level.width + level.tileWidth! - 1) ~/ level.tileWidth!;
    int totalRows = (level.height + level.tileHeight! - 1) ~/ level.tileHeight!;

    print('Grid size: $totalCols columns x $totalRows rows');

    // Extract tile at coordinate (tileX: 0, tileY: 0)
    final Uint8List? tileBytes = await extractSvsTile(svs, levelIndex, 0, 0);
    if (tileBytes != null) {
      print('Extracted tile (${tileBytes.length} bytes)');
    }
  }
}
```

---

## API Reference

### Functions

| Function | Description |
| :--- | :--- |
| `Future<SvsFile?> openSvsFile(String path)` | Opens an SVS file and parses the TIFF header. |
| `Future<SvsMetadata?> readSvsMetadata(SvsFile svs)` | Reads basic metadata of the primary image. |
| `Future<SvsFullMetadata?> readFullSvsMetadata(SvsFile svs)` | Reads all pyramid levels and associated image metadata. |
| `Future<Uint8List?> extractSvsImage(SvsFile svs, String type)` | Extracts raw bytes for `'thumbnail'`, `'label'`, or `'macro'`. |
| `Future<Uint8List?> extractSvsTile(SvsFile svs, int layerIndex, int tileX, int tileY)` | Extracts raw bytes for a specific tile at the given grid coordinates. |

### Classes

| Class | Description |
| :--- | :--- |
| `SvsFile` | Encapsulates the `RandomAccessFile`, endianness, and first IFD offset. Call `close()` when done. |
| `SvsMetadata` | Contains `width`, `height`, `tileWidth`, `tileHeight`, `compression`, and `properties` map for the primary image. |
| `SvsFullMetadata` | Contains `levels` (`List<SvsImageInfo>`) and `associations` (`Map<String, SvsImageInfo>`). |
| `SvsImageInfo` | Detailed metadata for a single layer or associated image (`width`, `height`, `tileWidth`, `tileHeight`, `compression`, `properties`, `type`). |

---

## Example Project

A complete runnable Flutter example demonstrating file picking, metadata inspection, and associated image extraction is available in the [`example/`](example/) directory.

---

## License

This project is licensed under the BSD 3-Clause License - see the [LICENSE](LICENSE) file for details.
