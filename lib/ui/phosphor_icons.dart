import 'package:flutter/widgets.dart';

/// Phosphor 图标（Regular 线稿风格）的本地子集。
///
/// 为什么不用 `phosphor_flutter` 包：它把 `IconData` 子类化，而本项目的
/// Flutter 版本已把 `IconData` 标成 final，编译直接失败。这里改为
/// 「自带字体 + 常量码点」，只保留实际用到的图标。
class PhosphorIconsRegular {
  PhosphorIconsRegular._();

  static const IconData archive = IconData(0xe00c, fontFamily: 'Phosphor');
  static const IconData arrowClockwise = IconData(0xe036, fontFamily: 'Phosphor');
  static const IconData arrowDown = IconData(0xe03e, fontFamily: 'Phosphor');
  static const IconData caretDown = IconData(0xe136, fontFamily: 'Phosphor');
  static const IconData caretRight = IconData(0xe13a, fontFamily: 'Phosphor');
  static const IconData caretUp = IconData(0xe13c, fontFamily: 'Phosphor');
  static const IconData chartBar = IconData(0xe150, fontFamily: 'Phosphor');
  static const IconData checkCircle = IconData(0xe184, fontFamily: 'Phosphor');
  static const IconData checkSquare = IconData(0xe186, fontFamily: 'Phosphor');
  static const IconData clockCounterClockwise = IconData(0xe1a0, fontFamily: 'Phosphor');
  static const IconData cloudArrowDown = IconData(0xe1ac, fontFamily: 'Phosphor');
  static const IconData cloudArrowUp = IconData(0xe1ae, fontFamily: 'Phosphor');
  static const IconData copy = IconData(0xe1ca, fontFamily: 'Phosphor');
  static const IconData downloadSimple = IconData(0xe20c, fontFamily: 'Phosphor');
  static const IconData file = IconData(0xe230, fontFamily: 'Phosphor');
  static const IconData fileText = IconData(0xe23a, fontFamily: 'Phosphor');
  static const IconData flask = IconData(0xe79e, fontFamily: 'Phosphor');
  static const IconData floppyDisk = IconData(0xe248, fontFamily: 'Phosphor');
  static const IconData folderOpen = IconData(0xe256, fontFamily: 'Phosphor');
  static const IconData folderSimpleMinus = IconData(0xe25c, fontFamily: 'Phosphor');
  static const IconData gauge = IconData(0xe628, fontFamily: 'Phosphor');
  static const IconData gear = IconData(0xe270, fontFamily: 'Phosphor');
  static const IconData hardDrives = IconData(0xe2a0, fontFamily: 'Phosphor');
  static const IconData hourglass = IconData(0xe2b2, fontFamily: 'Phosphor');
  static const IconData house = IconData(0xe2c2, fontFamily: 'Phosphor');
  static const IconData link = IconData(0xe2e2, fontFamily: 'Phosphor');
  static const IconData listBullets = IconData(0xe2f2, fontFamily: 'Phosphor');
  static const IconData paperPlaneRight = IconData(0xe396, fontFamily: 'Phosphor');
  static const IconData path = IconData(0xe39c, fontFamily: 'Phosphor');
  static const IconData play = IconData(0xe3d0, fontFamily: 'Phosphor');
  static const IconData pulse = IconData(0xe000, fontFamily: 'Phosphor');
  static const IconData stack = IconData(0xe466, fontFamily: 'Phosphor');
  static const IconData timer = IconData(0xe492, fontFamily: 'Phosphor');
  static const IconData trash = IconData(0xe4a6, fontFamily: 'Phosphor');
  static const IconData tray = IconData(0xe4aa, fontFamily: 'Phosphor');
  static const IconData uploadSimple = IconData(0xe4c0, fontFamily: 'Phosphor');
  static const IconData waveform = IconData(0xe802, fontFamily: 'Phosphor');
  static const IconData x = IconData(0xe4f6, fontFamily: 'Phosphor');
}
