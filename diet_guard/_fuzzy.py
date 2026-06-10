"""Shared typo-tolerant string matching for diet_guard.

Two callers need the same similarity logic: the food bank (matching what the
user typed against foods they have logged) and the portions table (matching a
description like "apple" against the known staples).  Both depend on the same
key property -- a short typo must still match a long multi-word name -- so the
scoring lives here once rather than being copied.

The trick is to score *word by word* instead of whole-string to whole-string.
"beast" scores near zero against "grilled chicken breast" as a whole (the
length gap dominates) but ~0.91 against the single token "breast"; taking the
best matching token per query word and averaging is what rescues the short
typo.  Built on :class:`difflib.SequenceMatcher` (stdlib, no dependency).
"""

from __future__ import annotations

from difflib import SequenceMatcher


def token_score(query: str, name: str) -> float:
    """Score ``query`` against ``name`` word-by-word (length-penalty free).

    Each query word is matched against its best word in ``name`` and the
    per-word similarities are averaged, so a short typo matches the relevant
    word in a long multi-word name instead of being drowned out by length.

    Args:
        query: The normalized user query.
        name: The normalized candidate name.

    Returns:
        The mean best-per-word similarity in ``[0, 1]``.
    """
    query_words = query.split()
    name_words = name.split()
    if not query_words or not name_words:
        return SequenceMatcher(None, query, name).ratio()
    total = 0.0
    for word in query_words:
        total += max(
            SequenceMatcher(None, word, target).ratio() for target in name_words
        )
    return total / len(query_words)


def match_score(query: str, name: str) -> float:
    """Score how well ``name`` matches ``query`` (higher is better).

    A substring hit scores at or above 1.0 (boosted by how much of the name the
    query covers, so the tightest containing name wins); otherwise fall back to
    the token-aware fuzzy score, which tolerates per-word typos.

    Args:
        query: The normalized user query.
        name: The normalized candidate name.

    Returns:
        A score; substring matches are ``>= 1.0``, fuzzy matches in ``[0, 1)``.
    """
    if query and query in name:
        return 1.0 + len(query) / len(name)
    return token_score(query, name)
