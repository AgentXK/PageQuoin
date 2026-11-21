import Foundation

struct BuildDiagnostic: Hashable, Sendable {
    enum Severity: Hashable, Sendable {
        case error
        case warning
    }

    struct Source: Hashable, Sendable {
        let file: URL?
        let line: Int
    }

    let severity: Severity
    let message: String
    var location: String? = nil
    var source: Source? = nil
}

struct TectonicDiagnostics {
    private struct Origin {
        let name: String
        let file: URL?
        let canNavigate: Bool
    }

    private static let generatedExtensions: Set<String> = ["aux", "bbl", "blg", "log", "out", "toc", "lof", "lot", "xdv"]
    private static let texExtensions: Set<String> = ["tex", "ltx", "cls", "sty", "clo", "def", "cfg", "fd", "ldf", "ini", "bib", "bst"]
    private static let bridgeMessages: Set<String> = [
        "something bad happened inside XeTeX; its output follows:",
        "the XeTeX engine had an unrecoverable error",
    ]

    let target: URL?
    let projectRoot: URL?

    func parse(output: String, transcript: String, bibliographyLog: String) -> [BuildDiagnostic] {
        let engineIssues = output.split(whereSeparator: \.isNewline).compactMap { line -> BuildDiagnostic? in
            guard let match = line.wholeMatch(of: #/\s*(error|warning):\s+(.+)/#) else { return nil }
            let severity: BuildDiagnostic.Severity = match.1 == "error" ? .error : .warning
            let message = String(match.2)
            if Self.bridgeMessages.contains(message) { return nil }
            if let location = message.wholeMatch(of: #/(.+?):([0-9]+):\s+(.+)/#),
               let line = Int(location.2), line > 0 {
                return diagnostic(severity, String(location.3), origin: origin(named: String(location.1)), line: line)
            }
            return BuildDiagnostic(severity: severity, message: message)
        }
        let texIssues = parseTeXWarnings(transcript)
        let missingCitations = Set(texIssues.compactMap { issue in
            issue.message.firstMatch(of: #/^Citation `(.+?)' .* undefined/#).map { String($0.1) }
        })
        let bibIssues = parseBibTeX(bibliographyLog, missingCitations: missingCitations)
        let hasTeXDetails = !texIssues.isEmpty || engineIssues.contains { $0.severity == .warning && $0.location != nil }
        let hasBibDetails = !bibIssues.isEmpty || !missingCitations.isEmpty
        let hasBibErrors = bibIssues.contains { $0.severity == .error }
        let engine = engineIssues.filter { issue in
            (!hasTeXDetails || !issue.message.hasPrefix("warnings were issued by the TeX engine;"))
                && (!hasBibDetails || !issue.message.hasPrefix("warnings were issued by BibTeX"))
                && (!hasBibErrors || !issue.message.hasPrefix("errors were issued by BibTeX"))
        }
        var seen = Set<BuildDiagnostic>()
        let issues = (engine + texIssues + bibIssues).filter { seen.insert($0).inserted }
        return issues.filter { $0.severity == .error } + issues.filter { $0.severity == .warning }
    }

    private func parseBibTeX(_ log: String, missingCitations: Set<String>) -> [BuildDiagnostic] {
        let lines = log.split(whereSeparator: \.isNewline)
        return lines.indices.compactMap { index in
            let line = lines[index]
            if let match = line.wholeMatch(of: #/(.+?)---line ([0-9]+) of file (.+)/#),
               let number = Int(match.2), number > 0 {
                return diagnostic(.error, String(match.1), origin: origin(named: String(match.3)), line: number)
            }
            let severity: BuildDiagnostic.Severity
            let message: String
            if line.hasPrefix("Warning--") {
                message = String(line.dropFirst("Warning--".count))
                if let match = message.wholeMatch(of: #/I didn't find a database entry for "(.+)"/#),
                   missingCitations.contains(String(match.1)) { return nil }
                severity = .warning
            } else if line.hasPrefix("I couldn't open ") {
                message = String(line)
                severity = .error
            } else {
                return nil
            }
            if index + 1 < lines.count,
               let match = lines[index + 1].wholeMatch(of: #/-{2,3}line ([0-9]+) of file (.+)/#),
               let number = Int(match.1), number > 0 {
                return diagnostic(severity, message, origin: origin(named: String(match.2)), line: number)
            }
            return BuildDiagnostic(severity: severity, message: message)
        }
    }

    private func parseTeXWarnings(_ log: String) -> [BuildDiagnostic] {
        let lines = log.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        var issues: [BuildDiagnostic] = []
        var activeFiles: [Origin?] = []
        var next = 0
        while next < lines.count {
            let entry = lines[next]
            next += 1
            guard let warning = entry.wholeMatch(of: #/\s*(LaTeX(?: Font)?|Package [^:]+|Class [^:]+) Warning:\s*(.+)/#) else {
                // File opens and closes appear between messages. Track bundle and generated
                // file scopes so their line numbers are never assigned to the main document.
                for token in entry.matches(of: #/\((?:"([^"\n]+)"|([^()\n]+))?|\)/#) {
                    if token.0 == ")" {
                        if !activeFiles.isEmpty { activeFiles.removeLast() }
                    } else {
                        let name = (token.1 ?? token.2).map(String.init) ?? ""
                        let candidate = origin(named: name)
                        let ext = (candidate.name as NSString).pathExtension.lowercased()
                        let isFile = candidate.canNavigate || Self.texExtensions.contains(ext) || Self.generatedExtensions.contains(ext)
                        activeFiles.append(isFile ? candidate : nil)
                    }
                }
                continue
            }

            var message = String(warning.2)
            let continuation = "(" + (warning.1.split(separator: " ").last.map(String.init) ?? "") + ")"
            var previous = entry
            while next < lines.count {
                let line = lines[next]
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix(continuation) {
                    message += " " + trimmed.dropFirst(continuation.count).trimmingCharacters(in: .whitespaces)
                    previous = line
                    next += 1
                    continue
                }
                let wraps = previous.utf8.count >= 79
                guard wraps || line.first?.isWhitespace == true, !trimmed.isEmpty,
                      !trimmed.contains(" Warning:"), !trimmed.hasPrefix("("), !trimmed.hasPrefix(")"),
                      !trimmed.hasPrefix("["), !trimmed.hasPrefix("!") else { break }
                message += wraps ? String(line) : " " + trimmed
                previous = line
                next += 1
            }
            if warning.1 != "LaTeX" { message = "\(warning.1): \(message)" }
            let origin = activeFiles.last ?? nil
            if let origin, let match = message.firstMatch(of: #/\s+on input line ([0-9]+)\.?$/#),
               let line = Int(match.1), line > 0 {
                issues.append(diagnostic(.warning, String(message[..<match.range.lowerBound]), origin: origin, line: line))
            } else {
                issues.append(BuildDiagnostic(severity: .warning, message: message))
            }
        }
        let hasUndefinedDetails = issues.contains {
            ($0.message.hasPrefix("Reference ") || $0.message.hasPrefix("Citation ")) && $0.message.contains(" undefined")
        }
        return hasUndefinedDetails ? issues.filter { $0.message != "There were undefined references." } : issues
    }

    private func diagnostic(_ severity: BuildDiagnostic.Severity, _ message: String, origin: Origin,
                            line: Int) -> BuildDiagnostic {
        let source = origin.canNavigate ? BuildDiagnostic.Source(file: origin.file, line: line) : nil
        return BuildDiagnostic(severity: severity, message: message, location: "\(origin.name):\(line)", source: source)
    }

    private func origin(named path: String) -> Origin {
        let name = path.trimmingCharacters(in: .whitespaces)
        if ["texput", "texput.tex", "./texput.tex", "-"].contains(name) {
            let display = target.flatMap(relativePath) ?? "Untitled"
            return Origin(name: display, file: target, canNavigate: true)
        }
        let external = Origin(name: name, file: nil, canNavigate: false)
        guard !name.isEmpty, !name.utf8.contains(0), !name.hasPrefix("\\"),
              let directory = target?.deletingLastPathComponent() else { return external }
        let reported = URL(fileURLWithPath: name, relativeTo: directory)
        let candidates = reported.pathExtension.isEmpty ? [reported, reported.appendingPathExtension("tex")] : [reported]
        for candidate in candidates {
            let file = candidate.standardizedFileURL.resolvingSymlinksInPath()
            guard let relative = relativePath(file), !relative.hasPrefix(BuildArtifactStore.folderName + "/"),
                  !Self.generatedExtensions.contains(file.pathExtension.lowercased()),
                  (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  ProjectFileKind.detect(for: file)?.isEditable == true else { continue }
            return Origin(name: relative, file: file, canNavigate: true)
        }
        return external
    }

    private func relativePath(_ file: URL) -> String? {
        guard let root = projectRoot ?? target?.deletingLastPathComponent() else { return nil }
        let rootComponents = root.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let parts = file.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        guard parts.count > rootComponents.count, parts.starts(with: rootComponents) else { return nil }
        return parts.dropFirst(rootComponents.count).joined(separator: "/")
    }
}
