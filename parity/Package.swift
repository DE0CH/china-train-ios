// swift-tools-version:5.9
// The app's planner (ios/App/Model.swift, symlinked) on Linux, checked against china-train's lib/planner.ts by parity.sh.
import PackageDescription
let package = Package(name: "Parity", targets: [.executableTarget(name: "Parity", path: "Sources/Parity")])
