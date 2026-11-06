import SwiftUI

struct P32MeasurementDetails: View {
    let measurement: Measurement
    let isLive: Bool
    let onExport: (String, String) -> Void

    @State private var showsSamples = false

    var body: some View {
        let sections = detailSections
        VStack(alignment: .leading, spacing: 14) {
            header

            HStack(spacing: 10) {
                Picker("显示内容", selection: $showsSamples) {
                    Text("设备参数").tag(false)
                    Text("波长采样").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text("\(measurement.points.count) 个采样点")
                    .font(InstrumentFont.style(.caption, light: true))
                    .foregroundStyle(InstrumentColor.secondary)
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 8)
            .instrumentPanel(cornerRadius: 11)

            if showsSamples {
                Table(measurement.points) {
                    TableColumn("波长") { point in
                        Text("\(point.wavelength) nm").font(InstrumentFont.style(.body))
                    }
                    TableColumn("光谱值") { point in
                        Text(String(format: "%.9g", point.value)).font(InstrumentFont.style(.body))
                    }
                }
                .scrollContentBackground(.hidden)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .instrumentPanel(cornerRadius: 14)
            } else {
                ScrollView {
                    let column = GridItem(.flexible(minimum: 254), spacing: 12, alignment: .top)
                    LazyVGrid(columns: [column, column], alignment: .leading, spacing: 12) {
                        ForEach(sections) { section in
                            detailCard(section)
                        }
                    }
                    .padding(1)
                }
            }

            HStack {
                Spacer()
                Button {
                    if showsSamples {
                        onExport(measurement.csv, "-p32-spectrum")
                    } else {
                        let rows = sections.flatMap(\.rows).map { row in
                            [row.key, row.title, row.value, row.unit].map { field in
                                "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
                            }.joined(separator: ",")
                        }
                        onExport("field,label,value,unit\r\n" + rows.joined(separator: "\r\n") + "\r\n", "-p32-metrics")
                    }
                } label: {
                    InstrumentFont.controlLabel(showsSamples ? "导出光谱 CSV…" : "导出参数 CSV…",
                                                systemImage: "square.and.arrow.down")
                }
                .instrumentButton(prominent: true)
            }
        }
        .padding(20)
        .foregroundStyle(InstrumentColor.text)
    }

    private var header: some View {
        HStack(spacing: 11) {
            Image(systemName: "list.bullet.rectangle")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(InstrumentColor.teal)
                .frame(width: 40, height: 40)
                .instrumentPanel(cornerRadius: 12)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text("P32 测量详情")
                    .font(InstrumentFont.style(.title2))
                Text(measurement.capturedAt.formatted(date: .abbreviated, time: .standard))
                    .font(InstrumentFont.style(.caption, light: true))
                    .foregroundStyle(InstrumentColor.secondary)
            }
            Spacer()
            if isLive {
                Label("连续测量中", systemImage: "dot.radiowaves.left.and.right")
                    .font(InstrumentFont.style(.caption))
                    .foregroundStyle(InstrumentColor.teal)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(.thinMaterial, in: Capsule())
            }
        }
    }

    private func detailCard(_ section: DetailSection) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(section.title, systemImage: section.symbol)
                .font(InstrumentFont.style(.headline))
                .foregroundStyle(InstrumentColor.teal)
                .accessibilityAddTraits(.isHeader)
            Divider()
            VStack(alignment: .leading, spacing: 7) {
                ForEach(section.rows) { row in
                    LabeledContent {
                        Text(row.displayValue)
                            .font(InstrumentFont.style(.callout))
                            .foregroundStyle(InstrumentColor.text)
                            .multilineTextAlignment(.trailing)
                    } label: {
                        Text(row.title)
                            .font(InstrumentFont.style(.callout, light: true))
                            .foregroundStyle(InstrumentColor.secondary)
                    }
                }
            }
            .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(13)
        .instrumentPanel(cornerRadius: 14)
    }

    private var detailSections: [DetailSection] {
        let device = measurement.device
        return [
            DetailSection(title: "设备与采集", symbol: "dot.radiowaves.left.and.right", rows: [
                DetailRow("model", "型号", device.model),
                DetailRow("firmware", "固件", device.firmware),
                DetailRow("serial", "序列号", device.serial),
                DetailRow("captured_at", "采集时间 (UTC)", measurement.capturedAt.ISO8601Format()),
                DetailRow("port", "串口", device.port),
                DetailRow("baud", "波特率", String(device.baud), "bps"),
                DetailRow("range", "采样范围", "\(device.startNM)–\(device.endNM)", "nm"),
                DetailRow("samples", "采样点数", String(measurement.points.count)),
                DetailRow("exposure", "曝光状态", measurement.exposure.label),
                DetailRow("exposure_us", "曝光时间", String(measurement.exposureUS), "µs"),
                DetailRow("spectral_exponent", "光谱缩放指数", String(measurement.spectralExponent)),
            ]),
            DetailSection(title: "光度与光谱", symbol: "waveform.path", rows: [
                metric("lux", "照度", "lx"),
                metric("CCT", "相关色温", "K"),
                metric("DUV", "黑体轨迹偏差 Duv"),
                metric("Lp", "峰值波长", "nm"),
                metric("HW", "半峰全宽", "nm"),
                metric("Ld", "主波长", "nm"),
                metric("purity", "色纯度", "%"),
                metric("SP", "S/P（设备原值）"),
                metric("SDCM", "色容差 SDCM"),
                metric("k", "色容差参考色温", "K"),
            ]),
            DetailSection(title: "色坐标与三刺激值", symbol: "scope", rows: [
                metric("X", "三刺激值 X"), metric("Y", "三刺激值 Y"), metric("Z", "三刺激值 Z"),
                metric("x", "CIE 1931 x"), metric("y", "CIE 1931 y"),
                metric("u", "CIE 1960 u"), metric("v", "CIE 1960 v"),
                metric("u′", "CIE 1976 u′"), metric("v′", "CIE 1976 v′"),
                metric("r_ratio", "红色比", "%"), metric("g_ratio", "绿色比", "%"),
                metric("b_ratio", "蓝色比", "%"),
            ]),
            DetailSection(title: "显色指数", symbol: "paintpalette", rows: [metric("Ra", "一般显色指数 Ra")]
                + (1...14).map { metric("R\($0)", "R\($0)") }),
        ]
    }

    private func metric(_ key: String, _ title: String, _ unit: String = "") -> DetailRow {
        DetailRow(key, title, measurement.p32Metrics?[key].map { String($0) } ?? "", unit)
    }
}

private struct DetailSection: Identifiable {
    let title: String
    let symbol: String
    let rows: [DetailRow]
    var id: String { title }
}

private struct DetailRow: Identifiable {
    let key: String
    let title: String
    let value: String
    let unit: String

    var id: String { key }

    var displayValue: String {
        if value.isEmpty { return "—" }
        if ["nan", "inf", "-inf"].contains(value) { return "无有效读数 (\(value))" }
        return unit.isEmpty ? value : "\(value) \(unit)"
    }

    init(_ key: String, _ title: String, _ value: String, _ unit: String = "") {
        self.key = key
        self.title = title
        self.value = value
        self.unit = unit
    }
}
