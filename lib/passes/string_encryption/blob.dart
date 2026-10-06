/// A single run of text holding every string of a snapshot, and where each of
/// them starts.
class StringBlob {
  const StringBlob._(this.text, this._offsets);

  static const StringBlob empty = StringBlob._('', <String, int>{});

  /// The packed text, before encryption.
  final String text;

  final Map<String, int> _offsets;

  /// The strings the blob was built from.
  Iterable<String> get values => _offsets.keys;

  int get length => text.length;

  /// Where [value] starts in [text].
  int offsetOf(String value) {
    final int? offset = _offsets[value];
    if (offset == null) {
      throw ArgumentError.value(value, 'value', 'not in the blob');
    }
    return offset;
  }

  /// The number of code units saved by packing instead of concatenating.
  int get savedCodeUnits =>
      _offsets.keys.fold<int>(
        0,
        (int sum, String value) => sum + value.length,
      ) -
      text.length;
}

/// Packs strings into a single [StringBlob], overlapping them where they fit
/// into each other.
///
/// Strings in a snapshot share a lot of text - paths, URLs, and the prefixes of
/// generated messages - so the blob is built as an approximate shortest common
/// superstring: strings that already occur inside another one do not take up
/// any room at all, and what is left is chained up by the longest
/// suffix/prefix overlap first, greedily. That is the textbook greedy
/// approximation; packing optimally is NP-hard, and the greedy result is
/// within a small factor while staying linear enough to run on every build.
///
/// Overlapping is what makes the packed text hostile to read: the blob is one
/// run of text where strings start inside each other, so there are no
/// boundaries to recover and dumping it gives up nothing about which parts are
/// used where.
class StringBlobBuilder {
  StringBlobBuilder({this.maxOverlap = 64}) : assert(maxOverlap > 0);

  /// The longest overlap considered when chaining strings up.
  ///
  /// Overlaps are searched from this length downwards, so the cost of building
  /// the blob scales with it while the gain drops off quickly.
  final int maxOverlap;

  final Set<String> _values = <String>{};

  void add(String value) {
    if (value.isNotEmpty) {
      _values.add(value);
    }
  }

  void addAll(Iterable<String> values) => values.forEach(add);

  StringBlob build() {
    if (_values.isEmpty) {
      return StringBlob.empty;
    }

    // Longest first, so a string is only ever found inside a string that is
    // already a root, and ties are broken deterministically.
    final List<String> sorted = _values.toList()
      ..sort((String a, String b) {
        final int byLength = b.length.compareTo(a.length);
        return byLength != 0 ? byLength : a.compareTo(b);
      });

    // Strings that already occur inside a longer one cost nothing to store.
    final roots = <String>[];
    final nested = <String, _Nested>{};
    for (final String value in sorted) {
      _Nested? host;
      for (final String root in roots) {
        final int at = root.indexOf(value);
        if (at >= 0) {
          host = _Nested(root, at);
          break;
        }
      }
      if (host == null) {
        roots.add(value);
      } else {
        nested[value] = host;
      }
    }

    final _Chains chains = _chainByOverlap(roots);

    final buffer = StringBuffer();
    final offsets = <String, int>{};
    for (int head = 0; head < roots.length; head++) {
      if (chains.previous[head] != -1) {
        continue;
      }
      for (int link = head; link != -1; link = chains.next[link]) {
        final String value = roots[link];
        // The tail of what is already written is this string's prefix.
        final int shared = chains.overlap[link];
        offsets[value] = buffer.length - shared;
        buffer.write(shared == 0 ? value : value.substring(shared));
      }
    }

    final String text = buffer.toString();
    nested.forEach((String value, _Nested host) {
      offsets[value] = offsets[host.host]! + host.offset;
    });

    assert(() {
      for (final MapEntry<String, int> entry in offsets.entries) {
        final int offset = entry.value;
        final String value = entry.key;
        if (offset < 0 ||
            offset + value.length > text.length ||
            text.substring(offset, offset + value.length) != value) {
          throw StateError('blob does not hold "$value" at $offset');
        }
      }
      return true;
    }());

    return StringBlob._(text, offsets);
  }

  /// Links [roots] into chains of maximal suffix/prefix overlap.
  _Chains _chainByOverlap(List<String> roots) {
    final int count = roots.length;
    final chains = _Chains(count);
    // Union-find over the chains, to keep a link from closing a cycle.
    final List<int> chainOf = List<int>.generate(count, (int index) => index);

    int findChain(int index) {
      while (chainOf[index] != index) {
        chainOf[index] = chainOf[chainOf[index]];
        index = chainOf[index];
      }
      return index;
    }

    final int longest = roots.fold<int>(
      0,
      (int max, String root) => root.length > max ? root.length : max,
    );
    final int start = longest - 1 < maxOverlap ? longest - 1 : maxOverlap;
    for (int overlap = start; overlap > 0; overlap--) {
      final heads = <String, List<int>>{};
      for (int index = 0; index < count; index++) {
        if (chains.previous[index] == -1 && roots[index].length > overlap) {
          heads
              .putIfAbsent(roots[index].substring(0, overlap), () => <int>[])
              .add(index);
        }
      }
      if (heads.isEmpty) {
        continue;
      }

      for (int tail = 0; tail < count; tail++) {
        final String value = roots[tail];
        if (chains.next[tail] != -1 || value.length <= overlap) {
          continue;
        }
        final List<int>? candidates =
            heads[value.substring(value.length - overlap)];
        if (candidates == null) {
          continue;
        }
        for (final int head in candidates) {
          if (head == tail ||
              chains.previous[head] != -1 ||
              findChain(head) == findChain(tail)) {
            continue;
          }
          chains.next[tail] = head;
          chains.previous[head] = tail;
          chains.overlap[head] = overlap;
          chainOf[findChain(head)] = findChain(tail);
          break;
        }
      }
    }

    return chains;
  }
}

class _Chains {
  _Chains(int count)
    : next = List<int>.filled(count, -1),
      previous = List<int>.filled(count, -1),
      overlap = List<int>.filled(count, 0);

  /// The string that follows this one, or -1.
  final List<int> next;

  /// The string that precedes this one, or -1.
  final List<int> previous;

  /// How many code units this string shares with its predecessor.
  final List<int> overlap;
}

class _Nested {
  const _Nested(this.host, this.offset);

  final String host;
  final int offset;
}
