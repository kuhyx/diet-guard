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
    return AlertDialog(
      title: const Text('One-time GitHub setup needed'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Diet Guard signs in via a GitHub OAuth App (no password '
              'typed into this app). You only have to set this up once:',
            ),
            const SizedBox(height: 12),
            const Text(
              '1. On any device, open '
              'github.com/settings/developers → "New OAuth App".\n'
              '2. Name/Homepage/Callback URL can be anything (device flow '
              "doesn't use the callback) — e.g. "
              '"Diet Guard" and your GitHub profile URL.\n'
              '3. Check "Enable Device Flow", then click "Register '
              'application".\n'
              "4. Copy the Client ID shown on the app's page and paste it "
              'below.',
            ),
            const SizedBox(height: 12),
            const Text(
              'When you connect below, log in with the GitHub account that '
              'has write access to kuhyx/syncs.',
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _controller,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Client ID'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            final id = _controller.text.trim();
            if (id.isNotEmpty) Navigator.of(context).pop(id);
          },
          child: const Text('Continue'),
        ),
      ],
    );
  }
}
