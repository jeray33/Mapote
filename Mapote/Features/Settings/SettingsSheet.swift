import SwiftUI

struct SettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: NoteStore
    @State private var config = AppConfig.load()
    @State private var diagnosing = false
    @State private var diagnosisLines: [String] = []

    var body: some View {
        NavigationStack {
            Form {
                Section("AI") {
                    SecureField("Gemini API Key", text: geminiKeyBinding)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section("地图（基础）") {
                    Picker("底图样式", selection: Binding(
                        get: { store.mapSettings.theme },
                        set: { newTheme in
                            store.updateMapSettings { settings in
                                settings.theme = newTheme
                            }
                        }
                    )) {
                        Text("标准").tag("default")
                        Text("影像").tag("night")
                    }
                    .pickerStyle(.segmented)

                    Toggle("显示导航路线", isOn: Binding(
                        get: { store.mapSettings.showRoute },
                        set: { value in store.updateMapSettings { $0.showRoute = value } }
                    ))
                    Toggle("显示地点连线", isOn: Binding(
                        get: { store.mapSettings.showConnections },
                        set: { value in store.updateMapSettings { $0.showConnections = value } }
                    ))
                    Toggle("显示编号", isOn: Binding(
                        get: { store.mapSettings.showNumber },
                        set: { value in store.updateMapSettings { $0.showNumber = value } }
                    ))
                    Toggle("显示名称", isOn: Binding(
                        get: { store.mapSettings.showName },
                        set: { value in store.updateMapSettings { $0.showName = value } }
                    ))
                }
                Section("POI 分类显示") {
                    Button("全部开启") {
                        store.updateMapSettings { settings in
                            settings.poiToggles = Dictionary(uniqueKeysWithValues: PlaceCategory.allCases.map { ($0, true) })
                        }
                    }
                    Button("全部关闭") {
                        store.updateMapSettings { settings in
                            settings.poiToggles = Dictionary(uniqueKeysWithValues: PlaceCategory.allCases.map { ($0, false) })
                        }
                    }
                    ForEach(PlaceCategory.allCases) { category in
                        Toggle(category.title, isOn: Binding(
                            get: { store.mapSettings.poiToggles[category] ?? true },
                            set: { value in
                                store.updateMapSettings { settings in
                                    settings.poiToggles[category] = value
                                }
                            }
                        ))
                    }
                }
                Section("开发者") {
                    DisclosureGroup("开发者高级设置") {
                        SecureField("Google Maps API Key", text: googleKeyBinding)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField("高德 API Key", text: amapKeyBinding)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Toggle("启用地图数据接口实验项", isOn: mapDataEnabledBinding)

                        Picker("当前数据接口", selection: Binding(
                            get: { store.mapEngineType },
                            set: { store.setMapEngine($0) }
                        )) {
                            Text("Google").tag(MapEngineType.google)
                            Text("高德").tag(MapEngineType.amap)
                        }
                        .pickerStyle(.segmented)
                        .disabled(!config.mapDataInterfaceEnabled)

                        if !config.mapDataInterfaceEnabled {
                            Text("已关闭实验项，数据接口切换与诊断不可用。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else if !store.hasGoogleMapKey || !store.hasAmapMapKey {
                            Text("未配置 Key 的接口不可用，请补全对应 Key。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Toggle("标记聚合（UI预留）", isOn: Binding(
                            get: { store.mapSettings.markerClustering },
                            set: { value in store.updateMapSettings { $0.markerClustering = value } }
                        ))
                        Toggle("交通标注（未接线）", isOn: Binding(
                            get: { store.mapSettings.showTraffic },
                            set: { value in store.updateMapSettings { $0.showTraffic = value } }
                        ))
                        .disabled(true)
                        Toggle("道路标注（未接线）", isOn: Binding(
                            get: { store.mapSettings.showRoadLabels },
                            set: { value in store.updateMapSettings { $0.showRoadLabels = value } }
                        ))
                        .disabled(true)
                        Toggle("水域标注（未接线）", isOn: Binding(
                            get: { store.mapSettings.showWaterLabels },
                            set: { value in store.updateMapSettings { $0.showWaterLabels = value } }
                        ))
                        .disabled(true)

                        Button {
                            Task { await runMapDiagnostics() }
                        } label: {
                            HStack {
                                if diagnosing {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Image(systemName: "stethoscope")
                                }
                                Text(diagnosing ? "诊断中..." : "运行诊断")
                            }
                        }
                        .disabled(diagnosing || !config.mapDataInterfaceEnabled)

                        if !config.mapDataInterfaceEnabled {
                            Text("需先开启“地图数据接口实验项”。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        ForEach(Array(diagnosisLines.enumerated()), id: \.offset) { _, line in
                            Text("• \(line)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Text("仅开发调试使用；普通使用无需展开本分组。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("应用配置")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }

    private var geminiKeyBinding: Binding<String> {
        Binding(
            get: { config.geminiAPIKey },
            set: { newValue in
                config.geminiAPIKey = newValue
                persistConfig()
            }
        )
    }

    private var googleKeyBinding: Binding<String> {
        Binding(
            get: { config.googleMapsKey },
            set: { newValue in
                config.googleMapsKey = newValue
                persistConfig(reinitializeMapEngine: true)
            }
        )
    }

    private var amapKeyBinding: Binding<String> {
        Binding(
            get: { config.amapKey },
            set: { newValue in
                config.amapKey = newValue
                persistConfig(reinitializeMapEngine: true)
            }
        )
    }

    private var mapDataEnabledBinding: Binding<Bool> {
        Binding(
            get: { config.mapDataInterfaceEnabled },
            set: { newValue in
                config.mapDataInterfaceEnabled = newValue
                persistConfig(reinitializeMapEngine: true)
            }
        )
    }

    private func persistConfig(reinitializeMapEngine: Bool = false) {
        config.save()
        guard reinitializeMapEngine else { return }
        Task {
            await store.initializeMapEngine()
        }
    }

    private func runMapDiagnostics() async {
        guard config.mapDataInterfaceEnabled else { return }
        diagnosing = true
        diagnosisLines = []
        defer { diagnosing = false }

        diagnosisLines.append("底图渲染：MapKit")
        diagnosisLines.append("数据接口：\(store.mapEngineType == .google ? "Google" : "高德")")
        diagnosisLines.append("Google Key：\(store.hasGoogleMapKey ? "已配置" : "未配置")，高德 Key：\(store.hasAmapMapKey ? "已配置" : "未配置")")

        do {
            try await store.nativeEngine.loadScript()
            diagnosisLines.append("MapKit 引擎：成功")
        } catch {
            diagnosisLines.append("MapKit 引擎：失败（\(error.localizedDescription)）")
            return
        }

        let nativeResults = await store.nativeEngine.textSearch(
            query: "咖啡",
            options: SearchOptions(locationBias: nil, radius: 12000, city: nil)
        )
        diagnosisLines.append("MapKit POI 搜索：\(nativeResults.isEmpty ? "无结果" : "成功，\(nativeResults.count) 条")")

        let selectedRemote = store.remoteEngine(for: store.mapEngineType)
        if store.isMapEngineAvailable(store.mapEngineType) {
            do {
                try await selectedRemote.loadScript()
                diagnosisLines.append("\(store.mapEngineType == .google ? "Google" : "高德") 接口初始化：成功")
            } catch {
                diagnosisLines.append("\(store.mapEngineType == .google ? "Google" : "高德") 接口初始化：失败（\(error.localizedDescription)）")
                return
            }
        } else {
            diagnosisLines.append("\(store.mapEngineType == .google ? "Google" : "高德") 接口初始化：未配置 key")
            return
        }

        let remoteResults = await selectedRemote.textSearch(
            query: "咖啡",
            options: SearchOptions(locationBias: nil, radius: 12000, city: nil)
        )
        diagnosisLines.append("\(store.mapEngineType == .google ? "Google" : "高德") POI 搜索：\(remoteResults.isEmpty ? "无结果" : "成功，\(remoteResults.count) 条")")
    }
}

