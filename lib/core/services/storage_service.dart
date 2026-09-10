import 'package:firebase_storage/firebase_storage.dart';
import 'package:image_picker/image_picker.dart';

import '../app_config.dart';

/// Validates + uploads user media to Firebase Storage under strict
/// path/type/size rules (mirrored server-side by storage rules).
library;

class StorageValidationException implements Exception {
  StorageValidationException(this.message);
  final String message;
  @override
  String toString() => message;
}

class StorageService {
  final FirebaseStorage _storage = FirebaseStorage.instance;
  final ImagePicker _picker = ImagePicker();

  static const Set<String> _imageExts = <String>{'jpg', 'jpeg', 'png', 'webp'};
  static const Set<String> _videoExts = <String>{'mp4', 'mov', 'webm'};

  String _ext(XFile file) {
    final String name = file.name;
    final int dot = name.lastIndexOf('.');
    return dot >= 0 ? name.substring(dot + 1).toLowerCase() : '';
  }

  void _validateImage(XFile file) {
    final String ext = _ext(file);
    if (!_imageExts.contains(ext)) {
      throw StorageValidationException(
          'Unsupported image format. Use JPG, PNG or WEBP.');
    }
    if (file.length > AppConfig.maxImageBytes) {
      throw StorageValidationException(
          'Image is too large. Maximum size is 10 MB.');
    }
  }

  void _validateVideo(XFile file) {
    final String ext = _ext(file);
    if (!_videoExts.contains(ext)) {
      throw StorageValidationException(
          'Unsupported video format. Use MP4, MOV or WEBM.');
    }
    if (file.length > AppConfig.maxVideoBytes) {
      throw StorageValidationException(
          'Video is too large. Maximum size is 50 MB.');
    }
  }

  void _validateAvatar(XFile file) {
    _validateImage(file);
    if (file.length > AppConfig.maxAvatarBytes) {
      throw StorageValidationException('Avatar is too large. Maximum 5 MB.');
    }
  }

  String _contentType(XFile file) {
    final String? mime = file.mimeType;
    if (mime != null && mime.isNotEmpty) return mime;
    final String ext = _ext(file);
    const Map<String, String> byExt = <String, String>{
      'jpg': 'image/jpeg',
      'jpeg': 'image/jpeg',
      'png': 'image/png',
      'webp': 'image/webp',
      'mp4': 'video/mp4',
      'mov': 'video/quicktime',
      'webm': 'video/webm',
    };
    return byExt[ext] ?? 'application/octet-stream';
  }

  Future<String> uploadIncidentImage(XFile file, String uid) async {
    _validateImage(file);
    final StorageReference ref = _storage
        .ref()
        .child('incidents')
        .child(uid)
        .child('${DateTime.now().millisecondsSinceEpoch}_img.${_ext(file)}');
    await ref.putFile(file, SettableMetadata(contentType: _contentType(file)));
    return ref.getDownloadURL();
  }

  Future<String> uploadIncidentVideo(XFile file, String uid) async {
    _validateVideo(file);
    final StorageReference ref = _storage
        .ref()
        .child('incidents')
        .child(uid)
        .child('${DateTime.now().millisecondsSinceEpoch}_vid.${_ext(file)}');
    await ref.putFile(file, SettableMetadata(contentType: _contentType(file)));
    return ref.getDownloadURL();
  }

  Future<String> uploadAvatar(XFile file, String uid) async {
    _validateAvatar(file);
    final StorageReference ref = _storage
        .ref()
        .child('avatars')
        .child(uid)
        .child('${DateTime.now().millisecondsSinceEpoch}_avatar.${_ext(file)}');
    await ref.putFile(file, SettableMetadata(contentType: _contentType(file)));
    return ref.getDownloadURL();
  }

  Future<XFile?> pickImage() =>
      _picker.pickImage(source: ImageSource.gallery, maxWidth: 1600, imageQuality: 85);

  Future<XFile?> pickVideo() =>
      _picker.pickVideo(source: ImageSource.gallery, maxWidth: 1280);

  Future<XFile?> pickAvatar() =>
      _picker.pickImage(source: ImageSource.gallery, maxWidth: 600, imageQuality: 85);
}
