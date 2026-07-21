import AppKit
import SwiftUI

struct ArtworkView: View {
  let remoteURL: URL?
  var localURL: URL? = nil
  var cornerRadius: CGFloat = 12
  @State private var remoteImage: NSImage?
  @State private var isLoading = false

  private static let ephemeralSession: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.urlCache = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    return URLSession(configuration: configuration)
  }()

  var body: some View {
    Group {
      if let localURL, let image = NSImage(contentsOf: localURL) {
        Image(nsImage: image)
          .resizable()
          .scaledToFill()
      } else if let remoteImage {
        Image(nsImage: remoteImage)
          .resizable()
          .scaledToFill()
      } else {
        ZStack {
          placeholder
          if isLoading { ProgressView().controlSize(.small) }
        }
      }
    }
    .clipped()
    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        .strokeBorder(.white.opacity(0.09))
    }
    .task(id: remoteURL) {
      remoteImage = nil
      guard localURL == nil, let remoteURL else {
        isLoading = false
        return
      }
      isLoading = true
      defer { isLoading = false }
      do {
        var request = URLRequest(url: remoteURL)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let (data, response) = try await Self.ephemeralSession.data(for: request)
        guard !Task.isCancelled,
          let response = response as? HTTPURLResponse,
          (200..<300).contains(response.statusCode)
        else { return }
        remoteImage = NSImage(data: data)
      } catch {
        // The gradient placeholder remains visible for network or decoding failures.
      }
    }
  }

  private var placeholder: some View {
    ZStack {
      LinearGradient(
        colors: [.purple.opacity(0.9), .pink.opacity(0.8), .orange.opacity(0.7)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
      Image(systemName: "music.note")
        .font(.system(size: 28, weight: .semibold))
        .foregroundStyle(.white.opacity(0.9))
    }
  }
}
