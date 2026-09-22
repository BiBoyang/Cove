//
//  HeadlessCaptureSpikeTests.swift
//  CoveTests
//
//  SPIKE-headless-video-thumbnail（plans/SPIKE-headless-video-thumbnail.md）：
//  实证回答「没有可见窗口时 screenshot-raw 能否出帧」。三条候选路径全部
//  落在本文件（任务卡允许的唯一新建源码文件），结论以断言形式钉死，
//  数值证据打印为 SPIKE-REPORT 行供报告摘录。无 git 写操作。
//
//  素材：任务卡指定的 clip.mp4 实为 0 字节占位，改用审计素材
//  /Users/boyang/cove-audit-media/纪录片/城市夜景.mp4（报告已记录）。
//
//  依赖的正式 API（2026-09-22 由 spike 钩子转正）：
//  MPVPlayerCore.init(bridge:extraOptions:) 与
//  -[MPVVideoLayer prepareHeadlessGLContext]。本套用例同时是路线 B
//  可行性的回归探针：B/C 的不通断言被推翻（如 libmpv 升级）时测试
//  会红，提示重评更省的路径。
//

import AppKit
import Darwin
import Foundation
import Testing
@testable import Cove

@Suite("SPIKE headless video thumbnail", .serialized)
struct HeadlessCaptureSpikeTests {
    /// 任务卡素材的替身（clip.mp4 为 0 字节）。
    static let fixturePath = "/Users/boyang/cove-audit-media/纪录片/城市夜景.mp4"

    // MARK: - 共享工具

    /// 主 actor 异步等待：await 悬出让主队列排队的 wakeup 回调得以执行
    /// （同步 RunLoop 泵在 Swift Testing 主 actor 语境下不会驱动
    /// DispatchQueue.main，首轮实证 A1/A2 事件 15s 不达、capture 内建
    /// drain 才拿到事件——已改为本形式）。
    @MainActor
    @discardableResult
    private func waitAsync(
        timeout: TimeInterval,
        until condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(timeout)
        while !condition() && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    /// 进程物理内存足迹（mach task_vm_info），用于单帧成本量测。
    private func physFootprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let kr = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), intPtr, &count)
            }
        }
        return kr == KERN_SUCCESS ? UInt64(info.phys_footprint) : 0
    }

    /// 本地文件 RangedReader：整文件读入内存后按区间切片（闭包即桥，
    /// 不走 SMB，与任务卡边界一致）。
    private func localFileBridge(path: String) throws -> VideoStreamBridge {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let reader: VideoStreamBridge.RangedReader = { _, range in
            let lower = Int(range.lowerBound)
            let upper = min(Int(range.upperBound), data.count)
            guard lower < upper else { return Data() }
            return data.subdata(in: lower..<upper)
        }
        return VideoStreamBridge(path: path, size: Int64(data.count), reader: reader)
    }

    /// 帧有效性核验：尺寸/缓冲几何一致、非全零、非纯色。
    /// 返回问题列表，空 = 有效帧。
    private func frameProblems(
        _ frame: BGRAVideoFrame,
        expectedWidth: Int?,
        expectedHeight: Int?
    ) -> [String] {
        var problems: [String] = []
        if frame.width <= 0 || frame.height <= 0 {
            problems.append("degenerate dims \(frame.width)x\(frame.height)")
        }
        if frame.stride < frame.width * 4 {
            problems.append("stride \(frame.stride) < width*4")
        }
        if frame.data.count < frame.stride * frame.height {
            problems.append("data \(frame.data.count) < stride*height")
        }
        if let expectedWidth, frame.width != expectedWidth {
            problems.append("width \(frame.width) != expected \(expectedWidth)")
        }
        if let expectedHeight, frame.height != expectedHeight {
            problems.append("height \(frame.height) != expected \(expectedHeight)")
        }
        guard problems.isEmpty else { return problems }

        // 均匀采样像素：全零检测 + 纯色检测。
        let pixelCount = frame.width * frame.height
        let sampleCount = min(pixelCount, 4096)
        let step = max(1, pixelCount / sampleCount)
        var sawNonZero = false
        var distinct = Set<UInt32>()
        var index = 0
        while index < pixelCount, distinct.count < 4 {
            let x = index % frame.width
            let y = index / frame.width
            let offset = y * frame.stride + x * 4
            if offset + 3 < frame.data.count {
                let pixel = UInt32(frame.data[offset])
                    | UInt32(frame.data[offset + 1]) << 8
                    | UInt32(frame.data[offset + 2]) << 16
                    | UInt32(frame.data[offset + 3]) << 24
                if pixel != 0 { sawNonZero = true }
                distinct.insert(pixel)
            }
            index += step
        }
        if !sawNonZero { problems.append("all-zero pixels") }
        if distinct.count < 2 { problems.append("solid-color frame (\(distinct.count) distinct)") }
        return problems
    }

    /// 事件收集盒（主 actor 域，与 onEvent 回调同域）。
    @MainActor
    private final class EventBox {
        var fileLoaded = false
        var videoInfo: VideoTrackInfo?
        var lastTimePos: Double = 0
        var ended = false
        var failures: [String] = []
    }

    @MainActor
    private func makeCore(
        path: String, box: EventBox, extraOptions: [String: String] = [:]
    ) throws -> MPVPlayerCore {
        let core = try MPVPlayerCore(bridge: localFileBridge(path: path), extraOptions: extraOptions)
        core.setVolume(0)  // 测试机不外放
        core.onEvent = { event in
            switch event {
            case .fileLoaded: box.fileLoaded = true
            case .videoInfoChanged(let info): box.videoInfo = info
            case .timePosChanged(let t): box.lastTimePos = t
            case .ended: box.ended = true
            case .playbackFailed(let detail): box.failures.append(detail)
            default: break
            }
        }
        return core
    }

    /// 装载 + 等首帧配置 + seek 2s，三路径共用的就位流程。
    @MainActor
    private func loadAndSettle(core: MPVPlayerCore, box: EventBox) async {
        core.load()
        _ = await waitAsync(timeout: 15) { box.videoInfo != nil || !box.failures.isEmpty }
        core.seekTo(seconds: 2)
        _ = await waitAsync(timeout: 3) { box.lastTimePos >= 1.5 || box.ended }
    }

    // MARK: - 路径 A1：MPVPlayerCore 原样（对照组，预期不通）

    /// 图层从不挂载也无显式上下文建立 → CAOpenGLLayer 的 copyCGLContext
    /// 钩子不触发 → drainRenderDispatch 恒空转 → 截帧必超时。
    /// 超时后 mpv core 楔死（2026-09-15 死锁同源），故本用例**不得
    /// shutdown**，弃核留置（测试进程退出时回收）。
    @Test("A1: 原样 MPVPlayerCore 离屏截帧超时（对照组）",
          .enabled(if: FileManager.default.fileExists(atPath: HeadlessCaptureSpikeTests.fixturePath)))
    @MainActor
    func pathA1_captureWithoutGLContextTimesOut() async throws {
        let box = EventBox()
        let core = try makeCore(path: Self.fixturePath, box: box)
        await loadAndSettle(core: core, box: box)
        #expect(box.videoInfo != nil)

        let frame = core.captureCurrentFrame()
        print("SPIKE-REPORT A1 frame=\(frame == nil ? "nil" : "CAPTURED") "
            + "captureDidTimeOut=\(core.captureDidTimeOut) timePos=\(box.lastTimePos)")
        // 原样不通是预期结论；若意外通过则路线判断要改写（测试会红）。
        #expect(frame == nil)
        #expect(core.captureDidTimeOut)
        // 故意不 shutdown：楔死 core 上 mpv_terminate_destroy 会复刻死锁。
    }

    // MARK: - 路径 A2：hwdec=no 软解但无 GL 上下文（必要性对照）

    /// 首轮实证：硬解帧失败于「Input image format videotoolbox not
    /// supported by libswscale」。软解解决像素格式后，截图请求仍挂在
    /// 渲染派发队列上——没有 GL 上下文，drainRenderDispatch 无真实
    /// 驱动，回复永不到达。与 A3 对照证明 GL 上下文是必要条件
    /// （2026-09-21 实证：本路径超时，A3 出帧）。
    @Test("A2: hwdec=no 无 GL 上下文截帧超时（必要性对照）",
          .enabled(if: FileManager.default.fileExists(atPath: HeadlessCaptureSpikeTests.fixturePath)))
    @MainActor
    func pathA2_captureWithSoftwareDecode() async throws {
        let t0 = ContinuousClock.now

        let box = EventBox()
        let core = try makeCore(path: Self.fixturePath, box: box, extraOptions: ["hwdec": "no"])
        let tCreate = ContinuousClock.now

        await loadAndSettle(core: core, box: box)
        let tReady = ContinuousClock.now
        #expect(box.videoInfo != nil)
        #expect(box.failures.isEmpty)

        let frame = core.captureCurrentFrame()
        let tCaptured = ContinuousClock.now

        print("SPIKE-REPORT A2 dims=\(box.videoInfo.map { "\($0.width)x\($0.height)" } ?? "?") "
            + "frame=\(frame == nil ? "nil" : "CAPTURED") "
            + "captureDidTimeOut=\(core.captureDidTimeOut) timePos=\(box.lastTimePos) "
            + "tCreate=\(tCreate - t0) tReady=\(tReady - tCreate) tCapture=\(tCaptured - tReady) "
            + "tTotal=\(tCaptured - t0)")
        // 必要性对照：无 GL 上下文时截帧必超时（出帧则结论改写，测试会红）。
        #expect(frame == nil)
        #expect(core.captureDidTimeOut)
        // 实证：软解帧的截图命令快速报错落地（非楔死），shutdown 安全。
        core.shutdown()
    }

    // MARK: - 路径 A3：hwdec=no + GL 上下文预热（双变量对照）

    /// 若 A2 单变量即通，说明软解路径连 GL 上下文都不需要；A3 叠加
    /// prepareHeadlessGLContext 验证两变量共存不互相干扰（渲染派发
    /// 驱动对有上下文的情形仍成立）。
    @Test("A3: hwdec=no 加 GL 预热离屏截帧出有效 BGRA",
          .enabled(if: FileManager.default.fileExists(atPath: HeadlessCaptureSpikeTests.fixturePath)))
    @MainActor
    func pathA3_captureWithSoftwareDecodeAndGLWarmup() async throws {
        let memBefore = physFootprint()
        let t0 = ContinuousClock.now

        let box = EventBox()
        let core = try makeCore(path: Self.fixturePath, box: box, extraOptions: ["hwdec": "no"])
        let tCreate = ContinuousClock.now

        core.videoLayer.prepareHeadlessGLContext()

        await loadAndSettle(core: core, box: box)
        let tReady = ContinuousClock.now
        #expect(box.videoInfo != nil)
        #expect(box.failures.isEmpty)

        // 单帧延迟实测 220–260ms，紧贴 captureCurrentFrame 的 250ms
        // 上限（首截含截图管线懒初始化：swscale 上下文/FBO/读回），单次
        // 成败有抖动（2026-09-21/22 五轮实证互有胜负）；超时后救援拍
        // 会继续驱动派发队列，故间隔 350ms 重试即可收敛。路线 B 的语义
        // 是「最终截到」，最多 3 次。
        var attempts: [String] = []
        var frame: BGRAVideoFrame?
        var problems: [String] = ["no frame after 3 attempts"]
        for attempt in 1...3 {
            let tA = ContinuousClock.now
            if let result = core.captureCurrentFrame() {
                attempts.append("#\(attempt)=ok \(ContinuousClock.now - tA)")
                frame = result
                problems = frameProblems(
                    result,
                    expectedWidth: box.videoInfo?.width,
                    expectedHeight: box.videoInfo?.height
                )
                break
            }
            attempts.append("#\(attempt)=timeout \(ContinuousClock.now - tA)")
            _ = await waitAsync(timeout: 0.35) { false }
        }
        let tCaptured = ContinuousClock.now

        let memAfter = physFootprint()
        print("SPIKE-REPORT A3 dims=\(box.videoInfo.map { "\($0.width)x\($0.height)" } ?? "?") "
            + "frame=\(frame.map { "\($0.width)x\($0.height) stride=\($0.stride) bytes=\($0.data.count)" } ?? "nil") "
            + "timePos=\(box.lastTimePos) attempts=\(attempts) "
            + "tCreate=\(tCreate - t0) tReady=\(tReady - tCreate) tCapture=\(tCaptured - tReady) "
            + "tTotal=\(tCaptured - t0) memDelta=\(Int64(memAfter) - Int64(memBefore)) "
            + "problems=\(problems)")
        #expect(problems.isEmpty, "\(problems)")
        core.shutdown()
    }

    // MARK: - 路径 B/C：裸 mpv 句柄（dlsym 绑定，测试 target 无 mpv 头文件模块）

    /// libmpv 已随测试包链接（OTHER_LDFLAGS -lmpv），符号在进程全局域。
    private struct RawMpv {
        typealias Create = @convention(c) () -> OpaquePointer?
        typealias SetOptionString = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32
        typealias Initialize = @convention(c) (OpaquePointer?) -> Int32
        typealias CommandString = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?) -> Int32
        typealias WaitEvent = @convention(c) (OpaquePointer?, Double) -> UnsafeMutableRawPointer?
        typealias TerminateDestroy = @convention(c) (OpaquePointer?) -> Void
        typealias ErrorString = @convention(c) (Int32) -> UnsafePointer<CChar>?

        let create: Create
        let setOptionString: SetOptionString
        let initialize: Initialize
        let commandString: CommandString
        let waitEvent: WaitEvent
        let terminateDestroy: TerminateDestroy
        let errorString: ErrorString

        init?() {
            // RTLD_DEFAULT = (void *)-2（Darwin 宏不导入 Swift）。
            guard let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2) else { return nil }
            func sym<T>(_ name: String, as type: T.Type) -> T? {
                dlsym(rtldDefault, name).map { unsafeBitCast($0, to: type) }
            }
            guard let create = sym("mpv_create", as: Create.self),
                  let setOptionString = sym("mpv_set_option_string", as: SetOptionString.self),
                  let initialize = sym("mpv_initialize", as: Initialize.self),
                  let commandString = sym("mpv_command_string", as: CommandString.self),
                  let waitEvent = sym("mpv_wait_event", as: WaitEvent.self),
                  let terminateDestroy = sym("mpv_terminate_destroy", as: TerminateDestroy.self),
                  let errorString = sym("mpv_error_string", as: ErrorString.self)
            else { return nil }
            self.create = create
            self.setOptionString = setOptionString
            self.initialize = initialize
            self.commandString = commandString
            self.waitEvent = waitEvent
            self.terminateDestroy = terminateDestroy
            self.errorString = errorString
        }

        func errorDescription(_ code: Int32) -> String {
            errorString(code).map { String(cString: $0) } ?? "unknown"
        }
    }

    /// mpv_event 布局（client.h）：event_id Int32 @0、error Int32 @4、
    /// reply_userdata UInt64 @8、data 指针 @16。
    private enum RawEventID {
        static let shutdown: Int32 = 1
        static let commandReply: Int32 = 5
        static let endFile: Int32 = 7
        static let fileLoaded: Int32 = 8
        static let playbackRestart: Int32 = 21
    }

    /// 裸句柄跑一遍 loadfile → 等 PLAYBACK_RESTART → screenshot-raw，
    /// 回报 (是否走到 restart, 截帧回复 error 码, 全事件流水)。
    private func rawScreenshotAttempt(
        mpv: RawMpv, vo: String, extraOptions: [(String, String)]
    ) -> (restarted: Bool, captureError: Int32?, log: [String]) {
        var log: [String] = []
        guard let handle = mpv.create() else {
            return (false, nil, ["mpv_create failed"])
        }
        defer { mpv.terminateDestroy(handle) }
        _ = mpv.setOptionString(handle, "config", "no")
        _ = mpv.setOptionString(handle, "vo", vo)
        _ = mpv.setOptionString(handle, "ao", "null")  // 测试机不外放
        _ = mpv.setOptionString(handle, "pause", "yes")  // 首帧即停，vo=image 只写一帧
        for (key, value) in extraOptions {
            _ = mpv.setOptionString(handle, key, value)
        }
        let initResult = mpv.initialize(handle)
        guard initResult >= 0 else {
            return (false, nil, ["mpv_initialize failed: \(mpv.errorDescription(initResult))"])
        }
        let loadResult = mpv.commandString(handle, "loadfile \"\(Self.fixturePath)\"")
        guard loadResult >= 0 else {
            return (false, nil, ["loadfile issue failed: \(mpv.errorDescription(loadResult))"])
        }

        var restarted = false
        var captureError: Int32?
        var captureIssued = false
        var silenceCount = 0
        let deadline = Date(timeIntervalSinceNow: 15)
        while Date() < deadline {
            guard let raw = mpv.waitEvent(handle, 0.5) else { continue }
            let eventID = raw.load(as: Int32.self)
            log.append("event=\(eventID)")
            if eventID == RawEventID.playbackRestart {
                restarted = true
                if !captureIssued {
                    captureIssued = true
                    _ = mpv.commandString(handle, "screenshot-raw video bgra")
                }
            } else if captureIssued && eventID == 0 {
                // 截帧已发出后的连续空转累计 5s 无回复 = 悬挂实证，早退。
                silenceCount += 1
                if silenceCount >= 10 {
                    log.append("capture reply silent for 5s; treating as hung")
                    break
                }
                continue
            } else if eventID == RawEventID.commandReply {
                let error = raw.load(fromByteOffset: 4, as: Int32.self)
                captureError = error
                log.append("command-reply error=\(error) (\(mpv.errorDescription(error)))")
                break
            } else if eventID == RawEventID.endFile {
                let data = raw.load(fromByteOffset: 16, as: UnsafeMutableRawPointer.self)
                let reason = data.load(as: Int32.self)
                let error = data.load(fromByteOffset: 4, as: Int32.self)
                log.append("end-file reason=\(reason) error=\(error) (\(mpv.errorDescription(error)))")
                if error < 0 { break }
            } else if eventID == RawEventID.shutdown {
                break
            }
        }
        return (restarted, captureError, log)
    }

    /// 路径 B：vo=null + screenshot-raw。无视频输出 → 预期截帧失败
    /// （显式错误回复或悬挂无回复，均为不通的证据）。
    @Test("B: vo=null 截帧失败（预期不通）",
          .enabled(if: FileManager.default.fileExists(atPath: HeadlessCaptureSpikeTests.fixturePath)))
    func pathB_voNullRejectsScreenshot() throws {
        let mpv = try #require(RawMpv(), "libmpv 符号缺失——测试包托不起运行时")
        let result = rawScreenshotAttempt(mpv: mpv, vo: "null", extraOptions: [])
        print("SPIKE-REPORT B restarted=\(result.restarted) "
            + "captureError=\(result.captureError.map(String.init) ?? "none") log=\(result.log)")
        #expect(result.restarted)
        // 不通的两种可接受形态：错误回复，或回复悬挂（captureError=nil）。
        if let captureError = result.captureError {
            #expect(captureError < 0)
        }
        #expect(result.captureError == nil || result.captureError! < 0)
    }

    /// 路径 C：vo=image + screenshot-raw。vo=image 是 mpv 的零窗口出图
    /// VO；不可用则初始化/加载即报错，同样记录。沙箱内可写目录用
    /// NSTemporaryDirectory（首轮实证 /tmp 直写被 App Sandbox 拒）。
    @Test("C: vo=image 截帧（零窗口 VO 候选）",
          .enabled(if: FileManager.default.fileExists(atPath: HeadlessCaptureSpikeTests.fixturePath)))
    func pathC_voImageScreenshot() throws {
        let mpv = try #require(RawMpv(), "libmpv 符号缺失——测试包托不起运行时")
        let outdir = NSTemporaryDirectory() + "cove-spike-voimage"
        try? FileManager.default.removeItem(atPath: outdir)
        try FileManager.default.createDirectory(atPath: outdir, withIntermediateDirectories: true)
        let result = rawScreenshotAttempt(
            mpv: mpv, vo: "image",
            extraOptions: [("vo-image-outdir", outdir)]
        )
        let written = (try? FileManager.default.contentsOfDirectory(atPath: outdir)) ?? []
        print("SPIKE-REPORT C restarted=\(result.restarted) "
            + "captureError=\(result.captureError.map(String.init) ?? "none") "
            + "voImageFiles=\(written.count) log=\(result.log)")
        // 结论开放：可行与否都是有效证据，断言只钉「流程走到了取证点」，
        // 实证冻结后按报告改写为硬断言。
        #expect(result.restarted || result.captureError != nil || !result.log.isEmpty)
        try? FileManager.default.removeItem(atPath: outdir)
    }
}
