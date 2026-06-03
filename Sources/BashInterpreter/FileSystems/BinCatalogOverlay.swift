import Foundation

/// An ``OverlayProvider`` that synthesises `/bin`, `/usr/bin`, and
/// `/usr/local/bin` (plus the intermediate `/usr` and `/usr/local`
/// directories) from the running shell's command registry and the
/// `BinCatalog` "where would this live on a real macOS install"
/// map.
///
/// The shell never executes real on-disk binaries — every command
/// dispatches in-process through ``Shell/commands``. This provider
/// makes that registry *visible* the way a real Unix `ls /bin`
/// would, so scripts inspecting `/bin/cat` get a sensible answer
/// and `which cat` resolves to `/bin/cat`.
///
/// Layout exposed:
///
/// ```
/// /bin/                       (synthesized leaf)
///   cat, cp, ls, mv, …        (each is a stub file)
/// /usr/                       (synthesized intermediate)
///   bin/                      (synthesized leaf)
///     awk, base64, sed, …
///   local/                    (synthesized intermediate)
///     bin/                    (synthesized leaf)
///       rg, yq, …
/// ```
///
/// All entries are read-only. The overlay layer translates any
/// mutation against these paths into `permissionDenied`.
public final class BinCatalogOverlay: OverlayProvider, @unchecked Sendable {

    public init() {}

    // MARK: Catalog geometry

    /// Catalog leaves — `ls /bin` returns files, never directories.
    private var leafDirectories: Set<String> {
        BinCatalog.knownDirectories
    }

    /// Synthetic intermediate directories implied by the catalog
    /// leaves — `/usr` and `/usr/local` today. Computed once.
    private static let intermediateDirectories: Set<String> = {
        var result: Set<String> = []
        for leaf in BinCatalog.knownDirectories {
            var dir = (leaf as NSString).deletingLastPathComponent
            while dir != "/" && !dir.isEmpty {
                result.insert(dir)
                dir = (dir as NSString).deletingLastPathComponent
            }
        }
        return result
    }()

    /// Names of commands the running shell has installed directly under
    /// `directory` — both catalog tools at their canonical path and any
    /// off-catalog command an embedder added via `install(_:at:)`. Drives the
    /// synthetic file listing the overlay vends, so an external package's
    /// command (e.g. `sqlite3`, `gog`) shows up in `ls /usr/bin` without
    /// needing a `BinCatalog` entry.
    private func registeredCatalogNames(in directory: String) -> [String] {
        let shell = Shell.bashCurrent
        var names = Set<String>()
        // Catalog commands installed at their canonical path.
        for (name, canonical) in BinCatalog.knownPaths
            where (canonical as NSString).deletingLastPathComponent == directory {
            if shell.commandsByPath[canonical] != nil {
                names.insert(name)
            }
        }
        // Any other command installed directly under this directory.
        for installedPath in shell.commandsByPath.keys
            where (installedPath as NSString).deletingLastPathComponent == directory {
            names.insert((installedPath as NSString).lastPathComponent)
        }
        return Array(names)
    }

    private func isLeafDir(_ path: String) -> Bool {
        leafDirectories.contains(path)
    }

    private func isIntermediateDir(_ path: String) -> Bool {
        Self.intermediateDirectories.contains(path)
    }

    private func isSynthesizedFile(_ path: String) -> Bool {
        // Any command installed directly under one of the synthesized leaf
        // directories (/bin, /usr/bin, /usr/local/bin) is a /bin file —
        // catalog or not.
        guard Shell.bashCurrent.commandsByPath[path] != nil else { return false }
        let parent = (path as NSString).deletingLastPathComponent
        if leafDirectories.contains(parent) { return true }
        // Fallback: a catalog command at its canonical path (in case a known
        // path lies outside the configured leaf directories).
        guard let canonical = BinCatalog.knownPaths[
            (path as NSString).lastPathComponent]
        else { return false }
        return canonical == path
    }

    // MARK: OverlayProvider

    public func metadata(_ path: String) async throws -> FileMetadata? {
        if isSynthesizedFile(path) {
            return Self.fileMetadata(path: path)
        }
        if isLeafDir(path) || isIntermediateDir(path) {
            return Self.dirMetadata
        }
        return nil
    }

    public func children(under parent: String) async -> [FileEntry] {
        // Leaf directory (`/bin`, `/usr/bin`, …): emit file entries
        // for each registered catalog command.
        if isLeafDir(parent) {
            return registeredCatalogNames(in: parent)
                .sorted()
                .map { name in
                    let path = (parent as NSString).appendingPathComponent(name)
                    return FileEntry(name: name,
                                     metadata: Self.fileMetadata(path: path))
                }
        }
        // Otherwise: inject any synthetic child *directories* that
        // sit under `parent`. Covers `/` → `[bin, usr]`,
        // `/usr` → `[bin, local]`, `/usr/local` → `[bin]`.
        let all = leafDirectories.union(Self.intermediateDirectories)
        let prefix = parent == "/" ? "/" : parent + "/"
        let directChildNames = all.compactMap { dir -> String? in
            guard dir.hasPrefix(prefix) else { return nil }
            let rest = String(dir.dropFirst(prefix.count))
            return rest.contains("/") ? nil : rest
        }
        return Set(directChildNames)
            .sorted()
            .map {
                FileEntry(name: $0, metadata: Self.dirMetadata)
            }
    }

    public func readData(_ path: String) async throws -> Data {
        guard isSynthesizedFile(path) else {
            throw FileSystemError.notFound(path)
        }
        return Self.stubBytes(
            forCommand: (path as NSString).lastPathComponent)
    }

    // MARK: Stubs

    /// Bytes returned when a script reads a synthesised binary
    /// — e.g. `cat /bin/cat`. There's no real ELF/Mach-O to dump,
    /// so we emit a one-line marker.
    private static func stubBytes(forCommand name: String) -> Data {
        Data("swift-bash built-in command: \(name)\n".utf8)
    }

    /// Synthetic file metadata: regular file, mode `0o755`, owner /
    /// group from the running shell's ``HostInfo`` so identity
    /// stays consistent with `whoami` / `id`. Modification time is
    /// epoch so directory listings stay stable across runs.
    private static func fileMetadata(path: String) -> FileMetadata {
        let host = Shell.bashCurrent.hostInfo
        let stub = stubBytes(
            forCommand: (path as NSString).lastPathComponent)
        let date = Date(timeIntervalSince1970: 0)
        return FileMetadata(
            kind: .file,
            size: Int64(stub.count),
            modifiedAt: date,
            mode: 0o755,
            uid: 0,
            gid: host.gid,
            linkCount: 1,
            accessedAt: date,
            createdAt: date)
    }

    /// Synthetic directory metadata: mode `0o755`, root-owned,
    /// epoch-dated.
    private static var dirMetadata: FileMetadata {
        let host = Shell.bashCurrent.hostInfo
        let date = Date(timeIntervalSince1970: 0)
        return FileMetadata(
            kind: .directory,
            size: 0,
            modifiedAt: date,
            mode: 0o755,
            uid: 0,
            gid: host.gid,
            linkCount: 2,
            accessedAt: date,
            createdAt: date)
    }
}
