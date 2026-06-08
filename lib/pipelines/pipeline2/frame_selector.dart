import 'dart:math' as math;
import 'dart:typed_data';

/// Selects the sharpest camera frame from a buffer using Laplacian variance.
///
/// Higher Laplacian variance = more edge detail = sharper frame.
class FrameSelector {
  /// Compute Laplacian variance for a greyscale image.
  ///
  /// [pixels] — raw greyscale bytes (1 channel), row-major.
  /// [width]  — image width in pixels.
  /// [height] — image height in pixels.
  ///
  /// Returns the variance of the Laplacian, a sharpness score.
  /// Higher is sharper.
  double computeSharpness(Uint8List pixels, int width, int height) {
    if (pixels.length != width * height) {
      throw ArgumentError(
          'pixels.length (${pixels.length}) != width*height (${width * height})');
    }
    if (width < 3 || height < 3) return 0.0;

    final laplacian = <double>[];

    // 3×3 Laplacian kernel: [0,1,0],[1,-4,1],[0,1,0]
    for (var y = 1; y < height - 1; y++) {
      for (var x = 1; x < width - 1; x++) {
        final center = pixels[y * width + x].toDouble();
        final top    = pixels[(y - 1) * width + x].toDouble();
        final bottom = pixels[(y + 1) * width + x].toDouble();
        final left   = pixels[y * width + (x - 1)].toDouble();
        final right  = pixels[y * width + (x + 1)].toDouble();

        final response = top + bottom + left + right - 4 * center;
        laplacian.add(response);
      }
    }

    return _variance(laplacian);
  }

  double _variance(List<double> values) {
    if (values.isEmpty) return 0.0;
    final mean = values.reduce((a, b) => a + b) / values.length;
    final sumSq = values.fold<double>(
        0.0, (acc, v) => acc + math.pow(v - mean, 2).toDouble());
    return sumSq / values.length;
  }

  /// Pick the index of the sharpest frame from a list of greyscale frames.
  ///
  /// [frames] — list of (pixels, width, height) tuples.
  /// Returns index of the sharpest frame, or 0 if list is empty.
  int selectSharpestIndex(
      List<({Uint8List pixels, int width, int height})> frames) {
    if (frames.isEmpty) return 0;
    var bestIdx   = 0;
    var bestScore = -1.0;
    for (var i = 0; i < frames.length; i++) {
      final f     = frames[i];
      final score = computeSharpness(f.pixels, f.width, f.height);
      if (score > bestScore) {
        bestScore = score;
        bestIdx   = i;
      }
    }
    return bestIdx;
  }

  /// Compute a perceptual hash (8×8 average hash) for duplicate detection.
  ///
  /// Returns a 64-bit integer. Hamming distance < 10 = likely duplicate.
  int pHash(Uint8List pixels, int width, int height) {
    // Downsample to 8×8
    final small = _resize8x8(pixels, width, height);
    final mean  = small.reduce((a, b) => a + b) / 64.0;

    var hash = 0;
    for (var i = 0; i < 64; i++) {
      if (small[i] > mean) hash |= (1 << i);
    }
    return hash;
  }

  List<double> _resize8x8(Uint8List pixels, int width, int height) {
    final out = List<double>.filled(64, 0.0);
    for (var ry = 0; ry < 8; ry++) {
      for (var rx = 0; rx < 8; rx++) {
        final srcX = (rx * width  / 8).floor();
        final srcY = (ry * height / 8).floor();
        out[ry * 8 + rx] = pixels[srcY * width + srcX].toDouble();
      }
    }
    return out;
  }

  /// Hamming distance between two pHash values.
  static int hammingDistance(int hashA, int hashB) {
    var diff = hashA ^ hashB;
    var dist = 0;
    while (diff != 0) {
      dist += diff & 1;
      diff >>= 1;
    }
    return dist;
  }

  /// Returns true if two frames are likely duplicates (hamming < threshold).
  static bool areDuplicates(int hashA, int hashB, {int threshold = 10}) =>
      hammingDistance(hashA, hashB) < threshold;
}
