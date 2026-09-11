// //
// Copyright (c) 2026, Vladislav Saradzev
// Vanadzor
// All rights reserved.

import 'dart:io';
import 'dart:typed_data';
import 'package:image/image.dart' as img;
import 'package:jpeg2000/jpeg2000.dart';
import 'package:omnigisto_pkg/types/types.dart';

/// Opens an SVS file at the specified [path] and reads its TIFF/BigTIFF header.
///
/// Supports both standard TIFF (Magic 42) and BigTIFF (Magic 43, 64-bit offsets).
/// [maxConcurrency] defines the maximum number of concurrent file handles in the pool
/// used for parallel tile reading (default is 4). For slow mechanical HDDs or resource-constrained
/// environments, set to 1 or 2 to avoid seek thrashing. For fast SSDs/NVMe, higher values
/// (e.g. 4 to 8) maximize read throughput.
/// Returns an [SvsFile] instance if the file is a valid SVS/TIFF file, or `null` if opening or validation fails.
Future<SvsFile?> openSvsFile(String path, {int maxConcurrency = 4}) async {
  final file = File(path);
  if (!await file.exists()) return null;

  final raf = await file.open();
  try {
    final headerBytes = await raf.read(16);
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
    if (magic == 42) {
      // Standard TIFF (32-bit offsets)
      final ifdOffset = bd.getUint32(4, endian);
      return SvsFile(raf, endian, ifdOffset, false, path, maxConcurrency);
    } else if (magic == 43) {
      // BigTIFF (64-bit offsets)
      if (headerBytes.length < 16) {
        await raf.close();
        return null;
      }
      final offsetByteSize = bd.getUint16(4, endian);
      final unused = bd.getUint16(6, endian);
      if (offsetByteSize != 8 || unused != 0) {
        await raf.close();
        return null;
      }
      final ifdOffset = bd.getUint64(8, endian);
      return SvsFile(raf, endian, ifdOffset, true, path, maxConcurrency);
    } else {
      await raf.close();
      return null;
    }
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
    final isBigTiff = svs.isBigTiff;
    int ifdOffset = svs.firstIfdOffset;

    while (ifdOffset != 0) {
      final header = await _readIfdHeader(raf, ifdOffset, endian, isBigTiff);
      if (header == null) break;

      int width = 0;
      int height = 0;
      int? tileWidth;
      int? tileHeight;
      String? description;
      List<int> stripOffsets = [];
      List<int> stripByteCounts = [];

      for (var i = 0; i < header.numEntries; i++) {
        final entry = await _readIfdEntry(raf, endian, isBigTiff);
        if (entry == null) break;

        if (entry.tag == 256) {
          width = _readTiffValue(entry.dataType, entry.count, entry.valueOffset, entry.entryBd, entry.offsetInEntry, endian);
        } else if (entry.tag == 257) {
          height = _readTiffValue(entry.dataType, entry.count, entry.valueOffset, entry.entryBd, entry.offsetInEntry, endian);
        } else if (entry.tag == 322) {
          tileWidth = _readTiffValue(entry.dataType, entry.count, entry.valueOffset, entry.entryBd, entry.offsetInEntry, endian);
        } else if (entry.tag == 323) {
          tileHeight = _readTiffValue(entry.dataType, entry.count, entry.valueOffset, entry.entryBd, entry.offsetInEntry, endian);
        } else if (entry.tag == 273) {
          stripOffsets = await _readTiffArray(raf, entry.dataType, entry.count, entry.valueOffset, endian, inlineMaxBytes: entry.inlineMaxBytes, entryBd: entry.entryBd, offsetInEntry: entry.offsetInEntry);
        } else if (entry.tag == 279) {
          stripByteCounts = await _readTiffArray(raf, entry.dataType, entry.count, entry.valueOffset, endian, inlineMaxBytes: entry.inlineMaxBytes, entryBd: entry.entryBd, offsetInEntry: entry.offsetInEntry);
        } else if (entry.tag == 270) {
          description = await _readTiffString(raf, entry.count, entry.valueOffset, inlineMaxBytes: entry.inlineMaxBytes, entryBd: entry.entryBd, offsetInEntry: entry.offsetInEntry);
        }
      }

      String? currentImageType = _determineImageType(description, width, height, tileWidth, tileHeight);

      if (currentImageType == type) {
        if (stripOffsets.isEmpty || stripByteCounts.isEmpty) {
          return null;
        }

        final bb = BytesBuilder();
        for (int i = 0; i < stripOffsets.length; i++) {
          final offset = stripOffsets[i];
          final count = stripByteCounts[i];
          await raf.setPosition(offset);
          final bytes = await raf.read(count);
          bb.add(bytes);
        }
        return bb.takeBytes();
      }

      ifdOffset = await _readNextIfdOffset(raf, header.nextIfdOffsetPos, endian, isBigTiff);
    }

    return null;
  });
}

/// Extracts an associated image (e.g. 'thumbnail', 'label', or 'macro') from an SVS file and returns it as a decoded [img.Image].
///
/// Handles decompression (JPEG strips with JPEGTables, JPEG 2000, LZW with predictor, uncompressed RGB, Deflate)
/// and stitches multi-strip images into a unified [img.Image].
///
/// [svs] is the open [SvsFile].
/// [type] is the image type identifier to extract ('thumbnail', 'label', or 'macro').
/// [applyColorScheme] if `true`, applies the appropriate color scheme interpretation
/// (e.g., treating RGB JPEG strips as RGB instead of default YCbCr, WhiteIsZero inversion, palette mapping).
/// If `false` extracts the image as-is (backward compatible).
/// [applyDisplayColor] if `true`, applies the DisplayColor color tinting/mapping if present in metadata or passed explicitly.
/// [displayColor] optional explicit display color override (e.g., 0xRRGGBB).
/// Returns the decoded [img.Image], or `null` if the requested image type was not found or failed to decode.
Future<img.Image?> extractSvsImageAsImage(
  SvsFile svs,
  String type, {
  bool applyColorScheme = true,
  bool applyDisplayColor = true,
  int? displayColor,
}) async {
  return await svs.synchronized(() async {
    final raf = svs.raf;
    final endian = svs.endian;
    final isBigTiff = svs.isBigTiff;
    int ifdOffset = svs.firstIfdOffset;
    Uint8List? globalJpegTables;

    while (ifdOffset != 0) {
      final header = await _readIfdHeader(raf, ifdOffset, endian, isBigTiff);
      if (header == null) break;

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

      for (var i = 0; i < header.numEntries; i++) {
        final entry = await _readIfdEntry(raf, endian, isBigTiff);
        if (entry == null) break;

        if (entry.tag == 256) {
          width = _readTiffValue(entry.dataType, entry.count, entry.valueOffset, entry.entryBd, entry.offsetInEntry, endian);
        } else if (entry.tag == 257) {
          height = _readTiffValue(entry.dataType, entry.count, entry.valueOffset, entry.entryBd, entry.offsetInEntry, endian);
        } else if (entry.tag == 259) {
          compression = _readTiffValue(entry.dataType, entry.count, entry.valueOffset, entry.entryBd, entry.offsetInEntry, endian);
        } else if (entry.tag == 262) {
          photometricInterpretation = _readTiffValue(entry.dataType, entry.count, entry.valueOffset, entry.entryBd, entry.offsetInEntry, endian);
        } else if (entry.tag == 273) {
          stripOffsets = await _readTiffArray(raf, entry.dataType, entry.count, entry.valueOffset, endian, inlineMaxBytes: entry.inlineMaxBytes, entryBd: entry.entryBd, offsetInEntry: entry.offsetInEntry);
        } else if (entry.tag == 277) {
          samplesPerPixel = _readTiffValue(entry.dataType, entry.count, entry.valueOffset, entry.entryBd, entry.offsetInEntry, endian);
        } else if (entry.tag == 278) {
          rowsPerStrip = _readTiffValue(entry.dataType, entry.count, entry.valueOffset, entry.entryBd, entry.offsetInEntry, endian);
        } else if (entry.tag == 279) {
          stripByteCounts = await _readTiffArray(raf, entry.dataType, entry.count, entry.valueOffset, endian, inlineMaxBytes: entry.inlineMaxBytes, entryBd: entry.entryBd, offsetInEntry: entry.offsetInEntry);
        } else if (entry.tag == 317) {
          predictor = _readTiffValue(entry.dataType, entry.count, entry.valueOffset, entry.entryBd, entry.offsetInEntry, endian);
        } else if (entry.tag == 320) {
          colorMap = await _readTiffArray(raf, entry.dataType, entry.count, entry.valueOffset, endian, inlineMaxBytes: entry.inlineMaxBytes, entryBd: entry.entryBd, offsetInEntry: entry.offsetInEntry);
        } else if (entry.tag == 322) {
          tileWidth = _readTiffValue(entry.dataType, entry.count, entry.valueOffset, entry.entryBd, entry.offsetInEntry, endian);
        } else if (entry.tag == 323) {
          tileHeight = _readTiffValue(entry.dataType, entry.count, entry.valueOffset, entry.entryBd, entry.offsetInEntry, endian);
        } else if (entry.tag == 347) {
          final currentPos = await raf.position();
          await raf.setPosition(entry.valueOffset);
          jpegTables = await raf.read(entry.count);
          globalJpegTables ??= jpegTables;
          await raf.setPosition(currentPos);
        } else if (entry.tag == 34675) {
          final currentPos = await raf.position();
          await raf.setPosition(entry.valueOffset);
          iccProfile = await raf.read(entry.count);
          await raf.setPosition(currentPos);
        } else if (entry.tag == 270) {
          description = await _readTiffString(raf, entry.count, entry.valueOffset, inlineMaxBytes: entry.inlineMaxBytes, entryBd: entry.entryBd, offsetInEntry: entry.offsetInEntry);
        }
      }

      if (rowsPerStrip <= 0) {
        rowsPerStrip = height > 0 ? height : 1;
      }

      jpegTables ??= globalJpegTables;

      String? currentImageType = _determineImageType(description, width, height, tileWidth, tileHeight);

      if (currentImageType == type) {
        if (stripOffsets.isEmpty || stripByteCounts.isEmpty || width <= 0 || height <= 0) {
          return null;
        }

        int? ifdDisplayColor;
        if (description != null) {
          final props = _parseAperioDescription(description);
          ifdDisplayColor = parseDisplayColor(props['DisplayColor']);
        }
        final effectiveDisplayColor = displayColor ?? ifdDisplayColor;

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
            if (applyDisplayColor && effectiveDisplayColor != null && effectiveDisplayColor != 0) {
              return _applyDisplayColorToImage(fullImage, effectiveDisplayColor);
            }
            return fullImage;
          } else if (compression == 33003 || compression == 33005 || compression == 34712) {
            final fullImage = img.Image(width: width, height: height, numChannels: 4);
            for (int i = 0; i < stripOffsets.length; i++) {
              await raf.setPosition(stripOffsets[i]);
              var stripBytes = await raf.read(stripByteCounts[i]);
              img.Image? stripImg = _decodeJpeg2000(stripBytes);
              stripImg ??= img.decodeImage(stripBytes);
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
            if (applyDisplayColor && effectiveDisplayColor != null && effectiveDisplayColor != 0) {
              return _applyDisplayColorToImage(fullImage, effectiveDisplayColor);
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

            img.Image? image = img.Image.fromBytes(
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
                displayColor: (applyDisplayColor ? effectiveDisplayColor : null),
              );
            } else if (applyDisplayColor && effectiveDisplayColor != null && effectiveDisplayColor != 0) {
              image = _applyDisplayColorToImage(image, effectiveDisplayColor);
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
            img.Image? image = img.Image.fromBytes(
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
                displayColor: (applyDisplayColor ? effectiveDisplayColor : null),
              );
            } else if (applyDisplayColor && effectiveDisplayColor != null && effectiveDisplayColor != 0) {
              image = _applyDisplayColorToImage(image, effectiveDisplayColor);
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

            img.Image? image = img.Image.fromBytes(
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
                displayColor: (applyDisplayColor ? effectiveDisplayColor : null),
              );
            } else if (applyDisplayColor && effectiveDisplayColor != null && effectiveDisplayColor != 0) {
              image = _applyDisplayColorToImage(image, effectiveDisplayColor);
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
            image ??= _decodeJpeg2000(rawBytes);
            if (image != null) {
              if (applyColorScheme) {
                image = _applyColorSchemeToImage(
                  image,
                  photometricInterpretation,
                  samplesPerPixel,
                  colorMap,
                  iccProfile,
                  displayColor: (applyDisplayColor ? effectiveDisplayColor : null),
                );
              } else if (applyDisplayColor && effectiveDisplayColor != null && effectiveDisplayColor != 0) {
                image = _applyDisplayColorToImage(image, effectiveDisplayColor);
              }
            }
            return image;
          }
        } catch (e) {
          return null;
        }
      }

      ifdOffset = await _readNextIfdOffset(raf, header.nextIfdOffsetPos, endian, isBigTiff);
    }

    return null;
  });
}

/// Extracts an associated image (e.g. 'thumbnail', 'label', or 'macro') from an SVS file and returns it as encoded JPEG bytes.
///
/// Handles decompression (JPEG strips with JPEGTables, JPEG 2000, LZW with predictor, uncompressed RGB, Deflate)
/// and stitches multi-strip images into a unified JPEG image.
///
/// [svs] is the open [SvsFile].
/// [type] is the image type identifier to extract ('thumbnail', 'label', or 'macro').
/// [quality] is the JPEG encoding quality (1 to 100, default is 90).
/// [applyColorScheme] if `true`, applies the appropriate color scheme interpretation.
/// [applyDisplayColor] if `true`, applies the DisplayColor color tinting/mapping if present in metadata or passed explicitly.
/// [displayColor] optional explicit display color override (e.g., 0xRRGGBB).
/// Returns the JPEG encoded byte data, or `null` if the requested image type was not found or failed to decode.
Future<Uint8List?> extractSvsImageAsJpeg(
  SvsFile svs,
  String type, {
  int quality = 90,
  bool applyColorScheme = true,
  bool applyDisplayColor = true,
  int? displayColor,
}) async {
  final image = await extractSvsImageAsImage(
    svs,
    type,
    applyColorScheme: applyColorScheme,
    applyDisplayColor: applyDisplayColor,
    displayColor: displayColor,
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
  final int? displayColor;

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
    this.displayColor,
  });
}

Future<({List<_TiledLevelInfo> levels, Uint8List? globalJpegTables, int? globalDisplayColor})> _collectTiledLevels(SvsFile svs) async {
  final raf = svs.raf;
  final endian = svs.endian;
  final isBigTiff = svs.isBigTiff;
  int ifdOffset = svs.firstIfdOffset;

  List<_TiledLevelInfo> levels = [];
  Uint8List? globalJpegTables;
  int? globalDisplayColor;

  while (ifdOffset != 0) {
    final header = await _readIfdHeader(raf, ifdOffset, endian, isBigTiff);
    if (header == null) break;

    int width = 0;
    int height = 0;
    int? tileWidth;
    int? tileHeight;
    List<int> subIfdOffsets = [];

    for (var i = 0; i < header.numEntries; i++) {
      final entry = await _readIfdEntry(raf, endian, isBigTiff);
      if (entry == null) break;

      if (entry.tag == 256) {
        width = _readTiffValue(entry.dataType, entry.count, entry.valueOffset, entry.entryBd, entry.offsetInEntry, endian);
      } else if (entry.tag == 257) {
        height = _readTiffValue(entry.dataType, entry.count, entry.valueOffset, entry.entryBd, entry.offsetInEntry, endian);
      } else if (entry.tag == 322) {
        tileWidth = _readTiffValue(entry.dataType, entry.count, entry.valueOffset, entry.entryBd, entry.offsetInEntry, endian);
      } else if (entry.tag == 323) {
        tileHeight = _readTiffValue(entry.dataType, entry.count, entry.valueOffset, entry.entryBd, entry.offsetInEntry, endian);
      } else if (entry.tag == 330) {
        subIfdOffsets = await _readTiffArray(raf, entry.dataType, entry.count, entry.valueOffset, endian, inlineMaxBytes: entry.inlineMaxBytes, entryBd: entry.entryBd, offsetInEntry: entry.offsetInEntry);
      } else if (entry.tag == 347 && globalJpegTables == null) {
        final currentPos = await raf.position();
        await raf.setPosition(entry.valueOffset);
        globalJpegTables = await raf.read(entry.count);
        await raf.setPosition(currentPos);
      } else if (entry.tag == 270 && globalDisplayColor == null) {
        final description = await _readTiffString(raf, entry.count, entry.valueOffset, inlineMaxBytes: entry.inlineMaxBytes, entryBd: entry.entryBd, offsetInEntry: entry.offsetInEntry);
        if (description != null) {
          final props = _parseAperioDescription(description);
          globalDisplayColor = parseDisplayColor(props['DisplayColor']);
        }
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

    // Process SubIFDs if present
    for (final subIfd in subIfdOffsets) {
      if (subIfd != 0) {
        final subHeader = await _readIfdHeader(raf, subIfd, endian, isBigTiff);
        if (subHeader != null) {
          int sWidth = 0;
          int sHeight = 0;
          int? sTileWidth;
          int? sTileHeight;
          for (var i = 0; i < subHeader.numEntries; i++) {
            final entry = await _readIfdEntry(raf, endian, isBigTiff);
            if (entry == null) break;
            if (entry.tag == 256) {
              sWidth = _readTiffValue(entry.dataType, entry.count, entry.valueOffset, entry.entryBd, entry.offsetInEntry, endian);
            } else if (entry.tag == 257) {
              sHeight = _readTiffValue(entry.dataType, entry.count, entry.valueOffset, entry.entryBd, entry.offsetInEntry, endian);
            } else if (entry.tag == 322) {
              sTileWidth = _readTiffValue(entry.dataType, entry.count, entry.valueOffset, entry.entryBd, entry.offsetInEntry, endian);
            } else if (entry.tag == 323) {
              sTileHeight = _readTiffValue(entry.dataType, entry.count, entry.valueOffset, entry.entryBd, entry.offsetInEntry, endian);
            }
          }
          if (sTileWidth != null && sTileHeight != null && sWidth > 0 && sHeight > 0) {
            levels.add(_TiledLevelInfo(
              ifdOffset: subIfd,
              width: sWidth,
              height: sHeight,
              tileWidth: sTileWidth,
              tileHeight: sTileHeight,
            ));
          }
        }
      }
    }

    ifdOffset = await _readNextIfdOffset(raf, header.nextIfdOffsetPos, endian, isBigTiff);
  }

  levels.sort((a, b) => b.width.compareTo(a.width));
  svs.cachedTiledLevels = levels;
  svs.cachedGlobalJpegTables = globalJpegTables;
  svs.cachedGlobalDisplayColor = globalDisplayColor;
  return (levels: levels, globalJpegTables: globalJpegTables, globalDisplayColor: globalDisplayColor);
}

Future<({List<_TiledLevelInfo> levels, Uint8List? globalJpegTables, int? globalDisplayColor})> _getOrCollectTiledLevels(SvsFile svs) async {
  if (svs.cachedTiledLevels != null) {
    return (
      levels: svs.cachedTiledLevels! as List<_TiledLevelInfo>,
      globalJpegTables: svs.cachedGlobalJpegTables,
      globalDisplayColor: svs.cachedGlobalDisplayColor,
    );
  }

  return await svs.synchronized(() async {
    if (svs.cachedTiledLevels != null) {
      return (
        levels: svs.cachedTiledLevels! as List<_TiledLevelInfo>,
        globalJpegTables: svs.cachedGlobalJpegTables,
        globalDisplayColor: svs.cachedGlobalDisplayColor,
      );
    }

    final collected = await _collectTiledLevels(svs);
    svs.cachedTiledLevels = collected.levels;
    svs.cachedGlobalJpegTables = collected.globalJpegTables;
    svs.cachedGlobalDisplayColor = collected.globalDisplayColor;
    return collected;
  });
}

Future<_TiledLevelFullData?> _getOrLoadLevelFullData(
  SvsFile svs,
  _TiledLevelInfo targetLevel,
  Uint8List? globalJpegTables, [
  int? globalDisplayColor,
]) async {
  if (targetLevel.fullData != null) {
    return targetLevel.fullData;
  }

  return await svs.synchronized(() async {
    if (targetLevel.fullData != null) {
      return targetLevel.fullData;
    }

    final raf = svs.raf;
    final endian = svs.endian;
    final isBigTiff = svs.isBigTiff;
    final targetIfd = targetLevel.ifdOffset;

    final header = await _readIfdHeader(raf, targetIfd, endian, isBigTiff);
    if (header == null) return null;

    int compression = 1;
    int samplesPerPixel = 3;
    int predictor = 1;
    int photometricInterpretation = 2;
    List<int> tileOffsets = [];
    List<int> tileByteCounts = [];
    Uint8List? jpegTables = globalJpegTables;
    Uint8List? iccProfile;
    List<int>? colorMap;
    int? displayColor;

    for (var i = 0; i < header.numEntries; i++) {
      final entry = await _readIfdEntry(raf, endian, isBigTiff);
      if (entry == null) break;

      if (entry.tag == 259) {
        compression = _readTiffValue(entry.dataType, entry.count, entry.valueOffset, entry.entryBd, entry.offsetInEntry, endian);
      } else if (entry.tag == 262) {
        photometricInterpretation = _readTiffValue(entry.dataType, entry.count, entry.valueOffset, entry.entryBd, entry.offsetInEntry, endian);
      } else if (entry.tag == 277) {
        samplesPerPixel = _readTiffValue(entry.dataType, entry.count, entry.valueOffset, entry.entryBd, entry.offsetInEntry, endian);
      } else if (entry.tag == 317) {
        predictor = _readTiffValue(entry.dataType, entry.count, entry.valueOffset, entry.entryBd, entry.offsetInEntry, endian);
      } else if (entry.tag == 320) {
        colorMap = await _readTiffArray(raf, entry.dataType, entry.count, entry.valueOffset, endian, inlineMaxBytes: entry.inlineMaxBytes, entryBd: entry.entryBd, offsetInEntry: entry.offsetInEntry);
      } else if (entry.tag == 324) {
        tileOffsets = await _readTiffArray(raf, entry.dataType, entry.count, entry.valueOffset, endian, inlineMaxBytes: entry.inlineMaxBytes, entryBd: entry.entryBd, offsetInEntry: entry.offsetInEntry);
      } else if (entry.tag == 325) {
        tileByteCounts = await _readTiffArray(raf, entry.dataType, entry.count, entry.valueOffset, endian, inlineMaxBytes: entry.inlineMaxBytes, entryBd: entry.entryBd, offsetInEntry: entry.offsetInEntry);
      } else if (entry.tag == 347) {
        final currentPos = await raf.position();
        await raf.setPosition(entry.valueOffset);
        jpegTables = await raf.read(entry.count);
        await raf.setPosition(currentPos);
      } else if (entry.tag == 34675) {
        final currentPos = await raf.position();
        await raf.setPosition(entry.valueOffset);
        iccProfile = await raf.read(entry.count);
        await raf.setPosition(currentPos);
      } else if (entry.tag == 270) {
        final description = await _readTiffString(raf, entry.count, entry.valueOffset, inlineMaxBytes: entry.inlineMaxBytes, entryBd: entry.entryBd, offsetInEntry: entry.offsetInEntry);
        if (description != null) {
          final props = _parseAperioDescription(description);
          displayColor = parseDisplayColor(props['DisplayColor']);
        }
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
      displayColor: displayColor ?? globalDisplayColor,
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
/// [cancelToken] optional cancellation token to abort the operation.
/// Returns the raw tile bytes, or `null` if the tile coordinates or layer are invalid or cancelled.
Future<Uint8List?> extractSvsTile(
  SvsFile svs,
  int layerIndex,
  int tileX,
  int tileY, {
  CancellationToken? cancelToken,
}) async {
  if (cancelToken?.isCancelled == true) {
    return null;
  }

  final collected = await _getOrCollectTiledLevels(svs);
  if (cancelToken?.isCancelled == true) {
    return null;
  }
  final levels = collected.levels;

  if (layerIndex < 0 || layerIndex >= levels.length) {
    return null;
  }

  final targetLevel = levels[layerIndex];
  final fullData = await _getOrLoadLevelFullData(svs, targetLevel, collected.globalJpegTables, collected.globalDisplayColor);
  if (fullData == null || cancelToken?.isCancelled == true) {
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

  if (cancelToken?.isCancelled == true) {
    return null;
  }

  final bytes = await svs.readBytesAt(offset, byteCount, cancelToken: cancelToken);
  if (cancelToken?.isCancelled == true) {
    return null;
  }
  return bytes;
}

/// Extracts a specific tile from a resolution layer in the SVS file and returns it as a decoded [img.Image].
///
/// Handles decompression (JPEG tiles with JPEGTables, JPEG 2000, LZW with predictor, uncompressed RGB, Deflate).
///
/// [svs] is the open [SvsFile].
/// [layerIndex] is the resolution layer index (0 is the highest resolution / baseline level).
/// [tileX] and [tileY] are the 0-based horizontal and vertical tile coordinates (not pixel coordinates).
/// [applyColorScheme] if `true`, applies the appropriate color scheme interpretation
/// (e.g., treating RGB JPEG as RGB instead of default YCbCr, WhiteIsZero inversion, palette mapping).
/// If `false`, extracts the tile image as-is.
/// [applyDisplayColor] if `true`, applies the DisplayColor color tinting/mapping if present in metadata or passed explicitly.
/// [displayColor] optional explicit display color override (e.g., 0xRRGGBB).
/// [cancelToken] optional cancellation token to abort the operation.
/// Returns the decoded [img.Image], or `null` if the tile coordinates or layer are invalid, failed to decode, or cancelled.
Future<img.Image?> extractSvsTileAsImage(
  SvsFile svs,
  int layerIndex,
  int tileX,
  int tileY, {
  bool applyColorScheme = true,
  bool applyDisplayColor = true,
  int? displayColor,
  CancellationToken? cancelToken,
}) async {
  if (cancelToken?.isCancelled == true) {
    return null;
  }

  final collected = await _getOrCollectTiledLevels(svs);
  if (cancelToken?.isCancelled == true) {
    return null;
  }
  final levels = collected.levels;

  if (layerIndex < 0 || layerIndex >= levels.length) {
    return null;
  }

  final targetLevel = levels[layerIndex];
  final fullData = await _getOrLoadLevelFullData(svs, targetLevel, collected.globalJpegTables, collected.globalDisplayColor);
  if (fullData == null || cancelToken?.isCancelled == true) {
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

  final effectiveDisplayColor = displayColor ?? fullData.displayColor;

  // Handle empty / sparse tiles (e.g. background)
  if (byteCount == 0 || offset == 0) {
    if (cancelToken?.isCancelled == true) {
      return null;
    }
    final blank = img.Image(
      width: targetLevel.tileWidth,
      height: targetLevel.tileHeight,
      numChannels: fullData.samplesPerPixel > 0 ? fullData.samplesPerPixel : 3,
    );
    blank.clear(img.ColorRgb8(255, 255, 255));
    if (applyDisplayColor && effectiveDisplayColor != null && effectiveDisplayColor != 0) {
      return _applyDisplayColorToImage(blank, effectiveDisplayColor);
    }
    return blank;
  }

  if (cancelToken?.isCancelled == true) {
    return null;
  }

  final rawTileBytes = await svs.readBytesAt(offset, byteCount, cancelToken: cancelToken);

  if (cancelToken?.isCancelled == true) {
    return null;
  }

  if (rawTileBytes.isEmpty) {
    final blank = img.Image(
      width: targetLevel.tileWidth,
      height: targetLevel.tileHeight,
      numChannels: fullData.samplesPerPixel > 0 ? fullData.samplesPerPixel : 3,
    );
    blank.clear(img.ColorRgb8(255, 255, 255));
    if (applyDisplayColor && effectiveDisplayColor != null && effectiveDisplayColor != 0) {
      return _applyDisplayColorToImage(blank, effectiveDisplayColor);
    }
    return blank;
  }

  return _decodeTileBytes(
    rawTileBytes: rawTileBytes,
    tileWidth: targetLevel.tileWidth,
    tileHeight: targetLevel.tileHeight,
    compression: fullData.compression,
    samplesPerPixel: fullData.samplesPerPixel,
    predictor: fullData.predictor,
    photometricInterpretation: fullData.photometricInterpretation,
    applyColorScheme: applyColorScheme,
    applyDisplayColor: applyDisplayColor,
    displayColor: effectiveDisplayColor,
    jpegTables: fullData.jpegTables,
    iccProfile: fullData.iccProfile,
    colorMap: fullData.colorMap,
    cancelToken: cancelToken,
  );
}

/// Internal helper for decoding tile bytes with given format settings.
img.Image? _decodeTileBytes({
  required Uint8List rawTileBytes,
  required int tileWidth,
  required int tileHeight,
  required int compression,
  required int samplesPerPixel,
  required int predictor,
  required int photometricInterpretation,
  required bool applyColorScheme,
  bool applyDisplayColor = true,
  int? displayColor,
  required Uint8List? jpegTables,
  required Uint8List? iccProfile,
  required List<int>? colorMap,
  CancellationToken? cancelToken,
}) {
  try {
    if (cancelToken?.isCancelled == true) return null;

    if (compression == 7 || compression == 6) {
      var tileBytes = rawTileBytes;
      if (jpegTables != null) {
        tileBytes = _combineJpegWithTables(rawTileBytes, jpegTables);
      }

      if (cancelToken?.isCancelled == true) return null;

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
        if (cancelToken?.isCancelled == true) return null;
        try {
          tileImg = img.decodeJpg(tileBytes);
        } catch (_) {
          tileImg = null;
        }
      }

      if (tileImg == null) {
        if (cancelToken?.isCancelled == true) return null;
        try {
          tileImg = img.decodeImage(tileBytes);
        } catch (_) {
          tileImg = null;
        }
      }

      if (tileImg != null) {
        if (cancelToken?.isCancelled == true) return null;
        if (applyColorScheme) {
          if (photometricInterpretation == 0) {
            _applyWhiteIsZero(tileImg);
          }
          if (iccProfile != null && iccProfile.length <= 65519) {
            if (cancelToken?.isCancelled == true) return null;
            tileImg.iccProfile = img.IccProfile('', img.IccProfileCompression.none, iccProfile);
          }
        }
        if (applyDisplayColor && displayColor != null && displayColor != 0) {
          if (cancelToken?.isCancelled == true) return null;
          tileImg = _applyDisplayColorToImage(tileImg, displayColor);
        }
      }
      return cancelToken?.isCancelled == true ? null : tileImg;
    } else if (compression == 33003 || compression == 33005 || compression == 34712) {
      if (cancelToken?.isCancelled == true) return null;
      var tileImg = _decodeJpeg2000(rawTileBytes);
      if (cancelToken?.isCancelled == true) return null;

      if (tileImg != null) {
        if (applyColorScheme) {
          if (photometricInterpretation == 0) {
            _applyWhiteIsZero(tileImg);
          }
          if (iccProfile != null && iccProfile.length <= 65519) {
            if (cancelToken?.isCancelled == true) return null;
            tileImg.iccProfile = img.IccProfile('', img.IccProfileCompression.none, iccProfile);
          }
        }
        if (applyDisplayColor && displayColor != null && displayColor != 0) {
          if (cancelToken?.isCancelled == true) return null;
          tileImg = _applyDisplayColorToImage(tileImg, displayColor);
        }
      }
      return cancelToken?.isCancelled == true ? null : tileImg;
    } else if (compression == 5) {
      if (cancelToken?.isCancelled == true) return null;

      final expectedLength = tileWidth * tileHeight * samplesPerPixel;
      final decompressed = _decompressTiffLzw(rawTileBytes, expectedLength);
      if (cancelToken?.isCancelled == true) return null;

      if (predictor == 2) {
        _applyHorizontalPredictor(decompressed, tileWidth, tileHeight, samplesPerPixel);
      }
      if (cancelToken?.isCancelled == true) return null;

      img.Image? tileImg = img.Image.fromBytes(
        width: tileWidth,
        height: tileHeight,
        bytes: decompressed.buffer,
        numChannels: samplesPerPixel,
        order: samplesPerPixel >= 3 ? img.ChannelOrder.rgb : null,
      );
      if (applyColorScheme) {
        if (cancelToken?.isCancelled == true) return null;
        tileImg = _applyColorSchemeToImage(
          tileImg,
          photometricInterpretation,
          samplesPerPixel,
          colorMap,
          iccProfile,
          displayColor: (applyDisplayColor ? displayColor : null),
          cancelToken: cancelToken,
        );
      } else if (applyDisplayColor && displayColor != null && displayColor != 0) {
        if (cancelToken?.isCancelled == true) return null;
        tileImg = _applyDisplayColorToImage(tileImg, displayColor);
      }
      return cancelToken?.isCancelled == true ? null : tileImg;
    } else if (compression == 1) {
      if (cancelToken?.isCancelled == true) return null;
      final dataBytes = Uint8List.fromList(rawTileBytes);
      if (predictor == 2) {
        _applyHorizontalPredictor(dataBytes, tileWidth, tileHeight, samplesPerPixel);
      }
      if (cancelToken?.isCancelled == true) return null;

      img.Image? tileImg = img.Image.fromBytes(
        width: tileWidth,
        height: tileHeight,
        bytes: dataBytes.buffer,
        numChannels: samplesPerPixel,
        order: samplesPerPixel >= 3 ? img.ChannelOrder.rgb : null,
      );
      if (applyColorScheme) {
        if (cancelToken?.isCancelled == true) return null;
        tileImg = _applyColorSchemeToImage(
          tileImg,
          photometricInterpretation,
          samplesPerPixel,
          colorMap,
          iccProfile,
          displayColor: (applyDisplayColor ? displayColor : null),
          cancelToken: cancelToken,
        );
      } else if (applyDisplayColor && displayColor != null && displayColor != 0) {
        if (cancelToken?.isCancelled == true) return null;
        tileImg = _applyDisplayColorToImage(tileImg, displayColor);
      }
      return cancelToken?.isCancelled == true ? null : tileImg;
    } else if (compression == 8 || compression == 32946) {
      if (cancelToken?.isCancelled == true) return null;
      final decompressed = Uint8List.fromList(zlib.decode(rawTileBytes));
      if (predictor == 2) {
        _applyHorizontalPredictor(decompressed, tileWidth, tileHeight, samplesPerPixel);
      }
      if (cancelToken?.isCancelled == true) return null;

      img.Image? tileImg = img.Image.fromBytes(
        width: tileWidth,
        height: tileHeight,
        bytes: decompressed.buffer,
        numChannels: samplesPerPixel,
        order: samplesPerPixel >= 3 ? img.ChannelOrder.rgb : null,
      );
      if (applyColorScheme) {
        if (cancelToken?.isCancelled == true) return null;
        tileImg = _applyColorSchemeToImage(
          tileImg,
          photometricInterpretation,
          samplesPerPixel,
          colorMap,
          iccProfile,
          displayColor: (applyDisplayColor ? displayColor : null),
          cancelToken: cancelToken,
        );
      } else if (applyDisplayColor && displayColor != null && displayColor != 0) {
        if (cancelToken?.isCancelled == true) return null;
        tileImg = _applyDisplayColorToImage(tileImg, displayColor);
      }
      return cancelToken?.isCancelled == true ? null : tileImg;
    } else {
      if (cancelToken?.isCancelled == true) return null;
      var tileImg = img.decodeImage(rawTileBytes);
      if (tileImg == null) {
        if (cancelToken?.isCancelled == true) return null;
        tileImg = _decodeJpeg2000(rawTileBytes);
      }
      if (cancelToken?.isCancelled == true) return null;
      if (tileImg != null) {
        if (applyColorScheme) {
          if (cancelToken?.isCancelled == true) return null;
          tileImg = _applyColorSchemeToImage(
            tileImg,
            photometricInterpretation,
            samplesPerPixel,
            colorMap,
            iccProfile,
            displayColor: (applyDisplayColor ? displayColor : null),
            cancelToken: cancelToken,
          );
        } else if (applyDisplayColor && displayColor != null && displayColor != 0) {
          if (cancelToken?.isCancelled == true) return null;
          tileImg = _applyDisplayColorToImage(tileImg, displayColor);
        }
      }
      return cancelToken?.isCancelled == true ? null : tileImg;
    }
  } catch (e) {
    return null;
  }
}

class _TiffIfdHeader {
  final int numEntries;
  final int nextIfdOffsetPos;

  const _TiffIfdHeader(this.numEntries, this.nextIfdOffsetPos);
}

class _TiffEntry {
  final int tag;
  final int dataType;
  final int count;
  final int valueOffset;
  final ByteData entryBd;
  final int offsetInEntry;
  final int inlineMaxBytes;

  const _TiffEntry({
    required this.tag,
    required this.dataType,
    required this.count,
    required this.valueOffset,
    required this.entryBd,
    required this.offsetInEntry,
    required this.inlineMaxBytes,
  });
}

Future<_TiffIfdHeader?> _readIfdHeader(
  RandomAccessFile raf,
  int ifdOffset,
  Endian endian,
  bool isBigTiff,
) async {
  if (ifdOffset <= 0) return null;
  await raf.setPosition(ifdOffset);
  if (isBigTiff) {
    final numEntriesBytes = await raf.read(8);
    if (numEntriesBytes.length < 8) return null;
    final numEntries = ByteData.sublistView(numEntriesBytes).getUint64(0, endian);
    final nextIfdOffsetPos = ifdOffset + 8 + numEntries * 20;
    return _TiffIfdHeader(numEntries, nextIfdOffsetPos);
  } else {
    final numEntriesBytes = await raf.read(2);
    if (numEntriesBytes.length < 2) return null;
    final numEntries = ByteData.sublistView(numEntriesBytes).getUint16(0, endian);
    final nextIfdOffsetPos = ifdOffset + 2 + numEntries * 12;
    return _TiffIfdHeader(numEntries, nextIfdOffsetPos);
  }
}

Future<_TiffEntry?> _readIfdEntry(
  RandomAccessFile raf,
  Endian endian,
  bool isBigTiff,
) async {
  if (isBigTiff) {
    final entryBytes = await raf.read(20);
    if (entryBytes.length < 20) return null;
    final entryBd = ByteData.sublistView(entryBytes);
    final tag = entryBd.getUint16(0, endian);
    final dataType = entryBd.getUint16(2, endian);
    final count = entryBd.getUint64(4, endian);
    final valueOffset = entryBd.getUint64(12, endian);
    return _TiffEntry(
      tag: tag,
      dataType: dataType,
      count: count,
      valueOffset: valueOffset,
      entryBd: entryBd,
      offsetInEntry: 12,
      inlineMaxBytes: 8,
    );
  } else {
    final entryBytes = await raf.read(12);
    if (entryBytes.length < 12) return null;
    final entryBd = ByteData.sublistView(entryBytes);
    final tag = entryBd.getUint16(0, endian);
    final dataType = entryBd.getUint16(2, endian);
    final count = entryBd.getUint32(4, endian);
    final valueOffset = entryBd.getUint32(8, endian);
    return _TiffEntry(
      tag: tag,
      dataType: dataType,
      count: count,
      valueOffset: valueOffset,
      entryBd: entryBd,
      offsetInEntry: 8,
      inlineMaxBytes: 4,
    );
  }
}

Future<int> _readNextIfdOffset(
  RandomAccessFile raf,
  int nextIfdOffsetPos,
  Endian endian,
  bool isBigTiff,
) async {
  await raf.setPosition(nextIfdOffsetPos);
  if (isBigTiff) {
    final nextIfdBytes = await raf.read(8);
    if (nextIfdBytes.length < 8) return 0;
    return ByteData.sublistView(nextIfdBytes).getUint64(0, endian);
  } else {
    final nextIfdBytes = await raf.read(4);
    if (nextIfdBytes.length < 4) return 0;
    return ByteData.sublistView(nextIfdBytes).getUint32(0, endian);
  }
}

Future<String?> _readTiffString(
  RandomAccessFile raf,
  int count,
  int valueOffset, {
  int inlineMaxBytes = 4,
  ByteData? entryBd,
  int offsetInEntry = 8,
}) async {
  if (count <= 0) return null;
  Uint8List descBytes;
  if (count <= inlineMaxBytes && entryBd != null) {
    descBytes = entryBd.buffer.asUint8List(
      entryBd.offsetInBytes + offsetInEntry,
      count,
    );
  } else {
    final currentPos = await raf.position();
    await raf.setPosition(valueOffset);
    descBytes = await raf.read(count);
    await raf.setPosition(currentPos);
  }
  var length = descBytes.length;
  if (length > 0 && descBytes[length - 1] == 0) {
    length--;
  }
  return String.fromCharCodes(descBytes.sublist(0, length)).trim();
}

int _readTiffValue(
  int type,
  int count,
  int valueOffset,
  ByteData entryBd,
  int offsetInEntry,
  Endian endian,
) {
  if (type == 1) { // BYTE
    return entryBd.getUint8(offsetInEntry);
  } else if (type == 3) { // SHORT
    return entryBd.getUint16(offsetInEntry, endian);
  } else if (type == 4) { // LONG
    return entryBd.getUint32(offsetInEntry, endian);
  } else if (type == 16 || type == 18) { // LONG8 or IFD8
    return entryBd.getUint64(offsetInEntry, endian);
  } else if (type == 6) { // SBYTE
    return entryBd.getInt8(offsetInEntry);
  } else if (type == 8) { // SSHORT
    return entryBd.getInt16(offsetInEntry, endian);
  } else if (type == 9) { // SLONG
    return entryBd.getInt32(offsetInEntry, endian);
  } else if (type == 17) { // SLONG8
    return entryBd.getInt64(offsetInEntry, endian);
  }
  return valueOffset;
}

Future<List<int>> _readTiffArray(
  RandomAccessFile raf,
  int type,
  int count,
  int valueOffset,
  Endian endian, {
  int inlineMaxBytes = 4,
  ByteData? entryBd,
  int offsetInEntry = 8,
}) async {
  if (count <= 0) return const [];

  int elementSize = 0;
  if (type == 1 || type == 6 || type == 7) {
    elementSize = 1;
  } else if (type == 3 || type == 8) {
    elementSize = 2;
  } else if (type == 4 || type == 9 || type == 11) {
    elementSize = 4;
  } else if (type == 16 || type == 17 || type == 18 || type == 5 || type == 10 || type == 12) {
    elementSize = 8;
  } else {
    elementSize = 4;
  }

  final totalBytes = count * elementSize;
  ByteData bd;
  int baseOffset = 0;

  if (totalBytes <= inlineMaxBytes && entryBd != null) {
    bd = entryBd;
    baseOffset = offsetInEntry;
  } else {
    final currentPos = await raf.position();
    await raf.setPosition(valueOffset);
    final bytes = await raf.read(totalBytes);
    await raf.setPosition(currentPos);

    if (bytes.length < totalBytes) return const [];
    bd = ByteData.sublistView(bytes);
    baseOffset = 0;
  }

  final result = List<int>.filled(count, 0);
  for (int i = 0; i < count; i++) {
    final offset = baseOffset + i * elementSize;
    if (type == 3) {
      result[i] = bd.getUint16(offset, endian);
    } else if (type == 4) {
      result[i] = bd.getUint32(offset, endian);
    } else if (type == 16 || type == 18) {
      result[i] = bd.getUint64(offset, endian);
    } else if (type == 1 || type == 7) {
      result[i] = bd.getUint8(offset);
    } else if (type == 8) {
      result[i] = bd.getInt16(offset, endian);
    } else if (type == 9) {
      result[i] = bd.getInt32(offset, endian);
    } else if (type == 17) {
      result[i] = bd.getInt64(offset, endian);
    } else if (type == 6) {
      result[i] = bd.getInt8(offset);
    } else {
      result[i] = bd.getUint32(offset, endian);
    }
  }
  return result;
}

/// Reads all metadata from the SVS file, including all pyramid levels and associated images.
///
/// [svs] is the open [SvsFile].
/// Returns an [SvsFullMetadata] instance containing the levels and associated images, or `null` on failure.
Future<SvsFullMetadata?> readFullSvsMetadata(SvsFile svs) async {
  return await svs.synchronized(() async {
    final raf = svs.raf;
    final endian = svs.endian;
    final isBigTiff = svs.isBigTiff;
    int ifdOffset = svs.firstIfdOffset;

    List<SvsImageInfo> allImages = [];

    while (ifdOffset != 0) {
      final header = await _readIfdHeader(raf, ifdOffset, endian, isBigTiff);
      if (header == null) break;

      int width = 0;
      int height = 0;
      int? tileWidth;
      int? tileHeight;
      Map<String, String> properties = {};
      String? description;
      List<int> subIfdOffsets = [];

      for (var i = 0; i < header.numEntries; i++) {
        final entry = await _readIfdEntry(raf, endian, isBigTiff);
        if (entry == null) break;

        if (entry.tag == 256) {
          width = _readTiffValue(entry.dataType, entry.count, entry.valueOffset, entry.entryBd, entry.offsetInEntry, endian);
        } else if (entry.tag == 257) {
          height = _readTiffValue(entry.dataType, entry.count, entry.valueOffset, entry.entryBd, entry.offsetInEntry, endian);
        } else if (entry.tag == 322) {
          tileWidth = _readTiffValue(entry.dataType, entry.count, entry.valueOffset, entry.entryBd, entry.offsetInEntry, endian);
        } else if (entry.tag == 323) {
          tileHeight = _readTiffValue(entry.dataType, entry.count, entry.valueOffset, entry.entryBd, entry.offsetInEntry, endian);
        } else if (entry.tag == 270) {
          description = await _readTiffString(raf, entry.count, entry.valueOffset, inlineMaxBytes: entry.inlineMaxBytes, entryBd: entry.entryBd, offsetInEntry: entry.offsetInEntry);
          if (description != null) {
            properties = _parseAperioDescription(description);
          }
        } else if (entry.tag == 330) {
          subIfdOffsets = await _readTiffArray(raf, entry.dataType, entry.count, entry.valueOffset, endian, inlineMaxBytes: entry.inlineMaxBytes, entryBd: entry.entryBd, offsetInEntry: entry.offsetInEntry);
        }
      }

      String? imageType;
      if (tileWidth != null && tileHeight != null) {
        imageType = 'level';
      } else {
        imageType = _determineImageType(description, width, height, tileWidth, tileHeight) ?? 'other_association';
      }

      if (imageType == 'other_association') {
        if (width > 0 && height > 0) {
          double aspect = width / height;
          if (width < 2000 && height < 2000 && (aspect > 0.5 && aspect < 2.0)) {
            if (!allImages.any((img) => img.type == 'thumbnail')) {
              imageType = 'thumbnail';
            }
          }
        }
      }

      allImages.add(SvsImageInfo(
        type: imageType,
        width: width,
        height: height,
        tileWidth: tileWidth,
        tileHeight: tileHeight,
        compression: properties['Compression'],
        properties: properties,
        displayColor: parseDisplayColor(properties['DisplayColor']),
      ));

      // Process SubIFDs if present
      for (final subIfd in subIfdOffsets) {
        if (subIfd != 0) {
          final subHeader = await _readIfdHeader(raf, subIfd, endian, isBigTiff);
          if (subHeader != null) {
            int sWidth = 0;
            int sHeight = 0;
            int? sTileWidth;
            int? sTileHeight;
            Map<String, String> sProperties = {};
            String? sDescription;

            for (var i = 0; i < subHeader.numEntries; i++) {
              final entry = await _readIfdEntry(raf, endian, isBigTiff);
              if (entry == null) break;

              if (entry.tag == 256) {
                sWidth = _readTiffValue(entry.dataType, entry.count, entry.valueOffset, entry.entryBd, entry.offsetInEntry, endian);
              } else if (entry.tag == 257) {
                sHeight = _readTiffValue(entry.dataType, entry.count, entry.valueOffset, entry.entryBd, entry.offsetInEntry, endian);
              } else if (entry.tag == 322) {
                sTileWidth = _readTiffValue(entry.dataType, entry.count, entry.valueOffset, entry.entryBd, entry.offsetInEntry, endian);
              } else if (entry.tag == 323) {
                sTileHeight = _readTiffValue(entry.dataType, entry.count, entry.valueOffset, entry.entryBd, entry.offsetInEntry, endian);
              } else if (entry.tag == 270) {
                sDescription = await _readTiffString(raf, entry.count, entry.valueOffset, inlineMaxBytes: entry.inlineMaxBytes, entryBd: entry.entryBd, offsetInEntry: entry.offsetInEntry);
                if (sDescription != null) {
                  sProperties = _parseAperioDescription(sDescription);
                }
              }
            }

            String? sImageType;
            if (sTileWidth != null && sTileHeight != null) {
              sImageType = 'level';
            } else {
              sImageType = _determineImageType(sDescription, sWidth, sHeight, sTileWidth, sTileHeight) ?? 'other_association';
            }

            if (sImageType == 'other_association') {
              if (sWidth > 0 && sHeight > 0) {
                double aspect = sWidth / sHeight;
                if (sWidth < 2000 && sHeight < 2000 && (aspect > 0.5 && aspect < 2.0)) {
                  if (!allImages.any((img) => img.type == 'thumbnail')) {
                    sImageType = 'thumbnail';
                  }
                }
              }
            }

            allImages.add(SvsImageInfo(
              type: sImageType,
              width: sWidth,
              height: sHeight,
              tileWidth: sTileWidth,
              tileHeight: sTileHeight,
              compression: sProperties['Compression'] ?? properties['Compression'],
              properties: sProperties.isNotEmpty ? sProperties : properties,
              displayColor: parseDisplayColor(sProperties['DisplayColor'] ?? properties['DisplayColor']),
            ));
          }
        }
      }

      ifdOffset = await _readNextIfdOffset(raf, header.nextIfdOffsetPos, endian, isBigTiff);
    }

    final levels = allImages.where((img) => img.type == 'level').toList();
    final Map<String, SvsImageInfo> associations = {};

    for (var img in allImages) {
      if (img.type != 'level') {
        String key = img.type ?? 'association';
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

    final double baseWidth = levels.isNotEmpty ? levels.first.width.toDouble() : 1.0;
    final List<SvsImageInfo> levelsWithDownsample = levels.map((lvl) {
      final double downsample = (baseWidth > 0 && lvl.width > 0)
          ? (baseWidth / lvl.width)
          : 1.0;
      return lvl.copyWith(downsample: downsample);
    }).toList();

    return SvsFullMetadata(levels: levelsWithDownsample, associations: associations);
  });
}

/// Reads basic metadata of the primary image from the SVS file.
///
/// [svs] is the open [SvsFile].
/// Returns an [SvsMetadata] instance, or `null` on failure.
Future<SvsMetadata?> readSvsMetadata(SvsFile svs) async {
  return await svs.synchronized(() async {
    final raf = svs.raf;
    final endian = svs.endian;
    final isBigTiff = svs.isBigTiff;
    int ifdOffset = svs.firstIfdOffset;

    Map<String, String> properties = {};
    int width = 0;
    int height = 0;
    int? tileWidth;
    int? tileHeight;

    if (ifdOffset != 0) {
      final header = await _readIfdHeader(raf, ifdOffset, endian, isBigTiff);
      if (header == null) return null;

      for (var i = 0; i < header.numEntries; i++) {
        final entry = await _readIfdEntry(raf, endian, isBigTiff);
        if (entry == null) break;

        if (entry.tag == 256) {
          width = _readTiffValue(entry.dataType, entry.count, entry.valueOffset, entry.entryBd, entry.offsetInEntry, endian);
        } else if (entry.tag == 257) {
          height = _readTiffValue(entry.dataType, entry.count, entry.valueOffset, entry.entryBd, entry.offsetInEntry, endian);
        } else if (entry.tag == 322) {
          tileWidth = _readTiffValue(entry.dataType, entry.count, entry.valueOffset, entry.entryBd, entry.offsetInEntry, endian);
        } else if (entry.tag == 323) {
          tileHeight = _readTiffValue(entry.dataType, entry.count, entry.valueOffset, entry.entryBd, entry.offsetInEntry, endian);
        } else if (entry.tag == 270) {
          final description = await _readTiffString(raf, entry.count, entry.valueOffset, inlineMaxBytes: entry.inlineMaxBytes, entryBd: entry.entryBd, offsetInEntry: entry.offsetInEntry);
          if (description != null) {
            properties = _parseAperioDescription(description);
          }
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
      displayColor: parseDisplayColor(properties['DisplayColor']),
    );
  });
}

Map<String, String> _parseAperioDescription(String description) {
  final Map<String, String> props = {};
  final lines = description.split(RegExp(r'[|\n\r]'));

  for (var line in lines) {
    line = line.trim();
    if (line.isEmpty) continue;

    if (line.startsWith('Aperio ')) {
      props['Vendor'] = 'Aperio';
      props['Version'] = line.substring(7).trim();
      continue;
    }

    if (RegExp(r'^\d+x\d+').hasMatch(line)) {
      props['ImageInfo'] = line;

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
      } else if (line.toUpperCase().contains('J2K') || line.toUpperCase().contains('JPEG2000')) {
        props['CompressionFormat'] = 'JPEG2000';
        props['Compression'] = 'JPEG2000';
      }
      continue;
    }

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
  if (tileWidth != null && tileHeight != null) {
    return 'level';
  }

  if (description != null) {
    final descLower = description.toLowerCase();
    if (descLower.contains('label') || descLower.contains('barcode')) {
      return 'label';
    } else if (descLower.contains('macro') || descLower.contains('overview')) {
      return 'macro';
    } else if (descLower.contains('thumbnail') ||
        descLower.contains('thumb') ||
        descLower.contains('->')) {
      return 'thumbnail';
    }
  }

  if (tileWidth == null && tileHeight == null && width > 0 && height > 0) {
    final double aspect = width / height;

    // Macro image: whole slide overview, typically wide aspect ratio (or tall if vertical)
    if (aspect >= 1.8 || aspect <= 0.55 || (aspect >= 1.5 && width >= 1200)) {
      return 'macro';
    }

    // Label image: square or near-square slide label / barcode
    // Aperio scanners (ScanScope CS, CS2, AT2, GT450, etc.) use square or near-square
    // label resolutions (e.g. 400x400, 500x500, 687x687, 1000x1000, etc.)
    if (aspect >= 0.75 && aspect <= 1.33) {
      return 'label';
    }

    // Thumbnail image: downsampled preview of the scanned area
    if (width <= 1024 && height <= 1024) {
      return 'thumbnail';
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

img.Image? _decodeJpeg2000(Uint8List bytes) {
  try {
    final jpx = JpxImage();
    jpx.parse(bytes);
    if (jpx.width <= 0 || jpx.height <= 0 || jpx.tiles.isEmpty) {
      return null;
    }

    if (jpx.tiles.length == 1 &&
        jpx.tiles[0].left == 0 &&
        jpx.tiles[0].top == 0 &&
        jpx.tiles[0].width == jpx.width &&
        jpx.tiles[0].height == jpx.height) {
      return img.Image.fromBytes(
        width: jpx.width,
        height: jpx.height,
        bytes: jpx.tiles[0].items.buffer,
        numChannels: 4,
        order: img.ChannelOrder.rgba,
      );
    }

    final image = img.Image(
      width: jpx.width,
      height: jpx.height,
      numChannels: 4,
    );
    for (final tile in jpx.tiles) {
      if (tile.width <= 0 || tile.height <= 0) continue;
      final tileImg = img.Image.fromBytes(
        width: tile.width,
        height: tile.height,
        bytes: tile.items.buffer,
        numChannels: 4,
        order: img.ChannelOrder.rgba,
      );
      img.compositeImage(image, tileImg, dstX: tile.left, dstY: tile.top);
    }
    return image;
  } catch (_) {
    return null;
  }
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

/// Parses an integer display color from a dynamic value, string (decimal, hex with # or 0x), or int.
int? parseDisplayColor(dynamic value) {
  if (value == null) return null;
  if (value is int) return value;
  final str = value.toString().trim();
  if (str.isEmpty) return null;
  if (str.startsWith('#')) {
    return int.tryParse(str.substring(1), radix: 16);
  }
  if (str.startsWith('0x') || str.startsWith('0X')) {
    return int.tryParse(str.substring(2), radix: 16);
  }
  return int.tryParse(str);
}

/// Applies the DisplayColor color tinting/mapping to the image.
///
/// [displayColor] is interpreted as a 24-bit/32-bit RGB integer (0xRRGGBB).
img.Image _applyDisplayColorToImage(img.Image image, int displayColor) {
  final targetR = (displayColor >> 16) & 0xFF;
  final targetG = (displayColor >> 8) & 0xFF;
  final targetB = displayColor & 0xFF;

  if (targetR == 255 && targetG == 255 && targetB == 255) {
    return image;
  }

  if (image.numChannels < 3) {
    final rgbImage = img.Image(
      width: image.width,
      height: image.height,
      numChannels: 3,
    );
    for (int y = 0; y < image.height; y++) {
      for (int x = 0; x < image.width; x++) {
        final pixel = image.getPixel(x, y);
        final v = pixel.r.toInt();
        final r = (v * targetR) ~/ 255;
        final g = (v * targetG) ~/ 255;
        final b = (v * targetB) ~/ 255;
        rgbImage.setPixelRgb(x, y, r, g, b);
      }
    }
    if (image.iccProfile != null) {
      rgbImage.iccProfile = image.iccProfile;
    }
    return rgbImage;
  }

  for (final pixel in image) {
    pixel.r = (pixel.r * targetR) ~/ 255;
    pixel.g = (pixel.g * targetG) ~/ 255;
    pixel.b = (pixel.b * targetB) ~/ 255;
  }

  return image;
}

img.Image? _applyColorSchemeToImage(
  img.Image image,
  int photometricInterpretation,
  int samplesPerPixel,
  List<int>? colorMap,
  Uint8List? iccProfile, {
  int? displayColor,
  CancellationToken? cancelToken,
}) {
  if (cancelToken?.isCancelled == true) return null;
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
    if (cancelToken?.isCancelled == true) return null;
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

  if (cancelToken?.isCancelled == true) return null;

  if (iccProfile != null && iccProfile.length <= 65519) {
    result.iccProfile = img.IccProfile('', img.IccProfileCompression.none, iccProfile);
  }

  if (cancelToken?.isCancelled == true) return null;

  if (displayColor != null && displayColor != 0) {
    result = _applyDisplayColorToImage(result, displayColor);
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
