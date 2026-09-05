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

