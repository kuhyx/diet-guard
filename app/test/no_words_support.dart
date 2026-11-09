/// The "no words" guard: collects every string the current frame paints (all
/// [RichText], which every [Text] builds, plus [Tooltip] messages, which paint
/// on long-press) and reports the ones that hold a word.
///
/// A word is two or more letters in a row. Allowed without listing: numbers,
/// punctuation, single letters, unit symbols next to a figure ([unitTokens])
/// and the method acronyms kept as DOUBT rows (`MET`). Content (food names,
/// workout labels, typed values) is passed per test as [content].
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Unit symbols and method acronyms that may sit next to a number.
const Set<String> unitTokens = {'kcal', 'kg', 'cm', 'lb', 'st', 'MET'};

final RegExp _word = RegExp('[A-Za-z]{2,}');

/// Every painted string in the current tree (one per [RichText] / tooltip).
List<String> paintedStrings(WidgetTester tester) => [
  for (final w in tester.widgetList<RichText>(find.byType(RichText)))
    w.text.toPlainText(includePlaceholders: false),
  for (final w in tester.widgetList<Tooltip>(find.byType(Tooltip))) ?w.message,
];

/// The words in [text] that are neither units nor part of [content].
List<String> wordsIn(String text, {Set<String> content = const {}}) {
  var rest = text;
  for (final c in content) {
    rest = rest.replaceAll(c, ' ');
  }
  return [
    for (final m in _word.allMatches(rest))
      if (!unitTokens.contains(m.group(0))) m.group(0)!,
  ];
}

/// The painted strings of the current frame that hold a word, prefixed with
/// [where]. Fails when fewer than [minStrings] strings were found (an empty
/// tree must not pass the guard).
List<String> wordyStrings(
  WidgetTester tester, {
  Set<String> content = const {},
  int minStrings = 1,
  String where = '',
}) {
  final strings = paintedStrings(tester);
  expect(
    strings.length,
    greaterThanOrEqualTo(minStrings),
    reason: '$where: guard saw too few painted strings (fail closed)',
  );
  return [
    for (final s in strings)
      if (wordsIn(s, content: content).isNotEmpty) '$where: $s',
  ];
}

/// Fails when a painted string of the current frame holds a word.
void expectNoWords(
  WidgetTester tester, {
  Set<String> content = const {},
  int minStrings = 1,
  String where = '',
}) => expect(
  wordyStrings(tester, content: content, minStrings: minStrings, where: where),
  isEmpty,
  reason: '$where: painted words',
);
