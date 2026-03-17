import SwiftUI
import SwiftData

@main
struct QuotaBarApp: App {
  private let sharedModelContainer: ModelContainer
  @StateObject private var viewModel: ProviderMonitorViewModel
  
  init() {
    do {
      let schema = Schema([
        ProviderAccountRecord.self,
      ])
      let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
      let modelContainer = try ModelContainer(for: schema, configurations: [configuration])
      let credentialStore = KeychainCredentialStore()
      let service = CodexAccountService(
        modelContext: modelContainer.mainContext,
        credentialStore: credentialStore
      )
      let viewModel = ProviderMonitorViewModel(service: service)
      
      self.sharedModelContainer = modelContainer
      _viewModel = StateObject(wrappedValue: viewModel)
      Task {
        await viewModel.bootstrap()
      }
    } catch {
      fatalError("Could not initialize QuotaBar: \(error)")
    }
  }
  
  var body: some Scene {
    MenuBarExtra {
      ContentView(viewModel: viewModel)
        .modelContainer(sharedModelContainer)
    } label: {
      if let nsImage = NSImage(named: "StatusBarIcon") {
        let _ = {
          let height: CGFloat = 18
          let ratio = nsImage.size.width / nsImage.size.height
          nsImage.size = NSSize(width: height * ratio, height: height)
        }()
        Image(nsImage: nsImage)
      }
    }
    .menuBarExtraStyle(.window)
    
    Window("QuotaBar Settings", id: "settings") {
      SettingsView(viewModel: viewModel)
        .modelContainer(sharedModelContainer)
    }
  }
}
