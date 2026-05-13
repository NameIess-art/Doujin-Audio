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
    final leftIsDigit = _isDigit(leftCode);
    final rightIsDigit = _isDigit(rightCode);

    if (leftIsDigit && rightIsDigit) {
      final leftEnd = _consumeDigits(normalizedLeft, leftIndex);
      final rightEnd = _consumeDigits(normalizedRight, rightIndex);
      final numberResult = _compareNumberRuns(
        normalizedLeft.substring(leftIndex, leftEnd),
        normalizedRight.substring(rightIndex, rightEnd),
      );
      if (numberResult != 0) return numberResult;
      leftIndex = leftEnd;
      rightIndex = rightEnd;
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

int _consumeDigits(String value, int start) {
  var index = start;
  while (index < value.length && _isDigit(value.codeUnitAt(index))) {
    index++;
  }
  return index;
}

bool _isDigit(int codeUnit) => codeUnit >= 48 && codeUnit <= 57;

int _compareNumberRuns(String leftRun, String rightRun) {
  final trimmedLeft = leftRun.replaceFirst(RegExp(r'^0+'), '');
  final trimmedRight = rightRun.replaceFirst(RegExp(r'^0+'), '');
  final normalizedLeft = trimmedLeft.isEmpty ? '0' : trimmedLeft;
  final normalizedRight = trimmedRight.isEmpty ? '0' : trimmedRight;

  final magnitudeResult = normalizedLeft.length.compareTo(
    normalizedRight.length,
  );
  if (magnitudeResult != 0) return magnitudeResult;

  final valueResult = normalizedLeft.compareTo(normalizedRight);
  if (valueResult != 0) return valueResult;

  return leftRun.length.compareTo(rightRun.length);
}
