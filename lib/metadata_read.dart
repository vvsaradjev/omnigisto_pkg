// //
// Copyright (c) 2026, Vladislav Saradzev
// All rights reserved.


import 'dart:io';
import 'dart:typed_data';
import 'package:omnigisto_pkg/types/types.dart';

/// Represents an open SVS file handle and TIFF header information.
class SvsFile {
  /// The underlying random access file handle.
  final RandomAccessFile raf;

  /// The byte order (endianness) of the TIFF/SVS file.
  final Endian endian;

  /// Byte offset to the first Image File Directory (IFD).
  final int firstIfdOffset;

  /// Creates an [SvsFile] instance.
  SvsFile(this.raf, this.endian, this.firstIfdOffset);

  /// Closes the underlying file handle.
  Future<void> close() async {
    await raf.close();
  }
}

/// Opens an SVS file at the specified [path] and reads its TIFF header.
///
/// Returns an [SvsFile] instance if the file is a valid SVS/TIFF file, or `null` if opening or validation fails.
Future<SvsFile?> openSvsFile(String path) async {
  final file = File(path);
  if (!await file.exists()) return null;

  final raf = await file.open();
  try {
    final headerBytes = await raf.read(8);
    if (headerBytes.length < 8) {
      await raf.close();
      return null;
    }

    final bd = ByteData.sublistView(headerBytes);
    Endian endian;
    final byteOrder = String.fromCharCodes(headerBytes.sublist(0, 2));
    if (byteOrder == 'II') {
      endian = Endian.little;
    } else if (byteOrder == 'MM') {
      endian = Endian.big;
    } else {
      await raf.close();
      return null;
    }

    final magic = bd.getUint16(2, endian);
    if (magic != 42) {
      await raf.close();
      return null;
    }

    int ifdOffset = bd.getUint32(4, endian);
    return SvsFile(raf, endian, ifdOffset);
  } catch (e) {
    await raf.close();
    return null;
  }
}

/// Extracts the raw image bytes for an associated image (e.g. 'thumbnail', 'label', or 'macro') from an SVS file.
///
/// [svs] is the open [SvsFile].
/// [type] is the image type identifier to extract ('thumbnail', 'label', or 'macro').
/// Returns the raw byte data, or `null` if the requested image type was not found.
Future<Uint8List?> extractSvsImage(SvsFile svs, String type) async {
  final raf = svs.raf;
  final endian = svs.endian;
  int ifdOffset = svs.firstIfdOffset;

  while (ifdOffset != 0) {
    await raf.setPosition(ifdOffset);
    final numEntriesBytes = await raf.read(2);
    if (numEntriesBytes.length < 2) break;

    final numEntries = ByteData.sublistView(numEntriesBytes).getUint16(0, endian);

    int width = 0;
    int height = 0;
    int? tileWidth;
    int? tileHeight;
    String? description;
    List<int> stripOffsets = [];
    List<int> stripByteCounts = [];

    int nextIfdOffsetPos = ifdOffset + 2 + numEntries * 12;

    for (var i = 0; i < numEntries; i++) {
      final entryBytes = await raf.read(12);
      if (entryBytes.length < 12) break;
      final entryBd = ByteData.sublistView(entryBytes);

      final tag = entryBd.getUint16(0, endian);
      final dataType = entryBd.getUint16(2, endian);
      final count = entryBd.getUint32(4, endian);
      final valueOffset = entryBd.getUint32(8, endian);

      if (tag == 256) {
        width = _readTiffValue(dataType, count, valueOffset, entryBd, 8, endian);
      } else if (tag == 257) {
        height = _readTiffValue(dataType, count, valueOffset, entryBd, 8, endian);
      } else if (tag == 322) {
        tileWidth = _readTiffValue(dataType, count, valueOffset, entryBd, 8, endian);
      } else if (tag == 323) {
        tileHeight = _readTiffValue(dataType, count, valueOffset, entryBd, 8, endian);
      } else if (tag == 273) {
        stripOffsets = await _readTiffArray(raf, dataType, count, valueOffset, endian);
      } else if (tag == 279) {
        stripByteCounts = await _readTiffArray(raf, dataType, count, valueOffset, endian);
      } else if (tag == 270) {
        final currentPos = await raf.position();
        await raf.setPosition(valueOffset);
        final descBytes = await raf.read(count);
        var length = descBytes.length;
        if (length > 0 && descBytes[length - 1] == 0) length--;
        description = String.fromCharCodes(descBytes.sublist(0, length)).trim();
        await raf.setPosition(currentPos);
      }
    }

    // Determine the type of the current image
    String? currentImageType;
    if (description != null) {
      if (description.startsWith('label')) {
        currentImageType = 'label';
      } else if (description.startsWith('macro')) {
        currentImageType = 'macro';
      } else if (description.startsWith('thumbnail')) {
        currentImageType = 'thumbnail';
      }
    }

    if (currentImageType == null && tileWidth == null && tileHeight == null) {
      if (width > 0 && height > 0) {
        double aspect = width / height;
        if (width < 2000 && height < 2000) {
          if (width == 687 && height == 687) {
            currentImageType = 'label';
          } else if (width <= 1024 && (aspect > 0.5 && aspect < 2.0)) {
            currentImageType = 'thumbnail';
          }
        }
        if (currentImageType == null && width >= 1500 && height < 1000 && aspect > 2.0) {
          currentImageType = 'macro';
        }
      }
    }

    if (currentImageType == type) {
      if (stripOffsets.isEmpty || stripByteCounts.isEmpty) {
        // Try looking for TileOffsets if StripOffsets is empty (for tiled layers).
        // However, extractSvsImage is typically used for non-tiled associations.
        return null;
      }

      BytesBuilder bb = BytesBuilder();
      for (int i = 0; i < stripOffsets.length; i++) {
        await raf.setPosition(stripOffsets[i]);
        final bytes = await raf.read(stripByteCounts[i]);
        bb.add(bytes);
      }
      return bb.takeBytes();
    }

    await raf.setPosition(nextIfdOffsetPos);
    final nextIfdBytes = await raf.read(4);
    if (nextIfdBytes.length < 4) break;
    ifdOffset = ByteData.sublistView(nextIfdBytes).getUint32(0, endian);
  }

  return null;
}

/// Extracts the raw bytes of a specific tile from a resolution layer in the SVS file.
///
/// [svs] is the open [SvsFile].
/// [layerIndex] is the resolution layer index (0 is the highest resolution / baseline level).
/// [tileX] and [tileY] are the 0-based horizontal and vertical tile coordinates (not pixel coordinates).
/// Returns the raw tile bytes, or `null` if the tile coordinates or layer are invalid.
Future<Uint8List?> extractSvsTile(SvsFile svs, int layerIndex, int tileX, int tileY) async {
  final raf = svs.raf;
  final endian = svs.endian;
  int ifdOffset = svs.firstIfdOffset;

  // 1. Collect all IFDs of layers that are 'level'
  List<int> levelIfdOffsets = [];

  int currentIfd = ifdOffset;
  while (currentIfd != 0) {
    await raf.setPosition(currentIfd);
    final numEntriesBytes = await raf.read(2);
    if (numEntriesBytes.length < 2) break;
    final numEntries = ByteData.sublistView(numEntriesBytes).getUint16(0, endian);

    int? tileWidth;
    // String? description;

    for (var i = 0; i < numEntries; i++) {
      final entryBytes = await raf.read(12);
      if (entryBytes.length < 12) break;
      final entryBd = ByteData.sublistView(entryBytes);
      final tag = entryBd.getUint16(0, endian);
      final type = entryBd.getUint16(2, endian);
      final count = entryBd.getUint32(4, endian);
      final valueOffset = entryBd.getUint32(8, endian);

      if (tag == 322) {
        tileWidth = _readTiffValue(type, count, valueOffset, entryBd, 8, endian);
      }
      // else if (tag == 270) {
      //   final currentPos = await raf.position();
      //   await raf.setPosition(valueOffset);
      //   final descBytes = await raf.read(count);
      //   var length = descBytes.length;
      //   if (length > 0 && descBytes[length - 1] == 0) length--;
      //   description = String.fromCharCodes(descBytes.sublist(0, length)).trim();
      //   await raf.setPosition(currentPos);
      // }
    }

    bool isLevel = false;
    if (tileWidth != null) {
      isLevel = true;
    }

    if (isLevel) {
      levelIfdOffsets.add(currentIfd);
    }

    await raf.setPosition(currentIfd + 2 + numEntries * 12);
    final nextIfdBytes = await raf.read(4);
    if (nextIfdBytes.length < 4) break;
    currentIfd = ByteData.sublistView(nextIfdBytes).getUint32(0, endian);
  }

  if (layerIndex < 0 || layerIndex >= levelIfdOffsets.length) {
    return null;
  }

  int targetIfd = levelIfdOffsets[layerIndex];

  // 2. Read tile parameters from target IFD
  await raf.setPosition(targetIfd);
  final numEntriesBytes = await raf.read(2);
  final numEntries = ByteData.sublistView(numEntriesBytes).getUint16(0, endian);

  int width = 0;
  int height = 0;
  int tileWidth = 0;
  int tileHeight = 0;
  List<int> tileOffsets = [];
  List<int> tileByteCounts = [];

  for (var i = 0; i < numEntries; i++) {
    final entryBytes = await raf.read(12);
    final entryBd = ByteData.sublistView(entryBytes);
    final tag = entryBd.getUint16(0, endian);
    final type = entryBd.getUint16(2, endian);
    final count = entryBd.getUint32(4, endian);
    final valueOffset = entryBd.getUint32(8, endian);

    if (tag == 256) {
      width = _readTiffValue(type, count, valueOffset, entryBd, 8, endian);
    } else if (tag == 257) {
      height = _readTiffValue(type, count, valueOffset, entryBd, 8, endian);
    } else if (tag == 322) {
      tileWidth = _readTiffValue(type, count, valueOffset, entryBd, 8, endian);
    } else if (tag == 323) {
      tileHeight = _readTiffValue(type, count, valueOffset, entryBd, 8, endian);
    } else if (tag == 324) {
      tileOffsets = await _readTiffArray(raf, type, count, valueOffset, endian);
    } else if (tag == 325) {
      tileByteCounts = await _readTiffArray(raf, type, count, valueOffset, endian);
    }
  }

  if (tileWidth == 0 || tileHeight == 0 || tileOffsets.isEmpty) {
    return null;
  }

  int tilesAcross = (width + tileWidth - 1) ~/ tileWidth;
  int tilesDown = (height + tileHeight - 1) ~/ tileHeight;

  if (tileX < 0 || tileX >= tilesAcross || tileY < 0 || tileY >= tilesDown) {
    return null;
  }

  int tileIndex = tileY * tilesAcross + tileX;
  if (tileIndex >= tileOffsets.length) {
    return null;
  }

  await raf.setPosition(tileOffsets[tileIndex]);
  return await raf.read(tileByteCounts[tileIndex]);
}

/// Helper function to read an array of values from TIFF.
Future<List<int>> _readTiffArray(RandomAccessFile raf, int type, int count, int valueOffset, Endian endian) async {
  if (count == 0) return [];

  int elementSize = 0;
  if (type == 3) {
    elementSize = 2; // SHORT
  } else if (type == 4) {
    elementSize = 4;
  }// LONG
  else {
    return [];
  }

  if (count * elementSize <= 4) {
    List<int> result = [];
    ByteData bd = ByteData(4);
    bd.setUint32(0, valueOffset, endian);
    for (int i = 0; i < count; i++) {
      if (type == 3) {
        result.add(bd.getUint16(i * 2, endian));
      } else {
        result.add(bd.getUint32(i * 4, endian));
      }
    }
    return result;
  } else {
    final currentPos = await raf.position();
    await raf.setPosition(valueOffset);
    final bytes = await raf.read(count * elementSize);
    await raf.setPosition(currentPos);

    if (bytes.length < count * elementSize) return [];

    ByteData bd = ByteData.sublistView(bytes);
    List<int> result = [];
    for (int i = 0; i < count; i++) {
      if (type == 3) {
        result.add(bd.getUint16(i * 2, endian));
      } else {
        result.add(bd.getUint32(i * 4, endian));
      }
    }
    return result;
  }
}

/// Reads all metadata from the SVS file, including all pyramid levels and associated images.
///
/// [svs] is the open [SvsFile].
/// Returns an [SvsFullMetadata] instance containing the levels and associated images, or `null` on failure.
Future<SvsFullMetadata?> readFullSvsMetadata(SvsFile svs) async {
  final raf = svs.raf;
  final endian = svs.endian;
  int ifdOffset = svs.firstIfdOffset;

  List<SvsImageInfo> allImages = [];

  while (ifdOffset != 0) {
    await raf.setPosition(ifdOffset);
    final numEntriesBytes = await raf.read(2);
    if (numEntriesBytes.length < 2) break;

    final numEntries = ByteData.sublistView(numEntriesBytes).getUint16(0, endian);

    int width = 0;
    int height = 0;
    int? tileWidth;
    int? tileHeight;
    Map<String, String> properties = {};
    String? description;

    for (var i = 0; i < numEntries; i++) {
      final entryBytes = await raf.read(12);
      if (entryBytes.length < 12) break;
      final entryBd = ByteData.sublistView(entryBytes);

      final tag = entryBd.getUint16(0, endian);
      final type = entryBd.getUint16(2, endian);
      final count = entryBd.getUint32(4, endian);
      final valueOffset = entryBd.getUint32(8, endian);

      if (tag == 256) {
        width = _readTiffValue(type, count, valueOffset, entryBd, 8, endian);
      } else if (tag == 257) {
        height = _readTiffValue(type, count, valueOffset, entryBd, 8, endian);
      } else if (tag == 322) {
        tileWidth = _readTiffValue(type, count, valueOffset, entryBd, 8, endian);
      } else if (tag == 323) {
        tileHeight = _readTiffValue(type, count, valueOffset, entryBd, 8, endian);
      } else if (tag == 270) {
        final currentPos = await raf.position();
        await raf.setPosition(valueOffset);
        final descBytes = await raf.read(count);
        var length = descBytes.length;
        if (length > 0 && descBytes[length - 1] == 0) length--;
        description = String.fromCharCodes(descBytes.sublist(0, length)).trim();
        properties = _parseAperioDescription(description);
        await raf.setPosition(currentPos);
      }
    }

    String? imageType;
    if (description != null) {
      if (description.startsWith('label')) {
        imageType = 'label';
      } else if (description.startsWith('macro')) {
        imageType = 'macro';
      } else if (description.startsWith('thumbnail')) {
        imageType = 'thumbnail';
      } else if (description.contains('AppMag')) {
        imageType = 'level';
      } else {
        if (tileWidth != null && tileHeight != null) {
          imageType = 'level';
        } else {
          imageType = 'other_association';
        }
      }
    } else {
      if (tileWidth != null && tileHeight != null) {
        imageType = 'level';
      } else {
        imageType = 'other_association';
      }
    }

    if (imageType == 'other_association' || imageType == 'level') {
      if (width > 0 && height > 0) {
        double aspect = width / height;
        bool canBeThumbnail = (imageType == 'other_association') || (imageType == 'level' && tileWidth == null);

        if (canBeThumbnail && width < 2000 && height < 2000) {
          if (width == 687 && height == 687) {
            imageType = 'label';
          } else if (width <= 1024 && (aspect > 0.5 && aspect < 2.0)) {
            imageType = 'thumbnail';
          }
        }
        if (canBeThumbnail && width >= 1500 && height < 1000 && aspect > 2.0) {
          imageType = 'macro';
        }
      }
    }

    allImages.add(SvsImageInfo(
      width: width,
      height: height,
      tileWidth: tileWidth,
      tileHeight: tileHeight,
      compression: properties['Compression'],
      properties: properties,
      type: imageType,
    ));

    final nextIfdBytes = await raf.read(4);
    if (nextIfdBytes.length < 4) break;
    ifdOffset = ByteData.sublistView(nextIfdBytes).getUint32(0, endian);
  }

  List<SvsImageInfo> levels = [];
  Map<String, SvsImageInfo> associations = {};

  for (var img in allImages) {
    if (img.type == 'level') {
      levels.add(img);
    } else if (img.type != null) {
      String key = img.type!;
      if (key == 'other_association') {
        key = 'assoc_${allImages.indexOf(img)}';
      } else {
        if (associations.containsKey(key)) {
          key = '${key}_${allImages.indexOf(img)}';
        }
      }
      associations[key] = img;
    }
  }

  levels.sort((a, b) => b.width.compareTo(a.width));

  return SvsFullMetadata(levels: levels, associations: associations);
}

/// Reads basic metadata of the primary image from the SVS file without loading the entire file into memory.
///
/// Uses [RandomAccessFile] for positional reading and [ByteData] for parsing.
/// [svs] is the open [SvsFile].
/// Returns an [SvsMetadata] instance, or `null` on failure.
Future<SvsMetadata?> readSvsMetadata(SvsFile svs) async {
  final raf = svs.raf;
  final endian = svs.endian;
  int ifdOffset = svs.firstIfdOffset;

  Map<String, String> properties = {};
  int width = 0;
  int height = 0;
  int? tileWidth;
  int? tileHeight;

  if (ifdOffset != 0) {
    await raf.setPosition(ifdOffset);
    final numEntriesBytes = await raf.read(2);
    if (numEntriesBytes.length < 2) return null;

    final numEntries = ByteData.sublistView(numEntriesBytes).getUint16(0, endian);

    for (var i = 0; i < numEntries; i++) {
      final entryBytes = await raf.read(12);
      if (entryBytes.length < 12) break;
      final entryBd = ByteData.sublistView(entryBytes);

      final tag = entryBd.getUint16(0, endian);
      final type = entryBd.getUint16(2, endian);
      final count = entryBd.getUint32(4, endian);
      final valueOffset = entryBd.getUint32(8, endian);

      if (tag == 256) {
        width = _readTiffValue(type, count, valueOffset, entryBd, 8, endian);
      }
      else if (tag == 257) {
        height = _readTiffValue(type, count, valueOffset, entryBd, 8, endian);
      }
      else if (tag == 322) {
        tileWidth = _readTiffValue(type, count, valueOffset, entryBd, 8, endian);
      }
      else if (tag == 323) {
        tileHeight = _readTiffValue(type, count, valueOffset, entryBd, 8, endian);
      }
      else if (tag == 270) {
        final currentPos = await raf.position();
        await raf.setPosition(valueOffset);
        final descBytes = await raf.read(count);
        var length = descBytes.length;
        if (length > 0 && descBytes[length - 1] == 0) {
          length--;
        }
        final description = String.fromCharCodes(descBytes.sublist(0, length)).trim();
        properties = _parseAperioDescription(description);
        await raf.setPosition(currentPos);
      }
    }
  }

  return SvsMetadata(
    properties: properties,
    width: width,
    height: height,
    tileWidth: tileWidth,
    tileHeight: tileHeight,
    compression: properties['Compression'],
  );
}

int _readTiffValue(int type, int count, int valueOffset, ByteData entryBd, int offsetInEntry, Endian endian) {
  if (type == 3) { // SHORT
    return entryBd.getUint16(offsetInEntry, endian);
  } else if (type == 4) { // LONG
    return entryBd.getUint32(offsetInEntry, endian);
  }
  return valueOffset;
}

Map<String, String> _parseAperioDescription(String description) {
  final Map<String, String> props = {};
  final lines = description.split(RegExp(r'[|\n\r]'));

  for (var line in lines) {
    line = line.trim();
    if (line.isEmpty) continue;

    // Extract vendor name and software version
    if (line.startsWith('Aperio ')) {
      props['Vendor'] = 'Aperio';
      props['Version'] = line.substring(7).trim();
      continue;
    }

    // Process line with general image characteristics (e.g. 44704x28257 [0,100 43823x28157] (240x240) JPEG/RGB Q=70)
    if (RegExp(r'^\d+x\d+').hasMatch(line)) {
      props['ImageInfo'] = line; // Save original string for completeness

      final qMatch = RegExp(r'Q[=:]\s*(\d+)').firstMatch(line);
      if (qMatch != null) {
        props['CompressionQuality'] = qMatch.group(1)!;
      }

      final formatMatch = RegExp(r'([A-Za-z0-9/_-]+)\s+Q[=:]').firstMatch(line);
      if (formatMatch != null) {
        props['CompressionFormat'] = formatMatch.group(1)!;
        props['Compression'] = '${formatMatch.group(1)} (Q=${props['CompressionQuality']})';
      } else if (qMatch != null) {
        props['Compression'] = 'JPEG (Q=${props['CompressionQuality']})';
      }
      continue;
    }

    // Process standard key-value parameters
    final parts = line.split('=');
    if (parts.length >= 2) {
      final key = parts[0].trim();
      final value = parts.sublist(1).join('=').trim();
      props[key] = value;
    }
  }

  return props;
}