/// 全局动作注册表：让托盘菜单 / 快捷键能调用界面里的动作
class AppActions {
  AppActions._();

  static void Function()? createNote;
  static void Function()? focusSearch;
  static void Function()? openSettings;
  static void Function()? showWindow;
}
