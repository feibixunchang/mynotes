import 'package:flutter/material.dart';

/// 方正宋黑（GBK 内嵌）为全局唯一字体
const String FZ_FONT = 'FangZhengSongHei';

/// 小字统一加深：宋黑细笔画在浅灰、小字号下会发虚，
/// 这里把次级文字压到接近正文的深色，保证与列表标题一样锐利。
const Color kTextColor = Color(0xFF1F2430);
const Color kSubTextColor = Color(0xFF374151);
const Color kHintColor = Color(0xFF465264);

/// 全局小字字号提档 + 默认字重 w500（宋黑细笔画加粗后才不发虚）
const double kFontTiny = 14.0;
const double kFontSmall = 15.0;
const double kFontNormal = 16.0;

/// 全界面默认文字样式：所有未显式写 fontFamily / fontWeight 的 Text
/// 都会通过 DefaultTextStyle.merge 继承它，彻底杜绝「某个按钮不是宋黑」。
const TextStyle kDefaultTextStyle = TextStyle(
  fontFamily: FZ_FONT,
  fontSize: 15,
  fontWeight: FontWeight.w500,
  color: kTextColor,
  height: 1.25,
);

const TextStyle kDefaultTextStyleDark = TextStyle(
  fontFamily: FZ_FONT,
  fontSize: 15,
  fontWeight: FontWeight.w500,
  color: Color(0xFFE7EAF3),
  height: 1.25,
);

ThemeData lightTheme() {
  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.light,
    fontFamily: FZ_FONT,
    colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF4A5EE5), brightness: Brightness.light),
    scaffoldBackgroundColor: const Color(0xFFF4F5F9),
    dividerColor: const Color(0xFFE3E6EE),
    splashFactory: NoSplash.splashFactory,
    tooltipTheme: TooltipThemeData(
      textStyle: const TextStyle(
          fontFamily: FZ_FONT,
          fontSize: 14,
          fontWeight: FontWeight.w500,
          color: Colors.white),
      decoration: BoxDecoration(
          color: const Color(0xFF232838),
          borderRadius: BorderRadius.circular(6)),
    ),
    inputDecorationTheme: const InputDecorationTheme(
      hintStyle: TextStyle(
          fontFamily: FZ_FONT,
          fontSize: 15,
          fontWeight: FontWeight.w500,
          color: Color(0xFF5A6474)),
      labelStyle: TextStyle(fontFamily: FZ_FONT, fontSize: 15),
    ),
    textTheme: ThemeData.light().textTheme.apply(fontFamily: FZ_FONT),
  );
}

ThemeData darkTheme() {
  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    fontFamily: FZ_FONT,
    colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF4A5EE5), brightness: Brightness.dark),
    scaffoldBackgroundColor: const Color(0xFF1B1E2A),
    dividerColor: const Color(0xFF2E3346),
    splashFactory: NoSplash.splashFactory,
    tooltipTheme: TooltipThemeData(
      textStyle: const TextStyle(
          fontFamily: FZ_FONT,
          fontSize: 14,
          fontWeight: FontWeight.w500,
          color: Colors.white),
      decoration: BoxDecoration(
          color: const Color(0xFF0E1119),
          borderRadius: BorderRadius.circular(6)),
    ),
    inputDecorationTheme: const InputDecorationTheme(
      hintStyle: TextStyle(
          fontFamily: FZ_FONT,
          fontSize: 15,
          fontWeight: FontWeight.w500,
          color: Color(0xFFB6BDD0)),
      labelStyle: TextStyle(fontFamily: FZ_FONT, fontSize: 15),
    ),
    textTheme: ThemeData.dark().textTheme.apply(fontFamily: FZ_FONT),
  );
}

/// 中文文本选择右键菜单。
/// Flutter 桌面端默认按 en_US 本地化，右键会显示 Cut/Copy/Paste/Select all；
/// AdaptiveTextSelectionToolbar 会优先使用 buttonItem.label，所以这里显式给
/// 每个按钮设置中文标签，保证任何系统语言下都是中文。
const Map<ContextMenuButtonType, String> kChineseContextLabels =
    <ContextMenuButtonType, String>{
  ContextMenuButtonType.cut: '剪切',
  ContextMenuButtonType.copy: '复制',
  ContextMenuButtonType.paste: '粘贴',
  ContextMenuButtonType.selectAll: '全选',
  ContextMenuButtonType.delete: '删除',
  ContextMenuButtonType.lookUp: '查询',
  ContextMenuButtonType.searchWeb: '在网上搜索',
  ContextMenuButtonType.share: '分享',
  ContextMenuButtonType.liveTextInput: '扫描文字',
  ContextMenuButtonType.custom: '更多',
};

Widget chineseContextMenuBuilder(
    BuildContext context, EditableTextState state) {
  return AdaptiveTextSelectionToolbar.buttonItems(
    anchors: state.contextMenuAnchors,
    buttonItems: state.contextMenuButtonItems
        .map((ContextMenuButtonItem item) => ContextMenuButtonItem(
              type: item.type,
              onPressed: item.onPressed,
              label: kChineseContextLabels[item.type] ?? item.label,
            ))
        .toList(),
  );
}
