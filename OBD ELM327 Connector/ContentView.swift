//
//  ContentView.swift
//  OBD ELM327 Connector

import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var viewModel = OBDViewModel()
    @State private var showingSettings = false
    @AppStorage("loggingEnabled") private var loggingEnabled: Bool = false

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 16) {
                    statusRow
                    fuelTrimCard
                    oilTempsCard
                    coolantCard
                    engineCard
                    if loggingEnabled {
                        communicationLogCard
                    }
                    Spacer(minLength: 8)
                    connectButton
                }
                .padding()
            }
            .navigationTitle("OBD-II Monitor")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showingSettings = true } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView()
            }
        }
    }

    // MARK: - Status Row

    private var statusRow: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusDotColor)
                .frame(width: 10, height: 10)
            Text(viewModel.connectionStatus)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            if let update = viewModel.lastUpdate {
                Text(update, style: .time)
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 4)
    }

    // MARK: - Fuel Trim Card

    private var fuelTrimCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Fuel Trims", systemImage: "gauge.with.needle")
                    .font(.headline)
                Spacer()
                Text(fuelTrimSum.map { String(format: "Total %+.2f%%", $0) } ?? "")
                    .font(.headline)
                    .foregroundStyle(trimColor(fuelTrimSum))
                    .monospacedDigit()
            }
            HStack(spacing: 0) {
                trimCell(label: "STFT", subtitle: "Short Term", value: viewModel.stft)
                Divider().frame(height: 60)
                trimCell(label: "LTFT", subtitle: "Long Term", value: viewModel.ltft)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 14))
    }

    private var fuelTrimSum: Double? {
        guard let stft = viewModel.stft, let ltft = viewModel.ltft else { return nil }
        return stft + ltft
    }

    @ViewBuilder
    private func trimCell(label: String, subtitle: String, value: Double?) -> some View {
        VStack(spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value.map { String(format: "%+.2f", $0) } ?? "—")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundStyle(trimColor(value))
                    .monospacedDigit()
                if value != nil {
                    Text("%")
                        .font(.callout.bold())
                        .foregroundStyle(.secondary)
                }
            }
            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }

    // MARK: - Oil Temperatures Card (ATF + Engine Oil)

    private var oilTempsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Oil Temperatures", systemImage: "thermometer.medium")
                .font(.headline)
            HStack(spacing: 0) {
                oilTempCell(label: "Trans Fluid", value: viewModel.atfTemp, color: atfColor, badge: atfLabel)
                Divider().frame(height: 60)
                oilTempCell(label: "Engine Oil", value: viewModel.engineOilTemp, color: engineOilColor, badge: engineOilLabel)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder
    private func oilTempCell(label: String, value: Double?, color: Color, badge: String) -> some View {
        VStack(spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value.map { String(format: "%.1f", $0) } ?? "—")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundStyle(color)
                    .monospacedDigit()
                if value != nil {
                    Text("°C")
                        .font(.callout.bold())
                        .foregroundStyle(.secondary)
                }
            }
            if value != nil {
                Text(badge)
                    .font(.caption2)
                    .foregroundStyle(color)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(color.opacity(0.15), in: Capsule())
            } else {
                Text(" ").font(.caption2)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }

    // MARK: - Coolant Temp Card

    private var coolantCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Coolant Temp", systemImage: "thermometer.medium")
                .font(.headline)
            HStack(spacing: 0) {
                coolantV2Cell(label: "7E0", subtitle: "2101 sensor", value: viewModel.coolantTemp)
                Divider().frame(height: 60)
                coolantV2Cell(label: "7C0", subtitle: "2123 sensor", value: viewModel.coolantTempV2)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder
    private func coolantV2Cell(label: String, subtitle: String, value: Double?) -> some View {
        VStack(spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value.map { String(format: "%.1f", $0) } ?? "—")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundStyle(coolantV2TempColor(value))
                    .monospacedDigit()
                if value != nil {
                    Text("°C")
                        .font(.callout.bold())
                        .foregroundStyle(.secondary)
                }
            }
            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }

    // MARK: - Engine Card (from 2101)

    private var engineCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Engine", systemImage: "gauge.open.with.lines.needle.33percent")
                .font(.headline)
            HStack(spacing: 0) {
                engineCell(label: "RPM", value: viewModel.engineSpeed, format: "%.0f", unit: "")
                Divider().frame(height: 60)
                engineCell(label: "Throttle", value: viewModel.throttlePosition, format: "%.1f", unit: "%")
                Divider().frame(height: 60)
                engineCell(label: "Throttle V", value: viewModel.throttleVolt, format: "%.1f", unit: "%")
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder
    private func engineCell(label: String, value: Double?, format: String, unit: String) -> some View {
        VStack(spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value.map { String(format: format, $0) } ?? "—")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                    .monospacedDigit()
                if value != nil, !unit.isEmpty {
                    Text(unit)
                        .font(.callout.bold())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }

    // MARK: - Communication Log

    private var communicationLogCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("TX / RX Log", systemImage: "terminal")
                    .font(.headline)
                Spacer()
                Text("\(viewModel.communicationLog.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            logFileControls

            if let error = viewModel.logFileError {
                Text("Log file error: \(error)")
                    .font(.caption2)
                    .foregroundStyle(.red)
            }

            if viewModel.communicationLog.isEmpty {
                Text("No messages yet")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 96, alignment: .center)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(viewModel.communicationLog) { entry in
                                communicationLogRow(entry)
                                    .id(entry.id)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 180)
                    .onChange(of: viewModel.communicationLog.last?.id) { _, id in
                        guard let id else { return }
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(id, anchor: .bottom)
                        }
                    }
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 14))
    }

    private var logFileControls: some View {
        HStack(spacing: 8) {
            Label(viewModel.logFileName, systemImage: "doc.text")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            Button {
                UIPasteboard.general.string = viewModel.savedLogText()
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Copy saved log")

            Button(role: .destructive) {
                viewModel.clearSavedLog()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Clear saved log")
        }
    }

    private func communicationLogRow(_ entry: OBDCommunicationLogEntry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(entry.timestamp, style: .time)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 62, alignment: .leading)

            Text(entry.direction.rawValue)
                .font(.caption2.weight(.bold).monospaced())
                .foregroundStyle(entry.direction == .sent ? .blue : .green)
                .frame(width: 24, alignment: .leading)

            Text(entry.message)
                .font(.caption.monospaced())
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Connect Button

    private var connectButton: some View {
        Button {
            if viewModel.isConnected {
                viewModel.disconnect()
            } else {
                viewModel.connect()
            }
        } label: {
            HStack {
                Image(systemName: viewModel.isConnected ? "antenna.radiowaves.left.and.right.slash" : "antenna.radiowaves.left.and.right")
                Text(viewModel.isConnected ? "Disconnect" : "Connect to OBD Adapter")
                    .fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(
                viewModel.isConnected
                    ? Color(.systemRed).opacity(0.12)
                    : Color.accentColor,
                in: RoundedRectangle(cornerRadius: 14)
            )
            .foregroundStyle(viewModel.isConnected ? .red : .white)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Derived colours

    private var statusDotColor: Color {
        let s = viewModel.connectionStatus
        if s.contains("Polling") || s.contains("Connected") || s.contains("Restoring")
            || s.contains("Listen") || s.contains("Monitor") { return .green }
        if s.contains("Querying")   { return .cyan }
        if s.contains("Scanning") || s.contains("Connecting") || s.contains("Initialising") { return .yellow }
        if s.contains("Error") || s.contains("Off") || s.contains("Unauthorized") { return .red }
        return .gray
    }

    private func trimColor(_ value: Double?) -> Color {
        guard let v = value else { return .primary }
        let abs = Swift.abs(v)
        if abs <= 5  { return .green }
        if abs <= 10 { return .orange }
        return .red
    }

    private var atfColor: Color {
        guard let t = viewModel.atfTemp else { return .primary }
        if t < 90  { return .green }
        if t < 110 { return .orange }
        return .red
    }

    private var atfLabel: String {
        guard let t = viewModel.atfTemp else { return "" }
        if t < 90  { return "Normal" }
        if t < 110 { return "Warm" }
        return "Hot"
    }

    private func coolantV2TempColor(_ temp: Double?) -> Color {
        guard let t = temp else { return .primary }
        if t < 95  { return .green }
        if t < 105 { return .orange }
        return .red
    }

    private var engineOilColor: Color {
        guard let t = viewModel.engineOilTemp else { return .primary }
        if t < 105 { return .green }
        if t < 125 { return .orange }
        return .red
    }

    private var engineOilLabel: String {
        guard let t = viewModel.engineOilTemp else { return "" }
        if t < 105 { return "Normal" }
        if t < 125 { return "Warm" }
        return "Hot"
    }
}

// MARK: - Settings View

struct SettingsView: View {
    @AppStorage("pollingDelay")    private var pollingDelay: Double = 1.0
    @AppStorage("keepScreenAwake") private var keepScreenAwake: Bool = true
    @AppStorage("loggingEnabled")  private var loggingEnabled: Bool = false
    @AppStorage("listenOnlyMode")  private var listenOnlyMode: Bool = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            Form {
                Section {
                    Toggle("Listen-Only (passive monitor)", isOn: $listenOnlyMode)
                } header: {
                    Text("Mode")
                } footer: {
                    Text("Applies on next connect. Passively sniffs the bus instead of requesting data — values update only while another tool is actively polling these PIDs.")
                }

                Section("Polling") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Delay between cycles")
                            Spacer()
                            Text(String(format: "%.1f s", pollingDelay))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: $pollingDelay, in: 0.5...10.0, step: 0.5)
                    }
                    .padding(.vertical, 4)
                }

                Section("Display") {
                    Toggle("Keep Screen Awake", isOn: $keepScreenAwake)
                        .onChange(of: keepScreenAwake) { _, newValue in
                            UIApplication.shared.isIdleTimerDisabled = newValue
                        }
                }

                Section("Diagnostics") {
                    Toggle("TX/RX Logging", isOn: $loggingEnabled)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

#if DEBUG
extension ContentView {
    init(viewModel: OBDViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }
}
#endif

#Preview {
    ContentView(viewModel: .preview)
}
