import Darwin
// The kernel checks the actual executable at launch. No app or verifier reads
// candidate contents, and no preflight pathname signature check is performed.
import Foundation
import LightweightCodeRequirements

// Foundation creates a new process group. Give the login CLI foreground TTY
// ownership for human input/Ctrl-C, then return it to the wrapper's group.
private func runInHumanTerminal(_ task: Process, _ fd: Int32) throws -> Bool {
  let previous = tcgetpgrp(fd)
  guard previous == getpgrp() else { return false }
  var blocked = sigset_t()
  var oldMask = sigset_t()
  sigemptyset(&blocked)
  sigaddset(&blocked, SIGTTOU)
  guard pthread_sigmask(SIG_BLOCK, &blocked, &oldMask) == 0 else { return false }
  defer { pthread_sigmask(SIG_SETMASK, &oldMask, nil) }

  // This fixed login mode has no job-control shell to foreground a stopped child.
  // Disable the terminal's suspend character before any provider code starts.
  var original = termios()
  guard tcgetattr(fd, &original) == 0 else { return false }
  var modes = original
  withUnsafeMutableBytes(of: &modes.c_cc) { $0[Int(VSUSP)] = UInt8.max }
  guard tcsetattr(fd, TCSANOW, &modes) == 0 else { return false }
  defer { _ = tcsetattr(fd, TCSANOW, &original) }

  try task.run()
  if !task.isRunning { return true }
  let suspended = task.suspend()
  let childGroup = getpgid(task.processIdentifier)
  guard suspended, childGroup == task.processIdentifier, tcsetpgrp(fd, childGroup) == 0 else {
    // Keep Foundation's handle and collect this child even if foreground transfer fails.
    if task.isRunning { task.terminate() }
    if suspended { _ = task.resume() }
    task.waitUntilExit()
    return false
  }
  _ = task.resume()
  task.waitUntilExit()
  return tcsetpgrp(fd, previous) == 0
}

@_cdecl("harness_probe_start")
public func harnessProbeStart(
  _ path: UnsafePointer<CChar>, _ home: UnsafePointer<CChar>,
  _ team: UnsafePointer<CChar>, _ identifier: UnsafePointer<CChar>,
  _ releaseHash: UnsafePointer<CChar>,
  _ platformTest: Bool, _ argv: UnsafePointer<UnsafePointer<CChar>?>,
  _ argc: Int, _ stdoutFD: Int32, _ stderrFD: Int32, _ stdinFD: Int32,
  _ launchError: UnsafeMutablePointer<Int32>
) -> UnsafeMutableRawPointer? {
  launchError.pointee = 0
  guard #available(macOS 14.4, *) else { return nil }
  if stdinFD >= 0 && (isatty(stdinFD) != 1 || isatty(stdoutFD) != 1 || isatty(stderrFD) != 1) {
    return nil
  }
  if stdinFD >= 0 && tcgetpgrp(stdinFD) != getpgrp() { return nil }
  return autoreleasepool {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: String(cString: path), isDirectory: false)
    task.currentDirectoryURL = URL(fileURLWithPath: "/")
    task.arguments = (0..<argc).compactMap { argv[$0].map { String(cString: $0) } }
    task.environment = [
      "HOME": String(cString: home), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
      "LANG": "en_US.UTF-8", "LC_ALL": "C",
    ]
    task.standardInput =
      stdinFD < 0
      ? FileHandle.nullDevice : FileHandle(fileDescriptor: stdinFD, closeOnDealloc: false)
    task.standardOutput = FileHandle(fileDescriptor: stdoutFD, closeOnDealloc: false)
    task.standardError = FileHandle(fileDescriptor: stderrFD, closeOnDealloc: false)
    do {
      let hex = String(cString: releaseHash)
      var digest: Data? = nil
      if !hex.isEmpty {
        guard hex.count == 40 else { return nil }
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
          let next = hex.index(index, offsetBy: 2)
          guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
          bytes.append(byte)
          index = next
        }
        digest = Data(bytes)
      }
      if platformTest {
        task.launchRequirement = try LaunchCodeRequirement.allOf {
          SigningIdentifier(String(cString: identifier))
          ValidationCategory(.platform)
          if let digest { CodeDirectoryHash(digest) }
          ProcessCodeSigningFlags.isSuperset(of: [.isDynamicallyValid])
        }
      } else {
        task.launchRequirement = try LaunchCodeRequirement.allOf {
          TeamIdentifier(String(cString: team))
          SigningIdentifier(String(cString: identifier))
          ValidationCategory(.developerID)
          if let digest { CodeDirectoryHash(digest) }
          ProcessCodeSigningFlags.isSuperset(of: [.isDynamicallyValid, .isHardenedRuntimeEnforced])
        }
      }
      if stdinFD >= 0 {
        guard try runInHumanTerminal(task, stdinFD) else { return nil }
      } else {
        try task.run()
      }
      return Unmanaged.passRetained(task).toOpaque()
    } catch {
      // A missing executable can advance the fixed candidate search. All other
      // errors stay refusals, and no path or OS diagnostic crosses the bridge.
      var cause: NSError? = error as NSError
      for _ in 0..<4 {
        guard let current = cause else { break }
        if (current.domain == NSPOSIXErrorDomain && current.code == Int(ENOENT))
          || (current.domain == NSCocoaErrorDomain
            && [CocoaError.fileNoSuchFile.rawValue, CocoaError.fileReadNoSuchFile.rawValue]
              .contains(current.code))
        {
          launchError.pointee = ENOENT
          break
        }
        cause = current.userInfo[NSUnderlyingErrorKey] as? NSError
      }
      return nil
    }
  }
}

@_cdecl("harness_probe_poll")
public func harnessProbePoll(_ handle: UnsafeMutableRawPointer, _ code: UnsafeMutablePointer<Int32>)
  -> Bool
{
  let task = Unmanaged<Process>.fromOpaque(handle).takeUnretainedValue()
  if task.isRunning { return false }
  code.pointee = task.terminationReason == .exit ? task.terminationStatus : -task.terminationStatus
  return true
}

@_cdecl("harness_probe_cancel")
public func harnessProbeCancel(_ handle: UnsafeMutableRawPointer) {
  let task = Unmanaged<Process>.fromOpaque(handle).takeUnretainedValue()
  // Use Foundation's owned-process API; never signal a cached numeric PID.
  if task.isRunning { task.terminate() }
}

@_cdecl("harness_probe_wait")
public func harnessProbeWait(_ handle: UnsafeMutableRawPointer) {
  Unmanaged<Process>.fromOpaque(handle).takeUnretainedValue().waitUntilExit()
}

@_cdecl("harness_probe_release")
public func harnessProbeRelease(_ handle: UnsafeMutableRawPointer) {
  Unmanaged<Process>.fromOpaque(handle).release()
}
