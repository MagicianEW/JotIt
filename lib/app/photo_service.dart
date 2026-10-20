import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:image_picker/image_picker.dart';

/// 取照片的接缝。
///
/// 相机和文件选择器都是平台通道，在 `flutter test` 里没有实现，所以这一层
/// 必须可替换——和录音、播放是同一个理由。抽象出来之后，「拍一张照插进
/// 光标所在处」这件事在一台没有摄像头的机器上也能被完整地测一遍。
abstract class PhotoService {
  /// 拍一张照，返回临时文件的路径。用户放弃拍摄时返回 null。
  ///
  /// [context] 是给那些没有系统相机界面的平台准备的：桌面端要自己开一个
  /// 取景页。平台自带相机界面时它会被忽略。
  Future<String?> capturePhoto(BuildContext context);

  /// 从本机挑一张现成的照片，返回路径。用户取消时返回 null。
  Future<String?> pickPhoto();
}

/// 这个平台没法拍照。
///
/// 单独一个类型，是因为「这个平台没有相机」和「用户按了取消」在界面上是
/// 两件事：前者要说清楚，后者一个字都不该留。
class PhotoUnsupported implements Exception {
  const PhotoUnsupported(this.reason);

  final String reason;

  @override
  String toString() => reason;
}

/// 桌面端开取景页的回调。
typedef DesktopCapture = Future<String?> Function(BuildContext context);

/// 真的去调平台的那一份。
class PluginPhotoService implements PhotoService {
  PluginPhotoService({this.desktopCapture});

  /// 桌面端开取景页的回调。
  ///
  /// 由 app 层注入，因为取景页住在界面层，而这一层不该反过来认得界面。
  final DesktopCapture? desktopCapture;

  @override
  Future<String?> capturePhoto(BuildContext context) async {
    // 手机上有系统相机，交给系统：它比我们自己做的好，而且用户已经习惯
    // 那个界面了。
    if (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS) {
      final XFile? shot =
          await ImagePicker().pickImage(source: ImageSource.camera);
      return shot?.path;
    }
    // 桌面系统没有「打开相机 App 就完事」这条捷径——image_picker 在 macOS
    // 和 Windows 上会直接抛 StateError，官方把这部分留给了 app 自己。
    final capture = desktopCapture;
    if (capture == null) {
      throw const PhotoUnsupported('这个平台没有可用的相机');
    }
    return capture(context);
  }

  @override
  Future<String?> pickPhoto() async {
    final XFile? picked =
        await openFile(acceptedTypeGroups: const <XTypeGroup>[_images]);
    return picked?.path;
  }
}

/// 允许挑选的图片类型。
///
/// 三个字段都给了，因为三个平台各认一个：macOS 认 UTI，Android 认 MIME，
/// Windows 认扩展名。少给一个，那个平台就会把选择器放开成「所有文件」。
const XTypeGroup _images = XTypeGroup(
  label: '图片',
  extensions: <String>[
    'jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp',
    'heic', 'heif', 'tif', 'tiff',
  ],
  mimeTypes: <String>['image/*'],
  uniformTypeIdentifiers: <String>['public.image'],
);
