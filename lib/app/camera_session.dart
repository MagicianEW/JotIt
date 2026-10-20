import 'package:camera/camera.dart';
import 'package:flutter/widgets.dart';

/// 取景页真正用到的那部分相机能力。
///
/// 相机是平台通道，`flutter test` 里没有实现，所以这一层必须可替换——
/// 和录音、播放是同一个理由。抽象出来的意义在于：取景页要测的是「初始化
/// 失败时给什么、按下快门后回什么、退出时有没有把相机放掉」这些逻辑，
/// 这些都不该被一台真的摄像头绑住。
abstract class CameraSession {
  /// 实时取景画面。
  Widget buildPreview();

  /// 拍一张，返回临时文件的路径。
  Future<String> takePicture();

  /// 放掉相机。
  Future<void> dispose();
}

/// 真的去调平台的那一份。
class PluginCameraSession implements CameraSession {
  PluginCameraSession._(this._controller);

  final CameraController _controller;

  /// 打开第一台相机并开始取景。
  ///
  /// 打开第一台而不是让用户挑，是因为笔记本和桌面的默认摄像头就是那台
  /// 朝着人的；多选是另一个功能，不该挡在这条路的中间。
  static Future<PluginCameraSession> open() async {
    final cameras = await availableCameras();
    if (cameras.isEmpty) {
      throw const CameraUnavailable('这台机器上没有找到可用的相机');
    }
    final controller = CameraController(
      cameras.first,
      ResolutionPreset.high,
      // 拍照不需要声音。开着音频会话会让系统多问一次麦克风权限，而用户
      // 此刻只想拍一张照片。
      enableAudio: false,
    );
    try {
      await controller.initialize();
    } on Object {
      // 初始化失败时控制器已经创建，不放掉它就等于把摄像头留在占用状态，
      // 下次再试会拿到一句更含糊的错。
      await controller.dispose();
      rethrow;
    }
    return PluginCameraSession._(controller);
  }

  @override
  Widget buildPreview() => CameraPreview(_controller);

  @override
  Future<String> takePicture() async {
    final XFile shot = await _controller.takePicture();
    return shot.path;
  }

  @override
  Future<void> dispose() => _controller.dispose();
}

/// 这台机器没法用相机——没有摄像头，或者用户不给权限。
///
/// 单独一个类型，是因为「没有相机」和「用户按了取消」在界面上是两件事：
/// 前者要说清楚，后者一个字都不该留。
class CameraUnavailable implements Exception {
  const CameraUnavailable(this.reason);

  final String reason;

  @override
  String toString() => reason;
}
