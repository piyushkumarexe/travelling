import 'dart:io';
import 'dart:typed_data';

import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

class PrivateFileService {
  static const MethodChannel _channel =
      MethodChannel('app.roamio.tourism/private_files');

  /// Removes downloaded private documents from the app-private cache. Android
  /// grants the receiving app access only to the selected content URI; this
  /// cleanup removes the local copy when the account/session is cleared.
  Future<void> clearTemporaryFiles() async {
    final Directory temporary = await getTemporaryDirectory();
    final Directory directory =
        Directory('${temporary.path}/tourism_private');
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  }

  Future<Uint8List> readBytes(String storagePath, int maxBytes) async {
    final Uint8List? bytes =
        await FirebaseStorage.instance.ref(storagePath).getData(maxBytes);
    if (bytes == null || bytes.isEmpty) {
      throw StateError('The private file is empty or unavailable.');
    }
    return bytes;
  }

  Future<File> materialize({
    required String storagePath,
    required String fileName,
    int maxBytes = 50 * 1024 * 1024,
  }) async {
    final Uint8List bytes = await readBytes(storagePath, maxBytes);
    final Directory temporary = await getTemporaryDirectory();
    final Directory directory =
        Directory('${temporary.path}/tourism_private');
    await directory.create(recursive: true);
    final String safeName = fileName
        .replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_')
        .replaceAll(RegExp(r'_+'), '_');
    final String extension = safeName.contains('.')
        ? safeName.substring(safeName.lastIndexOf('.'))
        : '';
    final File file = File(
      '${directory.path}/${DateTime.now().microsecondsSinceEpoch}$extension',
    );
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  Future<void> open({
    required String storagePath,
    required String fileName,
  }) async {
    if (!Platform.isAndroid) {
      throw UnsupportedError('External private-file opening is supported on Android.');
    }
    final File file = await materialize(
      storagePath: storagePath,
      fileName: fileName,
    );
    final bool opened = await _channel.invokeMethod<bool>(
          'openFile',
          <String, Object>{
            'path': file.path,
            'mimeType': _mimeType(fileName),
          },
        ) ??
        false;
    if (!opened) throw StateError('No installed app can open this file type.');
  }

  String _mimeType(String fileName) {
    switch (fileName.toLowerCase().split('.').last) {
      case 'pdf':
        return 'application/pdf';
      case 'png':
        return 'image/png';
      case 'webp':
        return 'image/webp';
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'mp4':
        return 'video/mp4';
      case 'mov':
        return 'video/quicktime';
      case 'webm':
        return 'video/webm';
      default:
        return 'application/octet-stream';
    }
  }
}
