//
//  ContentView.swift
//  OBD ELM327 Connector

import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var viewModel = OBDViewModel()
    @State private var showingSettings = false
    @State private var showingLogManager = false
    @AppStorage("loggingEnabled") private var loggingEnabled: Bool = false
    @AppStorage("dataLoggingEnabled") private var dataLoggingEnabled: Bool = false

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 16) {
                    statusRow
                    fuelTrimCard
                    oilTempsCard
                    engineCard
                    if dataLoggingEnabled {
                        tuningDataLogCard
                    }
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
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { showingLogManager = true } label: {
                        Image(systemName: "folder")
                    }
                    .accessibilityLabel("Saved logs")
                }
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView()
            }
            .sheet(isPresented: $showingLogManager) {
                LogManagerView(viewModel: viewModel)
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

    // MARK: - Fluid Temperatures Card (ATF + Engine Oil + Coolant)

    private var oilTempsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Fluid Temperatures", systemImage: "thermometer.medium")
                .font(.headline)
            HStack(spacing: 0) {
                oilTempCell(label: "Coolant", value: viewModel.coolantTemp, color: coolantColor, badge: coolantLabel)
                Divider().frame(height: 60)
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

    // MARK: - Engine Card (RPM / load / throttle, standard Mode-01 PIDs)

    private var engineCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Engine", systemImage: "gauge.open.with.lines.needle.33percent")
                .font(.headline)
            HStack(spacing: 0) {
                engineCell(label: "RPM", value: viewModel.engineSpeed, format: "%.0f", unit: "")
                Divider().frame(height: 60)
                engineCell(label: "Load", value: viewModel.engineLoad, format: "%.1f", unit: "%")
                Divider().frame(height: 60)
                engineCell(label: "Throttle", value: viewModel.throttlePosition, format: "%.1f", unit: "%")
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

    // MARK: - Tuning Data Log (CSV)

    private var tuningDataLogCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Tuning Data Log", systemImage: "tablecells")
                    .font(.headline)
                Spacer()
                Text("\(viewModel.dataRowCount) rows")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Label(viewModel.dataLogFileName ?? "No file yet", systemImage: "doc.text")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            if let error = viewModel.dataLogFileError {
                Text("Log file error: \(error)")
                    .font(.caption2)
                    .foregroundStyle(.red)
            }

            if let url = viewModel.currentDataLogFileURL {
                ShareLink(item: url) {
                    Label("Share / AirDrop", systemImage: "square.and.arrow.up")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
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
                Text("\(viewModel.communicationLog.count) rows")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Label(viewModel.logFileName ?? "No file yet", systemImage: "doc.text")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            if let error = viewModel.logFileError {
                Text("Log file error: \(error)")
                    .font(.caption2)
                    .foregroundStyle(.red)
            }

            if let url = viewModel.currentTxRxFileURL {
                ShareLink(item: url) {
                    Label("Share / AirDrop", systemImage: "square.and.arrow.up")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                }
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
    @AppStorage("dataLoggingEnabled") private var dataLoggingEnabled: Bool = false
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
                    Text("Listen-Only (applies on next connect): passively sniffs the bus instead of requesting data.")
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

                Section {
                    Toggle("Data Logging (CSV)", isOn: $dataLoggingEnabled)
                    Toggle("TX/RX Logging", isOn: $loggingEnabled)
                } header: {
                    Text("Diagnostics")
                } footer: {
                    Text("Data Logging records STFT, LTFT, RPM, Throttle, Engine Load and Coolant with timestamps to a CSV you can share via AirDrop for tuning.")
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

// MARK: - Log Manager

struct LogManagerView: View {
    @ObservedObject var viewModel: OBDViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var files: [OBDViewModel.LogFileInfo] = []
    @State private var selection = Set<URL>()
    @State private var isEditing = false

    var body: some View {
        NavigationView {
            Group {
                if files.isEmpty {
                    ContentUnavailableView(
                        "No Saved Logs",
                        systemImage: "folder",
                        description: Text("A log file is created each time you connect with logging enabled.")
                    )
                } else {
                    List(files, selection: $selection) { info in
                        row(info)
                    }
                    .environment(\.editMode, .constant(isEditing ? .active : .inactive))
                }
            }
            .navigationTitle("Saved Logs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if !files.isEmpty {
                        Button(isEditing ? "Cancel" : "Select") {
                            isEditing.toggle()
                            if !isEditing { selection.removeAll() }
                        }
                    }
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    if isEditing {
                        Button(allSelected ? "Deselect All" : "Select All") {
                            selection = allSelected ? [] : Set(files.map(\.id))
                        }
                    }
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    if isEditing {
                        ShareLink(items: Array(selection)) {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }
                        .disabled(selection.isEmpty)
                        Spacer()
                        Button(role: .destructive) {
                            viewModel.deleteLogFiles(Array(selection))
                            selection.removeAll()
                            reload()
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .disabled(selection.isEmpty)
                    }
                }
            }
            .onAppear(perform: reload)
        }
    }

    private var allSelected: Bool {
        !files.isEmpty && selection.count == files.count
    }

    private func reload() {
        files = viewModel.savedLogFiles()
        selection = selection.intersection(Set(files.map(\.id)))   // drop deleted/missing
    }

    @ViewBuilder
    private func row(_ info: OBDViewModel.LogFileInfo) -> some View {
        HStack(spacing: 12) {
            Image(systemName: info.isCSV ? "tablecells" : "terminal")
                .foregroundStyle(info.isCSV ? .blue : .green)
            VStack(alignment: .leading, spacing: 2) {
                Text(info.name)
                    .font(.subheadline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(info.date.formatted(date: .abbreviated, time: .shortened)) · \(info.sizeText)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(info.isCSV ? "CSV" : "TXT")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
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
