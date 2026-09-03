import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/parser/pptx_extractor.dart';

/// PowerPoint 幻灯片画布：按 xfrm 位置摆放文本框与图片，
/// 支持字号/加粗/颜色/对齐。幻灯片比例与 .pptx 一致。
class PptxSlideView extends StatelessWidget {
  const PptxSlideView({super.key, required this.slide});

  final PptSlideData slide;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final w = constraints.maxWidth;
      final h = constraints.maxHeight;
      final slideRatio = slide.wEmu / slide.hEmu;
      final boxRatio = w / h;
      double renderW, renderH;
      if (slideRatio > boxRatio) {
        renderW = w;
        renderH = w / slideRatio;
      } else {
        renderH = h;
        renderW = h * slideRatio;
      }
      final pxPerEmu = renderW / slide.wEmu;
      // 无位置信息的形状：集中到一个左上角线性布局，避免互相重叠
      final fallback = <Widget>[];
      final children = <Widget>[
        const Positioned.fill(child: ColoredBox(color: Colors.white)),
      ];
      for (final img in slide.images) {
        children.add(Positioned(
          left: img.x * pxPerEmu,
          top: img.y * pxPerEmu,
          width: img.w * pxPerEmu,
          height: img.h * pxPerEmu,
          child: Image.memory(img.bytes, fit: BoxFit.fill),
        ));
      }
      for (final box in slide.boxes) {
        if (box.hasPos) {
          children.add(_box(box, pxPerEmu));
        } else {
          fallback.addAll(_fallbackLines(box, pxPerEmu));
        }
      }
      if (fallback.isNotEmpty) {
        children.add(Positioned(
          left: 8,
          top: 8,
          child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: fallback),
        ));
      }
      Widget canvas = SizedBox(
        width: renderW,
        height: renderH,
        child: Stack(children: children),
      );
      return Center(child: canvas);
    });
  }

  // 1pt = 12700 EMU；字号 pt→px
  double? _sizePxOf(PptTextBox _, double? pt, double pxPerEmu) =>
      pt == null ? null : pt * 12700 * pxPerEmu;

  List<Widget> _fallbackLines(PptTextBox box, double pxPerEmu) => [
        for (final para in box.paras)
          Text(
            para.text,
            maxLines: 6,
            overflow: TextOverflow.clip,
            style: TextStyle(
              fontSize: math.max(
                  _sizePxOf(box, para.sizePt, pxPerEmu) ?? 18 * 12700 * pxPerEmu,
                  6),
              fontWeight:
                  para.bold ? FontWeight.bold : FontWeight.normal,
              color: para.color == null
                  ? Colors.black
                  : Color(0xFF000000 | para.color!),
            ),
          ),
      ];

  Widget _box(PptTextBox box, double pxPerEmu) {
    final children = <Widget>[];
    for (final para in box.paras) {
      final align = switch (para.align) {
        'ctr' => TextAlign.center,
        'r' => TextAlign.right,
        _ => TextAlign.left,
      };
      children.add(Text(
        para.text,
        textAlign: align,
        maxLines: 6,
        overflow: TextOverflow.clip,
        style: TextStyle(
          fontSize: math.max(
              _sizePxOf(box, para.sizePt, pxPerEmu) ?? 18 * 12700 * pxPerEmu,
              6),
          fontWeight: para.bold ? FontWeight.bold : FontWeight.normal,
          color: para.color == null ? Colors.black : Color(0xFF000000 | para.color!),
        ),
      ));
    }

    Widget content = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
    return Positioned(
      left: box.x * pxPerEmu,
      top: box.y * pxPerEmu,
      width: math.max(box.w * pxPerEmu, 8),
      height: math.max(box.h * pxPerEmu, 8),
      child: Align(
        alignment: Alignment.topLeft,
        child: OverflowBox(
          maxWidth: double.infinity,
          alignment: Alignment.topLeft,
          child: content,
        ),
      ),
    );
  }
}
