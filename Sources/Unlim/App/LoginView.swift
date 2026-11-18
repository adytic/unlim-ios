import CoreImage
import SwiftUI
import UIKit

/// Login flow driven by the TDLib authorization state machine.
/// One screen per waiting state: phone → code → 2FA password, or QR code.
struct LoginView: View {
    @EnvironmentObject private var appState: AppState
    @State private var phoneNumber = ""
    @State private var code = ""
    @State private var password = ""
    @State private var errorMessage: String?
    @State private var isBusy = false

    var body: some View {
        NavigationView {
            VStack(spacing: 16) {
                switch appState.auth.state {
                case .waitPhoneNumber:
                    phoneStep
                case .waitCode:
                    codeStep
                case .waitPassword:
                    passwordStep
                case .waitOtherDeviceConfirmation:
                    qrStep
                case .waitRegistration:
                    Text("This Telegram account needs to finish registration in the official Telegram app first, then log in here again.")
                        .multilineTextAlignment(.center)
                default:
                    ProgressView("Connecting to Telegram…")
                }
                if let errorMessage {
                    Text(errorMessage)
                        .foregroundColor(.red)
                        .font(.callout)
                }
            }
            .padding()
            .navigationTitle("Unlim")
        }
    }

    private var phoneStep: some View {
        Group {
            Text("Log in with your Telegram account.")
            TextField("Phone number (e.g. +62812…)", text: $phoneNumber)
                .keyboardType(.phonePad)
                .textFieldStyle(.roundedBorder)
                .autocapitalization(.none)
                .disableAutocorrection(true)
            Button("Send code") {
                run { try await appState.auth.sendPhoneNumber(phoneNumber) }
            }
            .buttonStyle(.borderedProminent)
            .disabled(phoneNumber.isEmpty || isBusy)
            Button("Log in with QR code") {
                run { _ = try await appState.auth.requestQRCode() }
            }
            .disabled(isBusy)
        }
    }

    private var codeStep: some View {
        Group {
            Text("Enter the code Telegram sent to \(phoneNumber).")
            TextField("Code", text: $code)
                .keyboardType(.numberPad)
                .textFieldStyle(.roundedBorder)
            Button("Confirm code") {
                run { try await appState.auth.sendCode(code) }
            }
            .buttonStyle(.borderedProminent)
            .disabled(code.isEmpty || isBusy)
        }
    }

    private var passwordStep: some View {
        Group {
            Text("Enter your two-step verification password.")
            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
            Button("Confirm password") {
                run { try await appState.auth.sendPassword(password) }
            }
            .buttonStyle(.borderedProminent)
            .disabled(password.isEmpty || isBusy)
        }
    }

    private var qrStep: some View {
        Group {
            Text("Scan this code in Telegram (Settings → Devices → Link Desktop Device).")
                .multilineTextAlignment(.center)
            if let link = appState.auth.qrLink, let image = qrImage(for: link) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 220, height: 220)
            } else {
                Button("Show QR code") {
                    run { _ = try await appState.auth.requestQRCode() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isBusy)
            }
        }
    }

    private func qrImage(for string: String) -> UIImage? {
        guard let data = string.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator")
        else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        return UIImage(ciImage: scaled)
    }

    private func run(_ work: @escaping () async throws -> Void) {
        errorMessage = nil
        isBusy = true
        Task {
            do {
                try await work()
            } catch {
                errorMessage = error.localizedDescription
            }
            isBusy = false
        }
    }
}
