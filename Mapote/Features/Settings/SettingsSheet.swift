import SwiftUI

struct SettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: NoteStore
    @AppStorage(AppConfigKey.amapKey) private var amapKey = ""

    var body: some View {
        NavigationStack {
            Form {
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

                    Picker("强调程度", selection: Binding(
                        get: { store.mapSettings.emphasis },
                        set: { newValue in
                            store.updateMapSettings { settings in
                                settings.emphasis = newValue
                            }
                        }
                    )) {
                        Text("标准").tag("default")
                        Text("弱化").tag("muted")
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
                    Toggle("显示交通路况", isOn: Binding(
                        get: { store.mapSettings.showTraffic },
                        set: { value in store.updateMapSettings { $0.showTraffic = value } }
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
                Section("iCloud 同步") {
                    HStack {
                        Text("状态")
                        Spacer()
                        if store.isCloudSyncing {
                            ProgressView()
                        } else if store.cloudSyncError == nil {
                            Text("已开启")
                                .foregroundStyle(.secondary)
                        } else {
                            Text("本地模式")
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let lastCloudSyncAt = store.lastCloudSyncAt {
                        LabeledContent("最近同步", value: lastCloudSyncAt.formatted(date: .abbreviated, time: .shortened))
                    } else {
                        LabeledContent("最近同步", value: "尚未完成")
                    }

                    if let error = store.cloudSyncError {
                        Text("iCloud 暂不可用，本机数据仍会正常保存。\n\(error)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Button {
                        Task { await store.syncWithiCloud() }
                    } label: {
                        Text(store.isCloudSyncing ? "正在同步…" : "立即同步")
                    }
                    .disabled(store.isCloudSyncing)
                }
                Section("地点图片") {
                    SecureField("高德 Web服务 API Key", text: $amapKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    if amapKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("填写后，新增地点如果没有图片，会自动用高德 POI 搜索补一张封面；高德无图时仍显示类别图标。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Button("清除高德 API Key", role: .destructive) {
                            amapKey = ""
                        }
                    }
                }
                Section("说明") {
                    Text("当前稳定版使用系统 MapKit 与本地保存；高德 Key 仅用于给无图地点补一张封面。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
}
