import '../core/tag_type.dart';

/// One tag to write into an IFD.
///
/// [values] holds a placeholder (all zero) when the field is a
/// StripOffsets/TileOffsets tag whose real values aren't known until pixel
/// data placement is decided — see `TiffWriter`, which patches those in
/// after layout. The placeholder still has the correct *length*, which is
/// all that matters for computing inline-vs-overflow placement.
class IfdField {
  final int tagId;
  final TiffTagType type;
  final List<int> values;

  const IfdField(this.tagId, this.type, this.values);
}
