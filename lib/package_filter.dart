import 'package:kernel/ast.dart';

/// Selects which libraries of a kernel snapshot may be obfuscated.
///
/// The selection is a regular expression matched against the *package name* of
/// a library's import URI, as documented in the README: `FS_PACKAGE=^my_app$`
/// selects `package:my_app/...` and nothing else. The expression is not
/// anchored for you, so `my_app` would also select `package:my_app_models`.
///
/// Libraries that are not `package:` libraries are never selected. A release
/// kernel snapshot has the platform (`dart:core`, `dart:ui`, ...) linked into
/// it, and also carries loose `file:` libraries such as the generated plugin
/// registrant; rewriting either is a good way to break the embedder without
/// hiding anything the author wrote.
class PackageFilter {
  const PackageFilter._(this._packages);

  /// A filter that selects the packages whose name matches [pattern].
  ///
  /// Throws a [FormatException] if [pattern] is not a valid regular
  /// expression.
  factory PackageFilter.matching(String pattern) {
    try {
      return PackageFilter._(RegExp(pattern));
    } on FormatException catch (error) {
      throw FormatException(
        'invalid package pattern: ${error.message}',
        pattern,
      );
    }
  }

  /// A filter that selects nothing, used when no pattern was configured.
  const PackageFilter.none() : this._(null);

  /// Parses the value of `FS_PACKAGE`, treating a missing or empty value as
  /// [PackageFilter.none].
  factory PackageFilter.parse(String? pattern) {
    if (pattern == null || pattern.isEmpty) {
      return const PackageFilter.none();
    }
    return PackageFilter.matching(pattern);
  }

  final RegExp? _packages;

  /// Whether this filter can never select anything, in which case the whole
  /// run can be skipped.
  bool get selectsNothing => _packages == null;

  /// The configured pattern, or null if there is none.
  String? get pattern => _packages?.pattern;

  /// Whether [library] may be obfuscated.
  bool allows(Library library) {
    final RegExp? packages = _packages;
    if (packages == null) {
      return false;
    }
    final String? package = packageOf(library.importUri);
    return package != null && packages.hasMatch(package);
  }

  /// The package name [uri] belongs to, or null if it is not a `package:` URI.
  static String? packageOf(Uri uri) {
    if (!uri.isScheme('package')) {
      return null;
    }
    final List<String> segments = uri.pathSegments;
    return segments.isEmpty ? null : segments.first;
  }

  @override
  String toString() => selectsNothing
      ? 'PackageFilter(none)'
      : 'PackageFilter(${_packages!.pattern})';
}
