import Foundation

/// A line diff (longest common subsequence after trimming the common start and end), enough for
/// files of a few thousand lines. Used to show Olo's proposed change and to keep review markers
/// on the right lines while the developer keeps typing.
public enum LineDiff {
    /// One step from the old lines to the new ones. Indices are 0-based.
    public enum Op: Equatable, Sendable {
        case same(Int, Int)
        case removed(Int)
        case added(Int)
    }

    /// Above this many table cells (old changed lines times new changed lines) the middle is shown
    /// as removed then added instead of being matched line by line.
    public static let maxCells = 6_000_000

    public static func ops(_ old: [String], _ new: [String]) -> [Op] {
        // Lines as small integers, so the table compares numbers, not strings.
        var ids: [String: Int] = [:]
        func id(_ s: String) -> Int {
            if let n = ids[s] { return n }
            let n = ids.count
            ids[s] = n
            return n
        }
        let a = old.map(id)
        let b = new.map(id)
        let n = a.count, m = b.count

        var start = 0
        while start < n && start < m && a[start] == b[start] { start += 1 }
        var endA = n, endB = m
        while endA > start && endB > start && a[endA - 1] == b[endB - 1] {
            endA -= 1
            endB -= 1
        }

        var out: [Op] = []
        out.reserveCapacity(max(n, m) + 8)
        for i in 0..<start { out.append(.same(i, i)) }

        let rows = endA - start, cols = endB - start
        if rows == 0 {
            for j in start..<endB { out.append(.added(j)) }
        } else if cols == 0 {
            for i in start..<endA { out.append(.removed(i)) }
        } else if rows * cols > maxCells {
            for i in start..<endA { out.append(.removed(i)) }
            for j in start..<endB { out.append(.added(j)) }
        } else {
            // table[i * w + j]: the longest common subsequence of a[start+i..<endA] and b[start+j..<endB].
            let w = cols + 1
            var table = [Int32](repeating: 0, count: (rows + 1) * w)
            for i in stride(from: rows - 1, through: 0, by: -1) {
                for j in stride(from: cols - 1, through: 0, by: -1) {
                    if a[start + i] == b[start + j] {
                        table[i * w + j] = table[(i + 1) * w + j + 1] + 1
                    } else {
                        table[i * w + j] = max(table[(i + 1) * w + j], table[i * w + j + 1])
                    }
                }
            }
            var i = 0, j = 0
            while i < rows && j < cols {
                if a[start + i] == b[start + j] {
                    out.append(.same(start + i, start + j))
                    i += 1
                    j += 1
                } else if table[(i + 1) * w + j] >= table[i * w + j + 1] {
                    out.append(.removed(start + i))
                    i += 1
                } else {
                    out.append(.added(start + j))
                    j += 1
                }
            }
            while i < rows {
                out.append(.removed(start + i))
                i += 1
            }
            while j < cols {
                out.append(.added(start + j))
                j += 1
            }
        }

        for k in 0..<(n - endA) { out.append(.same(endA + k, endB + k)) }
        return out
    }

    /// For each old line (0-based), the new line (0-based) it became, or nil when it was changed or removed.
    public static func lineMap(_ old: [String], _ new: [String]) -> [Int?] {
        var map = [Int?](repeating: nil, count: old.count)
        for op in ops(old, new) {
            if case .same(let o, let n) = op { map[o] = n }
        }
        return map
    }

    /// Rows for a unified diff: changes with `context` unchanged lines around them; longer unchanged
    /// runs fold into one skipped row. Empty when nothing changed.
    public static func rows(old: [String], new: [String], context: Int = 3) -> [DiffRow] {
        let all = ops(old, new)
        let changed = all.map { op -> Bool in
            if case .same = op { return false }
            return true
        }
        guard changed.contains(true) else { return [] }

        // Distance (in ops) to the nearest change, before and after.
        let far = Int.max / 2
        var distance = [Int](repeating: far, count: all.count)
        var last = -far
        for k in 0..<all.count {
            if changed[k] { last = k }
            distance[k] = k - last
        }
        var next = far
        for k in stride(from: all.count - 1, through: 0, by: -1) {
            if changed[k] { next = k }
            distance[k] = min(distance[k], next - k)
        }

        var out: [DiffRow] = []
        var hidden = 0
        func flushHidden() {
            if hidden > 0 {
                out.append(DiffRow(id: out.count, kind: .skipped, oldLine: nil, newLine: nil, text: "", skipped: hidden))
                hidden = 0
            }
        }
        for (k, op) in all.enumerated() {
            switch op {
            case .same(let o, let n):
                if distance[k] > context {
                    hidden += 1
                } else {
                    flushHidden()
                    out.append(DiffRow(id: out.count, kind: .same, oldLine: o + 1, newLine: n + 1, text: old[o]))
                }
            case .removed(let o):
                flushHidden()
                out.append(DiffRow(id: out.count, kind: .removed, oldLine: o + 1, newLine: nil, text: old[o]))
            case .added(let n):
                flushHidden()
                out.append(DiffRow(id: out.count, kind: .added, oldLine: nil, newLine: n + 1, text: new[n]))
            }
        }
        flushHidden()
        return out
    }

    /// How many lines were added and removed.
    public static func counts(_ rows: [DiffRow]) -> (added: Int, removed: Int) {
        (rows.filter { $0.kind == .added }.count, rows.filter { $0.kind == .removed }.count)
    }
}

/// One row of a unified diff. Line numbers are 1-based.
public struct DiffRow: Equatable, Identifiable, Sendable {
    public enum Kind: Equatable, Sendable { case same, removed, added, skipped }
    public var id: Int
    public var kind: Kind
    public var oldLine: Int?
    public var newLine: Int?
    public var text: String
    /// For a skipped row: how many unchanged lines it stands for.
    public var skipped: Int

    public init(id: Int, kind: Kind, oldLine: Int?, newLine: Int?, text: String, skipped: Int = 0) {
        self.id = id; self.kind = kind; self.oldLine = oldLine; self.newLine = newLine; self.text = text; self.skipped = skipped
    }
}

/// Keeps a review's issues on the right lines while the text changes under them.
public enum IssueRebaser {
    /// The issues that referred to `old`, moved onto `new`. An issue whose first line was changed or
    /// removed is dropped (the next review will look at it again); a fix is kept only when every
    /// line it replaces is unchanged and still consecutive, otherwise the issue stays without one.
    public static func rebase(_ issues: [CodeIssue], from old: String, to new: String) -> [CodeIssue] {
        if old == new || issues.isEmpty { return issues }
        let oldLines = SourceText(old).lines
        let newLines = SourceText(new).lines
        let map = LineDiff.lineMap(oldLines, newLines)
        func mapped(_ line: Int) -> Int? {
            guard line >= 1, line <= map.count, let n = map[line - 1] else { return nil }
            return n + 1
        }
        return issues.compactMap { issue -> CodeIssue? in
            guard let start = mapped(issue.line) else { return nil }
            var moved = issue
            moved.line = start
            if let end = mapped(issue.endLine), end >= start {
                moved.endLine = end
            } else {
                moved.endLine = start + max(0, issue.endLine - issue.line)
            }
            moved.endLine = max(start, min(moved.endLine, newLines.count))
            if let fix = issue.fix {
                moved.fix = rebaseFix(fix, map: map, oldCount: oldLines.count, newCount: newLines.count)
            }
            return moved
        }
    }

    static func rebaseFix(_ fix: CodeFix, map: [Int?], oldCount: Int, newCount: Int) -> CodeFix? {
        let r = FixApplier.clampedRange(fix, count: oldCount)
        if r.upper < r.lower {
            // An insertion before line r.lower (or at the end).
            if r.lower > oldCount { return CodeFix(startLine: newCount + 1, endLine: newCount, replacement: fix.replacement) }
            guard let n = map[r.lower - 1] else { return nil }
            return CodeFix(startLine: n + 1, endLine: n, replacement: fix.replacement)
        }
        guard let first = map[r.lower - 1] else { return nil }
        for (k, line) in (r.lower...r.upper).enumerated() where map[line - 1] != first + k {
            return nil
        }
        return CodeFix(startLine: first + 1, endLine: first + 1 + (r.upper - r.lower), replacement: fix.replacement)
    }
}
