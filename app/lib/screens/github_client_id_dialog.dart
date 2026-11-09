// The "paste your OAuth client id" dialog shown before the device flow.
//
// Split out of `github_mirror_screen.dart` for the repo's 250-line cap. A
// `part` so the class can stay library-private: it is an implementation
// detail of that screen and nothing else may construct it.

part of 'github_mirror_screen.dart';

/// Dialog shown when "Connect GitHub" is tapped with no OAuth App client id
/// configured yet. Explains what it is, how to get one, and lets the user
/// paste it in directly — rather than leaving them to discover a buried
/// field on their own. Pops the trimmed client id, or null if cancelled.
class _ClientIdSetupDialog extends StatefulWidget {
  const _ClientIdSetupDialog();

  @override
  State<_ClientIdSetupDialog> createState() => _ClientIdSetupDialogState();
}

class _ClientIdSetupDialogState extends State<_ClientIdSetupDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Icon-only: the setup steps (open github.com/settings/developers, make
    // an OAuth App with Device Flow, paste its client id) live in the repo
    // docs, not on screen.
    return AlertDialog(
      content: IconField(
        icon: Icons.apps,
        semanticLabel: 'Client ID',
        controller: _controller,
        autofocus: true,
      ),
      actions: [
        IconButton(
          onPressed: () => Navigator.of(context).pop(),
          icon: const Icon(Icons.close, semanticLabel: 'Cancel'),
        ),
        IconButton.filled(
          onPressed: () {
            final id = _controller.text.trim();
            if (id.isNotEmpty) Navigator.of(context).pop(id);
          },
          icon: const Icon(Icons.arrow_forward, semanticLabel: 'Continue'),
        ),
      ],
    );
  }
}
