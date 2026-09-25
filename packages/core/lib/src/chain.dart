import 'dart:convert';

import 'package:crypto/crypto.dart';

/// The per-device hash chain (ADR 001, #28). docs/event-chain.md is the
/// specification; fixtures/chain/ holds the vectors every verifier must agree
/// with, here, on shore (#62) and in burgee.
///
/// An event is hashed as its canonical text: the RFC 8785 (JCS) serialisation
/// of its wire form. That text is what the store keeps, and a verifier hashes
/// the text it was given, never a re-serialisation of it. Each event carries
/// the hash of its device's previous event in `prev_hash`, and a device's
/// first event carries [genesisHash].

/// The `prev_hash` of a device's first event.
const genesisHash = '0000000000000000000000000000000000000000000000000000000000000000';

/// The SHA-256 of [canonical]'s UTF-8 bytes, in lowercase hex.
String chainHash(String canonical) => sha256.convert(utf8.encode(canonical)).toString();

/// [value] serialised by RFC 8785: object members sorted by key (compared as
/// UTF-16 code units), no whitespace, strings with only the escapes the RFC
/// requires, and numbers as ECMAScript prints them. Throws [ArgumentError] on
/// anything that is not I-JSON: a non-string key, a non-finite number, an
/// integer past 2^53 - 1, or a lone surrogate.
String canonicalJson(Object? value) {
  final out = StringBuffer();
  _write(value, out);
  return out.toString();
}

void _write(Object? value, StringBuffer out) {
  switch (value) {
    case null:
      out.write('null');
    case bool():
      out.write(value ? 'true' : 'false');
    case int():
      // I-JSON's safe range, where every integer is exactly one double.
      if (value.abs() > 9007199254740991) {
        throw ArgumentError.value(value, 'value', 'is past 2^53 - 1, which JSON numbers cannot hold exactly');
      }
      out.write(value.toString());
    case double():
      out.write(_number(value));
    case String():
      _string(value, out);
    case List():
      out.write('[');
      for (var i = 0; i < value.length; i++) {
        if (i > 0) out.write(',');
        _write(value[i], out);
      }
      out.write(']');
    case Map():
      final keys = <String>[];
      for (final key in value.keys) {
        if (key is! String) throw ArgumentError.value(key, 'key', 'is not a string');
        keys.add(key);
      }
      keys.sort();
      out.write('{');
      for (var i = 0; i < keys.length; i++) {
        if (i > 0) out.write(',');
        _string(keys[i], out);
        out.write(':');
        _write(value[keys[i]], out);
      }
      out.write('}');
    default:
      throw ArgumentError.value(value, 'value', 'is not JSON');
  }
}

/// ECMAScript's Number.prototype.toString. Dart's own shortest round-trip form
/// agrees with it except for two things, measured for #28: Dart appends `.0`
/// to an integral value (1e20 prints `100000000000000000000.0`) and prints
/// negative zero as `-0.0`.
String _number(double d) {
  if (d.isNaN || d.isInfinite) {
    throw ArgumentError.value(d, 'value', 'is not a finite number');
  }
  if (d == 0) return '0';
  final s = d.toString();
  return s.endsWith('.0') ? s.substring(0, s.length - 2) : s;
}

void _string(String s, StringBuffer out) {
  out.write('"');
  for (var i = 0; i < s.length; i++) {
    final c = s.codeUnitAt(i);
    switch (c) {
      case 0x22:
        out.write(r'\"');
      case 0x5C:
        out.write(r'\\');
      case 0x08:
        out.write(r'\b');
      case 0x09:
        out.write(r'\t');
      case 0x0A:
        out.write(r'\n');
      case 0x0C:
        out.write(r'\f');
      case 0x0D:
        out.write(r'\r');
      default:
        if (c < 0x20) {
          out.write(r'\u00');
          out.write(c.toRadixString(16).padLeft(2, '0'));
        } else if (c >= 0xD800 && c <= 0xDBFF) {
          if (i + 1 >= s.length || s.codeUnitAt(i + 1) < 0xDC00 || s.codeUnitAt(i + 1) > 0xDFFF) {
            throw ArgumentError.value(s, 'value', 'holds a lone surrogate');
          }
          out.writeCharCode(c);
          out.writeCharCode(s.codeUnitAt(++i));
        } else if (c >= 0xDC00 && c <= 0xDFFF) {
          throw ArgumentError.value(s, 'value', 'holds a lone surrogate');
        } else {
          out.writeCharCode(c);
        }
    }
  }
  out.write('"');
}

/// How much of one device's chain stands.
enum ChainState {
  /// Every sequence number from 1 is present and every link holds.
  intact,

  /// Some sequence numbers are missing, and every link that can be checked
  /// holds. A far mark catching up looks like this, and it is not tampering.
  gapped,

  /// A link does not hold. See [ChainVerdict.atSeq].
  broken,
}

class ChainVerdict {
  const ChainVerdict._(this.state, {this.atSeq, this.atUlid, this.afterSeq, this.reason});

  const ChainVerdict.intact() : this._(ChainState.intact);

  const ChainVerdict.gapped() : this._(ChainState.gapped);

  const ChainVerdict.broken({required int atSeq, required String atUlid, int? afterSeq, required String reason})
      : this._(ChainState.broken, atSeq: atSeq, atUlid: atUlid, afterSeq: afterSeq, reason: reason);

  final ChainState state;

  /// The break point: the first event whose recorded link does not hold. The
  /// chain cannot say which side changed, so the event before it
  /// ([afterSeq], when there is one) may be the altered one instead.
  final int? atSeq;
  final String? atUlid;
  final int? afterSeq;
  final String? reason;

  @override
  bool operator ==(Object other) =>
      other is ChainVerdict &&
      other.state == state &&
      other.atSeq == atSeq &&
      other.atUlid == atUlid &&
      other.afterSeq == afterSeq;

  @override
  int get hashCode => Object.hash(state, atSeq, atUlid, afterSeq);

  @override
  String toString() => state == ChainState.broken
      ? 'broken at seq $atSeq ($atUlid)${afterSeq == null ? '' : ' after seq $afterSeq'}: $reason'
      : state.name;
}

class _Link {
  _Link(this.text) : hash = chainHash(text) {
    final wire = jsonDecode(text) as Map;
    ulid = wire['ulid'] as String;
    deviceId = wire['device_id'] as String;
    seq = wire['seq'] as int;
    prevHash = wire['prev_hash'] as String?;
  }

  final String text;
  final String hash;
  late final String ulid;
  late final String deviceId;
  late final int seq;
  late final String? prevHash;
}

/// Verifies one device's chain from the canonical texts of the events held,
/// in any order. They are read in sequence order, then ULID order, so two
/// events holding one number are named the same way by every verifier. The
/// verdict is broken at the first failing event; otherwise gapped when any
/// number is missing; otherwise intact. docs/event-chain.md states every rule.
ChainVerdict verifyChain(Iterable<String> canonicalTexts) {
  final links = [for (final text in canonicalTexts) _Link(text)]
    ..sort((a, b) => a.seq != b.seq ? a.seq.compareTo(b.seq) : a.ulid.compareTo(b.ulid));
  if (links.map((l) => l.deviceId).toSet().length > 1) {
    throw ArgumentError("verifyChain takes one device's events; use verifyChains for several");
  }
  var gapped = false;
  for (var i = 0; i < links.length; i++) {
    final e = links[i];
    ChainVerdict brokenHere(String reason, {int? afterSeq}) =>
        ChainVerdict.broken(atSeq: e.seq, atUlid: e.ulid, afterSeq: afterSeq, reason: reason);

    final prev = e.prevHash;
    if (prev == null) return brokenHere('it carries no previous hash');
    if (e.seq > 1 && prev == genesisHash) {
      return brokenHere('it claims to start the chain at seq ${e.seq}: the events before it were '
          'removed and it was re-linked');
    }
    if (i == 0) {
      if (e.seq == 1 && prev != genesisHash) return brokenHere('the first event does not start from genesis');
      if (e.seq > 1) gapped = true;
      continue;
    }
    final before = links[i - 1];
    if (e.seq == before.seq) return brokenHere('two events hold seq ${e.seq}: the chain forks there');
    if (e.seq == before.seq + 1) {
      if (prev != before.hash) {
        return brokenHere("its previous hash is not seq ${before.seq}'s: one of the two was altered",
            afterSeq: before.seq);
      }
    } else {
      gapped = true;
      if (prev == before.hash) {
        return brokenHere('it links straight to seq ${before.seq} across missing seqs: an event was '
            'removed and the chain re-linked', afterSeq: before.seq);
      }
    }
  }
  return gapped ? const ChainVerdict.gapped() : const ChainVerdict.intact();
}

/// [verifyChain] for each device in [canonicalTexts], keyed by device id and
/// in device-id order.
Map<String, ChainVerdict> verifyChains(Iterable<String> canonicalTexts) {
  final byDevice = <String, List<String>>{};
  for (final text in canonicalTexts) {
    final deviceId = (jsonDecode(text) as Map)['device_id'] as String;
    byDevice.putIfAbsent(deviceId, () => []).add(text);
  }
  final ids = byDevice.keys.toList()..sort();
  return {for (final id in ids) id: verifyChain(byDevice[id]!)};
}
