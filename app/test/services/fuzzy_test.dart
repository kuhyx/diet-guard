import 'package:diet_guard_app/services/fuzzy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('matchScore', () {
    test('scores an exact match at least 1.0', () {
      expect(matchScore('banana', 'banana'), greaterThanOrEqualTo(1.0));
    });

    test('boosts a substring match above a typo of similar length', () {
      final substring = matchScore('ban', 'banana');
      final typo = matchScore('bnaana', 'banana');
      expect(substring, greaterThan(typo));
    });

    test(
      'scores an empty query against a name as the fallback token score',
      () {
        expect(matchScore('', 'banana'), greaterThanOrEqualTo(0));
      },
    );

    test('scores a clear mismatch low', () {
      expect(matchScore('xyz', 'banana'), lessThan(0.6));
    });
  });

  group('tokenScore', () {
    test('matches one query word against the best name word', () {
      expect(tokenScore('chicken', 'grilled chicken breast'), 1.0);
    });

    test('falls back to sequence ratio when either side has no words', () {
      expect(tokenScore('', ''), 1.0);
    });
  });
}
