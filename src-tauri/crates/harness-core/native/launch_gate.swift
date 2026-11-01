import AppKit
import Darwin
// The kernel checks the actual executable at launch. No app or verifier reads
// candidate contents, and no preflight pathname signature check is performed.
import Foundation
import LightweightCodeRequirements

// Foundation creates a new process group. Give the login CLI foreground TTY
// ownership for human input/Ctrl-C, then return it to the wrapper's group.
private func runInHumanTerminal(_ task: Process, _ fd: Int32) -> Bool {
  let previous = tcgetpgrp(fd)
  guard previous == getpgrp() else { return false }
  if !task.isRunning { return true }
  guard task.suspend() else { return !task.isRunning }
  var blocked = sigset_t()
  var oldMask = sigset_t()
  sigemptyset(&blocked)
  sigaddset(&blocked, SIGTTOU)
  guard pthread_sigmask(SIG_BLOCK, &blocked, &oldMask) == 0 else {
    task.terminate()
    _ = task.resume()
    return false
  }
  defer { pthread_sigmask(SIG_SETMASK, &oldMask, nil) }
  let childGroup = getpgid(task.processIdentifier)
  guard childGroup == task.processIdentifier, tcsetpgrp(fd, childGroup) == 0 else {
    task.terminate()
    _ = task.resume()
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
  _ argc: Int, _ stdoutFD: Int32, _ stderrFD: Int32, _ stdinFD: Int32
) -> UnsafeMutableRawPointer? {
  guard #available(macOS 14.4, *) else { return nil }
  if stdinFD >= 0 && (isatty(stdinFD) != 1 || isatty(stdoutFD) != 1 || isatty(stderrFD) != 1) {
    return nil
  }
  if stdinFD >= 0 && tcgetpgrp(stdinFD) != getpgrp() { return nil }
  return autoreleasepool {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: String(cString: path))
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
      if !platformTest || !hex.isEmpty {
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
        guard let digest else { return nil }
        task.launchRequirement = try LaunchCodeRequirement.allOf {
          TeamIdentifier(String(cString: team))
          SigningIdentifier(String(cString: identifier))
          ValidationCategory(.developerID)
          CodeDirectoryHash(digest)
          ProcessCodeSigningFlags.isSuperset(of: [.isDynamicallyValid, .isHardenedRuntimeEnforced])
        }
      }
      try task.run()
      if stdinFD >= 0 && !runInHumanTerminal(task, stdinFD) {
        task.terminate()
        return nil
      }
      return Unmanaged.passRetained(task).toOpaque()
    } catch {
      // Never surface a pathname or raw operating-system error to logs.
      return nil
    }
  }
}

// A human's interactive CLI session, on the PTY this wrapper already controls.
// The kernel still checks the vendor, identifier, Developer ID category and
// runtime flags at launch. The reviewed-release hash is not required here: a
// new official release is still the official CLI, and the probe lane above
// keeps its pin. No app input reaches argv.
@_cdecl("harness_session_start")
public func harnessSessionStart(
  _ path: UnsafePointer<CChar>, _ cwd: UnsafePointer<CChar>,
  _ team: UnsafePointer<CChar>, _ identifier: UnsafePointer<CChar>,
  _ platformTest: Bool, _ env: UnsafePointer<UnsafePointer<CChar>?>, _ envc: Int,
  _ argv: UnsafePointer<UnsafePointer<CChar>?>, _ argc: Int,
  _ stdoutFD: Int32, _ stderrFD: Int32, _ stdinFD: Int32
) -> UnsafeMutableRawPointer? {
  guard #available(macOS 14.4, *) else { return nil }
  if stdinFD >= 0 && (isatty(stdinFD) != 1 || isatty(stdoutFD) != 1 || isatty(stderrFD) != 1) {
    return nil
  }
  if stdinFD >= 0 && tcgetpgrp(stdinFD) != getpgrp() { return nil }
  return autoreleasepool {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: String(cString: path))
    task.currentDirectoryURL = URL(fileURLWithPath: String(cString: cwd))
    task.arguments = (0..<argc).compactMap { argv[$0].map { String(cString: $0) } }
    var environment: [String: String] = [:]
    for index in 0..<envc {
      guard let entry = env[index] else { continue }
      let parts = String(cString: entry).split(
        separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
      if parts.count == 2 { environment[String(parts[0])] = String(parts[1]) }
    }
    task.environment = environment
    task.standardInput =
      stdinFD < 0
      ? FileHandle.nullDevice : FileHandle(fileDescriptor: stdinFD, closeOnDealloc: false)
    task.standardOutput = FileHandle(fileDescriptor: stdoutFD, closeOnDealloc: false)
    task.standardError = FileHandle(fileDescriptor: stderrFD, closeOnDealloc: false)
    do {
      if platformTest {
        task.launchRequirement = try LaunchCodeRequirement.allOf {
          SigningIdentifier(String(cString: identifier))
          ValidationCategory(.platform)
          ProcessCodeSigningFlags.isSuperset(of: [.isDynamicallyValid])
        }
      } else {
        task.launchRequirement = try LaunchCodeRequirement.allOf {
          TeamIdentifier(String(cString: team))
          SigningIdentifier(String(cString: identifier))
          ValidationCategory(.developerID)
          ProcessCodeSigningFlags.isSuperset(of: [.isDynamicallyValid, .isHardenedRuntimeEnforced])
        }
      }
      try task.run()
      if stdinFD >= 0 && !runInHumanTerminal(task, stdinFD) {
        task.terminate()
        return nil
      }
      return Unmanaged.passRetained(task).toOpaque()
    } catch {
      return nil
    }
  }
}

// The human picks the folder for a terminal. Main thread only; the app shell
// calls this from run_on_main_thread. Returns a malloc'd path, or nil on cancel.
@_cdecl("harness_choose_folder")
public func harnessChooseFolder() -> UnsafeMutablePointer<CChar>? {
  MainActor.assumeIsolated {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = true
    panel.prompt = "Choose"
    guard panel.runModal() == .OK, let url = panel.url else { return nil }
    return strdup(url.path)
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
