import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var model: AndroidAppModel

    var body: some View {
        TabView {
            HomeScreen(model: model)
                .tabItem { Label("Home", systemImage: "house.fill") }

            AppLibraryScreen(model: model)
                .tabItem { Label("Apps", systemImage: "square.grid.2x2.fill") }

            RuntimeScreen(model: model)
                .tabItem { Label("Runtime", systemImage: "cpu.fill") }

            SettingsScreen(model: model)
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
        }
        .tint(.green)
        .fileImporter(
            isPresented: $model.isImporterPresented,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first { model.importPackage(from: url) }
            case .failure(let error):
                model.alertMessage = "The package picker failed: \(error.localizedDescription)"
            }
        }
        .alert(
            "Android iOSEmulator",
            isPresented: Binding(
                get: { model.alertMessage != nil },
                set: { visible in if !visible { model.alertMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { model.alertMessage = nil }
        } message: {
            Text(model.alertMessage ?? "")
        }
    }
}

private struct HomeScreen: View {
    @ObservedObject var model: AndroidAppModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    RuntimeHero(model: model)

                    ActionGrid(model: model)

                    SectionHeader(title: "Android apps", trailing: "\(model.packages.count)")

                    if model.packages.isEmpty {
                        EmptyLibraryCard {
                            model.isImporterPresented = true
                        }
                    } else {
                        VStack(spacing: 10) {
                            ForEach(model.packages.prefix(4)) { package in
                                PackageRow(package: package) {
                                    model.launch(package)
                                } deleteAction: {
                                    model.deletePackage(package)
                                }
                            }
                        }
                    }

                    StatusCard(model: model)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 24)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Android")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        model.isImporterPresented = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Import Android package")
                }
            }
        }
    }
}

private struct RuntimeHero: View {
    @ObservedObject var model: AndroidAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(.green.gradient)
                    Image(systemName: "smartphone")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(.black)
                }
                .frame(width: 64, height: 64)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Android SE")
                        .font(.title2.bold())
                    Text(model.statusTitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(statusColor)
                    Text(model.runtimeDetail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            Button {
                if model.runtimePhase == .running {
                    model.stopRuntime()
                } else {
                    model.startRuntime()
                }
            } label: {
                Label(
                    model.runtimePhase == .running ? "Stop Android" : "Start Android",
                    systemImage: model.runtimePhase == .running ? "stop.fill" : "play.fill"
                )
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .tint(model.runtimePhase == .running ? .red : .green)
            .foregroundStyle(model.runtimePhase == .running ? .white : .black)
        }
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var statusColor: Color {
        switch model.runtimePhase {
        case .running: return .green
        case .failed: return .red
        case .blocked: return .orange
        default: return .secondary
        }
    }
}

private struct ActionGrid: View {
    @ObservedObject var model: AndroidAppModel

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                actionButton(title: "Import APK", subtitle: "APK, APKS, XAPK", icon: "square.and.arrow.down.fill") {
                    model.isImporterPresented = true
                }
                actionButton(title: "Check Runtime", subtitle: "Core and guest files", icon: "checkmark.shield.fill") {
                    model.refreshRuntimeAvailability()
                }
            }

            VStack(spacing: 12) {
                actionButton(title: "Import APK", subtitle: "APK, APKS, XAPK", icon: "square.and.arrow.down.fill") {
                    model.isImporterPresented = true
                }
                actionButton(title: "Check Runtime", subtitle: "Core and guest files", icon: "checkmark.shield.fill") {
                    model.refreshRuntimeAvailability()
                }
            }
        }
    }

    private func actionButton(
        title: String,
        subtitle: String,
        icon: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.title3)
                    .frame(width: 34, height: 34)
                    .background(.green.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline.bold())
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
            }
            .padding(14)
            .frame(maxWidth: .infinity)
            .background(.background, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct StatusCard: View {
    @ObservedObject var model: AndroidAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Build status", trailing: nil)
            ChecklistRow(
                title: "Phone interface",
                detail: "Responsive app library and importer",
                passed: true
            )
            ChecklistRow(
                title: "SE runtime core",
                detail: "UTM/QEMU threaded interpreter bridge",
                passed: model.runtimeCoreAvailable
            )
            ChecklistRow(
                title: "Android guest",
                detail: "Kernel, initramfs, system and userdata",
                passed: model.runtimeAssets.filter(\.required).allSatisfy(\.present)
            )
        }
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

private struct AppLibraryScreen: View {
    @ObservedObject var model: AndroidAppModel
    private let columns = [GridItem(.adaptive(minimum: 132, maximum: 190), spacing: 14)]

    var body: some View {
        NavigationStack {
            ScrollView {
                if model.packages.isEmpty {
                    EmptyLibraryCard {
                        model.isImporterPresented = true
                    }
                    .padding(16)
                } else {
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(model.packages) { package in
                            PackageTile(package: package) {
                                model.launch(package)
                            } deleteAction: {
                                model.deletePackage(package)
                            }
                        }
                    }
                    .padding(16)
                }
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Apps")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        model.isImporterPresented = true
                    } label: {
                        Label("Import", systemImage: "plus")
                    }
                }
            }
        }
    }
}

private struct RuntimeScreen: View {
    @ObservedObject var model: AndroidAppModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Execution mode")
                            .font(.headline)
                        Picker("Execution mode", selection: $model.runtimeMode) {
                            ForEach(AndroidRuntimeMode.allCases) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        Text(model.runtimeMode.detail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .cardStyle()

                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeader(title: "Runtime components", trailing: nil)
                        ChecklistRow(
                            title: "android_qemu_se_start",
                            detail: "Native SE bridge symbol",
                            passed: model.runtimeCoreAvailable
                        )
                        ForEach(model.runtimeAssets) { asset in
                            ChecklistRow(
                                title: asset.title,
                                detail: asset.required ? asset.filename : "\(asset.filename) · optional",
                                passed: asset.present
                            )
                        }
                        Button("Refresh Runtime Check") {
                            model.refreshRuntimeAvailability()
                        }
                        .buttonStyle(.bordered)
                    }
                    .cardStyle()

                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Runtime log").font(.headline)
                            Spacer()
                            Button("Export") { model.exportLogs() }
                                .font(.subheadline)
                        }

                        if model.logs.isEmpty {
                            Text("No runtime events yet.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        } else {
                            ScrollView(.horizontal) {
                                Text(model.logs.suffix(80).joined(separator: "\n"))
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(minHeight: 180)
                        }

                        if let url = model.exportedLogURL {
                            ShareLink(item: url) {
                                Label("Share exported log", systemImage: "square.and.arrow.up")
                            }
                        }
                    }
                    .cardStyle()
                }
                .padding(16)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Runtime")
        }
    }
}

private struct SettingsScreen: View {
    @ObservedObject var model: AndroidAppModel

    var body: some View {
        NavigationStack {
            List {
                Section("Android runtime") {
                    LabeledContent("Default mode", value: model.runtimeMode.rawValue)
                    LabeledContent("Runtime state", value: model.statusTitle)
                    LabeledContent("Imported packages", value: String(model.packages.count))
                }

                Section("Compatibility") {
                    Label("ARM64 Android packages are the primary target", systemImage: "cpu")
                    Label("SE mode does not need StikDebug or LocalDevVPN", systemImage: "checkmark.shield")
                    Label("JIT remains disabled on the current iOS 27 beta", systemImage: "exclamationmark.triangle")
                }

                Section("Storage") {
                    Button("Import Android Package") {
                        model.isImporterPresented = true
                    }
                    Button("Refresh Runtime Files") {
                        model.refreshRuntimeAvailability()
                    }
                }

                Section("About") {
                    LabeledContent("Interface", value: "LiveContainer-style")
                    LabeledContent("Runtime target", value: "UTM/QEMU SE")
                    LabeledContent("Guest target", value: "AOSP ARM64")
                    Text("The app reports missing runtime components honestly. It never marks Android as running unless the native bridge starts successfully.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
        }
    }
}

private struct PackageTile: View {
    let package: AndroidPackageRecord
    let launchAction: () -> Void
    let deleteAction: () -> Void

    var body: some View {
        Button(action: launchAction) {
            VStack(alignment: .leading, spacing: 10) {
                PackageIcon(name: package.displayName, size: 58)
                Text(package.displayName)
                    .font(.subheadline.bold())
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(package.formattedSize)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                StateBadge(state: package.state)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 174, alignment: .topLeading)
            .background(.background, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Launch", action: launchAction)
            Button("Delete", role: .destructive, action: deleteAction)
        }
    }
}

private struct PackageRow: View {
    let package: AndroidPackageRecord
    let launchAction: () -> Void
    let deleteAction: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            PackageIcon(name: package.displayName, size: 48)
            VStack(alignment: .leading, spacing: 3) {
                Text(package.displayName)
                    .font(.subheadline.bold())
                    .lineLimit(1)
                Text("\(package.formattedSize) · \(package.state.rawValue.capitalized)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button(action: launchAction) {
                Image(systemName: "play.fill")
                    .frame(width: 38, height: 38)
                    .background(.green, in: Circle())
                    .foregroundStyle(.black)
            }
            .buttonStyle(.plain)
            Menu {
                Button("Delete", role: .destructive, action: deleteAction)
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 34, height: 38)
            }
        }
        .padding(12)
        .background(.background, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct PackageIcon: View {
    let name: String
    let size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .fill(.green.gradient)
            Text(initials)
                .font(.system(size: size * 0.3, weight: .black, design: .rounded))
                .foregroundStyle(.black)
        }
        .frame(width: size, height: size)
    }

    private var initials: String {
        let words = name.split(separator: " ").prefix(2)
        let value = words.compactMap(\.first).map(String.init).joined()
        return value.isEmpty ? "A" : value.uppercased()
    }
}

private struct StateBadge: View {
    let state: AndroidPackageRecord.State

    var body: some View {
        Text(state.rawValue.capitalized)
            .font(.caption2.bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    private var color: Color {
        switch state {
        case .installed: return .green
        case .failed: return .red
        case .installing: return .orange
        case .imported: return .secondary
        }
    }
}

private struct EmptyLibraryCard: View {
    let importAction: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "square.stack.3d.up.slash")
                .font(.system(size: 42))
                .foregroundStyle(.secondary)
            Text("No Android apps yet")
                .font(.headline)
            Text("Import an APK, APKS, or XAPK package. It will stay in the app library between launches.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Import Package", action: importAction)
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .foregroundStyle(.black)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .background(.background, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

private struct ChecklistRow: View {
    let title: String
    let detail: String
    let passed: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(passed ? .green : .orange)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }
}

private struct SectionHeader: View {
    let title: String
    let trailing: String?

    var body: some View {
        HStack {
            Text(title).font(.headline)
            Spacer()
            if let trailing {
                Text(trailing).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }
}

private extension View {
    func cardStyle() -> some View {
        self
            .padding(16)
            .background(.background, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}
