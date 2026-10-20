// dialspace.swift
// 把 Logitech MX Creative Dialpad 的大旋钮转动翻译成 macOS 切换桌面/Spaces。
// 右转 -> 下一个桌面,左转 -> 上一个桌面。
//
// 编译: swiftc -O dialspace.swift -o dialspace -framework IOKit -framework CoreGraphics -framework CoreFoundation
// 运行: ./dialspace            正常模式
//       ./dialspace --tap      与 Options+ 共存的滚轮事件监听模式
//       ./dialspace --tap --debug 只打印滚轮事件,不切换桌面
//
// 需要在「系统设置 > 隐私与安全性」里给运行它的终端授予:
//   - 输入监控 (Input Monitoring)
//   - 辅助功能 (Accessibility)

import Foundation
import IOKit.hid
import CoreGraphics
import ApplicationServices

let VENDOR_ID  = 0x046D
let PRODUCT_ID = 0xBC00   // MX Dialpad

// 大旋钮通过 HID++ 长报文(report id 0x11)上报,feature index 0x0D,
// byte[5] 是有符号旋转增量(+ 右转 / - 左转)。这是断电复位、且 Logi agent 未占用设备时的默认行为。
let HIDPP_REPORT_ID: UInt8 = 0x11
let FEAT_DIAL: UInt8 = 0x0D       // 旋钮旋转通知
let FEAT_BUTTON: UInt8 = 0x0A     // 角键 diverted 通知(暂不使用,仅 debug 显示)

// 旋钮一个 detent 约发 1~2 个 ±1 事件。STEP=1 配合 COOLDOWN 做到"一格≈切一次",快速转则连切。
var STEP = 1
let DEBUG = CommandLine.arguments.contains("--debug")
let COOLDOWN: TimeInterval = 0.30

// 空间切换符号热键 ID(与 com.apple.symbolichotkeys 一致):79=左,81=右
let SHK_SPACE_LEFT: Int32  = 79
let SHK_SPACE_RIGHT: Int32 = 81

var accum = 0
var lastFire = Date.distantPast

func log(_ s: String) {
    FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
}

// ---- 私有 SkyLight API:直接操作 Spaces(macOS 26 上合成 Ctrl+方向键会被过滤,这条不会) ----
typealias ConnFn   = @convention(c) () -> Int32
typealias CopyFn   = @convention(c) (Int32) -> Unmanaged<CFArray>?
typealias ActiveFn = @convention(c) (Int32) -> UInt64
typealias SetFn    = @convention(c) (Int32, CFString, UInt64) -> Void

let skylight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)
let slsMainConnection: ConnFn?  = dlsym(skylight, "SLSMainConnectionID").map { unsafeBitCast($0, to: ConnFn.self) }
let slsCopySpaces:     CopyFn?  = dlsym(skylight, "SLSCopyManagedDisplaySpaces").map { unsafeBitCast($0, to: CopyFn.self) }
let slsActiveSpace:    ActiveFn? = dlsym(skylight, "SLSGetActiveSpace").map { unsafeBitCast($0, to: ActiveFn.self) }
let slsSetSpace:       SetFn?   = dlsym(skylight, "SLSManagedDisplaySetCurrentSpace").map { unsafeBitCast($0, to: SetFn.self) }

// 事务接口:带 WindowServer 横滑动画的空间切换(等同 Ctrl+方向键的过渡效果)
typealias TxnCreateFn   = @convention(c) (Int32) -> UnsafeMutableRawPointer?
typealias TxnSetSpaceFn = @convention(c) (UnsafeMutableRawPointer?, CFString, UInt64) -> Void
typealias TxnCommitFn   = @convention(c) (UnsafeMutableRawPointer?, Int32) -> Int32
let slsTxnCreate:   TxnCreateFn?   = dlsym(skylight, "SLSTransactionCreate").map { unsafeBitCast($0, to: TxnCreateFn.self) }
let slsTxnSetSpace: TxnSetSpaceFn? = dlsym(skylight, "SLSTransactionSetManagedDisplayCurrentSpace").map { unsafeBitCast($0, to: TxnSetSpaceFn.self) }
let slsTxnCommit:   TxnCommitFn?   = dlsym(skylight, "SLSTransactionCommit").map { unsafeBitCast($0, to: TxnCommitFn.self) }
let txnReady = slsTxnCreate != nil && slsTxnSetSpace != nil && slsTxnCommit != nil

let skylightReady = slsMainConnection != nil && slsCopySpaces != nil && slsActiveSpace != nil && slsSetSpace != nil

// ---- 合成 DockSwipe 手势:走真实 Dock 手势通道,带原生横滑动画、Dock/菜单栏正确联动 ----
// 配方来自 joshuarli/iss。end 事件的速度越高越接近"瞬切",越低越接近"慢滑动画"。
var SWIPE_VEL: Double = 5.0   // 低速=带横滑动画(实测 0~5 都顺滑);调高趋向瞬切。--swipe <vel> 可试
func cgField(_ i: UInt32) -> CGEventField { CGEventField(rawValue: i)! }
func dockSwipe(right: Bool, velocity: Double) {
    func mk(_ phase: Int64) -> CGEvent? {
        guard let ev = CGEvent(source: nil) else { return nil }
        ev.setIntegerValueField(cgField(55), value: 30)   // kCGSEventDockControl
        ev.setIntegerValueField(cgField(110), value: 23)  // kIOHIDEventTypeDockSwipe
        ev.setIntegerValueField(cgField(132), value: phase)
        let fp: Float = right ? Float.leastNonzeroMagnitude : -Float.leastNonzeroMagnitude
        ev.setIntegerValueField(cgField(135), value: Int64(Int32(bitPattern: fp.bitPattern)))
        ev.setIntegerValueField(cgField(123), value: 1)   // 横向
        ev.setDoubleValueField(cgField(119), value: 0)
        ev.setDoubleValueField(cgField(139), value: Double(Float.leastNonzeroMagnitude))
        return ev
    }
    func pair(_ dock: CGEvent) {
        guard let comp = CGEvent(source: nil) else { return }
        comp.setIntegerValueField(cgField(55), value: 29)  // kCGSEventGesture(companion)
        dock.post(tap: .cgSessionEventTap)
        comp.post(tap: .cgSessionEventTap)
    }
    let sign: Double = right ? 1.0 : -1.0
    guard let b = mk(1), let c = mk(2), let e = mk(4) else { return }   // began/changed/ended
    e.setDoubleValueField(cgField(129), value: sign * velocity)
    e.setDoubleValueField(cgField(130), value: 0)
    pair(b); pair(c); pair(e)
}

// 切到当前显示器上、当前空间的左/右相邻空间(顺序与 Mission Control 一致,含全屏空间)
func switchSpace(right: Bool) {
    guard skylightReady,
          let conn = slsMainConnection, let copy = slsCopySpaces,
          let active = slsActiveSpace, let setSpace = slsSetSpace else {
        log("⚠️ SkyLight 接口未就绪"); return
    }
    let cid = conn()
    let cur = active(cid)
    guard let displays = copy(cid)?.takeRetainedValue() as? [[String: Any]] else { return }
    for disp in displays {
        guard let ident = disp["Display Identifier"] as? String,
              let spaces = disp["Spaces"] as? [[String: Any]] else { continue }
        let ids = spaces.compactMap { ($0["ManagedSpaceID"] as? NSNumber)?.uint64Value }
        guard let idx = ids.firstIndex(of: cur) else { continue }
        let tidx = right ? idx + 1 : idx - 1
        guard tidx >= 0 && tidx < ids.count else {
            log("已在最\(right ? "右" : "左")端,无空间可切"); return
        }
        let target = ids[tidx]
        // 优先用事务接口(带横滑动画);拿不到再退回瞬切
        if txnReady, let create = slsTxnCreate, let txnSet = slsTxnSetSpace, let commit = slsTxnCommit,
           let txn = create(cid) {
            txnSet(txn, ident as CFString, target)
            _ = commit(txn, 0)
            Unmanaged<AnyObject>.fromOpaque(txn).release()
        } else {
            setSpace(cid, ident as CFString, target)
        }
        log("→ 切到\(right ? "右" : "左")侧桌面 (space \(target))")
        return
    }
}

func postSpaceSwitch(right: Bool) {
    let now = Date()
    if now.timeIntervalSince(lastFire) < COOLDOWN { return }
    lastFire = now
    dockSwipe(right: right, velocity: SWIPE_VEL)
    log("→ \(right ? "右" : "左")滑切桌面 (vel \(SWIPE_VEL))")
}

func handleWheel(_ delta: Int) {
    if delta == 0 { return }
    if (delta > 0) != (accum > 0) { accum = 0 }
    accum += delta
    while accum >= STEP  { accum -= STEP; postSpaceSwitch(right: true) }
    while accum <= -STEP { accum += STEP; postSpaceSwitch(right: false) }
}

func devicePID(_ dev: IOHIDDevice) -> Int {
    (IOHIDDeviceGetProperty(dev, kIOHIDProductIDKey as CFString) as? Int) ?? 0
}
func deviceName(_ dev: IOHIDDevice) -> String {
    (IOHIDDeviceGetProperty(dev, kIOHIDProductKey as CFString) as? String) ?? "?"
}

// ---- 原始报文回调:解析 HID++ 旋钮通知,这是核心逻辑 ----
var lastReportLine = ""
var lastReportCount = 0
let reportCallback: IOHIDReportCallback = { _, _, sender, _, reportID, report, reportLength in
    var name = "?"
    var pid = 0
    if let sender = sender {
        let dev = Unmanaged<IOHIDDevice>.fromOpaque(sender).takeUnretainedValue()
        name = deviceName(dev)
        pid = devicePID(dev)
    }
    if pid == 0xB031 { return } // LIFT 鼠标噪声

    // 路径一(agent 关闭、默认 HID++):11 FF <feature> <fnId> <args...>,feature 0x0D 是旋钮
    if pid == PRODUCT_ID && reportID == HIDPP_REPORT_ID && reportLength >= 6
        && report[0] == 0x11 && report[1] == 0xFF {
        if report[2] == FEAT_DIAL {
            handleWheel(Int(Int8(bitPattern: report[5])))   // byte[5] 有符号增量
        }
    }

    // 路径二(共存模式,Options+ 里把旋钮设成「滚动」):标准鼠标报文 id=0x02
    // 结构: [0]=ID [1..2]=按键 [3..5]=X/Y(12bit) [6]=Wheel(竖) [7]=AC Pan(横)
    if pid == PRODUCT_ID && reportID == 0x02 && reportLength >= 7 {
        let wheel = Int(Int8(bitPattern: report[6]))
        let pan = reportLength >= 8 ? Int(Int8(bitPattern: report[7])) : 0
        if wheel != 0 { handleWheel(wheel) }
        else if pan != 0 { handleWheel(pan) }   // 万一旋钮被映射成横向滚动
    }

    if DEBUG {
        var hex = ""
        for i in 0..<min(reportLength, 32) { hex += String(format: "%02X ", report[i]) }
        let line = String(format: "[report] %@ id=0x%02X len=%ld: %@", name, reportID, reportLength, hex)
        if line == lastReportLine {
            lastReportCount += 1
            if lastReportCount % 50 == 0 { log("(同上报文已重复 \(lastReportCount) 次)") }
            return
        }
        lastReportLine = line
        lastReportCount = 1
        log(line)
    }
}

// ---- 设备热插拔:重连(如断电重启 Dialpad)后给新设备实例补注册报文回调 ----
let matchingCallback: IOHIDDeviceCallback = { _, _, _, dev in
    let name = deviceName(dev)
    let pid = devicePID(dev)
    let maxLen = (IOHIDDeviceGetProperty(dev, kIOHIDMaxInputReportSizeKey as CFString) as? Int) ?? 64
    log(String(format: "[设备接入] %@ (PID=0x%04X)", name, pid))
    if pid != 0xB031 {
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: max(maxLen, 64))
        IOHIDDeviceRegisterInputReportCallback(dev, buf, max(maxLen, 64), reportCallback, nil)
    }
}
let removalCallback: IOHIDDeviceCallback = { _, _, _, dev in
    log(String(format: "[设备断开] %@ (PID=0x%04X)", deviceName(dev), devicePID(dev)))
}

// 速度试验模式:./dialspace --swipe <vel>  右滑一次 -> 停 -> 左滑回来。试不同 vel 找带动画的值。
if let i = CommandLine.arguments.firstIndex(of: "--swipe") {
    let vel = i + 1 < CommandLine.arguments.count ? (Double(CommandLine.arguments[i+1]) ?? 400) : 400
    log("3 秒后:用 velocity=\(vel) 右滑一格 → 停 1.5 秒 → 左滑回来(看是否带横滑动画)…")
    Thread.sleep(forTimeInterval: 3)
    dockSwipe(right: true, velocity: vel)
    Thread.sleep(forTimeInterval: 1.5)
    dockSwipe(right: false, velocity: vel)
    log("结束。告诉我这个 vel 下:① 切没切 ② 有没有横滑动画 ③ Dock 在全屏空间是否正确隐藏")
    exit(0)
}

// 自检模式:验证切屏机制
if CommandLine.arguments.contains("--diag") {
    log("SkyLight 空间接口就绪: \(skylightReady ? "是 ✅" : "否 ❌")")
    log("3 秒后:右切一格 → 停 1 秒 → 左切回来(盯着桌面看)…")
    Thread.sleep(forTimeInterval: 3)
    switchSpace(right: true)
    Thread.sleep(forTimeInterval: 1.2)
    switchSpace(right: false)
    log("自检结束。桌面有来回切动就说明机制 OK。")
    exit(0)
}

// 判断某个源进程是否属于 Logitech(按进程名,带缓存),避免误伤用户手动 Shift+滚动
var logiPidCache: [Int32: Bool] = [:]
func pidIsLogi(_ pid: Int32) -> Bool {
    if pid <= 0 { return false }
    if let cached = logiPidCache[pid] { return cached }
    var buf = [CChar](repeating: 0, count: 1024)
    let n = proc_name(pid, &buf, UInt32(buf.count))
    let name = n > 0 ? String(cString: buf) : ""
    let isLogi = name.lowercased().contains("logi")
    logiPidCache[pid] = isLogi
    return isLogi
}

// ---- 事件层抓包/拦截模式(共存方案:读 Options+ 注入的滚动)----
// --tap        : 拦截大旋钮的横向滚动 -> 切屏,并吞掉该事件;纵向滚动放行
// --tap --debug: 只打印所有滚动事件(轴/来源PID),不吞、不切,用来观察
let TAP_DEBUG = DEBUG
var gTap: CFMachPort?   // 全局保存 tap,供回调/看门狗自愈用
let scrollTapCallback: CGEventTapCallBack = { _, type, event, _ in
    // 系统在超时/显示器重配等情况下会禁用 tap,这里立即重新启用(自愈)
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let t = gTap { CGEvent.tapEnable(tap: t, enable: true); log("⚠️ 事件 tap 被禁用,已自动重新启用") }
        return Unmanaged.passUnretained(event)
    }
    guard type == .scrollWheel else { return Unmanaged.passUnretained(event) }
    let a1 = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)   // 纵向(小旋钮)
    let a2 = event.getIntegerValueField(.scrollWheelEventDeltaAxis2)   // 横向(大旋钮)
    let p2 = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2)
    let src = event.getIntegerValueField(.eventSourceUnixProcessID)
    let cont = event.getIntegerValueField(.scrollWheelEventIsContinuous)
    if TAP_DEBUG {
        let f = event.flags.rawValue
        var mods = ""
        if event.flags.contains(.maskShift)     { mods += "Shift " }
        if event.flags.contains(.maskControl)   { mods += "Ctrl " }
        if event.flags.contains(.maskAlternate) { mods += "Opt " }
        if event.flags.contains(.maskCommand)   { mods += "Cmd " }
        log("scroll a1=\(a1) a2=\(a2) p2=\(p2) cont=\(cont) srcPID=\(src) flags=0x\(String(f, radix:16)) [\(mods)]")
        return Unmanaged.passUnretained(event)   // debug 不吞、不切
    }
    // 大旋钮 = Shift + 离散纵向滚动 + 来自 Logi 进程。命中则转成切屏并吞掉事件。
    let isShift = event.flags.contains(.maskShift)
    if isShift && cont == 0 && a1 != 0 && pidIsLogi(Int32(src)) {
        handleWheel(Int(a1))   // a1>0 右转 -> 右桌面;a1<0 左转 -> 左桌面
        return nil             // 吞掉,避免窗口被横向滚动
    }
    return Unmanaged.passUnretained(event)   // 小旋钮/鼠标/触控板照常放行
}

if CommandLine.arguments.contains("--tap") {
    let mask: CGEventMask = (1 << CGEventType.scrollWheel.rawValue)
    guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                      options: TAP_DEBUG ? .listenOnly : .defaultTap,
                                      eventsOfInterest: mask, callback: scrollTapCallback, userInfo: nil) else {
        log("❌ 创建事件 tap 失败 —— 请检查当前终端或已安装程序的「辅助功能」权限"); exit(1)
    }
    gTap = tap
    let rls = CFMachPortCreateRunLoopSource(nil, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetCurrent(), rls, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)

    // 看门狗:每 3 秒检查 tap 是否还活着,被禁用(超时/插拔屏/睡眠唤醒)就自动拉起
    let watchdog = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent() + 3, 3, 0, 0) { _ in
        if let t = gTap, !CGEvent.tapIsEnabled(tap: t) {
            CGEvent.tapEnable(tap: t, enable: true)
            log("⚠️ 看门狗:检测到 tap 已停,已自动重启")
        }
    }
    CFRunLoopAddTimer(CFRunLoopGetCurrent(), watchdog, .commonModes)

    // 显示器重配(插拔屏/分辨率变化)后,主动重新启用一次,避免多屏切换失效
    let reconfigCB: CGDisplayReconfigurationCallBack = { _, flags, _ in
        if flags.contains(.setModeFlag) || flags.contains(.addFlag) || flags.contains(.removeFlag) {
            if let t = gTap { CGEvent.tapEnable(tap: t, enable: true); log("⚠️ 显示器配置变化,已重新启用 tap") }
        }
    }
    CGDisplayRegisterReconfigurationCallback(reconfigCB, nil)

    log(TAP_DEBUG ? "事件抓包模式:转大旋钮(横向)和小旋钮(纵向),观察 a1/a2/srcPID…(Ctrl+C 退出)"
                  : "共存模式运行中(含自愈看门狗):大旋钮横向滚动 -> 切屏。(Ctrl+C 退出)")
    CFRunLoopRun()
    exit(0)
}

let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))

// debug 模式匹配所有 Logitech 设备(方便对照 LIFT 鼠标等正常设备);正常模式只匹配 Dialpad
var match: [String: Any] = [kIOHIDVendorIDKey as String: VENDOR_ID]
if !DEBUG { match[kIOHIDProductIDKey as String] = PRODUCT_ID }
IOHIDManagerSetDeviceMatching(manager, match as CFDictionary)
IOHIDManagerRegisterDeviceMatchingCallback(manager, matchingCallback, nil)
IOHIDManagerRegisterDeviceRemovalCallback(manager, removalCallback, nil)
IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)

let openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
if openResult != kIOReturnSuccess {
    log("打开 HID manager 失败: \(String(format: "0x%08X", openResult)) —— 多半是没给「输入监控」权限")
    exit(1)
}

let devices = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? []
if devices.isEmpty {
    log("⚠️ 没匹配到设备。确认 Dialpad 已蓝牙连接,且终端已获「输入监控」权限。")
}
log(DEBUG ? "抓包模式:转动旋钮/滚轮、按按键,这里会 dump 原始报文(LIFT 已过滤,重复报文已折叠)…(Ctrl+C 退出)"
          : "开始监听大旋钮…(Ctrl+C 退出)")

CFRunLoopRun()
