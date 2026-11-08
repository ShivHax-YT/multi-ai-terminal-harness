use std::path::PathBuf;
use std::process::Command;

fn main() {
    println!("cargo:rerun-if-changed=native/launch_gate.swift");
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() != Ok("macos") {
        return;
    }
    let out = PathBuf::from(std::env::var_os("OUT_DIR").expect("OUT_DIR"));
    let arch = match std::env::var("CARGO_CFG_TARGET_ARCH").as_deref() {
        Ok("aarch64") => "arm64",
        Ok("x86_64") => "x86_64",
        _ => panic!("unsupported macOS architecture"),
    };
    let status = Command::new("/usr/bin/xcrun")
        .args([
            "swiftc",
            "-parse-as-library",
            "-emit-library",
            "-static",
            "-O",
            "-target",
        ])
        .arg(format!("{arch}-apple-macos14.4"))
        .arg("native/launch_gate.swift")
        .arg("-o")
        .arg(out.join("libharness_launch_gate.a"))
        .status()
        .expect("Apple Swift compiler");
    assert!(status.success(), "failed to compile the kernel launch gate");
    let sdk = Command::new("/usr/bin/xcrun")
        .arg("--show-sdk-path")
        .output()
        .expect("macOS SDK");
    assert!(sdk.status.success(), "macOS SDK unavailable");
    println!("cargo:rustc-link-search=native={}", out.display());
    println!(
        "cargo:rustc-link-search=native={}/usr/lib/swift",
        String::from_utf8(sdk.stdout).unwrap().trim()
    );
    println!("cargo:rustc-link-lib=static=harness_launch_gate");
    // Test binaries target an older macOS, where the Swift runtime is found by rpath.
    println!("cargo:rustc-link-arg=-Wl,-rpath,/usr/lib/swift");
    println!("cargo:rustc-link-lib=framework=Foundation");
    println!("cargo:rustc-link-lib=framework=LightweightCodeRequirements");
}
