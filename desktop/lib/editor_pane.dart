import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:nativeapi/nativeapi.dart' as na;

import '../app_style.dart';
import '../db.dart';
import '../sync.dart';

class EditorPane extends StatefulWidget {
  final String noteId;
  final VoidCallback onChanged;
  final VoidCallback onClose;
  const EditorPane({
    super.key,
    required this.noteId,
    required this.onChanged,
    required this.onClose,
  });

  @override
  State<EditorPane> createState() => _EditorPaneState();
}

class _EditorPaneState extends State<EditorPane> {
  Note? note;
  final TextEditingController _ctrl = TextEditingController();
  bool _loading = true;
  bool _preview = false;
  Timer? _saveTimer;
  // 用户是否手动动过标题：没动过时用正文开头自动当标题
  bool _titleTouched = false;
  bool _suppressTitle = false;
  final TextEditingController _titleCtrl = TextEditingController();
  final FocusNode _titleFocus = FocusNode();
  final FocusNode _bodyFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    // 标题控制器只创建一次（旧实现放在 build 里，导致标题无法正常修改/删除）
    _titleCtrl.addListener(() {
      if (_suppressTitle) return;
      _titleTouched = true;
      final n = note;
      if (n == null) return;
      if (n.title != _titleCtrl.text) {
        n.title = _titleCtrl.text;
        _scheduleSave();
      }
    });
    _load();
  }

  @override
  void didUpdateWidget(covariant EditorPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.noteId != widget.noteId) {
      _saveTimer?.cancel();
      note = null;
      _loading = true;
      _load();
    }
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    _save();
    _titleCtrl.dispose();
    _titleFocus.dispose();
    _bodyFocus.dispose();
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final n = await NotesDb.getNote(widget.noteId);
    if (!mounted) return;
    note = n;
    _loading = false;
    if (n != null) {
      if (_titleCtrl.text != n.title) _titleCtrl.text = n.title;
      if (_ctrl.text != n.body) _ctrl.text = n.body;
      final isNew = n.title.trim().isEmpty && n.body.trim().isEmpty;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (isNew) {
          _titleFocus.requestFocus();
          _titleCtrl.selection =
              TextSelection.collapsed(offset: _titleCtrl.text.length);
        } else {
          _ctrl.selection = TextSelection.collapsed(offset: _ctrl.text.length);
        }
      });
    }
    setState(() {});
  }

  void _save() {
    final n = note;
    if (n == null) return;
    n.title = _titleCtrl.text;
    n.body = _ctrl.text;
    n.plainText = NotesDb.markdownToPlainText(n.body);
    // 正文开头几个字自动成为标题（仅当用户没有手动编辑过标题）
    if (!_titleTouched && n.title.trim().isEmpty) {
      final derived = NotesDb.deriveTitle(n.body);
      if (derived.isNotEmpty) {
        n.title = derived;
        _suppressTitle = true;
        _titleCtrl.text = derived;
        _titleCtrl.selection =
            TextSelection.collapsed(offset: derived.length);
        _suppressTitle = false;
      }
    }
    NotesDb.updateNote(n).catchError((e) {
      return null;
    });
    SyncService.i.markDirty();
  }

  void _saveNow() {
    final n = note;
    if (n == null) return;
    _save();
    NotesDb.getNote(n.id).then((_) {
      if (mounted) widget.onChanged();
    }).catchError((e) {});
  }

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 500), _saveNow);
  }

  // ---------- 文件选择（nativeapi 原生对话框） ----------

  Future<String?> _pickFile(
      {List<String> extensions = const [], bool save = false, String suggested = ''}) async {
    final dialog =
        na.FileDialog.create(save ? na.FileDialogMode.saveFile : na.FileDialogMode.openFile);
    if (dialog == null) return null;
    if (extensions.isNotEmpty) dialog.setFileTypes(extensions);
    if (save && suggested.isNotEmpty) dialog.setSuggestedFileName(suggested);
    dialog.open();
    final result = dialog.result;
    final paths = dialog.paths;
    dialog.dispose();
    if (result == na.FileDialogResult.accepted && paths.isNotEmpty) {
      return paths.first;
    }
    return null;
  }

  Future<void> _insertImage() async {
    final path = await _pickFile(
        extensions: const ['png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp']);
    if (path == null) return;
    try {
      final ref = await NotesDb.saveAttachment(path);
      final t = _ctrl.text;
      final idx = _ctrl.selection.baseOffset;
      final insert = '![]($ref)';
      _ctrl.value = TextEditingValue(
        text: t.replaceRange(idx, idx, '\n$insert\n'),
        selection: TextSelection.collapsed(offset: idx + insert.length + 3),
      );
      _scheduleSave();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('插入图片失败：$e')));
      }
    }
  }

  Future<void> _showImages() async {
    final refs = RegExp(r'!\[[^\]]*\]\(([^)\s]+)\)')
        .allMatches(_ctrl.text)
        .map((m) => m.group(1)!)
        .toList();
    if (!mounted) return;
    if (refs.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('当前笔记里还没有图片')));
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (b) => AlertDialog(
        title: const Text('看图',
            style: TextStyle(
                fontFamily: FZ_FONT,
                fontSize: 18,
                fontWeight: FontWeight.bold)),
        content: SizedBox(
          width: 640,
          height: 420,
          child: ListView.separated(
            itemCount: refs.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (_, i) => Padding(
              padding: const EdgeInsets.all(10),
              child: _imageForRef(refs[i]),
            ),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(b).pop(),
              child: const Text('关闭',
                  style: TextStyle(fontFamily: FZ_FONT, fontSize: 15))),
        ],
      ),
    );
  }

  Widget _imageForRef(String ref) {
    try {
      if (ref.startsWith('mynotes://')) {
        final f = File(NotesDb.resolveAttachment(ref));
        return f.existsSync()
            ? Image.file(f, fit: BoxFit.contain)
            : Text('图片不存在：$ref',
                style: const TextStyle(fontFamily: FZ_FONT, fontSize: 14));
      }
      if (ref.startsWith('http')) {
        return Image.network(ref, fit: BoxFit.contain,
            errorBuilder: (_, __, ___) => Text('图片无法加载：$ref',
                style: const TextStyle(fontFamily: FZ_FONT, fontSize: 14)));
      }
      final f = File(ref);
      return f.existsSync()
          ? Image.file(f, fit: BoxFit.contain)
          : Text('图片不存在：$ref',
              style: const TextStyle(fontFamily: FZ_FONT, fontSize: 14));
    } catch (_) {
      return Text('图片无法加载：$ref',
          style: const TextStyle(fontFamily: FZ_FONT, fontSize: 14));
    }
  }

  Future<void> _importMd() async {
    final path = await _pickFile(extensions: const ['md', 'markdown', 'txt']);
    if (path == null) return;
    try {
      final text = await File(path).readAsString();
      _ctrl.text = text;
      _saveNow();
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('已导入 Markdown')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('导入失败：$e')));
      }
    }
  }

  Future<void> _exportMd() async {
    final fileName = (note?.title.isNotEmpty == true ? note!.title : '未命名笔记')
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    final path = await _pickFile(
        extensions: const ['md'], save: true, suggested: '$fileName.md');
    if (path == null) return;
    try {
      // 把 mynotes:// 附件引用换成导出目录下的绝对路径
      final parts = _ctrl.text.split(RegExp(r'mynotes://attach/([^)]+)'));
      final out = StringBuffer();
      for (var i = 0; i < parts.length; i++) {
        out.write(parts[i]);
        if (i + 1 < parts.length) {
          out.write(NotesDb.resolveAttachment('mynotes://attach/${parts[i + 1]}'));
        }
      }
      await File(path).writeAsString(out.toString());
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('已导出 Markdown')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('导出失败：$e')));
      }
    }
  }

  // ---------- 工具栏：在光标处插入 Markdown 语法 ----------

  void _wrapSelection(String prefix, String suffix) {
    final t = _ctrl.text;
    final sel = _ctrl.selection;
    if (sel.isCollapsed) {
      final idx = sel.baseOffset;
      _ctrl.value = TextEditingValue(
        text: t.replaceRange(idx, idx, '${prefix}${suffix}'),
        selection: TextSelection.collapsed(offset: idx + prefix.length),
      );
    } else {
      final start = sel.start;
      final end = sel.end;
      final selected = t.substring(start, end);
      _ctrl.value = TextEditingValue(
        text: t.replaceRange(start, end, '${prefix}$selected${suffix}'),
        selection: TextSelection.collapsed(
            offset: start + prefix.length + selected.length + suffix.length),
      );
    }
  }

  void _prefixLines(String prefix) {
    final t = _ctrl.text;
    final sel = _ctrl.selection;
    final lines = t.split('\n');
    final startLine = t.substring(0, sel.start).split('\n').length - 1;
    final endLine = t.substring(0, sel.end).split('\n').length - 1;
    for (var i = startLine; i <= endLine && i < lines.length; i++) {
      if (lines[i].isNotEmpty && !lines[i].startsWith(prefix)) {
        lines[i] = prefix + lines[i];
      }
    }
    _ctrl.value = TextEditingValue(text: lines.join('\n'), selection: sel);
  }

  Future<void> _pickTags() async {
    final all = await NotesDb.listTags();
    final selected = <String>{...await NotesDb.getTagIds(widget.noteId)};
    final newNames = <String>{};
    await showDialog<void>(
      context: context,
      builder: (b) => StatefulBuilder(
        builder: (context, setState2) {
          return AlertDialog(
            title: const Text('编辑标签'),
            content: SizedBox(
              width: 340,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    contextMenuBuilder: chineseContextMenuBuilder,
                    decoration:
                        const InputDecoration(hintText: '输入标签名，逗号分隔（自动创建）'),
                    onChanged: (v) {
                      newNames.clear();
                      newNames.addAll(v.split(',').map((s) => s.trim())
                          .where((s) => s.isNotEmpty));
                    },
                  ),
                  if (all.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: all.map((t) {
                        final sel = selected.contains(t.id);
                        return FilterChip(
                          label: Text(t.name),
                          selected: sel,
                          onSelected: (v) => setState2(() {
                            if (v) selected.add(t.id);
                            else selected.remove(t.id);
                          }),
                        );
                      }).toList(),
                    ),
                  ],
                  if (newNames.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Wrap(
                      spacing: 6,
                      children: newNames.map((nm) => FilterChip(
                              label: Text(nm),
                              selected: true,
                              onSelected: (_) {})).toList(),
                    ),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                  onPressed: () async {
                    final realNew = <String>[];
                    for (final nm in newNames) {
                      final t = await NotesDb.createTag(nm);
                      realNew.add(t.id);
                    }
                    final finalIds = [...selected.toList(), ...realNew];
                    await NotesDb.setTags(widget.noteId, finalIds);
                    final refreshed = await NotesDb.getNote(widget.noteId);
                    if (mounted) setState(() => note = refreshed);
                    Navigator.of(context).pop();
                  },
                  child: const Text('确定')),
              TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('取消')),
            ],
          );
        },
      ),
    );
  }

  Widget _toolbarSep() {
    return Container(
      width: 1,
      height: 18,
      margin: const EdgeInsets.symmetric(horizontal: 4),
      color: Colors.grey.withValues(alpha: 0.25),
    );
  }

  Widget _toolbarBtn(String label, VoidCallback onPressed, [IconData? icon]) {
    return IconButton(
      icon: Icon(icon, size: 18),
      tooltip: label,
      onPressed: onPressed,
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 32, minHeight: 30),
    );
  }

  /// 带文字的工具栏按钮：文字必须用内嵌方正宋黑，且加粗保证小字号清晰
  Widget _textToolbarBtn(String label, VoidCallback onPressed) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: TextButton(
        onPressed: onPressed,
        style: TextButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          minimumSize: const Size(0, 30),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          textStyle: const TextStyle(
              fontFamily: FZ_FONT,
              fontSize: kFontSmall,
              fontWeight: FontWeight.w600),
        ),
        child: Text(label,
            style: const TextStyle(
                fontFamily: FZ_FONT,
                fontSize: kFontSmall,
                fontWeight: FontWeight.w600)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    final n = note;
    if (n == null) {
      return const Center(child: Text('笔记不存在'));
    }
    return Scaffold(
      // 透明背景：避免与父级 Scaffold 重复整屏铺底（减少每帧绘制量）
      backgroundColor: Colors.transparent,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
                color: Theme.of(context).dividerColor,
                border: Border(bottom: BorderSide(color: Theme.of(context).dividerColor))),
            child: ValueListenableBuilder<TextEditingValue>(
              valueListenable: _titleCtrl,
              builder: (context, titleValue, _) => LayoutBuilder(builder: (context, cons) {
              // 标题框宽度按标题文字自适应：短的紧凑，长的变宽（上限 62%），
              // 这样标签/按钮紧跟在标题后面，长标题也不会被截断
              final probe = titleValue.text.isEmpty ? '标题' : titleValue.text;
              final tp = TextPainter(
                text: TextSpan(
                  text: probe,
                  style: const TextStyle(
                      fontFamily: FZ_FONT,
                      fontSize: 18,
                      fontWeight: FontWeight.bold),
                ),
                maxLines: 1,
                textDirection: TextDirection.ltr,
              )..layout();
              final maxTitleW = (cons.maxWidth * 0.62).clamp(170.0, 900.0);
              final titleW = (tp.width + 28).clamp(170.0, maxTitleW);
              return Row(
                children: [
                  SizedBox(
                    width: titleW,
                    child: TextField(
                      controller: _titleCtrl,
                      focusNode: _titleFocus,
                      contextMenuBuilder: chineseContextMenuBuilder,
                      textInputAction: TextInputAction.next,
                      onSubmitted: (_) => _bodyFocus.requestFocus(),
                      decoration: const InputDecoration(
                          hintText: '标题', border: InputBorder.none, isDense: true),
                      style: const TextStyle(
                          fontFamily: FZ_FONT,
                          fontSize: 18,
                          fontWeight: FontWeight.bold),
                    ),
                  ),
                  const SizedBox(width: 12),
                  ConstrainedBox(
                    constraints: BoxConstraints(
                        maxWidth: (cons.maxWidth - titleW - 12)
                            .clamp(0.0, double.infinity)),
                    child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        const Icon(Icons.label_outline,
                            size: 15, color: kSubTextColor),
                        const SizedBox(width: 6),
                        for (final name in n.tags)
                          Padding(
                            padding: const EdgeInsets.only(right: 6),
                            child: _tagChip(name, () async {
                              final all = await NotesDb.listTags();
                              String removeId = '';
                              for (final t in all) {
                                if (t.name == name) removeId = t.id;
                              }
                              final ids = (await NotesDb.getTagIds(widget.noteId))
                                ..remove(removeId);
                              await NotesDb.setTags(widget.noteId, ids);
                              final refreshed = await NotesDb.getNote(widget.noteId);
                              if (mounted) setState(() => note = refreshed);
                            }),
                          ),
                        _tagAddChip(),
                        const SizedBox(width: 12),
                        ValueListenableBuilder<TextEditingValue>(
                          valueListenable: _ctrl,
                          builder: (context, value, child) => Text(
                              '${value.text.length} 字',
                              style: const TextStyle(
                                  fontSize: kFontSmall, color: kSubTextColor)),
                        ),
                        const SizedBox(width: 10),
                        SegmentedButton<bool>(
                          segments: const [
                            ButtonSegment(value: false, label: Text('编辑')),
                            ButtonSegment(value: true, label: Text('预览')),
                          ],
                          selected: {_preview},
                          onSelectionChanged: (s) =>
                              setState(() => _preview = s.first),
                          style: const ButtonStyle(
                            visualDensity: VisualDensity.compact,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            textStyle: WidgetStatePropertyAll(TextStyle(
                                fontFamily: FZ_FONT,
                                fontSize: kFontSmall,
                                fontWeight: FontWeight.w600)),
                            padding: WidgetStatePropertyAll(
                                EdgeInsets.symmetric(horizontal: 10)),
                            minimumSize: WidgetStatePropertyAll(Size(0, 30)),
                          ),
                        ),
                        const SizedBox(width: 4),
                        IconButton(
                            icon: const Icon(Icons.push_pin, size: 18),
                            tooltip: n.pinned ? '取消置顶' : '置顶',
                            visualDensity: VisualDensity.compact,
                            onPressed: () async {
                              n.pinned = !n.pinned;
                              await NotesDb.updateNote(n);
                              widget.onChanged();
                            }),
                        IconButton(
                            icon: const Icon(Icons.delete_outline, size: 18),
                            tooltip: '删除到回收站',
                            visualDensity: VisualDensity.compact,
                            onPressed: () async {
                              await NotesDb.softDelete(widget.noteId);
                              widget.onChanged();
                              widget.onClose();
                            }),
                      ],
                    ),
                  ),
                ),
              ],
            );
            }),
            ),
          ),
          Container(
            padding: const EdgeInsets.fromLTRB(10, 4, 10, 4),
            color: Theme.of(context).dividerColor,
            child: Wrap(
              spacing: 4,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                // —— 格式工具栏 ——
                _toolbarBtn('粗体', () => _wrapSelection('**', '**'), Icons.format_bold),
                _toolbarBtn('斜体', () => _wrapSelection('*', '*'), Icons.format_italic),
                _toolbarBtn('删除线', () => _wrapSelection('~~', '~~'),
                    Icons.format_strikethrough_rounded),
                _toolbarBtn('行内代码', () => _wrapSelection('`', '`'), Icons.code),
                _toolbarSep(),
                _toolbarBtn('一级标题', () => _prefixLines('# '), Icons.looks_one),
                _toolbarBtn('二级标题', () => _prefixLines('## '), Icons.looks_two),
                _toolbarBtn('三级标题', () => _prefixLines('### '), Icons.title),
                _toolbarSep(),
                _toolbarBtn('引用', () => _prefixLines('> '), Icons.format_quote),
                _toolbarBtn('无序列表', () => _prefixLines('- '), Icons.format_list_bulleted),
                _toolbarBtn('有序列表', () => _prefixLines('1. '), Icons.list),
                _toolbarBtn('分割线', () {
                  final idx = _ctrl.selection.baseOffset;
                  _ctrl.value = TextEditingValue(
                    text: _ctrl.text.replaceRange(idx, idx, '\n---\n'),
                    selection: TextSelection.collapsed(offset: idx + 6),
                  );
                }, Icons.horizontal_rule),
                _toolbarSep(),
                _toolbarBtn('链接', () async {
                  final ctrl = TextEditingController();
                  await showDialog(
                    context: context,
                    builder: (b) => AlertDialog(
                      title: const Text('插入链接'),
                      content: TextField(
                          controller: ctrl,
                          contextMenuBuilder: chineseContextMenuBuilder,
                          decoration: const InputDecoration(hintText: 'https://')),
                      actions: [
                        TextButton(
                            onPressed: () {
                              if (ctrl.text.trim().isNotEmpty) {
                                _wrapSelection('[', '](${ctrl.text.trim()})');
                              }
                              Navigator.of(context).pop();
                            },
                            child: const Text('插入')),
                        TextButton(onPressed: () => Navigator.of(context).pop(),
                            child: const Text('取消')),
                      ],
                    ),
                  );
                }, Icons.insert_link),
                _toolbarBtn('插入图片', _insertImage, Icons.image),
                _textToolbarBtn('看图', _showImages),
                _toolbarSep(),
                _toolbarBtn('导入 Markdown', _importMd, Icons.upload_file),
                _toolbarBtn('导出 Markdown', _exportMd, Icons.download),
              ],
            ),
          ),
          Expanded(
            child: _preview
                ? _PreviewWidget(md: _ctrl.text)
                : TextField(
                    controller: _ctrl,
                    focusNode: _bodyFocus,
                    contextMenuBuilder: chineseContextMenuBuilder,
                    expands: true,
                    textAlignVertical: TextAlignVertical.top,
                    maxLines: null,
                    minLines: null,
                    style: const TextStyle(
                        fontFamily: FZ_FONT,
                        fontSize: 16,
                        fontWeight: FontWeight.w500,
                        height: 1.8),
                    decoration: const InputDecoration(
                        border: InputBorder.none,
                        isDense: true,
                        contentPadding:
                            EdgeInsets.symmetric(horizontal: 16, vertical: 12)),
                    onChanged: (_) => _scheduleSave(),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _tagChip(String id, VoidCallback onRemove) {
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 4, 6, 4),
      decoration: BoxDecoration(
          color: const Color(0xFFE8EBF9), borderRadius: BorderRadius.circular(10)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('#', style: TextStyle(fontSize: 13, color: Color(0xFF4A5EE5))),
          Text(id, style: const TextStyle(fontSize: kFontSmall)),
          const SizedBox(width: 4),
          GestureDetector(
            onTap: onRemove,
            child: const Icon(Icons.close, size: 13, color: kSubTextColor),
          ),
        ],
      ),
    );
  }

  Widget _tagAddChip() {
    return InkWell(
      onTap: _pickTags,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        decoration: BoxDecoration(
          border: Border.all(color: Colors.grey.withValues(alpha: 0.35)),
          borderRadius: BorderRadius.circular(10),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.add, size: 13, color: kSubTextColor),
            SizedBox(width: 3),
            Text('标签', style: TextStyle(fontSize: kFontSmall, color: kSubTextColor)),
          ],
        ),
      ),
    );
  }
}

class _PreviewWidget extends StatelessWidget {
  final String md;
  const _PreviewWidget({required this.md});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Theme.of(context).scaffoldBackgroundColor,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Markdown(
        data: md,
        styleSheet: MarkdownStyleSheet(
          h1: TextStyle(
              fontFamily: FZ_FONT, fontSize: 28, fontWeight: FontWeight.bold),
          h2: TextStyle(
              fontFamily: FZ_FONT, fontSize: 24, fontWeight: FontWeight.bold),
          h3: TextStyle(
              fontFamily: FZ_FONT, fontSize: 20, fontWeight: FontWeight.bold),
          p: TextStyle(
              fontFamily: FZ_FONT,
              fontSize: 16,
              fontWeight: FontWeight.w500,
              height: 1.7),
          a: TextStyle(fontFamily: FZ_FONT, color: const Color(0xFF4A5EE5)),
          strong: TextStyle(fontFamily: FZ_FONT, fontWeight: FontWeight.bold),
          em: TextStyle(fontFamily: FZ_FONT, fontStyle: FontStyle.italic),
          code: TextStyle(fontFamily: FZ_FONT, fontSize: 16, height: 1.5),
          blockquote: TextStyle(
              fontFamily: FZ_FONT,
              fontSize: 16,
              fontWeight: FontWeight.w500,
              color: const Color(0xFF465264)),
        ),
        imageBuilder: (uri, title, alt) => _buildImage(uri),
      ),
    );
  }

  Widget _buildImage(Uri uri) {
    try {
      if (uri.scheme == 'mynotes' && uri.host == 'attach') {
        final file = File(NotesDb.resolveAttachment(uri.toString()));
        if (file.existsSync()) {
          return Image.file(file, fit: BoxFit.contain);
        }
        return _brokenWidget(uri);
      }
      if (uri.scheme == 'data') {
        final b64 = uri.fragment.isNotEmpty ? uri.fragment : uri.path.substring(5);
        final bytes = base64Decode(Uri.decodeQueryComponent(b64));
        return Image.memory(bytes, fit: BoxFit.contain);
      }
      if (uri.scheme == 'file') {
        final file = File(uri.toFilePath());
        if (file.existsSync()) return Image.file(file, fit: BoxFit.contain);
      }
      return _brokenWidget(uri);
    } catch (_) {
      return _brokenWidget(uri);
    }
  }

  Widget _brokenWidget(Uri uri) {
    return Container(
      padding: const EdgeInsets.all(8),
      color: Colors.red.withValues(alpha: 0.1),
      child: Text('图片无法加载：$uri',
          style: const TextStyle(
              fontFamily: FZ_FONT,
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: Colors.red)),
    );
  }
}

String formatTimeShort(int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  final sameDay =
      d.day == DateTime.now().day && d.month == DateTime.now().month;
  if (sameDay) {
    return '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }
  return '${d.month.toString().padLeft(2, '0')}/${d.day.toString().padLeft(2, '0')} ' +
      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
}
