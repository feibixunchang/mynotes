# 字体说明

本应用界面默认指定 `FangZhengSongHei`（方正宋黑）。该字体为商业授权字体，
**本仓库不附带、也不分发字体文件**。

未放置字体时，`pubspec.yaml` 中没有对应的 `fonts` 声明，Flutter 会自动回退到系统默认字体，
构建与所有功能都不受影响。

如果你拥有合法授权并希望使用原字体：

1. 把 `FangZhengSongHei.ttf` 放到本目录（`desktop/assets/fonts/`）；
2. 在 `desktop/pubspec.yaml` 末尾加入：

```yaml
  fonts:
    - family: FangZhengSongHei
      fonts:
        - asset: assets/fonts/FangZhengSongHei.ttf
          weight: 400
```

3. 重新执行 `flutter pub get && flutter build windows --release`。

`*.ttf` 已被 `.gitignore` 排除，不会被误提交。
