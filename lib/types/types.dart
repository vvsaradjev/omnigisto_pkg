/// Information about an individual resolution level or associated image in an SVS file.
class SvsImageInfo {
  /// Image width in pixels.
  final int width;

  /// Image height in pixels.
  final int height;

  /// Tile width in pixels, or `null` if the image is not tiled.
  final int? tileWidth;

  /// Tile height in pixels, or `null` if the image is not tiled.
  final int? tileHeight;

  /// Compression format description (if available).
  final String? compression;

  /// Map of properties parsed from ImageDescription.
  final Map<String, String> properties;

  /// Image type (e.g. 'label', 'macro', 'thumbnail', 'level', or 'other_association').
  final String? type;

  /// Creates an [SvsImageInfo] instance.
  SvsImageInfo({
    required this.width,
    required this.height,
    this.tileWidth,
    this.tileHeight,
    this.compression,
    required this.properties,
    this.type,
  });

  @override
  String toString() =>
      'SvsImageInfo(type: $type, width: $width, height: $height, tileWidth: $tileWidth, tileHeight: $tileHeight, compression: $compression, properties: $properties)';
}

/// Full metadata of an SVS file, including all pyramid levels and associated images.
class SvsFullMetadata {
  /// List of pyramid resolution levels sorted from highest resolution (largest) to lowest.
  final List<SvsImageInfo> levels;

  /// Map of associated non-level images (e.g. 'thumbnail', 'label', 'macro').
  final Map<String, SvsImageInfo> associations;

  /// Creates an [SvsFullMetadata] instance.
  SvsFullMetadata({
    required this.levels,
    required this.associations,
  });

  @override
  String toString() => 'SvsFullMetadata(levels: ${levels.length}, associations: ${associations.keys.toList()})';
}

/// Basic metadata of the primary/baseline image in an SVS file.
class SvsMetadata {
  /// Map of properties extracted from ImageDescription (Aperio format).
  final Map<String, String> properties;

  /// Width of the primary image in pixels.
  final int width;

  /// Height of the primary image in pixels.
  final int height;

  /// Tile width in pixels (if tiled).
  final int? tileWidth;

  /// Tile height in pixels (if tiled).
  final int? tileHeight;

  /// Compression format or quality description (if available).
  final String? compression;

  /// Creates an [SvsMetadata] instance.
  SvsMetadata({
    required this.properties,
    required this.width,
    required this.height,
    this.tileWidth,
    this.tileHeight,
    this.compression,
  });

  @override
  String toString() =>
      'SvsMetadata(width: $width, height: $height, tileWidth: $tileWidth, tileHeight: $tileHeight, compression: $compression, properties: $properties)';
}