import '../tiff_exception.dart';
import 'tag_type.dart';

/// A RATIONAL/SRATIONAL value: an exact numerator/denominator pair.
///
/// Kept as a fraction rather than eagerly converted to [double] because
/// TIFF commonly uses rationals for exact ratios (e.g. resolution) where
/// float rounding would be lossy for round-tripping.
class TiffRational {
  final int numerator;
  final int denominator;

  const TiffRational(this.numerator, this.denominator);

  double toDouble() => denominator == 0 ? 0 : numerator / denominator;

  @override
  String toString() => '$numerator/$denominator';
}

/// A fully-resolved value read from a TIFF tag, typed according to its
/// [TiffTagType]. Exactly one of [ints]/[floats]/[rationals]/[text] is set,
/// matching [type].
class TiffTagValue {
  final TiffTagType type;
  final int count;
  final List<int>? ints;
  final List<double>? floats;
  final List<TiffRational>? rationals;
  final String? text;

  const TiffTagValue._({
    required this.type,
    required this.count,
    this.ints,
    this.floats,
    this.rationals,
    this.text,
  });

  factory TiffTagValue.ints(TiffTagType type, List<int> values) =>
      TiffTagValue._(type: type, count: values.length, ints: values);

  factory TiffTagValue.floats(TiffTagType type, List<double> values) =>
      TiffTagValue._(type: type, count: values.length, floats: values);

  factory TiffTagValue.rationals(TiffTagType type, List<TiffRational> values) =>
      TiffTagValue._(type: type, count: values.length, rationals: values);

  factory TiffTagValue.ascii(String value) =>
      TiffTagValue._(type: TiffTagType.tAscii, count: value.length + 1, text: value);

  /// First value as an int. Works for integer, float and rational types.
  int asInt() {
    if (ints != null && ints!.isNotEmpty) return ints!.first;
    if (floats != null && floats!.isNotEmpty) return floats!.first.round();
    if (rationals != null && rationals!.isNotEmpty) return rationals!.first.toDouble().round();
    throw const TiffException('Tag value has no integer representation');
  }

  /// All values as ints. Works for integer, float and rational types.
  List<int> asIntList() {
    if (ints != null) return ints!;
    if (floats != null) return floats!.map((f) => f.round()).toList();
    if (rationals != null) return rationals!.map((r) => r.toDouble().round()).toList();
    throw const TiffException('Tag value has no integer representation');
  }

  /// First value as a double. Works for integer, float and rational types.
  double asDouble() {
    if (floats != null && floats!.isNotEmpty) return floats!.first;
    if (rationals != null && rationals!.isNotEmpty) return rationals!.first.toDouble();
    if (ints != null && ints!.isNotEmpty) return ints!.first.toDouble();
    throw const TiffException('Tag value has no numeric representation');
  }

  /// All values as doubles. Works for integer, float and rational types.
  List<double> asDoubleList() {
    if (floats != null) return floats!;
    if (rationals != null) return rationals!.map((r) => r.toDouble()).toList();
    if (ints != null) return ints!.map((i) => i.toDouble()).toList();
    throw const TiffException('Tag value has no numeric representation');
  }

  String asString() {
    final value = text;
    if (value == null) throw const TiffException('Tag value is not ASCII text');
    return value;
  }
}
