import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

/// A cancellation token that allows cancelling asynchronous operations.
class CancellationToken {
  bool _isCancelled = false;
  final List<void Function()> _listeners = [];

  /// Returns `true` if cancellation has been requested.
  bool get isCancelled => _isCancelled;

  /// Registers a callback to be invoked when the token is cancelled.
  /// If the token is already cancelled, the callback is invoked immediately.
  void addListener(void Function() listener) {
    if (_isCancelled) {
      listener();
    } else {
      _listeners.add(listener);
    }
  }

  /// Removes a previously registered callback.
  void removeListener(void Function() listener) {
    _listeners.remove(listener);
  }

  /// Cancels the operation and notifies all registered listeners.
  void cancel() {
    if (_isCancelled) return;
    _isCancelled = true;
    for (final listener in List<void Function()>.from(_listeners)) {
      try {
        listener();
      } catch (_) {}
    }
    _listeners.clear();
  }
}

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

  /// Display color integer value parsed from properties (if available), e.g. 0xRRGGBB.
  final int? displayColor;

  /// Downsample factor relative to the baseline image (level 0).
  final double? downsample;

  /// Creates an [SvsImageInfo] instance.
  SvsImageInfo({
    required this.width,
    required this.height,
    this.tileWidth,
    this.tileHeight,
    this.compression,
    required this.properties,
    this.type,
    this.displayColor,
    this.downsample,
  });

  /// Creates a copy of this [SvsImageInfo] with the given fields replaced.
  SvsImageInfo copyWith({
    int? width,
    int? height,
    int? tileWidth,
    int? tileHeight,
    String? compression,
    Map<String, String>? properties,
    String? type,
    int? displayColor,
    double? downsample,
  }) {
    return SvsImageInfo(
      width: width ?? this.width,
      height: height ?? this.height,
      tileWidth: tileWidth ?? this.tileWidth,
      tileHeight: tileHeight ?? this.tileHeight,
      compression: compression ?? this.compression,
      properties: properties ?? this.properties,
      type: type ?? this.type,
      displayColor: displayColor ?? this.displayColor,
      downsample: downsample ?? this.downsample,
    );
  }

  @override
  String toString() =>
      'SvsImageInfo(type: $type, width: $width, height: $height, tileWidth: $tileWidth, tileHeight: $tileHeight, compression: $compression, displayColor: $displayColor, downsample: $downsample, properties: $properties)';
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

  /// Display color integer value parsed from properties (if available), e.g. 0xRRGGBB.
  final int? displayColor;

  /// Creates an [SvsMetadata] instance.
  SvsMetadata({
    required this.properties,
    required this.width,
    required this.height,
    this.tileWidth,
    this.tileHeight,
    this.compression,
    this.displayColor,
  });

  @override
  String toString() =>
      'SvsMetadata(width: $width, height: $height, tileWidth: $tileWidth, tileHeight: $tileHeight, compression: $compression, displayColor: $displayColor, properties: $properties)';
}

/// Represents an open SVS file handle, TIFF header information, and a pool of file descriptors for parallel I/O.
class SvsFile {
  /// The primary underlying random access file handle.
  final RandomAccessFile raf;

  /// The byte order (endianness) of the TIFF/SVS file.
  final Endian endian;

  /// Byte offset to the first Image File Directory (IFD).
  final int firstIfdOffset;

  /// Whether the file is in BigTIFF format (64-bit offsets, magic 43).
  final bool isBigTiff;

  /// The file path of the SVS file, if opened from a file path.
  final String? filePath;

  /// Maximum number of concurrent file handles in the pool for parallel reads.
  int _maxConcurrency;

  /// Returns the maximum allowed concurrent file handles.
  int get maxConcurrency => _maxConcurrency;

  /// Updates the maximum concurrency limit, closing excess idle handles if reduced.
  set maxConcurrency(int value) {
    _maxConcurrency = value < 1 ? 1 : value;
    _shrinkPoolIfNeeded();
  }

  /// Internal list of all currently open handles (including [raf]).
  final List<RandomAccessFile> _allHandles = [];

  /// Internal queue of idle handles ready for reuse.
  final List<RandomAccessFile> _availableHandles = [];

  /// Queue of pending waiters for any available file handle.
  final List<Completer<RandomAccessFile?>> _waiters = [];

  /// Queue of pending waiters specifically waiting for the primary [raf] handle.
  final List<Completer<void>> _rafWaiters = [];

  /// Set of currently checked-out / busy handles.
  final Set<RandomAccessFile> _busyHandles = {};

  /// Whether this file handle and pool have been closed.
  bool _isClosed = false;

  /// Whether the file is closed.
  bool get isClosed => _isClosed;

  /// Number of currently open handles in the pool.
  int get openHandlesCount => _allHandles.length;

  /// Number of currently idle handles in the pool.
  int get idleHandlesCount => _availableHandles.length;

  /// Number of currently busy handles in the pool.
  int get busyHandlesCount => _busyHandles.length;

  /// Internal synchronization lock to serialize access across IFD/metadata operations.
  Future<void>? _lastOp;

  /// Zone key used to detect re-entrant calls to `synchronized`.
  static const Object _syncZoneKey = #_svsSyncZone;

  /// Effective limit on concurrency if OS file descriptor limit is encountered.
  int _effectiveMaxConcurrency;

  /// Internal cache for tiled levels.
  Object? cachedTiledLevels;

  /// Internal cache for global JPEG tables.
  Uint8List? cachedGlobalJpegTables;

  /// Internal cache for global DisplayColor.
  int? cachedGlobalDisplayColor;

  /// Creates an [SvsFile] instance.
  ///
  /// [maxConcurrency] specifies the maximum number of concurrent file handles used for parallel reads (default: 4).
  /// For slow mechanical HDDs or resource-constrained devices, set to 1 or 2 to avoid seek thrashing.
  /// For fast SSDs/NVMe, higher values (e.g. 4 to 8) maximize read throughput.
  SvsFile(
    this.raf,
    this.endian,
    this.firstIfdOffset, [
    this.isBigTiff = false,
    this.filePath,
    int maxConcurrency = 4,
  ])  : _maxConcurrency = maxConcurrency < 1 ? 1 : maxConcurrency,
        _effectiveMaxConcurrency = maxConcurrency < 1 ? 1 : maxConcurrency {
    _allHandles.add(raf);
    _availableHandles.add(raf);
  }

  /// Acquires an available handle from the pool, opening a new handle if needed and allowed.
  /// If [cancelToken] is cancelled before or while waiting, returns `null` without acquiring a handle.
  Future<RandomAccessFile?> _acquireHandle({CancellationToken? cancelToken}) async {
    if (_isClosed) {
      throw StateError('Cannot read from a closed SvsFile');
    }
    if (cancelToken?.isCancelled == true) {
      return null;
    }

    // 1. If an idle handle is available:
    if (_availableHandles.isNotEmpty) {
      // If synchronized is waiting specifically for primary raf, prefer taking a non-raf handle:
      if (_rafWaiters.isNotEmpty && _availableHandles.length > 1) {
        final nonRafIndex = _availableHandles.indexWhere((h) => h != raf);
        if (nonRafIndex != -1) {
          final handle = _availableHandles.removeAt(nonRafIndex);
          _busyHandles.add(handle);
          return handle;
        }
      }
      final handle = _availableHandles.removeLast();
      _busyHandles.add(handle);
      return handle;
    }

    // 2. If we can allocate a new handle (haven't reached effective limit):
    final effectivePath = filePath ?? (raf.path.isNotEmpty ? raf.path : null);
    if (_allHandles.length < _effectiveMaxConcurrency && effectivePath != null) {
      try {
        final newRaf = await File(effectivePath).open(mode: FileMode.read);
        if (_isClosed) {
          await newRaf.close();
          throw StateError('Cannot read from a closed SvsFile');
        }
        if (cancelToken?.isCancelled == true) {
          await newRaf.close();
          return null;
        }
        _allHandles.add(newRaf);
        _busyHandles.add(newRaf);
        return newRaf;
      } catch (_) {
        // OS file descriptor limit or file access error: fall back gracefully to existing handles
        _effectiveMaxConcurrency = _allHandles.isNotEmpty ? _allHandles.length : 1;
      }
    }

    if (cancelToken?.isCancelled == true) {
      return null;
    }

    // 3. Pool is at capacity or cannot open more handles; wait for one to be released:
    final completer = Completer<RandomAccessFile?>();
    _waiters.add(completer);

    void onCancel() {
      if (!completer.isCompleted) {
        _waiters.remove(completer);
        completer.complete(null);
      }
    }

    cancelToken?.addListener(onCancel);

    try {
      return await completer.future;
    } finally {
      cancelToken?.removeListener(onCancel);
    }
  }

  /// Acquires exclusive access to the primary [raf] handle (used for metadata/IFD scanning).
  Future<void> _acquireSpecificHandle(RandomAccessFile target) async {
    while (_busyHandles.contains(target)) {
      if (_isClosed) {
        throw StateError('Cannot access a closed SvsFile');
      }
      final completer = Completer<void>();
      _rafWaiters.add(completer);
      await completer.future;
    }
    if (_isClosed) {
      throw StateError('Cannot access a closed SvsFile');
    }
    _availableHandles.remove(target);
    _busyHandles.add(target);
  }

  /// Releases a borrowed handle back to the pool or hands it to waiting operations.
  void _releaseHandle(RandomAccessFile handle) {
    _busyHandles.remove(handle);

    if (_isClosed) {
      try {
        handle.close();
      } catch (_) {}
      return;
    }

    // If pool size was reduced and this handle is beyond maxConcurrency (and not primary raf), close it:
    if (_allHandles.length > _maxConcurrency && handle != raf) {
      _allHandles.remove(handle);
      try {
        handle.close();
      } catch (_) {}
      return;
    }

    // If handle == raf and there is a specific waiter for primary raf (i.e. synchronized):
    if (handle == raf && _rafWaiters.isNotEmpty) {
      final waiter = _rafWaiters.removeAt(0);
      if (!waiter.isCompleted) {
        waiter.complete();
        return;
      }
    }

    // If there are general waiters for any handle:
    while (_waiters.isNotEmpty) {
      final waiter = _waiters.removeAt(0);
      if (!waiter.isCompleted) {
        _busyHandles.add(handle);
        waiter.complete(handle);
        return;
      }
    }

    _availableHandles.add(handle);
  }

  /// Closes idle handles if maxConcurrency was decreased.
  void _shrinkPoolIfNeeded() {
    _effectiveMaxConcurrency = _maxConcurrency;
    while (_allHandles.length > _maxConcurrency && _availableHandles.isNotEmpty) {
      final index = _availableHandles.indexWhere((h) => h != raf);
      if (index != -1) {
        final handle = _availableHandles.removeAt(index);
        _allHandles.remove(handle);
        try {
          handle.close();
        } catch (_) {}
      } else {
        break;
      }
    }
  }

  /// Executes [action] sequentially to guarantee concurrency-safe access to metadata and IFDs.
  Future<T> synchronized<T>(Future<T> Function() action) {
    if (_isClosed) {
      throw StateError('Cannot access a closed SvsFile');
    }

    // Re-entrant call from within an active synchronized block on this SvsFile:
    if (Zone.current[_syncZoneKey] == this) {
      return action();
    }

    final prev = _lastOp;
    final completer = Completer<void>();
    _lastOp = completer.future;

    return Future.sync(() async {
      if (prev != null) {
        try {
          await prev;
        } catch (_) {}
      }

      if (_isClosed) {
        throw StateError('Cannot access a closed SvsFile');
      }

      await _acquireSpecificHandle(raf);
      try {
        return await runZoned(
          () => action(),
          zoneValues: {_syncZoneKey: this},
        );
      } finally {
        _releaseHandle(raf);
      }
    }).whenComplete(() {
      completer.complete();
    });
  }

  /// Concurrently sets position to [offset] and reads [count] bytes using an available handle from the pool.
  ///
  /// Multiple [readBytesAt] calls can run in parallel up to [maxConcurrency] without serializing or blocking each other.
  /// If [cancelToken] is provided and cancelled, reading is aborted and an empty [Uint8List] is returned.
  Future<Uint8List> readBytesAt(int offset, int count, {CancellationToken? cancelToken}) async {
    if (_isClosed) throw StateError('Cannot read from a closed SvsFile');
    if (count <= 0 || cancelToken?.isCancelled == true) return Uint8List(0);

    // If inside synchronized on this SvsFile, use the already locked primary handle directly:
    if (Zone.current[_syncZoneKey] == this) {
      if (cancelToken?.isCancelled == true) return Uint8List(0);
      await raf.setPosition(offset);
      return await raf.read(count);
    }

    final handle = await _acquireHandle(cancelToken: cancelToken);
    if (handle == null || cancelToken?.isCancelled == true) {
      if (handle != null) _releaseHandle(handle);
      return Uint8List(0);
    }

    try {
      await handle.setPosition(offset);
      return await handle.read(count);
    } finally {
      _releaseHandle(handle);
    }
  }

  /// Closes all underlying file handles in the pool.
  Future<void> close() async {
    if (_isClosed) return;
    _isClosed = true;

    for (final waiter in _waiters) {
      if (!waiter.isCompleted) {
        waiter.completeError(StateError('SvsFile was closed'));
      }
    }
    _waiters.clear();

    for (final waiter in _rafWaiters) {
      if (!waiter.isCompleted) {
        waiter.completeError(StateError('SvsFile was closed'));
      }
    }
    _rafWaiters.clear();

    final handlesToClose = List<RandomAccessFile>.from(_allHandles);
    _allHandles.clear();
    _availableHandles.clear();
    _busyHandles.clear();

    for (final handle in handlesToClose) {
      try {
        await handle.close();
      } catch (_) {}
    }
  }
}