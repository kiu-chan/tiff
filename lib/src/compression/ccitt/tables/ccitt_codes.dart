/// Shared constants for the CCITT Huffman code tables (see the `tables/`
/// sibling files) — mode codes for 2D (T.6) coding, and the End-Of-Line
/// sentinel shared by the white/black run tables.
library;

/// Sentinel "value" for a decoded End-Of-Line code.
const int ccittEol = -2;

// 2D mode codes (ITU-T T.4 Table 4 / T.6 mode codes).
const int twoDimPass = 0;
const int twoDimHoriz = 1;
const int twoDimVert0 = 2;
const int twoDimVertR1 = 3;
const int twoDimVertL1 = 4;
const int twoDimVertR2 = 5;
const int twoDimVertL2 = 6;
const int twoDimVertR3 = 7;
const int twoDimVertL3 = 8;
