import 'dart:typed_data';

import '../../tiff_exception.dart';
import 'ccitt_tables.dart';

const int _ccittEof = -1;

/// Modified Huffman / Modified READ (ITU-T T.4/T.6) bilevel bitmap decoder.
///
/// A faithful port of the well-known XPDF/pdf.js `CCITTFaxDecoder` state
/// machine (itself derived directly from the ITU-T T.4/T.6 recommendations),
/// adapted for TIFF: it always uses the direct-lookup ("whole codeword fits
/// in one table index") decode path — TIFF strips/tiles have no PDF-style
/// end-of-block/RTC marker, so that machinery is dropped — and it emits
/// **black pixels as bit 1, white as bit 0** to match TIFF's convention of
/// PhotometricInterpretation 0 (WhiteIsZero) being the default for fax data
/// (the opposite default from PDF's `CCITTFaxDecode` filter, which has no
/// bearing on TIFF).
///
/// [k] selects the coding scheme, matching the T4Options/T6Options meaning:
/// `k < 0` for pure 2D (Group 4 / T.6, compression 4), `k == 0` for pure 1D
/// (Modified Huffman, compression 2), `k > 0` for mixed 1D/2D (Group 3 2D,
/// compression 3 with T4Options bit 0 set).
class CcittFaxDecoder {
  final Uint8List _data;
  int _pos = 0;

  final int columns;
  final int encoding;
  final bool byteAlign;

  final List<int> codingLine;
  final List<int> refLine;
  int codingPos = 0;

  bool nextLine2D;
  int inputBits = 0;
  int inputBuf = 0;
  int outputBits = 0;
  bool eof = false;
  bool err = false;

  CcittFaxDecoder(
    this._data, {
    required this.columns,
    required this.encoding,
    this.byteAlign = false,
  }) : codingLine = List<int>.filled(columns + 1, 0),
       refLine = List<int>.filled(columns + 2, 0),
       nextLine2D = encoding < 0 {
    codingLine[0] = columns;

    var code1 = _lookBits(12);
    while (code1 == 0) {
      _eatBits(1);
      code1 = _lookBits(12);
    }
    if (code1 == 1) {
      _eatBits(12);
    }
    if (encoding > 0) {
      nextLine2D = _lookBits(1) == 0;
      _eatBits(1);
    }
  }

  int _next() => _pos < _data.length ? _data[_pos++] : -1;

  /// Decodes exactly [rows] scanlines of [columns] pixels, each padded to a
  /// byte boundary (matching TIFF's per-row byte alignment), returning
  /// `ceil(columns / 8) * rows` bytes with 1 bits for black, 0 for white.
  Uint8List decodeRows(int rows) {
    final bytesPerRow = (columns + 7) >> 3;
    final out = Uint8List(bytesPerRow * rows);
    var outPos = 0;
    for (var r = 0; r < rows; r++) {
      for (var b = 0; b < bytesPerRow; b++) {
        final c = _readNextByte();
        if (c < 0) {
          throw TiffException(
            'CCITT stream ended early: expected $rows rows of $columns pixels, ran out during row $r',
          );
        }
        out[outPos++] = c;
      }
    }
    return out;
  }

  int _readNextByte() {
    if (outputBits == 0) {
      // Only refuses to *start* a new row once genuinely out of data — never
      // aborts a row already in progress. TIFF strips/tiles have no EOFB/RTC
      // trailer, so the lookahead below routinely hits end-of-stream right
      // after decoding the final row's own pixels but before that row's
      // last output byte(s) have been emitted; checking `eof` unconditionally
      // here (as upstream fax decoders designed for PDF's EOFB-terminated
      // streams do) would truncate that row.
      if (eof) return -1;
      err = false;

      if (nextLine2D) {
        _decode2DLine();
      } else {
        _decode1DLine();
      }

      if (byteAlign) {
        inputBits &= ~7;
      }

      var code1 = _lookBits(12);
      while (code1 == 0) {
        _eatBits(1);
        code1 = _lookBits(12);
      }
      if (code1 == 1) {
        _eatBits(12);
      } else if (code1 == _ccittEof) {
        eof = true;
      }

      if (!eof && encoding > 0) {
        nextLine2D = _lookBits(1) == 0;
        _eatBits(1);
      }

      if (codingLine[0] > 0) {
        codingPos = 0;
        outputBits = codingLine[0];
      } else {
        codingPos = 1;
        outputBits = codingLine[1];
      }
    }

    int c;
    if (outputBits >= 8) {
      c = (codingPos & 1) != 0 ? 0xff : 0x00;
      outputBits -= 8;
      if (outputBits == 0 && codingLine[codingPos] < columns) {
        codingPos++;
        outputBits = codingLine[codingPos] - codingLine[codingPos - 1];
      }
    } else {
      var bits = 8;
      c = 0;
      do {
        if (outputBits > bits) {
          c <<= bits;
          if ((codingPos & 1) != 0) {
            c |= (0xff >> (8 - bits));
          }
          outputBits -= bits;
          bits = 0;
        } else {
          c <<= outputBits;
          if ((codingPos & 1) != 0) {
            c |= (0xff >> (8 - outputBits));
          }
          bits -= outputBits;
          outputBits = 0;
          if (codingLine[codingPos] < columns) {
            codingPos++;
            outputBits = codingLine[codingPos] - codingLine[codingPos - 1];
          } else if (bits > 0) {
            c <<= bits;
            bits = 0;
          }
        }
      } while (bits > 0);
    }
    return c & 0xff;
  }

  void _decode1DLine() {
    codingLine[0] = 0;
    codingPos = 0;
    var blackPixels = 0;
    while (codingLine[codingPos] < columns) {
      var runLength = 0;
      int code3;
      if (blackPixels != 0) {
        do {
          code3 = _getBlackCode();
          runLength += code3;
        } while (code3 >= 64);
      } else {
        do {
          code3 = _getWhiteCode();
          runLength += code3;
        } while (code3 >= 64);
      }
      _addPixels(codingLine[codingPos] + runLength, blackPixels);
      blackPixels ^= 1;
    }
  }

  void _decode2DLine() {
    var i = 0;
    while (codingLine[i] < columns) {
      refLine[i] = codingLine[i];
      i++;
    }
    refLine[i++] = columns;
    if (i < refLine.length) refLine[i] = columns;

    codingLine[0] = 0;
    codingPos = 0;
    var refPos = 0;
    var blackPixels = 0;

    while (codingLine[codingPos] < columns) {
      final mode = _getTwoDimCode();
      switch (mode) {
        case twoDimPass:
          _addPixels(refLine[refPos + 1], blackPixels);
          if (refLine[refPos + 1] < columns) {
            refPos += 2;
          }
          break;
        case twoDimHoriz:
          var code1 = 0, code2 = 0;
          int code3;
          if (blackPixels != 0) {
            do {
              code3 = _getBlackCode();
              code1 += code3;
            } while (code3 >= 64);
            do {
              code3 = _getWhiteCode();
              code2 += code3;
            } while (code3 >= 64);
          } else {
            do {
              code3 = _getWhiteCode();
              code1 += code3;
            } while (code3 >= 64);
            do {
              code3 = _getBlackCode();
              code2 += code3;
            } while (code3 >= 64);
          }
          _addPixels(codingLine[codingPos] + code1, blackPixels);
          if (codingLine[codingPos] < columns) {
            _addPixels(codingLine[codingPos] + code2, blackPixels ^ 1);
          }
          while (refLine[refPos] <= codingLine[codingPos] &&
              refLine[refPos] < columns) {
            refPos += 2;
          }
          break;
        case twoDimVertR3:
          _addPixels(refLine[refPos] + 3, blackPixels);
          blackPixels ^= 1;
          if (codingLine[codingPos] < columns) {
            refPos++;
            while (refLine[refPos] <= codingLine[codingPos] &&
                refLine[refPos] < columns) {
              refPos += 2;
            }
          }
          break;
        case twoDimVertR2:
          _addPixels(refLine[refPos] + 2, blackPixels);
          blackPixels ^= 1;
          if (codingLine[codingPos] < columns) {
            refPos++;
            while (refLine[refPos] <= codingLine[codingPos] &&
                refLine[refPos] < columns) {
              refPos += 2;
            }
          }
          break;
        case twoDimVertR1:
          _addPixels(refLine[refPos] + 1, blackPixels);
          blackPixels ^= 1;
          if (codingLine[codingPos] < columns) {
            refPos++;
            while (refLine[refPos] <= codingLine[codingPos] &&
                refLine[refPos] < columns) {
              refPos += 2;
            }
          }
          break;
        case twoDimVert0:
          _addPixels(refLine[refPos], blackPixels);
          blackPixels ^= 1;
          if (codingLine[codingPos] < columns) {
            refPos++;
            while (refLine[refPos] <= codingLine[codingPos] &&
                refLine[refPos] < columns) {
              refPos += 2;
            }
          }
          break;
        case twoDimVertL3:
          _addPixelsNeg(refLine[refPos] - 3, blackPixels);
          blackPixels ^= 1;
          if (codingLine[codingPos] < columns) {
            refPos = refPos > 0 ? refPos - 1 : refPos + 1;
            while (refLine[refPos] <= codingLine[codingPos] &&
                refLine[refPos] < columns) {
              refPos += 2;
            }
          }
          break;
        case twoDimVertL2:
          _addPixelsNeg(refLine[refPos] - 2, blackPixels);
          blackPixels ^= 1;
          if (codingLine[codingPos] < columns) {
            refPos = refPos > 0 ? refPos - 1 : refPos + 1;
            while (refLine[refPos] <= codingLine[codingPos] &&
                refLine[refPos] < columns) {
              refPos += 2;
            }
          }
          break;
        case twoDimVertL1:
          _addPixelsNeg(refLine[refPos] - 1, blackPixels);
          blackPixels ^= 1;
          if (codingLine[codingPos] < columns) {
            refPos = refPos > 0 ? refPos - 1 : refPos + 1;
            while (refLine[refPos] <= codingLine[codingPos] &&
                refLine[refPos] < columns) {
              refPos += 2;
            }
          }
          break;
        case _ccittEof:
          _addPixels(columns, 0);
          eof = true;
          break;
        default:
          _addPixels(columns, 0);
          err = true;
          throw const TiffException('Invalid CCITT 2D mode code');
      }
    }
  }

  void _addPixels(int a1, int blackPixels) {
    if (a1 > codingLine[codingPos]) {
      if (a1 > columns) {
        err = true;
        a1 = columns;
      }
      if (((codingPos & 1) ^ blackPixels) != 0) {
        codingPos++;
      }
      codingLine[codingPos] = a1;
    }
  }

  void _addPixelsNeg(int a1, int blackPixels) {
    if (a1 > codingLine[codingPos]) {
      if (a1 > columns) {
        err = true;
        a1 = columns;
      }
      if (((codingPos & 1) ^ blackPixels) != 0) {
        codingPos++;
      }
      codingLine[codingPos] = a1;
    } else if (a1 < codingLine[codingPos]) {
      if (a1 < 0) {
        err = true;
        a1 = 0;
      }
      while (codingPos > 0 && a1 < codingLine[codingPos - 1]) {
        codingPos--;
      }
      codingLine[codingPos] = a1;
    }
  }

  int _getTwoDimCode() {
    final code = _lookBits(7);
    if (code == _ccittEof) return _ccittEof;
    final p = twoDimTable[code];
    if (p[0] > 0) {
      _eatBits(p[0]);
      return p[1];
    }
    throw const TiffException('Bad CCITT 2D mode code');
  }

  int _getWhiteCode() {
    final code = _lookBits(12);
    if (code == _ccittEof) return 1;
    final p = (code >> 5) == 0 ? whiteTable1[code] : whiteTable2[code >> 3];
    if (p[0] > 0) {
      _eatBits(p[0]);
      return p[1];
    }
    throw TiffException('Bad CCITT white run code (bits: $code)');
  }

  int _getBlackCode() {
    final code = _lookBits(13);
    if (code == _ccittEof) return 1;
    final List<int> p;
    if ((code >> 7) == 0) {
      p = blackTable1[code];
    } else if ((code >> 9) == 0) {
      p = blackTable2[(code >> 1) - 64];
    } else {
      p = blackTable3[code >> 7];
    }
    if (p[0] > 0) {
      _eatBits(p[0]);
      return p[1];
    }
    throw TiffException('Bad CCITT black run code (bits: $code)');
  }

  int _lookBits(int n) {
    while (inputBits < n) {
      final c = _next();
      if (c == -1) {
        if (inputBits == 0) return _ccittEof;
        return (inputBuf << (n - inputBits)) & (0xffff >> (16 - n));
      }
      inputBuf = ((inputBuf << 8) | c) & 0xffffffff;
      inputBits += 8;
    }
    return (inputBuf >> (inputBits - n)) & (0xffff >> (16 - n));
  }

  void _eatBits(int n) {
    inputBits -= n;
    if (inputBits < 0) inputBits = 0;
  }
}
