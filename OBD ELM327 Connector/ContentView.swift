//
//  ContentView.swift
//  OBD ELM327 Connector

import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var viewModel = OBDViewModel()

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 16) {
                    statusRow
                    fuelTrimCard
                    atfCard
                    coolantCard
                    coolantV2Card
                    engineOilCard
                    communicationLogCard
                    Spacer(minLength: 8)
                    connectButton
                }
                .padding()
            }
            .navigationTitle("OBD-II Monitor")
            .navigationBarTitleDisplayMode(.large)
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
            Label("Fuel Trims", systemImage: "gauge.with.needle")
                .font(.headline)
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

    // MARK: - ATF Temp Card

    private var atfCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Transmission Fluid Temp", systemImage: "thermometer.medium")
                .font(.headline)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(viewModel.atfTemp.map { String(format: "%.1f", $0) } ?? "—")
                    .font(.system(size: 52, weight: .bold, design: .rounded))
                    .foregroundStyle(atfColor)
                    .monospacedDigit()
                if viewModel.atfTemp != nil {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("°C")
                            .font(.title2.bold())
                            .foregroundStyle(.secondary)
                        Text(atfLabel)
                            .font(.caption2)
                            .foregroundStyle(atfColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(atfColor.opacity(0.15), in: Capsule())
                    }
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Coolant Temp Card

    private var coolantCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Coolant Temp", systemImage: "thermometer.medium")
                .font(.headline)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(viewModel.coolantTemp.map { String(format: "%.1f", $0) } ?? "—")
                    .font(.system(size: 52, weight: .bold, design: .rounded))
                    .foregroundStyle(coolantColor)
                    .monospacedDigit()
                if viewModel.coolantTemp != nil {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("°C")
                            .font(.title2.bold())
                            .foregroundStyle(.secondary)
                        Text(coolantLabel)
                            .font(.caption2)
                            .foregroundStyle(coolantColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(coolantColor.opacity(0.15), in: Capsule())
                    }
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Coolant Temp V2 Card

    private var coolantV2Card: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Coolant Temp (V2)", systemImage: "thermometer.medium")
                .font(.headline)
            HStack(spacing: 0) {
                coolantV2Cell(label: "ECT", subtitle: "Engine Coolant", value: viewModel.coolantTempECT)
                Divider().frame(height: 60)
                coolantV2Cell(label: "Coolant", subtitle: "7C0 Sensor", value: viewModel.coolantTempV2)
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

    // MARK: - Engine Oil Temp Card

    private var engineOilCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Engine Oil Temp", systemImage: "oilcan")
                .font(.headline)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(viewModel.engineOilTemp.map { String(format: "%.1f", $0) } ?? "—")
                    .font(.system(size: 52, weight: .bold, design: .rounded))
                    .foregroundStyle(engineOilColor)
                    .monospacedDigit()
                if viewModel.engineOilTemp != nil {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("°C")
                            .font(.title2.bold())
                            .foregroundStyle(.secondary)
                        Text(engineOilLabel)
                            .font(.caption2)
                            .foregroundStyle(engineOilColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(engineOilColor.opacity(0.15), in: Capsule())
                    }
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 14))
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
        if s.contains("Monitoring") || s.contains("Connected") { return .green }
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

    private var coolantColor: Color {
        guard let t = viewModel.coolantTemp else { return .primary }
        if t < 95  { return .green }
        if t < 105 { return .orange }
        return .red
    }

    private var coolantLabel: String {
        guard let t = viewModel.coolantTemp else { return "" }
        if t < 95  { return "Normal" }
        if t < 105 { return "Warm" }
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
