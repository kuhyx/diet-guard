"""The one exception the Kuchnia Wikinga importer raises.

Its own module so :mod:`diet_guard._kuchnia_client`, which raises it, and the
callers that catch it do not have to import each other -- the same shape as
:mod:`diet_guard._sync_errors`.

Deliberately a single class rather than a hierarchy. Every failure mode here
(no credentials, login rejected, a non-200, an unparsable body, a blown
deadline) is handled identically by every caller: report the reason and carry
on without the catering data. A richer taxonomy would cost branch-coverage
tests for a distinction nothing acts on.
"""

from __future__ import annotations


class KuchniaError(Exception):
    """Raised when the catering panel cannot be read."""
