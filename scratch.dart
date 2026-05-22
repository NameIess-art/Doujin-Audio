void main() {
  var l = [1, 2].toList(growable: false);
  try {
    l.replaceRange(0, 2, [3, 4]);
    print('ok');
  } catch (e) {
    print('Error: $e');
  }
}
