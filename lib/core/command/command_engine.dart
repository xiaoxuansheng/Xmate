/// XMate 命令匹配引擎
///
/// 支持模糊搜索，按匹配质量排序。
/// 匹配策略：精确匹配 > 前缀匹配 > 子串匹配 > 别名匹配
class CommandEngine {
  /// 对命令列表进行模糊搜索，返回按相关性排序的结果
  List<CommandMatch> search(String query, List<CommandMatchable> items) {
    if (query.isEmpty) return [];
    final q = query.toLowerCase().trim();

    final results = <CommandMatch>[];

    for (final item in items) {
      final score = _matchScore(q, item);
      if (score > 0) {
        results.add(CommandMatch(item: item, score: score));
      }
    }

    // 按分数降序排列
    results.sort((a, b) => b.score.compareTo(a.score));

    return results;
  }

  /// 计算匹配分数
  /// 分数越高，匹配质量越好
  int _matchScore(String query, CommandMatchable item) {
    int bestScore = 0;

    for (final term in item.matchTerms) {
      final lower = term.toLowerCase();

      if (lower == query) {
        // 精确匹配：最高优先级
        bestScore = bestScore > 100 ? bestScore : 100;
      } else if (lower.startsWith(query)) {
        // 前缀匹配：高优先级
        final score = 80 + (10 - query.length).clamp(0, 10);
        if (score > bestScore) bestScore = score;
      } else if (lower.contains(query)) {
        // 子串匹配：中优先级
        final pos = lower.indexOf(query);
        final score = 50 + (pos == 0 ? 10 : 0);
        if (score > bestScore) bestScore = score;
      } else {
        // 模糊匹配：字符按序出现
        final score = _fuzzyScore(query, lower);
        if (score > bestScore) bestScore = score;
      }
    }

    return bestScore;
  }

  /// 简单模糊匹配分数
  /// 检查 query 的字符是否按顺序出现在 target 中
  int _fuzzyScore(String query, String target) {
    int qi = 0;
    int matches = 0;
    int consecutiveBonus = 0;

    for (int ti = 0; ti < target.length && qi < query.length; ti++) {
      if (target[ti] == query[qi]) {
        matches++;
        qi++;
        if (ti > 0 && target[ti - 1] == query[qi - 1]) {
          consecutiveBonus += 2;
        }
      }
    }

    // 不是所有字符都匹配
    if (qi < query.length) return 0;

    return 20 + matches + consecutiveBonus;
  }
}

/// 可被命令引擎匹配的接口
abstract class CommandMatchable {
  List<String> get matchTerms;
  String get displayText;
  String? get description;
}

/// 匹配结果
class CommandMatch {
  final CommandMatchable item;
  final int score;

  const CommandMatch({required this.item, required this.score});
}
