import 'dart:io';
import 'package:flutter/widgets.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

/// Centralized service to manage Flutter RAM image cache limits,
/// disk image cache pruning, and storage cleanup.
/// Prevents cache bloat and memory leaks on Smart TVs during long streaming sessions.
class CacheService {
  CacheService._();

  static bool _configured = false;

  /// Call once at app startup (e.g. in `main()`) to enforce strict RAM bounds
  /// on Flutter's internal image cache.
  static void configureRamImageCache() {
    if (_configured) return;
    _configured = true;
    try {
      // Smart TVs typically have 1GB-2GB RAM.
      // Default Flutter limits (1000 images, 100MB) drain RAM over multi-hour TV use.
      // Cap at 50 decoded images (~25 MB RAM max).
      PaintingBinding.instance.imageCache.maximumSize = 50;
      PaintingBinding.instance.imageCache.maximumSizeBytes = 25 * 1024 * 1024;
      debugPrint('[CacheService] RAM image cache limits configured (50 images / 25MB max)');
    } catch (e) {
      debugPrint('[CacheService] Error setting image cache limits: $e');
    }
  }

  /// Clears Flutter RAM image cache immediately.
  static void clearRamCache() {
    try {
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
      debugPrint('[CacheService] RAM image cache cleared');
    } catch (e) {
      debugPrint('[CacheService] Error clearing RAM cache: $e');
    }
  }

  /// Completely clears disk image cache and temporary directory files.
  /// Returns the total bytes freed.
  static Future<int> clearDiskCache() async {
    int bytesFreed = 0;
    try {
      // 1. Clear cached_network_image disk cache
      await DefaultCacheManager().emptyCache();

      // 2. Clean temporary directory files
      final tempDir = Directory.systemTemp;
      if (await tempDir.exists()) {
        final entities = tempDir.listSync(recursive: true, followLinks: false);
        for (final entity in entities) {
          try {
            if (entity is File) {
              bytesFreed += await entity.length();
              await entity.delete();
            }
          } catch (_) {}
        }
      }

      // 3. Flush RAM image cache
      clearRamCache();
      debugPrint('[CacheService] Disk cache cleared — freed ${bytesFreed ~/ (1024 * 1024)} MB');
    } catch (e) {
      debugPrint('[CacheService] Error clearing disk cache: $e');
    }
    return bytesFreed;
  }

  /// Checks if temporary disk cache exceeds [maxBytes] (default 30 MB)
  /// and automatically prunes old cached files if needed.
  static Future<void> autoPruneDiskCache({int maxBytes = 30 * 1024 * 1024}) async {
    try {
      final tempDir = Directory.systemTemp;
      if (!await tempDir.exists()) return;
      int totalBytes = 0;
      final entities = tempDir.listSync(recursive: true, followLinks: false);
      for (final entity in entities) {
        if (entity is File) {
          totalBytes += await entity.length();
        }
      }
      if (totalBytes > maxBytes) {
        debugPrint('[CacheService] Cache size (${totalBytes ~/ (1024 * 1024)} MB) > limit (${maxBytes ~/ (1024 * 1024)} MB). Auto-pruning...');
        await clearDiskCache();
      }
    } catch (e) {
      debugPrint('[CacheService] Error auto-pruning disk cache: $e');
    }
  }
}
