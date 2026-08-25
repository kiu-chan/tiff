import 'dart:typed_data';

import '../tag_type.dart';

/// One raw entry inside an IFD, before its value has been resolved.
///
/// The value/offset field is kept as raw bytes because whether it holds an
/// inline value or a pointer elsewhere in the file depends on [type] and
/// [count], which is decided during resolution (see `TiffIfdReader.resolveValue`).
class TiffIfdEntry {
  final int tagId;

  /// Null when [rawTypeCode] does not match a known [TiffTagType].
  final TiffTagType? type;
  final int rawTypeCode;
  final int count;

  /// The raw 4-byte (Classic) or 8-byte (BigTIFF) value/offset field.
  final Uint8List valueField;

  const TiffIfdEntry({
    required this.tagId,
    required this.type,
    required this.rawTypeCode,
    required this.count,
    required this.valueField,
  });
}
