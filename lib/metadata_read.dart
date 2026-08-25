// //
// Copyright (c) 2026, Vladislav Saradzev
// All rights reserved.


import 'dart:io';
import 'dart:typed_data';
import 'package:image/image.dart' as img;
import 'package:omnigisto_pkg/types/types.dart';



export 'types/types.dart';

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
  return await svs.synchronized(() async {
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
      String? currentImageType = _determineImageType(description, width, height, tileWidth, tileHeight);

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
  });
}

/// Extracts an associated image (e.g. 'thumbnail', 'label', or 'macro') from an SVS file and returns it as a decoded [img.Image].
///
/// Handles decompression (JPEG strips with JPEGTables, LZW with predictor, uncompressed RGB, Deflate)
/// and stitches multi-strip images into a unified [img.Image].
///
/// [svs] is the open [SvsFile].
/// [type] is the image type identifier to extract ('thumbnail', 'label', or 'macro').
/// [applyColorScheme] if `true`, applies the appropriate color scheme interpretation
/// (e.g., treating RGB JPEG strips as RGB instead of default YCbCr, WhiteIsZero inversion, palette mapping).
/// If `false` extracts the image as-is (backward compatible).
/// Returns the decoded [img.Image], or `null` if the requested image type was not found or failed to decode.
Future<img.Image?> extractSvsImageAsImage(
  SvsFile svs,
  String type, {
  bool applyColorScheme = true,
}) async {
  return await svs.synchronized(() async {
    final raf = svs.raf;
    final endian = svs.endian;
    int ifdOffset = svs.firstIfdOffset;
    Uint8List? globalJpegTables;

    while (ifdOffset != 0) {
      await raf.setPosition(ifdOffset);
      final numEntriesBytes = await raf.read(2);
      if (numEntriesBytes.length < 2) break;

      final numEntries = ByteData.sublistView(numEntriesBytes).getUint16(0, endian);

      int width = 0;
      int height = 0;
      int? tileWidth;
      int? tileHeight;
      int compression = 1;
      int samplesPerPixel = 3;
      int rowsPerStrip = 0;
      int predictor = 1;
      int photometricInterpretation = 2;
      String? description;
      List<int> stripOffsets = [];
      List<int> stripByteCounts = [];
      Uint8List? jpegTables;
      Uint8List? iccProfile;
      List<int>? colorMap;

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
        } else if (tag == 259) {
          compression = _readTiffValue(dataType, count, valueOffset, entryBd, 8, endian);
        } else if (tag == 262) {
          photometricInterpretation = _readTiffValue(dataType, count, valueOffset, entryBd, 8, endian);
        } else if (tag == 273) {
          stripOffsets = await _readTiffArray(raf, dataType, count, valueOffset, endian);
        } else if (tag == 277) {
          samplesPerPixel = _readTiffValue(dataType, count, valueOffset, entryBd, 8, endian);
        } else if (tag == 278) {
          rowsPerStrip = _readTiffValue(dataType, count, valueOffset, entryBd, 8, endian);
        } else if (tag == 279) {
          stripByteCounts = await _readTiffArray(raf, dataType, count, valueOffset, endian);
        } else if (tag == 317) {
          predictor = _readTiffValue(dataType, count, valueOffset, entryBd, 8, endian);
        } else if (tag == 320) {
          colorMap = await _readTiffArray(raf, dataType, count, valueOffset, endian);
        } else if (tag == 322) {
          tileWidth = _readTiffValue(dataType, count, valueOffset, entryBd, 8, endian);
        } else if (tag == 323) {
          tileHeight = _readTiffValue(dataType, count, valueOffset, entryBd, 8, endian);
        } else if (tag == 347) {
          final currentPos = await raf.position();
          await raf.setPosition(valueOffset);
          jpegTables = await raf.read(count);
          globalJpegTables ??= jpegTables;
          await raf.setPosition(currentPos);
        } else if (tag == 34675) {
          final currentPos = await raf.position();
          await raf.setPosition(valueOffset);
          iccProfile = await raf.read(count);
          await raf.setPosition(currentPos);
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

      if (rowsPerStrip <= 0) {
        rowsPerStrip = height > 0 ? height : 1;
      }

      jpegTables ??= globalJpegTables;

      // Determine the type of the current image
      String? currentImageType = _determineImageType(description, width, height, tileWidth, tileHeight);

      if (currentImageType == type) {
        if (stripOffsets.isEmpty || stripByteCounts.isEmpty || width <= 0 || height <= 0) {
          return null;
        }

        try {
          if (compression == 7 || compression == 6) {
            final fullImage = img.Image(width: width, height: height, numChannels: 3);
            for (int i = 0; i < stripOffsets.length; i++) {
              await raf.setPosition(stripOffsets[i]);
              var stripBytes = await raf.read(stripByteCounts[i]);
              if (jpegTables != null) {
                stripBytes = _combineJpegWithTables(stripBytes, jpegTables);
              }
              img.Image? stripImg;
              if (applyColorScheme && photometricInterpretation == 2) {
                try {
                  final adobeBytes = _injectAdobeMarker(stripBytes, 0);
                  stripImg = img.decodeJpg(adobeBytes);
                } catch (_) {
                  stripImg = null;
                }
              }
              if (stripImg == null) {
                try {
                  stripImg = img.decodeJpg(stripBytes);
                } catch (_) {
                  stripImg = null;
                }
              }
              if (stripImg == null) {
                try {
                  stripImg = img.decodeImage(stripBytes);
                } catch (_) {
                  stripImg = null;
                }
              }
              if (stripImg != null) {
                img.compositeImage(fullImage, stripImg, dstY: i * rowsPerStrip);
              }
            }
            if (applyColorScheme) {
              if (photometricInterpretation == 0) {
                _applyWhiteIsZero(fullImage);
              }
              if (iccProfile != null && iccProfile.length <= 65519) {
                fullImage.iccProfile = img.IccProfile('', img.IccProfileCompression.none, iccProfile);
              }
            }
            return fullImage;
          } else if (compression == 5) {
            final totalBytes = width * height * samplesPerPixel;
            final uncompressedAll = Uint8List(totalBytes);
            int offset = 0;

            for (int i = 0; i < stripOffsets.length; i++) {
              await raf.setPosition(stripOffsets[i]);
              final compressedStrip = await raf.read(stripByteCounts[i]);

              int stripRows = rowsPerStrip;
              if ((i + 1) * rowsPerStrip > height) {
                stripRows = height - i * rowsPerStrip;
              }
              if (stripRows <= 0) break;

              int stripExpectedBytes = width * stripRows * samplesPerPixel;
              final decompressedStrip = _decompressTiffLzw(compressedStrip, stripExpectedBytes);

              if (predictor == 2) {
                _applyHorizontalPredictor(decompressedStrip, width, stripRows, samplesPerPixel);
              }

              if (offset + stripExpectedBytes <= uncompressedAll.length) {
                uncompressedAll.setRange(offset, offset + stripExpectedBytes, decompressedStrip);
              }
              offset += stripExpectedBytes;
            }

            var image = img.Image.fromBytes(
              width: width,
              height: height,
              bytes: uncompressedAll.buffer,
              numChannels: samplesPerPixel,
              order: samplesPerPixel >= 3 ? img.ChannelOrder.rgb : null,
            );
            if (applyColorScheme) {
              image = _applyColorSchemeToImage(
                image,
                photometricInterpretation,
                samplesPerPixel,
                colorMap,
                iccProfile,
              );
            }
            return image;
          } else if (compression == 1) {
            final bb = BytesBuilder();
            for (int i = 0; i < stripOffsets.length; i++) {
              await raf.setPosition(stripOffsets[i]);
              final bytes = await raf.read(stripByteCounts[i]);
              bb.add(bytes);
            }
            final rawBytes = bb.takeBytes();
            if (predictor == 2) {
              _applyHorizontalPredictor(rawBytes, width, height, samplesPerPixel);
            }
            var image = img.Image.fromBytes(
              width: width,
              height: height,
              bytes: rawBytes.buffer,
              numChannels: samplesPerPixel,
              order: samplesPerPixel >= 3 ? img.ChannelOrder.rgb : null,
            );
            if (applyColorScheme) {
              image = _applyColorSchemeToImage(
                image,
                photometricInterpretation,
                samplesPerPixel,
                colorMap,
                iccProfile,
              );
            }
            return image;
          } else if (compression == 8 || compression == 32946) {
            final totalBytes = width * height * samplesPerPixel;
            final uncompressedAll = Uint8List(totalBytes);
            int offset = 0;

            for (int i = 0; i < stripOffsets.length; i++) {
              await raf.setPosition(stripOffsets[i]);
              final compressedStrip = await raf.read(stripByteCounts[i]);

              int stripRows = rowsPerStrip;
              if ((i + 1) * rowsPerStrip > height) {
                stripRows = height - i * rowsPerStrip;
              }
              if (stripRows <= 0) break;

              int stripExpectedBytes = width * stripRows * samplesPerPixel;
              final decompressedStrip = Uint8List.fromList(zlib.decode(compressedStrip));

              if (predictor == 2) {
                _applyHorizontalPredictor(decompressedStrip, width, stripRows, samplesPerPixel);
              }

              if (offset + stripExpectedBytes <= uncompressedAll.length) {
                uncompressedAll.setRange(offset, offset + stripExpectedBytes, decompressedStrip);
              }
              offset += stripExpectedBytes;
            }

            var image = img.Image.fromBytes(
              width: width,
              height: height,
              bytes: uncompressedAll.buffer,
              numChannels: samplesPerPixel,
              order: samplesPerPixel >= 3 ? img.ChannelOrder.rgb : null,
            );
            if (applyColorScheme) {
              image = _applyColorSchemeToImage(
                image,
                photometricInterpretation,
                samplesPerPixel,
                colorMap,
                iccProfile,
              );
            }
            return image;
          } else {
            final bb = BytesBuilder();
            for (int i = 0; i < stripOffsets.length; i++) {
              await raf.setPosition(stripOffsets[i]);
              final bytes = await raf.read(stripByteCounts[i]);
              bb.add(bytes);
            }
            final rawBytes = bb.takeBytes();
            var image = img.decodeImage(rawBytes);
            if (image != null && applyColorScheme) {
              image = _applyColorSchemeToImage(
                image,
                photometricInterpretation,
                samplesPerPixel,
                colorMap,
                iccProfile,
              );
            }
            return image;
          }
        } catch (e) {
          return null;
        }
      }

      await raf.setPosition(nextIfdOffsetPos);
      final nextIfdBytes = await raf.read(4);
      if (nextIfdBytes.length < 4) break;
      ifdOffset = ByteData.sublistView(nextIfdBytes).getUint32(0, endian);
    }

    return null;
  });
}

/// Extracts an associated image (e.g. 'thumbnail', 'label', or 'macro') from an SVS file and returns it as encoded JPEG bytes.
///
/// Handles decompression (JPEG strips with JPEGTables, LZW with predictor, uncompressed RGB, Deflate)
/// and stitches multi-strip images into a unified JPEG image.
///
/// [svs] is the open [SvsFile].
/// [type] is the image type identifier to extract ('thumbnail', 'label', or 'macro').
/// [quality] is the JPEG encoding quality (1 to 100, default is 90).
/// [applyColorScheme] if `true`, applies the appropriate color scheme interpretation.
/// Returns the JPEG encoded byte data, or `null` if the requested image type was not found or failed to decode.
Future<Uint8List?> extractSvsImageAsJpeg(
  SvsFile svs,
  String type, {
  int quality = 90,
  bool applyColorScheme = true,
}) async {
  final image = await extractSvsImageAsImage(
    svs,
    type,
    applyColorScheme: applyColorScheme,
  );
  if (image == null) return null;
  return Uint8List.fromList(img.encodeJpg(image, quality: quality));
}

class _TiledLevelInfo {
  final int ifdOffset;
  final int width;
  final int height;
  final int tileWidth;
  final int tileHeight;
  final int tilesAcross;
  final int tilesDown;
  _TiledLevelFullData? fullData;

  _TiledLevelInfo({
    required this.ifdOffset,
    required this.width,
    required this.height,
    required this.tileWidth,
    required this.tileHeight,
  })  : tilesAcross = (width + tileWidth - 1) ~/ tileWidth,
        tilesDown = (height + tileHeight - 1) ~/ tileHeight;
}

class _TiledLevelFullData {
  final int compression;
  final int samplesPerPixel;
  final int predictor;
  final int photometricInterpretation;
  final List<int> tileOffsets;
  final List<int> tileByteCounts;
  final Uint8List? jpegTables;
  final Uint8List? iccProfile;
  final List<int>? colorMap;

  _TiledLevelFullData({
    required this.compression,
    required this.samplesPerPixel,
    required this.predictor,
    required this.photometricInterpretation,
    required this.tileOffsets,
    required this.tileByteCounts,
    this.jpegTables,
    this.iccProfile,
    this.colorMap,
  });
}

Future<({List<_TiledLevelInfo> levels, Uint8List? globalJpegTables})> _collectTiledLevels(SvsFile svs) async {
  final raf = svs.raf;
  final endian = svs.endian;
  int ifdOffset = svs.firstIfdOffset;

  List<_TiledLevelInfo> levels = [];
  Uint8List? globalJpegTables;

  while (ifdOffset != 0) {
    await raf.setPosition(ifdOffset);
    final numEntriesBytes = await raf.read(2);
    if (numEntriesBytes.length < 2) break;
    final numEntries = ByteData.sublistView(numEntriesBytes).getUint16(0, endian);

    int width = 0;
    int height = 0;
    int? tileWidth;
    int? tileHeight;

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
      } else if (tag == 347 && globalJpegTables == null) {
        final currentPos = await raf.position();
        await raf.setPosition(valueOffset);
        globalJpegTables = await raf.read(count);
        await raf.setPosition(currentPos);
      }
    }

    if (tileWidth != null && tileHeight != null && width > 0 && height > 0) {
      levels.add(_TiledLevelInfo(
        ifdOffset: ifdOffset,
        width: width,
        height: height,
        tileWidth: tileWidth,
        tileHeight: tileHeight,
      ));
    }

    await raf.setPosition(ifdOffset + 2 + numEntries * 12);
    final nextIfdBytes = await raf.read(4);
    if (nextIfdBytes.length < 4) break;
    ifdOffset = ByteData.sublistView(nextIfdBytes).getUint32(0, endian);
  }

  levels.sort((a, b) => b.width.compareTo(a.width));
  return (levels: levels, globalJpegTables: globalJpegTables);
}

Future<({List<_TiledLevelInfo> levels, Uint8List? globalJpegTables})> _getOrCollectTiledLevels(SvsFile svs) async {
  if (svs.cachedTiledLevels != null) {
    return (
      levels: svs.cachedTiledLevels! as List<_TiledLevelInfo>,
      globalJpegTables: svs.cachedGlobalJpegTables,
    );
  }

  return await svs.synchronized(() async {
    if (svs.cachedTiledLevels != null) {
      return (
        levels: svs.cachedTiledLevels! as List<_TiledLevelInfo>,
        globalJpegTables: svs.cachedGlobalJpegTables,
      );
    }

    final collected = await _collectTiledLevels(svs);
    svs.cachedTiledLevels = collected.levels;
    svs.cachedGlobalJpegTables = collected.globalJpegTables;
    return collected;
  });
}

Future<_TiledLevelFullData?> _getOrLoadLevelFullData(
  SvsFile svs,
  _TiledLevelInfo targetLevel,
  Uint8List? globalJpegTables,
) async {
  if (targetLevel.fullData != null) {
    return targetLevel.fullData;
  }

  return await svs.synchronized(() async {
    if (targetLevel.fullData != null) {
      return targetLevel.fullData;
    }

    final raf = svs.raf;
    final endian = svs.endian;
    final targetIfd = targetLevel.ifdOffset;

    await raf.setPosition(targetIfd);
    final numEntriesBytes = await raf.read(2);
    if (numEntriesBytes.length < 2) return null;
    final numEntries = ByteData.sublistView(numEntriesBytes).getUint16(0, endian);

    int compression = 1;
    int samplesPerPixel = 3;
    int predictor = 1;
    int photometricInterpretation = 2;
    List<int> tileOffsets = [];
    List<int> tileByteCounts = [];
    Uint8List? jpegTables = globalJpegTables;
    Uint8List? iccProfile;
    List<int>? colorMap;

    for (var i = 0; i < numEntries; i++) {
      final entryBytes = await raf.read(12);
      if (entryBytes.length < 12) break;
      final entryBd = ByteData.sublistView(entryBytes);
      final tag = entryBd.getUint16(0, endian);
      final type = entryBd.getUint16(2, endian);
      final count = entryBd.getUint32(4, endian);
      final valueOffset = entryBd.getUint32(8, endian);

      if (tag == 259) {
        compression = _readTiffValue(type, count, valueOffset, entryBd, 8, endian);
      } else if (tag == 262) {
        photometricInterpretation = _readTiffValue(type, count, valueOffset, entryBd, 8, endian);
      } else if (tag == 277) {
        samplesPerPixel = _readTiffValue(type, count, valueOffset, entryBd, 8, endian);
      } else if (tag == 317) {
        predictor = _readTiffValue(type, count, valueOffset, entryBd, 8, endian);
      } else if (tag == 320) {
        colorMap = await _readTiffArray(raf, type, count, valueOffset, endian);
      } else if (tag == 324) {
        tileOffsets = await _readTiffArray(raf, type, count, valueOffset, endian);
      } else if (tag == 325) {
        tileByteCounts = await _readTiffArray(raf, type, count, valueOffset, endian);
      } else if (tag == 347) {
        final currentPos = await raf.position();
        await raf.setPosition(valueOffset);
        jpegTables = await raf.read(count);
        await raf.setPosition(currentPos);
      } else if (tag == 34675) {
        final currentPos = await raf.position();
        await raf.setPosition(valueOffset);
        iccProfile = await raf.read(count);
        await raf.setPosition(currentPos);
      }
    }

    if (tileOffsets.isEmpty) {
      return null;
    }

    final fullData = _TiledLevelFullData(
      compression: compression,
      samplesPerPixel: samplesPerPixel,
      predictor: predictor,
      photometricInterpretation: photometricInterpretation,
      tileOffsets: tileOffsets,
      tileByteCounts: tileByteCounts,
      jpegTables: jpegTables,
      iccProfile: iccProfile,
      colorMap: colorMap,
    );

    targetLevel.fullData = fullData;
    return fullData;
  });
}

/// Extracts the raw bytes of a specific tile from a resolution layer in the SVS file.
///
/// [svs] is the open [SvsFile].
/// [layerIndex] is the resolution layer index (0 is the highest resolution / baseline level).
/// [tileX] and [tileY] are the 0-based horizontal and vertical tile coordinates (not pixel coordinates).
/// Returns the raw tile bytes, or `null` if the tile coordinates or layer are invalid.
Future<Uint8List?> extractSvsTile(SvsFile svs, int layerIndex, int tileX, int tileY) async {
  final collected = await _getOrCollectTiledLevels(svs);
  final levels = collected.levels;

  if (layerIndex < 0 || layerIndex >= levels.length) {
    return null;
  }

  final targetLevel = levels[layerIndex];
  final fullData = await _getOrLoadLevelFullData(svs, targetLevel, collected.globalJpegTables);
  if (fullData == null) {
    return null;
  }

  if (tileX < 0 || tileX >= targetLevel.tilesAcross || tileY < 0 || tileY >= targetLevel.tilesDown) {
    return null;
  }

  final tileIndex = tileY * targetLevel.tilesAcross + tileX;
  if (tileIndex >= fullData.tileOffsets.length) {
    return null;
  }

  final offset = fullData.tileOffsets[tileIndex];
  final byteCount = tileIndex < fullData.tileByteCounts.length ? fullData.tileByteCounts[tileIndex] : 0;

  if (byteCount == 0 || offset == 0) {
    return Uint8List(0);
  }

  return await svs.readBytesAt(offset, byteCount);
}

/// Extracts a specific tile from a resolution layer in the SVS file and returns it as a decoded [img.Image].
///
/// Handles decompression (JPEG tiles with JPEGTables, LZW with predictor, uncompressed RGB, Deflate).
///
/// [svs] is the open [SvsFile].
/// [layerIndex] is the resolution layer index (0 is the highest resolution / baseline level).
/// [tileX] and [tileY] are the 0-based horizontal and vertical tile coordinates (not pixel coordinates).
/// [applyColorScheme] if `true`, applies the appropriate color scheme interpretation
/// (e.g., treating RGB JPEG as RGB instead of default YCbCr, WhiteIsZero inversion, palette mapping).
/// If `false`, extracts the tile image as-is.
/// Returns the decoded [img.Image], or `null` if the tile coordinates or layer are invalid or failed to decode.
Future<img.Image?> extractSvsTileAsImage(
  SvsFile svs,
  int layerIndex,
  int tileX,
  int tileY, {
  bool applyColorScheme = true,
}) async {
  final collected = await _getOrCollectTiledLevels(svs);
  final levels = collected.levels;

  if (layerIndex < 0 || layerIndex >= levels.length) {
    return null;
  }

  final targetLevel = levels[layerIndex];
  final fullData = await _getOrLoadLevelFullData(svs, targetLevel, collected.globalJpegTables);
  if (fullData == null) {
    return null;
  }

  if (tileX < 0 || tileX >= targetLevel.tilesAcross || tileY < 0 || tileY >= targetLevel.tilesDown) {
    return null;
  }

  final tileIndex = tileY * targetLevel.tilesAcross + tileX;
  if (tileIndex >= fullData.tileOffsets.length) {
    return null;
  }

  final offset = fullData.tileOffsets[tileIndex];
  final byteCount = tileIndex < fullData.tileByteCounts.length ? fullData.tileByteCounts[tileIndex] : 0;

  // Handle empty / sparse tiles (e.g. background)
  if (byteCount == 0 || offset == 0) {
    final blank = img.Image(
      width: targetLevel.tileWidth,
      height: targetLevel.tileHeight,
      numChannels: fullData.samplesPerPixel > 0 ? fullData.samplesPerPixel : 3,
    );
    blank.clear(img.ColorRgb8(255, 255, 255));
    return blank;
  }

  // Atomically read raw tile bytes (critical section: ~0.1 ms)
  final rawTileBytes = await svs.readBytesAt(offset, byteCount);

  if (rawTileBytes.isEmpty) {
    final blank = img.Image(
      width: targetLevel.tileWidth,
      height: targetLevel.tileHeight,
      numChannels: fullData.samplesPerPixel > 0 ? fullData.samplesPerPixel : 3,
    );
    blank.clear(img.ColorRgb8(255, 255, 255));
    return blank;
  }

  // Decompression and color scheme processing happen outside the lock (parallel on CPU)
  return _decodeTileBytes(
    rawTileBytes: rawTileBytes,
    tileWidth: targetLevel.tileWidth,
    tileHeight: targetLevel.tileHeight,
    compression: fullData.compression,
    samplesPerPixel: fullData.samplesPerPixel,
    predictor: fullData.predictor,
    photometricInterpretation: fullData.photometricInterpretation,
    jpegTables: fullData.jpegTables,
    iccProfile: fullData.iccProfile,
    colorMap: fullData.colorMap,
    applyColorScheme: applyColorScheme,
  );
}

img.Image? _decodeTileBytes({
  required Uint8List rawTileBytes,
  required int tileWidth,
  required int tileHeight,
  required int compression,
  required int samplesPerPixel,
  required int predictor,
  required int photometricInterpretation,
  required Uint8List? jpegTables,
  required Uint8List? iccProfile,
  required List<int>? colorMap,
  required bool applyColorScheme,
}) {
  try {
    if (compression == 7 || compression == 6) {
      var tileBytes = rawTileBytes;
      if (jpegTables != null) {
        tileBytes = _combineJpegWithTables(tileBytes, jpegTables);
      }

      img.Image? tileImg;

      if (applyColorScheme && photometricInterpretation == 2) {
        try {
          final adobeBytes = _injectAdobeMarker(tileBytes, 0);
          tileImg = img.decodeJpg(adobeBytes);
        } catch (_) {
          tileImg = null;
        }
      }

      if (tileImg == null) {
        try {
          tileImg = img.decodeJpg(tileBytes);
        } catch (_) {
          tileImg = null;
        }
      }

      if (tileImg == null) {
        try {
          tileImg = img.decodeImage(tileBytes);
        } catch (_) {
          tileImg = null;
        }
      }

      if (tileImg != null && applyColorScheme) {
        if (photometricInterpretation == 0) {
          _applyWhiteIsZero(tileImg);
        }
        if (iccProfile != null && iccProfile.length <= 65519) {
          tileImg.iccProfile = img.IccProfile('', img.IccProfileCompression.none, iccProfile);
        }
      }
      return tileImg;
    } else if (compression == 5) {
      final expectedLength = tileWidth * tileHeight * samplesPerPixel;
      final decompressed = _decompressTiffLzw(rawTileBytes, expectedLength);

      if (predictor == 2) {
        _applyHorizontalPredictor(decompressed, tileWidth, tileHeight, samplesPerPixel);
      }

      var tileImg = img.Image.fromBytes(
        width: tileWidth,
        height: tileHeight,
        bytes: decompressed.buffer,
        numChannels: samplesPerPixel,
        order: samplesPerPixel >= 3 ? img.ChannelOrder.rgb : null,
      );
      if (applyColorScheme) {
        tileImg = _applyColorSchemeToImage(
          tileImg,
          photometricInterpretation,
          samplesPerPixel,
          colorMap,
          iccProfile,
        );
      }
      return tileImg;
    } else if (compression == 1) {
      final dataBytes = Uint8List.fromList(rawTileBytes);
      if (predictor == 2) {
        _applyHorizontalPredictor(dataBytes, tileWidth, tileHeight, samplesPerPixel);
      }
      var tileImg = img.Image.fromBytes(
        width: tileWidth,
        height: tileHeight,
        bytes: dataBytes.buffer,
        numChannels: samplesPerPixel,
        order: samplesPerPixel >= 3 ? img.ChannelOrder.rgb : null,
      );
      if (applyColorScheme) {
        tileImg = _applyColorSchemeToImage(
          tileImg,
          photometricInterpretation,
          samplesPerPixel,
          colorMap,
          iccProfile,
        );
      }
      return tileImg;
    } else if (compression == 8 || compression == 32946) {
      final decompressed = Uint8List.fromList(zlib.decode(rawTileBytes));
      if (predictor == 2) {
        _applyHorizontalPredictor(decompressed, tileWidth, tileHeight, samplesPerPixel);
      }
      var tileImg = img.Image.fromBytes(
        width: tileWidth,
        height: tileHeight,
        bytes: decompressed.buffer,
        numChannels: samplesPerPixel,
        order: samplesPerPixel >= 3 ? img.ChannelOrder.rgb : null,
      );
      if (applyColorScheme) {
        tileImg = _applyColorSchemeToImage(
          tileImg,
          photometricInterpretation,
          samplesPerPixel,
          colorMap,
          iccProfile,
        );
      }
      return tileImg;
    } else {
      var tileImg = img.decodeImage(rawTileBytes);
      if (tileImg != null && applyColorScheme) {
        tileImg = _applyColorSchemeToImage(
          tileImg,
          photometricInterpretation,
          samplesPerPixel,
          colorMap,
          iccProfile,
        );
      }
      return tileImg;
    }
  } catch (e) {
    return null;
  }
}




/// Helper function to read an array of values from TIFF.
Future<List<int>> _readTiffArray(RandomAccessFile raf, int type, int count, int valueOffset, Endian endian) async {
  if (count == 0) return const [];

  int elementSize = 0;
  if (type == 3) {
    elementSize = 2; // SHORT
  } else if (type == 4) {
    elementSize = 4; // LONG
  } else {
    return const [];
  }

  if (count * elementSize <= 4) {
    final result = List<int>.filled(count, 0);
    final bd = ByteData(4);
    bd.setUint32(0, valueOffset, endian);
    for (int i = 0; i < count; i++) {
      result[i] = (type == 3) ? bd.getUint16(i * 2, endian) : bd.getUint32(i * 4, endian);
    }
    return result;
  } else {
    final currentPos = await raf.position();
    await raf.setPosition(valueOffset);
    final bytes = await raf.read(count * elementSize);
    await raf.setPosition(currentPos);

    if (bytes.length < count * elementSize) return const [];

    final bd = ByteData.sublistView(bytes);
    final result = List<int>.filled(count, 0);
    for (int i = 0; i < count; i++) {
      result[i] = (type == 3) ? bd.getUint16(i * 2, endian) : bd.getUint32(i * 4, endian);
    }
    return result;
  }
}

/// Reads all metadata from the SVS file, including all pyramid levels and associated images.
///
/// [svs] is the open [SvsFile].
/// Returns an [SvsFullMetadata] instance containing the levels and associated images, or `null` on failure.
Future<SvsFullMetadata?> readFullSvsMetadata(SvsFile svs) async {
  return await svs.synchronized(() async {
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
      if (tileWidth != null && tileHeight != null) {
        imageType = 'level';
      } else if (description != null && description.contains('AppMag')) {
        imageType = 'level';
      } else {
        imageType = _determineImageType(description, width, height, tileWidth, tileHeight) ?? 'other_association';
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
  });
}

/// Reads basic metadata of the primary image from the SVS file without loading the entire file into memory.
///
/// Uses [RandomAccessFile] for positional reading and [ByteData] for parsing.
/// [svs] is the open [SvsFile].
/// Returns an [SvsMetadata] instance, or `null` on failure.
Future<SvsMetadata?> readSvsMetadata(SvsFile svs) async {
  return await svs.synchronized(() async {
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
  });
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

String? _determineImageType(
  String? description,
  int width,
  int height,
  int? tileWidth,
  int? tileHeight,
) {
  if (description != null) {
    final descLower = description.toLowerCase();
    if (descLower.contains('label')) {
      return 'label';
    } else if (descLower.contains('macro')) {
      return 'macro';
    } else if (descLower.contains('thumbnail')) {
      return 'thumbnail';
    }
  }

  if (tileWidth == null && tileHeight == null && width > 0 && height > 0) {
    double aspect = width / height;
    if (width < 2000 && height < 2000) {
      if (width == 687 && height == 687) {
        return 'label';
      } else if (width <= 1024 && (aspect > 0.5 && aspect < 2.0)) {
        return 'thumbnail';
      }
    }
    if (width >= 1500 && height < 1000 && aspect > 2.0) {
      return 'macro';
    }
  }

  return null;
}

Uint8List _combineJpegWithTables(Uint8List jpegBytes, Uint8List jpegTables) {
  int tablesStart = 0;
  if (jpegTables.length >= 2 && jpegTables[0] == 0xFF && jpegTables[1] == 0xD8) {
    tablesStart = 2;
  }
  int tablesEnd = jpegTables.length;
  if (tablesEnd >= 2 && jpegTables[tablesEnd - 2] == 0xFF && jpegTables[tablesEnd - 1] == 0xD9) {
    tablesEnd -= 2;
  }

  final tablesPayload = jpegTables.sublist(tablesStart, tablesEnd);
  final bb = BytesBuilder();
  if (jpegBytes.length >= 2 && jpegBytes[0] == 0xFF && jpegBytes[1] == 0xD8) {
    bb.add(jpegBytes.sublist(0, 2));
    bb.add(tablesPayload);
    bb.add(jpegBytes.sublist(2));
  } else {
    bb.add([0xFF, 0xD8]);
    bb.add(tablesPayload);
    bb.add(jpegBytes);
  }
  return bb.takeBytes();
}

Uint8List _decompressTiffLzw(Uint8List input, int expectedLength) {
  final output = Uint8List(expectedLength);
  int outIndex = 0;

  final prefix = Int32List(4096);
  final suffix = Uint8List(4096);
  final stack = Uint8List(4096);

  int bitPos = 0;
  final inputLen = input.length;

  int readCode(int codeSize) {
    int bytePos = bitPos >> 3;
    int bitOffset = bitPos & 7;
    if (bytePos >= inputLen) return 257;

    int val = input[bytePos] << 16;
    if (bytePos + 1 < inputLen) val |= input[bytePos + 1] << 8;
    if (bytePos + 2 < inputLen) val |= input[bytePos + 2];

    val = (val >> (24 - bitOffset - codeSize)) & ((1 << codeSize) - 1);
    bitPos += codeSize;
    return val;
  }

  int codeSize = 9;
  int nextCode = 258;
  int oldCode = -1;

  while (outIndex < expectedLength && (bitPos >> 3) < inputLen) {
    int code = readCode(codeSize);
    if (code == 257) {
      break;
    }
    if (code == 256) {
      codeSize = 9;
      nextCode = 258;
      code = readCode(codeSize);
      if (code == 257) break;
      if (outIndex < expectedLength) {
        output[outIndex++] = code;
      }
      oldCode = code;
      continue;
    }

    int inCode = code;
    int stackPtr = 0;

    if (code >= nextCode) {
      if (code > nextCode) {
        break;
      }
      if (oldCode >= 0 && oldCode < 4096) {
        stack[stackPtr++] = suffix[oldCode];
      }
      code = oldCode;
    }

    while (code >= 258 && code < 4096) {
      stack[stackPtr++] = suffix[code];
      code = prefix[code];
    }
    stack[stackPtr++] = code;
    int firstChar = code;

    while (stackPtr > 0 && outIndex < expectedLength) {
      output[outIndex++] = stack[--stackPtr];
    }

    if (nextCode < 4096 && oldCode != -1) {
      prefix[nextCode] = oldCode;
      suffix[nextCode] = firstChar;
      nextCode++;
      if (nextCode >= (1 << codeSize) - 1 && codeSize < 12) {
        codeSize++;
      }
    }
    oldCode = inCode;
  }

  return output;
}

void _applyHorizontalPredictor(Uint8List data, int width, int height, int samplesPerPixel) {
  int rowBytes = width * samplesPerPixel;
  for (int y = 0; y < height; y++) {
    int rowStart = y * rowBytes;
    for (int i = samplesPerPixel; i < rowBytes && (rowStart + i) < data.length; i++) {
      data[rowStart + i] = (data[rowStart + i] + data[rowStart + i - samplesPerPixel]) & 0xFF;
    }
  }
}

Uint8List _injectAdobeMarker(Uint8List jpegBytes, int transformCode) {
  for (int i = 0; i < jpegBytes.length - 15; i++) {
    if (jpegBytes[i] == 0xFF && jpegBytes[i + 1] == 0xEE) {
      if (i + 15 < jpegBytes.length &&
          jpegBytes[i + 4] == 0x41 &&
          jpegBytes[i + 5] == 0x64 &&
          jpegBytes[i + 6] == 0x6F &&
          jpegBytes[i + 7] == 0x62 &&
          jpegBytes[i + 8] == 0x65) {
        final updated = Uint8List.fromList(jpegBytes);
        updated[i + 15] = transformCode;
        return updated;
      }
    }
  }

  final adobeMarker = Uint8List.fromList([
    0xFF, 0xEE, // APP14 marker
    0x00, 0x0E, // length = 14
    0x41, 0x64, 0x6F, 0x62, 0x65, 0x00, // 'Adobe\0'
    0x64, // version (100)
    0x00, 0x00, // flags0
    0x00, 0x00, // flags1
    transformCode, // transformCode: 0 for RGB, 1 for YCbCr
  ]);

  final bb = BytesBuilder();
  if (jpegBytes.length >= 2 && jpegBytes[0] == 0xFF && jpegBytes[1] == 0xD8) {
    bb.add(jpegBytes.sublist(0, 2));
    bb.add(adobeMarker);
    bb.add(jpegBytes.sublist(2));
  } else {
    bb.add([0xFF, 0xD8]);
    bb.add(adobeMarker);
    bb.add(jpegBytes);
  }
  return bb.takeBytes();
}

img.Image _applyColorSchemeToImage(
  img.Image image,
  int photometricInterpretation,
  int samplesPerPixel,
  List<int>? colorMap,
  Uint8List? iccProfile,
) {
  img.Image result = image;

  if (photometricInterpretation == 0) {
    // WhiteIsZero: Invert brightness
    for (final pixel in result) {
      pixel.r = 255 - pixel.r;
      if (result.numChannels >= 3) {
        pixel.g = 255 - pixel.g;
        pixel.b = 255 - pixel.b;
      }
    }
  } else if (photometricInterpretation == 3 && colorMap != null && samplesPerPixel == 1) {
    // Palette: Map 1-channel indexed colors to RGB
    final numColors = colorMap.length ~/ 3;
    final rOffset = 0;
    final gOffset = numColors;
    final bOffset = numColors * 2;

    final rgbImage = img.Image(
      width: result.width,
      height: result.height,
      numChannels: 3,
    );

    for (int y = 0; y < result.height; y++) {
      for (int x = 0; x < result.width; x++) {
        final index = result.getPixel(x, y).r.toInt();
        if (index < numColors) {
          int r = colorMap[rOffset + index];
          int g = colorMap[gOffset + index];
          int b = colorMap[bOffset + index];
          if (r > 255 || g > 255 || b > 255) {
            r >>= 8;
            g >>= 8;
            b >>= 8;
          }
          rgbImage.setPixelRgb(x, y, r, g, b);
        }
      }
    }
    result = rgbImage;
  }

  if (iccProfile != null && iccProfile.length <= 65519) {
    result.iccProfile = img.IccProfile('', img.IccProfileCompression.none, iccProfile);
  }

  return result;
}

void _applyWhiteIsZero(img.Image image) {
  for (final pixel in image) {
    pixel.r = 255 - pixel.r;
    if (image.numChannels >= 3) {
      pixel.g = 255 - pixel.g;
      pixel.b = 255 - pixel.b;
    }
  }
}