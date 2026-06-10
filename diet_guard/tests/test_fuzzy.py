"""Tests for _fuzzy.py — token-aware fuzzy matching.

Covers both the substring fast path and the per-word token scorer, including
the degenerate empty-input branch that falls back to a whole-string ratio.
"""

from __future__ import annotations

from python_pkg.diet_guard._fuzzy import match_score, token_score


class TestTokenScore:
    """The per-word best-match averaging scorer."""

    def test_empty_query_falls_back_to_ratio(self) -> None:
        """An empty query has no words, so a whole-string ratio is used (0.0)."""
        assert token_score("", "apple") == 0.0

    def test_empty_name_falls_back_to_ratio(self) -> None:
        """An empty name has no words, so the ratio path runs."""
        assert token_score("apple", "") == 0.0

    def test_perfect_word_match(self) -> None:
        """Identical single words score 1.0."""
        assert token_score("apple", "apple") == 1.0

    def test_typo_word_scores_high(self) -> None:
        """A near-miss word (beast/breast) scores well above the 0.6 bar."""
        assert token_score("beast", "breast") > 0.8

    def test_multiword_averages_best_per_word(self) -> None:
        """Each query word takes its best name word; the mean is in (0, 1)."""
        score = token_score("grilled chicken", "chicken breast")
        assert 0.0 < score < 1.0


class TestMatchScore:
    """Substring containment first, then the token scorer."""

    def test_substring_beats_one(self) -> None:
        """A contained query scores above 1.0 (1 + coverage fraction)."""
        assert match_score("breast", "chicken breast") > 1.0

    def test_non_substring_uses_token_score(self) -> None:
        """A typo that is not a substring routes to the token scorer (< 1.0)."""
        assert match_score("beast", "breast") == token_score("beast", "breast")
