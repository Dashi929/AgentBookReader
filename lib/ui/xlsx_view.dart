import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/parser/xlsx_extractor.dart';

/// Excel 网格视图：近似 Office 视觉——列标/行号表头、网格线、
/// 合并单元格、列宽/行高、加粗与对齐、数字右对齐。可双向滚动。
class XlsxSheetView extends StatelessWidget {
  const XlsxSheetView(
      {super.key, required this.sheet, this.scale = 1.2, this.verticalScroll = true});

  final XlsxSheetData sheet;
  final double scale; // 字符宽度→像素
  final bool verticalScroll; // false：纵向由外部滚动容器接管（连续模式）

  static const _rowHeadW = 44.0;
  static const _colHeadH = 22.0;

  double _colPx(int i) =>
      (i < sheet.colWidths.length ? sheet.colWidths[i] : 8.43) * 7.5 + 5;
  double _rowPx(int i) =>
      (i < sheet.rowHeights.length ? sheet.rowHeights[i] : 15) * 4 / 3 + 2;

  /// 网格内容总高（含列标表头），供连续模式计算累计偏移。
  static double contentHeight(XlsxSheetData sheet) {
    var h = _colHeadH;
    for (var i = 0; i < math.max(sheet.rows, 1); i++) {
      h += (i < sheet.rowHeights.length ? sheet.rowHeights[i] : 15) * 4 / 3 + 2;
    }
    return h;
  }

  double _totalW() => [
        for (var i = 0; i < math.max(sheet.cols, 1); i++) _colPx(i)
      ].fold<double>(0, (a, b) => a + b);
  double _totalH() => [
        for (var i = 0; i < math.max(sheet.rows, 1); i++) _rowPx(i)
      ].fold<double>(0, (a, b) => a + b);

  @override
  Widget build(BuildContext context) {
    final totalW = _totalW();
    final totalH = _totalH();
    final grid = SizedBox(
      width: _rowHeadW + totalW,
      height: _colHeadH + totalH,
      child: CustomPaint(
        size: Size(_rowHeadW + totalW, _colHeadH + totalH),
        painter: _XlsxGridPainter(this),
      ),
    );
    if (!verticalScroll) {
      return SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: grid,
      );
    }
    return SingleChildScrollView(
      scrollDirection: Axis.vertical,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: grid,
      ),
    );
  }
}

class _XlsxGridPainter extends CustomPainter {
  _XlsxGridPainter(this.view);

  final XlsxSheetView view;
  static const _grid = Color(0xFFD0D0D0);
  static const _headBg = Color(0xFFF0F0F0);
  static const _headLine = Color(0xFFB8B8B8);

  @override
  void paint(Canvas canvas, Size size) {
    final sheet = view.sheet;
    final x0 = XlsxSheetView._rowHeadW;
    final y0 = XlsxSheetView._colHeadH;

    // 列/行偏移表
    final colX = <double>[0];
    for (var i = 0; i < sheet.cols; i++) {
      colX.add(colX[i] + view._colPx(i));
    }
    final rowY = <double>[0];
    for (var i = 0; i < sheet.rows; i++) {
      rowY.add(rowY[i] + view._rowPx(i));
    }

    // 网格区铺白底（阅读主题背景是米黄/深色，Excel 表体应为白色）
    canvas.drawRect(
        Rect.fromLTWH(0, 0, size.width, size.height), Paint()..color = Colors.white);

    // 网格线
    final gridPaint = Paint()
      ..color = _grid
      ..strokeWidth = 0.7;
    for (var i = 0; i <= sheet.cols; i++) {
      canvas.drawLine(Offset(x0 + colX[i], y0), Offset(x0 + colX[i], y0 + rowY.last), gridPaint);
    }
    for (var i = 0; i <= sheet.rows; i++) {
      canvas.drawLine(Offset(x0, y0 + rowY[i]), Offset(x0 + colX.last, y0 + rowY[i]), gridPaint);
    }

    // 表头
    final headBg = Paint()..color = _headBg;
    canvas.drawRect(Rect.fromLTWH(0, 0, x0 + colX.last, y0), headBg);
    canvas.drawRect(Rect.fromLTWH(0, 0, x0, y0 + rowY.last), headBg);
    final headLine = Paint()
      ..color = _headLine
      ..strokeWidth = 1;
    canvas.drawLine(Offset(0, y0), Offset(x0 + colX.last, y0), headLine);
    canvas.drawLine(Offset(x0, 0), Offset(x0, y0 + rowY.last), headLine);
    for (var i = 0; i < sheet.cols; i++) {
      _text(canvas, _colName(i),
          Rect.fromLTWH(x0 + colX[i], 0, view._colPx(i), y0),
          fontSize: 10,
          color: const Color(0xFF444444),
          align: TextAlign.center,
          vCenter: true);
    }
    for (var i = 0; i < sheet.rows; i++) {
      _text(canvas, '${i + 1}', Rect.fromLTWH(0, y0 + rowY[i], x0, view._rowPx(i)),
          fontSize: 10,
          color: const Color(0xFF444444),
          align: TextAlign.right,
          vCenter: true,
          padding: 4);
    }

    // 合并区域底色（盖住网格线）+ 边框
    final fill = Paint()..color = Colors.white;
    final border = Paint()
      ..color = _grid
      ..strokeWidth = 0.7;
    for (final m in sheet.merges) {
      final rect = Rect.fromLTRB(x0 + colX[m[1]], y0 + rowY[m[0]],
          x0 + colX[m[3] + 1], y0 + rowY[m[2] + 1]);
      canvas.drawRect(rect.deflate(0.4), fill);
      canvas.drawRect(rect.deflate(0.4), border..style = PaintingStyle.stroke);
    }

    // 单元格文本（合并区域只画锚点）
    final mergedAnchors = <List<int>>{
      for (final m in sheet.merges) [m[0], m[1]],
    };
    sheet.cells.forEach((r, colsMap) {
      colsMap.forEach((c, cell) {
        if (mergedAnchors.contains([r, c]) && c > 0) return;
        var span = 1;
        for (final m in sheet.merges) {
          if (m[0] == r && m[1] == c) {
            span = m[3] - m[1] + 1;
          }
        }
        final w =
            [for (var i = c; i < c + span && i < sheet.cols; i++) view._colPx(i)]
                .fold<double>(0, (a, b) => a + b);
        final h = view._rowPx(r);
        final align = switch (cell.align.isEmpty ? (cell.number ? 'right' : 'left') : cell.align) {
          'center' => TextAlign.center,
          'right' => TextAlign.right,
          _ => TextAlign.left,
        };
        _text(canvas, cell.text,
            Rect.fromLTWH(x0 + colX[c], y0 + rowY[r], w, h),
            fontSize: 12 * view.scale,
            color: Colors.black,
            bold: cell.bold,
            align: align,
            vCenter: true);
      });
    });
  }

  String _colName(int i) {
    var n = i + 1;
    var s = '';
    while (n > 0) {
      n--;
      s = String.fromCharCode(65 + n % 26) + s;
      n ~/= 26;
    }
    return s;
  }

  void _text(Canvas canvas, String text, Rect rect,
      {required double fontSize,
      required Color color,
      bool bold = false,
      TextAlign align = TextAlign.left,
      bool vCenter = false,
      double padding = 3}) {
    final tp = TextPainter(
        text: TextSpan(
            text: text,
            style: TextStyle(
                fontSize: fontSize, color: color, fontWeight: bold ? FontWeight.bold : null)),
        textDirection: TextDirection.ltr,
        maxLines: 1,
        ellipsis: '…')
      ..layout(maxWidth: math.max(rect.width - padding * 2, 1));
    final dy = vCenter ? (rect.height - tp.height) / 2 : padding;
    final dx = switch (align) {
      TextAlign.center => (rect.width - tp.width) / 2,
      TextAlign.right => rect.width - tp.width - padding,
      _ => padding,
    };
    tp.paint(canvas, Offset(rect.left + dx, rect.top + math.max(dy, 1)));
  }

  @override
  bool shouldRepaint(covariant _XlsxGridPainter oldDelegate) =>
      oldDelegate.view.sheet != view.sheet;
}
