import AppKit

// `--probe` keeps the app testable without a GUI: it prints what the services
// actually see, which is how the display and DDC layers were verified before any
// view existed.
if CommandLine.arguments.contains("--probe") {
    Probe.run()
    exit(0)
}

if let index = CommandLine.arguments.firstIndex(of: "--set-mode") {
    MainActor.assumeIsolated {
        SetMode.run(Array(CommandLine.arguments[index...]))
    }
    exit(0)
}

if let index = CommandLine.arguments.firstIndex(of: "--persist-check") {
    MainActor.assumeIsolated {
        PersistCheck.run(Array(CommandLine.arguments[index...]))
    }
    exit(0)
}

if CommandLine.arguments.contains("--test-mode") {
    MainActor.assumeIsolated { ModeTest.run() }
    exit(0)
}

if CommandLine.arguments.contains("--overflow-test") {
    MainActor.assumeIsolated { OverflowTest.run() }
    exit(0)
}

if let index = CommandLine.arguments.firstIndex(of: "--software-test") {
    MainActor.assumeIsolated {
        SoftwareDimmingTest.run(Array(CommandLine.arguments[index...]))
    }
    exit(0)
}

if let index = CommandLine.arguments.firstIndex(of: "--move") {
    MainActor.assumeIsolated { MoveDisplay.run(Array(CommandLine.arguments[index...])) }
    exit(0)
}

if CommandLine.arguments.contains("--arrangement-test") {
    MainActor.assumeIsolated { ArrangementTest.run(CommandLine.arguments) }
    exit(0)
}

if let index = CommandLine.arguments.firstIndex(of: "--hidpi-matrix") {
    MainActor.assumeIsolated { HiDPIMatrix.run(Array(CommandLine.arguments[index...])) }
    exit(0)
}

if let index = CommandLine.arguments.firstIndex(of: "--test-hidpi") {
    MainActor.assumeIsolated { HiDPITest.run(Array(CommandLine.arguments[index...])) }
    exit(0)
}

if let index = CommandLine.arguments.firstIndex(of: "--audit-modes") {
    MainActor.assumeIsolated { ModeAudit.run(Array(CommandLine.arguments[index...])) }
    exit(0)
}

if CommandLine.arguments.contains("--drag-test") {
    MainActor.assumeIsolated { DragTest.run() }
    exit(0)
}

if CommandLine.arguments.contains("--geometry-test") {
    MainActor.assumeIsolated { GeometryTest.run() }
    exit(0)
}

if CommandLine.arguments.contains("--menu-rows") {
    MainActor.assumeIsolated { UIPrefsTest.runMenuRows() }
    exit(0)
}

if CommandLine.arguments.contains("--key-test") {
    MainActor.assumeIsolated { UIPrefsTest.runKeyTest() }
    exit(0)
}

if CommandLine.arguments.contains("--hidpi-test") {
    MainActor.assumeIsolated { HiDPIScaleTest.run(Array(CommandLine.arguments.dropFirst())) }
    exit(0)
}

if CommandLine.arguments.contains("--control-test") {
    MainActor.assumeIsolated { ControlTest.run(CommandLine.arguments) }
    exit(0)
}

if let index = CommandLine.arguments.firstIndex(of: "--flex-hidpi") {
    MainActor.assumeIsolated { FlexibleProbe.run(Array(CommandLine.arguments[index...])) }
    exit(0)
}

if CommandLine.arguments.contains("--probe-virtual") {
    MainActor.assumeIsolated { VirtualProbe.run(CommandLine.arguments) }
    exit(0)
}

if CommandLine.arguments.contains("--selftest") {
    MainActor.assumeIsolated { SelfTest.run() }
    exit(0)
}

if let index = CommandLine.arguments.firstIndex(of: "--render"),
   CommandLine.arguments.count > index + 1 {
    MainActor.assumeIsolated {
        RenderPreview.run(path: CommandLine.arguments[index + 1])
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
