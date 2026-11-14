import 'dart:io';

import 'package:flutter/material.dart';

/// 原图查看：可双指缩放，多张可左右滑动
class ImageViewerPage extends StatefulWidget {
  final List<String> paths;
  final int initial;

  const ImageViewerPage({super.key, required this.paths, required this.initial});

  @override
  State<ImageViewerPage> createState() => _ImageViewerPageState();
}

class _ImageViewerPageState extends State<ImageViewerPage> {
  late PageController _controller;
  late int _index;

  @override
  void initState() {
    super.initState();
    _index = widget.initial;
    _controller = PageController(initialPage: widget.initial);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(
          '原图 ${_index + 1}/${widget.paths.length}',
          style: const TextStyle(fontSize: 15, color: Colors.white),
        ),
      ),
      body: PageView.builder(
        controller: _controller,
        itemCount: widget.paths.length,
        onPageChanged: (i) => setState(() => _index = i),
        itemBuilder: (context, i) {
          return InteractiveViewer(
            minScale: 1,
            maxScale: 5,
            child: Center(
              child: Image.file(
                File(widget.paths[i]),
                fit: BoxFit.contain,
                errorBuilder: (_, __, ___) => const Text(
                  '图片文件已丢失',
                  style: TextStyle(color: Colors.white70),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
