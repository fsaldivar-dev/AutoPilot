import SwiftUI

struct AuthView: View {
    @Environment(AppState.self) private var appState
    @State private var logoScale: CGFloat = 0.5
    @State private var logoOpacity: Double = 0
    @State private var buttonsOffset: CGFloat = 50
    @State private var buttonsOpacity: Double = 0
    @State private var isAuthenticating = false

    var body: some View {
        @Bindable var appState = appState

        ZStack {
            LinearGradient(
                colors: [Color(hex: "FF6B6B"), Color(hex: "FF8E53"), Color(hex: "F093FB")],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            // Decorative circles
            Circle()
                .fill(.white.opacity(0.1))
                .frame(width: 300, height: 300)
                .offset(x: -100, y: -250)

            Circle()
                .fill(.white.opacity(0.08))
                .frame(width: 200, height: 200)
                .offset(x: 150, y: 300)

            VStack(spacing: 40) {
                Spacer()

                // Logo area
                VStack(spacing: 16) {
                    ZStack {
                        Circle()
                            .fill(.white.opacity(0.2))
                            .frame(width: 120, height: 120)

                        Image(systemName: "airplane.circle.fill")
                            .font(.system(size: 70))
                            .foregroundStyle(.white)
                            .rotationEffect(.degrees(logoScale == 1 ? 0 : -30))
                    }
                    .scaleEffect(logoScale)
                    .opacity(logoOpacity)

                    VStack(spacing: 8) {
                        Text("Explorea")
                            .font(.system(size: 42, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)

                        Text("Tu diario de viajes")
                            .font(.title3)
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    .opacity(logoOpacity)
                }

                Spacer()

                // Auth buttons
                VStack(spacing: 16) {
                    if appState.showPinFallback {
                        pinEntryView
                    } else {
                        faceIDButton
                    }

                    if let error = appState.authError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.9))
                            .padding(.horizontal, 20)
                            .padding(.vertical, 8)
                            .background(.red.opacity(0.3))
                            .clipShape(Capsule())
                            .transition(.scale.combined(with: .opacity))
                    }

                    if !appState.showPinFallback {
                        Button {
                            withAnimation(.spring(response: 0.4)) {
                                appState.showPinFallback = true
                            }
                        } label: {
                            Text("Usar PIN")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.white.opacity(0.8))
                        }
                    } else {
                        Button {
                            withAnimation(.spring(response: 0.4)) {
                                appState.showPinFallback = false
                                appState.pinCode = ""
                                appState.authError = nil
                            }
                        } label: {
                            Text("Usar Face ID")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.white.opacity(0.8))
                        }
                    }
                }
                .offset(y: buttonsOffset)
                .opacity(buttonsOpacity)

                Spacer()
                    .frame(height: 60)
            }
            .padding(.horizontal, 32)
        }
        .onAppear {
            withAnimation(.spring(response: 0.8, dampingFraction: 0.6).delay(0.2)) {
                logoScale = 1
                logoOpacity = 1
            }
            withAnimation(.easeOut(duration: 0.6).delay(0.6)) {
                buttonsOffset = 0
                buttonsOpacity = 1
            }
        }
    }

    private var faceIDButton: some View {
        Button {
            isAuthenticating = true
            appState.authenticateWithBiometrics()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                isAuthenticating = false
            }
        } label: {
            HStack(spacing: 12) {
                if isAuthenticating {
                    ProgressView()
                        .tint(.white)
                } else {
                    Image(systemName: "faceid")
                        .font(.title2)
                }
                Text("Desbloquear con Face ID")
                    .font(.headline)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .background(.white.opacity(0.25))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(.white.opacity(0.4), lineWidth: 1)
            )
        }
        .disabled(isAuthenticating)
    }

    private var pinEntryView: some View {
        @Bindable var appState = appState

        return VStack(spacing: 20) {
            Text("Ingresa tu PIN")
                .font(.headline)
                .foregroundStyle(.white)

            HStack(spacing: 16) {
                ForEach(0..<4, id: \.self) { index in
                    Circle()
                        .fill(index < appState.pinCode.count ? .white : .white.opacity(0.3))
                        .frame(width: 16, height: 16)
                        .scaleEffect(index < appState.pinCode.count ? 1.2 : 1)
                        .animation(.spring(response: 0.3), value: appState.pinCode.count)
                }
            }

            // Number pad
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 12) {
                ForEach(1...9, id: \.self) { number in
                    pinButton(String(number))
                }
                pinButton("") // empty
                pinButton("0")
                pinDeleteButton
            }
            .padding(.horizontal, 20)

            Button {
                appState.authenticateWithPin()
            } label: {
                Text("Confirmar")
                    .font(.headline)
                    .foregroundStyle(AppTheme.primary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .disabled(appState.pinCode.count < 4)
            .opacity(appState.pinCode.count == 4 ? 1 : 0.5)
        }
        .transition(.asymmetric(
            insertion: .move(edge: .trailing).combined(with: .opacity),
            removal: .move(edge: .leading).combined(with: .opacity)
        ))
    }

    private func pinButton(_ digit: String) -> some View {
        Button {
            guard appState.pinCode.count < 4, !digit.isEmpty else { return }
            appState.pinCode += digit
            appState.triggerSelectionHaptic()
        } label: {
            Text(digit)
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 70, height: 55)
                .background(.white.opacity(digit.isEmpty ? 0 : 0.15))
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .disabled(digit.isEmpty)
    }

    private var pinDeleteButton: some View {
        Button {
            if !appState.pinCode.isEmpty {
                appState.pinCode.removeLast()
                appState.triggerSelectionHaptic()
            }
        } label: {
            Image(systemName: "delete.backward")
                .font(.title3)
                .foregroundStyle(.white)
                .frame(width: 70, height: 55)
                .background(.white.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }
}
