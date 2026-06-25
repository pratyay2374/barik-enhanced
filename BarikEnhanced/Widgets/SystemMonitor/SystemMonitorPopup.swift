import SwiftUI

// MARK: - CPU & RAM Popup (shown when clicking the CPU/RAM widget)

struct CPURAMPopup: View {
    @ObservedObject private var systemMonitor = SystemMonitorManager.shared
    @State private var cpuHistory: [Double] = Array(repeating: 0, count: 30)
    @State private var ramHistory: [Double] = Array(repeating: 0, count: 30)
    
    private let timer = Timer.publish(every: 3, on: .main, in: .common).autoconnect()
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(cpuColor.opacity(0.15))
                        .frame(width: 32, height: 32)
                    Image(systemName: "cpu")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(cpuColor)
                }
                
                VStack(alignment: .leading, spacing: 1) {
                    Text("CPU & Memory")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(Date(), style: .time)
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.4))
                }
                Spacer()
            }
            
            // CPU Section
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text("CPU")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                    Spacer()
                    Text("\(Int(systemMonitor.cpuLoad))%")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(cpuColor)
                }
                
                // CPU Chart
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.white.opacity(0.04))
                    
                    SmoothLineChart(data: cpuHistory, color: cpuColor, maxValue: 100)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                }
                .frame(height: 56)
                
                // CPU Breakdown - pill badges
                HStack(spacing: 6) {
                    StatPill(label: "User", value: "\(Int(systemMonitor.userLoad))%", color: .cyan)
                    StatPill(label: "System", value: "\(Int(systemMonitor.systemLoad))%", color: .orange)
                    StatPill(label: "Idle", value: "\(Int(systemMonitor.idleLoad))%", color: .white.opacity(0.5))
                    Spacer()
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(.white.opacity(0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(.white.opacity(0.06), lineWidth: 1)
                    )
            )
            
            // RAM Section
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Memory")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                    Spacer()
                    VStack(alignment: .trailing, spacing: 1) {
                        Text("\(Int(systemMonitor.ramUsage))%")
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                            .foregroundStyle(ramColor)
                        Text("\(String(format: "%.1f", usedRAM)) / \(String(format: "%.0f", systemMonitor.totalRAM)) GB")
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                }
                
                // RAM Chart
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.white.opacity(0.04))
                    
                    SmoothLineChart(data: ramHistory, color: ramColor, maxValue: 100)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                }
                .frame(height: 56)
                
                // Memory breakdown bars
                VStack(spacing: 5) {
                    MemoryBar(label: "Active", value: systemMonitor.activeRAM, total: systemMonitor.totalRAM, color: .cyan)
                    MemoryBar(label: "Wired", value: systemMonitor.wiredRAM, total: systemMonitor.totalRAM, color: .orange)
                    MemoryBar(label: "Compressed", value: systemMonitor.compressedRAM, total: systemMonitor.totalRAM, color: .purple)
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(.white.opacity(0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(.white.opacity(0.06), lineWidth: 1)
                    )
            )
        }
        .padding(16)
        .frame(width: 300)
        .onReceive(timer) { _ in
            updateHistory()
        }
    }
    
    private var usedRAM: Double {
        systemMonitor.activeRAM + systemMonitor.wiredRAM + systemMonitor.compressedRAM
    }
    
    private var cpuColor: Color {
        let cpu = Int(systemMonitor.cpuLoad)
        if cpu >= 90 { return Color(hue: 0.0, saturation: 0.75, brightness: 1.0) }
        else if cpu >= 70 { return Color(hue: 0.12, saturation: 0.85, brightness: 1.0) }
        else { return Color(hue: 0.38, saturation: 0.7, brightness: 0.9) }
    }
    
    private var ramColor: Color {
        let ram = Int(systemMonitor.ramUsage)
        if ram >= 90 { return Color(hue: 0.0, saturation: 0.75, brightness: 1.0) }
        else if ram >= 70 { return Color(hue: 0.12, saturation: 0.85, brightness: 1.0) }
        else { return Color(hue: 0.38, saturation: 0.7, brightness: 0.9) }
    }
    
    private func updateHistory() {
        cpuHistory.removeFirst()
        cpuHistory.append(systemMonitor.cpuLoad)
        ramHistory.removeFirst()
        ramHistory.append(systemMonitor.ramUsage)
    }
}

// MARK: - Network Activity Popup (shown when clicking the Network Activity widget)

struct NetworkActivityPopup: View {
    @ObservedObject private var systemMonitor = SystemMonitorManager.shared
    @State private var networkUpHistory: [Double] = Array(repeating: 0, count: 30)
    @State private var networkDownHistory: [Double] = Array(repeating: 0, count: 30)
    
    private let timer = Timer.publish(every: 3, on: .main, in: .common).autoconnect()
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(Color.blue.opacity(0.15))
                        .frame(width: 32, height: 32)
                    Image(systemName: "network")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.blue)
                }
                
                VStack(alignment: .leading, spacing: 1) {
                    Text("Network Activity")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(Date(), style: .time)
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.4))
                }
                Spacer()
            }
            
            // Upload card
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.green)
                    Text("Upload")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                    Spacer()
                    Text(formatSpeed(systemMonitor.uploadSpeed))
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(.green)
                }
                
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(.white.opacity(0.04))
                    
                    SmoothLineChart(data: networkUpHistory, color: .green, maxValue: nil)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                }
                .frame(height: 40)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(.white.opacity(0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(.white.opacity(0.06), lineWidth: 1)
                    )
            )
            
            // Download card
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.cyan)
                    Text("Download")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                    Spacer()
                    Text(formatSpeed(systemMonitor.downloadSpeed))
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(.cyan)
                }
                
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(.white.opacity(0.04))
                    
                    SmoothLineChart(data: networkDownHistory, color: .cyan, maxValue: nil)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                }
                .frame(height: 40)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(.white.opacity(0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(.white.opacity(0.06), lineWidth: 1)
                    )
            )
        }
        .padding(16)
        .frame(width: 300)
        .onReceive(timer) { _ in
            updateHistory()
        }
    }
    
    private func formatSpeed(_ speed: Double) -> String {
        if speed >= 1.0 {
            return String(format: "%.1f MB/s", speed)
        } else if speed >= 0.001 {
            return String(format: "%.0f KB/s", speed * 1024)
        } else {
            return "0 B/s"
        }
    }
    
    private func updateHistory() {
        networkUpHistory.removeFirst()
        networkUpHistory.append(systemMonitor.uploadSpeed)
        networkDownHistory.removeFirst()
        networkDownHistory.append(systemMonitor.downloadSpeed)
    }
}

// MARK: - Full System Monitor Popup (kept for backward compatibility)

struct SystemMonitorPopup: View {
    @ObservedObject private var systemMonitor = SystemMonitorManager.shared
    @State private var cpuHistory: [Double] = Array(repeating: 0, count: 30)
    @State private var ramHistory: [Double] = Array(repeating: 0, count: 30)
    @State private var networkUpHistory: [Double] = Array(repeating: 0, count: 30)
    @State private var networkDownHistory: [Double] = Array(repeating: 0, count: 30)
    
    private let timer = Timer.publish(every: 3, on: .main, in: .common).autoconnect()
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(cpuColor.opacity(0.15))
                        .frame(width: 32, height: 32)
                    Image(systemName: "cpu")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(cpuColor)
                }
                
                VStack(alignment: .leading, spacing: 1) {
                    Text("System Monitor")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(Date(), style: .time)
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.4))
                }
                Spacer()
            }
            
            // CPU Section
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text("CPU")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                    Spacer()
                    Text("\(Int(systemMonitor.cpuLoad))%")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(cpuColor)
                }
                
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.white.opacity(0.04))
                    
                    SmoothLineChart(data: cpuHistory, color: cpuColor, maxValue: 100)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                }
                .frame(height: 50)
                
                HStack(spacing: 6) {
                    StatPill(label: "User", value: "\(Int(systemMonitor.userLoad))%", color: .cyan)
                    StatPill(label: "System", value: "\(Int(systemMonitor.systemLoad))%", color: .orange)
                    StatPill(label: "Idle", value: "\(Int(systemMonitor.idleLoad))%", color: .white.opacity(0.5))
                    Spacer()
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(.white.opacity(0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(.white.opacity(0.06), lineWidth: 1)
                    )
            )
            
            // RAM Section
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Memory")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                    Spacer()
                    VStack(alignment: .trailing, spacing: 1) {
                        Text("\(Int(systemMonitor.ramUsage))%")
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                            .foregroundStyle(ramColor)
                        Text("\(String(format: "%.1f", usedRAM)) / \(String(format: "%.0f", systemMonitor.totalRAM)) GB")
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                }
                
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.white.opacity(0.04))
                    
                    SmoothLineChart(data: ramHistory, color: ramColor, maxValue: 100)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                }
                .frame(height: 50)
                
                VStack(spacing: 5) {
                    MemoryBar(label: "Active", value: systemMonitor.activeRAM, total: systemMonitor.totalRAM, color: .cyan)
                    MemoryBar(label: "Wired", value: systemMonitor.wiredRAM, total: systemMonitor.totalRAM, color: .orange)
                    MemoryBar(label: "Compressed", value: systemMonitor.compressedRAM, total: systemMonitor.totalRAM, color: .purple)
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(.white.opacity(0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(.white.opacity(0.06), lineWidth: 1)
                    )
            )
            
            // Network Section
            VStack(alignment: .leading, spacing: 10) {
                Text("Network")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                
                HStack(spacing: 12) {
                    // Upload
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(.green)
                            Text("Up")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.white.opacity(0.5))
                        }
                        
                        Text(formatSpeed(systemMonitor.uploadSpeed))
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundStyle(.green)
                        
                        SmoothLineChart(data: networkUpHistory, color: .green, maxValue: nil)
                            .frame(height: 24)
                    }
                    
                    // Download
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.down.circle.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(.cyan)
                            Text("Down")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.white.opacity(0.5))
                        }
                        
                        Text(formatSpeed(systemMonitor.downloadSpeed))
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundStyle(.cyan)
                        
                        SmoothLineChart(data: networkDownHistory, color: .cyan, maxValue: nil)
                            .frame(height: 24)
                    }
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(.white.opacity(0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(.white.opacity(0.06), lineWidth: 1)
                    )
            )
        }
        .padding(16)
        .frame(width: 300)
        .onReceive(timer) { _ in
            updateHistory()
        }
    }
    
    private var usedRAM: Double {
        systemMonitor.activeRAM + systemMonitor.wiredRAM + systemMonitor.compressedRAM
    }
    
    private var cpuColor: Color {
        let cpu = Int(systemMonitor.cpuLoad)
        if cpu >= 90 { return Color(hue: 0.0, saturation: 0.75, brightness: 1.0) }
        else if cpu >= 70 { return Color(hue: 0.12, saturation: 0.85, brightness: 1.0) }
        else { return Color(hue: 0.38, saturation: 0.7, brightness: 0.9) }
    }
    
    private var ramColor: Color {
        let ram = Int(systemMonitor.ramUsage)
        if ram >= 90 { return Color(hue: 0.0, saturation: 0.75, brightness: 1.0) }
        else if ram >= 70 { return Color(hue: 0.12, saturation: 0.85, brightness: 1.0) }
        else { return Color(hue: 0.38, saturation: 0.7, brightness: 0.9) }
    }
    
    private func formatSpeed(_ speed: Double) -> String {
        if speed >= 1.0 {
            return String(format: "%.1f MB/s", speed)
        } else if speed >= 0.001 {
            return String(format: "%.0f KB/s", speed * 1024)
        } else {
            return "0 B/s"
        }
    }
    
    private func updateHistory() {
        cpuHistory.removeFirst()
        cpuHistory.append(systemMonitor.cpuLoad)
        ramHistory.removeFirst()
        ramHistory.append(systemMonitor.ramUsage)
        networkUpHistory.removeFirst()
        networkUpHistory.append(systemMonitor.uploadSpeed)
        networkDownHistory.removeFirst()
        networkDownHistory.append(systemMonitor.downloadSpeed)
    }
}

// MARK: - Shared Components

/// Pill-shaped stat badge used in CPU breakdown
private struct StatPill: View {
    let label: String
    let value: String
    let color: Color
    
    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 5, height: 5)
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
            Text(value)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.8))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(.white.opacity(0.06))
        )
    }
}

// MARK: - Chart Views

/// Smooth line chart with gradient fill, used across all popups
struct SmoothLineChart: View {
    let data: [Double]
    let color: Color
    let maxValue: Double?
    
    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            let effectiveMax = maxValue ?? max(data.max() ?? 1.0, 0.001)
            
            // Fill area
            Path { path in
                guard data.count > 1 else { return }
                let stepX = width / CGFloat(data.count - 1)
                
                path.move(to: CGPoint(x: 0, y: height))
                
                for (index, value) in data.enumerated() {
                    let x = CGFloat(index) * stepX
                    let normalizedValue = effectiveMax > 0 ? value / effectiveMax : 0
                    let y = height - CGFloat(min(normalizedValue, 1.0)) * height
                    
                    if index == 0 {
                        path.addLine(to: CGPoint(x: x, y: y))
                    } else {
                        // Smooth curve using quadratic bezier
                        let prevX = CGFloat(index - 1) * stepX
                        let prevValue = data[index - 1]
                        let prevNorm = effectiveMax > 0 ? prevValue / effectiveMax : 0
                        let prevY = height - CGFloat(min(prevNorm, 1.0)) * height
                        let midX = (prevX + x) / 2
                        path.addCurve(
                            to: CGPoint(x: x, y: y),
                            control1: CGPoint(x: midX, y: prevY),
                            control2: CGPoint(x: midX, y: y)
                        )
                    }
                }
                
                path.addLine(to: CGPoint(x: width, y: height))
                path.closeSubpath()
            }
            .fill(
                LinearGradient(
                    colors: [color.opacity(0.25), color.opacity(0.02)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            
            // Stroke line
            Path { path in
                guard data.count > 1 else { return }
                let stepX = width / CGFloat(data.count - 1)
                
                for (index, value) in data.enumerated() {
                    let x = CGFloat(index) * stepX
                    let normalizedValue = effectiveMax > 0 ? value / effectiveMax : 0
                    let y = height - CGFloat(min(normalizedValue, 1.0)) * height
                    
                    if index == 0 {
                        path.move(to: CGPoint(x: x, y: y))
                    } else {
                        let prevX = CGFloat(index - 1) * stepX
                        let prevValue = data[index - 1]
                        let prevNorm = effectiveMax > 0 ? prevValue / effectiveMax : 0
                        let prevY = height - CGFloat(min(prevNorm, 1.0)) * height
                        let midX = (prevX + x) / 2
                        path.addCurve(
                            to: CGPoint(x: x, y: y),
                            control1: CGPoint(x: midX, y: prevY),
                            control2: CGPoint(x: midX, y: y)
                        )
                    }
                }
            }
            .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            
            // Glow on the last point
            if let lastValue = data.last, data.count > 1 {
                let normalizedValue = effectiveMax > 0 ? lastValue / effectiveMax : 0
                let y = height - CGFloat(min(normalizedValue, 1.0)) * height
                
                Circle()
                    .fill(color)
                    .frame(width: 4, height: 4)
                    .shadow(color: color.opacity(0.6), radius: 4)
                    .position(x: width, y: y)
            }
        }
    }
}

// Legacy chart type aliases for backward compatibility
struct CPUChart: View {
    let data: [Double]
    let color: Color
    var body: some View {
        SmoothLineChart(data: data, color: color, maxValue: 100)
    }
}

struct RAMChart: View {
    let data: [Double]
    let color: Color
    var body: some View {
        SmoothLineChart(data: data, color: color, maxValue: 100)
    }
}

struct NetworkMiniChart: View {
    let data: [Double]
    let color: Color
    var body: some View {
        SmoothLineChart(data: data, color: color, maxValue: nil)
    }
}

struct MemoryBar: View {
    let label: String
    let value: Double
    let total: Double
    let color: Color
    
    private var percentage: Double {
        total > 0 ? (value / total) : 0
    }
    
    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 5, height: 5)
            
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.5))
                .frame(width: 72, alignment: .leading)
            
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2.5)
                        .fill(.white.opacity(0.08))
                    
                    RoundedRectangle(cornerRadius: 2.5)
                        .fill(
                            LinearGradient(
                                colors: [color, color.opacity(0.7)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(2, geometry.size.width * percentage))
                        .animation(.easeInOut(duration: 0.4), value: percentage)
                }
            }
            .frame(height: 5)
            
            Text("\(String(format: "%.1f", value)) GB")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 50, alignment: .trailing)
        }
    }
}

struct SystemMonitorPopup_Previews: PreviewProvider {
    static var previews: some View {
        SystemMonitorPopup()
            .previewLayout(.sizeThatFits)
    }
}