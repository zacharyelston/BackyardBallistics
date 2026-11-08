import SwiftUI
import PhotosUI
import UIKit
import CoreLocation
import CoreGeo
import GroupKit

/// A field note: what you see, where you are (GPS and its ±), an optional photo, and which field.
/// Sent to the Theater host, or to the squad leader when you're in a squad (who passes it on).
struct FieldNoteView: View {
    @EnvironmentObject private var theater: TheaterLink
    @EnvironmentObject private var membership: SquadMembership
    @EnvironmentObject private var courses: CourseStore
    @AppStorage(Settings.playerNameKey) private var player = Settings.defaultPlayerName
    @StateObject private var gps = SurveySampler()

    enum Destination: Hashable { case theater, leader }

    @State private var text = ""
    @State private var courseID = ""
    @State private var includeLocation = true
    @State private var photo: Data?
    @State private var pickedItem: PhotosPickerItem?
    @State private var takingPhoto = false
    @State private var destination: Destination = .theater
    @State private var sentToTheater: [UUID] = []
    @State private var leaderProblem: String?

    var body: some View {
        Form {
            Section {
                TextField("What do you see? A hazard, a better firing point, a soft patch…", text: $text, axis: .vertical)
                    .lineLimit(3...8)
                    .onChange(of: text) { _, t in if t.count > FieldNote.maxText { text = String(t.prefix(FieldNote.maxText)) } }
                Text("\(text.count) of \(FieldNote.maxText)").font(.caption2).foregroundStyle(.secondary)
            } header: {
                Text("Note")
            }

            Section {
                Toggle("Pin it where I'm standing", isOn: $includeLocation)
                if includeLocation {
                    if let fix = gps.latest {
                        LabeledContent("GPS", value: String(format: "%.6f, %.6f  ±%.0f m", fix.coordinate.latitude, fix.coordinate.longitude, fix.horizontalAccuracy))
                            .font(.footnote.monospacedDigit())
                    } else if gps.authorization == .denied || gps.authorization == .restricted {
                        Text("Location is off for SpudGunGolf. The note goes without a pin.").font(.footnote).foregroundStyle(.orange)
                    } else {
                        HStack { ProgressView(); Text("Waiting for GPS…").foregroundStyle(.secondary) }
                    }
                }
                TextField("Field", text: $courseID).autocorrectionDisabled().textInputAutocapitalization(.never)
            } header: {
                Text("Where")
            } footer: {
                Text("The field is the course's ID; it starts as the course loaded on this phone.")
            }

            photoSection

            Section {
                Picker("Send to", selection: $destination) {
                    Text("Theater").tag(Destination.theater)
                    Text("Squad leader").tag(Destination.leader)
                }
                .pickerStyle(.segmented)
                .disabled(!membership.isInSquad)
            } footer: {
                Text(membership.isInSquad ? "Your squad leader passes notes on to the Theater."
                                          : "Join a squad to send notes to its leader.")
            }

            if destination == .theater {
                TheaterPickerSections()
            }

            Section {
                Button {
                    send()
                } label: {
                    Label(destination == .theater ? "Send to Theater" : "Send to my squad leader", systemImage: "paperplane.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSend)
                if let leaderProblem { Text(leaderProblem).font(.footnote).foregroundStyle(.red) }
            }

            if destination == .theater {
                TheaterItemsSection(ids: sentToTheater.isEmpty ? nil : sentToTheater)
            } else if !membership.sentToLeader.isEmpty {
                Section {
                    ForEach(membership.sentToLeader) { s in
                        SentItemRow(title: s.title, receipt: s.receipt)
                    }
                } header: {
                    Text("Sent to the squad leader")
                }
            }
        }
        .navigationTitle("Field note")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            gps.start()
            theater.startBrowsing()
            if courseID.isEmpty { courseID = courses.loaded?.result.course?.id ?? courses.practiceCourse?.id ?? "" }
            if membership.isInSquad { destination = .leader }
        }
        .onDisappear {
            gps.stop()
            theater.stopBrowsing()
        }
        .onChange(of: pickedItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                    photo = PhotoShrinker.jpeg(image, under: FieldNote.maxInlinePhotoBytes)
                }
            }
        }
        .fullScreenCover(isPresented: $takingPhoto) {
            CameraPicker { image in
                if let image { photo = PhotoShrinker.jpeg(image, under: FieldNote.maxInlinePhotoBytes) }
                takingPhoto = false
            }
            .ignoresSafeArea()
        }
    }

    @ViewBuilder private var photoSection: some View {
        Section {
            if let photo, let image = UIImage(data: photo) {
                Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                HStack {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(photo.count), countStyle: .file))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Remove", role: .destructive) { self.photo = nil; pickedItem = nil }.font(.footnote)
                }
            }
            HStack {
                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    Button { takingPhoto = true } label: { Label("Camera", systemImage: "camera") }
                        .buttonStyle(.bordered)
                }
                PhotosPicker(selection: $pickedItem, matching: .images) {
                    Label("Library", systemImage: "photo.on.rectangle")
                }
                .buttonStyle(.bordered)
            }
        } header: {
            Text("Photo (optional)")
        } footer: {
            Text("Shrunk to under 300 KB so it travels with the note.")
        }
    }

    private var canSend: Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || photo != nil else { return false }
        return destination == .theater ? theater.isReady : membership.canSendToLeader
    }

    private func note() -> FieldNote {
        let fix = includeLocation ? gps.latest : nil
        let id = courseID.trimmingCharacters(in: .whitespaces)
        return FieldNote(author: player, time: Date(), courseID: id.isEmpty ? nil : id,
                         at: fix.map { GeoPoint(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude) },
                         accuracy: fix?.horizontalAccuracy, text: text.trimmingCharacters(in: .whitespacesAndNewlines), photo: photo)
    }

    private func send() {
        leaderProblem = nil
        let n = note()
        switch destination {
        case .theater:
            sentToTheater = theater.send([.note(n)]) + sentToTheater
            reset()
        case .leader:
            if membership.sendNote(n) != nil { reset() } else { leaderProblem = "Not linked to the squad's iPad right now. Try again in a moment." }
        }
    }

    private func reset() {
        text = ""
        photo = nil
        pickedItem = nil
    }
}

/// Shrinks a photo to a JPEG under a byte limit: first down to 1600 px on the long side, then
/// lower quality, then smaller again.
enum PhotoShrinker {
    static func jpeg(_ image: UIImage, under limit: Int) -> Data? {
        var side: CGFloat = 1600
        while side >= 320 {
            let resized = resize(image, longSide: side)
            for q in stride(from: 0.8, through: 0.35, by: -0.15) {
                if let d = resized.jpegData(compressionQuality: q), d.count <= limit { return d }
            }
            side *= 0.75
        }
        return nil
    }

    static func resize(_ image: UIImage, longSide: CGFloat) -> UIImage {
        let s = image.size
        let scale = min(1, longSide / max(s.width, s.height))
        guard scale < 1 else { return image }
        let size = CGSize(width: (s.width * scale).rounded(), height: (s.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
    }
}

/// The system camera, for a note's photo.
struct CameraPicker: UIViewControllerRepresentable {
    let done: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let p = UIImagePickerController()
        p.sourceType = .camera
        p.delegate = context.coordinator
        return p
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(done: done) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let done: (UIImage?) -> Void
        init(done: @escaping (UIImage?) -> Void) { self.done = done }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            done(info[.originalImage] as? UIImage)
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { done(nil) }
    }
}
