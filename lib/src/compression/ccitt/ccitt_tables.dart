/// ITU-T T.4/T.6 (CCITT Group 3/4 fax) Huffman code tables.
///
/// Each table entry is `[bitLength, value]`, indexed by the leading bits of
/// the input stream (MSB-first) truncated to the table's addressing width —
/// this is a fully expanded lookup (one slot per possible bit pattern of
/// that width, with short codes repeated across every slot they prefix-match)
/// so decoding a code is a single array index, no bit-by-bit tree walk.
/// `bitLength == -1` marks a slot that isn't a valid complete code at that
/// width. Ported from the ITU-T T.4 Table 2/3 code assignments (the same
/// tables appear, unexpanded, in the standard's Recommendation text and, in
/// this exact expanded form, in longstanding open-source fax decoders).
///
/// This file is just a facade — the tables themselves (large, but pure
/// data) live in `tables/`, split by which run/mode they cover so no single
/// file grows unwieldy.
library;

export 'tables/black_tables.dart';
export 'tables/ccitt_codes.dart';
export 'tables/two_dim_table.dart';
export 'tables/white_tables.dart';
