import AppKit
import Darwin
import IOKit
import IOKit.ps
import CoreWLAN
import Carbon.HIToolbox

@_silgen_name("IOHIDEventSystemClientCreate")
func hidClientCreate(_ allocator: CFAllocator?) -> UnsafeMutableRawPointer?

@_silgen_name("IOHIDEventSystemClientSetMatching")
func hidClientSetMatching(_ client: UnsafeMutableRawPointer, _ matching: CFDictionary)

@_silgen_name("IOHIDEventSystemClientCopyServices")
func hidClientCopyServices(_ client: UnsafeMutableRawPointer) -> Unmanaged<CFArray>?

@_silgen_name("IOHIDServiceClientCopyProperty")
func hidServiceCopyProperty(_ service: UnsafeMutableRawPointer, _ key: CFString) -> Unmanaged<AnyObject>?

@_silgen_name("IOHIDServiceClientCopyEvent")
func hidServiceCopyEvent(_ service: UnsafeMutableRawPointer, _ type: Int64, _ options: Int32, _ timestamp: Int64) -> UnsafeMutableRawPointer?

@_silgen_name("IOHIDEventGetFloatValue")
func hidEventGetFloat(_ event: UnsafeMutableRawPointer, _ field: Int32) -> Double

let cyan = NSColor(srgbRed: 0.0, green: 0.94, blue: 1.0, alpha: 1)
let magenta = NSColor(srgbRed: 1.0, green: 0.15, blue: 0.6, alpha: 1)
let yellow = NSColor(srgbRed: 0.99, green: 0.93, blue: 0.25, alpha: 1)
let gib = 1_073_741_824.0
var backdrop: CGFloat = 0.2

func level(_ f: Double, _ warn: Double, _ crit: Double) -> NSColor {
    f < warn ? cyan : (f < crit ? yellow : magenta)
}

func fmtTotal(_ b: UInt64) -> String {
    b >= 1_000_000_000 ? String(format: "%.1f GB", Double(b) / 1e9) : String(format: "%.0f MB", Double(b) / 1e6)
}

struct USBDev {
    let name: String
    let id: String
}

struct AppRow {
    let name: String
    let cpu: Double
    let ram: Double
}

final class Sampler {
    let ramTotal = Double(ProcessInfo.processInfo.physicalMemory)
    var ramUsed = 0.0
    var cpu = 0.0
    var temp: Double?
    var totalDown: UInt64 = 0
    var downRate = 0.0
    var upRate = 0.0
    var history = [Double](repeating: 0, count: 16)
    var diskName = "Macintosh HD"
    var diskUsed = 0.0
    var diskTotal = 0.0
    var apps: [AppRow] = []
    var hasBattery = false
    var batPct = 0.0
    var batCharging = false
    var batPlugged = false
    var batWatts = 0.0
    var batCycles = 0
    var batHealth = 0.0
    var batMinutes: Int?
    var wifiOn = false
    var wifiRSSI = 0
    var wifiNoise = 0
    var wifiRate = 0.0
    var wifiChannel = 0
    var wifiBand = ""
    var wifiSSID: String?
    var usb: [USBDev] = []
    var ports: [String] = []

    private var counter = 0
    private var lastCPU: (UInt32, UInt32, UInt32, UInt32)?
    private var lastNet: [String: (UInt32, UInt32)] = [:]
    private var lastNetTime = 0.0
    private var lastProcCPU: [pid_t: UInt64] = [:]
    private var lastProcTime = 0.0
    private var pathCache: [pid_t: String] = [:]
    private var hid: UnsafeMutableRawPointer?
    private let timebase: (Double, Double)
    private let cores = Double(ProcessInfo.processInfo.activeProcessorCount)

    init() {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        timebase = (Double(tb.numer), Double(tb.denom))
        setupHID()
    }

    func resetBaselines() {
        lastCPU = nil
        lastNetTime = 0
        lastProcCPU = [:]
        lastProcTime = 0
        counter = 0
    }

    func tick() {
        sampleRAM()
        sampleCPU()
        sampleNet()
        if counter % 2 == 0 { temp = readTemp() }
        if counter % 3 == 0 { sampleApps() }
        if counter % 30 == 0 { sampleDisk() }
        if counter % 3 == 0 { sampleWiFi() }
        if counter % 5 == 0 { sampleBattery() }
        counter += 1
    }

    private func sampleRAM() {
        var s = vm_statistics64()
        var c = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let n = Int(c)
        let r = withUnsafeMutablePointer(to: &s) {
            $0.withMemoryRebound(to: integer_t.self, capacity: n) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &c)
            }
        }
        guard r == KERN_SUCCESS else { return }
        let pages = Double(s.internal_page_count) - Double(s.purgeable_count) + Double(s.wire_count) + Double(s.compressor_page_count)
        ramUsed = pages * Double(sysconf(_SC_PAGESIZE))
    }

    private func sampleCPU() {
        var info = host_cpu_load_info()
        var c = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        let n = Int(c)
        let r = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: n) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &c)
            }
        }
        guard r == KERN_SUCCESS else { return }
        let t = info.cpu_ticks
        if let l = lastCPU {
            let user = Double(t.0 &- l.0)
            let sys = Double(t.1 &- l.1)
            let idle = Double(t.2 &- l.2)
            let nice = Double(t.3 &- l.3)
            let total = user + sys + idle + nice
            cpu = total > 0 ? (user + sys + nice) / total * 100 : 0
        }
        lastCPU = (t.0, t.1, t.2, t.3)
    }

    private func sampleNet() {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return }
        defer { freeifaddrs(head) }
        var dIn: UInt64 = 0
        var dOut: UInt64 = 0
        var seen: [String: (UInt32, UInt32)] = [:]
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = p {
            let a = cur.pointee
            if let sa = a.ifa_addr, sa.pointee.sa_family == UInt8(AF_LINK), let data = a.ifa_data {
                let name = String(cString: a.ifa_name)
                if name.hasPrefix("en") {
                    let d = data.assumingMemoryBound(to: if_data.self).pointee
                    seen[name] = (d.ifi_ibytes, d.ifi_obytes)
                    if let l = lastNet[name] {
                        dIn += UInt64(d.ifi_ibytes &- l.0)
                        dOut += UInt64(d.ifi_obytes &- l.1)
                    }
                }
            }
            p = a.ifa_next
        }
        lastNet = seen
        totalDown += dIn
        let now = ProcessInfo.processInfo.systemUptime
        if lastNetTime > 0 {
            let dt = now - lastNetTime
            if dt > 0 && dt < 10 {
                downRate = Double(dIn) / dt
                upRate = Double(dOut) / dt
                history.removeFirst()
                history.append(downRate)
            } else {
                downRate = 0
                upRate = 0
            }
        }
        lastNetTime = now
    }

    private func sampleDisk() {
        let u = URL(fileURLWithPath: "/")
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey, .volumeNameKey]
        guard let v = try? u.resourceValues(forKeys: keys),
              let t = v.volumeTotalCapacity,
              let f = v.volumeAvailableCapacityForImportantUsage else { return }
        diskTotal = Double(t)
        diskUsed = Double(t) - Double(f)
        if let n = v.volumeName { diskName = n }
    }

    private func sampleBattery() {
        var found = false
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] {
            for ps in list {
                guard let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
                      (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
                let cur = (d[kIOPSCurrentCapacityKey] as? NSNumber)?.doubleValue ?? 0
                let mx = (d[kIOPSMaxCapacityKey] as? NSNumber)?.doubleValue ?? 100
                batPct = mx > 0 ? cur / mx * 100 : 0
                batCharging = (d[kIOPSIsChargingKey] as? Bool) ?? false
                batPlugged = (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
                let tte = (d[kIOPSTimeToEmptyKey] as? NSNumber)?.intValue ?? -1
                let ttf = (d[kIOPSTimeToFullChargeKey] as? NSNumber)?.intValue ?? -1
                let t = batCharging ? ttf : tte
                batMinutes = t > 0 ? t : nil
                found = true
            }
        }
        hasBattery = found
        guard found else { return }
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard svc != 0 else { return }
        defer { IOObjectRelease(svc) }
        var cf: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(svc, &cf, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let d = cf?.takeRetainedValue() as? [String: Any] else { return }
        let amp = Int64(bitPattern: (d["Amperage"] as? NSNumber)?.uint64Value ?? 0)
        let volt = (d["Voltage"] as? NSNumber)?.doubleValue ?? 0
        batWatts = volt / 1000 * Double(amp) / 1000
        batCycles = (d["CycleCount"] as? NSNumber)?.intValue ?? 0
        let design = (d["DesignCapacity"] as? NSNumber)?.doubleValue ?? 0
        let raw = (d["AppleRawMaxCapacity"] as? NSNumber)?.doubleValue ?? 0
        batHealth = design > 0 && raw > 0 ? raw / design * 100 : 0
    }

    private func sampleWiFi() {
        guard let i = CWWiFiClient.shared().interface(), i.powerOn() else {
            wifiOn = false
            return
        }
        wifiOn = true
        wifiRSSI = i.rssiValue()
        wifiNoise = i.noiseMeasurement()
        wifiRate = i.transmitRate()
        wifiSSID = i.ssid()
        if let ch = i.wlanChannel() {
            wifiChannel = ch.channelNumber
            switch ch.channelBand {
            case .band2GHz: wifiBand = "2.4G"
            case .band5GHz: wifiBand = "5G"
            case .band6GHz: wifiBand = "6G"
            default: wifiBand = ""
            }
        }
    }

    func sampleUSB() {
        var devs: [USBDev] = []
        var iter: io_iterator_t = 0
        if IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &iter) == KERN_SUCCESS {
            var e = IOIteratorNext(iter)
            while e != 0 {
                let cur = e
                func prop(_ k: String) -> Any? {
                    IORegistryEntryCreateCFProperty(cur, k as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
                }
                let vid = (prop("idVendor") as? NSNumber)?.intValue ?? 0
                let pid = (prop("idProduct") as? NSNumber)?.intValue ?? 0
                let name = (prop("USB Product Name") as? String) ?? "USB Device"
                if vid != 0x05ac && !name.contains("Hub") {
                    devs.append(USBDev(name: name, id: String(format: "%04X:%04X", vid, pid)))
                }
                IOObjectRelease(cur)
                e = IOIteratorNext(iter)
            }
            IOObjectRelease(iter)
        }
        usb = devs.sorted { $0.name < $1.name }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        ports = names
            .filter { $0.hasPrefix("cu.") && !$0.contains("Bluetooth") && !$0.contains("debug-console") && !$0.contains("wlan") }
            .sorted()
    }

    private func setupHID() {
        guard let c = hidClientCreate(kCFAllocatorDefault) else { return }
        let match: [String: Int] = ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5]
        hidClientSetMatching(c, match as CFDictionary)
        hid = c
    }

    private func readTemp() -> Double? {
        guard let c = hid, let services = hidClientCopyServices(c)?.takeRetainedValue() else { return nil }
        let list = services as [AnyObject]
        var sum = 0.0
        var n = 0.0
        for s in list {
            let ptr = Unmanaged.passUnretained(s).toOpaque()
            guard let prop = hidServiceCopyProperty(ptr, "Product" as CFString)?.takeRetainedValue(),
                  let name = prop as? String, name.contains("tdie") else { continue }
            guard let ev = hidServiceCopyEvent(ptr, 15, 0, 0) else { continue }
            let v = hidEventGetFloat(ev, 15 << 16)
            Unmanaged<AnyObject>.fromOpaque(ev).release()
            if v > 10 && v < 130 {
                sum += v
                n += 1
            }
        }
        return n > 0 ? sum / n : nil
    }

    private func appName(_ pid: pid_t) -> String? {
        if let c = pathCache[pid] { return c.isEmpty ? nil : c }
        var buf = [CChar](repeating: 0, count: 4096)
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        var name = ""
        if n > 0 {
            let path = String(cString: buf)
            let parts = path.split(separator: "/")
            if let i = parts.firstIndex(where: { $0.hasSuffix(".app") }) {
                name = String(parts[i].dropLast(4))
            } else if let l = parts.last {
                name = String(l)
            }
        }
        pathCache[pid] = name
        return name.isEmpty ? nil : name
    }

    private func sampleApps() {
        let now = ProcessInfo.processInfo.systemUptime
        let size = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard size > 0 else { return }
        var pids = [pid_t](repeating: 0, count: Int(size) / MemoryLayout<pid_t>.size + 32)
        let bytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard bytes > 0 else { return }
        let count = Int(bytes) / MemoryLayout<pid_t>.size
        let dt = now - lastProcTime
        var cur: [pid_t: UInt64] = [:]
        var agg: [String: (Double, Double)] = [:]
        for i in 0..<count {
            let pid = pids[i]
            if pid <= 0 { continue }
            var ti = proc_taskinfo()
            let want = Int32(MemoryLayout<proc_taskinfo>.size)
            if proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &ti, want) != want { continue }
            let ticks = ti.pti_total_user &+ ti.pti_total_system
            cur[pid] = ticks
            guard let name = appName(pid) else { continue }
            var pct = 0.0
            if lastProcTime > 0, dt > 0, let prev = lastProcCPU[pid], ticks >= prev {
                let ns = Double(ticks - prev) * timebase.0 / timebase.1
                pct = ns / (dt * 1e9) * 100 / cores
            }
            let e = agg[name] ?? (0, 0)
            agg[name] = (e.0 + pct, e.1 + Double(ti.pti_resident_size))
        }
        pathCache = pathCache.filter { cur[$0.key] != nil }
        lastProcCPU = cur
        lastProcTime = now
        apps = agg
            .map { AppRow(name: $0.key, cpu: $0.value.0, ram: $0.value.1 / ramTotal * 100) }
            .sorted { (Int($0.cpu.rounded()), $0.ram) > (Int($1.cpu.rounded()), $1.ram) }
            .prefix(5)
            .map { $0 }
    }
}

final class PanelView: NSView {
    enum Side { case left, mid, right }
    let side: Side
    let s: Sampler

    let design: NSSize
    var editing = false { didSet { needsDisplay = true } }
    private var resizing = false
    private var startMouse = NSPoint.zero
    private var startFrame = NSRect.zero

    init(side: Side, sampler: Sampler, design: NSSize, frame: NSRect) {
        self.side = side
        self.s = sampler
        self.design = design
        super.init(frame: frame)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard editing, let w = window else { return }
        let p = convert(event.locationInWindow, from: nil)
        let hs = max(18, 24 * bounds.width / design.width)
        if p.x > bounds.maxX - hs && p.y > bounds.maxY - hs {
            resizing = true
            startMouse = NSEvent.mouseLocation
            startFrame = w.frame
        } else {
            resizing = false
            w.performDrag(with: event)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard editing, resizing, let w = window else { return }
        let m = NSEvent.mouseLocation
        let nw = max(design.width * 0.4, min(design.width * 3, startFrame.width + (m.x - startMouse.x)))
        let nh = design.height * nw / design.width
        w.setFrame(NSRect(x: startFrame.minX, y: startFrame.maxY - nh, width: nw, height: nh), display: true)
    }

    override func mouseUp(with event: NSEvent) {
        resizing = false
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.compositingOperation = .copy
        NSColor.clear.setFill()
        bounds.fill()
        NSGraphicsContext.current?.compositingOperation = .sourceOver
        let k = bounds.width / design.width
        NSGraphicsContext.current?.cgContext.scaleBy(x: k, y: k)

        let path = panelPath(NSRect(origin: .zero, size: design).insetBy(dx: 0.5, dy: 0.5), 12)
        NSColor.black.withAlphaComponent(backdrop).setFill()
        path.fill()
        cyan.withAlphaComponent(0.4).setStroke()
        path.lineWidth = 1
        path.stroke()

        let acc = NSBezierPath()
        acc.move(to: NSPoint(x: 0, y: 1))
        acc.line(to: NSPoint(x: 34, y: 1))
        acc.lineWidth = 2
        magenta.setStroke()
        acc.stroke()

        switch side {
        case .left: drawLeft()
        case .mid: drawMid()
        case .right: drawRight()
        }

        if editing {
            let d = NSBezierPath(rect: NSRect(origin: .zero, size: design).insetBy(dx: 1.5, dy: 1.5))
            d.lineWidth = 1.5
            d.setLineDash([5, 4], count: 2, phase: 0)
            magenta.setStroke()
            d.stroke()
            let h = NSBezierPath()
            h.move(to: NSPoint(x: design.width - 2, y: design.height - 22))
            h.line(to: NSPoint(x: design.width - 2, y: design.height - 2))
            h.line(to: NSPoint(x: design.width - 22, y: design.height - 2))
            h.close()
            magenta.setFill()
            h.fill()
        }
    }

    private func glow(_ c: NSColor, _ blur: CGFloat) -> NSShadow {
        let sh = NSShadow()
        sh.shadowColor = c.withAlphaComponent(0.8)
        sh.shadowBlurRadius = blur
        sh.shadowOffset = .zero
        return sh
    }

    private func panelPath(_ r: NSRect, _ c: CGFloat) -> NSBezierPath {
        let p = NSBezierPath()
        p.move(to: NSPoint(x: r.minX, y: r.minY))
        p.line(to: NSPoint(x: r.maxX - c, y: r.minY))
        p.line(to: NSPoint(x: r.maxX, y: r.minY + c))
        p.line(to: NSPoint(x: r.maxX, y: r.maxY))
        p.line(to: NSPoint(x: r.minX + c, y: r.maxY))
        p.line(to: NSPoint(x: r.minX, y: r.maxY - c))
        p.close()
        return p
    }

    @discardableResult
    private func text(_ str: String, x: CGFloat, y: CGFloat, size: CGFloat, weight: NSFont.Weight = .medium, color: NSColor = cyan, right: Bool = false, kern: CGFloat = 0, glowing: Bool = true) -> CGFloat {
        var attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: size, weight: weight),
            .foregroundColor: color,
            .kern: kern
        ]
        if glowing { attrs[.shadow] = glow(color, 6) }
        let a = NSAttributedString(string: str, attributes: attrs)
        let w = a.size().width
        a.draw(at: NSPoint(x: right ? x - w : x, y: y))
        return w
    }

    private func dim(_ str: String, x: CGFloat, y: CGFloat, right: Bool = false, kern: CGFloat = 0) {
        text(str, x: x, y: y, size: 9, weight: .bold, color: cyan.withAlphaComponent(0.65), right: right, kern: kern, glowing: false)
    }

    private func rule(_ y: CGFloat, _ x0: CGFloat, _ x1: CGFloat) {
        let p = NSBezierPath()
        p.move(to: NSPoint(x: x0, y: y))
        p.line(to: NSPoint(x: x1, y: y))
        p.lineWidth = 1
        cyan.withAlphaComponent(0.2).setStroke()
        p.stroke()
    }

    private func segBar(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, frac: Double, color: NSColor, segs: Int) {
        let gap: CGFloat = 2
        let sw = (w - gap * CGFloat(segs - 1)) / CGFloat(segs)
        let on = Int((max(0, min(1, frac)) * Double(segs)).rounded())
        let off = NSBezierPath()
        let lit = NSBezierPath()
        for i in 0..<segs {
            let r = NSRect(x: x + CGFloat(i) * (sw + gap), y: y, width: sw, height: h)
            if i < on { lit.appendRect(r) } else { off.appendRect(r) }
        }
        NSColor.white.withAlphaComponent(0.1).setFill()
        off.fill()
        NSGraphicsContext.saveGraphicsState()
        glow(color, 5).set()
        color.withAlphaComponent(0.92).setFill()
        lit.fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    private func metricRaw(_ label: String, detail: String?, detailColor: NSColor, big: String, unit: String, frac: Double, color: NSColor, y: CGFloat, right: CGFloat, barX: CGFloat) {
        dim(label, x: 14, y: y, kern: 2)
        if let d = detail {
            text(d, x: right, y: y, size: 9, weight: .bold, color: detailColor, right: true, glowing: false)
        }
        let w = text(big, x: 14, y: y + 12, size: 22, weight: .bold, color: color)
        text(unit, x: 15 + w, y: y + 22, size: 10, weight: .bold, color: color)
        segBar(x: barX, y: y + 20, w: right - barX, h: 8, frac: frac, color: color, segs: 22)
    }

    private func metric(_ label: String, detail: String?, detailColor: NSColor, frac: Double, color: NSColor, y: CGFloat, right: CGFloat) {
        metricRaw(label, detail: detail, detailColor: detailColor, big: String(format: "%.0f", frac * 100), unit: "%", frac: frac, color: color, y: y, right: right, barX: 70)
    }

    private func cut(_ s: String, _ n: Int) -> String {
        s.count > n ? String(s.prefix(n - 1)) + "…" : s
    }

    private func drawLeft() {
        let R: CGFloat = 246
        let ramF = s.ramUsed / s.ramTotal
        metric("MEM", detail: String(format: "%.1f/%.1f GB", s.ramUsed / gib, s.ramTotal / gib), detailColor: cyan,
               frac: ramF, color: level(ramF, 0.6, 0.85), y: 16, right: R)

        let cpuF = s.cpu / 100
        var td: String?
        var tc = cyan
        if let t = s.temp {
            td = String(format: "%.0f°C", t)
            tc = level(t / 100, 0.6, 0.8)
        }
        metric("CPU", detail: td, detailColor: tc, frac: cpuF, color: level(cpuF, 0.6, 0.85), y: 62, right: R)

        rule(106, 14, R)
        dim("DL TOTAL", x: 14, y: 114, kern: 2)
        text(fmtTotal(s.totalDown), x: R, y: 111, size: 13, weight: .bold, right: true)

        let peak = max(s.history.max() ?? 0, 200_000)
        let n = s.history.count
        let pitch = (R - 14 - 4) / CGFloat(n - 1)
        let off = NSBezierPath()
        let lit = NSBezierPath()
        let last = NSBezierPath()
        for (i, v) in s.history.enumerated() {
            let x = 14 + CGFloat(i) * pitch
            off.appendRect(NSRect(x: x, y: 132, width: 4, height: 30))
            let h = max(2, CGFloat(v / peak) * 30)
            let r = NSRect(x: x, y: 162 - h, width: 4, height: h)
            if i == n - 1 { last.appendRect(r) } else { lit.appendRect(r) }
        }
        NSColor.white.withAlphaComponent(0.08).setFill()
        off.fill()
        NSGraphicsContext.saveGraphicsState()
        glow(cyan, 4).set()
        cyan.withAlphaComponent(0.9).setFill()
        lit.fill()
        glow(magenta, 4).set()
        magenta.setFill()
        last.fill()
        NSGraphicsContext.restoreGraphicsState()

        text(String(format: "▼ %.2f", s.downRate / 1e6), x: 14, y: 169, size: 11, weight: .bold, color: cyan)
        text(String(format: "▲ %.2f", s.upRate / 1e6), x: 100, y: 169, size: 11, weight: .bold, color: magenta)
        dim("MB/s", x: R, y: 172, right: true)
    }

    private func drawMid() {
        let R: CGFloat = 266
        if s.hasBattery {
            let f = s.batPct / 100
            let c = s.batCharging ? cyan : level(1 - f, 0.8, 0.9)
            var state = s.batCharging ? "CHARGING" : (s.batPlugged ? "AC" : "ON BATTERY")
            if let m = s.batMinutes { state += String(format: " %d:%02d", m / 60, m % 60) }
            metricRaw("BAT", detail: state, detailColor: c, big: String(format: "%.0f", s.batPct), unit: "%", frac: f, color: c, y: 14, right: R, barX: 70)
            var info = String(format: "%+.1f W", s.batWatts)
            if s.batCycles > 0 { info += "  \(s.batCycles) CYC" }
            if s.batHealth > 0 { info += String(format: "  %.0f%% HEALTH", s.batHealth) }
            dim(info, x: 14, y: 56)
        } else {
            dim("BAT", x: 14, y: 14, kern: 2)
            text("NO BATTERY", x: 14, y: 30, size: 14, weight: .bold, color: yellow)
        }

        rule(74, 14, R)

        if s.wifiOn && s.wifiRSSI != 0 {
            let q = max(0, min(1, Double(s.wifiRSSI + 90) / 60))
            let c = level(1 - q, 0.45, 0.75)
            var label = "WIFI"
            if let n = s.wifiSSID, !n.isEmpty { label += " " + cut(n.uppercased(), 14) }
            var ch = "CH \(s.wifiChannel)"
            if !s.wifiBand.isEmpty { ch += " " + s.wifiBand }
            metricRaw(label, detail: ch, detailColor: cyan, big: "\(s.wifiRSSI)", unit: "dBm", frac: q, color: c, y: 80, right: R, barX: 92)
            dim(String(format: "TX %.0f MBPS  NOISE %d  SNR %d", s.wifiRate, s.wifiNoise, s.wifiRSSI - s.wifiNoise), x: 14, y: 122)
        } else {
            dim("WIFI", x: 14, y: 80, kern: 2)
            text("OFFLINE", x: 14, y: 96, size: 14, weight: .bold, color: magenta)
        }

        rule(138, 14, R)
        dim("USB / SERIAL", x: 14, y: 146, kern: 2)
        dim("\(s.usb.count) DEV  \(s.ports.count) TTY", x: R, y: 146, right: true)

        let portShow = min(s.ports.count, 1)
        let usbShow = min(s.usb.count, 3 - portShow)
        var y: CGFloat = 161
        for d in s.usb.prefix(usbShow) {
            text(cut(d.name, 22), x: 14, y: y, size: 10, weight: .medium, color: NSColor.white.withAlphaComponent(0.92))
            text(d.id, x: R, y: y, size: 10, weight: .bold, color: cyan, right: true, glowing: false)
            y += 14
        }
        for p in s.ports.prefix(portShow) {
            let n = p.hasPrefix("cu.") ? String(p.dropFirst(3)) : p
            text("▸ " + cut(n, 30), x: 14, y: y, size: 10, weight: .bold, color: magenta)
            y += 14
        }
        if usbShow + portShow == 0 {
            dim("NO DEVICE", x: 14, y: 161)
        }
    }

    private func drawRight() {
        let R: CGFloat = 286
        let usedF = s.diskTotal > 0 ? s.diskUsed / s.diskTotal : 0
        metric("DISK", detail: s.diskName.uppercased(), detailColor: cyan, frac: usedF, color: level(usedF, 0.7, 0.8), y: 16, right: R)
        dim(String(format: "%.1f GB FREE / %.1f GB", (s.diskTotal - s.diskUsed) / 1e9, s.diskTotal / 1e9), x: 14, y: 58)

        rule(78, 14, R)
        dim("PROC", x: 14, y: 88, kern: 2)
        dim("CPU", x: 232, y: 88, right: true, kern: 2)
        dim("MEM", x: R, y: 88, right: true, kern: 2)

        for (i, a) in s.apps.enumerated() {
            let y = CGFloat(106 + Double(i) * 16.5)
            let name = a.name.count > 20 ? String(a.name.prefix(19)) + "…" : a.name
            text(name, x: 14, y: y, size: 10.5, weight: .medium, color: NSColor.white.withAlphaComponent(0.92))
            text(String(format: "%.0f%%", a.cpu), x: 232, y: y, size: 10.5, weight: .bold, color: level(a.cpu / 100, 0.2, 0.5), right: true, glowing: false)
            text(String(format: "%.0f%%", a.ram), x: R, y: y, size: 10.5, weight: .bold, color: level(a.ram / 100, 0.2, 0.4), right: true, glowing: false)
        }
    }
}

final class USBWatcher {
    var onChange: () -> Void = {}
    private var port: IONotificationPortRef?
    private var addIter: io_iterator_t = 0
    private var remIter: io_iterator_t = 0

    private static func drain(_ it: io_iterator_t) {
        var s = IOIteratorNext(it)
        while s != 0 {
            IOObjectRelease(s)
            s = IOIteratorNext(it)
        }
    }

    func start() {
        guard let p = IONotificationPortCreate(kIOMainPortDefault) else { return }
        port = p
        CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(p).takeUnretainedValue(), .commonModes)
        let cb: IOServiceMatchingCallback = { ref, iter in
            USBWatcher.drain(iter)
            guard let ref = ref else { return }
            Unmanaged<USBWatcher>.fromOpaque(ref).takeUnretainedValue().onChange()
        }
        let me = Unmanaged.passUnretained(self).toOpaque()
        IOServiceAddMatchingNotification(p, kIOFirstMatchNotification, IOServiceMatching("IOUSBHostDevice"), cb, me, &addIter)
        USBWatcher.drain(addIter)
        IOServiceAddMatchingNotification(p, kIOTerminatedNotification, IOServiceMatching("IOUSBHostDevice"), cb, me, &remIter)
        USBWatcher.drain(remIter)
    }
}

final class HotKey {
    var onPress: () -> Void = {}
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?

    func register(keyCode: UInt32, modifiers: UInt32) {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, data in
            guard let data = data else { return noErr }
            Unmanaged<HotKey>.fromOpaque(data).takeUnretainedValue().onPress()
            return noErr
        }, 1, &spec, me, &handler)
        let id = EventHotKeyID(signature: OSType(0x53444B59), id: 1)
        RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &ref)
    }
}

final class HUDWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class Controller: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let sampler = Sampler()
    let usbWatcher = USBWatcher()
    let hotKey = HotKey()
    let defaults = UserDefaults.standard
    let desktopLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) - 1)
    let titles = ["MEM / CPU / NET", "BAT / WIFI / USB", "DISK / PROC"]
    var windows: [HUDWindow] = []
    var views: [PanelView] = []
    var designs: [NSSize] = []
    var timer: Timer?
    var asleep = false
    var locked = false
    var editing = false
    var statusItem: NSStatusItem?
    var editItem: NSMenuItem?
    var panelItems: [NSMenuItem] = []
    var bgItems: [NSMenuItem] = []

    func defaultRect(_ i: Int, _ size: NSSize, _ vf: NSRect) -> NSRect {
        let margin: CGFloat = 10
        let x: CGFloat
        switch i {
        case 0: x = vf.minX + margin
        case 1: x = vf.minX + margin + 260 + margin
        default: x = vf.maxX - size.width - margin
        }
        return NSRect(x: x, y: vf.maxY - size.height - margin, width: size.width, height: size.height)
    }

    func savedRect(_ i: Int, _ size: NSSize) -> NSRect? {
        guard let str = defaults.string(forKey: "frame.\(i)") else { return nil }
        let r = NSRectFromString(str)
        guard r.width >= size.width * 0.4, NSScreen.screens.contains(where: { $0.frame.intersects(r) }) else { return nil }
        let h = size.height * r.width / size.width
        return NSRect(x: r.minX, y: r.maxY - h, width: r.width, height: h)
    }

    func saveFrames() {
        for (i, w) in windows.enumerated() {
            defaults.set(NSStringFromRect(w.frame), forKey: "frame.\(i)")
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let screen = NSScreen.screens.first else {
            NSApp.terminate(nil)
            return
        }
        let vf = screen.visibleFrame
        if let b = defaults.object(forKey: "backdrop") as? Double { backdrop = CGFloat(b) }
        designs = [NSSize(width: 260, height: 190), NSSize(width: 280, height: 210), NSSize(width: 300, height: 190)]
        let sides: [PanelView.Side] = [.left, .mid, .right]
        for i in 0..<3 {
            let rect = savedRect(i, designs[i]) ?? defaultRect(i, designs[i], vf)
            let w = HUDWindow(contentRect: rect, styleMask: .borderless, backing: .buffered, defer: false)
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            w.ignoresMouseEvents = true
            w.isReleasedWhenClosed = false
            w.level = desktopLevel
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            let v = PanelView(side: sides[i], sampler: sampler, design: designs[i], frame: NSRect(origin: .zero, size: rect.size))
            w.contentView = v
            if !defaults.bool(forKey: "hidden.\(i)") { w.orderFrontRegardless() }
            windows.append(w)
            views.append(v)
            NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: w, queue: .main) { [weak self] _ in
                self?.evaluate()
            }
        }
        setupMenu()
        hotKey.onPress = { [weak self] in self?.toggleEdit() }
        hotKey.register(keyCode: UInt32(kVK_ANSI_E), modifiers: UInt32(cmdKey | optionKey))

        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.asleep = true
            self?.evaluate()
        }
        ws.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.asleep = false
            self?.evaluate()
        }
        let dc = DistributedNotificationCenter.default()
        dc.addObserver(forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            self?.locked = true
            self?.evaluate()
        }
        dc.addObserver(forName: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            self?.locked = false
            self?.evaluate()
        }
        sampler.sampleUSB()
        usbWatcher.onChange = { [weak self] in self?.usbChanged() }
        usbWatcher.start()
        start()
    }

    func setupMenu() {
        let it = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let b = it.button {
            if let img = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: nil) {
                b.image = img
            } else {
                b.title = "SD"
            }
        }
        let m = NSMenu()
        m.delegate = self
        let e = NSMenuItem(title: "Edit layout", action: #selector(toggleEdit), keyEquivalent: "e")
        e.target = self
        e.keyEquivalentModifierMask = [.command, .option]
        m.addItem(e)
        editItem = e
        let r = NSMenuItem(title: "Reset layout", action: #selector(resetLayout), keyEquivalent: "r")
        r.target = self
        m.addItem(r)
        m.addItem(NSMenuItem.separator())
        for i in 0..<3 {
            let p = NSMenuItem(title: titles[i], action: #selector(togglePanel(_:)), keyEquivalent: "")
            p.target = self
            p.tag = i
            m.addItem(p)
            panelItems.append(p)
        }
        m.addItem(NSMenuItem.separator())
        let bg = NSMenuItem(title: "Background", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for pct in [0, 10, 20, 35, 50] {
            let b = NSMenuItem(title: "\(pct)%", action: #selector(setBackdrop(_:)), keyEquivalent: "")
            b.target = self
            b.tag = pct
            sub.addItem(b)
            bgItems.append(b)
        }
        bg.submenu = sub
        m.addItem(bg)
        m.addItem(NSMenuItem.separator())
        let q = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        q.target = NSApp
        m.addItem(q)
        it.menu = m
        statusItem = it
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        editItem?.title = editing ? "Done editing" : "Edit layout"
        for p in panelItems { p.state = defaults.bool(forKey: "hidden.\(p.tag)") ? .off : .on }
        for b in bgItems { b.state = Int((backdrop * 100).rounded()) == b.tag ? .on : .off }
    }

    @objc func toggleEdit() {
        editing.toggle()
        for (i, w) in windows.enumerated() {
            w.ignoresMouseEvents = !editing
            w.level = editing ? NSWindow.Level.floating : desktopLevel
            views[i].editing = editing
            if !defaults.bool(forKey: "hidden.\(i)") { w.orderFrontRegardless() }
        }
        if !editing { saveFrames() }
    }

    @objc func resetLayout() {
        guard let screen = NSScreen.screens.first else { return }
        let vf = screen.visibleFrame
        for i in 0..<3 {
            defaults.removeObject(forKey: "frame.\(i)")
            windows[i].setFrame(defaultRect(i, designs[i], vf), display: true)
        }
    }

    @objc func togglePanel(_ sender: NSMenuItem) {
        let i = sender.tag
        let hidden = !defaults.bool(forKey: "hidden.\(i)")
        defaults.set(hidden, forKey: "hidden.\(i)")
        if hidden { windows[i].orderOut(nil) } else { windows[i].orderFrontRegardless() }
    }

    @objc func setBackdrop(_ sender: NSMenuItem) {
        backdrop = CGFloat(sender.tag) / 100
        defaults.set(Double(backdrop), forKey: "backdrop")
        redraw()
    }

    func redraw() {
        for v in views { v.needsDisplay = true }
    }

    func usbChanged() {
        sampler.sampleUSB()
        redraw()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.sampler.sampleUSB()
            self?.redraw()
        }
    }

    func fire() {
        sampler.tick()
        redraw()
    }

    func start() {
        guard timer == nil else { return }
        sampler.resetBaselines()
        fire()
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.fire() }
        t.tolerance = 0.6
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func evaluate() {
        let visible = windows.contains { $0.occlusionState.contains(.visible) }
        if visible && !asleep && !locked { start() } else { stop() }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = Controller()
app.delegate = controller
app.run()
