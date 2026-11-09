/// An icon-captioned text field: the glyph is painted, the words are only a
/// spoken label (see [IconField]).
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// A bordered text field whose caption is an icon plus a spoken label.
///
/// Replaces `InputDecoration(labelText: ...)`: the glyph is painted, the
/// words exist only for screen readers, tests and flutter-web-drive.
class IconField extends StatelessWidget {
  /// Creates a field captioned by [icon].
  const IconField({
    required this.icon,
    required this.semanticLabel,
    this.controller,
    this.keyboardType,
    this.obscure = false,
    this.suffix,
    this.onChanged,
    this.dense = false,
    this.fieldKey,
    this.iconColor,
    this.inputFormatters,
    this.onSubmitted,
    this.autofocus = false,
    this.autocorrect = true,
    super.key,
  });

  /// Input formatters, e.g. digits only.
  final List<TextInputFormatter>? inputFormatters;

  /// Called when the user submits from the keyboard.
  final ValueChanged<String>? onSubmitted;

  /// Whether the field grabs focus when it first appears.
  final bool autofocus;

  /// Whether the keyboard may autocorrect (false for e-mails and secrets).
  final bool autocorrect;

  /// Painted caption.
  final IconData icon;

  /// Tint of [icon]; the theme's default when null.
  final Color? iconColor;

  /// Spoken caption; never painted.
  final String semanticLabel;

  /// Backing controller.
  final TextEditingController? controller;

  /// Keyboard type.
  final TextInputType? keyboardType;

  /// Hides the typed characters.
  final bool obscure;

  /// Trailing widget, e.g. a visibility toggle.
  final Widget? suffix;

  /// Change callback.
  final ValueChanged<String>? onChanged;

  /// Compact vertical padding.
  final bool dense;

  /// Key given to the inner [TextField].
  final Key? fieldKey;

  @override
  Widget build(BuildContext context) {
    // MergeSemantics folds the spoken label into the TextField's own node:
    // a bare `Semantics(textField: true)` wrapper produced a second,
    // disabled textbox beside the real one, so drivers tapped the dead one.
    return MergeSemantics(
      child: Semantics(
        label: semanticLabel,
        child: TextField(
          key: fieldKey,
          controller: controller,
          keyboardType: keyboardType,
          obscureText: obscure,
          onChanged: onChanged,
          onSubmitted: onSubmitted,
          inputFormatters: inputFormatters,
          autofocus: autofocus,
          autocorrect: autocorrect,
          enableSuggestions: autocorrect,
          decoration: InputDecoration(
            prefixIcon: ExcludeSemantics(child: Icon(icon, color: iconColor)),
            prefixIconConstraints: dense
                ? const BoxConstraints(minWidth: 32, minHeight: 32)
                : null,
            suffixIcon: suffix,
            isDense: dense,
          ),
        ),
      ),
    );
  }
}

/// Gives [child] a spoken name without painting any text.
///
/// Wraps `Semantics(label:)`; keeping the string on a `semanticLabel:` line
/// lets line-based text scanners recognise it as accessibility metadata even
/// after the formatter splits `Semantics(` from its arguments.
class SpokenLabel extends StatelessWidget {
  /// Creates a labelled wrapper around [child].
  const SpokenLabel({
    required this.semanticLabel,
    required this.child,
    super.key,
  });

  /// Spoken name; never painted.
  final String semanticLabel;

  /// The widget being named.
  final Widget child;

  @override
  Widget build(BuildContext context) =>
      Semantics(label: semanticLabel, container: true, child: child);
}
