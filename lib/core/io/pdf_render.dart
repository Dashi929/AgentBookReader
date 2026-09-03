import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:pdfrx/pdfrx.dart';

/// 渲染 PDF 单页为 PNG（宽 [width] 像素，等比高度）。
/// pdfrx 输出 RGBA，需转 RGBA8888 再编码；调用方负责 PdfDocument 生命周期。
Future<Uint8List?> renderPdfPagePng(PdfPage page, {int width = 1080}) async {
  final image = await page.render(
      fullWidth: width.toDouble(),
      fullHeight: width * page.height / page.width);
  if (image == null) return null;
  final w = image.width, h = image.height;
  final rgba = Uint8List(image.pixels.length);
  for (var i = 0; i < image.pixels.length; i += 4) {
    rgba[i] = image.pixels[i + 2];
    rgba[i + 1] = image.pixels[i + 1];
    rgba[i + 2] = image.pixels[i];
    rgba[i + 3] = image.pixels[i + 3];
  }
  image.dispose();
  final buffer = await ui.ImmutableBuffer.fromUint8List(rgba);
  final descriptor = ui.ImageDescriptor.raw(buffer,
      width: w, height: h, pixelFormat: ui.PixelFormat.rgba8888);
  final codec = await descriptor.instantiateCodec();
  final frameData = await codec.getNextFrame();
  final png = await frameData.image.toByteData(format: ui.ImageByteFormat.png);
  frameData.image.dispose();
  codec.dispose();
  descriptor.dispose();
  buffer.dispose();
  if (png == null) return null;
  return Uint8List.view(png.buffer, png.offsetInBytes, png.lengthInBytes);
}
