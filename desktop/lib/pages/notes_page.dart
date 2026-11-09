import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:nativeapi/nativeapi.dart' as na;

import '../app_actions.dart';
import '../app_style.dart';
import '../app_version.dart';
import '../db.dart';
import '../editor_pane.dart';
import '../sync.dart';
import 'settings_page.dart';

class NotesPage extends StatefulWidget {
  static void Function(String mode)? themeChanged;
  final String? initialNoteId;

  const NotesPage({super.key, this.initialNoteId});

  @override
  State<NotesPage> createState() => _NotesPageState();
}

enum View { books, trash, tag }

class _NotesPageState extends State<NotesPage> {
  List<Book> _books = [];
  List<Tag> _tags = [];
  String? _selectedBookId;
  View _view = View.books;
  String? _tagFilter;
  String _search = '';
  late final TextEditingController _searchCtrl;
  final FocusNode _searchFocus = FocusNode();
  List<Note> _notes = [];
  int _trashCount = 0;
  String? _selectedNoteId;
  Timer? _searchTimer;
  late final ValueNotifier<(double, double)> _paneWidths;

  @override
  void initState() {
    super.initState();
    _searchCtrl = TextEditingController(text: _search);
    _selectedNoteId = widget.initialNoteId;
    final lw = double.tryParse(SettingsStore.readSync('leftW', '')) ?? 230.0;
    final mw = double.tryParse(SettingsStore.readSync('midW', '')) ?? 330.0;
    _paneWidths = ValueNotifier<(double, double)>((
      lw.clamp(160.0, 420.0),
      mw.clamp(240.0, 560.0),
    ));
    // 注册全局动作（托盘菜单 / 快捷键用）
    AppActions.createNote = _createNote;
    AppActions.focusSearch = () => _searchFocus.requestFocus();
    AppActions.openSettings = _openSettings;
    _refreshBooks();
    _refreshTrashCount();
  }

  @override
  void dispose() {
    AppActions.createNote = null;
    AppActions.focusSearch = null;
    AppActions.openSettings = null;
    _searchCtrl.dispose();
    _searchFocus.dispose();
    _searchTimer?.cancel();
    _paneWidths.dispose();
    super.dispose();
  }

  Future<void> _refreshTrashCount() async {
    final r = await NotesDb.queryAll('SELECT COUNT(*) AS c FROM notes WHERE trashed = 1');
    if (mounted) setState(() => _trashCount = r.first['c'] as int);
  }

  Future<void> _refreshTags() async {
    final tags = await NotesDb.listTags();
    if (mounted) setState(() => _tags = tags);
  }

  Future<void> _refreshBooks() async {
    final books = await NotesDb.listBooks();
    if (!mounted) return;
    setState(() => _books = books);
    _applyView();
  }

  Future<void> _applyView() async {
    List<Note> notes;
    if (_search.isNotEmpty) {
      notes = await NotesDb.searchNotes(_search);
    } else if (_view == View.trash) {
      notes = await NotesDb.listNotes(null, trash: true);
      _refreshTrashCount();
    } else if (_view == View.tag && _tagFilter != null) {
      notes = await NotesDb.notesWithTag(_tagFilter!);
    } else {
      notes = await NotesDb.listNotes(_selectedBookId ?? '');
    }
    if (mounted) {
      setState(() {
        _notes = notes;
        if (_selectedNoteId != null && !notes.any((n) => n.id == _selectedNoteId)) {
          _selectedNoteId = null;
        }
      });
    }
    _refreshTags();
    _refreshTotals();
  }

  Future<void> _createNote() async {
    // 新建笔记：带完整兜底，任何情况下都返回可用笔记（修复旧版"没反应"的 bug）
    try {
      final bookId = _view == View.trash
          ? null
          : (_view == View.tag ? _tagFilter : _selectedBookId);
      final n = await NotesDb.createNote(bookId);
      SyncService.i.markDirty();
      if (!mounted) return;
      setState(() => _selectedNoteId = n.id);
      _applyView();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已新建笔记')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('新建笔记失败：$e')));
      }
    }
  }

  void _selectNote(Note n) {
    if (n.trashed) {
      setState(() => _selectedNoteId = null);
      _restore(n.id);
      return;
    }
    setState(() => _selectedNoteId = n.id);
  }

  Future<void> _restore(String id) async {
    await NotesDb.restore(id);
    SyncService.i.markDirty();
    _applyView();
    _refreshTrashCount();
    final n = await NotesDb.getNote(id);
    if (mounted && n != null) setState(() => _selectedNoteId = n.id);
  }

  Future<void> _purge(String id) async {
    await NotesDb.purge(id);
    SyncService.i.markDirty();
    _refreshTrashCount();
    if (mounted && _selectedNoteId == id) setState(() => _selectedNoteId = null);
    _applyView();
  }

  Future<void> _clearTrash() async {
    final count = _notes.length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (b) => AlertDialog(
        title: const Text('清空回收站'),
        content: Text('将永久删除回收站中的 $count 条笔记，此操作不可恢复。'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              style: TextButton.styleFrom(foregroundColor: Colors.red),
              child: const Text('清空')),
        ],
      ),
    );
    if (ok == true) {
      await NotesDb.clearTrash();
      SyncService.i.markDirty();
      _refreshTrashCount();
      _applyView();
    }
  }

  Future<void> _newBook() async {
    final ctrl = TextEditingController();
    await showDialog(
      context: context,
      builder: (b) => AlertDialog(
        title: const Text('新建笔记本'),
        content: TextField(controller: ctrl,
            contextMenuBuilder: chineseContextMenuBuilder,
            decoration: const InputDecoration(hintText: '名称')),
        actions: [
          TextButton(
              onPressed: () async {
                final name = ctrl.text.trim();
                if (name.isNotEmpty) {
                  await NotesDb.createBook(name, null, 'notebook');
                  SyncService.i.markDirty();
                  await _refreshBooks();
                }
                Navigator.of(context).pop();
              },
              child: const Text('创建')),
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('取消')),
        ],
      ),
    );
  }

  Future<void> _renameBook(Book b) async {
    final ctrl = TextEditingController(text: b.name);
    await showDialog(
      context: context,
      builder: (b2) => AlertDialog(
        title: const Text('重命名'),
        content: TextField(controller: ctrl,
            contextMenuBuilder: chineseContextMenuBuilder,
            decoration: const InputDecoration(hintText: '名称')),
        actions: [
          TextButton(
              onPressed: () async {
                final name = ctrl.text.trim();
                if (name.isNotEmpty && name != b.name) {
                  await NotesDb.renameBook(b.id, name);
                  await _refreshBooks();
                }
                Navigator.of(context).pop();
              },
              child: const Text('确定')),
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('取消')),
        ],
      ),
    );
  }

  Future<void> _deleteBook(Book b) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (b2) => AlertDialog(
        title: const Text('删除笔记本'),
        content: Text('「${b.name}」及其子笔记本中的笔记将移入回收站。'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              style: TextButton.styleFrom(foregroundColor: Colors.red),
              child: const Text('删除')),
        ],
      ),
    );
    if (ok == true) {
      await NotesDb.deleteBook(b.id);
      SyncService.i.markDirty();
      if (mounted && _selectedBookId == b.id) setState(() => _selectedBookId = null);
      _refreshBooks();
    }
  }

  Widget _bookTree(List<Book> books, String? parentId) {
    final children = books.where((b) => b.parentId == parentId).toList();
    children.sort((a, b) => a.name.compareTo(b.name));
    return Column(
      children: children
          .expand((b) => [_bookRow(b), const SizedBox(height: 1)])
          .toList(),
    );
  }

  Widget _bookRow(Book b) {
    final selected = _selectedBookId == b.id && _view == View.books;
    return Material(
      color: selected ? const Color(0xFFE8EBF9) : Colors.transparent,
      borderRadius: const BorderRadius.horizontal(right: Radius.circular(10)),
      child: InkWell(
        onTap: () {
          setState(() {
            _selectedBookId = b.id;
            _view = View.books;
            _tagFilter = null;
          });
          _applyView();
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Row(
            children: [
              Icon(b.kind == 'folder' ? Icons.folder : Icons.menu_book, size: 18,
                  color: selected ? const Color(0xFF4A5EE5) : null),
              const SizedBox(width: 8),
              Expanded(child: Text(b.name, overflow: TextOverflow.ellipsis)),
              IconButton(
                  icon: const Icon(Icons.edit_outlined, size: 14),
                  visualDensity: VisualDensity.compact,
                  onPressed: () => _renameBook(b)),
              IconButton(
                  icon: const Icon(Icons.delete_outline, size: 14),
                  visualDensity: VisualDensity.compact,
                  onPressed: () => _deleteBook(b)),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final currentTitle = _search.isNotEmpty
        ? '搜索：$_search'
        : switch (_view) {
            View.trash => '回收站',
            View.tag => _tags.firstWhere((t) => t.id == _tagFilter,
                    orElse: () => const Tag(id: '', name: '标签')).name,
            _ => (_selectedBookId != null
                    ? _books.firstWhere((b) => b.id == _selectedBookId,
                            orElse: () => const Book(id: '', name: '全部笔记')).name
                    : '全部笔记'),
          };

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyN, control: true): _createNote,
        const SingleActivator(LogicalKeyboardKey.keyF, control: true): () =>
            _searchFocus.requestFocus(),
        const SingleActivator(LogicalKeyboardKey.keyS, control: true): () {
          if (_selectedNoteId != null) _applyView();
        },
        // 托盘菜单「设置」经由原生层发送 Ctrl+, 触发
        const SingleActivator(LogicalKeyboardKey.comma, control: true):
            _openSettings,
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          body: Column(
        children: [
          Expanded(
            child: ValueListenableBuilder<(double, double)>(
              valueListenable: _paneWidths,
              builder: (context, _pw, _) => Row(
        children: [
          // ---------- 左栏 ----------
          SizedBox(
            width: _pw.$1,
            child: Container(
              decoration: BoxDecoration(
                  border: Border(right: BorderSide(color: Theme.of(context).dividerColor))),
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 14, 8, 8),
                    child: Row(
                      children: [
                        const Icon(Icons.menu_book_outlined, size: 20),
                        const SizedBox(width: 8),
                        const Expanded(
                            child: Text('我的笔记',
                                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold))),
                        IconButton(
                            icon: const Icon(Icons.file_download_outlined, size: 18),
                            tooltip: '导入笔记（Simplenote / Markdown）',
                            onPressed: _openImportDialog),
                        IconButton(
                            icon: const Icon(Icons.settings_outlined, size: 18),
                            onPressed: _openSettings),
                      ],
                    ),
                  ),
                  Expanded(
                    child: ListView(
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(12, 4, 8, 4),
                          child: Row(
                            children: [
                              Expanded(
                                  child: Text('目录',
                                      style: TextStyle(fontSize: kFontSmall, color: kSubTextColor))),
                              IconButton(
                                  icon: const Icon(Icons.add, size: 16),
                                  visualDensity: VisualDensity.compact,
                                  onPressed: _newBook),
                            ],
                          ),
                        ),
                        _bookTree(_books, null),
                        Divider(height: 28, color: Theme.of(context).dividerColor),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(12, 4, 8, 4),
                          child: Text('标签', style: TextStyle(fontSize: kFontSmall, color: kSubTextColor)),
                        ),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                          child: Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: [
                              if (_tags.isEmpty)
                                const Padding(
                                    padding: EdgeInsets.symmetric(vertical: 6),
                                    child: Text('暂无标签',
                                        style: TextStyle(fontSize: kFontSmall, color: kSubTextColor)))
                              else
                                ..._tags.map((t) {
                                  final sel = _view == View.tag && _tagFilter == t.id;
                                  return ChoiceChip(
                                      label: Text('#${t.name}'),
                                      selected: sel,
                                      labelStyle: TextStyle(fontSize: kFontTiny),
                                      onSelected: (_) {
                                        setState(() {
                                          _view = View.tag;
                                          _tagFilter = t.id;
                                          _selectedBookId = null;
                                          _search = '';
                                          _searchCtrl.clear();
                                        });
                                        _applyView();
                                      });
                                }),
                            ],
                          ),
                        ),
                        Divider(height: 28, color: Theme.of(context).dividerColor),
                        ListTile(
                          dense: true,
                          leading: const Icon(Icons.delete_outline, size: 18),
                          title: Text('回收站', style: TextStyle(fontSize: 15, color: kSubTextColor)),
                          trailing: Text('$_trashCount',
                              style: const TextStyle(fontSize: kFontTiny, color: kSubTextColor)),
                          onTap: () {
                            setState(() {
                              _view = View.trash;
                              _tagFilter = null;
                              _search = '';
                              _searchCtrl.clear();
                            });
                            _applyView();
                          },
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          _dragHandle(true),
          // ---------- 中栏 ----------
          SizedBox(
            width: _pw.$2,
            child: Container(
              decoration: BoxDecoration(
                  border: Border(right: BorderSide(color: Theme.of(context).dividerColor))),
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 14, 8, 8),
                    child: Row(
                      children: [
                        Expanded(
                            child: Text(currentTitle,
                                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold))),
                        if (_view == View.trash)
                          IconButton(icon: const Icon(Icons.delete_sweep, size: 18), onPressed: _clearTrash)
                        else
                          const SizedBox(width: 36),
                        IconButton(
                            icon: const Icon(Icons.add, size: 22),
                            tooltip: '新建笔记（Ctrl+Shift+Alt+N）',
                            onPressed: _createNote),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
                    child: Container(
                      decoration: BoxDecoration(
                        color: Theme.of(context).dividerColor,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      child: Row(
                        children: [
                          const Icon(Icons.search, size: 16, color: Colors.grey),
                          const SizedBox(width: 8),
                          Expanded(
                            child: TextField(
                              controller: _searchCtrl,
                              focusNode: _searchFocus,
                              contextMenuBuilder: chineseContextMenuBuilder,
                              style: const TextStyle(fontSize: kFontSmall),
                              decoration: const InputDecoration(
                                hintText: '搜索标题或内容',
                                hintStyle: TextStyle(fontSize: kFontSmall, color: kHintColor),
                                isDense: true,
                                border: InputBorder.none,
                                contentPadding: EdgeInsets.symmetric(vertical: 9),
                              ),
                              onChanged: (v) {
                                _searchTimer?.cancel();
                                _search = v;
                                _searchTimer = Timer(const Duration(milliseconds: 300), () {
                                  _applyView();
                                });
                              },
                            ),
                          ),
                          if (_search.isNotEmpty)
                            InkWell(
                              onTap: () {
                                setState(() {
                                  _search = '';
                                  _searchCtrl.clear();
                                });
                                _applyView();
                              },
                              child: const Padding(
                                padding: EdgeInsets.all(4),
                                child: Icon(Icons.close, size: 14, color: Colors.grey),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  Expanded(
                    child: _notes.isEmpty
                        ? _emptyState()
                        : ListView.builder(
                            itemCount: _notes.length,
                            itemBuilder: (context, i) => _noteCard(_notes[i]),
                          ),
                  ),
                ],
              ),
            ),
          ),
          _dragHandle(false),
          // ---------- 右栏 ----------
          Expanded(
            child: _selectedNoteId != null
                ? EditorPane(
                    key: ValueKey(_selectedNoteId),
                    noteId: _selectedNoteId!,
                    onChanged: _applyView,
                    onClose: () => setState(() => _selectedNoteId = null),
                  )
                : const Center(
                    child: Text(
                      '双击左侧笔记开始编辑\n\n字体：方正宋黑（内嵌）',
                      textAlign: TextAlign.center,
                       style: TextStyle(color: kSubTextColor, fontSize: kFontSmall),
                     ),
                   ),
           ),
            ],
          ),
          ),
          ),
          _buildStatusBar(),
        ],
      ),
        ),
      ),
    );
  }

  /// 可拖动的分栏手柄：只更新宽度 notifier，不重建整个页面，拖动跟手
  Widget _dragHandle(bool first) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onHorizontalDragUpdate: (d) {
        final cur = _paneWidths.value;
        final target = first
            ? (cur.$1 + d.delta.dx).clamp(160.0, 420.0)
            : (cur.$2 + d.delta.dx).clamp(240.0, 560.0);
        _paneWidths.value = first ? (target, cur.$2) : (cur.$1, target);
      },
      onHorizontalDragEnd: (_) {
        final w = _paneWidths.value;
        SettingsStore.write(first ? 'leftW' : 'midW',
            (first ? w.$1 : w.$2).toStringAsFixed(0));
      },
      child: MouseRegion(
        cursor: SystemMouseCursors.resizeLeftRight,
        child: Container(
          width: 6,
          color: Colors.transparent,
          child: Center(
            child: Container(
              width: 2,
              height: 36,
              decoration: BoxDecoration(
                color: Colors.grey.withValues(alpha: 0.35),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ---------- 底部状态栏 ----------
  Widget _buildStatusBar() {
    return ListenableBuilder(
      listenable: SyncService.i,
      builder: (context, _) => Container(
        height: 30,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: Theme.of(context).dividerColor,
          border: Border(top: BorderSide(color: Theme.of(context).dividerColor)),
        ),
        child: Row(
          children: [
            const Icon(Icons.description_outlined, size: 14, color: kSubTextColor),
            const SizedBox(width: 6),
            Text('笔记 $_totalNotes 条',
                style: const TextStyle(fontSize: kFontTiny, color: kSubTextColor)),
            const SizedBox(width: 16),
            const Icon(Icons.delete_outline, size: 14, color: kSubTextColor),
            const SizedBox(width: 6),
            Text('回收站 $_trashCount 条',
                style: const TextStyle(fontSize: kFontTiny, color: kSubTextColor)),
            const SizedBox(width: 16),
            Icon(SyncService.i.live
                ? Icons.cloud_sync
                : (SyncService.i.lastOk ? Icons.cloud_done : Icons.cloud_off),
                size: 14,
                color: SyncService.i.live
                    ? const Color(0xFF4A5EE5)
                    : (SyncService.i.lastOk ? const Color(0xFF2E7D32) : Colors.red)),
            const SizedBox(width: 6),
            Text('${SyncService.i.live ? '实时同步' : '同步'} '
                '${SyncService.i.formatTime(SyncService.i.atMs)} · '
                '${SyncService.i.resultText}',
                style: TextStyle(
                    fontSize: kFontTiny,
                    color: SyncService.i.lastOk ? kSubTextColor : Colors.red)),
            const Spacer(),
            Text(kVersionLabel,
                style: const TextStyle(
                    fontSize: kFontTiny,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFFB45309))),
            const SizedBox(width: 12),
            Text(SyncService.i.baseUrl,
                style: const TextStyle(fontSize: kFontTiny, color: kHintColor)),
            const SizedBox(width: 12),
            Text(NotesDb.dataDir,
                style: const TextStyle(fontSize: kFontTiny, color: kHintColor)),
          ],
        ),
      ),
    );
  }

  // ---------- 导入 ----------

  Future<void> _openImportDialog() async {
    await showDialog<void>(
      context: context,
      builder: (b) => AlertDialog(
        title: const Text('导入笔记'),
        content: const SizedBox(
          width: 320,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('导入的内容会放进「导入笔记」笔记本；\n已有同 ID 的笔记会被更新，不会重复。',
                  style: TextStyle(fontSize: 13)),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(b).pop(), child: const Text('取消')),
          TextButton(
              onPressed: () {
                Navigator.of(b).pop();
                _importSimplenoteJson();
              },
              child: const Text('Simplenote JSON')),
          TextButton(
              onPressed: () {
                Navigator.of(b).pop();
                _importMarkdownFolder();
              },
              child: const Text('Markdown 文件夹')),
        ],
      ),
    );
  }

  Future<String?> _pickPath({bool folder = false, List<String> ext = const []}) async {
    final dialog = na.FileDialog.create(
        folder ? na.FileDialogMode.selectFolder : na.FileDialogMode.openFile);
    if (dialog == null) return null;
    if (ext.isNotEmpty) dialog.setFileTypes(ext);
    dialog.open();
    final r = dialog.result;
    final paths = dialog.paths;
    dialog.dispose();
    if (r == na.FileDialogResult.accepted && paths.isNotEmpty) return paths.first;
    return null;
  }

  Future<void> _importSimplenoteJson() async {
    final path = await _pickPath(ext: const ['json']);
    if (path == null) return;
    try {
      final raw = jsonDecode(await File(path).readAsString());
      List items = [];
      if (raw is List) {
        items = raw;
      } else if (raw is Map && raw['notes'] is List) {
        items = raw['notes'] as List;
      }
      final n = await NotesDb.importBatch(
          items.whereType<Map>().toList(), bookName: '导入笔记');
      await _refreshBooks();
      SyncService.i.markDirty();
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('已导入 $n 条笔记')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('导入失败：$e')));
      }
    }
  }

  Future<void> _importMarkdownFolder() async {
    final dir = await _pickPath(folder: true);
    if (dir == null) return;
    try {
      final items = <Map>[];
      await for (final e in Directory(dir).list(recursive: true)) {
        if (e is! File) continue;
        final name = e.path.toLowerCase();
        if (!name.endsWith('.md') && !name.endsWith('.markdown') &&
            !name.endsWith('.txt')) {
          continue;
        }
        final content = await e.readAsString();
        items.add({
          'id': 'md-${await _hashPath(e.path)}',
          'title': NotesDb.deriveTitle(content),
          'content': content,
          'tags': <String>[],
          'pinned': false,
          'trashed': false,
          'createdAt': e.statSync().modified.millisecondsSinceEpoch,
          'updatedAt': e.statSync().modified.millisecondsSinceEpoch,
        });
      }
      if (items.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('该文件夹里没有 .md/.txt 文件')));
        }
        return;
      }
      final n = await NotesDb.importBatch(items, bookName: '导入笔记');
      await _refreshBooks();
      SyncService.i.markDirty();
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('已导入 $n 条笔记')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('导入失败：$e')));
      }
    }
  }

  Future<String> _hashPath(String s) async {
    final bytes = utf8.encode(s);
    var h = 0x811c9dc5;
    for (final b in bytes) {
      h ^= b;
      h = (h * 0x01000193) & 0xFFFFFFFF;
    }
    return h.toRadixString(16).padLeft(8, '0');
  }

  int _totalNotes = 0;

  Future<void> _refreshTotals() async {
    final rows = await NotesDb.queryAll(
        'SELECT COUNT(*) AS c FROM notes WHERE trashed = 0');
    if (mounted) setState(() => _totalNotes = rows.first['c'] as int);
  }

  Widget _emptyState() {
    if (_view == View.trash) {
      return const Center(
          child: Text('回收站是空的', style: TextStyle(color: kSubTextColor, fontSize: kFontSmall)));
    }
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.edit_note_outlined, size: 56, color: Colors.grey.shade300),
          const SizedBox(height: 12),
          const Text('还没有笔记', style: TextStyle(fontSize: 16, color: kSubTextColor)),
          const SizedBox(height: 4),
          TextButton(
              onPressed: _createNote,
              child: const Row(mainAxisSize: MainAxisSize.min,
                  children: [Icon(Icons.add), Text('新建第一篇笔记')])),
        ],
      ),
    );
  }

  Widget _noteCard(Note n) {
    final title = n.title.isEmpty ? '未命名笔记' : n.title;
    final snippet = n.plainText.isEmpty ? '' : n.plainText.replaceAll('\n', ' ');
    final selected = _selectedNoteId == n.id;
    return InkWell(
      onTap: () => _selectNote(n),
      borderRadius: const BorderRadius.all(Radius.circular(8)),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
            color: selected ? const Color(0xFFE8EBF9) : null,
            borderRadius: const BorderRadius.all(Radius.circular(8)),
            border: selected
                ? Border.all(color: const Color(0xFF4A5EE5), width: 1)
                : Border(
                    bottom: BorderSide(
                        color: Theme.of(context).dividerColor, width: 1))),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 第一行：置顶 + 标题 + 时间
            Row(
              children: [
                if (n.pinned) ...[
                  const Icon(Icons.push_pin, size: 12, color: Colors.amber),
                  const SizedBox(width: 3),
                ],
                Expanded(
                    child: Text(title,
                        style: const TextStyle(
                            fontSize: kFontNormal, fontWeight: FontWeight.w600),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis)),
                const SizedBox(width: 6),
                Text(formatTimeShort(n.updatedAt),
                    style: const TextStyle(
                        fontSize: kFontTiny, color: kSubTextColor)),
              ],
            ),
            // 第二行：一行摘要 + 标签
            if (snippet.isNotEmpty || n.tags.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Row(
                  children: [
                    Expanded(
                        child: Text(
                            snippet.isEmpty ? '（空笔记）' : snippet,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: kFontTiny, color: kSubTextColor))),
                    if (n.tags.isNotEmpty) ...[
                      const SizedBox(width: 6),
                      Text(n.tags.map((t) => '#$t').join(' '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: kFontTiny, color: Color(0xFF4A5EE5))),
                    ],
                    if (n.trashed) ...[
                      const SizedBox(width: 4),
                      IconButton(
                          icon: const Icon(Icons.restore, size: 13),
                          visualDensity: VisualDensity.compact,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(
                              minWidth: 24, minHeight: 24),
                          onPressed: () => _restore(n.id)),
                      IconButton(
                          icon: const Icon(Icons.delete_forever, size: 13),
                          visualDensity: VisualDensity.compact,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(
                              minWidth: 24, minHeight: 24),
                          onPressed: () => _purge(n.id)),
                    ],
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _openSettings() async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => SettingsPage(onThemeChanged: NotesPage.themeChanged)),
    );
    if (changed == true && mounted) {
      _selectedNoteId = null;
      await _refreshBooks();
      _refreshTrashCount();
      _refreshTotals();
      _applyView();
    }
  }
}
