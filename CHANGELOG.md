## 0.0.1-alfa.1
* Initial, read about it in README.md

## 0.0.1-alfa.3
* new function extractSvsImageAsImage, extractSvsImageAsJpeg, extractSvsTileAsImage added
* Export changes
* Example added
* bug fixes

## 0.0.2-alfa.1
* Async upload of the tiles, without mutex


## 0.1.0-beta
* Increased reading speed of the tiles
* Added full BigTIFF support for reading slides > 4 GB
* Added JPEG 2000 decompression support
* Added SubIFD traversal for multi-resolution pyramid levels.
* Added main library export `package:omnigisto_pkg/omnigisto_pkg.dart`
* Added comprehensive test suite for BigTIFF and JPEG 2000 parsing and extraction
* Extra tests on iOs and Android
* Bug fixes

## 0.1.1
* First release
* Fixed SubIFD (tag 330) handling in `readFullSvsMetadata` for consistent pyramid level count with `extractSvsTile`
* Improved associated image detection (`label`, `macro`, `thumbnail`) in `_determineImageType`
* Removed hardcoded resolution check (687x687) for label images to support various Aperio scanner models (AT2, GT450, CS2, etc.)
* Added aspect ratio and keyword-based heuristics for slide labels, macro overviews, and thumbnails

## 0.1.2
* Some packages updated

## 0.1.4
* Added `DisplayColor` support: automatic extraction and parsing of Aperio `DisplayColor` parameter in `SvsMetadata` and `SvsImageInfo`.
* Added pixel tinting and color mapping according to `DisplayColor` in tile and associated image extraction pipelines.
* Added `applyDisplayColor` and optional `displayColor` override parameters to `extractSvsTileAsImage`, `extractSvsImageAsImage`, and `extractSvsImageAsJpeg`.
* Exported `parseDisplayColor` utility function for parsing decimal and hexadecimal color formats.
* Added `downsample` property to `SvsImageInfo` representing resolution pyramid layer downsampling factor in `readFullSvsMetadata`.
* Added file descriptor pooling (`RandomAccessFile`) in `SvsFile` for high-throughput parallel asynchronous tile reading without I/O serialization bottlenecks.
* Added `maxConcurrency` parameter to `openSvsFile` (default: 4) and `SvsFile`, allowing fine-tuned I/O scaling for slow HDDs (1-2) up to fast SSDs/NVMe (4-8).
* Added dynamic concurrency level adjustment via `SvsFile.maxConcurrency` setter with automatic idle handle cleanup and pool shrinking.
* Enhanced `SvsFile.synchronized` with re-entrancy support and exclusive primary handle locking, keeping metadata scans thread-safe without blocking parallel tile reads.
* Added graceful degradation when hitting OS file descriptor limits (`EMFILE`) and safe cleanup of all pooled handles in `SvsFile.close()`.
* Added `CancellationToken` class for cooperative cancellation of asynchronous I/O and image decoding tasks.
* Added `cancelToken` support to `SvsFile` descriptor pool (`_acquireHandle` and `readBytesAt`) with automatic waiter removal and zero descriptor leaks upon cancellation.
* Added `cancelToken` parameter to `extractSvsTile` and `extractSvsTileAsImage` with cancellation checks before heavy operations (I/O, LZW, JPEG 2000 decompressions, ICC and color map processing).

