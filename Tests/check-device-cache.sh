#!/bin/zsh
set -eu
cd "${0:A:h:h}"
check_dir=$(mktemp -d)
trap 'rm -rf "$check_dir"' EXIT
cat > "$check_dir/main.swift" <<'SWIFT'
import Foundation

enum Config { static var pausedDevices = [String]() }
struct ConnectedDevice {
    enum State: Equatable { case playing(String), paused(String), idle, offline }
}
enum ConnectedDevices {
    static var states: [String: ConnectedDevice.State] = [:]
    static var muted = false
    static var calls = [[String]]()
    static var failMute = false
    static func state(ip: String) -> ConnectedDevice.State { states[ip] ?? .offline }
    static func catt(_ args: [String], timeout: TimeInterval) -> String? {
        calls.append(args)
        if args[2] == "volumemute" { return failMute ? nil : "" }
        return "volume_muted: \(muted ? "True" : "False")"
    }
}
func wait(_ action: (@escaping () -> Void) -> Void) {
    var done = false
    action { done = true }
    let deadline = Date().addingTimeInterval(3)
    while !done && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    assert(done, "Asynchronous device operation did not finish")
}
func refresh() { wait { done in TVControl.refreshAvailability { _ in done() } } }
func muteDevices() { wait { done in TVControl.mute(completion: done) } }
func unmuteAndDrain() { TVControl.unmute(); refresh() }

assert(TVControl.refreshInterval == 300)
assert(!TVControl.needsMute, "No selection must start recording directly")
Config.pausedDevices = ["tv"]
assert(TVControl.needsMute, "An unknown device must be checked")
refresh()
assert(!TVControl.needsMute, "Offline cache must not delay recording")
// Seen offline (often a failed check at app launch): still tried, in the background.
ConnectedDevices.states["tv"] = .idle
var started = false
TVControl.mute { started = true }
assert(started, "Offline cache must start recording at once")
unmuteAndDrain()
assert(ConnectedDevices.calls.map { $0.last! } == ["info", "true", "false"], "A stale offline device must still be muted")

// Netflix: on, but no readable player state → still muted.
ConnectedDevices.states["tv"] = .idle
refresh()
assert(TVControl.needsMute, "A reachable device must be muted whatever its app")
ConnectedDevices.calls = []
muteDevices()
assert(ConnectedDevices.calls.map { $0.last! } == ["info", "true"])
unmuteAndDrain()
assert(ConnectedDevices.calls.contains { $0.suffix(2) == ["volumemute", "false"] })

// Already muted by the user: leave it muted after the dictation.
ConnectedDevices.calls = []
ConnectedDevices.muted = true
muteDevices()
unmuteAndDrain()
assert(ConnectedDevices.calls.map { $0.last! } == ["info"], "Do not unmute a device muted by the user")

// A failed mute must not cause an unsolicited unmute later.
ConnectedDevices.calls = []
ConnectedDevices.muted = false
ConnectedDevices.failMute = true
muteDevices()
unmuteAndDrain()
assert(!ConnectedDevices.calls.contains { $0.last == "false" })

Config.pausedDevices = []
assert(!TVControl.needsMute, "Deselected devices must be ignored immediately")
print("Device cache checks passed")
SWIFT
swiftc Sources/Murmure/TVControl.swift "$check_dir/main.swift" -o "$check_dir/check"
"$check_dir/check"
