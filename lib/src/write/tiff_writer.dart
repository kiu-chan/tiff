import 'dart:typed_data';

import '../core/tag_type.dart';
import '../tags/tag_id.dart';
import '../tiff_exception.dart';
import 'bigtiff_promotion.dart';
import 'ifd_field.dart';
import 'strip_writer.dart';
import 'tile_writer.dart';
import 'tiff_image_spec.dart';

/// Assembles one or more [TiffImageSpec]s into TIFF/BigTIFF bytes.
///
/// Layout happens in phases, mirroring how the format is actually read:
///
/// 1. Compress every page's pixel data. This doesn't depend on Classic vs
///    BigTIFF, so it happens first and its total size decides that choice.
/// 2. Lay out every page's IFD plus its tags' overflow areas (any tag value
///    too big to fit inline), back to back. A tag's *size* only depends on
///    its type and count, never its value, so this can happen before the
///    StripOffsets/TileOffsets tag's real values (which depend on where
///    pixel data ends up) are known — they're carried as a zero placeholder
///    of the right length until step 4.
/// 3. Now that IFD space is accounted for, place every page's compressed
///    chunks right after it, back to back, recording each one's offset.
/// 4. Serialize: header, then each page's IFD (patching the real
///    Strip/TileOffsets values in as they're written), then all pixel data.
class TiffWriter {
  const TiffWriter._();

  static Uint8List write({
    required List<TiffImageSpec> pages,
    bool? forceBigTiff,
    Endian endian = Endian.little,
    void Function(int pageIndex, int pageCount, int chunkIndex, int chunkCount)?
    onChunkEncoded,
  }) {
    if (pages.isEmpty) {
      throw const TiffException('Cannot write a TIFF file with no pages');
    }

    final pageChunks = <List<Uint8List>>[];
    for (var p = 0; p < pages.length; p++) {
      final spec = pages[p];
      void onChunk(int chunkIndex, int chunkCount) =>
          onChunkEncoded?.call(p, pages.length, chunkIndex, chunkCount);
      pageChunks.add(
        spec.isTiled
            ? TileWriter.buildChunks(spec, endian, onChunkEncoded: onChunk)
            : StripWriter.buildChunks(spec, endian, onChunkEncoded: onChunk),
      );
    }

    var totalPixelDataBytes = 0;
    for (final chunks in pageChunks) {
      for (final chunk in chunks) {
        totalPixelDataBytes += chunk.length;
      }
    }

    final isBigTiff = BigTiffPromotion.shouldUseBigTiff(
      totalPixelDataBytes: totalPixelDataBytes,
      forceBigTiff: forceBigTiff,
    );
    final offsetType = isBigTiff ? TiffTagType.tLong8 : TiffTagType.tLong;

    final entrySize = isBigTiff ? 20 : 12;
    final offsetFieldSize = isBigTiff ? 8 : 4;
    final countFieldSize = isBigTiff ? 8 : 2;
    final headerSize = isBigTiff ? 16 : 8;

    final pageFields = <List<IfdField>>[];
    final pageIfdStarts = <int>[];
    final pageFieldOverflowOffsets = <List<int?>>[];

    var cursor = headerSize;
    for (var p = 0; p < pages.length; p++) {
      final fields = _buildFields(
        spec: pages[p],
        chunks: pageChunks[p],
        offsetType: offsetType,
      )..sort((a, b) => a.tagId.compareTo(b.tagId));

      final ifdStart = cursor;
      var overflowCursor =
          ifdStart +
          countFieldSize +
          fields.length * entrySize +
          offsetFieldSize;
      final overflowOffsets = List<int?>.filled(fields.length, null);

      for (var i = 0; i < fields.length; i++) {
        final size = fields[i].values.length * fields[i].type.byteSize;
        if (size > offsetFieldSize) {
          overflowOffsets[i] = overflowCursor;
          overflowCursor += size;
          if (overflowCursor.isOdd) overflowCursor++;
        }
      }

      pageFields.add(fields);
      pageIfdStarts.add(ifdStart);
      pageFieldOverflowOffsets.add(overflowOffsets);
      cursor = overflowCursor;
    }

    var dataCursor = cursor;
    final pageChunkOffsets = <List<int>>[];
    for (final chunks in pageChunks) {
      final offsets = <int>[];
      for (final chunk in chunks) {
        offsets.add(dataCursor);
        dataCursor += chunk.length;
      }
      pageChunkOffsets.add(offsets);
    }

    if (!isBigTiff && dataCursor > BigTiffPromotion.classicOffsetLimit) {
      throw const TiffException(
        'Total file size exceeds the 4 GiB Classic TIFF limit; pass bigTiff: true '
        '(or leave it unset to auto-promote)',
      );
    }

    final out = Uint8List(dataCursor);
    final data = ByteData.sublistView(out);
    _writeHeader(
      out,
      data,
      isBigTiff: isBigTiff,
      endian: endian,
      firstIfdOffset: pageIfdStarts.first,
    );

    for (var p = 0; p < pages.length; p++) {
      final offsetTagId = pages[p].isTiled
          ? TiffTagId.tileOffsets
          : TiffTagId.stripOffsets;
      final fields = [
        for (final f in pageFields[p])
          f.tagId == offsetTagId
              ? IfdField(f.tagId, f.type, pageChunkOffsets[p])
              : f,
      ];
      final nextIfdOffset = p < pages.length - 1 ? pageIfdStarts[p + 1] : 0;

      _writeIfd(
        out,
        data,
        ifdStart: pageIfdStarts[p],
        fields: fields,
        overflowOffsets: pageFieldOverflowOffsets[p],
        nextIfdOffset: nextIfdOffset,
        isBigTiff: isBigTiff,
        endian: endian,
      );

      for (var c = 0; c < pageChunks[p].length; c++) {
        out.setRange(
          pageChunkOffsets[p][c],
          pageChunkOffsets[p][c] + pageChunks[p][c].length,
          pageChunks[p][c],
        );
      }
    }

    return out;
  }

  static void _writeHeader(
    Uint8List out,
    ByteData data, {
    required bool isBigTiff,
    required Endian endian,
    required int firstIfdOffset,
  }) {
    if (endian == Endian.little) {
      out[0] = 0x49;
      out[1] = 0x49;
    } else {
      out[0] = 0x4D;
      out[1] = 0x4D;
    }
    if (!isBigTiff) {
      data.setUint16(2, 42, endian);
      data.setUint32(4, firstIfdOffset, endian);
    } else {
      data.setUint16(2, 43, endian);
      data.setUint16(4, 8, endian);
      data.setUint16(6, 0, endian);
      data.setUint64(8, firstIfdOffset, endian);
    }
  }

  static void _writeIfd(
    Uint8List out,
    ByteData data, {
    required int ifdStart,
    required List<IfdField> fields,
    required List<int?> overflowOffsets,
    required int nextIfdOffset,
    required bool isBigTiff,
    required Endian endian,
  }) {
    final entrySize = isBigTiff ? 20 : 12;

    var cursor = ifdStart;
    if (!isBigTiff) {
      data.setUint16(cursor, fields.length, endian);
      cursor += 2;
    } else {
      data.setUint64(cursor, fields.length, endian);
      cursor += 8;
    }

    for (var i = 0; i < fields.length; i++) {
      final field = fields[i];
      final entryOffset = cursor + i * entrySize;
      data.setUint16(entryOffset, field.tagId, endian);
      data.setUint16(entryOffset + 2, field.type.code, endian);
      if (!isBigTiff) {
        data.setUint32(entryOffset + 4, field.values.length, endian);
      } else {
        data.setUint64(entryOffset + 4, field.values.length, endian);
      }

      final valueFieldOffset = entryOffset + (isBigTiff ? 12 : 8);
      final valueBytes = _encodeFieldValues(field, endian);
      final overflowOffset = overflowOffsets[i];
      if (overflowOffset == null) {
        out.setRange(
          valueFieldOffset,
          valueFieldOffset + valueBytes.length,
          valueBytes,
        );
      } else {
        if (!isBigTiff) {
          data.setUint32(valueFieldOffset, overflowOffset, endian);
        } else {
          data.setUint64(valueFieldOffset, overflowOffset, endian);
        }
        out.setRange(
          overflowOffset,
          overflowOffset + valueBytes.length,
          valueBytes,
        );
      }
    }

    final nextIfdOffsetPos = cursor + fields.length * entrySize;
    if (!isBigTiff) {
      data.setUint32(nextIfdOffsetPos, nextIfdOffset, endian);
    } else {
      data.setUint64(nextIfdOffsetPos, nextIfdOffset, endian);
    }
  }

  static List<IfdField> _buildFields({
    required TiffImageSpec spec,
    required List<Uint8List> chunks,
    required TiffTagType offsetType,
  }) {
    final fields = <IfdField>[
      IfdField(TiffTagId.imageWidth, TiffTagType.tLong, [spec.width]),
      IfdField(TiffTagId.imageLength, TiffTagType.tLong, [spec.height]),
      IfdField(
        TiffTagId.bitsPerSample,
        TiffTagType.tShort,
        List.filled(spec.samplesPerPixel, spec.bitsPerSample),
      ),
      IfdField(TiffTagId.compression, TiffTagType.tShort, [spec.compression]),
      IfdField(TiffTagId.photometricInterpretation, TiffTagType.tShort, [
        spec.photometric.code,
      ]),
      IfdField(TiffTagId.samplesPerPixel, TiffTagType.tShort, [
        spec.samplesPerPixel,
      ]),
      IfdField(TiffTagId.planarConfiguration, TiffTagType.tShort, [1]),
    ];
    if (spec.predictor != 1) {
      fields.add(
        IfdField(TiffTagId.predictor, TiffTagType.tShort, [spec.predictor]),
      );
    }
    if (spec.colorMap != null) {
      fields.add(
        IfdField(TiffTagId.colorMap, TiffTagType.tShort, spec.colorMap!),
      );
    }
    fields.addAll(
      spec.isTiled
          ? TileWriter.buildFields(
              spec: spec,
              chunks: chunks,
              offsetType: offsetType,
            )
          : StripWriter.buildFields(
              spec: spec,
              chunks: chunks,
              offsetType: offsetType,
            ),
    );
    return fields;
  }

  static Uint8List _encodeFieldValues(IfdField field, Endian endian) {
    final bytes = Uint8List(field.values.length * field.type.byteSize);
    final bd = ByteData.sublistView(bytes);
    for (var i = 0; i < field.values.length; i++) {
      final off = i * field.type.byteSize;
      if (field.type == TiffTagType.tShort) {
        bd.setUint16(off, field.values[i], endian);
      } else if (field.type == TiffTagType.tLong) {
        bd.setUint32(off, field.values[i], endian);
      } else if (field.type == TiffTagType.tLong8) {
        bd.setUint64(off, field.values[i], endian);
      } else {
        throw TiffException(
          'Writing tag type ${field.type} is not supported yet',
        );
      }
    }
    return bytes;
  }
}
