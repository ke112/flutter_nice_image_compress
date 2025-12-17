import 'dart:io';

import 'package:flutter/material.dart';

/// A full-screen viewer to inspect original and compressed images.
/// - Supports pinch-to-zoom and pan
/// - Provides tabs for Original, Compressed and Compare (slider)
/// - Compare slider respects LTR/RTL by using the start side as anchor
class ImageCompareViewerPage extends StatefulWidget {
  const ImageCompareViewerPage({
    super.key,
    required this.originalFile,
    required this.compressedFile,
    this.initialPreferredTab,
  });

  final File? originalFile;
  final File? compressedFile;

  /// Preferred initial tab: 'original' | 'compressed' | null (auto)
  final String? initialPreferredTab;

  @override
  State<ImageCompareViewerPage> createState() => _ImageCompareViewerPageState();
}

enum _ViewerTab { original, compressed, compare }

class _ImageCompareViewerPageState extends State<ImageCompareViewerPage> {
  double _fraction = 0.5; // for compare slider
  final TransformationController _compareController = TransformationController();

  @override
  void dispose() {
    _compareController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final TextDirection dir = Directionality.of(context);
    final bool hasOriginal = widget.originalFile != null;
    final bool hasCompressed = widget.compressedFile != null;

    final List<_ViewerTab> tabKinds = <_ViewerTab>[];
    final List<Tab> tabs = <Tab>[];
    final List<Widget> pages = <Widget>[];

    if (hasOriginal) {
      tabKinds.add(_ViewerTab.original);
      tabs.add(const Tab(icon: Icon(Icons.image), text: '原图'));
      pages.add(_ZoomableImage(file: widget.originalFile!));
    }
    if (hasCompressed) {
      tabKinds.add(_ViewerTab.compressed);
      tabs.add(const Tab(icon: Icon(Icons.compress), text: '压缩图'));
      pages.add(_ZoomableImage(file: widget.compressedFile!));
    }
    if (hasOriginal && hasCompressed) {
      tabKinds.add(_ViewerTab.compare);
      tabs.add(const Tab(icon: Icon(Icons.compare), text: '对比'));
      pages.add(_buildCompareTab(dir));
    }

    // Fallback when no images; shouldn't happen in normal flow
    if (tabs.isEmpty) {
      return Scaffold(appBar: AppBar(title: const Text('图片查看')), body: const Center(child: Text('没有可查看的图片')));
    }

    final int initialIndex = _computeInitialIndex(tabKinds);

    return DefaultTabController(
      length: tabs.length,
      initialIndex: initialIndex.clamp(0, tabs.length - 1),
      child: Scaffold(
        appBar: AppBar(title: const Text('图片查看'), bottom: TabBar(tabs: tabs)),
        body: TabBarView(children: pages),
      ),
    );
  }

  int _computeInitialIndex(List<_ViewerTab> tabKinds) {
    final String pref = widget.initialPreferredTab ?? '';
    _ViewerTab? want;
    if (pref == 'original') want = _ViewerTab.original;
    if (pref == 'compressed') want = _ViewerTab.compressed;
    if (want == null) return 0;
    final int idx = tabKinds.indexOf(want);
    return idx >= 0 ? idx : 0;
  }

  Widget _buildCompareTab(TextDirection dir) {
    final String leftLabel = dir == TextDirection.ltr ? '压缩图' : '原图';
    final String rightLabel = dir == TextDirection.ltr ? '原图' : '压缩图';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Expanded(
          child: InteractiveViewer(
            transformationController: _compareController,
            minScale: 1,
            maxScale: 8,
            child: LayoutBuilder(
              builder: (BuildContext context, BoxConstraints constraints) {
                final double width = constraints.maxWidth;
                return Stack(
                  fit: StackFit.expand,
                  clipBehavior: Clip.hardEdge,
                  children: <Widget>[
                    // Base: Original image
                    _buildContainedImagePlain(widget.originalFile!),

                    // Top: Compressed image clipped from the start side
                    ClipPath(
                      clipper: _StartSideRectClipper(fraction: _fraction, textDirection: dir),
                      child: _buildContainedImagePlain(widget.compressedFile!),
                    ),

                    // Divider handler line at current slider position (from start)
                    PositionedDirectional(
                      start: width.isFinite ? width * _fraction - 1 : null,
                      top: 0,
                      bottom: 0,
                      child: Container(width: 2, color: Theme.of(context).colorScheme.primary.withOpacity(0.8)),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(12, 8, 12, 45),
          child: Directionality(
            textDirection: dir,
            child: Row(
              textDirection: dir,
              children: <Widget>[
                SizedBox(width: 50, child: Text(leftLabel)),
                const SizedBox(width: 8),
                Expanded(child: Slider(value: _fraction, onChanged: (double v) => setState(() => _fraction = v))),
                const SizedBox(width: 8),
                SizedBox(width: 50, child: Text(rightLabel)),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildContainedImagePlain(File file) {
    return Center(child: Image.file(file, fit: BoxFit.contain, width: double.infinity, height: double.infinity));
  }
}

class _ZoomableImage extends StatelessWidget {
  const _ZoomableImage({required this.file});
  final File file;

  @override
  Widget build(BuildContext context) {
    return InteractiveViewer(
      minScale: 1,
      maxScale: 8,
      child: Center(child: Image.file(file, fit: BoxFit.contain, width: double.infinity, height: double.infinity)),
    );
  }
}

class _StartSideRectClipper extends CustomClipper<Path> {
  _StartSideRectClipper({required this.fraction, required this.textDirection});
  final double fraction; // 0..1 amount from the start side
  final TextDirection textDirection;

  @override
  Path getClip(Size size) {
    final Path p = Path();
    final double w = size.width;
    final double h = size.height;
    final double startWidth = (fraction.clamp(0.0, 1.0)) * w;
    if (textDirection == TextDirection.rtl) {
      // Start is on the right in RTL
      final Rect r = Rect.fromLTWH(w - startWidth, 0, startWidth, h);
      p.addRect(r);
    } else {
      final Rect r = Rect.fromLTWH(0, 0, startWidth, h);
      p.addRect(r);
    }
    return p;
  }

  @override
  bool shouldReclip(covariant _StartSideRectClipper oldClipper) {
    return oldClipper.fraction != fraction || oldClipper.textDirection != textDirection;
  }
}
