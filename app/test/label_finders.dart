/// Finders for text-free controls: they match the spoken label that icons and
/// [Semantics] carry, so tests keep addressing widgets by name without any
/// visible text.
library;

import 'package:diet_guard_app/ui/cues.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Finds an [Icon] with this `semanticLabel`.
Finder byIconLabel(String label) =>
    find.byWidgetPredicate((w) => w is Icon && w.semanticLabel == label);

/// Finds a [Semantics] node with this label.
Finder bySemLabel(String label) => find.byWidgetPredicate(
  (w) => w is Semantics && w.properties.label == label,
);

/// Finds the [TextField] captioned [label] (an [IconField] or a bare
/// [Semantics] wrapper).
Finder fieldByLabel(String label) =>
    find.descendant(of: bySemLabel(label), matching: find.byType(TextField));

/// Finds the tappable control whose icon or semantics carries [label].
Finder controlByLabel(String label) => find
    .ancestor(
      of: byIconLabel(label),
      matching: find.byWidgetPredicate(
        (w) => w is IconButton || w is ButtonStyleButton || w is InkResponse,
      ),
    )
    .first;

/// Finds a [StatusCue] of [kind].
Finder cueOfKind(CueKind kind) =>
    find.byWidgetPredicate((w) => w is StatusCue && w.kind == kind);

/// Finds a [StatusCue] whose spoken label is [label].
Finder cueLabelled(String label) =>
    find.byWidgetPredicate((w) => w is StatusCue && w.semanticLabel == label);

/// Finds the chip ([FilterChip] or [ChoiceChip]) whose icon carries [label].
Finder chipByLabel(String label) => find.ancestor(
  of: byIconLabel(label),
  matching: find.byWidgetPredicate((w) => w is FilterChip || w is ChoiceChip),
);
