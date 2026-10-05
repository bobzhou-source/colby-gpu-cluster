import Foundation

enum SlurmDataParser {
    private static let maximumDiagnosticCharacters = 400

    static func parse(
        domain: SlurmDataDomain,
        definitions: [SlurmCommandDefinition],
        result: SSHCommandResult,
        observedAt: Date,
        ttl: TimeInterval
    ) -> SlurmDomainObservation {
        let definitionIDs = Set(definitions.map(\.id))
        let split = splitSections(result.raw, definitionIDs: definitionIDs)
        let interrupted = result.timedOut || result.truncated
        let globalDiagnostic = boundedDiagnostic(result.diagnostic)

        var commands: [SlurmCommandObservation] = []
        var tables: [SlurmTable] = []
        var usableCommandCount = 0
        var missingSectionCount = 0

        commands.reserveCapacity(definitions.count)
        tables.reserveCapacity(definitions.count)

        for definition in definitions {
            if let section = split.completed[definition.id] {
                let parsedTable = parseTable(definition: definition, lines: section.lines)
                if section.exitCode == 0 {
                    tables.append(parsedTable)
                    usableCommandCount += 1

                    if interrupted {
                        commands.append(SlurmCommandObservation(
                            commandID: definition.id,
                            parserKind: definition.parserKind,
                            status: .partial,
                            exitCode: section.exitCode,
                            timedOut: result.timedOut,
                            truncated: result.truncated,
                            diagnostic: interruptionDiagnostic(result: result)
                        ))
                    } else {
                        commands.append(SlurmCommandObservation(
                            commandID: definition.id,
                            parserKind: definition.parserKind,
                            status: parsedTable.records.isEmpty ? .empty : .fresh,
                            exitCode: section.exitCode
                        ))
                    }
                } else if interrupted {
                    commands.append(SlurmCommandObservation(
                        commandID: definition.id,
                        parserKind: definition.parserKind,
                        status: .partial,
                        exitCode: section.exitCode,
                        timedOut: result.timedOut,
                        truncated: result.truncated,
                        diagnostic: interruptionDiagnostic(result: result)
                    ))
                } else {
                    let diagnostic = sectionDiagnostic(
                        lines: section.lines,
                        exitCode: section.exitCode
                    )
                    commands.append(SlurmCommandObservation(
                        commandID: definition.id,
                        parserKind: definition.parserKind,
                        status: isPermissionDenied(diagnostic) ? .denied : .unavailable,
                        exitCode: section.exitCode,
                        diagnostic: diagnostic
                    ))
                }
                continue
            }

            if let lines = split.incomplete[definition.id] {
                let parsedTable = parseTable(definition: definition, lines: lines)
                if !parsedTable.records.isEmpty {
                    tables.append(parsedTable)
                    usableCommandCount += 1
                }

                commands.append(SlurmCommandObservation(
                    commandID: definition.id,
                    parserKind: definition.parserKind,
                    status: .partial,
                    exitCode: nil,
                    timedOut: result.timedOut,
                    truncated: result.truncated,
                    diagnostic: interruptionDiagnostic(result: result)
                        ?? "Command section ended without a return-code marker."
                ))
                continue
            }

            if interrupted {
                missingSectionCount += 1
                commands.append(SlurmCommandObservation(
                    commandID: definition.id,
                    parserKind: definition.parserKind,
                    status: .partial,
                    exitCode: nil,
                    timedOut: result.timedOut,
                    truncated: result.truncated,
                    diagnostic: interruptionDiagnostic(result: result)
                        ?? "Command section was not captured."
                ))
            } else if result.exitStatus != 0 {
                let denied = isPermissionDenied(globalDiagnostic)
                commands.append(SlurmCommandObservation(
                    commandID: definition.id,
                    parserKind: definition.parserKind,
                    status: denied ? .denied : .unavailable,
                    exitCode: nil,
                    diagnostic: globalDiagnostic
                        ?? "SSH command exited with status \(result.exitStatus) before this section was captured."
                ))
            } else {
                missingSectionCount += 1
                commands.append(SlurmCommandObservation(
                    commandID: definition.id,
                    parserKind: definition.parserKind,
                    status: .unavailable,
                    exitCode: nil,
                    diagnostic: "Command section is missing from the response."
                ))
            }
        }

        let status = domainStatus(
            commands: commands,
            tables: tables,
            usableCommandCount: usableCommandCount,
            missingSectionCount: missingSectionCount,
            interrupted: interrupted
        )
        let data: SlurmDomainData?
        switch status {
        case .fresh, .empty:
            data = SlurmDomainData(tables: tables)
        case .partial, .stale, .unavailable, .denied:
            data = tables.isEmpty ? nil : SlurmDomainData(tables: tables)
        }

        return SlurmDomainObservation(
            domain: domain,
            observedAt: observedAt,
            expiresAt: observedAt.addingTimeInterval(ttl),
            status: status,
            commands: commands,
            data: data
        )
    }

    private struct CapturedSection {
        let lines: [String]
        let exitCode: Int32
    }

    private struct ProtocolSections {
        var completed: [String: CapturedSection] = [:]
        var incomplete: [String: [String]] = [:]
    }

    private enum ProtocolLine {
        case begin(String)
        case end(String, Int32)
        case malformedEnd(String)
        case output
    }

    private static func splitSections(
        _ raw: String,
        definitionIDs: Set<String>
    ) -> ProtocolSections {
        var sections = ProtocolSections()
        var activeID: String?
        var activeLines: [String] = []

        for substring in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = substring.last == "\r" ? String(substring.dropLast()) : String(substring)
            switch classifyProtocolLine(line, definitionIDs: definitionIDs) {
            case let .begin(id):
                if let activeID, sections.completed[activeID] == nil {
                    sections.incomplete[activeID] = activeLines
                }
                activeID = id
                activeLines.removeAll(keepingCapacity: true)

            case let .end(id, exitCode):
                guard activeID == id else { continue }
                if sections.completed[id] == nil {
                    sections.completed[id] = CapturedSection(lines: activeLines, exitCode: exitCode)
                }
                sections.incomplete[id] = nil
                activeID = nil
                activeLines.removeAll(keepingCapacity: true)

            case let .malformedEnd(id):
                guard activeID == id else { continue }
                if sections.completed[id] == nil {
                    sections.incomplete[id] = activeLines
                }
                activeID = nil
                activeLines.removeAll(keepingCapacity: true)

            case .output:
                if activeID != nil {
                    activeLines.append(line)
                }
            }
        }

        if let activeID, sections.completed[activeID] == nil {
            sections.incomplete[activeID] = activeLines
        }
        return sections
    }

    private static func classifyProtocolLine(
        _ line: String,
        definitionIDs: Set<String>
    ) -> ProtocolLine {
        let beginPrefix = SlurmDataCommands.beginMarker + "|"
        if line.hasPrefix(beginPrefix) {
            let id = String(line.dropFirst(beginPrefix.count))
            if definitionIDs.contains(id), !id.contains("|") {
                return .begin(id)
            }
        }

        let endPrefix = SlurmDataCommands.endMarker + "|"
        if line.hasPrefix(endPrefix) {
            let components = line.split(separator: "|", omittingEmptySubsequences: false)
            guard components.count == 3 else { return .output }
            let id = String(components[1])
            guard definitionIDs.contains(id) else { return .output }
            guard let exitCode = Int32(components[2]) else { return .malformedEnd(id) }
            return .end(id, exitCode)
        }

        return .output
    }

    private static func parseTable(
        definition: SlurmCommandDefinition,
        lines: [String]
    ) -> SlurmTable {
        let records: [SlurmRecord]
        switch definition.parserKind {
        case .pipeTable:
            records = parsePipeTable(lines: lines, columns: definition.columns)
        case .keyValueRecord:
            records = parseKeyValueRecords(lines: lines, columns: definition.columns)
        case .keyValueLines:
            records = parseKeyValueLines(lines: lines, columns: definition.columns)
        case .hierarchicalKeyValue:
            records = parseHierarchicalKeyValue(lines: lines, columns: definition.columns)
        case .plainLines:
            records = parsePlainLines(lines: lines, columns: definition.columns)
        }
        return SlurmTable(name: definition.id, columns: definition.columns, records: records)
    }

    private static func parsePipeTable(
        lines: [String],
        columns: [String]
    ) -> [SlurmRecord] {
        var records: [SlurmRecord] = []
        records.reserveCapacity(lines.count)

        for line in lines where !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            var values = line.split(separator: "|", omittingEmptySubsequences: false).map {
                String($0).trimmingCharacters(in: .whitespaces)
            }
            if values.count == columns.count + 1, values.last?.isEmpty == true {
                values.removeLast()
            }

            var fields: [String: String] = [:]
            fields.reserveCapacity(min(columns.count, values.count))
            for index in 0..<min(columns.count, values.count) {
                fields[columns[index]] = values[index]
            }

            var unknownFields: [String: String] = [:]
            if values.count > columns.count {
                unknownFields.reserveCapacity(values.count - columns.count)
                for index in columns.count..<values.count {
                    unknownFields["ExtraColumn\(index - columns.count + 1)"] = values[index]
                }
            }
            records.append(SlurmRecord(fields: fields, unknownFields: unknownFields))
        }
        return records
    }

    private static func parseKeyValueRecords(
        lines: [String],
        columns: [String]
    ) -> [SlurmRecord] {
        lines.compactMap { line in
            let entries = keyValueEntries(in: line)
            guard !entries.isEmpty else { return nil }
            return makeRecord(entries: entries, columns: columns)
        }
    }

    private static func keyValueEntries(in line: String) -> [(String, String)] {
        let characters = Array(line)
        var starts: [(key: String, valueStart: Int, tokenStart: Int)] = []
        var index = 0

        while index < characters.count {
            while index < characters.count, characters[index].isWhitespace {
                index += 1
            }
            let tokenStart = index
            while index < characters.count,
                  !characters[index].isWhitespace,
                  characters[index] != "=" {
                index += 1
            }
            if index < characters.count, characters[index] == "=", index > tokenStart {
                starts.append((
                    key: String(characters[tokenStart..<index]),
                    valueStart: index + 1,
                    tokenStart: tokenStart
                ))
                index += 1
                while index < characters.count, !characters[index].isWhitespace {
                    index += 1
                }
            } else {
                while index < characters.count, !characters[index].isWhitespace {
                    index += 1
                }
            }
        }

        guard !starts.isEmpty else { return [] }
        var entries: [(String, String)] = []
        entries.reserveCapacity(starts.count)
        for entryIndex in starts.indices {
            let entry = starts[entryIndex]
            let valueEnd = entryIndex + 1 < starts.count
                ? starts[entryIndex + 1].tokenStart
                : characters.count
            let value = String(characters[entry.valueStart..<valueEnd])
                .trimmingCharacters(in: .whitespaces)
            entries.append((entry.key, value))
        }
        return entries
    }

    private static func parseKeyValueLines(
        lines: [String],
        columns: [String]
    ) -> [SlurmRecord] {
        var entries: [(String, String)] = []
        entries.reserveCapacity(lines.count)
        for line in lines {
            guard let separator = line.firstIndex(of: "=") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            let value = line[line.index(after: separator)...]
                .trimmingCharacters(in: .whitespaces)
            entries.append((key, value))
        }
        return entries.isEmpty ? [] : [makeRecord(entries: entries, columns: columns)]
    }

    private static func parseHierarchicalKeyValue(
        lines: [String],
        columns: [String]
    ) -> [SlurmRecord] {
        var records: [SlurmRecord] = []
        var section = ""

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            guard let separator = trimmed.firstIndex(of: ":") else {
                section = trimmed
                continue
            }

            let key = trimmed[..<separator].trimmingCharacters(in: .whitespaces)
            let value = trimmed[trimmed.index(after: separator)...]
                .trimmingCharacters(in: .whitespaces)
            if value.isEmpty {
                section = key
                continue
            }

            records.append(makeRecord(entries: [
                ("Section", section),
                ("Key", key),
                ("Value", value),
            ], columns: columns))
        }
        return records
    }

    private static func parsePlainLines(
        lines: [String],
        columns: [String]
    ) -> [SlurmRecord] {
        let fieldName = columns.first ?? "Line"
        return lines.compactMap { line in
            let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return nil }
            return makeRecord(entries: [(fieldName, value)], columns: columns)
        }
    }

    private static func makeRecord(
        entries: [(String, String)],
        columns: [String]
    ) -> SlurmRecord {
        let recognizedColumns = Set(columns)
        var fields: [String: String] = [:]
        var unknownFields: [String: String] = [:]
        fields.reserveCapacity(min(entries.count, columns.count))

        for (key, value) in entries {
            if recognizedColumns.contains(key) {
                fields[key] = value
            } else {
                unknownFields[key] = value
            }
        }
        return SlurmRecord(fields: fields, unknownFields: unknownFields)
    }

    private static func sectionDiagnostic(lines: [String], exitCode: Int32) -> String {
        boundedDiagnostic(lines: lines)
            ?? "Command exited with status \(exitCode)."
    }

    private static func interruptionDiagnostic(result: SSHCommandResult) -> String? {
        switch (result.timedOut, result.truncated) {
        case (true, true):
            return "Command capture timed out and was truncated."
        case (true, false):
            return "Command capture timed out."
        case (false, true):
            return "Command capture was truncated."
        case (false, false):
            return nil
        }
    }

    private static func boundedDiagnostic(_ diagnostic: String?) -> String? {
        guard let diagnostic else { return nil }
        let trimmed = diagnostic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(maximumDiagnosticCharacters))
    }

    private static func boundedDiagnostic(lines: [String]) -> String? {
        var diagnostic = ""
        diagnostic.reserveCapacity(maximumDiagnosticCharacters)

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if !diagnostic.isEmpty, diagnostic.count < maximumDiagnosticCharacters {
                diagnostic.append("\n")
            }
            let remaining = maximumDiagnosticCharacters - diagnostic.count
            guard remaining > 0 else { break }
            diagnostic.append(contentsOf: trimmed.prefix(remaining))
        }
        return diagnostic.isEmpty ? nil : diagnostic
    }

    private static func isPermissionDenied(_ diagnostic: String?) -> Bool {
        guard let diagnostic else { return false }
        let normalized = diagnostic.lowercased()
        return [
            "permission denied",
            "access denied",
            "access/permission denied",
            "not authorized",
            "authorization denied",
            "insufficient privilege",
            "operation not permitted",
            "user is not allowed",
            "not permitted",
            "administrator privilege",
            "admin privilege",
            "must be an administrator",
            "must have admin",
            "only root",
        ].contains { normalized.contains($0) }
    }

    private static func domainStatus(
        commands: [SlurmCommandObservation],
        tables: [SlurmTable],
        usableCommandCount: Int,
        missingSectionCount: Int,
        interrupted: Bool
    ) -> SlurmCollectionStatus {
        if commands.isEmpty {
            return .empty
        }

        let allSuccessful = commands.allSatisfy {
            $0.status == .fresh || $0.status == .empty
        }
        if allSuccessful {
            return tables.contains { !$0.records.isEmpty } ? .fresh : .empty
        }

        let failures = commands.filter {
            $0.status != .fresh && $0.status != .empty
        }
        if usableCommandCount == 0,
           !failures.isEmpty,
           failures.allSatisfy({ $0.status == .denied }) {
            return .denied
        }

        if interrupted
            || missingSectionCount > 0
            || usableCommandCount > 0
            || failures.contains(where: { $0.status == .partial })
        {
            return .partial
        }
        return .unavailable
    }
}
