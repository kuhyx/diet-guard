/// Shared typo-tolerant string matching, mirroring diet_guard's `_fuzzy.py`.
///
/// Ports the *intent* of `_fuzzy.py`'s scoring -- word-by-word matching so a
/// short typo isn't drowned out by a long multi-word name -- rather than a
/// line-for-line port of `difflib.SequenceMatcher`, which has no direct
/// Dart equivalent. A longest-common-subsequence ratio stands in for
/// SequenceMatcher's matching-blocks algorithm; both converge on
/// near-1.0 for an exact match and fall off smoothly for typos, but scores
/// are not guaranteed bit-identical to the Python implementation for the
/// same inputs.
library;

double _sequenceRatio(String a, String b) {
  if (a.isEmpty && b.isEmpty) return 1;
  if (a.isEmpty || b.isEmpty) return 0;
  final lcs = _longestCommonSubsequenceLength(a, b);
  return 2.0 * lcs / (a.length + b.length);
}

int _longestCommonSubsequenceLength(String a, String b) {
  var previous = List.filled(b.length + 1, 0);
  for (var i = 1; i <= a.length; i++) {
    final current = List.filled(b.length + 1, 0);
    for (var j = 1; j <= b.length; j++) {
      current[j] = a[i - 1] == b[j - 1]
          ? previous[j - 1] + 1
          : (previous[j] > current[j - 1] ? previous[j] : current[j - 1]);
    }
    previous = current;
  }
  return previous[b.length];
}

/// Returns the non-empty whitespace-separated words in [text].
List<String> _words(String text) =>
    text.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();

/// Scores [query] against [name] word-by-word (length-penalty free).
///
/// Mirrors `_fuzzy.token_score`.
double tokenScore(String query, String name) {
  final queryWords = _words(query);
  final nameWords = _words(name);
  if (queryWords.isEmpty || nameWords.isEmpty) {
    return _sequenceRatio(query, name);
  }
  var total = 0.0;
  for (final word in queryWords) {
    var best = 0.0;
    for (final target in nameWords) {
      final score = _sequenceRatio(word, target);
      if (score > best) best = score;
    }
    total += best;
  }
  return total / queryWords.length;
}

/// Scores how well [name] matches [query] (higher is better).
///
/// A substring hit scores at or above 1.0 (boosted by how much of [name]
/// the query covers); otherwise falls back to the token-aware fuzzy score.
/// Mirrors `_fuzzy.match_score`.
double matchScore(String query, String name) {
  if (query.isNotEmpty && name.contains(query)) {
    return 1.0 + query.length / name.length;
  }
  return tokenScore(query, name);
}
