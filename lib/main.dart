import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'state/app_state.dart';
import 'widgets/image_compare_viewer.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  // This widget is the root of your application.
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Image Compress Demo',
      theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple)),
      home: const MyHomePage(title: 'Image Compress Demo'),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key, required this.title});

  final String title;

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  late final AppState _state;

  @override
  void initState() {
    super.initState();
    _state = AppState();
    _state.addListener(_onStateChanged);
  }

  @override
  void dispose() {
    _state.removeListener(_onStateChanged);
    super.dispose();
  }

  void _onStateChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final TextDirection dir = Directionality.of(context);
    final EdgeInsetsGeometry pagePadding = const EdgeInsetsDirectional.fromSTEB(16, 16, 16, 16);
    return Scaffold(
      appBar: AppBar(backgroundColor: Theme.of(context).colorScheme.inversePrimary, title: Text(widget.title)),
      body: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: () async => _state.hiddenKeyboard(),
        child: SingleChildScrollView(
          padding: pagePadding,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Row(
                textDirection: dir,
                children: [
                  Expanded(
                    flex: 4,
                    child: ElevatedButton.icon(
                      onPressed: _state.pickImage,
                      icon: const Icon(Icons.photo_library, size: 12),
                      label: const Text('选择图片', style: TextStyle(fontSize: 11)),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 3,
                    child: ElevatedButton.icon(
                      onPressed: _state.captureImage,
                      icon: const Icon(Icons.photo_camera, size: 12),
                      label: const Text('拍照', style: TextStyle(fontSize: 11)),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 4,
                    child: ElevatedButton.icon(
                      onPressed: _state.originalFile != null ? _state.compress : null,
                      icon: const Icon(Icons.compress, size: 12),
                      label: const Text('压缩到目标', style: TextStyle(fontSize: 10)),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                textDirection: dir,
                children: [
                  Expanded(
                    child: _TargetSizeField(
                      value: _state.targetKB,
                      onChanged: (v) => _state.targetKB = v,
                      label: '目标大小 (KB)',
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Directionality(
                      textDirection: dir,
                      child: SwitchListTile(
                        contentPadding: EdgeInsetsDirectional.zero,
                        title: const Text('展示/上传原图'),
                        value: _state.includeOriginal,
                        onChanged: (v) => _state.includeOriginal = v,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  if (_state.originalFile != null)
                    _buildPreviewCard(context, file: _state.originalFile!, bytes: _state.originalBytes, title: '原图'),
                  if (_state.compressedFile != null)
                    _buildPreviewCard(
                      context,
                      file: _state.compressedFile!,
                      bytes: _state.compressedBytes,
                      title: '压缩图 (质量 ${_state.qualityUsed})',
                    ),
                ],
              ),
              if (_state.compressedFile != null) ...[const SizedBox(height: 12), _buildStatsCard(context)],
              const SizedBox(height: 20),
              Row(
                textDirection: dir,
                children: [
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed:
                          !_state.uploading && _state.originalFile != null
                              ? () async {
                                final String? err = await _state.upload(original: true);
                                if (!mounted) return;
                                if (err == null) {
                                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('上传成功')));
                                } else {
                                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
                                }
                              }
                              : null,
                      icon: const Icon(Icons.cloud_upload),
                      label: const Text('上传原图'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed:
                          !_state.uploading && _state.compressedFile != null
                              ? () async {
                                final String? err = await _state.upload(original: false);
                                if (!mounted) return;
                                if (err == null) {
                                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('上传成功')));
                                } else {
                                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
                                }
                              }
                              : null,
                      icon: const Icon(Icons.cloud_upload_outlined),
                      label: const Text('上传压缩图'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPreviewCard(BuildContext context, {required File file, int? bytes, required String title}) {
    final int size = bytes ?? file.lengthSync();
    final double kb = size / 1024.0;
    final bool isOriginal = title.contains('原图');
    return Card(
      child: InkWell(
        onTap: () {
          Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder:
                  (BuildContext ctx) => ImageCompareViewerPage(
                    originalFile: _state.originalFile,
                    compressedFile: _state.compressedFile,
                    initialPreferredTab: isOriginal ? 'original' : 'compressed',
                  ),
              fullscreenDialog: true,
            ),
          );
        },
        child: Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(8, 8, 8, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title),
              Text('${kb.toStringAsFixed(1)} KB'),
              const SizedBox(height: 8),
              Image.file(file, width: 100, fit: BoxFit.contain),
              const SizedBox(height: 8),
              Row(
                children: [
                  ElevatedButton.icon(
                    onPressed: () async {
                      final bool ok = await _state.saveToGallery(file);
                      if (!mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(ok ? '已保存到相册' : '保存失败')));
                    },
                    icon: const Icon(Icons.download),
                    label: const Text('保存到相册'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStatsCard(BuildContext context) {
    final TextDirection dir = Directionality.of(context);
    final int? o = _state.originalBytes ?? _state.originalFile?.lengthSync();
    final int? c = _state.compressedBytes ?? _state.compressedFile?.lengthSync();
    final double? okb = o != null ? o / 1024.0 : null;
    final double? ckb = c != null ? c / 1024.0 : null;
    final String durationText = _state.compressDurationMs == null ? '-' : '${_state.compressDurationMs} ms';

    String ratioText = '-';
    if (o != null && c != null && o > 0) {
      final double ratio = c / o;
      ratioText = '${(ratio * 100).toStringAsFixed(1)}%';
    }

    String savedText = '-';
    if (o != null && c != null) {
      final int saved = o - c;
      final double savedKb = saved / 1024.0;
      savedText = '${savedKb.toStringAsFixed(1)} KB';
    }

    return Card(
      child: Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(12, 12, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              textDirection: dir,
              children: <Widget>[
                const Icon(Icons.image, size: 18),
                const SizedBox(width: 8),
                Text('原图大小: ${okb == null ? '-' : '${okb.toStringAsFixed(1)} KB'}'),
              ],
            ),
            const SizedBox(height: 6),
            Row(
              textDirection: dir,
              children: <Widget>[
                const Icon(Icons.compress, size: 18),
                const SizedBox(width: 8),
                Text('压缩后大小: ${ckb == null ? '-' : '${ckb.toStringAsFixed(1)} KB'}'),
              ],
            ),
            const SizedBox(height: 6),
            Row(
              textDirection: dir,
              children: <Widget>[Icon(Icons.percent, size: 18), SizedBox(width: 8), Text('压缩比例: $ratioText')],
            ),
            // Using separate Text to ensure correct formatting and avoid const issues
            const SizedBox(height: 6),
            Row(
              textDirection: dir,
              children: <Widget>[
                const Icon(Icons.timer, size: 18),
                const SizedBox(width: 8),
                Text('压缩耗时: $durationText'),
              ],
            ),
            const SizedBox(height: 6),
            Row(
              textDirection: dir,
              children: <Widget>[
                const Icon(Icons.savings, size: 18),
                const SizedBox(width: 8),
                Text('节省容量: $savedText'),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _TargetSizeField extends StatefulWidget {
  final int value;
  final ValueChanged<int> onChanged;
  final String label;
  const _TargetSizeField({required this.value, required this.onChanged, required this.label});

  @override
  State<_TargetSizeField> createState() => _TargetSizeFieldState();
}

class _TargetSizeFieldState extends State<_TargetSizeField> {
  late final TextEditingController _controller;
  bool _programmaticUpdate = false;
  late final FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.value.toString());
    _controller.addListener(_onTextChanged);
    _focusNode = FocusNode();
    _focusNode.addListener(_onFocusChange);
  }

  @override
  void didUpdateWidget(covariant _TargetSizeField oldWidget) {
    super.didUpdateWidget(oldWidget);
    final String currentText = _controller.text;
    final String newText = widget.value.toString();
    // Only sync from outside when not focused, to avoid overriding user typing
    if (!_focusNode.hasFocus && currentText != newText) {
      _programmaticUpdate = true;
      _controller.value = _controller.value.copyWith(
        text: newText,
        selection: TextSelection.collapsed(offset: newText.length),
        composing: TextRange.empty,
      );
      _programmaticUpdate = false;
    }
  }

  void _onTextChanged() {
    if (_programmaticUpdate) return;
    final String text = _controller.text;
    final int? v = int.tryParse(text);
    if (v != null && v > 0) {
      widget.onChanged(v);
    }
  }

  void _onFocusChange() {
    if (_focusNode.hasFocus) return;
    // On blur: commit valid value or restore to last good external value
    final String text = _controller.text;
    final int? v = int.tryParse(text);
    if (v != null && v > 0) {
      widget.onChanged(v);
    } else {
      final String fallback = widget.value.toString();
      _programmaticUpdate = true;
      _controller.value = _controller.value.copyWith(
        text: fallback,
        selection: TextSelection.collapsed(offset: fallback.length),
        composing: TextRange.empty,
      );
      _programmaticUpdate = false;
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_onTextChanged);
    _controller.dispose();
    _focusNode.removeListener(_onFocusChange);
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _controller,
      focusNode: _focusNode,
      keyboardType: TextInputType.number,
      inputFormatters: <TextInputFormatter>[FilteringTextInputFormatter.digitsOnly],
      decoration: InputDecoration(
        labelText: widget.label,
        prefixIcon: const Icon(Icons.tune),
        contentPadding: const EdgeInsetsDirectional.fromSTEB(12, 12, 12, 12),
        border: const OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(8))),
      ),
    );
  }
}
