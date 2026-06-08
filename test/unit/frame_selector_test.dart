import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:narrator/pipelines/pipeline2/frame_selector.dart';

void main() {
  group('FrameSelector', () {
    final selector = FrameSelector();

    // Helper: create a flat greyscale image filled with a constant value.
    Uint8List solidFrame(int width, int height, int value) =>
        Uint8List(width * height)..fillRange(0, width * height, value);

    // Helper: create a checkerboard pattern (high sharpness).
    Uint8List checkerboard(int width, int height) {
      final pixels = Uint8List(width * height);
      for (var y = 0; y < height; y++) {
        for (var x = 0; x < width; x++) {
          pixels[y * width + x] = ((x + y) % 2 == 0) ? 255 : 0;
        }
      }
      return pixels;
    }

    // ── computeSharpness ──────────────────────────────────────────────────

    group('computeSharpness', () {
      test('uniform grey frame has sharpness 0', () {
        final pixels = solidFrame(10, 10, 128);
        expect(selector.computeSharpness(pixels, 10, 10), closeTo(0.0, 0.001));
      });

      test('checkerboard has high sharpness', () {
        final pixels = checkerboard(20, 20);
        expect(selector.computeSharpness(pixels, 20, 20), greaterThan(100.0));
      });

      test('sharpness is higher for checkerboard than solid', () {
        final sharp = selector.computeSharpness(checkerboard(20, 20), 20, 20);
        final blunt = selector.computeSharpness(solidFrame(20, 20, 200), 20, 20);
        expect(sharp, greaterThan(blunt));
      });

      test('throws ArgumentError when pixels.length != width*height', () {
        final pixels = Uint8List(50); // wrong size
        expect(
          () => selector.computeSharpness(pixels, 10, 10),
          throwsArgumentError,
        );
      });

      test('returns 0 for images smaller than 3x3', () {
        final pixels = Uint8List(4)..fillRange(0, 4, 100);
        expect(selector.computeSharpness(pixels, 2, 2), closeTo(0.0, 0.001));
      });

      test('sharpness is non-negative', () {
        final pixels = checkerboard(10, 10);
        expect(selector.computeSharpness(pixels, 10, 10), greaterThanOrEqualTo(0.0));
      });
    });

    // ── selectSharpestIndex ───────────────────────────────────────────────

    group('selectSharpestIndex', () {
      test('returns 0 for empty list', () {
        expect(selector.selectSharpestIndex([]), equals(0));
      });

      test('returns 0 for single frame', () {
        final frame = (
          pixels: solidFrame(10, 10, 128),
          width:  10,
          height: 10,
        );
        expect(selector.selectSharpestIndex([frame]), equals(0));
      });

      test('selects sharpest frame from list', () {
        final blurry = (
          pixels: solidFrame(20, 20, 100),
          width:  20,
          height: 20,
        );
        final sharp = (
          pixels: checkerboard(20, 20),
          width:  20,
          height: 20,
        );
        // sharp is at index 1
        expect(selector.selectSharpestIndex([blurry, sharp]), equals(1));
      });

      test('selects correct index when sharp frame is first', () {
        final sharp = (
          pixels: checkerboard(20, 20),
          width:  20,
          height: 20,
        );
        final blurry = (
          pixels: solidFrame(20, 20, 100),
          width:  20,
          height: 20,
        );
        expect(selector.selectSharpestIndex([sharp, blurry]), equals(0));
      });

      test('selects correct index from 5 frames', () {
        final frames = [
          (pixels: solidFrame(10, 10, 50),  width: 10, height: 10),
          (pixels: solidFrame(10, 10, 100), width: 10, height: 10),
          (pixels: checkerboard(10, 10),    width: 10, height: 10), // sharpest
          (pixels: solidFrame(10, 10, 200), width: 10, height: 10),
          (pixels: solidFrame(10, 10, 150), width: 10, height: 10),
        ];
        expect(selector.selectSharpestIndex(frames), equals(2));
      });
    });

    // ── pHash ─────────────────────────────────────────────────────────────

    group('pHash', () {
      test('same image produces same hash', () {
        final pixels = checkerboard(16, 16);
        final h1 = selector.pHash(pixels, 16, 16);
        final h2 = selector.pHash(pixels, 16, 16);
        expect(h1, equals(h2));
      });

      test('different images produce different hashes', () {
        // Left half black, right half white — mean=127, right bits set
        final p1 = Uint8List(16 * 16);
        for (var y = 0; y < 16; y++) {
          for (var x = 0; x < 16; x++) {
            p1[y * 16 + x] = x >= 8 ? 255 : 0;
          }
        }
        final p2 = solidFrame(16, 16, 0); // all black
        expect(selector.pHash(p1, 16, 16),
            isNot(equals(selector.pHash(p2, 16, 16))));
      });

      test('hash is a non-negative integer', () {
        final pixels = checkerboard(16, 16);
        expect(selector.pHash(pixels, 16, 16), greaterThanOrEqualTo(0));
      });
    });

    // ── hammingDistance ───────────────────────────────────────────────────

    group('hammingDistance', () {
      test('identical hashes have distance 0', () {
        expect(FrameSelector.hammingDistance(0xDEADBEEF, 0xDEADBEEF), equals(0));
      });

      test('all-zeros vs all-ones has distance 32 (for 32-bit)', () {
        expect(FrameSelector.hammingDistance(0x00000000, 0xFFFFFFFF), equals(32));
      });

      test('single bit difference has distance 1', () {
        expect(FrameSelector.hammingDistance(8, 9), equals(1)); // 0b1000 vs 0b1001
      });

      test('distance is symmetric', () {
        expect(FrameSelector.hammingDistance(0xABCD, 0x1234),
            equals(FrameSelector.hammingDistance(0x1234, 0xABCD)));
      });
    });

    // ── areDuplicates ─────────────────────────────────────────────────────

    group('areDuplicates', () {
      test('identical hashes are duplicates', () {
        expect(FrameSelector.areDuplicates(0x1234, 0x1234), isTrue);
      });

      test('very different hashes are not duplicates', () {
        expect(FrameSelector.areDuplicates(0x00000000, 0xFFFFFFFF), isFalse);
      });

      test('hashes within threshold are duplicates', () {
        // Hamming distance 1 — within default threshold of 10
        expect(FrameSelector.areDuplicates(8, 9), isTrue); // 0b1000 vs 0b1001
      });

      test('custom threshold is respected', () {
        // distance = 1, threshold = 1 → NOT duplicate (< means dup)
        expect(FrameSelector.areDuplicates(8, 9, threshold: 1), isFalse);
      });
    });
  });
}
