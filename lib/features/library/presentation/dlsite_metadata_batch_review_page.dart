import 'package:flutter/material.dart';

import '../application/dlsite_metadata_batch_session.dart';
import 'dlsite_metadata_review_page.dart';

class DlsiteMetadataBatchReviewPage extends StatefulWidget {
  const DlsiteMetadataBatchReviewPage({
    super.key,
    required this.session,
    required this.initialIndex,
  });

  final DlsiteMetadataBatchSession session;
  final int initialIndex;

  @override
  State<DlsiteMetadataBatchReviewPage> createState() =>
      _DlsiteMetadataBatchReviewPageState();
}

class _DlsiteMetadataBatchReviewPageState
    extends State<DlsiteMetadataBatchReviewPage> {
  late int _currentIndex = widget.initialIndex;
  bool _saveCover = true;

  DlsiteMetadataBatchItem get _currentItem =>
      widget.session.items[_currentIndex];

  void _navigate(int offset) {
    final nextIndex = widget.session.reviewableIndexFrom(_currentIndex, offset);
    if (nextIndex == null) return;
    setState(() {
      _currentIndex = nextIndex;
    });
  }

  void _complete(DlsiteMetadataReviewResult result) {
    if (result.saveCover != null) _saveCover = result.saveCover!;
    final metadata = result.metadata;
    if (result.isConfirmed && metadata != null) {
      widget.session.confirm(
        _currentIndex,
        metadata: metadata,
        saveCover: result.saveCover ?? false,
      );
    }
    final nextIndex = widget.session.reviewableIndexFrom(_currentIndex, 1);
    if (nextIndex == null) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _currentIndex = nextIndex;
    });
  }

  @override
  Widget build(BuildContext context) {
    final item = _currentItem;
    return DlsiteMetadataReviewPage(
      key: const ValueKey<String>('dlsite_metadata_batch_review_page'),
      detail: item.entry.detail,
      batchIndex: _currentIndex + 1,
      batchTotal: widget.session.items.length,
      allowSkip: true,
      initialSaveCover: _saveCover,
      initialCandidates: item.reviewCandidates,
      canNavigatePrevious:
          widget.session.reviewableIndexFrom(_currentIndex, -1) != null,
      canNavigateNext:
          widget.session.reviewableIndexFrom(_currentIndex, 1) != null,
      onBatchNavigate: _navigate,
      onCompleted: _complete,
    );
  }
}
