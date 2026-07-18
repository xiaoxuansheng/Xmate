/// LRU page-image cache for PDF preview.
///
/// Holds up to [maxSize] rendered [ui.Image] objects, keyed by 0-based page
/// index.  When the cache is full the least recently accessed page is evicted
/// and its image disposed.
library;

import 'dart:ui' as ui;

class PdfPageCache {
  final int maxSize;

  final Map<int, ui.Image> _images = {};
  final List<int> _order = []; // MRU at end

  PdfPageCache({this.maxSize = 20});

  /// Return the cached image for [page], or null.  Updates access order.
  ui.Image? get(int page) {
    final img = _images[page];
    if (img != null) {
      _order.remove(page);
      _order.add(page);
    }
    return img;
  }

  /// Store [image] for [page].  Evicts LRU entry if the cache exceeds [maxSize].
  void put(int page, ui.Image image) {
    _images[page]?.dispose();
    _images[page] = image;
    _order.remove(page);
    _order.add(page);
    while (_images.length > maxSize) {
      final evict = _order.removeAt(0);
      _images[evict]?.dispose();
      _images.remove(evict);
    }
  }

  /// Remove a specific page from cache.
  void remove(int page) {
    _images.remove(page)?.dispose();
    _order.remove(page);
  }

  /// Dispose all cached images and clear the cache.
  void clear() {
    for (final img in _images.values) {
      img.dispose();
    }
    _images.clear();
    _order.clear();
  }

  /// Number of entries currently cached.
  int get length => _images.length;

  /// Whether [page] is in the cache.
  bool contains(int page) => _images.containsKey(page);
}
