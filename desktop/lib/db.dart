import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class Book {
  const Book({
    required this.id,
    required this.name,
    this.parentId,
    this.kind = 'notebook',
    this.sortOrder = 0,
  });
  final String id;
  final String name;
  final String? parentId;
  final String kind; // notebook | folder
  final int sortOrder;

  factory Book.fromMap(Map<String, dynamic> m) => Book(
      id: m['id'],
      name: m['name'],
      parentId: m['parent_id'],
      kind: m['kind'],
      sortOrder: m['sort_order'] as int);
}

class Note {
  Note({
    required this.id,
    required this.bookId,
    this.title = '',
    this.body = '',
    this.plainText = '',
    this.pinned = false,
    this.trashed = false,
    this.trashAt = 0,
    required this.createdAt,
    required this.updatedAt,
    this.tags = const [],
  });
  String id;
  String bookId;
  String title;
  String body; // Markdown 原文
  String plainText;
  bool pinned;
  bool trashed;
  int trashAt;
  int createdAt;
  int updatedAt;
  List<String> tags;

  factory Note.fromMap(Map<String, dynamic> m) {
    final tagsRaw = m['tags'] as String? ?? '';
    return Note(
        id: m['id'],
        bookId: m['book_id'],
        title: m['title'] ?? '',
        body: m['body'] ?? '',
        plainText: m['plain_text'] ?? '',
        pinned: m['pinned'] == 1,
        trashed: m['trashed'] == 1,
        trashAt: m['trash_at'] ?? 0,
        createdAt: m['created_at'],
        updatedAt: m['updated_at'],
        tags: tagsRaw.split('\n').where((s) => s.isNotEmpty).toList());
  }
}

class Tag {
  const Tag({required this.id, required this.name, this.color = '#4A5EE5'});
  final String id;
  final String name;
  final String color;
  factory Tag.fromMap(Map<String, dynamic> m) =>
      Tag(id: m['id'], name: m['name'], color: m['color']);
}

final Random _rnd = Random();
int _seq = 0;

/// 生成全局唯一 ID：毫秒时间戳 + 进程内自增序号 + 随机数
/// （旧写法用"当前毫秒"当随机种子，同一毫秒内连续创建会生成重复 ID，
///   可能导致主键冲突、笔记插入失败，这里做了加固）
String newId() {
  _seq = (_seq + 1) % 1000000;
  return '${DateTime.now().millisecondsSinceEpoch}-${_seq.toString().padLeft(6, '0')}'
      '-${_rnd.nextInt(1 << 30).toRadixString(16)}';
}

class NotesDb {
  NotesDb._();

  static Database? _db;
  static String? _dataDir;

  /// 仅供单元测试注入：设置后数据目录固定为它，绝不写进真实笔记库。
  /// 生产代码不会设置这个字段。
  static String? testDataDirOverride;

  static String get dataDir => _dataDir!;
  static String get attachmentsDir => p.join(_dataDir!, 'attachments');

  static Future<void> init() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    _dataDir = await resolveDataDir();
    await Directory(attachmentsDir).create(recursive: true);
    _db = await openDatabase(p.join(_dataDir!, 'notes.db'), version: 1, onCreate: _onCreate);
    // 老库（version 1）没有墓碑表：这里补建，保证「彻底删除」后不会被同步重新拉回。
    await _db!.execute('CREATE TABLE IF NOT EXISTS tombstones('
        'id TEXT PRIMARY KEY, deleted_at INTEGER NOT NULL)');
    // 老库（v1.3.8 及以前）没有 dirty 列：补建。dirty 是「按笔记粒度」的
    // 本地待推送标记 —— 同步只推真正改动过的笔记，杜绝一端的旧快照
    // 覆盖另一端刚写入的新内容。
    try {
      await _db!.execute(
          'ALTER TABLE notes ADD COLUMN dirty INTEGER NOT NULL DEFAULT 0');
    } catch (_) {
      // 列已存在，忽略。
    }
    // 墓碑保留一年；服务端确认删除后会被立即清掉，这里只是防止无限增长。
    await _db!.delete('tombstones',
        where: 'deleted_at < ?',
        whereArgs: [DateTime.now().millisecondsSinceEpoch - 365 * 24 * 3600 * 1000]);
    // 保证至少存在一个笔记本（修复"新建笔记没反应"的关键兜底）
    if ((await queryAll('SELECT id FROM books')).isEmpty) {
      await createBook('我的笔记本', null, 'notebook');
    }
  }

  static Future<String> resolveDataDir() async {
    final override = testDataDirOverride;
    if (override != null && override.isNotEmpty) {
      await Directory(override).create(recursive: true);
      return override;
    }
    final env = Platform.environment['MYNOTES_DATA'];
    if (env != null && env.isNotEmpty) return p.join(env, 'notes-data');
    // 便携优先：程序目录/data；不可写则退回用户目录
    try {
      final exeDir = p.dirname(Platform.resolvedExecutable);
      final dir = p.join(exeDir, 'notes-data');
      final probe = p.join(dir, '.probe');
      await Directory(dir).create(recursive: true);
      await File(probe).writeAsString('ok');
      return dir;
    } catch (_) {
      // 程序目录不可写（例如 macOS 的 .app 放在 /Applications）时，
      // 退回各平台标准的用户数据目录，不写死任何 Windows 路径。
      final home = Platform.environment['HOME'] ??
          Platform.environment['USERPROFILE'] ?? '.';
      final String base;
      if (Platform.isMacOS) {
        base = p.join(home, 'Library', 'Application Support');
      } else if (Platform.isLinux) {
        base = Platform.environment['XDG_DATA_HOME'] ??
            p.join(home, '.local', 'share');
      } else {
        base = Platform.environment['APPDATA'] ??
            p.join(home, 'AppData', 'Roaming');
      }
      final dir = p.join(base, 'MyNotes', 'My Notes');
      await Directory(dir).create(recursive: true);
      return dir;
    }
  }

  static Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
CREATE TABLE books(
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  parent_id TEXT,
  kind TEXT NOT NULL DEFAULT 'notebook',
  sort_order INTEGER NOT NULL DEFAULT 0);
''');
    await db.execute('''
CREATE TABLE notes(
  id TEXT PRIMARY KEY,
  book_id TEXT NOT NULL,
  title TEXT NOT NULL DEFAULT '',
  body TEXT NOT NULL DEFAULT '',
  plain_text TEXT NOT NULL DEFAULT '',
  pinned INTEGER NOT NULL DEFAULT 0,
  trashed INTEGER NOT NULL DEFAULT 0,
  trash_at INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  dirty INTEGER NOT NULL DEFAULT 0);
''');
    await db.execute('CREATE INDEX idx_notes_book ON notes(book_id);');
    await db.execute('''
CREATE TABLE tags(
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL UNIQUE,
  color TEXT NOT NULL DEFAULT '#4A5EE5');
''');
    await db.execute('''
CREATE TABLE note_tags(
  note_id TEXT NOT NULL,
  tag_id TEXT NOT NULL,
  PRIMARY KEY(note_id, tag_id));
''');
    await db.execute('CREATE TABLE tombstones('
        'id TEXT PRIMARY KEY, deleted_at INTEGER NOT NULL)');
  }

  static Database get db => _db!;

  static Future<List<Map<String, dynamic>>> queryAll(String sql, [List? args]) =>
      _db!.rawQuery(sql, args ?? []);

  // ---------- 笔记本 / 文件夹 ----------

  static Future<Book> createBook(String name, String? parentId, String kind) async {
    final b = Book(id: newId(), name: name, parentId: parentId, kind: kind);
    await _db!.insert('books', {'id': b.id, 'name': b.name, 'parent_id': b.parentId, 'kind': b.kind, 'sort_order': b.sortOrder});
    return b;
  }

  static Future<Book?> getBook(String id) async {
    final rows = await _db!.rawQuery('SELECT * FROM books WHERE id = ?', [id]);
    return rows.isNotEmpty ? Book.fromMap(rows.first) : null;
  }

  static Future<void> renameBook(String id, String name) async {
    await _db!.update('books', {'name': name}, where: 'id = ?', whereArgs: [id]);
  }

  static Future<void> setBookKind(String id, String kind) async {
    await _db!.update('books', {'kind': kind}, where: 'id = ?', whereArgs: [id]);
  }

  /// 删除笔记本：子笔记本递归并入回收站；笔记全部移入回收站；最后删除笔记本本身
  static Future<void> deleteBook(String id) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await _collectSubBooks(id);
    await _db!.transaction((txn) async {
      await txn.update('notes', {'trashed': 1, 'trash_at': now}, where: 'book_id = ?', whereArgs: [id]);
      await txn.delete('books', where: 'id = ?', whereArgs: [id]);
      await txn.delete('books', where: 'parent_id = ?', whereArgs: [id]);
    });
  }

  static Future<List<String>> _collectSubBooks(String id) async {
    final rows = await queryAll('SELECT id FROM books WHERE parent_id = ?', [id]);
    final out = <String>[];
    for (final r in rows) {
      final sub = await _collectSubBooks(r['id'] as String);
      out.addAll(sub);
      out.add(r['id'] as String);
    }
    return out;
  }

  static Future<List<Book>> listBooks() async {
    final rows = await queryAll('SELECT * FROM books ORDER BY kind, name');
    return rows.map(Book.fromMap).toList();
  }

  // ---------- 笔记 ----------

  /// 新建笔记。旧版在无笔记本等情况下会静默失败（bug），这里做完整兜底，保证永远可用。
  /// 标记这条笔记「本地已改动、待推送」。
  /// 计算这条笔记的新 updated_at：必须严格大于旧值。
  /// 直接用 DateTime.now() 会在同一毫秒内的连续操作（新建→删除、删除→恢复）
  /// 拿到和上次相同的时间戳，服务端按时间戳判「没变」就把这次变更丢掉 ——
  /// 回收站因此同步不到其它端。改为单调递增 +1，与服务端裁决逻辑一致。
  static Future<int> _nextStamp(String id) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final rows = await _db!.query('notes',
        columns: ['updated_at'], where: 'id = ?', whereArgs: [id], limit: 1);
    if (rows.isEmpty) return now;
    final old = (rows.first['updated_at'] as int?) ?? 0;
    return old >= now ? old + 1 : now;
  }

  static Future<void> markDirty(String id) async {
    await _db!.update('notes', {'dirty': 1}, where: 'id = ?', whereArgs: [id]);
  }

  /// 清除脏标记（服务端已确认收到该版本）。
  static Future<void> clearDirty(Iterable<String> ids) async {
    final list = ids.toList();
    if (list.isEmpty) return;
    await _db!.transaction((txn) async {
      for (final id in list) {
        await txn.update('notes', {'dirty': 0}, where: 'id = ?', whereArgs: [id]);
      }
    });
  }

  /// 本地改动过、尚未推送成功的笔记 id。
  static Future<Set<String>> dirtyIds() async {
    final rows = await _db!.query('notes', columns: ['id'], where: 'dirty = 1');
    return rows.map((r) => r['id'] as String).toSet();
  }

  /// 单条笔记是否处于「本地已改动、待推送」状态。
  /// 远端事件落地前必须查这个：内存里的脏集合只在 pull() 时刷新，
  /// SSE 事件帧走的是另一条路径，只看内存集合会漏判，把用户刚写的内容覆盖掉。
  static Future<bool> isDirty(String id) async {
    final rows = await _db!.query('notes',
        columns: ['dirty'], where: 'id = ?', whereArgs: [id], limit: 1);
    if (rows.isEmpty) return false;
    return (rows.first['dirty'] as int? ?? 0) == 1;
  }

  /// 应用服务端回传的权威时间戳：把本地的 updated_at 对齐到服务端，
  /// 三端才会用同一套时间戳排出完全一致的列表顺序。
  /// 只改时间戳，不动内容，也不清脏标记。
  static Future<void> applyServerStamps(Map<String, dynamic> stamps) async {
    if (stamps.isEmpty) return;
    await _db!.transaction((txn) async {
      for (final entry in stamps.entries) {
        final ts = (entry.value as num?)?.toInt();
        if (ts == null || ts <= 0) continue;
        await txn.update('notes', {'updated_at': ts},
            where: 'id = ?', whereArgs: [entry.key]);
      }
    });
  }

  /// 本地改动过、尚未推送成功的笔记。
  static Future<List<Note>> dirtyNotes() async {
    final rows = await _db!.rawQuery(
        'SELECT n.*, (SELECT group_concat(t.name, char(10)) FROM note_tags nt JOIN tags t ON t.id = nt.tag_id WHERE nt.note_id = n.id) AS tags FROM notes n WHERE n.dirty = 1');
    return rows.map(Note.fromMap).toList();
  }

  static Future<Note> createNote(String? bookId) async {
    String target = bookId ?? '';
    if (target.isEmpty) {
      var root = await _db!.rawQuery("SELECT id FROM books WHERE parent_id IS NULL AND kind = 'notebook' ORDER BY name LIMIT 1");
      if (root.isEmpty) {
        root = await _db!.rawQuery("SELECT id FROM books WHERE parent_id IS NULL ORDER BY name LIMIT 1");
      }
      if (root.isEmpty) {
        root = await _db!.rawQuery("SELECT id FROM books ORDER BY name LIMIT 1");
      }
      if (root.isEmpty) {
        await createBook('我的笔记本', null, 'notebook');
        root = await _db!.rawQuery("SELECT id FROM books LIMIT 1");
      }
      target = root.first['id'] as String;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final n = Note(id: newId(), bookId: target, createdAt: now, updatedAt: now);
    await _db!.insert('notes', {
      'id': n.id, 'book_id': n.bookId, 'title': '', 'body': '',
      'plain_text': '', 'pinned': 0, 'trashed': 0, 'trash_at': 0,
      'created_at': now, 'updated_at': now, 'dirty': 1,
    });
    return n;
  }

  static Future<Note?> getNote(String id) async {
    final rows = await _db!.rawQuery(
        'SELECT n.*, (SELECT group_concat(t.name, char(10)) FROM note_tags nt JOIN tags t ON t.id = nt.tag_id WHERE nt.note_id = n.id) AS tags FROM notes n WHERE n.id = ?',
        [id]);
    return rows.isEmpty ? null : Note.fromMap(rows.first);
  }

  static Future<void> updateNote(Note n) async {
    n.updatedAt = await _nextStamp(n.id);
    await _db!.update('notes', {
      'title': n.title, 'body': n.body, 'plain_text': n.plainText,
      'pinned': n.pinned ? 1 : 0, 'updated_at': n.updatedAt, 'dirty': 1,
    }, where: 'id = ?', whereArgs: [n.id]);
  }

  static Future<void> softDelete(String id) async {
    final now = await _nextStamp(id);
    // 必须同时推进 updated_at：否则远端按时间戳判断「这条没变」，
    // 移入回收站 / 恢复就永远同步不到其它端。
    await _db!.update('notes',
        {'trashed': 1, 'trash_at': now, 'updated_at': now, 'dirty': 1},
        where: 'id = ?', whereArgs: [id]);
  }

  static Future<void> restore(String id) async {
    final now = await _nextStamp(id);
    await _db!.update('notes',
        {'trashed': 0, 'trash_at': 0, 'updated_at': now, 'dirty': 1},
        where: 'id = ?', whereArgs: [id]);
  }

  /// 永久删除：先写墓碑再删笔记，防止 NAS 服务端把旧笔记同步回来。
  static Future<void> purge(String id) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await _db!.transaction((txn) async {
      await txn.rawInsert(
          'INSERT OR REPLACE INTO tombstones(id, deleted_at) VALUES(?, ?)',
          [id, now]);
      await txn.delete('note_tags', where: 'note_id = ?', whereArgs: [id]);
      await txn.delete('notes', where: 'id = ?', whereArgs: [id]);
    });
  }

  /// 清空回收站：返回被删掉的 id，交给同步层立刻通知服务端。
  static Future<List<String>> clearTrash() async {
    final rows = await _db!.query('notes',
        columns: ['id'], where: 'trashed = 1');
    final ids = rows.map((r) => r['id'] as String).toList();
    final now = DateTime.now().millisecondsSinceEpoch;
    await _db!.transaction((txn) async {
      await txn.rawInsert(
          'INSERT OR REPLACE INTO tombstones(id, deleted_at) '
          'SELECT id, ? FROM notes WHERE trashed = 1', [now]);
      await txn.rawDelete('DELETE FROM note_tags WHERE note_id IN '
          '(SELECT id FROM notes WHERE trashed = 1)');
      await txn.delete('notes', where: 'trashed = 1');
    });
    return ids;
  }

  /// 一键删除所有笔记（含回收站）；保留笔记本与标签定义
  static Future<void> clearAllNotes() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await _db!.transaction((txn) async {
      await txn.rawInsert(
          'INSERT OR REPLACE INTO tombstones(id, deleted_at) '
          'SELECT id, ? FROM notes', [now]);
      await txn.delete('note_tags');
      await txn.delete('notes');
    });
  }

  /// 墓碑：本机已永久删除的笔记 id -> 删除时刻（毫秒）。
  static Future<Map<String, int>> tombstones() async {
    final rows = await _db!.query('tombstones', columns: ['id', 'deleted_at']);
    return <String, int>{
      for (final r in rows)
        r['id'] as String: (r['deleted_at'] as num?)?.toInt() ?? 0
    };
  }

  /// 服务端确认删除后清掉对应墓碑。
  static Future<void> forgetTombstones(Iterable<String> ids) async {
    if (ids.isEmpty) return;
    await _db!.transaction((txn) async {
      for (final id in ids) {
        await txn.delete('tombstones', where: 'id = ?', whereArgs: [id]);
      }
    });
  }

  /// 新版服务端下发的删除列表：本地按 id 删除（幂等）。
  static Future<int> purgeRemoteIds(List<String> ids) async {
    if (ids.isEmpty) return 0;
    var n = 0;
    await _db!.transaction((txn) async {
      for (final id in ids) {
        n += await txn.delete('notes', where: 'id = ?', whereArgs: [id]);
        await txn.delete('note_tags', where: 'note_id = ?', whereArgs: [id]);
      }
    });
    return n;
  }

  static Future<void> moveNote(String id, String bookId) async {
    final now = await _nextStamp(id);
    await _db!.update('notes',
        {'book_id': bookId, 'updated_at': now, 'dirty': 1},
        where: 'id = ?', whereArgs: [id]);
  }

  /// 查询笔记。bookId 传 null 表示全部笔记本；trash=true 查回收站
  static Future<List<Note>> listNotes(String? bookId, {bool trash = false}) async {
    final args = <dynamic>[];
    var sql = 'SELECT n.*, (SELECT group_concat(t.name, char(10)) FROM note_tags nt JOIN tags t ON t.id = nt.tag_id WHERE nt.note_id = n.id) AS tags FROM notes n WHERE n.trashed = ?';
    args.add(trash ? 1 : 0);
    if (bookId != null && bookId.isNotEmpty) {
      sql += ' AND n.book_id = ?';
      args.add(bookId);
    }
    sql += ' ORDER BY n.pinned DESC, n.updated_at DESC, n.id ASC';
    final rows = await _db!.rawQuery(sql, args);
    return rows.map(Note.fromMap).toList();
  }

  static Future<List<Note>> searchNotes(String q) async {
    final like = '%$q%';
    final rows = await _db!.rawQuery(
      'SELECT n.*, (SELECT group_concat(t.name, char(10)) FROM note_tags nt JOIN tags t ON t.id = nt.tag_id WHERE nt.note_id = n.id) AS tags FROM notes n WHERE n.trashed = 0 AND (n.title LIKE ? OR n.plain_text LIKE ?) ORDER BY n.pinned DESC, n.updated_at DESC, n.id ASC',
      [like, like]);
    return rows.map(Note.fromMap).toList();
  }

  static Future<int> noteCount(String bookId, {bool trash = false}) async {
    final r = await _db!.rawQuery(
      'SELECT COUNT(*) AS c FROM notes WHERE book_id = ? AND trashed = ?', [bookId, trash ? 1 : 0]);
    return r.first['c'] as int;
  }

  // ---------- 标签 ----------

  static Future<List<Tag>> listTags() async {
    final rows = await _db!.rawQuery('SELECT * FROM tags ORDER BY name');
    return rows.map(Tag.fromMap).toList();
  }

  static Future<Tag> createTag(String name, {String color = '#4A5EE5'}) async {
    final existing = await _db!.rawQuery('SELECT * FROM tags WHERE name = ?', [name]);
    if (existing.isNotEmpty) return Tag.fromMap(existing.first);
    final t = Tag(id: newId(), name: name, color: color);
    await _db!.insert('tags', {'id': t.id, 'name': t.name, 'color': t.color});
    return t;
  }

  static Future<List<String>> getTagIds(String noteId) async {
    final rows = await _db!.rawQuery(
        'SELECT tag_id FROM note_tags WHERE note_id = ?', [noteId]);
    return rows.map((r) => r['tag_id'] as String).toList();
  }

  static Future<void> setTags(String noteId, List<String> tagIds) async {
    await _db!.transaction((txn) async {
      await txn.delete('note_tags', where: 'note_id = ?', whereArgs: [noteId]);
      for (final tid in tagIds) {
        await txn.insert('note_tags', {'note_id': noteId, 'tag_id': tid});
      }
    });
    // 标签参与服务端内容比较，不打脏标记就同步不过去。
    // 同时推进 updated_at：否则三端排序仍会不一致。
    final now = await _nextStamp(noteId);
    await _db!.update('notes', {'updated_at': now, 'dirty': 1},
        where: 'id = ?', whereArgs: [noteId]);
  }

  static Future<List<Note>> notesWithTag(String tagId) async {
    final rows = await _db!.rawQuery(
      'SELECT n.*, (SELECT group_concat(t.name, char(10)) FROM note_tags nt JOIN tags t ON t.id = nt.tag_id WHERE nt.note_id = n.id) AS tags FROM notes n JOIN note_tags nt ON nt.note_id = n.id WHERE n.trashed = 0 AND nt.tag_id = ? ORDER BY n.pinned DESC, n.updated_at DESC, n.id ASC',
      [tagId]);
    return rows.map(Note.fromMap).toList();
  }

  // ---------- 导入 / 同步合并 / 自动标题 ----------

  /// 从正文第一行推导标题（去掉 Markdown 记号，最多 30 字）
  static String deriveTitle(String content) {
    for (final raw in content.split('\n')) {
      final line = raw
          .replaceFirst(RegExp(r'^\s*#{1,6}\s+'), '')
          .replaceFirst(RegExp(r'^\s*>\s?'), '')
          .replaceFirst(RegExp(r'^\s*[-*+]\s+'), '')
          .replaceFirst(RegExp(r'^\s*\d+\.\s+'), '')
          .replaceAll('**', '')
          .replaceAll('`', '')
          .trim();
      if (line.isNotEmpty) {
        return line.length > 30 ? line.substring(0, 30) : line;
      }
    }
    return '';
  }

  /// 解析远端 bookId：可能是本地笔记本 id，也可能是网页版写的名称。
  static Future<String> _resolveBookId(String raw) async {
    var target = raw;
    if (target.isNotEmpty && (await getBook(target)) == null) {
      final byName = (await listBooks())
          .where((b) => b.name == target && b.kind == 'notebook')
          .toList();
      if (byName.isNotEmpty) {
        target = byName.first.id;
      } else {
        target = (await createBook(target, null, 'notebook')).id;
      }
    }
    if (target.isEmpty) {
      var root = await _db!.rawQuery(
          "SELECT id FROM books WHERE parent_id IS NULL AND kind = 'notebook' ORDER BY name LIMIT 1");
      if (root.isEmpty) {
        await createBook('我的笔记本', null, 'notebook');
        root = await _db!.rawQuery(
            "SELECT id FROM books WHERE parent_id IS NULL AND kind = 'notebook' ORDER BY name LIMIT 1");
      }
      final again = root.isNotEmpty
          ? root
          : await _db!.rawQuery(
              "SELECT id FROM books WHERE kind = 'notebook' ORDER BY name LIMIT 1");
      target = again.first['id'] as String;
    }
    return target;
  }

  /// 解析远端传来的笔记本名称 → 本地笔记本 id（找不到就按同名新建）。
  static Future<String> resolveBookId(String raw) => _resolveBookId(raw);

  /// 只落地远端的「状态」字段：回收站 / 置顶 / 笔记本 / 时间戳。
  ///
  /// 用途：本地这条笔记还有未推送的编辑（正文冲突）时，正文必须保护，
  /// 但回收站状态必须立刻跟随远端 —— 否则「另一端把笔记删了，
  /// 这端还躺在正常列表里」就永远修不好。
  /// 脏标记保留：本地正文还没上推，下次 push 仍要带上。
  static Future<void> applyRemoteState(
    String id, {
    required bool trashed,
    required bool pinned,
    String bookId = '',
    int updatedAt = 0,
  }) async {
    if (id.isEmpty) return;
    final values = <String, Object?>{
      'trashed': trashed ? 1 : 0,
      'pinned': pinned ? 1 : 0,
    };
    if (trashed) {
      values['trash_at'] = DateTime.now().millisecondsSinceEpoch;
    }
    if (bookId.isNotEmpty) {
      values['book_id'] = await _resolveBookId(bookId);
    }
    if (updatedAt > 0) {
      values['updated_at'] = updatedAt;
    }
    if (values.isEmpty) return;
    await _db!.update('notes', values, where: 'id = ?', whereArgs: [id]);
  }

  /// 按服务端快照整条落地（新增或更新），写入全部字段。
  ///
  /// 必须与本地编辑用的 updateNote() 分开：updateNote() 会把 updated_at
  /// 刷成本机时间，用在同步路径上会让三端时间戳各自漂移、列表顺序永远
  /// 对不上；这里保留服务端的权威 updatedAt。同时必须写 trashed —— 以前
  /// applyRemote / importOne 缺了它，另一端「移入回收站 / 恢复」永远同步不过来。
  static Future<int> applyRemoteSnapshot(Map item,
      {String? bookIdOverride,
      bool keepDirty = false,
      bool? forceTrashed}) async {
    final id = (item['id'] as String?) ?? '';
    if (id.isEmpty) return 0;
    final now = DateTime.now().millisecondsSinceEpoch;
    final content = (item['content'] ?? item['body'] ?? '') as String;
    var title = (item['title'] ?? '') as String;
    if (title.isEmpty) title = deriveTitle(content);
    final created = (item['createdAt'] as num?)?.toInt() ?? now;
    final updated = (item['updatedAt'] as num?)?.toInt() ?? now;
    final trashed =
        forceTrashed != null ? (forceTrashed ? 1 : 0) : (item['trashed'] == true ? 1 : 0);
    final pinned = item['pinned'] == true ? 1 : 0;

    final existing = await getNoteById(id);
    // 远端传的是笔记本名称，本地存的是笔记本 id：必须解析后写入。
    // 以前直接沿用 existing.bookId，远端把笔记移到别的笔记本后，
    // 本端永远不会跟着变 —— 三端列表因此对不上。
    String bookId = bookIdOverride ?? '';
    if (bookId.isEmpty) {
      final raw = (item['bookId'] as String?) ?? '';
      bookId = raw.isNotEmpty
          ? await _resolveBookId(raw)
          : (existing?.bookId ?? await _resolveBookId(''));
    }
    final values = <String, Object?>{
      'title': title,
      'body': content,
      'plain_text': markdownToPlainText(content),
      'pinned': pinned,
      'trashed': trashed,
      'trash_at': trashed == 1 ? now : 0,
      'updated_at': updated,
      // 以远端版本为准：本地不再有待推送的改动。
      // keepDirty=true 用于「分项合并」：本地正文被保护、尚未推送，
      // 脏标记必须留着，否则这次编辑永远上不去了。
      'dirty': keepDirty ? 1 : 0,
    };
    if (existing == null) {
      await _db!.insert('notes', {
        'id': id,
        'book_id': bookId,
        'created_at': created,
        ...values,
      });
    } else {
      await _db!.update('notes', values, where: 'id = ?', whereArgs: [id]);
    }
    await _applyTagNames(id, item['tags']);
    return 1;
  }

  /// 导入一条（来自 Simplenote JSON 或远端快照）
  static Future<Note> importOne(Map item, {String? bookId}) async {
    final target = await _resolveBookId(bookId ?? (item['bookId'] as String?) ?? '');
    final id = (item['id'] as String?) ?? newId();
    final data = Map<String, dynamic>.from(item);
    data['id'] = id;
    await applyRemoteSnapshot(data, bookIdOverride: target);
    // 本地导入的内容要推给其它端（applyRemoteSnapshot 内部会清脏标记，
    // 所以导入完成后再补上）。
    await markDirty(id);
    return (await getNoteById(id))!;
  }

  static Future<void> _applyTagNames(String noteId, dynamic rawTags) async {
    if (rawTags is! List) return;
    final ids = <String>[];
    for (final t in rawTags) {
      if (t is String && t.trim().isNotEmpty) {
        final tag = await createTag(t.trim());
        ids.add(tag.id);
      }
    }
    if (ids.isNotEmpty) await setTags(noteId, ids);
  }

  /// 远端较新时覆盖本地（保留签名兼容同步层与回归测试）
  static Future<void> applyRemote(Note local, Map item) async {
    await applyRemoteSnapshot(item);
  }

  static Future<Note?> getNoteById(String id) => getNote(id);

  /// 批量导入（Simplenote JSON / Markdown 文件列表）
  static Future<int> importBatch(List<Map> items, {String bookName = '导入笔记'}) async {
    var book = (await listBooks())
        .where((b) => b.name == bookName && b.kind == 'notebook')
        .toList();
    String bookId;
    if (book.isEmpty) {
      bookId = (await createBook(bookName, null, 'notebook')).id;
    } else {
      bookId = book.first.id;
    }
    var n = 0;
    for (final item in items) {
      await importOne(item, bookId: bookId);
      n++;
    }
    return n;
  }

  // ---------- Markdown 纯文本提取（用于列表摘要与全文搜索） ----------

  static String markdownToPlainText(String md) {
    final lines = <String>[];
    for (final line in md.split('\n')) {
      final t = line.trim();
      if (t.isEmpty) {
        lines.add('');
        continue;
      }
      final stripped = t
          .replaceFirst(RegExp(r'^#{1,6}\s+'), '')
          .replaceFirst(RegExp(r'^\s*>\s?'), '')
          .replaceFirst(RegExp(r'^\s*[-*+]\s+'), '• ')
          .replaceFirst(RegExp(r'^\s*\d+\.\s+'), '• ')
          .replaceAll(RegExp(r'!\[[^\]]*\]\([^)]*\)'), '【图片】')
          .replaceAll(RegExp(r'\[([^\]]*)\]\([^)]*\)'), r'$1')
          .replaceAll('**', '')
          .replaceAll('`', '')
          .trim();
      lines.add(stripped);
    }
    return lines.join('\n');
  }

  /// 保存附件并返回可内嵌的引用（mynotes://attach/xxx）
  static Future<String> saveAttachment(String sourcePath, [String? originalName]) async {
    final ext = p.extension(sourcePath).isNotEmpty
        ? p.extension(sourcePath)
        : '';
    final name = '${newId()}${ext.isNotEmpty ? '$ext' : ''}';
    await Directory(attachmentsDir).create(recursive: true);
    await File(sourcePath).copy(p.join(attachmentsDir, name));
    return 'mynotes://attach/$name';
  }

  /// 把 mynotes:// 附件引用解析为实际路径
  static String resolveAttachment(String uri) {
    final m = RegExp(r'mynotes://attach/([^)]+)$').firstMatch(uri);
    if (m != null) return p.join(attachmentsDir, m.group(1)!);
    return uri;
  }
}
