import 'package:flutter_test/flutter_test.dart';
import 'package:doujin_audio/core/media/music_track.dart';
import 'package:doujin_audio/core/platform/file_cache_platform_gateway.dart';
import 'package:doujin_audio/features/library/application/work_text_service.dart';
import 'package:doujin_audio/features/library/domain/library_node.dart';
import 'package:doujin_audio/features/library/presentation/work_detail_entries.dart';
import 'package:doujin_audio/features/asmr/domain/asmr_models.dart';

MusicTrack _track(String name) => MusicTrack(
  path: 'C:/作品/$name',
  displayName: name,
  groupKey: 'C:/作品',
  groupTitle: '',
  groupSubtitle: '',
  isSingle: false,
);

class _DirectoryGateway extends Fake implements FileCachePlatformGateway {
  List<Map<String, String>> files = [
    {
      'name': 'script.txt',
      'relativePath': 'script.txt',
      'path': 'C:/作品/script.txt',
    },
  ];
  int scans = 0;

  @override
  Future<List<Map<String, String>>> discoverWorkTexts(String folderPath) async {
    scans++;
    return files;
  }
}

AsmrTrackFile _remote(
  String name,
  String type, {
  List<AsmrTrackFile> children = const [],
}) => AsmrTrackFile(
  hash: name,
  title: name,
  type: type,
  streamUrl: 'https://example.test/$name',
  downloadUrl: null,
  lowQualityUrl: null,
  duration: Duration.zero,
  size: 0,
  children: children,
  workId: 1,
  workTitle: 'Work',
  sourceId: 'RJ1',
  relativePath: name,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('local index sorts once and includes file-only nested directories', () {
    final root = FolderNode('作品', 'C:/作品')
      ..addChild(TrackNode(_track('Track10.mp3')))
      ..addChild(TrackNode(_track('Track2.mp3')));
    final input = WorkDirectoryInput.local(
      root: root,
      texts: const [
        WorkTextFile(
          name: 'notes.txt',
          relativePath: 'Extras/Texts/notes.txt',
          path: 'source.txt',
        ),
      ],
      images: const [
        CoverImageReference(
          sourcePath: 'C:/作品/Extras/Images/cover.jpg',
          displayPath: 'decoded.jpg',
        ),
      ],
      folderPath: 'C:/作品',
    );
    final snapshot = buildWorkDirectorySnapshot(input);
    expect(snapshot.entriesAt([]).map((entry) => entry.name), [
      'Extras',
      'Track2.mp3',
      'Track10.mp3',
    ]);
    expect(snapshot.entriesAt(['Extras']).map((entry) => entry.name), [
      'Images',
      'Texts',
    ]);
    expect(
      snapshot.entriesAt(['Extras', 'Images']).single.imageItem!.path,
      'decoded.jpg',
    );
    expect(snapshot.images.single.relativePath, 'Extras/Images/cover.jpg');
    expect(
      snapshot.entriesAt(['Extras', 'Texts']).single.textFile,
      same(input.texts.single),
    );
    expect(snapshot.validDepth(['Extras', 'Texts', 'Missing']), 2);
    expect(
      snapshot.entriesAt(['Extras']),
      same(snapshot.entriesAt(['Extras'])),
    );
    expect(() => snapshot.entriesAt([]).clear(), throwsUnsupportedError);
  });

  test('remote index retains audio, image, subtitle and folder identities', () {
    final tree = [
      _remote(
        'Extras',
        'folder',
        children: [
          _remote('audio10.mp3', 'audio'),
          _remote('audio2.mp3', 'audio'),
          _remote('cover.jpg', 'image'),
          _remote('sub.lrc', 'text'),
        ],
      ),
    ];
    final snapshot = buildWorkDirectorySnapshot(WorkDirectoryInput.asmr(tree));
    expect(snapshot.entriesAt([]).single.asmrNode, same(tree.single));
    expect(snapshot.entriesAt(['Extras']).map((entry) => entry.name), [
      'audio2',
      'audio10',
      'cover.jpg',
    ]);
    expect(snapshot.hasSubtitle, isTrue);
    expect(snapshot.images.single.path, 'https://example.test/cover.jpg');
    expect(snapshot.validDepth(['Missing']), 0);
  });

  test(
    'background preparation coalesces and reopened pages reuse immutable snapshot',
    () async {
      final root = FolderNode('作品', 'C:/作品')
        ..addChild(TrackNode(_track('audio.mp3')));
      final input = WorkDirectoryInput.local(
        root: root,
        texts: const [],
        images: const [],
        folderPath: 'C:/作品',
      );
      expect(input.resolved, isNull);
      final first = input.load();
      expect(input.load(), same(first));
      final snapshot = await first;
      final reopened = WorkDirectoryInput.local(
        root: root,
        texts: const [],
        images: const [],
        folderPath: 'C:/作品',
      );
      expect(reopened.resolved, same(snapshot));
      expect(await reopened.load(), same(snapshot));
      expect(reopened.resolved!.entriesAt([]), same(snapshot.entriesAt([])));
    },
  );

  test(
    'unchanged attachment refresh reuses the prepared directory index',
    () async {
      final gateway = _DirectoryGateway();
      var imageScans = 0;
      final service = WorkTextService(
        platformGateway: gateway,
        discoverImages: (_) async {
          imageScans++;
          return [
            const CoverImageReference(
              displayPath: 'C:/作品/cover.jpg',
              sourcePath: 'C:/作品/cover.jpg',
            ),
          ];
        },
      );
      addTearDown(service.dispose);
      final root = FolderNode('作品', 'C:/作品')
        ..addChild(TrackNode(_track('audio.mp3')));
      Future<WorkDirectoryInput> refresh() async => WorkDirectoryInput.local(
        root: root,
        texts: await service.refreshWorkTextFiles('C:/作品'),
        images: await service.refreshWorkImageFiles('C:/作品'),
        folderPath: 'C:/作品',
      );
      final first = await refresh();
      final directory = await first.load();
      final unchanged = await refresh();
      expect(unchanged.resolved, same(directory));
      expect(await unchanged.load(), same(directory));
      expect(gateway.scans, 2);
      expect(imageScans, 2);
      gateway.files = [
        {'name': 'new.txt', 'relativePath': 'new.txt', 'path': 'C:/作品/new.txt'},
      ];
      final changed = await refresh();
      expect(changed.resolved, isNull);
      final updated = await changed.load();
      expect(updated, isNot(same(directory)));
      expect(
        updated
            .entriesAt([])
            .where((item) => item.type == WorkEntryType.text)
            .single
            .name,
        'new.txt',
      );
    },
  );

  test(
    'changed file snapshot replaces in-flight index without stale cache commit',
    () async {
      final root = FolderNode('作品', 'C:/作品')
        ..addChild(TrackNode(_track('audio.mp3')));
      final initial = WorkDirectoryInput.local(
        root: root,
        texts: const [],
        images: const [],
        folderPath: 'C:/作品',
      );
      final old = initial.load();
      final changed = WorkDirectoryInput.local(
        root: root,
        texts: [
          const WorkTextFile(
            name: 'new.txt',
            relativePath: 'New/new.txt',
            path: 'new.txt',
          ),
        ],
        images: const [],
        folderPath: 'C:/作品',
      );
      final current = await changed.load();
      await old;
      expect(changed.resolved, same(current));
      expect(initial.resolved, isNull);
      expect(current.entriesAt([]).first.name, 'New');
      expect(current.validDepth(['New']), 1);
    },
  );
}
