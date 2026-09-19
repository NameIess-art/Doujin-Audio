int compareNatural(String left, String right, {bool caseSensitive = false}) {
  if (identical(left, right)) return 0;

  final normalizedLeft = caseSensitive ? left : left.toLowerCase();
  final normalizedRight = caseSensitive ? right : right.toLowerCase();

  var leftIndex = 0;
  var rightIndex = 0;

  while (leftIndex < normalizedLeft.length &&
      rightIndex < normalizedRight.length) {
    final leftCode = normalizedLeft.codeUnitAt(leftIndex);
    final rightCode = normalizedRight.codeUnitAt(rightIndex);
    final leftIsNumber = _isNumberStart(leftCode);
    final rightIsNumber = _isNumberStart(rightCode);

    if (leftIsNumber && rightIsNumber) {
      final leftToken = _consumeNumber(normalizedLeft, leftIndex);
      final rightToken = _consumeNumber(normalizedRight, rightIndex);
      final numberResult = _compareNumbers(leftToken, rightToken);
      if (numberResult != 0) return numberResult;
      leftIndex = leftToken.endIndex;
      rightIndex = rightToken.endIndex;
      continue;
    }

    if (leftCode != rightCode) return leftCode.compareTo(rightCode);
    leftIndex++;
    rightIndex++;
  }

  final lengthResult = normalizedLeft.length.compareTo(normalizedRight.length);
  if (lengthResult != 0) return lengthResult;
  return left.compareTo(right);
}

int compareNaturalTreeEntries({
  required bool leftIsFolder,
  required String leftName,
  required String leftPath,
  required bool rightIsFolder,
  required String rightName,
  required String rightPath,
}) {
  if (leftIsFolder != rightIsFolder) {
    return leftIsFolder ? -1 : 1;
  }
  final nameResult = compareNatural(leftName, rightName);
  if (nameResult != 0) return nameResult;
  return compareNatural(leftPath, rightPath);
}

class _NumberToken {
  const _NumberToken({
    required this.normalizedDigits,
    required this.rawRun,
    required this.endIndex,
    required this.isArabic,
  });

  final String normalizedDigits;
  final String rawRun;
  final int endIndex;
  final bool isArabic;
}

bool _isNumberStart(int codeUnit) =>
    _isDigit(codeUnit) || _isChineseNumeralStart(codeUnit);

bool _isDigit(int codeUnit) =>
    (codeUnit >= 48 && codeUnit <= 57) ||
    (codeUnit >= 0xff10 && codeUnit <= 0xff19);

int _consumeDigits(String value, int start) {
  var index = start;
  while (index < value.length && _isDigit(value.codeUnitAt(index))) {
    index++;
  }
  return index;
}

_NumberToken _consumeNumber(String value, int start) {
  final firstCode = value.codeUnitAt(start);
  if (_isDigit(firstCode)) {
    final end = _consumeDigits(value, start);
    final run = value.substring(start, end);
    return _NumberToken(
      normalizedDigits: _normalizeDigitRun(run),
      rawRun: run,
      endIndex: end,
      isArabic: true,
    );
  }

  final end = _consumeChineseNumerals(value, start);
  final run = value.substring(start, end);
  final parsed = _parseChineseNumerals(value, start, end);
  return _NumberToken(
    normalizedDigits: parsed.toString(),
    rawRun: run,
    endIndex: end,
    isArabic: false,
  );
}

int _compareNumbers(_NumberToken left, _NumberToken right) {
  final trimmedLeft = left.normalizedDigits.replaceFirst(RegExp(r'^0+'), '');
  final trimmedRight = right.normalizedDigits.replaceFirst(RegExp(r'^0+'), '');
  final valLeft = trimmedLeft.isEmpty ? '0' : trimmedLeft;
  final valRight = trimmedRight.isEmpty ? '0' : trimmedRight;

  final magnitudeResult = valLeft.length.compareTo(valRight.length);
  if (magnitudeResult != 0) return magnitudeResult;

  final valueResult = valLeft.compareTo(valRight);
  if (valueResult != 0) return valueResult;

  if (left.isArabic && right.isArabic) {
    return left.rawRun.length.compareTo(right.rawRun.length);
  }

  if (left.rawRun != right.rawRun) {
    return left.rawRun.compareTo(right.rawRun);
  }

  return 0;
}

String _normalizeDigitRun(String value) => String.fromCharCodes(
  value.codeUnits.map(
    (codeUnit) => codeUnit >= 0xff10 ? codeUnit - 0xfee0 : codeUnit,
  ),
);

const Map<int, int> _chineseDigits = <int, int>{
  0x3007: 0, // 〇
  0x96f6: 0, // 零
  0x4e00: 1, // 一
  0x58f9: 1, // 壹
  0x58f1: 1, // 壱
  0x4e8c: 2, // 二
  0x8d30: 2, // 贰
  0x8cb3: 2, // 貳
  0x5f10: 2, // 弐
  0x4e24: 2, // 两
  0x5169: 2, // 兩
  0x4e09: 3, // 三
  0x53c1: 3, // 叁
  0x53c3: 3, // 參
  0x53c2: 3, // 参
  0x56db: 4, // 四
  0x8086: 4, // 肆
  0x4e94: 5, // 五
  0x4f0d: 5, // 伍
  0x516d: 6, // 六
  0x9646: 6, // 陆
  0x9678: 6, // 陸
  0x4e03: 7, // 七
  0x67d2: 7, // 柒
  0x6f06: 7, // 漆
  0x516b: 8, // 八
  0x634c: 8, // 捌
  0x4e5d: 9, // 九
  0x7396: 9, // 玖
};

const Map<int, int> _chineseUnits = <int, int>{
  0x5341: 10,        // 十
  0x62fe: 10,        // 拾
  0x5344: 20,        // 廿
  0x5345: 30,        // 卅
  0x767e: 100,       // 百
  0x4f70: 100,       // 佰
  0x5343: 1000,      // 千
  0x4edf: 1000,      // 仟
  0x4e07: 10000,     // 万
  0x842c: 10000,     // 萬
  0x4ebf: 100000000, // 亿
  0x5104: 100000000, // 億
};

bool _isChineseNumeralStart(int codeUnit) {
  if (codeUnit < 0x3007) return false;
  if (_chineseDigits.containsKey(codeUnit)) return true;
  return codeUnit == 0x5341 || // 十
      codeUnit == 0x62fe ||    // 拾
      codeUnit == 0x5344 ||    // 廿
      codeUnit == 0x5345 ||    // 卅
      codeUnit == 0x767e ||    // 百
      codeUnit == 0x4f70 ||    // 佰
      codeUnit == 0x5343 ||    // 千
      codeUnit == 0x4edf;      // 仟
}

bool _isChineseNumeralChar(int codeUnit) {
  if (codeUnit < 0x3007) return false;
  return _chineseDigits.containsKey(codeUnit) ||
      _chineseUnits.containsKey(codeUnit);
}

int _consumeChineseNumerals(String value, int start) {
  var index = start;
  while (index < value.length &&
      _isChineseNumeralChar(value.codeUnitAt(index))) {
    index++;
  }
  return index;
}

BigInt _parseChineseNumerals(String value, int start, int end) {
  var hasUnit = false;
  for (var i = start; i < end; i++) {
    if (_chineseUnits.containsKey(value.codeUnitAt(i))) {
      hasUnit = true;
      break;
    }
  }

  if (!hasUnit) {
    var result = BigInt.zero;
    final ten = BigInt.from(10);
    for (var i = start; i < end; i++) {
      final digit = _chineseDigits[value.codeUnitAt(i)] ?? 0;
      result = result * ten + BigInt.from(digit);
    }
    return result;
  }

  var total = BigInt.zero;
  var section = BigInt.zero;
  var currentDigit = BigInt.zero;
  var hasDigit = false;

  for (var i = start; i < end; i++) {
    final code = value.codeUnitAt(i);
    final digit = _chineseDigits[code];
    if (digit != null) {
      if (digit == 0) {
        hasDigit = false;
      } else {
        currentDigit = BigInt.from(digit);
        hasDigit = true;
      }
      continue;
    }

    final unit = _chineseUnits[code];
    if (unit != null) {
      if (unit >= 10000) {
        if (hasDigit) {
          section += currentDigit;
          currentDigit = BigInt.zero;
          hasDigit = false;
        }
        if (section == BigInt.zero) {
          section = BigInt.one;
        }
        total += section * BigInt.from(unit);
        section = BigInt.zero;
      } else if (unit == 20 || unit == 30) {
        section += BigInt.from(unit);
        currentDigit = BigInt.zero;
        hasDigit = false;
      } else {
        if (!hasDigit) {
          currentDigit = BigInt.one;
        }
        section += currentDigit * BigInt.from(unit);
        currentDigit = BigInt.zero;
        hasDigit = false;
      }
    }
  }

  if (hasDigit) {
    section += currentDigit;
  }
  total += section;
  return total;
}
