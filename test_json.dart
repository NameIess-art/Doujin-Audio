import 'dart:convert';
void main() {
  final jsonString = '[{"a": 1}]';
  final list = json.decode(jsonString) as List<dynamic>;
  print('is Map<String, dynamic>: ${list[0] is Map<String, dynamic>}');
}
