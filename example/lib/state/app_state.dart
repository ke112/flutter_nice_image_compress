import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../services/gallery_saver.dart';
import '../services/image_compressor.dart';
import '../services/uploader.dart';

class AppState extends ChangeNotifier {
  AppState({ImagePicker? picker, ImageUploaderService? uploader})
    : _picker = picker ?? ImagePicker(),
      _uploader = uploader ?? ImageUploaderService();

  final ImagePicker _picker;
  final ImageUploaderService _uploader;

  File? _originalFile;
  File? _compressedFile;
  int? _originalBytes;
  int? _compressedBytes;
  bool _uploading = false;
  bool _includeOriginal = true;
  int _targetKB = 500;
  int? _qualityUsed;
  int? _compressDurationMs;

  File? get originalFile => _originalFile;
  File? get compressedFile => _compressedFile;
  int? get originalBytes => _originalBytes;
  int? get compressedBytes => _compressedBytes;
  bool get uploading => _uploading;
  bool get includeOriginal => _includeOriginal;
  int get targetKB => _targetKB;
  int? get qualityUsed => _qualityUsed;
  int? get compressDurationMs => _compressDurationMs;

  set targetKB(int v) {
    if (v == _targetKB) return;
    _targetKB = v;
    notifyListeners();
  }

  set includeOriginal(bool v) {
    if (v == _includeOriginal) return;
    _includeOriginal = v;
    notifyListeners();
  }

  Future<void> pickImage() async {
    final XFile? picked = await _picker.pickImage(source: ImageSource.gallery);
    if (picked == null) return;
    final File f = File(picked.path);
    final int b = await f.length();
    _originalFile = f;
    _originalBytes = b;
    _compressedFile = null;
    _compressedBytes = null;
    _qualityUsed = null;
    _compressDurationMs = null;
    notifyListeners();
  }

  Future<void> captureImage() async {
    hiddenKeyboard();
    final XFile? captured = await _picker.pickImage(source: ImageSource.camera);
    if (captured == null) return;
    final File f = File(captured.path);
    final int b = await f.length();
    _originalFile = f;
    _originalBytes = b;
    _compressedFile = null;
    _compressedBytes = null;
    _qualityUsed = null;
    _compressDurationMs = null;
    notifyListeners();
  }

  Future<void> compress() async {
    hiddenKeyboard();
    if (_originalFile == null) return;
    final opts = ImageCompressorOptions(targetSizeInKB: _targetKB);
    final Stopwatch sw = Stopwatch()..start();
    final res = await ImageCompressorService.compressToTarget(_originalFile!, options: opts);
    sw.stop();
    _compressedFile = res.file;
    _compressedBytes = res.bytes;
    _qualityUsed = res.qualityUsed;
    _compressDurationMs = sw.elapsedMilliseconds;
    notifyListeners();
  }

  Future<String?> upload({required bool original}) async {
    final File? file = original ? _originalFile : _compressedFile;
    if (file == null) return '没有可上传的文件';
    _uploading = true;
    notifyListeners();
    try {
      final Uri url = Uri.parse('https://httpbin.org/post');
      await _uploader.uploadFile(url: url, file: file, extraFields: {'original': original.toString()});
      return null;
    } catch (e) {
      return '上传失败: $e';
    } finally {
      _uploading = false;
      notifyListeners();
    }
  }

  Future<bool> saveToGallery(File file) async {
    final String name = 'img_${DateTime.now().millisecondsSinceEpoch}';
    return await GallerySaverService.saveImageFile(file, name: name);
  }

  void hiddenKeyboard() {
    SystemChannels.textInput.invokeMethod('TextInput.hide');
  }
}
