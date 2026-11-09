# 桌面版构建

```bash
flutter pub get
flutter build windows --release
```

产物：`build/windows/x64/runner/Release/`。

需要：Flutter 3.x（启用 Windows 桌面支持）、Visual Studio 2022 Build Tools
（"使用 C++ 的桌面开发"工作负载）、Windows 10/11 SDK。

运行时数据目录为可执行文件同级的 `notes-data/`，首次运行自动创建。
字体为可选项，详见 `assets/fonts/README.md`。
