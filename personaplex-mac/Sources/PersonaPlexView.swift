import SwiftUI
import PersonaPlex

struct PersonaPlexView: View {
    @State private var vm = PersonaPlexViewModel()

    var body: some View {
        VStack(spacing: 16) {
            Text("PersonaPlex")
                .font(.largeTitle.bold())

            if !vm.modelLoaded && !vm.isLoading {
                Spacer()
                Picker("Precision", selection: $vm.precision) {
                    ForEach(ModelPrecision.allCases) { p in
                        Text("\(p.rawValue)  \(p.approxSize)").tag(p)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 320)
                Button("Load PersonaPlex \(vm.precision.rawValue)") {
                    Task { await vm.loadModel() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                Text("Loaded from the local HF cache — no download.\nInstall with: python3 mlxmgr.py install personaplex-mlx-8bit")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Spacer()
            }

            if vm.isLoading {
                Spacer()
                ProgressView()
                    .controlSize(.large)
                if let status = vm.loadingStatus {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                Spacer()
            }

            if vm.modelLoaded {
                modelLoadedContent
            }

            if let error = vm.errorMessage {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.caption)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(24)
        .frame(minWidth: 600, minHeight: 500)
    }

    @ViewBuilder
    private var modelLoadedContent: some View {
        // Settings row
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Voice").font(.caption).foregroundStyle(.secondary)
                Picker("Voice", selection: $vm.selectedVoice) {
                    Section("Natural Female") {
                        ForEach([PersonaPlexVoice.NATF0, .NATF1, .NATF2, .NATF3], id: \.self) { v in
                            Text(v.displayName).tag(v)
                        }
                    }
                    Section("Natural Male") {
                        ForEach([PersonaPlexVoice.NATM0, .NATM1, .NATM2, .NATM3], id: \.self) { v in
                            Text(v.displayName).tag(v)
                        }
                    }
                    Section("Variety Female") {
                        ForEach([PersonaPlexVoice.VARF0, .VARF1, .VARF2, .VARF3, .VARF4], id: \.self) { v in
                            Text(v.displayName).tag(v)
                        }
                    }
                    Section("Variety Male") {
                        ForEach([PersonaPlexVoice.VARM0, .VARM1, .VARM2, .VARM3, .VARM4], id: \.self) { v in
                            Text(v.displayName).tag(v)
                        }
                    }
                }
                .labelsHidden()
                .frame(width: 140)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Precision").font(.caption).foregroundStyle(.secondary)
                Picker("Precision", selection: $vm.precision) {
                    ForEach(ModelPrecision.allCases) { p in
                        Text(p.rawValue).tag(p)
                    }
                }
                .labelsHidden()
                .frame(width: 90)
                .onChange(of: vm.precision) {
                    // Swapping precision means swapping 7B of weights.
                    Task { await vm.loadModel() }
                }
            }

            if !vm.isFullDuplexMode {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Max Steps").font(.caption).foregroundStyle(.secondary)
                    Stepper("\(vm.maxSteps)", value: $vm.maxSteps, in: 50...500, step: 50)
                        .frame(width: 120)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text("Mode").font(.caption).foregroundStyle(.secondary)
                Picker("Mode", selection: $vm.isFullDuplexMode) {
                    Text("Turn-based").tag(false)
                    Text("Full-Duplex").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
            }

            if vm.isFullDuplexMode {
                VStack(alignment: .trailing, spacing: 4) {
                    Text("Echo Suppression").font(.caption).foregroundStyle(.secondary)
                    Toggle("", isOn: $vm.echoSuppression)
                        .labelsHidden()
                        .help("Enable when using speakers to prevent the mic from picking up agent audio. Disable when using headphones.")
                }
            }
        }
        .disabled(vm.isActive || vm.isBusy)

        Spacer()

        // Main conversation button
        VStack(spacing: 12) {
            conversationButton
            stateLabel
            if vm.isActive { inputMeter }
        }

        // Debug info
        if !vm.debugInfo.isEmpty {
            Text(vm.debugInfo)
                .font(.caption.monospaced())
                .foregroundStyle(.orange)
        }

        Spacer()

        // Latency info
        if let info = vm.latencyInfo {
            Text(info)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        }

        // Persona
        GroupBox("Persona") {
            TextEditor(text: $vm.personaPrompt)
                .font(.callout)
                .frame(height: 60)
                .disabled(vm.isActive)
        }

        // Transcripts
        if !vm.modelTranscript.isEmpty {
            VStack(spacing: 8) {
                if !vm.modelTranscript.isEmpty {
                    GroupBox("Model response") {
                        ScrollView {
                            Text(vm.modelTranscript)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 80)
                    }
                }
            }
        }
    }

    /// Explicit input meter.
    ///
    /// The orb's ring already scales with level, but a 3pt stroke change is not
    /// something you can read while also judging whether the model is talking
    /// over you. When the complaint is "it ignores my mic", the first question
    /// is whether any signal arrives at all — this answers it without a log.
    @ViewBuilder
    private var inputMeter: some View {
        // Speech sits around -30 dBFS; the room floor is well below that.
        let db = 20 * log10(max(vm.audioLevel, 1e-7))
        let frac = min(max((db + 60) / 60, 0), 1)   // -60 dBFS .. 0 dBFS
        let silent = db < -55

        VStack(spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: silent ? "mic.slash" : "mic.fill")
                    .foregroundStyle(silent ? Color.secondary : Color.green)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.secondary.opacity(0.18))
                        Capsule()
                            .fill(frac > 0.85 ? Color.orange : Color.green)
                            .frame(width: geo.size.width * CGFloat(frac))
                    }
                }
                .frame(height: 6)
                Text(silent ? "--" : String(format: "%.0f dB", db))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 52, alignment: .trailing)
            }
            if silent && vm.isActive {
                Text("No input detected — check System Settings > Privacy > Microphone, "
                     + "and that the right input device is selected.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: 320)
    }

    @ViewBuilder
    private var conversationButton: some View {
        let size: CGFloat = 100

        Button {
            vm.toggleConversation()
        } label: {
            ZStack {
                Circle()
                    .fill(buttonColor)
                    .frame(width: size, height: size)
                    .overlay {
                        if vm.conversationState == .listening || vm.conversationState == .fullDuplex {
                            Circle()
                                .stroke(Color.white.opacity(0.6), lineWidth: 3 + CGFloat(vm.audioLevel) * 12)
                                .frame(width: size + 10, height: size + 10)
                        }
                    }
                    .overlay {
                        buttonIcon
                    }
                    .shadow(color: buttonShadow, radius: 10)
            }
        }
        .buttonStyle(.plain)
        .disabled(vm.isBusy)
        .animation(.easeInOut(duration: 0.3), value: vm.conversationState)
    }

    private var buttonColor: Color {
        switch vm.conversationState {
        case .inactive: return .accentColor
        case .listening: return .green
        case .processing: return .orange
        case .speaking: return .purple
        case .fullDuplex: return .teal
        }
    }

    private var buttonShadow: Color {
        switch vm.conversationState {
        case .inactive: return .clear
        case .listening: return .green.opacity(0.4)
        case .processing: return .orange.opacity(0.4)
        case .speaking: return .purple.opacity(0.4)
        case .fullDuplex: return .teal.opacity(0.4)
        }
    }

    @ViewBuilder
    private var buttonIcon: some View {
        switch vm.conversationState {
        case .inactive:
            Image(systemName: "mic.fill")
                .font(.system(size: 36))
                .foregroundStyle(.white)
        case .listening:
            Image(systemName: "waveform")
                .font(.system(size: 36))
                .foregroundStyle(.white)
        case .processing:
            ProgressView()
                .controlSize(.large)
                .tint(.white)
        case .speaking:
            Image(systemName: "speaker.wave.2.fill")
                .font(.system(size: 36))
                .foregroundStyle(.white)
        case .fullDuplex:
            Image(systemName: "waveform.and.mic")
                .font(.system(size: 36))
                .foregroundStyle(.white)
        }
    }

    @ViewBuilder
    private var stateLabel: some View {
        switch vm.conversationState {
        case .inactive:
            Text("Tap to start conversation")
                .font(.callout)
                .foregroundStyle(.secondary)
        case .listening:
            Text("Listening... speak now")
                .font(.callout)
                .foregroundStyle(.green)
        case .processing:
            Text("Generating response...")
                .font(.callout)
                .foregroundStyle(.orange)
        case .speaking:
            Text("Speaking... tap to stop")
                .font(.callout)
                .foregroundStyle(.purple)
        case .fullDuplex:
            Text("Full-duplex active... tap to stop")
                .font(.callout)
                .foregroundStyle(.teal)
        }
    }
}
