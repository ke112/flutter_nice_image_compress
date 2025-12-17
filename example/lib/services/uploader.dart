import 'dart:io';

import 'package:dio/dio.dart';

class ImageUploaderService {
  final Dio _dio;
  ImageUploaderService({Dio? dio}) : _dio = dio ?? Dio();

  Future<Response<dynamic>> uploadFile({
    required Uri url,
    required File file,
    Map<String, dynamic>? extraFields,
    String fieldName = 'file',
    CancelToken? cancelToken,
    ProgressCallback? onSendProgress,
    Map<String, String>? headers,
  }) async {
    final FormData formData = FormData.fromMap({
      fieldName: await MultipartFile.fromFile(file.path),
      if (extraFields != null) ...extraFields,
    });

    final Response res = await _dio.postUri(
      url,
      data: formData,
      options: Options(headers: headers),
      cancelToken: cancelToken,
      onSendProgress: onSendProgress,
    );
    return res;
  }
}
