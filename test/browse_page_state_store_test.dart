import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/app/application/browse_page_state_store.dart';

void main() {
  test(
    'root display state is shared only within the current application run',
    () {
      final store = BrowsePageStateStore();
      store.update('library', {
        'offset': 280.0,
        'expanded': ['work'],
      });
      store.update('library', {'offset': 400.0});
      expect(store.stateFor('library')['offset'], 400.0);
      expect(store.stateFor('library')['expanded'], ['work']);
      expect(BrowsePageStateStore().stateFor('library'), isEmpty);
    },
  );

  test('clear rejects retired page writes and allows fresh interactions', () {
    final store = BrowsePageStateStore();
    final previousEpoch = store.epoch;
    store.update('library', {'offset': 280.0});
    store.clear();
    store.update('library', {'offset': 900.0}, epoch: previousEpoch);
    expect(store.stateFor('library'), isEmpty);
    store.update('library', {'offset': 120.0}, epoch: store.epoch);
    expect(store.stateFor('library')['offset'], 120.0);
  });
}
