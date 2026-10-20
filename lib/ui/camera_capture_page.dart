import 'package:flutter/material.dart';

import '../app/camera_session.dart';

/// 桌面端的取景页。
///
/// 桌面系统没有「打开相机 App 就完事」这条捷径——image_picker 在 macOS
/// 和 Windows 上都会直接抛 StateError，官方把这部分留给了 app 自己。于是
/// 这里就是一个最小的取景界面：一个取景画面、一个快门、一个取消。
///
/// 它做的是「拍一张照片」这一件事，不做裁剪、不做滤镜、不做连拍。照片拍
/// 完就交给上层，和录音结束时交给上层的是同一种文件。
class CameraCapturePage extends StatefulWidget {
  const CameraCapturePage({super.key, this.sessionFactory});

  /// 打开取景页，拍完返回照片路径，用户取消则返回 null。
  static Future<String?> capture(BuildContext context) {
    return Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const CameraCapturePage()),
    );
  }

  /// 打开相机的入口。测试里换成假的，于是取景页的逻辑可以被完整地测。
  final Future<CameraSession> Function()? sessionFactory;

  @override
  State<CameraCapturePage> createState() => _CameraCapturePageState();
}

class _CameraCapturePageState extends State<CameraCapturePage> {
  late final Future<CameraSession> _opening;
  CameraSession? _session;
  bool _taking = false;
  String? _failure;

  @override
  void initState() {
    super.initState();
    _opening = _open();
  }

  Future<CameraSession> _open() async {
    final factory = widget.sessionFactory ?? PluginCameraSession.open;
    final session = await factory();
    if (!mounted) {
      // 页面在相机打开的半路就没了。相机不会因为没人看它就自己关掉。
      await session.dispose();
      throw const CameraUnavailable('取景页已经关闭');
    }
    _session = session;
    return session;
  }

  @override
  void dispose() {
    _session?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: FutureBuilder<CameraSession>(
        future: _opening,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return _failureView('${snapshot.error}');
          }
          final session = snapshot.data;
          if (session == null) {
            return const Center(child: CircularProgressIndicator());
          }
          return _viewfinder(session);
        },
      ),
    );
  }

  Widget _viewfinder(CameraSession session) {
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        session.buildPreview(),
        Positioned(
          top: 12,
          left: 12,
          child: Material(
            color: Colors.black54,
            shape: const CircleBorder(),
            child: IconButton(
              key: const ValueKey('camera-capture-close'),
              icon: const Icon(Icons.close, color: Colors.white),
              tooltip: '取消',
              onPressed: () => Navigator.of(context).pop(),
            ),
          ),
        ),
        Positioned(
          bottom: 28,
          left: 0,
          right: 0,
          child: Center(
            child: Semantics(
              button: true,
              label: '拍照',
              child: GestureDetector(
                key: const ValueKey('camera-capture-shutter'),
                onTap: _taking ? null : () => _shoot(session),
                child: Container(
                  width: 68,
                  height: 68,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _taking ? Colors.white24 : Colors.white,
                    border: Border.all(color: Colors.white54, width: 3),
                  ),
                ),
              ),
            ),
          ),
        ),
        // A capture that failed says so, and the screen stays open: the user
        // is still standing in front of the camera and the shutter still
        // works. Closing the screen on a failure would throw away a photo
        // that one more try would have taken.
        if (_failure != null)
          Positioned(
            bottom: 110,
            left: 24,
            right: 24,
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.black87,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                _failure!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white),
              ),
            ),
          ),
      ],
    );
  }

  Widget _failureView(String reason) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(Icons.no_photography_outlined,
                color: Colors.white70, size: 48),
            const SizedBox(height: 12),
            Text(
              reason,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white),
            ),
            const SizedBox(height: 16),
            OutlinedButton(
              key: const ValueKey('camera-capture-dismiss'),
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('关闭'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _shoot(CameraSession session) async {
    setState(() => _taking = true);
    try {
      final path = await session.takePicture();
      if (!mounted) return;
      Navigator.of(context).pop(path);
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _taking = false;
        _failure = '$e';
      });
    }
  }
}
