import 'package:ensemble_llama/src/llama.dart' show Token;

// 4294967295 (32 bit unsigned)
// -1 (32 bit signed)
const int32Max = 0xFFFFFFFF;

extension TokenLogString on Token {
  String toLogString([int? i]) {
    final buf = StringBuffer();
    if (i != null) {
      buf.write(i.toString().padLeft(4));
      buf.write(':');
    }
    buf.write(id.toString().padLeft(6));
    buf.write(' = ');
    buf.write(text.replaceAll(' ', '▁').replaceAll('\n', '<0x0A>').padRight(10));
    return buf.toString();
  }
}

extension NumberRangeChecks on num {
  void checkIncInc(num start, num end, String name) {
    if (!(this >= start && this <= end)) {
      throw RangeError.value(this, name, 'must be between [$start, $end]');
    }
  }

  void checkGTE(num min, String name) {
    if (!(this >= min)) {
      throw RangeError.value(this, name, 'must be greater than or equal to $min');
    }
  }
}
