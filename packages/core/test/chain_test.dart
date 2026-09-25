import 'dart:convert';
import 'dart:math';

import 'package:pro_companion_core/store.dart';
import 'package:test/test.dart';

import 'support.dart';

/// #28: the canonical text, the hash, the store's chain and the verifier.
/// chain_vectors_test.dart holds the committed vectors; these hold what the
/// vectors cannot, each against an answer from outside the code under test.
void main() {
  group('canonical text (RFC 8785)', () {
    test("reproduces RFC 8785's own example (section 3.2.2)", () {
      // The RFC's input, escapes and all. The escapes of printable characters are assembled at run
      // time: written into this file as one literal, they were turned into the characters themselves
      // on the way to disk (measured), and the test then parsed a different input from the RFC's.
      String u(String hex) => r'\u' + hex;
      final input = '{"numbers": [333333333.33333329, 1E30, 4.50, 2e-3, 0.000000000000000000000000001], '
          '"string": "${u('20ac')}\$${u('000F')}${u('000a')}A\'${u('0042')}${u('0022')}${u('005c')}'
          r'\\\"\/", "literals": [null, true, false]}';
      expect(input, contains(u('20ac')), reason: 'the input keeps its escapes');
      const expected = r'''{"literals":[null,true,false],"numbers":[333333333.3333333,1e+30,4.5,0.002,1e-27],"string":"€$\u000f\nA'B\"\\\\\"/"}''';
      expect(canonicalJson(jsonDecode(input)), expected);
    });

    test('sorts members by UTF-16 code units, which puts an emoji before U+FB33 (section 3.2.3)', () {
      const input = r'''{"€": "Euro Sign", "\r": "Carriage Return", "דּ": "Hebrew Letter Dalet With Dagesh",
        "1": "One", "😀": "Emoji: Grinning Face", "\u0080": "Control", "ö": "Latin Small Letter O With Diaeresis"}''';
      final keys = (jsonDecode(canonicalJson(jsonDecode(input))) as Map).keys.toList();
      expect(keys, ['\r', '1', '\u0080', 'ö', '€', '\u{1F600}', 'דּ']);
    });

    test('writes numbers as ECMAScript writes them', () {
      // A list, not a map: 0 == -0.0 in Dart, so a map would drop the negative zero case.
      final cases = <(num, String)>[
        (5.0, '5'),
        (-0.0, '0'),
        (1e20, '100000000000000000000'),
        (1e21, '1e+21'),
        (1.5e21, '1.5e+21'),
        (1e-7, '1e-7'),
        (0.000001, '0.000001'),
        (123456789012345680000.0, '123456789012345680000'),
        (0.1, '0.1'),
        (1.7976931348623157e308, '1.7976931348623157e+308'),
        (5e-324, '5e-324'),
        (1e23, '1e+23'),
        (9007199254740992.0, '9007199254740992'),
        (4.35, '4.35'),
        (-1.5, '-1.5'),
        (33.4012, '33.4012'),
        (0, '0'),
        (-7, '-7'),
        (9007199254740991, '9007199254740991'),
      ];
      for (final (n, es) in cases) {
        expect(canonicalJson(n), es, reason: '$n');
      }
    });

    test('escapes only the characters RFC 8785 escapes', () {
      expect(canonicalJson('\u0000\u001f\b\t\n\f\r"\\/\u007f é€'),
          '"${r'\u0000\u001f\b\t\n\f\r\"\\'}/\u007f é€"');
    });

    test('refuses what is not I-JSON rather than writing it', () {
      final refused = <String, Object?>{
        'not a number': double.nan,
        'infinity': double.infinity,
        'an integer past 2^53 - 1': 9007199254740992,
        'a lone surrogate': 'a\uD800b',
        'a key that is not a string': {1: 'x'},
      };
      refused.forEach((reason, value) => expect(() => canonicalJson(value), throwsArgumentError, reason: reason));
    });
  });

  test('the hash is SHA-256 of the UTF-8 text, in lowercase hex, and genesis is 64 zeros', () {
    expect(chainHash('abc'), 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
    expect(chainHash(''), 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855');
    expect(chainHash('€'), 'c4cc90ed3d26f12d4b08a75140970a7904035c31cbb4515a83f19b9003c00d1d');
    expect(genesisHash, '0' * 64);
  });

  group('the store chains each device (criteria 1 and 5)', () {
    test("a first event carries genesis, and each later one its predecessor's hash as stored", () {
      final store = openStore(tempDbPath());
      final events = [for (var i = 0; i < 3; i++) store.append(NewEvent(kind: 'note', source: 'tap', payload: {'n': i}))];
      final texts = store.readCanonical();
      expect(events.map((e) => e.prevHash).toList(), [genesisHash, chainHash(texts[0]), chainHash(texts[1])]);
      expect(texts, [for (final e in events) canonicalJson(e.toWire())], reason: 'the body is the canonical text');
      expect(verifyChains(texts), {store.deviceId: const ChainVerdict.intact()});
    });

    test('the chain continues across a reopen', () {
      final path = tempDbPath();
      final first = EventStore.open(path);
      first.append(const NewEvent(kind: 'note', source: 'tap'));
      first.append(const NewEvent(kind: 'note', source: 'tap'));
      final lastText = first.readCanonical().last;
      first.close();

      final again = openStore(path);
      final next = again.append(const NewEvent(kind: 'note', source: 'tap'));
      expect(next.seq, 3);
      expect(next.prevHash, chainHash(lastText));
      expect(verifyChains(again.readCanonical()).values.single, const ChainVerdict.intact());
    });

    test('a replacement phone is a new device and starts its own chain from genesis', () {
      final original = openStore(tempDbPath());
      original.append(const NewEvent(kind: 'finish', source: 'tap'));
      original.append(const NewEvent(kind: 'finish', source: 'tap'));

      final replacement = openStore(tempDbPath());
      for (final e in original.readAll()) {
        replacement.insert(e);
      }
      final first = replacement.append(const NewEvent(kind: 'finish', source: 'tap'));
      expect(replacement.deviceId, isNot(original.deviceId));
      expect(first.seq, 1, reason: "the other device's events do not advance this one's sequence");
      expect(first.prevHash, genesisHash);
      expect(verifyChains(replacement.readCanonical()), {
        original.deviceId: const ChainVerdict.intact(),
        replacement.deviceId: const ChainVerdict.intact(),
      });
    });
  });

  group('the verifier beyond the vectors', () {
    List<String> chainOf(int n) {
      final store = openStore(tempDbPath());
      for (var i = 0; i < n; i++) {
        store.append(NewEvent(kind: 'note', source: 'tap', payload: {'n': i}));
      }
      return store.readCanonical();
    }

    test('reads the events in any order', () {
      final texts = chainOf(8);
      final altered = [...texts]..[3] = texts[3].replaceFirst('"n":3', '"n":4');
      for (final seed in [1, 2, 3]) {
        expect(verifyChain([...texts]..shuffle(Random(seed))), const ChainVerdict.intact());
        final verdict = verifyChain([...altered]..shuffle(Random(seed)));
        expect([verdict.state, verdict.atSeq, verdict.afterSeq], [ChainState.broken, 5, 4]);
      }
    });

    test('an event with no previous hash breaks the chain there', () {
      final texts = chainOf(3);
      final unchained = (jsonDecode(texts[1]) as Map)..['prev_hash'] = null;
      final verdict = verifyChain([texts[0], canonicalJson(unchained), texts[2]]);
      expect([verdict.state, verdict.atSeq], [ChainState.broken, 2]);
    });

    test('refuses to verify two devices as one chain', () {
      expect(() => verifyChain([...chainOf(1), ...chainOf(1)]), throwsArgumentError);
    });
  });
}
