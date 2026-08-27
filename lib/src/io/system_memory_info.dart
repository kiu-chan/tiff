import 'dart:io';

/// A best-effort snapshot of the machine's total and currently-available
/// physical memory, probed by shelling out to a short OS command
/// ([Process.runSync]) — there is no portable Dart/`dart:io` API for this,
/// and no reading at all is possible on a sandboxed mobile OS (iOS/Android
/// don't expose system-wide memory to an app, and `Process` itself isn't
/// available there).
///
/// [probe] never throws: any failure — an unsupported platform, a missing
/// command, output in an unexpected shape — is treated the same as "no
/// reading available" and produces `null`. Callers that need a memory
/// budget regardless (see [TiffAutoDecodeBudget]) should always have a
/// fixed fallback for that case.
class SystemMemoryInfo {
  /// Total physical RAM installed on the machine.
  final int totalBytes;

  /// Currently unused RAM plus RAM the OS could reclaim without swapping
  /// (e.g. macOS's inactive pages, Linux's `MemAvailable`) — a much more
  /// useful number than [totalBytes] for "how much can I safely claim right
  /// now", since most of [totalBytes] is normally already in use by the OS
  /// and other processes.
  final int availableBytes;

  const SystemMemoryInfo({required this.totalBytes, required this.availableBytes});

  static SystemMemoryInfo? _cached;
  static DateTime? _cachedAt;

  /// Reads current system memory, or `null` if unavailable on this
  /// platform/right now (see the class doc comment). Shelling out on every
  /// call would be wasteful for a caller probing repeatedly in a short
  /// window, so a reading is reused for [maxAge] before this shells out
  /// again; pass `Duration.zero` to force a fresh read.
  static SystemMemoryInfo? probe({Duration maxAge = const Duration(seconds: 5)}) {
    final cached = _cached;
    final cachedAt = _cachedAt;
    if (cached != null && cachedAt != null && DateTime.now().difference(cachedAt) < maxAge) {
      return cached;
    }
    final fresh = _probeUncached();
    if (fresh != null) {
      _cached = fresh;
      _cachedAt = DateTime.now();
    }
    return fresh;
  }

  static SystemMemoryInfo? _probeUncached() {
    try {
      if (Platform.isMacOS) return _probeMacOS();
      if (Platform.isLinux) return _probeLinux();
      if (Platform.isWindows) return _probeWindows();
    } catch (_) {
      // Any failure here — Process unsupported, command missing, output we
      // don't recognize — just means "no reading available".
    }
    return null;
  }

  static SystemMemoryInfo? _probeMacOS() {
    final totalResult = Process.runSync('sysctl', ['-n', 'hw.memsize']);
    if (totalResult.exitCode != 0) return null;
    final total = int.tryParse('${totalResult.stdout}'.trim());
    if (total == null) return null;

    final vmStat = Process.runSync('vm_stat', const []);
    if (vmStat.exitCode != 0) return null;
    final output = '${vmStat.stdout}';

    final pageSizeMatch = RegExp(r'page size of (\d+) bytes').firstMatch(output);
    final pageSize = pageSizeMatch != null ? int.parse(pageSizeMatch.group(1)!) : 4096;

    int pagesFor(String label) {
      final match = RegExp('$label:\\s*(\\d+)').firstMatch(output);
      return match != null ? int.parse(match.group(1)!) : 0;
    }

    final available = (pagesFor('Pages free') + pagesFor('Pages inactive')) * pageSize;
    return SystemMemoryInfo(totalBytes: total, availableBytes: available);
  }

  static SystemMemoryInfo? _probeLinux() {
    final file = File('/proc/meminfo');
    if (!file.existsSync()) return null;
    final content = file.readAsStringSync();

    int? kbFor(String label) {
      final match = RegExp('$label:\\s*(\\d+)').firstMatch(content);
      return match != null ? int.parse(match.group(1)!) : null;
    }

    final totalKb = kbFor('MemTotal');
    final availableKb = kbFor('MemAvailable') ?? kbFor('MemFree');
    if (totalKb == null || availableKb == null) return null;
    return SystemMemoryInfo(totalBytes: totalKb * 1024, availableBytes: availableKb * 1024);
  }

  static SystemMemoryInfo? _probeWindows() {
    final result = Process.runSync('wmic', const [
      'OS',
      'get',
      'FreePhysicalMemory,TotalVisibleMemorySize',
      '/Value',
    ]);
    if (result.exitCode != 0) return null;
    final output = '${result.stdout}';

    int? kbFor(String key) {
      final match = RegExp('$key=(\\d+)').firstMatch(output);
      return match != null ? int.parse(match.group(1)!) : null;
    }

    final totalKb = kbFor('TotalVisibleMemorySize');
    final freeKb = kbFor('FreePhysicalMemory');
    if (totalKb == null || freeKb == null) return null;
    return SystemMemoryInfo(totalBytes: totalKb * 1024, availableBytes: freeKb * 1024);
  }
}
