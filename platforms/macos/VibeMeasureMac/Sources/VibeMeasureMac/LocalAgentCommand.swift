import Darwin
import Foundation

struct LocalAgentCommandResult {
    let stdout: Data
    let stderr: Data
    let status: Int32
}

enum LocalAgentCommandError: LocalizedError {
    case timedOut
    case outputTooLarge

    var errorDescription: String? {
        switch self {
        case .timedOut: "The usage command timed out."
        case .outputTooLarge: "The usage command produced too much output."
        }
    }
}

enum LocalAgentCommand {
    static func run(executable: URL, arguments: [String], timeout: TimeInterval = 15) throws -> LocalAgentCommandResult {
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errors

        let handles = [output.fileHandleForReading, errors.fileHandleForReading]
        var descriptors = handles.map { pollfd(fd: $0.fileDescriptor, events: Int16(POLLIN), revents: 0) }
        for descriptor in descriptors {
            guard fcntl(descriptor.fd, F_SETFL, O_NONBLOCK) != -1 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }

        try process.run()
        defer {
            if process.isRunning {
                let pid = process.processIdentifier
                // Terminate descendants sharing the subprocess's own group when available.
                kill(getpgid(pid) == pid ? -pid : pid, SIGKILL)
            }
            for handle in handles { try? handle.close() }
        }

        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var streams = [Data(), Data()]
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while process.isRunning || descriptors.contains(where: { $0.fd >= 0 }) {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw LocalAgentCommandError.timedOut }
            let count = poll(&descriptors, nfds_t(descriptors.count), Int32(min(50, ceil(remaining * 1_000))))
            if count < 0 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            for index in descriptors.indices where descriptors[index].revents != 0 {
                let size = read(descriptors[index].fd, &buffer, buffer.count)
                if size == 0 {
                    descriptors[index].fd = -1
                } else if size > 0 {
                    guard streams[index].count + size <= 4 * 1_024 * 1_024 else {
                        throw LocalAgentCommandError.outputTooLarge
                    }
                    streams[index].append(buffer, count: size)
                } else if errno != EAGAIN && errno != EINTR {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }
        }
        return LocalAgentCommandResult(stdout: streams[0], stderr: streams[1], status: process.terminationStatus)
    }
}
