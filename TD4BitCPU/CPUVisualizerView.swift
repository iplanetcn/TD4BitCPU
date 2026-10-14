//
//  Cpuvisualizerview.swift
//  TD4BitCPU
//
//  Created by John Lee on 2026/10/14.
//
import SwiftUI
import Combine

// MARK: - Instruction set (TD4-style 4-bit CPU)
// Each instruction is 8 bits: high nibble = opcode, low nibble = immediate.
// Registers: A, B (4-bit), OUT port, IN port, PC (4-bit), Carry flag.
// Every instruction updates Carry (only ADD can set it); JNC tests the
// carry produced by the *previous* instruction.

enum Opcode: UInt8, CaseIterable, Identifiable {
    case addA = 0x0, movAB = 0x1, inA = 0x2, movAIm = 0x3
    case movBA = 0x4, addB = 0x5, inB = 0x6, movBIm = 0x7
    case outB = 0x9, outIm = 0xB, jnc = 0xE, jmp = 0xF

    var id: UInt8 { rawValue }

    var usesImmediate: Bool {
        switch self {
        case .addA, .movAIm, .addB, .movBIm, .outIm, .jnc, .jmp: true
        default: false
        }
    }

    func format(_ im: String) -> String {
        switch self {
        case .addA:   "ADD A, \(im)"
        case .movAB:  "MOV A, B"
        case .inA:    "IN A"
        case .movAIm: "MOV A, \(im)"
        case .movBA:  "MOV B, A"
        case .addB:   "ADD B, \(im)"
        case .inB:    "IN B"
        case .movBIm: "MOV B, \(im)"
        case .outB:   "OUT B"
        case .outIm:  "OUT \(im)"
        case .jnc:    "JNC \(im)"
        case .jmp:    "JMP \(im)"
        }
    }
}

func mnemonic(_ byte: UInt8) -> String {
    guard let op = Opcode(rawValue: byte >> 4) else { return "NOP" }
    return op.format("\(byte & 0x0F)")
}

func bin(_ v: UInt8, _ width: Int = 4) -> String {
    let s = String(v, radix: 2)
    return String(repeating: "0", count: max(0, width - s.count)) + s
}

// MARK: - Presets

enum Preset: String, CaseIterable, Identifiable {
    case counter = "Binary counter"
    case scanner = "LED scanner"
    case carry = "Carry demo"

    var id: String { rawValue }

    var bytes: [UInt8] {
        switch self {
        case .counter: [0x01, 0x40, 0x90, 0xF0]
        case .scanner: [0xB1, 0xB2, 0xB4, 0xB8, 0xB4, 0xB2, 0xF0]
        case .carry:   [0x05, 0xE0, 0xBF, 0xB0, 0xF0]
        }
    }
}

// MARK: - CPU model

@MainActor
final class CPU: ObservableObject {
    @Published var rom: [UInt8] = Preset.counter.bytes + Array(repeating: 0, count: 12)
    @Published var a: UInt8 = 0
    @Published var b: UInt8 = 0
    @Published var out: UInt8 = 0
    @Published var input: UInt8 = 0
    @Published var pc: UInt8 = 0
    @Published var carry = false
    @Published var cycles = 0
    @Published var lastPC: UInt8?
    @Published var isRunning = false
    @Published var hz: Double = 5

    private var task: Task<Void, Never>?

    func step() {
        let instr = rom[Int(pc)]
        let im = instr & 0x0F
        let carryIn = carry
        var nextPC = (pc + 1) & 0x0F
        var newCarry = false

        switch Opcode(rawValue: instr >> 4) {
        case .addA:
            let s = a + im; a = s & 0x0F; newCarry = s > 0x0F
        case .movAB:  a = b
        case .inA:    a = input
        case .movAIm: a = im
        case .movBA:  b = a
        case .addB:
            let s = b + im; b = s & 0x0F; newCarry = s > 0x0F
        case .inB:    b = input
        case .movBIm: b = im
        case .outB:   out = b
        case .outIm:  out = im
        case .jnc:    if !carryIn { nextPC = im }
        case .jmp:    nextPC = im
        case nil:     break
        }

        lastPC = pc
        pc = nextPC
        carry = newCarry
        cycles += 1
    }

    func run() {
        guard !isRunning else { return }
        isRunning = true
        task = Task {
            while !Task.isCancelled {
                step()
                try? await Task.sleep(for: .seconds(1 / hz))
            }
        }
    }

    func pause() {
        task?.cancel()
        task = nil
        isRunning = false
    }

    func reset() {
        pause()
        a = 0; b = 0; out = 0; pc = 0
        carry = false; cycles = 0; lastPC = nil
    }

    func load(_ preset: Preset) {
        reset()
        rom = preset.bytes + Array(repeating: 0, count: 16 - preset.bytes.count)
    }

    func toggleInput(_ bit: Int) { input ^= UInt8(1 << bit) }
}

// MARK: - Small building blocks

extension View {
    func panel() -> some View {
        self
            .padding(14)
            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.08)))
    }
}

struct LED: View {
    let on: Bool
    let tint: Color

    var body: some View {
        Circle()
            .fill(on ? tint : Color.white.opacity(0.08))
            .frame(width: 26, height: 26)
            .overlay(Circle().strokeBorder(.white.opacity(0.12)))
            .shadow(color: on ? tint.opacity(0.8) : .clear, radius: 8)
            .animation(.easeOut(duration: 0.12), value: on)
    }
}

struct BitRow: View {
    let value: UInt8
    let tint: Color
    var onToggle: ((Int) -> Void)? = nil

    var body: some View {
        HStack(spacing: 10) {
            ForEach((0..<4).reversed(), id: \.self) { bit in
                LED(on: value & (1 << bit) != 0, tint: tint)
                    .contentShape(Circle())
                    .onTapGesture { onToggle?(bit) }
            }
        }
    }
}

struct RegisterCard: View {
    let name: String
    let value: UInt8
    let tint: Color
    var onToggle: ((Int) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(name).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Text("0x\(String(value, radix: 16).uppercased())  \(value)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            BitRow(value: value, tint: tint, onToggle: onToggle)
        }
        .panel()
    }
}

struct MemoryRow: View {
    let addr: Int
    let byte: UInt8
    let isPC: Bool
    let wasLast: Bool
    let onChange: (UInt8) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrowtriangle.right.fill")
                .font(.caption2)
                .foregroundStyle(.orange)
                .opacity(isPC ? 1 : 0)

            Text(String(addr, radix: 16).uppercased())
                .font(.system(.footnote, design: .monospaced).weight(.bold))
                .foregroundStyle(.secondary)
                .frame(width: 14)

            HStack(spacing: 6) {
                Text(bin(byte >> 4)).foregroundStyle(.cyan)
                Text(bin(byte & 0x0F)).foregroundStyle(.green)
            }
            .font(.system(.footnote, design: .monospaced))

            Spacer()

            Menu {
                ForEach(Opcode.allCases) { op in
                    Button(op.format("n")) {
                        onChange((op.rawValue << 4) | (op.usesImmediate ? byte & 0x0F : 0))
                    }
                }
                if Opcode(rawValue: byte >> 4)?.usesImmediate == true {
                    Divider()
                    Menu("Operand") {
                        ForEach(0..<16, id: \.self) { n in
                            Button("\(n)  ·  \(bin(UInt8(n)))") {
                                onChange((byte & 0xF0) | UInt8(n))
                            }
                        }
                    }
                }
            } label: {
                Text(mnemonic(byte))
                    .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(.white.opacity(0.08), in: Capsule())
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isPC ? Color.orange.opacity(0.18) : wasLast ? Color.white.opacity(0.05) : .clear)
        )
        .animation(.easeOut(duration: 0.15), value: isPC)
    }
}

// MARK: - 7-segment display (driven by the OUT port)

struct SegmentShape: Shape {
    let horizontal: Bool

    func path(in r: CGRect) -> Path {
        var p = Path()
        if horizontal {
            let h = r.height / 2
            p.move(to: CGPoint(x: r.minX, y: r.midY))
            p.addLine(to: CGPoint(x: r.minX + h, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX - h, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.midY))
            p.addLine(to: CGPoint(x: r.maxX - h, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX + h, y: r.maxY))
        } else {
            let h = r.width / 2
            p.move(to: CGPoint(x: r.midX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.minY + h))
            p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - h))
            p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX, y: r.maxY - h))
            p.addLine(to: CGPoint(x: r.minX, y: r.minY + h))
        }
        p.closeSubpath()
        return p
    }
}

/// One hex digit on a 7-segment display. Bit 0 = a ... bit 6 = g.
struct SevenSegmentDigit: View {
    let value: UInt8            // low nibble is shown, 0...F
    var tint: Color = .red

    static let table: [UInt8] = [
        0x3F, 0x06, 0x5B, 0x4F, 0x66, 0x6D, 0x7D, 0x07,   // 0-7
        0x7F, 0x6F, 0x77, 0x7C, 0x39, 0x5E, 0x79, 0x71    // 8-F
    ]

    static func mask(for v: UInt8) -> UInt8 { table[Int(v & 0x0F)] }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let t = w * 0.17
            let hLen = w - t - 3, vLen = (h - t) / 2 - 3
            ZStack {
                seg(0, true,  CGSize(width: hLen, height: t), CGPoint(x: w / 2, y: t / 2))           // a
                seg(1, false, CGSize(width: t, height: vLen), CGPoint(x: w - t / 2, y: h / 4 + t / 4)) // b
                seg(2, false, CGSize(width: t, height: vLen), CGPoint(x: w - t / 2, y: 3 * h / 4 - t / 4)) // c
                seg(3, true,  CGSize(width: hLen, height: t), CGPoint(x: w / 2, y: h - t / 2))       // d
                seg(4, false, CGSize(width: t, height: vLen), CGPoint(x: t / 2, y: 3 * h / 4 - t / 4)) // e
                seg(5, false, CGSize(width: t, height: vLen), CGPoint(x: t / 2, y: h / 4 + t / 4))   // f
                seg(6, true,  CGSize(width: hLen, height: t), CGPoint(x: w / 2, y: h / 2))           // g
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Display shows \(String(value & 0x0F, radix: 16).uppercased())")
    }

    private func seg(_ bit: Int, _ horizontal: Bool, _ size: CGSize, _ at: CGPoint) -> some View {
        let on = Self.mask(for: value) & (1 << bit) != 0
        return SegmentShape(horizontal: horizontal)
            .fill(on ? tint : Color.white.opacity(0.07))
            .frame(width: size.width, height: size.height)
            .shadow(color: on ? tint.opacity(0.8) : .clear, radius: 6)
            .position(at)
            .animation(.easeOut(duration: 0.12), value: on)
    }
}

// MARK: - Screen

struct CPUVisualizerView: View {
    @StateObject private var cpu = CPU()
    @State private var preset: Preset = .counter

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                header
                controls
                registers
                display
                status
                program
            }
            .padding()
        }
        .background(Color(red: 0.04, green: 0.05, blue: 0.08).ignoresSafeArea())
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("NIBBLE-4").font(.title2.weight(.heavy)).tracking(2)
                Text("4-bit CPU · 16 × 8-bit ROM").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Label("Programs", systemImage: "square.stack.3d.up")
                .font(.subheadline.weight(.semibold))
                .labelStyle(.iconOnly)
            Picker("Program:", selection: $preset) {
                ForEach(Preset.allCases, id: \.self) { p in
                    Text(p.rawValue)
                        .tag(p)
                }
            }
            .pickerStyle(.menu)
            .onChange(of: preset) { oldValue, newValue in
                cpu.load(newValue)
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Button { cpu.step() } label: {
                    Label("Step", systemImage: "forward.frame.fill").frame(maxWidth: .infinity)
                        .labelStyle(.titleOnly)
                }
                .disabled(cpu.isRunning)

                Button { cpu.isRunning ? cpu.pause() : cpu.run() } label: {
                    Label(cpu.isRunning ? "Pause" : "Run",
                          systemImage: cpu.isRunning ? "pause.fill" : "play.fill")
                        .frame(maxWidth: .infinity)
                        .labelStyle(.titleOnly)
                }
                .tint(.orange)

                Button(role: .destructive) { cpu.reset() } label: {
                    Label("Reset", systemImage: "arrow.counterclockwise").frame(maxWidth: .infinity)
                        .labelStyle(.titleOnly)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            HStack {
                Image(systemName: "tortoise.fill").foregroundStyle(.secondary)
                Slider(value: $cpu.hz, in: 1...20, step: 1)
                Image(systemName: "hare.fill").foregroundStyle(.secondary)
                Text("\(Int(cpu.hz)) Hz")
                    .font(.system(.caption, design: .monospaced))
                    .frame(width: 44, alignment: .trailing)
            }
        }
        .panel()
    }

    private var registers: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            RegisterCard(name: "REG A", value: cpu.a, tint: .cyan)
            RegisterCard(name: "REG B", value: cpu.b, tint: .green)
            RegisterCard(name: "OUT", value: cpu.out, tint: .red)
            RegisterCard(name: "IN (tap bits)", value: cpu.input, tint: .yellow) { cpu.toggleInput($0) }
        }
    }

    private var display: some View {
        let m = SevenSegmentDigit.mask(for: cpu.out)
        let bits = (0..<7).map { m & (1 << $0) != 0 ? "1" : "0" }.joined()
        return HStack {
            VStack(alignment: .leading, spacing: 8) {
                Text("7-SEG DISPLAY").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text("OUT \(bin(cpu.out)) → \(String(cpu.out, radix: 16).uppercased())")
                    .font(.system(.footnote, design: .monospaced))
                Text("abcdefg  \(bits)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            SevenSegmentDigit(value: cpu.out)
                .frame(width: 54, height: 90)
                .padding(.horizontal, 16).padding(.vertical, 12)
                .background(Color.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .panel()
    }

    private var status: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 10) {
                Text("PC").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                BitRow(value: cpu.pc, tint: .orange)
            }
            .panel()

            VStack(spacing: 10) {
                Text("CARRY").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                LED(on: cpu.carry, tint: .pink)
            }
            .frame(maxWidth: 80)
            .panel()

            VStack(spacing: 10) {
                Text("CYCLES").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text("\(cpu.cycles)")
                    .font(.system(.title3, design: .monospaced).weight(.bold))
                    .contentTransition(.numericText())
            }
            .frame(maxWidth: 80)
            .panel()
        }
    }

    private var program: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("PROGRAM MEMORY").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Text("opcode").foregroundStyle(.cyan)
                Text("operand").foregroundStyle(.green)
            }
            .font(.caption2)
            .padding(.horizontal, 12).padding(.bottom, 4)

            ForEach(0..<16, id: \.self) { addr in
                MemoryRow(
                    addr: addr,
                    byte: cpu.rom[addr],
                    isPC: Int(cpu.pc) == addr,
                    wasLast: cpu.lastPC.map { Int($0) == addr } ?? false
                ) { cpu.rom[addr] = $0 }
            }
        }
        .padding(.vertical, 12)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.08)))
    }
}

#Preview {
    CPUVisualizerView()
}
